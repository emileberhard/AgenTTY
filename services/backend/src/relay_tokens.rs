use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;

use crate::config::Settings;
use crate::models::generate_pairing_host_token;

const CONNECTOR_CONTROL_TOKEN_TTL_SECONDS: i64 = 5 * 60;
const CONNECTOR_SESSION_TOKEN_TTL_SECONDS: i64 = 5 * 60;
const APP_SESSION_TOKEN_TTL_SECONDS: i64 = 5 * 60;

struct RelayTokenIssueSpec<'a> {
    ttl_seconds: i64,
    websocket_path: &'a str,
}

#[derive(Clone)]
pub struct RelayTokenManager {
    public_base_url: String,
}

#[derive(Debug, Clone)]
pub struct RelayTokenIssue {
    pub expires_at_epoch_seconds: i64,
    pub authorization_token: String,
    pub websocket_url: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RelayTokenKind {
    AppSession,
    ConnectorControl,
    ConnectorSession,
}

impl RelayTokenKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::AppSession => "app_session",
            Self::ConnectorControl => "connector_control",
            Self::ConnectorSession => "connector_session",
        }
    }
}

impl RelayTokenManager {
    pub fn from_settings(settings: &Settings) -> Result<Self> {
        Self::new(settings.public_base_url.clone())
    }

    pub fn new(public_base_url: String) -> Result<Self> {
        Ok(Self {
            public_base_url: normalize_public_base_url(&public_base_url)?,
        })
    }

    pub fn for_test(public_base_url: &str) -> Result<Self> {
        Self::new(public_base_url.to_owned())
    }

    pub fn issue_app_session(&self, relay_session_id: &str) -> RelayTokenIssue {
        self.issue(RelayTokenIssueSpec {
            ttl_seconds: APP_SESSION_TOKEN_TTL_SECONDS,
            websocket_path: &format!("/v1/ssh-relay-sessions/{relay_session_id}/ws"),
        })
    }

    pub fn issue_connector_control(&self) -> RelayTokenIssue {
        self.issue(RelayTokenIssueSpec {
            ttl_seconds: CONNECTOR_CONTROL_TOKEN_TTL_SECONDS,
            websocket_path: "/v1/connectors/ws",
        })
    }

    pub fn issue_connector_session(&self, relay_session_id: &str) -> RelayTokenIssue {
        self.issue(RelayTokenIssueSpec {
            ttl_seconds: CONNECTOR_SESSION_TOKEN_TTL_SECONDS,
            websocket_path: &format!("/v1/connectors/sessions/{relay_session_id}/ws"),
        })
    }

    fn issue(&self, spec: RelayTokenIssueSpec<'_>) -> RelayTokenIssue {
        let expires_at_epoch_seconds = current_epoch_seconds() + spec.ttl_seconds;
        RelayTokenIssue {
            expires_at_epoch_seconds,
            authorization_token: generate_pairing_host_token(),
            websocket_url: format!(
                "{}{}",
                websocket_base_url(&self.public_base_url),
                spec.websocket_path
            ),
        }
    }
}

fn current_epoch_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}

fn normalize_public_base_url(public_base_url: &str) -> Result<String> {
    let trimmed = public_base_url.trim().trim_end_matches('/');
    if trimmed.starts_with("https://") || trimmed.starts_with("http://") {
        return Ok(trimmed.to_owned());
    }
    anyhow::bail!("public relay base URL must start with http:// or https://");
}

fn websocket_base_url(public_base_url: &str) -> String {
    if let Some(suffix) = public_base_url.strip_prefix("https://") {
        return format!("wss://{suffix}");
    }
    if let Some(suffix) = public_base_url.strip_prefix("http://") {
        return format!("ws://{suffix}");
    }
    public_base_url.to_owned()
}
