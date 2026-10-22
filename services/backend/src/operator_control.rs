use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, PermissionsExt};
use std::path::PathBuf;

use agentty_backend::relay_broker::{DrainStatus, RelayBroker};
use anyhow::{Context, Result, ensure};
use axum::{
    Json, Router,
    extract::State,
    routing::{get, post},
};
use tokio::net::{UnixListener, UnixStream};

pub struct ControlServer {
    task: tokio::task::JoinHandle<()>,
    path: PathBuf,
    inode: u64,
}

impl ControlServer {
    pub async fn start(path: PathBuf, broker: RelayBroker) -> Result<Self> {
        let parent = path
            .parent()
            .context("control socket needs a parent directory")?;
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(parent)?;
        ensure!(
            std::fs::metadata(parent)?.permissions().mode() & 0o077 == 0,
            "control socket directory must be private (mode 0700)"
        );
        match std::fs::symlink_metadata(&path) {
            Ok(metadata) => {
                ensure!(
                    metadata.file_type().is_socket(),
                    "control socket path is occupied by another file"
                );
                match tokio::time::timeout(
                    std::time::Duration::from_secs(1),
                    UnixStream::connect(&path),
                )
                .await
                {
                    Ok(Err(error)) if error.kind() == std::io::ErrorKind::ConnectionRefused => {
                        std::fs::remove_file(&path)?
                    }
                    _ => anyhow::bail!(
                        "control socket is already active or cannot be safely replaced"
                    ),
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        let listener =
            UnixListener::bind(&path).context("failed to bind operator control socket")?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
        let inode = std::fs::symlink_metadata(&path)?.ino();
        if parent.join("start-fenced").try_exists()? {
            broker.fence();
        }
        let app = Router::new()
            .route("/status", get(status))
            .route("/fence", post(fence))
            .route("/resume", post(resume))
            .with_state(broker);
        let task = tokio::spawn(async move {
            if let Err(error) = axum::serve(listener, app).await {
                tracing::error!("operator control server stopped: {error}");
            }
        });
        Ok(Self { task, path, inode })
    }
}

impl Drop for ControlServer {
    fn drop(&mut self) {
        self.task.abort();
        if std::fs::symlink_metadata(&self.path).is_ok_and(|metadata| metadata.ino() == self.inode)
        {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

async fn status(State(broker): State<RelayBroker>) -> Json<DrainStatus> {
    Json(broker.drain_status())
}

async fn fence(State(broker): State<RelayBroker>) -> Json<DrainStatus> {
    Json(broker.fence())
}

async fn resume(State(broker): State<RelayBroker>) -> Json<DrainStatus> {
    Json(broker.resume())
}
