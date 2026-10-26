#![forbid(unsafe_code)]

mod operator_control;

use std::future::IntoFuture;

use anyhow::{Context, Result};
use tokio::net::TcpListener;
use tracing_subscriber::EnvFilter;

use agentty_backend::{build_info, config::Settings, create_app, relay_broker::RelayBroker};

#[tokio::main]
async fn main() -> Result<()> {
    init_tracing();

    let build_info = build_info::current_build_info();
    tracing::info!(
        "agentty_backend starting version={} git_sha={} git_tag={}",
        build_info.version,
        build_info.git_sha,
        build_info.git_tag.unwrap_or("")
    );

    let settings = Settings::from_env()?;
    let bind_address = settings.bind_address;
    let relay_broker = RelayBroker::default();
    let _control = operator_control::ControlServer::start(
        settings.control_socket_path.clone(),
        relay_broker.clone(),
    )
    .await?;
    let app = create_app(settings, relay_broker.clone()).await?;

    let listener = TcpListener::bind(bind_address)
        .await
        .with_context(|| format!("failed to bind relay on {bind_address}"))?;

    tracing::info!("agentty_backend listening addr={bind_address}");

    let (drained, received) = tokio::sync::oneshot::channel();
    let server = axum::serve(listener, app)
        .with_graceful_shutdown(async move {
            shutdown_signal(relay_broker).await;
            let _ = drained.send(());
        })
        .into_future();
    tokio::select! {
        result = server => result.context("relay server exited unexpectedly"),
        _ = async {
            received.await.expect("shutdown completion sender must remain owned by the server");
            tokio::time::sleep(std::time::Duration::from_secs(40)).await;
        } => {
            tracing::warn!("host shutdown HTTP grace expired");
            Ok(())
        }
    }
}

fn init_tracing() {
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("agentty_backend=info"));

    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(false)
        .compact()
        .init();
}

async fn shutdown_signal(relay_broker: RelayBroker) {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
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
    let status = relay_broker.fence();
    tracing::info!(
        active_ssh_sessions = status.active_ssh_sessions,
        "shutdown fenced relay admission"
    );
    if !relay_broker
        .wait_for_idle(std::time::Duration::from_secs(10))
        .await
    {
        tracing::warn!(
            active_ssh_sessions = relay_broker.drain_status().active_ssh_sessions,
            "host shutdown grace expired with live relay SSH sessions"
        );
    }
}
