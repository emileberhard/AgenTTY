use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::extract::ws::{CloseFrame, Message, close_code};
use serde::Serialize;
use thiserror::Error;
use tokio::sync::mpsc;

const BUFFER_LIMIT_BYTES: usize = 256 * 1024;

#[derive(Clone)]
pub struct RelayBroker {
    inner: Arc<Mutex<RelayBrokerState>>,
}

#[derive(Debug, Error)]
pub enum RelayBrokerError {
    #[error("relay admission is fenced for maintenance")]
    Draining,
    #[error("relay session capacity reached")]
    CapacityReached,
    #[error("relay session was not found")]
    SessionNotFound,
    #[error("relay session side already attached")]
    AlreadyAttached,
    #[error("relay session buffer exceeded limit")]
    BufferLimitExceeded,
    #[error("relay session peer is already closed")]
    PeerClosed,
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ConnectorControlMessage {
    OpenSshRelaySession {
        expires_at_epoch_seconds: i64,
        relay_session_id: String,
        authorization_token: String,
        websocket_url: String,
    },
}

#[derive(Default)]
struct RelayBrokerState {
    connectors_by_relay_host: HashMap<String, LiveConnector>,
    sessions_by_id: HashMap<String, LiveRelaySession>,
    next_control_connection_id: u64,
    draining: bool,
}

#[derive(Clone)]
struct LiveConnector {
    control_connection_id: u64,
    control_tx: mpsc::UnboundedSender<ConnectorControlMessage>,
}

struct LiveRelaySession {
    relay_host_id: String,
    expires_at_epoch_seconds: i64,
    open_request_control_connection_id: Option<u64>,
    connector_authorization_token: String,
    connector_websocket_url: String,
    app_tx: Option<RelayPeerTx>,
    connector_tx: Option<RelayPeerTx>,
    pending_app_frames: Vec<Vec<u8>>,
    pending_app_bytes: usize,
    pending_connector_frames: Vec<Vec<u8>>,
    pending_connector_bytes: usize,
}

#[derive(Clone)]
pub struct RelayPeerTx {
    queued_bytes: Arc<AtomicUsize>,
    tx: mpsc::UnboundedSender<QueuedRelayMessage>,
}

pub struct QueuedRelayMessage {
    pub byte_cost: usize,
    pub message: Message,
}

pub fn relay_peer_channel() -> (RelayPeerTx, mpsc::UnboundedReceiver<QueuedRelayMessage>) {
    let (tx, rx) = mpsc::unbounded_channel();
    (
        RelayPeerTx {
            queued_bytes: Arc::new(AtomicUsize::new(0)),
            tx,
        },
        rx,
    )
}

impl RelayPeerTx {
    pub fn release_queue_bytes(&self, byte_cost: usize) {
        if byte_cost == 0 {
            return;
        }
        self.queued_bytes.fetch_sub(byte_cost, Ordering::AcqRel);
    }

    fn reserve_queue_bytes(&self, byte_cost: usize) -> Result<(), RelayBrokerError> {
        loop {
            let current = self.queued_bytes.load(Ordering::Acquire);
            let next = current
                .checked_add(byte_cost)
                .ok_or(RelayBrokerError::BufferLimitExceeded)?;
            if next > BUFFER_LIMIT_BYTES {
                return Err(RelayBrokerError::BufferLimitExceeded);
            }
            if self
                .queued_bytes
                .compare_exchange(current, next, Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
            {
                return Ok(());
            }
        }
    }

    fn send_binary(&self, data: Vec<u8>) -> Result<(), RelayBrokerError> {
        let byte_cost = data.len();
        self.reserve_queue_bytes(byte_cost)?;
        if self
            .tx
            .send(QueuedRelayMessage {
                byte_cost,
                message: Message::Binary(data.into()),
            })
            .is_err()
        {
            self.release_queue_bytes(byte_cost);
            return Err(RelayBrokerError::PeerClosed);
        }
        Ok(())
    }

    fn send_close(&self, close_frame: Option<CloseFrame>) {
        let _ = self.tx.send(QueuedRelayMessage {
            byte_cost: 0,
            message: Message::Close(close_frame),
        });
    }
}

#[derive(Serialize)]
pub struct DrainStatus {
    pub process_id: u32,
    pub draining: bool,
    pub active_ssh_sessions: usize,
}

impl RelayBroker {
    pub fn drain_status(&self) -> DrainStatus {
        let state = self.inner.lock().expect("relay broker lock poisoned");
        state.drain_status()
    }

    pub fn fence(&self) -> DrainStatus {
        let mut state = self.inner.lock().expect("relay broker lock poisoned");
        state.draining = true;
        state.drain_status()
    }

    pub fn resume(&self) -> DrainStatus {
        let mut state = self.inner.lock().expect("relay broker lock poisoned");
        state.draining = false;
        state.drain_status()
    }

    pub async fn wait_for_idle(&self, bound: Duration) -> bool {
        tokio::time::timeout(bound, async {
            loop {
                if self.drain_status().active_ssh_sessions == 0 {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        })
        .await
        .is_ok()
    }

    pub fn is_connector_online(&self, relay_host_id: &str) -> bool {
        let state = self.inner.lock().expect("relay broker lock poisoned");
        state.connectors_by_relay_host.contains_key(relay_host_id)
    }

    pub fn register_connector_control(
        &self,
        relay_host_id: String,
        _connector_id: String,
        control_tx: mpsc::UnboundedSender<ConnectorControlMessage>,
    ) -> u64 {
        let mut state = self.inner.lock().expect("relay broker lock poisoned");
        state.cleanup_expired_sessions();
        let control_connection_id = state.next_control_connection_id;
        state.next_control_connection_id = state.next_control_connection_id.wrapping_add(1);
        state.connectors_by_relay_host.insert(
            relay_host_id.clone(),
            LiveConnector {
                control_connection_id,
                control_tx: control_tx.clone(),
            },
        );

        for (relay_session_id, session) in &mut state.sessions_by_id {
            if session.relay_host_id != relay_host_id
                || session.connector_tx.is_some()
                || session.open_request_control_connection_id == Some(control_connection_id)
            {
                continue;
            }
            if control_tx
                .send(ConnectorControlMessage::OpenSshRelaySession {
                    expires_at_epoch_seconds: session.expires_at_epoch_seconds,
                    relay_session_id: relay_session_id.clone(),
                    authorization_token: session.connector_authorization_token.clone(),
                    websocket_url: session.connector_websocket_url.clone(),
                })
                .is_ok()
            {
                session.open_request_control_connection_id = Some(control_connection_id);
            }
        }

        control_connection_id
    }

    pub fn unregister_connector_control(&self, relay_host_id: &str, control_connection_id: u64) {
        let mut state = self.inner.lock().expect("relay broker lock poisoned");
        let should_remove = state
            .connectors_by_relay_host
            .get(relay_host_id)
            .map(|connector| connector.control_connection_id == control_connection_id)
            .unwrap_or(false);
        if should_remove {
            state.connectors_by_relay_host.remove(relay_host_id);
        }
    }

    pub fn create_session(
        &self,
        relay_host_id: String,
        relay_session_id: String,
        expires_at_epoch_seconds: i64,
        connector_authorization_token: String,
        connector_websocket_url: String,
    ) -> Result<(), RelayBrokerError> {
        let mut state = self.inner.lock().expect("relay broker lock poisoned");
        state.cleanup_expired_sessions();
        if state.draining {
            return Err(RelayBrokerError::Draining);
        }
        if state.sessions_by_id.len() >= 32
            || state
                .sessions_by_id
                .values()
                .filter(|session| session.relay_host_id == relay_host_id)
                .count()
                >= 4
        {
            return Err(RelayBrokerError::CapacityReached);
        }
        let mut session = LiveRelaySession {
            relay_host_id: relay_host_id.clone(),
            expires_at_epoch_seconds,
            open_request_control_connection_id: None,
            connector_authorization_token,
            connector_websocket_url,
            app_tx: None,
            connector_tx: None,
            pending_app_frames: Vec::new(),
            pending_app_bytes: 0,
            pending_connector_frames: Vec::new(),
            pending_connector_bytes: 0,
        };

        if let Some(connector) = state.connectors_by_relay_host.get(&relay_host_id)
            && connector
                .control_tx
                .send(ConnectorControlMessage::OpenSshRelaySession {
                    expires_at_epoch_seconds,
                    relay_session_id: relay_session_id.clone(),
                    authorization_token: session.connector_authorization_token.clone(),
                    websocket_url: session.connector_websocket_url.clone(),
                })
                .is_ok()
        {
            session.open_request_control_connection_id = Some(connector.control_connection_id);
        }

        state.sessions_by_id.insert(relay_session_id, session);
        Ok(())
    }

    pub fn attach_app(
        &self,
        relay_session_id: &str,
        app_tx: RelayPeerTx,
    ) -> Result<(), RelayBrokerError> {
        let mut state = self.inner.lock().expect("relay broker lock poisoned");
        state.cleanup_expired_sessions();
        let draining = state.draining;
        let existing_control = state.connectors_by_relay_host.clone();
        let session = state
            .sessions_by_id
            .get_mut(relay_session_id)
            .ok_or(RelayBrokerError::SessionNotFound)?;
        if draining && session.app_tx.is_none() && session.connector_tx.is_none() {
            return Err(RelayBrokerError::Draining);
        }
        if session.app_tx.is_some() {
            return Err(RelayBrokerError::AlreadyAttached);
        }

        let pending_connector_frames = std::mem::take(&mut session.pending_connector_frames);
        session.pending_connector_bytes = 0;
        session.app_tx = Some(app_tx.clone());
        for frame in pending_connector_frames {
            app_tx.send_binary(frame)?;
        }

        if let Some(connector) = existing_control.get(&session.relay_host_id).cloned()
            && session.connector_tx.is_none()
            && session.open_request_control_connection_id != Some(connector.control_connection_id)
            && connector
                .control_tx
                .send(ConnectorControlMessage::OpenSshRelaySession {
                    expires_at_epoch_seconds: session.expires_at_epoch_seconds,
                    relay_session_id: relay_session_id.to_owned(),
                    authorization_token: session.connector_authorization_token.clone(),
                    websocket_url: session.connector_websocket_url.clone(),
                })
                .is_ok()
        {
            session.open_request_control_connection_id = Some(connector.control_connection_id);
        }

        Ok(())
    }

    pub fn attach_connector(
        &self,
        relay_session_id: &str,
        connector_tx: RelayPeerTx,
    ) -> Result<(), RelayBrokerError> {
        let mut state = self.inner.lock().expect("relay broker lock poisoned");
        state.cleanup_expired_sessions();
        let draining = state.draining;
        let session = state
            .sessions_by_id
            .get_mut(relay_session_id)
            .ok_or(RelayBrokerError::SessionNotFound)?;
        if draining && session.app_tx.is_none() && session.connector_tx.is_none() {
            return Err(RelayBrokerError::Draining);
        }
        if session.connector_tx.is_some() {
            return Err(RelayBrokerError::AlreadyAttached);
        }
        let pending_app_frames = std::mem::take(&mut session.pending_app_frames);
        session.pending_app_bytes = 0;
        session.connector_tx = Some(connector_tx.clone());
        for frame in pending_app_frames {
            connector_tx.send_binary(frame)?;
        }
        Ok(())
    }

    pub fn forward_from_app(
        &self,
        relay_session_id: &str,
        data: Vec<u8>,
    ) -> Result<(), RelayBrokerError> {
        let mut state = self.inner.lock().expect("relay broker lock poisoned");
        let session = state
            .sessions_by_id
            .get_mut(relay_session_id)
            .ok_or(RelayBrokerError::SessionNotFound)?;
        if let Some(connector_tx) = &session.connector_tx {
            connector_tx.send_binary(data)?;
            return Ok(());
        }

        session.pending_app_bytes = session
            .pending_app_bytes
            .checked_add(data.len())
            .ok_or(RelayBrokerError::BufferLimitExceeded)?;
        if session.pending_app_bytes > BUFFER_LIMIT_BYTES {
            return Err(RelayBrokerError::BufferLimitExceeded);
        }
        session.pending_app_frames.push(data);
        Ok(())
    }

    pub fn forward_from_connector(
        &self,
        relay_session_id: &str,
        data: Vec<u8>,
    ) -> Result<(), RelayBrokerError> {
        let mut state = self.inner.lock().expect("relay broker lock poisoned");
        let session = state
            .sessions_by_id
            .get_mut(relay_session_id)
            .ok_or(RelayBrokerError::SessionNotFound)?;
        if let Some(app_tx) = &session.app_tx {
            app_tx.send_binary(data)?;
            return Ok(());
        }

        session.pending_connector_bytes = session
            .pending_connector_bytes
            .checked_add(data.len())
            .ok_or(RelayBrokerError::BufferLimitExceeded)?;
        if session.pending_connector_bytes > BUFFER_LIMIT_BYTES {
            return Err(RelayBrokerError::BufferLimitExceeded);
        }
        session.pending_connector_frames.push(data);
        Ok(())
    }

    pub fn close_session(&self, relay_session_id: &str, reason: &str) {
        let mut state = self.inner.lock().expect("relay broker lock poisoned");
        let Some(session) = state.sessions_by_id.remove(relay_session_id) else {
            return;
        };
        let close_frame = Some(CloseFrame {
            code: close_code::NORMAL,
            reason: reason.to_owned().into(),
        });
        if let Some(app_tx) = session.app_tx {
            app_tx.send_close(close_frame.clone());
        }
        if let Some(connector_tx) = session.connector_tx {
            connector_tx.send_close(close_frame);
        }
    }
}

impl RelayBrokerState {
    fn drain_status(&self) -> DrainStatus {
        DrainStatus {
            process_id: std::process::id(),
            draining: self.draining,
            active_ssh_sessions: self
                .sessions_by_id
                .values()
                .filter(|session| session.app_tx.is_some() || session.connector_tx.is_some())
                .count(),
        }
    }

    fn cleanup_expired_sessions(&mut self) {
        let now = current_epoch_seconds();
        self.sessions_by_id.retain(|_, session| {
            session.app_tx.is_some()
                || session.connector_tx.is_some()
                || session.expires_at_epoch_seconds > now
        });
    }
}

impl Default for RelayBroker {
    fn default() -> Self {
        Self {
            inner: Arc::new(Mutex::new(RelayBrokerState::default())),
        }
    }
}

fn current_epoch_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    const FUTURE_EXPIRY_EPOCH_SECONDS: i64 = i64::MAX / 2;

    #[tokio::test]
    async fn deploy_fence_preserves_live_traffic_and_blocks_new_attachments() {
        let broker = RelayBroker::default();
        for id in ["live", "pending"] {
            broker
                .create_session(
                    "host".to_owned(),
                    id.to_owned(),
                    FUTURE_EXPIRY_EPOCH_SECONDS,
                    "token".to_owned(),
                    "wss://relay.test".to_owned(),
                )
                .unwrap();
        }
        let (app, _app_rx) = relay_peer_channel();
        broker.attach_app("live", app).unwrap();
        assert_eq!(broker.fence().active_ssh_sessions, 1);
        let (pending, _pending_rx) = relay_peer_channel();
        assert!(matches!(
            broker.attach_app("pending", pending),
            Err(RelayBrokerError::Draining)
        ));
        assert!(matches!(
            broker.create_session(
                "host".to_owned(),
                "new".to_owned(),
                FUTURE_EXPIRY_EPOCH_SECONDS,
                "token".to_owned(),
                "wss://relay.test".to_owned()
            ),
            Err(RelayBrokerError::Draining)
        ));
        let (connector, mut connector_rx) = relay_peer_channel();
        broker.attach_connector("live", connector).unwrap();
        broker.forward_from_app("live", vec![1, 2, 3]).unwrap();
        assert!(matches!(
            connector_rx.try_recv().unwrap().message,
            Message::Binary(_)
        ));
        assert!(!broker.wait_for_idle(Duration::from_millis(1)).await);
        broker.close_session("live", "finished");
        assert!(broker.wait_for_idle(Duration::from_millis(1)).await);
        assert!(!broker.resume().draining);
        let (pending, _pending_rx) = relay_peer_channel();
        broker.attach_app("pending", pending).unwrap();
    }

    #[test]
    fn replays_pending_open_when_connector_reconnects() {
        let broker = RelayBroker::default();
        let (control_tx_one, mut control_rx_one) = mpsc::unbounded_channel();
        let control_connection_one = broker.register_connector_control(
            "host-1".to_owned(),
            "connector-1".to_owned(),
            control_tx_one,
        );

        broker
            .create_session(
                "host-1".to_owned(),
                "relay-session-1".to_owned(),
                FUTURE_EXPIRY_EPOCH_SECONDS,
                "connector-auth-token".to_owned(),
                "wss://connector.example/session-1".to_owned(),
            )
            .unwrap();
        assert!(matches!(
            control_rx_one.try_recv(),
            Ok(ConnectorControlMessage::OpenSshRelaySession { .. })
        ));

        broker.unregister_connector_control("host-1", control_connection_one);

        let (control_tx_two, mut control_rx_two) = mpsc::unbounded_channel();
        broker.register_connector_control(
            "host-1".to_owned(),
            "connector-1".to_owned(),
            control_tx_two,
        );

        assert!(matches!(
            control_rx_two.try_recv(),
            Ok(ConnectorControlMessage::OpenSshRelaySession { .. })
        ));
    }

    #[test]
    fn stale_connector_unregister_does_not_remove_newer_connection() {
        let broker = RelayBroker::default();
        let (control_tx_one, _control_rx_one) = mpsc::unbounded_channel();
        let control_connection_one = broker.register_connector_control(
            "host-1".to_owned(),
            "connector-1".to_owned(),
            control_tx_one,
        );

        let (control_tx_two, mut control_rx_two) = mpsc::unbounded_channel();
        let control_connection_two = broker.register_connector_control(
            "host-1".to_owned(),
            "connector-1".to_owned(),
            control_tx_two,
        );

        broker.unregister_connector_control("host-1", control_connection_one);
        assert!(broker.is_connector_online("host-1"));

        broker
            .create_session(
                "host-1".to_owned(),
                "relay-session-1".to_owned(),
                FUTURE_EXPIRY_EPOCH_SECONDS,
                "connector-auth-token".to_owned(),
                "wss://connector.example/session-1".to_owned(),
            )
            .unwrap();
        assert!(matches!(
            control_rx_two.try_recv(),
            Ok(ConnectorControlMessage::OpenSshRelaySession { .. })
        ));

        broker.unregister_connector_control("host-1", control_connection_two);
        assert!(!broker.is_connector_online("host-1"));
    }

    #[test]
    fn attached_peer_queue_is_bounded_by_byte_limit() {
        let broker = RelayBroker::default();
        broker
            .create_session(
                "host-1".to_owned(),
                "relay-session-1".to_owned(),
                FUTURE_EXPIRY_EPOCH_SECONDS,
                "connector-auth-token".to_owned(),
                "wss://connector.example/session-1".to_owned(),
            )
            .unwrap();

        let (connector_tx, _connector_rx) = relay_peer_channel();
        broker
            .attach_connector("relay-session-1", connector_tx)
            .expect("attach connector");

        assert!(
            broker
                .forward_from_app("relay-session-1", vec![0_u8; BUFFER_LIMIT_BYTES])
                .is_ok()
        );
        assert!(matches!(
            broker.forward_from_app("relay-session-1", vec![1_u8]),
            Err(RelayBrokerError::BufferLimitExceeded)
        ));
    }
}
