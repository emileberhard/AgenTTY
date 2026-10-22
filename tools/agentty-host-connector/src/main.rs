#![forbid(unsafe_code)]

use std::env;
use std::fs;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use futures_util::{SinkExt, StreamExt};
use reqwest::Client;
use serde::Deserialize;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::signal;
use tokio::time::{MissedTickBehavior, interval, sleep, timeout};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::http::header::AUTHORIZATION;
use tokio_tungstenite::{connect_async, tungstenite::Message};
use tracing::{error, info};
use tracing_subscriber::EnvFilter;

const CONNECTOR_CONTROL_PROBE_HEADER: &str = "x-agentty-probe";
const CONNECTOR_CONTROL_PROBE_VALUE: &str = "connector-control";
const CONTROL_WEBSOCKET_KEEPALIVE_INTERVAL: Duration = Duration::from_secs(30);
const STABLE_CONTROL_CONNECTION_DURATION: Duration = Duration::from_secs(60);

#[derive(Debug, Clone, Deserialize)]
struct ConnectorConfig {
    connector_id: String,
    connector_secret: String,
    public_base_url: String,
    relay_host_id: String,
    ssh_port: u16,
}

#[derive(Debug, Deserialize)]
struct ConnectorSessionTokenResponse {
    expires_at_epoch_seconds: i64,
    authorization_token: String,
    websocket_url: String,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ControlMessage {
    OpenSshRelaySession {
        expires_at_epoch_seconds: i64,
        relay_session_id: String,
        authorization_token: String,
        websocket_url: String,
    },
}

#[derive(Debug, serde::Serialize)]
struct ConnectorSessionTokenRequest<'a> {
    connector_id: &'a str,
    connector_secret: &'a str,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CommandMode {
    Run,
    ProbeControl,
}

#[derive(Debug)]
struct ParsedArgs {
    config_path: PathBuf,
    mode: CommandMode,
}

struct ControlConnectionAttempt {
    result: Result<()>,
    connected_duration: Option<Duration>,
}

#[tokio::main]
async fn main() -> Result<()> {
    if env::args().nth(1).as_deref() == Some("--version") {
        println!("{}", env!("AGENTTY_BUILD_VERSION"));
        return Ok(());
    }
    init_tracing();

    let parsed_args = parse_args()?;
    let config = load_config(&parsed_args.config_path)?;
    let http_client = Client::builder()
        .user_agent("agentty-host-connector")
        .build()
        .context("failed to build HTTP client")?;

    match parsed_args.mode {
        CommandMode::Run => {
            info!(
                relay_host_id = %config.relay_host_id,
                ssh_port = config.ssh_port,
                "agentty host connector starting"
            );

            let mut reconnect_delay_seconds = 1_u64;
            loop {
                tokio::select! {
                    _ = shutdown_signal() => {
                        info!("agentty host connector shutting down");
                        return Ok(());
                    }
                    attempt = run_control_connection(&http_client, &config) => {
                        match attempt.result {
                            Ok(()) => {
                                reconnect_delay_seconds = 1;
                            }
                            Err(error) => {
                                let retry_delay_seconds = reconnect_delay_after_failure(
                                    reconnect_delay_seconds,
                                    attempt.connected_duration,
                                );
                                error!(
                                    error = %error,
                                    connected_for_ms = attempt.connected_duration.map_or(0, |duration| duration.as_millis()),
                                    retry_in_seconds = retry_delay_seconds,
                                    "connector control connection failed"
                                );
                                sleep(Duration::from_secs(retry_delay_seconds)).await;
                                reconnect_delay_seconds =
                                    (retry_delay_seconds.saturating_mul(2)).min(30);
                            }
                        }
                    }
                }
            }
        }
        CommandMode::ProbeControl => {
            info!(
                relay_host_id = %config.relay_host_id,
                ssh_port = config.ssh_port,
                "agentty host connector probe starting"
            );
            probe_control_connection(&http_client, &config).await?;
            info!(
                relay_host_id = %config.relay_host_id,
                "agentty host connector probe succeeded"
            );
            Ok(())
        }
    }
}

fn init_tracing() {
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("agentty_host_connector=info"));
    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(false)
        .compact()
        .init();
}

fn parse_args() -> Result<ParsedArgs> {
    let mut args = env::args().skip(1);
    let mut config_path: Option<PathBuf> = None;
    let mut mode = CommandMode::Run;
    while let Some(argument) = args.next() {
        match argument.as_str() {
            "probe-control" => {
                mode = CommandMode::ProbeControl;
            }
            "--config" => {
                let value = args.next().context("--config requires a path")?;
                config_path = Some(PathBuf::from(value));
            }
            "-h" | "--help" => {
                println!("Usage: agentty-host-connector [probe-control] --config <path>");
                std::process::exit(0);
            }
            other => bail!("unknown argument: {other}"),
        }
    }
    Ok(ParsedArgs {
        config_path: config_path.context("missing required --config <path>")?,
        mode,
    })
}

fn load_config(path: &std::path::Path) -> Result<ConnectorConfig> {
    let raw = fs::read_to_string(path)
        .with_context(|| format!("failed to read connector config {}", path.display()))?;
    let config: ConnectorConfig =
        serde_json::from_str(&raw).context("failed to decode connector config")?;
    if config.connector_id.is_empty()
        || config.connector_secret.is_empty()
        || config.public_base_url.is_empty()
        || config.relay_host_id.is_empty()
    {
        bail!("connector config is incomplete");
    }
    Ok(config)
}

async fn run_control_connection(
    client: &Client,
    config: &ConnectorConfig,
) -> ControlConnectionAttempt {
    let token_response = match issue_control_session_token(client, config).await {
        Ok(response) => response,
        Err(error) => {
            return ControlConnectionAttempt {
                result: Err(error),
                connected_duration: None,
            };
        }
    };
    info!(
        relay_host_id = %config.relay_host_id,
        expires_at = token_response.expires_at_epoch_seconds,
        "connector control session token issued"
    );

    let request = match websocket_request(
        &token_response.websocket_url,
        &token_response.authorization_token,
        false,
    ) {
        Ok(request) => request,
        Err(error) => {
            return ControlConnectionAttempt {
                result: Err(error),
                connected_duration: None,
            };
        }
    };
    let (websocket, _) = match connect_async(request)
        .await
        .context("failed to connect connector control websocket")
    {
        Ok(connection) => connection,
        Err(error) => {
            return ControlConnectionAttempt {
                result: Err(error),
                connected_duration: None,
            };
        }
    };

    let connected_at = Instant::now();
    let result = run_control_websocket(websocket, config.ssh_port).await;
    ControlConnectionAttempt {
        result,
        connected_duration: Some(connected_at.elapsed()),
    }
}

fn reconnect_delay_after_failure(
    current_delay_seconds: u64,
    connected_duration: Option<Duration>,
) -> u64 {
    if connected_duration.is_some_and(|duration| duration >= STABLE_CONTROL_CONNECTION_DURATION) {
        1
    } else {
        current_delay_seconds
    }
}

async fn run_control_websocket<S>(
    mut websocket: tokio_tungstenite::WebSocketStream<S>,
    ssh_port: u16,
) -> Result<()>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    run_control_websocket_with_keepalive(
        &mut websocket,
        ssh_port,
        CONTROL_WEBSOCKET_KEEPALIVE_INTERVAL,
    )
    .await
}

async fn run_control_websocket_with_keepalive<S>(
    websocket: &mut tokio_tungstenite::WebSocketStream<S>,
    ssh_port: u16,
    keepalive_interval: Duration,
) -> Result<()>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    let mut keepalive = interval(keepalive_interval);
    keepalive.set_missed_tick_behavior(MissedTickBehavior::Delay);
    keepalive.tick().await;

    loop {
        tokio::select! {
            _ = keepalive.tick() => {
                websocket
                    .send(Message::Ping(Vec::new().into()))
                    .await
                    .context("failed to send connector control keepalive ping")?;
            }
            next_message = websocket.next() => {
                match next_message {
                    Some(message) => match message.context("connector control websocket failed")? {
                        Message::Text(text) => {
                            let control_message: ControlMessage = serde_json::from_str(&text)
                                .context("failed to decode connector control message")?;
                            match control_message {
                                ControlMessage::OpenSshRelaySession {
                                    expires_at_epoch_seconds,
                                    relay_session_id,
                                    authorization_token,
                                    websocket_url,
                                } => {
                                    info!(
                                        relay_session_id = %relay_session_id,
                                        expires_at = expires_at_epoch_seconds,
                                        "opening SSH relay session"
                                    );
                                    tokio::spawn(async move {
                                        if let Err(error) = run_ssh_relay_session(
                                            ssh_port,
                                            &websocket_url,
                                            &authorization_token,
                                        )
                                        .await
                                        {
                                            error!(
                                                relay_session_id = %relay_session_id,
                                                error = %error,
                                                "SSH relay session failed"
                                            );
                                        }
                                    });
                                }
                            }
                        }
                        Message::Ping(payload) => {
                            websocket
                                .send(Message::Pong(payload))
                                .await
                                .context("failed to reply to connector control ping")?;
                        }
                        Message::Close(_) => break,
                        Message::Pong(_) | Message::Binary(_) => {}
                        Message::Frame(_) => {}
                    },
                    None => break,
                }
            }
        }
    }

    bail!("connector control websocket closed")
}

async fn probe_control_connection(client: &Client, config: &ConnectorConfig) -> Result<()> {
    let token_response = issue_control_session_token(client, config).await?;
    info!(
        relay_host_id = %config.relay_host_id,
        expires_at = token_response.expires_at_epoch_seconds,
        "connector control probe token issued"
    );

    let (mut websocket, response) = connect_async(websocket_request(
        &token_response.websocket_url,
        &token_response.authorization_token,
        true,
    )?)
    .await
    .context("failed to connect connector control websocket")?;

    if response.status().as_u16() != 101 {
        bail!(
            "connector control websocket returned unexpected status {}",
            response.status()
        );
    }

    match timeout(Duration::from_secs(2), websocket.next()).await {
        Ok(Some(Ok(Message::Close(_)))) | Ok(None) => {
            bail!("connector control websocket closed during probe");
        }
        Ok(Some(Err(error))) => {
            return Err(error).context("connector control websocket failed during probe");
        }
        Ok(Some(Ok(_))) | Err(_) => {}
    }

    let _ = websocket.close(None).await;
    Ok(())
}

async fn issue_control_session_token(
    client: &Client,
    config: &ConnectorConfig,
) -> Result<ConnectorSessionTokenResponse> {
    let request_url = format!(
        "{}/v1/connectors/session-token",
        config.public_base_url.trim_end_matches('/')
    );
    let response = client
        .post(&request_url)
        .json(&ConnectorSessionTokenRequest {
            connector_id: &config.connector_id,
            connector_secret: &config.connector_secret,
        })
        .send()
        .await
        .context("failed to request connector control session token")?;
    let response = response
        .error_for_status()
        .context("connector control session token request was rejected")?;
    response
        .json()
        .await
        .context("failed to decode connector control session token response")
}

async fn run_ssh_relay_session(
    ssh_port: u16,
    websocket_url: &str,
    authorization_token: &str,
) -> Result<()> {
    let local_stream = TcpStream::connect(("127.0.0.1", ssh_port))
        .await
        .with_context(|| format!("failed to connect to local sshd on 127.0.0.1:{ssh_port}"))?;
    let (websocket, _) = connect_async(websocket_request(
        websocket_url,
        authorization_token,
        false,
    )?)
    .await
    .context("failed to connect relay session websocket")?;

    let (mut ws_sink, mut ws_stream) = websocket.split();
    let (mut local_reader, mut local_writer) = local_stream.into_split();

    let local_to_websocket = async {
        let mut buffer = [0_u8; 64 * 1024];
        loop {
            let read_len = local_reader
                .read(&mut buffer)
                .await
                .context("failed to read local ssh stream")?;
            if read_len == 0 {
                let _ = ws_sink.send(Message::Close(None)).await;
                return Ok::<(), anyhow::Error>(());
            }
            ws_sink
                .send(Message::Binary(buffer[..read_len].to_vec().into()))
                .await
                .context("failed to forward local ssh bytes to websocket")?;
        }
    };

    let websocket_to_local = async {
        while let Some(next_message) = ws_stream.next().await {
            match next_message.context("relay session websocket failed")? {
                Message::Binary(data) => {
                    local_writer
                        .write_all(&data)
                        .await
                        .context("failed to write websocket bytes to local ssh stream")?;
                }
                Message::Close(_) => return Ok::<(), anyhow::Error>(()),
                Message::Ping(_) | Message::Pong(_) | Message::Text(_) => {}
                Message::Frame(_) => {}
            }
        }
        Ok(())
    };

    tokio::select! {
        result = local_to_websocket => result,
        result = websocket_to_local => result,
    }
}

fn websocket_request(
    websocket_url: &str,
    authorization_token: &str,
    is_probe: bool,
) -> Result<tokio_tungstenite::tungstenite::http::Request<()>> {
    let mut request = websocket_url
        .into_client_request()
        .context("failed to build websocket request")?;
    let authorization_header = format!("Bearer {authorization_token}");
    request.headers_mut().insert(
        AUTHORIZATION,
        HeaderValue::from_str(&authorization_header)
            .context("failed to encode websocket authorization header")?,
    );
    if is_probe {
        request.headers_mut().insert(
            CONNECTOR_CONTROL_PROBE_HEADER,
            HeaderValue::from_static(CONNECTOR_CONTROL_PROBE_VALUE),
        );
    }
    Ok(request)
}

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = signal::ctrl_c().await;
    };

    #[cfg(unix)]
    let terminate = async {
        use tokio::signal::unix::{SignalKind, signal};

        match signal(SignalKind::terminate()) {
            Ok(mut stream) => {
                let _ = stream.recv().await;
            }
            Err(_) => std::future::pending::<()>().await,
        }
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {}
        _ = terminate => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use tokio::net::TcpListener;
    use tokio::sync::oneshot;
    use tokio_tungstenite::accept_async;

    #[tokio::test]
    async fn control_websocket_replies_to_ping_frames() -> Result<()> {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
        let address = listener.local_addr()?;
        let (pong_tx, pong_rx) = oneshot::channel();

        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await?;
            let mut websocket = accept_async(stream).await?;
            websocket
                .send(Message::Ping(b"keepalive".to_vec().into()))
                .await?;

            let next_message = timeout(Duration::from_secs(2), websocket.next())
                .await
                .context("timed out waiting for connector pong")?;
            match next_message {
                Some(Ok(Message::Pong(payload))) if payload.as_ref() == b"keepalive" => {
                    let _ = pong_tx.send(());
                }
                other => bail!("expected pong keepalive response, got {other:?}"),
            }

            let _ = websocket.close(None).await;
            Ok::<(), anyhow::Error>(())
        });

        let (mut websocket, _) = connect_async(format!("ws://{address}")).await?;
        let client_result =
            run_control_websocket_with_keepalive(&mut websocket, 22, Duration::from_secs(60)).await;

        assert!(client_result.is_err());
        pong_rx
            .await
            .context("server did not receive connector pong response")?;
        server.await.context("server task panicked")??;
        Ok(())
    }

    #[tokio::test]
    async fn control_websocket_sends_keepalive_ping_frames() -> Result<()> {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
        let address = listener.local_addr()?;
        let (ping_tx, ping_rx) = oneshot::channel();

        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await?;
            let mut websocket = accept_async(stream).await?;

            let next_message = timeout(Duration::from_secs(1), websocket.next())
                .await
                .context("timed out waiting for connector keepalive ping")?;
            match next_message {
                Some(Ok(Message::Ping(payload))) if payload.is_empty() => {
                    let _ = ping_tx.send(());
                }
                other => bail!("expected empty keepalive ping, got {other:?}"),
            }

            let _ = websocket.close(None).await;
            Ok::<(), anyhow::Error>(())
        });

        let (mut websocket, _) = connect_async(format!("ws://{address}")).await?;
        let client_result =
            run_control_websocket_with_keepalive(&mut websocket, 22, Duration::from_millis(25))
                .await;

        assert!(client_result.is_err());
        ping_rx
            .await
            .context("server did not receive connector keepalive ping")?;
        server.await.context("server task panicked")??;
        Ok(())
    }

    #[test]
    fn stable_control_connection_resets_reconnect_delay() {
        assert_eq!(
            reconnect_delay_after_failure(30, Some(Duration::from_secs(60))),
            1
        );
        assert_eq!(
            reconnect_delay_after_failure(30, Some(Duration::from_secs(300))),
            1
        );
    }

    #[test]
    fn short_or_unestablished_connection_preserves_reconnect_delay() {
        assert_eq!(
            reconnect_delay_after_failure(8, Some(Duration::from_secs(59))),
            8
        );
        assert_eq!(reconnect_delay_after_failure(16, None), 16);
    }
}
