use crate::{AppState, config::DictationLimits};
use axum::{
    extract::{Request, State},
    http::StatusCode,
    middleware::Next,
    response::{IntoResponse, Response},
};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use subtle::ConstantTimeEq;
use tokio::sync::Semaphore;

pub struct Admission {
    pub dictation_limits: DictationLimits,
    requests: Semaphore,
    dictation: Semaphore,
    windows: Mutex<[(Instant, u32); 2]>,
    devices: Mutex<HashMap<String, (Instant, u32)>>,
    sockets: Arc<Semaphore>,
}

impl Admission {
    pub fn new(limits: DictationLimits) -> Self {
        Self {
            requests: Semaphore::new(32),
            sockets: Arc::new(Semaphore::new(128)),
            dictation: Semaphore::new(limits.concurrency),
            dictation_limits: limits,
            devices: Mutex::new(HashMap::new()),
            windows: Mutex::new([(Instant::now(), 0); 2]),
        }
    }

    pub fn socket_permit(
        &self,
    ) -> Result<tokio::sync::OwnedSemaphorePermit, crate::error::ApiError> {
        self.sockets.clone().try_acquire_owned().map_err(|_| {
            crate::error::ApiError::ResourceLimit {
                code: "relay_socket_capacity",
                detail: "Relay socket capacity reached. Please try again shortly.",
            }
        })
    }

    pub fn admit_device(&self, device_id: &str) -> bool {
        let now = Instant::now();
        let mut devices = self.devices.lock().expect("device admission lock poisoned");
        devices.retain(|_, (started, _)| now.duration_since(*started) < Duration::from_secs(60));
        if devices.len() >= 10_000 && !devices.contains_key(device_id) {
            return false;
        }
        let (_, count) = devices.entry(device_id.to_owned()).or_insert((now, 0));
        if *count >= 120 {
            return false;
        }
        *count += 1;
        true
    }

    fn admit_rate(&self, provision: bool) -> bool {
        let mut windows = self.windows.lock().expect("admission lock poisoned");
        let now = Instant::now();
        for (started, count) in windows.iter_mut() {
            if now.duration_since(*started) >= Duration::from_secs(60) {
                *started = now;
                *count = 0;
            }
        }
        if windows[0].1 >= 600 || (provision && windows[1].1 >= 60) {
            return false;
        }
        windows[0].1 += 1;
        if provision {
            windows[1].1 += 1;
        }
        true
    }
}

pub async fn limit(State(state): State<AppState>, request: Request, next: Next) -> Response {
    let admission = &state.admission;
    let path = request.uri().path();
    let trusted_internal = path.starts_with("/v1/internal/")
        && request
            .headers()
            .get("authorization")
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.strip_prefix("Bearer "))
            .is_some_and(|token| {
                state
                    .internal_clients
                    .iter()
                    .any(|client| client.token.as_bytes().ct_eq(token.as_bytes()).unwrap_u8() == 1)
            });
    if path == "/healthz" || trusted_internal {
        return next.run(request).await;
    }
    let provision = matches!(
        path,
        "/v1/pairing-sessions"
            | "/v1/pairing-sessions/claim"
            | "/v1/devices/ensure"
            | "/v1/devices/register"
            | "/v1/relay-sessions"
            | "/v1/dictation/sessions"
    );
    if !admission.admit_rate(provision) {
        return (StatusCode::TOO_MANY_REQUESTS, axum::Json(serde_json::json!({"code":"relay_request_limit","detail":"Relay request limit reached. Please try again shortly."}))).into_response();
    }
    let Ok(_request_permit) = admission.requests.try_acquire() else {
        return busy();
    };
    let _dictation_permit = if path == "/v1/dictation/transcriptions" {
        match admission.dictation.try_acquire() {
            Ok(permit) => Some(permit),
            Err(_) => return busy(),
        }
    } else {
        None
    };
    match tokio::time::timeout(Duration::from_secs(150), next.run(request)).await {
        Ok(response) => response,
        Err(_) => (
            StatusCode::GATEWAY_TIMEOUT,
            axum::Json(serde_json::json!({"detail":"Relay request timed out."})),
        )
            .into_response(),
    }
}

fn busy() -> Response {
    (StatusCode::SERVICE_UNAVAILABLE, axum::Json(serde_json::json!({"code":"relay_busy","detail":"Dictation or relay capacity is busy. Please try again shortly."}))).into_response()
}
