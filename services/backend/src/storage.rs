use std::path::PathBuf;
use std::str::FromStr;
use std::sync::atomic::{AtomicI64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};
use std::{fs, io};

use anyhow::{Context, Result};
use rusqlite::{OptionalExtension, params};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use tokio_rusqlite::Connection;

use crate::config::DictationLimits;
use crate::dictation::{
    DictationGrant, DictationQuotaExceeded, DictationSubject, DictationTier, DictationWindows,
};
use crate::models::{
    AnalyticsAccessStatePayload, AnalyticsEventType, ConnectorAuthRecord,
    ConnectorBootstrapPayload, ConnectorRegistrationRecord, DeviceRecord, PairingCompletionPayload,
    PairingPlatform, PairingSessionClaimResponse, PairingSessionRecord, PairingSessionResponse,
    PairingSessionStatus, PushEnvironment, RelaySessionResponse, SshRelaySessionRecord,
    generate_pairing_code, generate_pairing_host_token, generate_pairing_session_id,
    normalize_device_id,
};
use crate::relay_tokens::RelayTokenKind;

const RELAY_SESSION_TTL_SECONDS: i64 = 30 * 24 * 60 * 60;
const PAIRING_SESSION_TTL_SECONDS: i64 = 10 * 60;
const CONNECTOR_BOOTSTRAP_TOKEN_TTL_SECONDS: i64 = 10 * 60;
const SSH_RELAY_SESSION_TTL_SECONDS: i64 = 60;
const DICTATION_WEEKLY_LIMIT_SECONDS: i64 = 30 * 60;
const ANALYTICS_SENSITIVE_CONTEXT_RETENTION_SECONDS: i64 = 14 * 24 * 60 * 60;
const RELAY_ATTACH_TOKEN_CLEANUP_INTERVAL_SECONDS: i64 = 5 * 60;
static LAST_RELAY_ATTACH_TOKEN_CLEANUP_EPOCH_SECONDS: AtomicI64 = AtomicI64::new(0);
const LEGACY_DEVICE_ID_NORMALIZATION_STATEMENTS: [&str; 9] = [
    "UPDATE relay_sessions SET device_id = lower(device_id) WHERE device_id != lower(device_id)",
    "UPDATE pairing_sessions SET device_id = lower(device_id) WHERE device_id IS NOT NULL AND device_id != lower(device_id)",
    "UPDATE connector_bootstrap_tokens SET device_id = lower(device_id) WHERE device_id != lower(device_id)",
    "UPDATE device_relay_host_grants SET device_id = lower(device_id) WHERE device_id != lower(device_id)",
    "UPDATE dictation_usage_weekly SET device_id = lower(device_id) WHERE device_id != lower(device_id)",
    "UPDATE analytics_device_user_links SET device_id = lower(device_id) WHERE device_id != lower(device_id)",
    "UPDATE analytics_events SET device_id = lower(device_id) WHERE device_id != lower(device_id)",
    "UPDATE ssh_relay_sessions SET device_id = lower(device_id) WHERE device_id != lower(device_id)",
    "UPDATE devices SET device_id = lower(device_id) WHERE device_id != lower(device_id)",
];

#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub(crate) struct RelayCapacityError(pub &'static str);

fn capacity_error(code: &'static str) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(RelayCapacityError(code)))
}

#[derive(Debug, Clone)]
pub struct AnalyticsEventRecord {
    pub event_id: String,
    pub event_type: AnalyticsEventType,
    pub occurred_at_epoch_seconds: i64,
    pub payload_json: String,
    pub access_state: Option<AnalyticsAccessStatePayload>,
    pub saved_host_count: Option<i64>,
    pub sensitive_context: Option<AnalyticsSensitiveEventContextInput>,
}

#[derive(Debug, Clone)]
pub struct AnalyticsDeviceContextRecord {
    pub system_version: Option<String>,
    pub device_model_identifier: Option<String>,
    pub device_family: Option<String>,
    pub locale_identifier: Option<String>,
    pub preferred_languages_json: Option<String>,
}

#[derive(Debug, Clone)]
pub struct AnalyticsSensitiveEventContextInput {
    pub raw_detected_username: Option<String>,
    pub raw_selected_candidate_value: Option<String>,
    pub raw_candidate_values_json: Option<String>,
    pub raw_disconnect_reason: Option<String>,
    pub raw_error_detail: Option<String>,
}

#[derive(Debug, Clone)]
pub struct AnalyticsIngestFailureRecord {
    pub device_id: String,
    pub user_key_hash: Option<String>,
    pub bundle_id: Option<String>,
    pub app_transaction_environment: Option<String>,
    pub app_version: Option<String>,
    pub build_number: Option<String>,
    pub flavor: Option<String>,
    pub platform: Option<String>,
    pub error: String,
    pub event_count: i64,
    pub event_diagnostics: String,
    pub failed_event_id: Option<String>,
    pub failed_event_type: Option<String>,
    pub validation_field: Option<String>,
    pub validation_rule: Option<String>,
    pub payload_version: Option<i64>,
    pub redacted_payload_shape_json: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AnalyticsIssueSeverity {
    Warning,
    Blocked,
}

impl AnalyticsIssueSeverity {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Warning => "warning",
            Self::Blocked => "blocked",
        }
    }

    fn rank(self) -> i64 {
        match self {
            Self::Warning => 1,
            Self::Blocked => 2,
        }
    }
}

impl FromStr for AnalyticsIssueSeverity {
    type Err = io::Error;

    fn from_str(value: &str) -> std::result::Result<Self, Self::Err> {
        match value {
            "warning" => Ok(Self::Warning),
            "blocked" => Ok(Self::Blocked),
            _ => Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("invalid analytics issue severity {value}"),
            )),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AnalyticsIssueKind {
    AutomaticAllLowConfidenceCandidates,
    AutomaticReachabilityFailureAfterPairing,
    AutomaticUsernameResolutionUnreliable,
    SavedHostWithoutReadySsh,
    RepeatedPreReadySshFailure,
    RsaPrivateKeyUnsupported,
    RepeatedKeyMaterialFailure,
}

impl AnalyticsIssueKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::AutomaticAllLowConfidenceCandidates => "automatic_all_low_confidence_candidates",
            Self::AutomaticReachabilityFailureAfterPairing => {
                "automatic_reachability_failure_after_pairing"
            }
            Self::AutomaticUsernameResolutionUnreliable => {
                "automatic_username_resolution_unreliable"
            }
            Self::SavedHostWithoutReadySsh => "saved_host_without_ready_ssh",
            Self::RepeatedPreReadySshFailure => "repeated_pre_ready_ssh_failure",
            Self::RsaPrivateKeyUnsupported => "rsa_private_key_unsupported",
            Self::RepeatedKeyMaterialFailure => "repeated_key_material_failure",
        }
    }
}

impl FromStr for AnalyticsIssueKind {
    type Err = io::Error;

    fn from_str(value: &str) -> std::result::Result<Self, Self::Err> {
        match value {
            "automatic_all_low_confidence_candidates" => {
                Ok(Self::AutomaticAllLowConfidenceCandidates)
            }
            "automatic_reachability_failure_after_pairing" => {
                Ok(Self::AutomaticReachabilityFailureAfterPairing)
            }
            "automatic_username_resolution_unreliable" => {
                Ok(Self::AutomaticUsernameResolutionUnreliable)
            }
            "saved_host_without_ready_ssh" => Ok(Self::SavedHostWithoutReadySsh),
            "repeated_pre_ready_ssh_failure" => Ok(Self::RepeatedPreReadySshFailure),
            "rsa_private_key_unsupported" => Ok(Self::RsaPrivateKeyUnsupported),
            "repeated_key_material_failure" => Ok(Self::RepeatedKeyMaterialFailure),
            _ => Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("invalid analytics issue kind {value}"),
            )),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AnalyticsIssueCandidate {
    pub signature_key: String,
    pub user_key_hash: String,
    pub issue_kind: AnalyticsIssueKind,
    pub issue_severity: AnalyticsIssueSeverity,
    pub summary: String,
    pub first_seen_at_epoch_seconds: i64,
    pub last_seen_at_epoch_seconds: i64,
    pub occurrence_count: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AnalyticsStoredIssueAlert {
    pub signature_key: String,
    pub user_key_hash: String,
    pub issue_kind: AnalyticsIssueKind,
    pub issue_severity: AnalyticsIssueSeverity,
    pub summary: String,
    pub first_seen_at_epoch_seconds: i64,
    pub last_seen_at_epoch_seconds: i64,
    pub first_alerted_at_epoch_seconds: Option<i64>,
    pub last_alerted_at_epoch_seconds: Option<i64>,
    pub alert_count: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AnalyticsIssueAlertDecision {
    pub should_send_alert: bool,
}

#[derive(Clone)]
pub struct Database {
    connection: Connection,
}

pub enum CompletePairingSessionResult {
    Updated(Box<PairingSessionRecord>),
    NotFound,
    InvalidHostToken,
    Unavailable,
}

pub enum HostPairingSessionLookupResult {
    Found(Box<PairingSessionRecord>),
    NotFound,
    InvalidHostToken,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayAttachTokenRecord {
    pub relay_host_id: String,
    pub relay_session_id: Option<String>,
    pub connector_id: Option<String>,
}

impl Database {
    pub async fn open(path: PathBuf) -> Result<Self> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).with_context(|| {
                format!("failed to create database directory {}", parent.display())
            })?;
        }

        let connection = Connection::open(path.clone())
            .await
            .with_context(|| format!("failed to open sqlite database {}", path.display()))?;

        connection
            .call(|connection| -> rusqlite::Result<()> {
                connection
                    .execute_batch("PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;")?;
                let page_size: i64 =
                    connection.query_row("PRAGMA page_size", [], |row| row.get(0))?;
                let cap_pages = (512_i64 * 1024 * 1024) / page_size;
                let actual: i64 = connection.query_row(
                    &format!("PRAGMA max_page_count = {cap_pages}"),
                    [],
                    |row| row.get(0),
                )?;
                if actual > cap_pages {
                    return Err(rusqlite::Error::InvalidParameterName(
                        "relay database exceeds its 512 MiB cap".to_owned(),
                    ));
                }
                Ok(())
            })
            .await
            .context("failed to configure relay storage bounds")?;

        connection
            .call(|connection| {
                connection.execute_batch(
                    r#"
                    CREATE TABLE IF NOT EXISTS devices (
                        device_id TEXT PRIMARY KEY,
                        device_secret_hash TEXT NOT NULL,
                        apns_token TEXT NOT NULL,
                        bundle_id TEXT NOT NULL,
                        push_environment TEXT NOT NULL,
                        created_at_epoch_seconds INTEGER NOT NULL,
                        updated_at_epoch_seconds INTEGER NOT NULL
                    );

                    CREATE TABLE IF NOT EXISTS relay_sessions (
                        relay_token_hash TEXT PRIMARY KEY,
                        device_id TEXT NOT NULL,
                        expires_at_epoch_seconds INTEGER NOT NULL,
                        created_at_epoch_seconds INTEGER NOT NULL,
                        last_used_at_epoch_seconds INTEGER,
                        FOREIGN KEY(device_id) REFERENCES devices(device_id)
                    );

                    CREATE INDEX IF NOT EXISTS idx_relay_sessions_expires_at
                    ON relay_sessions(expires_at_epoch_seconds);
                    "#,
                )
            })
            .await
            .context("failed to initialize relay database")?;

        connection
            .call(|connection| {
                ensure_table_has_columns(
                    connection,
                    "relay_sessions",
                    &[
                        ("scope", "TEXT NOT NULL DEFAULT 'legacy'"),
                        ("dictation_identity", "TEXT"),
                        ("dictation_tier", "TEXT"),
                    ],
                )
            })
            .await
            .context("failed to add relay credential scopes")?;
        connection
            .call(|connection| ensure_pairing_sessions_schema(connection))
            .await
            .context("failed to initialize pairing session schema")?;

        connection
            .call(|connection| ensure_dictation_usage_schema(connection))
            .await
            .context("failed to initialize dictation quota schema")?;

        connection
            .call(|connection| ensure_relay_connector_schema(connection))
            .await
            .context("failed to initialize relay connector schema")?;

        connection
            .call(|connection| ensure_analytics_schema(connection))
            .await
            .context("failed to initialize analytics schema")?;

        connection
            .call(|connection| expire_stale_pairing_sessions(connection, current_epoch_seconds()))
            .await
            .context("failed to expire stale pairing sessions")?;
        connection
            .call(|connection| prune_ingest_failures(connection, current_epoch_seconds()))
            .await
            .context("failed to prune analytics ingest failures")?;
        connection
            .call(|connection| {
                redact_expired_sensitive_event_context(connection, current_epoch_seconds())
            })
            .await
            .context("failed to redact expired analytics sensitive context")?;

        connection
            .call(normalize_legacy_device_ids)
            .await
            .context("failed to normalize legacy device ids")?;
        connection.call(|connection| connection.execute_batch("CREATE TABLE IF NOT EXISTS device_admissions (device_id TEXT PRIMARY KEY REFERENCES devices(device_id), identity_hash TEXT NOT NULL); CREATE TABLE IF NOT EXISTS relay_bandwidth_daily (subject TEXT NOT NULL, day INTEGER NOT NULL, bytes INTEGER NOT NULL CHECK(bytes >= 0), PRIMARY KEY(subject, day));")).await.context("failed to initialize device admission schema")?;

        Ok(Self { connection })
    }

    pub async fn device_admission(
        &self,
        device_id: String,
    ) -> Result<Option<(String, Option<String>)>> {
        let device_id = normalize_device_id(&device_id);
        self.connection.call(move |connection| connection.query_row("SELECT d.device_secret_hash, a.identity_hash FROM devices d LEFT JOIN device_admissions a ON a.device_id = d.device_id WHERE d.device_id = ?", params![device_id], |row| Ok((row.get(0)?, row.get(1)?))).optional()).await.context("failed to read device admission")
    }

    pub async fn admit_verified_device(&self, device_id: String, identity: String) -> Result<()> {
        let device_id = normalize_device_id(&device_id);
        self.connection.call(move |connection| -> rusqlite::Result<()> {
            connection.execute("INSERT INTO device_admissions VALUES (?, ?) ON CONFLICT(device_id) DO UPDATE SET identity_hash = excluded.identity_hash", params![device_id, identity])?;
            Ok(())
        }).await.context("failed to admit verified device")
    }

    pub async fn relay_bandwidth_available(
        &self,
        device_id: String,
        limits: DictationLimits,
    ) -> Result<bool> {
        self.connection
            .call(move |connection| {
                charge_relay_device_bandwidth(connection, &device_id, 0, &limits)
            })
            .await
            .context("failed to check relay bandwidth")
    }

    pub async fn charge_relay_bandwidth(
        &self,
        session: String,
        bytes: usize,
        limits: DictationLimits,
    ) -> Result<bool> {
        self.connection
            .call(move |connection| {
                let device_id: Option<String> = connection
                    .query_row(
                        "SELECT device_id FROM ssh_relay_sessions WHERE relay_session_id = ?",
                        params![session],
                        |row| row.get(0),
                    )
                    .optional()?;
                let Some(device_id) = device_id else {
                    return Ok(false);
                };
                charge_relay_device_bandwidth(connection, &device_id, bytes, &limits)
            })
            .await
            .context("failed to reserve relay bandwidth")
    }

    pub async fn ensure_device_identity(
        &self,
        device_id: String,
        device_secret: String,
        bundle_id: String,
        push_environment: PushEnvironment,
    ) -> Result<bool> {
        let device_id = normalize_device_id(&device_id);
        let device_secret_hash = hash_text(&device_secret);
        let environment = push_environment.as_str().to_owned();
        let now = current_epoch_seconds();

        self.connection
            .call(move |connection| -> rusqlite::Result<bool> {
                let stored_hash: Option<String> = connection
                    .query_row(
                        "SELECT device_secret_hash FROM devices WHERE device_id = ?",
                        params![&device_id],
                        |row| row.get(0),
                    )
                    .optional()?;

                if let Some(stored_hash) = stored_hash {
                    if stored_hash
                        .as_bytes()
                        .ct_eq(device_secret_hash.as_bytes())
                        .unwrap_u8()
                        != 1
                    {
                        return Ok(false);
                    }

                    connection.execute(
                        r#"
                        UPDATE devices
                        SET bundle_id = ?, push_environment = ?, updated_at_epoch_seconds = ?
                        WHERE device_id = ?
                        "#,
                        params![bundle_id, environment, now, device_id],
                    )?;
                    return Ok(true);
                }

                let count: i64 =
                    connection.query_row("SELECT COUNT(*) FROM devices", [], |row| row.get(0))?;
                if count >= 10_000 {
                    return Err(capacity_error("device_capacity"));
                }
                connection.execute(
                    r#"
                    INSERT INTO devices (
                        device_id,
                        device_secret_hash,
                        apns_token,
                        bundle_id,
                        push_environment,
                        created_at_epoch_seconds,
                        updated_at_epoch_seconds
                    )
                    VALUES (?, ?, '', ?, ?, ?, ?)
                    "#,
                    params![
                        device_id,
                        device_secret_hash,
                        bundle_id,
                        environment,
                        now,
                        now
                    ],
                )?;

                Ok(true)
            })
            .await
            .context("failed to ensure device identity")
    }

    pub async fn register_device(
        &self,
        device_id: String,
        device_secret: String,
        apns_token: String,
        bundle_id: String,
        push_environment: PushEnvironment,
    ) -> Result<bool> {
        let device_id = normalize_device_id(&device_id);
        let device_secret_hash = hash_text(&device_secret);
        let environment = push_environment.as_str().to_owned();
        let now = current_epoch_seconds();

        self.connection
            .call(move |connection| -> rusqlite::Result<bool> {
                let stored_hash: Option<String> = connection
                    .query_row(
                        "SELECT device_secret_hash FROM devices WHERE device_id = ?",
                        params![&device_id],
                        |row| row.get(0),
                    )
                    .optional()?;

                if let Some(stored_hash) = stored_hash {
                    if stored_hash
                        .as_bytes()
                        .ct_eq(device_secret_hash.as_bytes())
                        .unwrap_u8()
                        != 1
                    {
                        return Ok(false);
                    }

                    connection.execute(
                        r#"
                        UPDATE devices
                        SET apns_token = ?, bundle_id = ?, push_environment = ?, updated_at_epoch_seconds = ?
                        WHERE device_id = ?
                        "#,
                        params![apns_token, bundle_id, environment, now, device_id],
                    )?;
                    return Ok(true);
                }

                let count: i64 = connection.query_row("SELECT COUNT(*) FROM devices", [], |row| row.get(0))?;
                if count >= 10_000 { return Err(capacity_error("device_capacity")); }
                connection.execute(
                    r#"
                    INSERT INTO devices (
                        device_id,
                        device_secret_hash,
                        apns_token,
                        bundle_id,
                        push_environment,
                        created_at_epoch_seconds,
                        updated_at_epoch_seconds
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    "#,
                    params![
                        device_id,
                        device_secret_hash,
                        apns_token,
                        bundle_id,
                        environment,
                        now,
                        now,
                    ],
                )?;
                Ok(true)
            })
            .await
            .context("failed to register device")
    }

    pub async fn authenticate_device_credentials(
        &self,
        device_id: String,
        device_secret: String,
    ) -> Result<bool> {
        let device_id = normalize_device_id(&device_id);
        let device_secret_hash = hash_text(&device_secret);

        self.connection
            .call(move |connection| {
                authenticate_device(connection, &device_id, &device_secret_hash)
            })
            .await
            .context("failed to authenticate device credentials")
    }

    pub async fn device_for_credentials(
        &self,
        device_id: String,
        device_secret: String,
    ) -> Result<Option<DeviceRecord>> {
        let device_id = normalize_device_id(&device_id);
        let device_secret_hash = hash_text(&device_secret);

        self.connection
            .call(
                move |connection| -> rusqlite::Result<Option<DeviceRecord>> {
                    let row = connection
                        .query_row(
                            r#"
                        SELECT
                            device_id,
                            apns_token,
                            bundle_id,
                            push_environment,
                            device_secret_hash
                        FROM devices
                        WHERE device_id = ?
                        "#,
                            params![device_id],
                            |row| {
                                let push_environment: String = row.get(3)?;
                                let push_environment = parse_environment_column(&push_environment)?;
                                Ok((
                                    DeviceRecord {
                                        device_id: row.get(0)?,
                                        apns_token: row.get(1)?,
                                        bundle_id: row.get(2)?,
                                        push_environment,
                                    },
                                    row.get::<_, String>(4)?,
                                ))
                            },
                        )
                        .optional()?;

                    let Some((device, stored_hash)) = row else {
                        return Ok(None);
                    };

                    if stored_hash
                        .as_bytes()
                        .ct_eq(device_secret_hash.as_bytes())
                        .unwrap_u8()
                        != 1
                    {
                        return Ok(None);
                    }

                    Ok(Some(device))
                },
            )
            .await
            .context("failed to load authenticated device")
    }

    pub async fn issue_relay_session(
        &self,
        device_id: String,
        device_secret: String,
        scope: String,
        dictation: Option<(String, DictationTier)>,
    ) -> Result<Option<RelaySessionResponse>> {
        let (dictation_identity, dictation_tier) = dictation.unzip();
        let device_id = normalize_device_id(&device_id);
        let device_secret_hash = hash_text(&device_secret);
        let now = current_epoch_seconds();

        let relay_session = self
            .connection
            .call(
                move |connection| -> rusqlite::Result<Option<RelaySessionResponse>> {
                    delete_expired_relay_sessions(connection, now)?;

                    if !authenticate_device(connection, &device_id, &device_secret_hash)? {
                        return Ok(None);
                    }

                    let expires_at = now + if scope == "dictation" { 60 * 60 } else { RELAY_SESSION_TTL_SECONDS };
                    connection.execute("DELETE FROM relay_sessions WHERE relay_token_hash IN (SELECT relay_token_hash FROM relay_sessions WHERE device_id = ? ORDER BY created_at_epoch_seconds DESC, rowid DESC LIMIT -1 OFFSET 511)", params![&device_id])?;
                    let mut relay_session = RelaySessionResponse::new(expires_at);
                    relay_session.dictation_tier = dictation_tier.map(DictationTier::as_str);
                    let relay_token_hash = hash_text(&relay_session.relay_token);

                    connection.execute(
                        r#"
                        INSERT INTO relay_sessions (
                            relay_token_hash,
                            device_id,
                            expires_at_epoch_seconds,
                            created_at_epoch_seconds, scope, dictation_identity, dictation_tier
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        "#,
                        params![relay_token_hash, device_id, expires_at, now, scope, dictation_identity, relay_session.dictation_tier],
                    )?;

                    Ok(Some(relay_session))
                },
            )
            .await
            .context("failed to issue relay session")?;

        Ok(relay_session)
    }

    pub async fn create_pairing_session(&self) -> Result<PairingSessionResponse> {
        let now = current_epoch_seconds();

        self.connection
            .call(
                move |connection| -> rusqlite::Result<PairingSessionResponse> {
                    expire_stale_pairing_sessions(connection, now)?;
                    let count: i64 = connection.query_row(
                        "SELECT COUNT(*) FROM pairing_sessions",
                        [],
                        |row| row.get(0),
                    )?;
                    if count >= 4096 {
                        return Err(capacity_error("pairing_capacity"));
                    }
                    for _ in 0..8 {
                        let session_id = generate_pairing_session_id();
                        let pairing_code = generate_pairing_code();
                        let code_hash = hash_text(&pairing_code);
                        let host_token = generate_pairing_host_token();
                        let host_token_hash = hash_text(&host_token);
                        let expires_at_epoch_seconds = now + PAIRING_SESSION_TTL_SECONDS;

                        let insert_result = connection.execute(
                            r#"
                        INSERT INTO pairing_sessions (
                            session_id,
                            code_hash,
                            host_token_hash,
                            status,
                            expires_at_epoch_seconds,
                            created_at_epoch_seconds
                        )
                        VALUES (?, ?, ?, ?, ?, ?)
                        "#,
                            params![
                                &session_id,
                                code_hash,
                                host_token_hash,
                                PairingSessionStatus::Pending.as_str(),
                                expires_at_epoch_seconds,
                                now,
                            ],
                        );

                        match insert_result {
                            Ok(_) => {
                                return Ok(PairingSessionResponse {
                                    session_id,
                                    pairing_code: pairing_code.clone(),
                                    qr_payload: format!("agentty://pair?code={pairing_code}"),
                                    host_token,
                                    expires_at_epoch_seconds,
                                });
                            }
                            Err(error) if is_unique_constraint(&error) => continue,
                            Err(error) => return Err(error),
                        }
                    }

                    Err(rusqlite::Error::ToSqlConversionFailure(Box::new(
                        io::Error::new(
                            io::ErrorKind::AlreadyExists,
                            "failed to allocate unique pairing session",
                        ),
                    )))
                },
            )
            .await
            .context("failed to create pairing session")
    }

    pub async fn pairing_session_for_device(
        &self,
        session_id: String,
        device_id: String,
    ) -> Result<Option<PairingSessionRecord>> {
        let device_id = normalize_device_id(&device_id);
        let now = current_epoch_seconds();

        self.connection
            .call(
                move |connection| -> rusqlite::Result<Option<PairingSessionRecord>> {
                    expire_stale_pairing_sessions(connection, now)?;

                    connection
                        .query_row(
                            r#"
                        SELECT
                            session_id,
                            public_key,
                            status,
                            completion_json,
                            expires_at_epoch_seconds,
                            claimed_at_epoch_seconds,
                            completed_at_epoch_seconds
                        FROM pairing_sessions
                        WHERE session_id = ?
                          AND device_id = ?
                        "#,
                            params![session_id, device_id],
                            pairing_session_record_from_row,
                        )
                        .optional()
                },
            )
            .await
            .context("failed to load pairing session")
    }

    pub async fn claim_pairing_session(
        &self,
        code: String,
        device_id: String,
        public_key: String,
    ) -> Result<Option<PairingSessionClaimResponse>> {
        let code_hash = hash_text(&code);
        let device_id = normalize_device_id(&device_id);
        let now = current_epoch_seconds();

        self.connection
            .call(
                move |connection| -> rusqlite::Result<Option<PairingSessionClaimResponse>> {
                    expire_stale_pairing_sessions(connection, now)?;

                    let row = connection
                        .query_row(
                            r#"
                        SELECT session_id, device_id, public_key, status, expires_at_epoch_seconds
                        FROM pairing_sessions
                        WHERE code_hash = ?
                        "#,
                            params![code_hash],
                            |row| {
                                let status_raw: String = row.get(3)?;
                                let status = parse_pairing_session_status_column(&status_raw)?;
                                Ok((
                                    row.get::<_, String>(0)?,
                                    row.get::<_, Option<String>>(1)?,
                                    row.get::<_, Option<String>>(2)?,
                                    status,
                                    row.get::<_, i64>(4)?,
                                ))
                            },
                        )
                        .optional()?;

                    let Some((
                        session_id,
                        stored_device_id,
                        stored_public_key,
                        status,
                        expires_at_epoch_seconds,
                    )) = row
                    else {
                        return Ok(None);
                    };

                    if status != PairingSessionStatus::Pending {
                        let reclaimable_status = matches!(
                            status,
                            PairingSessionStatus::Claimed
                                | PairingSessionStatus::Completed
                                | PairingSessionStatus::Failed
                        );
                        if reclaimable_status
                            && stored_device_id.as_deref() == Some(device_id.as_str())
                            && stored_public_key.as_deref() == Some(public_key.as_str())
                        {
                            return Ok(Some(PairingSessionClaimResponse {
                                session_id,
                                expires_at_epoch_seconds,
                            }));
                        }
                        return Ok(None);
                    }

                    let updated = connection.execute(
                        r#"
                    UPDATE pairing_sessions
                    SET device_id = ?, public_key = ?, status = ?, claimed_at_epoch_seconds = ?
                    WHERE session_id = ? AND status = ?
                    "#,
                        params![
                            &device_id,
                            &public_key,
                            PairingSessionStatus::Claimed.as_str(),
                            now,
                            &session_id,
                            PairingSessionStatus::Pending.as_str(),
                        ],
                    )?;

                    if updated != 1 {
                        return Ok(None);
                    }

                    Ok(Some(PairingSessionClaimResponse {
                        session_id,
                        expires_at_epoch_seconds,
                    }))
                },
            )
            .await
            .context("failed to claim pairing session")
    }

    pub async fn pairing_session_for_host(
        &self,
        session_id: String,
        host_token: String,
    ) -> Result<HostPairingSessionLookupResult> {
        let host_token_hash = hash_text(&host_token);
        let now = current_epoch_seconds();

        self.connection
            .call(
                move |connection| -> rusqlite::Result<HostPairingSessionLookupResult> {
                    expire_stale_pairing_sessions(connection, now)?;

                    let row = connection
                        .query_row(
                            r#"
                        SELECT
                            public_key,
                            status,
                            host_token_hash,
                            completion_json,
                            expires_at_epoch_seconds,
                            claimed_at_epoch_seconds,
                            completed_at_epoch_seconds
                        FROM pairing_sessions
                        WHERE session_id = ?
                        "#,
                            params![&session_id],
                            |row| {
                                let status_raw: String = row.get(1)?;
                                let status = parse_pairing_session_status_column(&status_raw)?;
                                Ok((
                                    row.get::<_, Option<String>>(0)?,
                                    status,
                                    row.get::<_, String>(2)?,
                                    row.get::<_, Option<String>>(3)?,
                                    row.get::<_, i64>(4)?,
                                    row.get::<_, Option<i64>>(5)?,
                                    row.get::<_, Option<i64>>(6)?,
                                ))
                            },
                        )
                        .optional()?;

                    let Some((
                        public_key,
                        status,
                        stored_host_token_hash,
                        completion_json,
                        expires_at_epoch_seconds,
                        claimed_at_epoch_seconds,
                        completed_at_epoch_seconds,
                    )) = row
                    else {
                        return Ok(HostPairingSessionLookupResult::NotFound);
                    };

                    if stored_host_token_hash
                        .as_bytes()
                        .ct_eq(host_token_hash.as_bytes())
                        .unwrap_u8()
                        != 1
                    {
                        return Ok(HostPairingSessionLookupResult::InvalidHostToken);
                    }

                    Ok(HostPairingSessionLookupResult::Found(Box::new(
                        PairingSessionRecord {
                            session_id,
                            public_key,
                            status,
                            expires_at_epoch_seconds,
                            claimed_at_epoch_seconds,
                            completed_at_epoch_seconds,
                            completion: decode_pairing_completion_json(completion_json)?,
                        },
                    )))
                },
            )
            .await
            .context("failed to load host pairing session")
    }

    pub async fn complete_pairing_session(
        &self,
        session_id: String,
        host_token: String,
        completion: PairingCompletionPayload,
    ) -> Result<CompletePairingSessionResult> {
        let host_token_hash = hash_text(&host_token);
        let now = current_epoch_seconds();

        self.connection
            .call(
                move |connection| -> rusqlite::Result<CompletePairingSessionResult> {
                    expire_stale_pairing_sessions(connection, now)?;

                    let row = connection
                        .query_row(
                            r#"
                        SELECT
                            public_key,
                            status,
                            host_token_hash,
                            expires_at_epoch_seconds,
                            claimed_at_epoch_seconds
                        FROM pairing_sessions
                        WHERE session_id = ?
                        "#,
                            params![&session_id],
                            |row| {
                                let status_raw: String = row.get(1)?;
                                let status = parse_pairing_session_status_column(&status_raw)?;
                                Ok((
                                    row.get::<_, Option<String>>(0)?,
                                    status,
                                    row.get::<_, String>(2)?,
                                    row.get::<_, i64>(3)?,
                                    row.get::<_, Option<i64>>(4)?,
                                ))
                            },
                        )
                        .optional()?;

                    let Some((
                        public_key,
                        status,
                        stored_host_token_hash,
                        expires_at_epoch_seconds,
                        claimed_at_epoch_seconds,
                    )) = row
                    else {
                        return Ok(CompletePairingSessionResult::NotFound);
                    };

                    if stored_host_token_hash
                        .as_bytes()
                        .ct_eq(host_token_hash.as_bytes())
                        .unwrap_u8()
                        != 1
                    {
                        return Ok(CompletePairingSessionResult::InvalidHostToken);
                    }

                    if status != PairingSessionStatus::Claimed {
                        return Ok(CompletePairingSessionResult::Unavailable);
                    }

                    let Some(public_key) = public_key else {
                        return Ok(CompletePairingSessionResult::Unavailable);
                    };

                    let next_status = if completion.error_message.is_some() {
                        PairingSessionStatus::Failed
                    } else {
                        PairingSessionStatus::Completed
                    };
                    let completion_json = serde_json::to_string(&completion).map_err(|error| {
                        rusqlite::Error::ToSqlConversionFailure(Box::new(error))
                    })?;

                    let updated = connection.execute(
                        r#"
                    UPDATE pairing_sessions
                    SET status = ?, completion_json = ?, completed_at_epoch_seconds = ?
                    WHERE session_id = ? AND status = ? AND host_token_hash = ?
                    "#,
                        params![
                            next_status.as_str(),
                            completion_json,
                            now,
                            &session_id,
                            PairingSessionStatus::Claimed.as_str(),
                            stored_host_token_hash,
                        ],
                    )?;

                    if updated != 1 {
                        return Ok(CompletePairingSessionResult::Unavailable);
                    }

                    Ok(CompletePairingSessionResult::Updated(Box::new(
                        PairingSessionRecord {
                            session_id,
                            public_key: Some(public_key),
                            status: next_status,
                            expires_at_epoch_seconds,
                            claimed_at_epoch_seconds,
                            completed_at_epoch_seconds: Some(now),
                            completion: Some(completion),
                        },
                    )))
                },
            )
            .await
            .context("failed to complete pairing session")
    }

    pub async fn issue_connector_bootstrap_token(
        &self,
        session_id: String,
        host_token: String,
    ) -> Result<Option<ConnectorBootstrapPayload>> {
        let host_token_hash = hash_text(&host_token);
        let now = current_epoch_seconds();

        self.connection
            .call(
                move |connection| -> rusqlite::Result<Option<ConnectorBootstrapPayload>> {
                    delete_expired_connector_bootstrap_tokens(connection, now)?;
                    let row = connection
                        .query_row(
                            r#"
                        SELECT device_id, status, host_token_hash, expires_at_epoch_seconds
                        FROM pairing_sessions
                        WHERE session_id = ?
                        "#,
                            params![&session_id],
                            |row| {
                                let status_raw: String = row.get(1)?;
                                let status = parse_pairing_session_status_column(&status_raw)?;
                                Ok((
                                    row.get::<_, Option<String>>(0)?,
                                    status,
                                    row.get::<_, String>(2)?,
                                    row.get::<_, i64>(3)?,
                                ))
                            },
                        )
                        .optional()?;

                    let Some((device_id, status, stored_host_token_hash, pairing_expires_at)) = row
                    else {
                        return Ok(None);
                    };

                    if stored_host_token_hash
                        .as_bytes()
                        .ct_eq(host_token_hash.as_bytes())
                        .unwrap_u8()
                        != 1
                    {
                        return Ok(None);
                    }
                    if status != PairingSessionStatus::Claimed {
                        return Ok(None);
                    }
                    let Some(device_id) = device_id else {
                        return Ok(None);
                    };

                    let expires_at_epoch_seconds = std::cmp::min(
                        pairing_expires_at,
                        now + CONNECTOR_BOOTSTRAP_TOKEN_TTL_SECONDS,
                    );
                    if expires_at_epoch_seconds <= now {
                        return Ok(None);
                    }

                    connection.execute(
                        "DELETE FROM connector_bootstrap_tokens WHERE session_id = ?",
                        params![&session_id],
                    )?;

                    let token = generate_pairing_host_token();
                    let token_hash = hash_text(&token);
                    connection.execute(
                        r#"
                    INSERT INTO connector_bootstrap_tokens (
                        token_hash,
                        session_id,
                        device_id,
                        expires_at_epoch_seconds,
                        created_at_epoch_seconds,
                        consumed_at_epoch_seconds
                    )
                    VALUES (?, ?, ?, ?, ?, NULL)
                    "#,
                        params![
                            token_hash,
                            &session_id,
                            device_id,
                            expires_at_epoch_seconds,
                            now,
                        ],
                    )?;

                    Ok(Some(ConnectorBootstrapPayload {
                        token,
                        expires_at_epoch_seconds,
                    }))
                },
            )
            .await
            .context("failed to issue connector bootstrap token")
    }

    pub async fn register_connector_from_bootstrap(
        &self,
        bootstrap_token: String,
        machine_id: String,
        ssh_username: String,
        platform: PairingPlatform,
        port: u16,
        existing_connector_id: Option<String>,
        existing_connector_secret: Option<String>,
        require_existing_host_proof: bool,
    ) -> Result<Option<ConnectorRegistrationRecord>> {
        let token_hash = hash_text(&bootstrap_token);
        let now = current_epoch_seconds();

        self.connection
            .call(
                move |connection| -> rusqlite::Result<Option<ConnectorRegistrationRecord>> {
                    let tx = connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
                    let connection = &tx;
                    delete_expired_connector_bootstrap_tokens(connection, now)?;
                    let row = connection
                        .query_row(
                            r#"
                            SELECT device_id, expires_at_epoch_seconds, consumed_at_epoch_seconds
                            FROM connector_bootstrap_tokens
                            WHERE token_hash = ?
                            "#,
                            params![token_hash],
                            |row| {
                                Ok((
                                    row.get::<_, String>(0)?,
                                    row.get::<_, i64>(1)?,
                                    row.get::<_, Option<i64>>(2)?,
                                ))
                            },
                        )
                        .optional()?;

                    let Some((device_id, expires_at_epoch_seconds, consumed_at_epoch_seconds)) =
                        row
                    else {
                        return Ok(None);
                    };
                    if consumed_at_epoch_seconds.is_some() || expires_at_epoch_seconds <= now {
                        return Ok(None);
                    }

                    let existing_host_id = connection
                        .query_row(
                            r#"
                            SELECT relay_host_id
                            FROM relay_hosts
                            WHERE machine_id = ? AND ssh_username = ?
                            "#,
                            params![&machine_id, &ssh_username],
                            |row| row.get::<_, String>(0),
                        )
                        .optional()?;
                    let existing_grant = match &existing_host_id {
                        Some(host_id) => connection.query_row("SELECT EXISTS(SELECT 1 FROM device_relay_host_grants WHERE relay_host_id = ? AND device_id = ?)", params![host_id, &device_id], |row| row.get::<_, bool>(0))?,
                        None => false,
                    };
                    if let Some(host_id) = &existing_host_id {
                        let proof_hash: Option<String> = match (&existing_connector_id, &existing_connector_secret) {
                            (Some(id), Some(_)) => connection.query_row("SELECT connector_secret_hash FROM connectors WHERE connector_id = ? AND relay_host_id = ?", params![id, host_id], |row| row.get(0)).optional()?,
                            _ => None,
                        };
                        let proven = match (proof_hash, &existing_connector_secret) {
                            (Some(expected), Some(secret)) => expected.as_bytes().ct_eq(hash_text(secret).as_bytes()).unwrap_u8() == 1,
                            _ => false,
                        };
                        if require_existing_host_proof && !existing_grant && !proven { return Ok(None); }
                    }
                    let host_count: i64 = connection.query_row("SELECT COUNT(*) FROM relay_hosts", [], |row| row.get(0))?;
                    let grant_count: i64 = connection.query_row("SELECT COUNT(*) FROM device_relay_host_grants WHERE device_id = ?", params![&device_id], |row| row.get(0))?;
                    if (existing_host_id.is_none() && host_count >= 4096) || (!existing_grant && grant_count >= 32) { return Err(capacity_error("host_capacity")); }
                    let relay_host_id = existing_host_id.unwrap_or_else(generate_pairing_session_id);

                    connection.execute(
                        r#"
                        INSERT INTO relay_hosts (
                            relay_host_id,
                            machine_id,
                            ssh_username,
                            platform,
                            port,
                            created_at_epoch_seconds,
                            updated_at_epoch_seconds
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(relay_host_id) DO UPDATE SET
                            machine_id = excluded.machine_id,
                            ssh_username = excluded.ssh_username,
                            platform = excluded.platform,
                            port = excluded.port,
                            updated_at_epoch_seconds = excluded.updated_at_epoch_seconds
                        "#,
                        params![
                            &relay_host_id,
                            &machine_id,
                            &ssh_username,
                            platform.as_str(),
                            i64::from(port),
                            now,
                            now,
                        ],
                    )?;

                    let connector_id = generate_pairing_session_id();
                    let connector_secret = generate_pairing_host_token();
                    let connector_secret_hash = hash_text(&connector_secret);

                    connection.execute(
                        r#"
                        INSERT INTO connectors (
                            connector_id,
                            relay_host_id,
                            connector_secret_hash,
                            created_at_epoch_seconds,
                            updated_at_epoch_seconds
                        )
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(relay_host_id) DO UPDATE SET
                            connector_id = excluded.connector_id,
                            connector_secret_hash = excluded.connector_secret_hash,
                            updated_at_epoch_seconds = excluded.updated_at_epoch_seconds
                        "#,
                        params![
                            &connector_id,
                            &relay_host_id,
                            connector_secret_hash,
                            now,
                            now,
                        ],
                    )?;

                    connection.execute(
                        r#"
                        INSERT INTO device_relay_host_grants (
                            relay_host_id,
                            device_id,
                            created_at_epoch_seconds
                        )
                        VALUES (?, ?, ?)
                        ON CONFLICT(relay_host_id, device_id) DO NOTHING
                        "#,
                        params![&relay_host_id, device_id, now],
                    )?;

                    connection.execute(
                        r#"
                        UPDATE connector_bootstrap_tokens
                        SET consumed_at_epoch_seconds = ?
                        WHERE token_hash = ?
                        "#,
                        params![now, hash_text(&bootstrap_token)],
                    )?;

                    tx.commit()?;
                    Ok(Some(ConnectorRegistrationRecord {
                        connector_id,
                        connector_secret,
                        relay_host_id,
                    }))
                },
            )
            .await
            .context("failed to register connector from bootstrap token")
    }

    pub async fn connector_for_credentials(
        &self,
        connector_id: String,
        connector_secret: String,
    ) -> Result<Option<ConnectorAuthRecord>> {
        let connector_secret_hash = hash_text(&connector_secret);

        self.connection
            .call(
                move |connection| -> rusqlite::Result<Option<ConnectorAuthRecord>> {
                    let row = connection
                        .query_row(
                            r#"
                        SELECT relay_host_id, connector_secret_hash
                        FROM connectors
                        WHERE connector_id = ?
                        "#,
                            params![&connector_id],
                            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
                        )
                        .optional()?;

                    let Some((relay_host_id, stored_secret_hash)) = row else {
                        return Ok(None);
                    };
                    if stored_secret_hash
                        .as_bytes()
                        .ct_eq(connector_secret_hash.as_bytes())
                        .unwrap_u8()
                        != 1
                    {
                        return Ok(None);
                    }

                    Ok(Some(ConnectorAuthRecord {
                        connector_id,
                        relay_host_id,
                    }))
                },
            )
            .await
            .context("failed to authenticate connector credentials")
    }

    pub async fn touch_connector(&self, connector_id: String) -> Result<()> {
        let now = current_epoch_seconds();
        self.connection
            .call(move |connection| -> rusqlite::Result<()> {
                connection.execute(
                    "UPDATE connectors SET updated_at_epoch_seconds = ? WHERE connector_id = ?",
                    params![now, connector_id],
                )?;
                Ok(())
            })
            .await
            .context("failed to update connector last-seen timestamp")
    }

    pub async fn store_relay_attach_token(
        &self,
        token: String,
        kind: RelayTokenKind,
        relay_host_id: String,
        relay_session_id: Option<String>,
        connector_id: Option<String>,
        expires_at_epoch_seconds: i64,
    ) -> Result<()> {
        let token_hash = hash_text(&token);
        let kind_name = kind.as_str().to_owned();
        let now = current_epoch_seconds();

        self.connection
            .call(move |connection| -> rusqlite::Result<()> {
                maybe_delete_expired_relay_attach_tokens(connection, now)?;
                connection.execute(
                    r#"
                    INSERT INTO relay_attach_tokens (
                        token_hash,
                        kind,
                        relay_host_id,
                        relay_session_id,
                        connector_id,
                        expires_at_epoch_seconds,
                        created_at_epoch_seconds,
                        consumed_at_epoch_seconds
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
                    "#,
                    params![
                        token_hash,
                        kind_name,
                        relay_host_id,
                        relay_session_id,
                        connector_id,
                        expires_at_epoch_seconds,
                        now,
                    ],
                )?;
                Ok(())
            })
            .await
            .context("failed to store relay attach token")
    }

    pub async fn consume_relay_attach_token(
        &self,
        token: String,
        kind: RelayTokenKind,
    ) -> Result<Option<RelayAttachTokenRecord>> {
        let token_hash = hash_text(&token);
        let kind_name = kind.as_str().to_owned();
        let now = current_epoch_seconds();

        self.connection
            .call(
                move |connection| -> rusqlite::Result<Option<RelayAttachTokenRecord>> {
                    maybe_delete_expired_relay_attach_tokens(connection, now)?;

                    let transaction = connection.transaction()?;
                    let row = transaction
                        .query_row(
                            r#"
                            SELECT relay_host_id, relay_session_id, connector_id, kind
                            FROM relay_attach_tokens
                            WHERE token_hash = ?
                            "#,
                            params![&token_hash],
                            |row| {
                                Ok((
                                    row.get::<_, String>(0)?,
                                    row.get::<_, Option<String>>(1)?,
                                    row.get::<_, Option<String>>(2)?,
                                    row.get::<_, String>(3)?,
                                ))
                            },
                        )
                        .optional()?;

                    let Some((relay_host_id, relay_session_id, connector_id, stored_kind)) = row
                    else {
                        transaction.commit()?;
                        return Ok(None);
                    };

                    if stored_kind != kind_name {
                        transaction.commit()?;
                        return Ok(None);
                    }

                    let updated = transaction.execute(
                        r#"
                        UPDATE relay_attach_tokens
                        SET consumed_at_epoch_seconds = ?
                        WHERE token_hash = ?
                          AND kind = ?
                          AND consumed_at_epoch_seconds IS NULL
                          AND expires_at_epoch_seconds > ?
                        "#,
                        params![now, token_hash, kind_name, now],
                    )?;

                    if updated != 1 {
                        transaction.commit()?;
                        return Ok(None);
                    }

                    transaction.commit()?;
                    Ok(Some(RelayAttachTokenRecord {
                        relay_host_id,
                        relay_session_id,
                        connector_id,
                    }))
                },
            )
            .await
            .context("failed to consume relay attach token")
    }

    pub async fn create_ssh_relay_session(
        &self,
        device_id: String,
        device_secret: String,
        relay_host_id: String,
    ) -> Result<Option<SshRelaySessionRecord>> {
        let device_id = normalize_device_id(&device_id);
        let device_secret_hash = hash_text(&device_secret);
        let now = current_epoch_seconds();

        self.connection
            .call(
                move |connection| -> rusqlite::Result<Option<SshRelaySessionRecord>> {
                    delete_expired_ssh_relay_sessions(connection, now)?;
                    if !authenticate_device(connection, &device_id, &device_secret_hash)? {
                        return Ok(None);
                    }

                    let has_grant = connection
                        .query_row(
                            r#"
                        SELECT 1
                        FROM device_relay_host_grants
                        WHERE relay_host_id = ? AND device_id = ?
                        "#,
                            params![&relay_host_id, &device_id],
                            |_| Ok(()),
                        )
                        .optional()?
                        .is_some();
                    if !has_grant {
                        return Ok(None);
                    }

                    let relay_session_id = generate_pairing_session_id();
                    let expires_at_epoch_seconds = now + SSH_RELAY_SESSION_TTL_SECONDS;
                    connection.execute(
                        r#"
                    INSERT INTO ssh_relay_sessions (
                        relay_session_id,
                        relay_host_id,
                        device_id,
                        expires_at_epoch_seconds,
                        created_at_epoch_seconds,
                        closed_at_epoch_seconds,
                        close_reason
                    )
                    VALUES (?, ?, ?, ?, ?, NULL, NULL)
                    "#,
                        params![
                            &relay_session_id,
                            &relay_host_id,
                            &device_id,
                            expires_at_epoch_seconds,
                            now,
                        ],
                    )?;

                    Ok(Some(SshRelaySessionRecord {
                        relay_host_id,
                        relay_session_id,
                        device_id,
                        expires_at_epoch_seconds,
                    }))
                },
            )
            .await
            .context("failed to create SSH relay session")
    }

    pub async fn close_ssh_relay_session(
        &self,
        relay_session_id: String,
        close_reason: String,
    ) -> Result<()> {
        let now = current_epoch_seconds();
        self.connection
            .call(move |connection| -> rusqlite::Result<()> {
                connection.execute(
                    r#"
                    UPDATE ssh_relay_sessions
                    SET closed_at_epoch_seconds = COALESCE(closed_at_epoch_seconds, ?),
                        close_reason = COALESCE(close_reason, ?)
                    WHERE relay_session_id = ?
                    "#,
                    params![now, close_reason, relay_session_id],
                )?;
                Ok(())
            })
            .await
            .context("failed to close SSH relay session")
    }

    pub async fn get_device_for_relay_token(
        &self,
        relay_token: &str,
    ) -> Result<Option<DeviceRecord>> {
        let relay_token_hash = hash_text(relay_token);
        let now = current_epoch_seconds();

        let device = self
            .connection
            .call(
                move |connection| -> rusqlite::Result<Option<DeviceRecord>> {
                    let row = connection
                        .query_row(
                            r#"
                            SELECT
                                d.device_id,
                                d.apns_token,
                                d.bundle_id,
                                d.push_environment
                            FROM relay_sessions s
                            JOIN devices d ON d.device_id = s.device_id
                            WHERE s.relay_token_hash = ?
                              AND s.expires_at_epoch_seconds > ?
                              AND s.scope IN ('legacy', 'notify')
                            "#,
                            params![relay_token_hash, now],
                            |row| {
                                let push_environment: String = row.get(3)?;
                                let push_environment = parse_environment_column(&push_environment)?;
                                Ok(DeviceRecord {
                                    device_id: row.get(0)?,
                                    apns_token: row.get(1)?,
                                    bundle_id: row.get(2)?,
                                    push_environment,
                                })
                            },
                        )
                        .optional()?;

                    Ok(row)
                },
            )
            .await
            .context("failed to resolve relay token")?;

        Ok(device)
    }

    pub async fn dictation_authorization(
        &self,
        token: String,
    ) -> Result<Option<(DeviceRecord, Option<(String, DictationTier)>)>> {
        let token_hash = hash_text(&token);
        let now = current_epoch_seconds();
        self.connection.call(move |connection| {
            connection.query_row("SELECT d.device_id, d.apns_token, d.bundle_id, d.push_environment, s.dictation_identity, s.dictation_tier FROM relay_sessions s JOIN devices d ON d.device_id = s.device_id WHERE s.relay_token_hash = ? AND s.expires_at_epoch_seconds > ? AND s.scope IN ('legacy', 'dictation')", params![token_hash, now], |row| {
                let identity: Option<String> = row.get(4)?;
                let tier: Option<String> = row.get(5)?;
                Ok((
                    DeviceRecord { device_id: row.get(0)?, apns_token: row.get(1)?, bundle_id: row.get(2)?, push_environment: parse_environment_column(&row.get::<_, String>(3)?)? },
                    identity.map(|identity| (identity, DictationTier::from_stored(tier.as_deref()))),
                ))
            }).optional()
        }).await.context("failed to authenticate dictation token")
    }

    pub async fn device_by_id(&self, device_id: String) -> Result<Option<DeviceRecord>> {
        let device_id = normalize_device_id(&device_id);

        self.connection
            .call(
                move |connection| -> rusqlite::Result<Option<DeviceRecord>> {
                    connection
                        .query_row(
                            r#"
                        SELECT
                            device_id,
                            apns_token,
                            bundle_id,
                            push_environment
                        FROM devices
                        WHERE device_id = ?
                        "#,
                            params![device_id],
                            |row| {
                                let push_environment: String = row.get(3)?;
                                let push_environment = parse_environment_column(&push_environment)?;
                                Ok(DeviceRecord {
                                    device_id: row.get(0)?,
                                    apns_token: row.get(1)?,
                                    bundle_id: row.get(2)?,
                                    push_environment,
                                })
                            },
                        )
                        .optional()
                },
            )
            .await
            .context("failed to load device by id")
    }

    pub async fn analytics_issue_candidates_for_user(
        &self,
        user_key_hash: String,
    ) -> Result<Vec<AnalyticsIssueCandidate>> {
        self.connection
            .call(
                move |connection| -> rusqlite::Result<Vec<AnalyticsIssueCandidate>> {
                    let mut statement = connection.prepare(
                        r#"
                    SELECT
                        signature_key,
                        user_key_hash,
                        issue_kind,
                        issue_severity,
                        summary,
                        first_seen_at_epoch_seconds,
                        last_seen_at_epoch_seconds,
                        occurrence_count
                    FROM analytics_blocked_user_candidates
                    WHERE user_key_hash = ?
                    ORDER BY
                        CASE issue_severity
                            WHEN 'blocked' THEN 0
                            ELSE 1
                        END,
                        last_seen_at_epoch_seconds DESC,
                        signature_key ASC
                    "#,
                    )?;
                    let rows = statement
                        .query_map(params![user_key_hash], analytics_issue_candidate_from_row)?;
                    rows.collect::<rusqlite::Result<Vec<_>>>()
                },
            )
            .await
            .context("failed to load analytics issue candidates")
    }

    pub async fn list_analytics_blocked_user_candidates(
        &self,
    ) -> Result<Vec<AnalyticsIssueCandidate>> {
        self.connection
            .call(
                move |connection| -> rusqlite::Result<Vec<AnalyticsIssueCandidate>> {
                    let mut statement = connection.prepare(
                        r#"
                    SELECT
                        signature_key,
                        user_key_hash,
                        issue_kind,
                        issue_severity,
                        summary,
                        first_seen_at_epoch_seconds,
                        last_seen_at_epoch_seconds,
                        occurrence_count
                    FROM analytics_blocked_user_candidates
                    ORDER BY
                        CASE issue_severity
                            WHEN 'blocked' THEN 0
                            ELSE 1
                        END,
                        last_seen_at_epoch_seconds DESC,
                        signature_key ASC
                    "#,
                    )?;
                    let rows = statement.query_map([], analytics_issue_candidate_from_row)?;
                    rows.collect::<rusqlite::Result<Vec<_>>>()
                },
            )
            .await
            .context("failed to list analytics issue candidates")
    }

    pub async fn list_recent_analytics_issue_alerts(
        &self,
        limit: usize,
    ) -> Result<Vec<AnalyticsStoredIssueAlert>> {
        let limit = i64::try_from(limit).unwrap_or(i64::MAX);
        self.connection
            .call(
                move |connection| -> rusqlite::Result<Vec<AnalyticsStoredIssueAlert>> {
                    let mut statement = connection.prepare(
                        r#"
                    SELECT
                        signature_key,
                        user_key_hash,
                        issue_kind,
                        issue_severity,
                        summary,
                        first_seen_at_epoch_seconds,
                        last_seen_at_epoch_seconds,
                        first_alerted_at_epoch_seconds,
                        last_alerted_at_epoch_seconds,
                        alert_count
                    FROM analytics_issue_alerts
                    WHERE last_alerted_at_epoch_seconds IS NOT NULL
                    ORDER BY last_alerted_at_epoch_seconds DESC, signature_key ASC
                    LIMIT ?
                    "#,
                    )?;
                    let rows =
                        statement.query_map(params![limit], analytics_issue_alert_from_row)?;
                    rows.collect::<rusqlite::Result<Vec<_>>>()
                },
            )
            .await
            .context("failed to list analytics issue alerts")
    }

    pub async fn upsert_analytics_issue_candidate(
        &self,
        issue: AnalyticsIssueCandidate,
        cooldown_seconds: i64,
        now: i64,
    ) -> Result<AnalyticsIssueAlertDecision> {
        self.connection
            .call(
                move |connection| -> rusqlite::Result<AnalyticsIssueAlertDecision> {
                    let existing_row = connection
                        .query_row(
                            r#"
                        SELECT
                            issue_severity,
                            last_alerted_at_epoch_seconds
                        FROM analytics_issue_alerts
                        WHERE signature_key = ?
                        "#,
                            params![&issue.signature_key],
                            |row| {
                                let severity: String = row.get(0)?;
                                Ok((
                                    parse_analytics_issue_severity(&severity)?,
                                    row.get::<_, Option<i64>>(1)?,
                                ))
                            },
                        )
                        .optional()?;

                    let existing_severity = existing_row.as_ref().map(|(severity, _)| *severity);
                    let last_alerted_at_epoch_seconds =
                        existing_row
                            .as_ref()
                            .and_then(|(_, last_alerted_at_epoch_seconds)| {
                                *last_alerted_at_epoch_seconds
                            });
                    let severity_escalated = existing_severity
                        .map(|severity| issue.issue_severity.rank() > severity.rank())
                        .unwrap_or(false);
                    let should_send_alert =
                        matches!(issue.issue_severity, AnalyticsIssueSeverity::Blocked)
                            && last_alerted_at_epoch_seconds.is_none_or(
                                |last_alerted_at_epoch_seconds| {
                                    severity_escalated
                                        || now - last_alerted_at_epoch_seconds >= cooldown_seconds
                                },
                            );

                    connection.execute(
                        r#"
                    INSERT INTO analytics_issue_alerts (
                        signature_key,
                        user_key_hash,
                        issue_kind,
                        issue_severity,
                        summary,
                        first_seen_at_epoch_seconds,
                        last_seen_at_epoch_seconds,
                        first_alerted_at_epoch_seconds,
                        last_alerted_at_epoch_seconds,
                        alert_count
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, NULL, NULL, 0)
                    ON CONFLICT(signature_key) DO UPDATE SET
                        issue_severity = excluded.issue_severity,
                        summary = excluded.summary,
                        first_seen_at_epoch_seconds = MIN(
                            analytics_issue_alerts.first_seen_at_epoch_seconds,
                            excluded.first_seen_at_epoch_seconds
                        ),
                        last_seen_at_epoch_seconds = MAX(
                            analytics_issue_alerts.last_seen_at_epoch_seconds,
                            excluded.last_seen_at_epoch_seconds
                        )
                    "#,
                        params![
                            &issue.signature_key,
                            &issue.user_key_hash,
                            issue.issue_kind.as_str(),
                            issue.issue_severity.as_str(),
                            &issue.summary,
                            issue.first_seen_at_epoch_seconds,
                            issue.last_seen_at_epoch_seconds,
                        ],
                    )?;

                    Ok(AnalyticsIssueAlertDecision { should_send_alert })
                },
            )
            .await
            .context("failed to upsert analytics issue candidate")
    }

    pub async fn mark_analytics_issue_alert_sent(
        &self,
        signature_key: String,
        sent_at_epoch_seconds: i64,
    ) -> Result<()> {
        self.connection
            .call(move |connection| -> rusqlite::Result<()> {
                connection.execute(
                    r#"
                    UPDATE analytics_issue_alerts
                    SET
                        first_alerted_at_epoch_seconds = COALESCE(
                            first_alerted_at_epoch_seconds,
                            ?
                        ),
                        last_alerted_at_epoch_seconds = ?,
                        alert_count = alert_count + 1
                    WHERE signature_key = ?
                    "#,
                    params![sent_at_epoch_seconds, sent_at_epoch_seconds, signature_key],
                )?;
                Ok(())
            })
            .await
            .context("failed to mark analytics issue alert as sent")
    }

    pub async fn reserve_dictation(
        &self,
        subject: DictationSubject,
        limits: DictationLimits,
        windows: DictationWindows,
        minimum_seconds: i64,
        preferred_seconds: i64,
    ) -> Result<Result<DictationGrant, DictationQuotaExceeded>> {
        anyhow::ensure!(
            0 < minimum_seconds
                && minimum_seconds <= preferred_seconds
                && preferred_seconds <= 1800,
            "invalid dictation charge"
        );
        let now = current_epoch_seconds();
        self.connection.call(move |connection| -> rusqlite::Result<Result<DictationGrant, DictationQuotaExceeded>> {
            let tx = connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let (weekly_used, legacy_used): (i64, i64) = tx.query_row("SELECT used_seconds, legacy_seconds FROM dictation_operator_usage WHERE week_start_epoch_seconds = ?", params![windows.week_start], |row| Ok((row.get(0)?, row.get(1)?))).optional()?.unwrap_or((0, 0));
            let daily_used: i64 = tx.query_row("SELECT used_seconds FROM dictation_operator_daily WHERE day = ?", params![windows.day], |row| row.get(0)).optional()?.unwrap_or(0);
            let legacy = matches!(subject, DictationSubject::LegacyDevice(_));
            let mut operator_available = (limits.daily_seconds - daily_used).min(limits.weekly_seconds - weekly_used);
            if legacy {
                operator_available = if limits.require_verified_devices { 0 } else { operator_available.min(limits.legacy_weekly_seconds - legacy_used) };
            }
            let (subject_available, resets) = match &subject {
                DictationSubject::Ledger { hash, monthly_seconds } => {
                    let used: i64 = tx.query_row("SELECT used_seconds FROM dictation_monthly_usage WHERE subject_hash = ? AND month_start_epoch_seconds = ?", params![hash, windows.month_start], |row| row.get(0)).optional()?.unwrap_or(0);
                    (monthly_seconds - used, windows.next_month_start)
                }
                DictationSubject::LegacyDevice(device_id) => {
                    let used: i64 = tx.query_row("SELECT used_seconds FROM dictation_usage_weekly WHERE device_id = ? AND week_start_epoch_seconds = ?", params![normalize_device_id(device_id), windows.week_start], |row| row.get(0)).optional()?.unwrap_or(0);
                    (DICTATION_WEEKLY_LIMIT_SECONDS - used, windows.week_resets_at())
                }
            };
            if subject_available < minimum_seconds || operator_available < minimum_seconds {
                return Ok(Err(DictationQuotaExceeded { operator_limit: subject_available >= minimum_seconds, remaining_seconds: subject_available.max(0), quota_resets_at_epoch_seconds: resets }));
            }
            let seconds = preferred_seconds.min(subject_available).min(operator_available);
            match &subject {
                DictationSubject::Ledger { hash, .. } => {
                    tx.execute("INSERT INTO dictation_monthly_usage VALUES (?, ?, ?) ON CONFLICT(subject_hash, month_start_epoch_seconds) DO UPDATE SET used_seconds = used_seconds + excluded.used_seconds", params![hash, windows.month_start, seconds])?;
                    tx.execute("DELETE FROM dictation_monthly_usage WHERE month_start_epoch_seconds < ?", params![windows.month_start - 400 * 86_400])?;
                }
                DictationSubject::LegacyDevice(device_id) => {
                    tx.execute("INSERT INTO dictation_usage_weekly VALUES (?, ?, ?, ?, ?) ON CONFLICT(device_id, week_start_epoch_seconds) DO UPDATE SET used_seconds = used_seconds + excluded.used_seconds, updated_at_epoch_seconds = excluded.updated_at_epoch_seconds", params![normalize_device_id(device_id), windows.week_start, seconds, now, now])?;
                }
            }
            tx.execute("INSERT INTO dictation_operator_usage VALUES (?, ?, ?) ON CONFLICT(week_start_epoch_seconds) DO UPDATE SET used_seconds = used_seconds + excluded.used_seconds, legacy_seconds = legacy_seconds + excluded.legacy_seconds", params![windows.week_start, seconds, if legacy { seconds } else { 0 }])?;
            tx.execute("INSERT INTO dictation_operator_daily VALUES (?, ?) ON CONFLICT(day) DO UPDATE SET used_seconds = used_seconds + excluded.used_seconds", params![windows.day, seconds])?;
            tx.execute("DELETE FROM dictation_operator_daily WHERE day < ?", params![windows.day - 8])?;
            tx.commit()?;
            Ok(Ok(DictationGrant { seconds, remaining_seconds: subject_available - seconds, resets_at_epoch_seconds: resets }))
        }).await.context("failed to reserve dictation")
    }

    pub async fn release_dictation(
        &self,
        subject: DictationSubject,
        windows: DictationWindows,
        personal_seconds: i64,
        operator_seconds: i64,
    ) -> Result<()> {
        anyhow::ensure!(
            personal_seconds >= 0 && operator_seconds >= 0,
            "invalid dictation release"
        );
        let now = current_epoch_seconds();
        self.connection.call(move |connection| -> rusqlite::Result<()> {
            let tx = connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let legacy = match &subject {
                DictationSubject::Ledger { hash, .. } => {
                    tx.execute("UPDATE dictation_monthly_usage SET used_seconds = MAX(0, used_seconds - ?) WHERE subject_hash = ? AND month_start_epoch_seconds = ?", params![personal_seconds, hash, windows.month_start])?;
                    false
                }
                DictationSubject::LegacyDevice(device_id) => {
                    tx.execute("UPDATE dictation_usage_weekly SET used_seconds = MAX(0, used_seconds - ?), updated_at_epoch_seconds = ? WHERE device_id = ? AND week_start_epoch_seconds = ?", params![personal_seconds, now, normalize_device_id(device_id), windows.week_start])?;
                    true
                }
            };
            tx.execute("UPDATE dictation_operator_usage SET used_seconds = MAX(0, used_seconds - ?1), legacy_seconds = MAX(0, legacy_seconds - ?2) WHERE week_start_epoch_seconds = ?3", params![operator_seconds, if legacy { operator_seconds } else { 0 }, windows.week_start])?;
            tx.execute("UPDATE dictation_operator_daily SET used_seconds = MAX(0, used_seconds - ?) WHERE day = ?", params![operator_seconds, windows.day])?;
            tx.commit()
        }).await.context("failed to release dictation")
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn ingest_analytics_batch(
        &self,
        device_id: String,
        device_context: AnalyticsDeviceContextRecord,
        user_key_hash: String,
        original_purchase_date_epoch_seconds: i64,
        bundle_id: String,
        app_transaction_environment: String,
        app_version: String,
        build_number: String,
        flavor: String,
        platform: String,
        events: Vec<AnalyticsEventRecord>,
    ) -> Result<()> {
        let device_id = normalize_device_id(&device_id);
        let now = current_epoch_seconds();
        let first_seen_at_epoch_seconds = events
            .iter()
            .map(|event| event.occurred_at_epoch_seconds)
            .min()
            .unwrap_or(now);
        let last_seen_at_epoch_seconds = events
            .iter()
            .map(|event| event.occurred_at_epoch_seconds)
            .max()
            .unwrap_or(now);
        let latest_access_state = latest_access_state_from_events(&events);
        let latest_saved_host_count = latest_saved_host_count_from_events(&events);

        self.connection
            .call(move |connection| -> rusqlite::Result<()> {
                let tx = connection.transaction()?;

                tx.execute(
                    r#"
                    INSERT INTO analytics_users (
                        user_key_hash,
                        first_seen_at_epoch_seconds,
                        last_seen_at_epoch_seconds,
                        original_purchase_date_epoch_seconds,
                        last_bundle_id,
                        last_app_transaction_environment,
                        last_app_version,
                        last_build_number,
                        last_flavor,
                        last_platform,
                        last_access_state_at_epoch_seconds,
                        last_has_lifetime_access,
                        last_trial_expired,
                        last_trial_consumed_usage_seconds,
                        last_trial_remaining_usage_seconds,
                        updated_at_epoch_seconds
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 0, 0, 0, 0, ?)
                    ON CONFLICT(user_key_hash) DO UPDATE SET
                        first_seen_at_epoch_seconds = MIN(analytics_users.first_seen_at_epoch_seconds, excluded.first_seen_at_epoch_seconds),
                        last_seen_at_epoch_seconds = MAX(analytics_users.last_seen_at_epoch_seconds, excluded.last_seen_at_epoch_seconds),
                        original_purchase_date_epoch_seconds = MIN(
                            analytics_users.original_purchase_date_epoch_seconds,
                            excluded.original_purchase_date_epoch_seconds
                        ),
                        last_bundle_id = excluded.last_bundle_id,
                        last_app_transaction_environment = excluded.last_app_transaction_environment,
                        last_app_version = excluded.last_app_version,
                        last_build_number = excluded.last_build_number,
                        last_flavor = excluded.last_flavor,
                        last_platform = excluded.last_platform,
                        updated_at_epoch_seconds = excluded.updated_at_epoch_seconds
                    "#,
                    params![
                        &user_key_hash,
                        first_seen_at_epoch_seconds,
                        last_seen_at_epoch_seconds,
                        original_purchase_date_epoch_seconds,
                        &bundle_id,
                        &app_transaction_environment,
                        &app_version,
                        &build_number,
                        &flavor,
                        &platform,
                        now,
                    ],
                )?;

                tx.execute(
                    r#"
                    INSERT INTO analytics_device_user_links (
                        device_id,
                        user_key_hash,
                        first_seen_at_epoch_seconds,
                        last_seen_at_epoch_seconds,
                        last_system_version,
                        last_device_model_identifier,
                        last_device_family,
                        last_locale_identifier,
                        last_preferred_languages_json,
                        last_saved_host_count
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(device_id, user_key_hash) DO UPDATE SET
                        first_seen_at_epoch_seconds = MIN(
                            analytics_device_user_links.first_seen_at_epoch_seconds,
                            excluded.first_seen_at_epoch_seconds
                        ),
                        last_seen_at_epoch_seconds = MAX(
                            analytics_device_user_links.last_seen_at_epoch_seconds,
                            excluded.last_seen_at_epoch_seconds
                        ),
                        last_system_version = COALESCE(
                            excluded.last_system_version,
                            analytics_device_user_links.last_system_version
                        ),
                        last_device_model_identifier = COALESCE(
                            excluded.last_device_model_identifier,
                            analytics_device_user_links.last_device_model_identifier
                        ),
                        last_device_family = COALESCE(
                            excluded.last_device_family,
                            analytics_device_user_links.last_device_family
                        ),
                        last_locale_identifier = COALESCE(
                            excluded.last_locale_identifier,
                            analytics_device_user_links.last_locale_identifier
                        ),
                        last_preferred_languages_json = COALESCE(
                            excluded.last_preferred_languages_json,
                            analytics_device_user_links.last_preferred_languages_json
                        ),
                        last_saved_host_count = COALESCE(
                            excluded.last_saved_host_count,
                            analytics_device_user_links.last_saved_host_count
                        )
                    "#,
                    params![
                        &device_id,
                        &user_key_hash,
                        first_seen_at_epoch_seconds,
                        last_seen_at_epoch_seconds,
                        device_context.system_version,
                        device_context.device_model_identifier,
                        device_context.device_family,
                        device_context.locale_identifier,
                        device_context.preferred_languages_json,
                        latest_saved_host_count,
                    ],
                )?;

                if let Some((access_state_at_epoch_seconds, access_state)) = latest_access_state {
                    tx.execute(
                        r#"
                        UPDATE analytics_users
                        SET
                            last_access_state_at_epoch_seconds = ?,
                            last_has_lifetime_access = ?,
                            last_trial_expired = ?,
                            last_trial_consumed_usage_seconds = ?,
                            last_trial_remaining_usage_seconds = ?,
                            updated_at_epoch_seconds = ?
                        WHERE user_key_hash = ?
                          AND (
                            last_access_state_at_epoch_seconds IS NULL
                            OR last_access_state_at_epoch_seconds <= ?
                          )
                        "#,
                        params![
                            access_state_at_epoch_seconds,
                            access_state.has_lifetime_access,
                            access_state.trial_expired,
                            access_state.trial_consumed_usage_seconds,
                            access_state.trial_remaining_usage_seconds,
                            now,
                            &user_key_hash,
                            access_state_at_epoch_seconds,
                        ],
                    )?;
                }

                let mut insert_event = tx.prepare(
                    r#"
                    INSERT OR IGNORE INTO analytics_events (
                        event_id,
                        user_key_hash,
                        device_id,
                        event_type,
                        occurred_at_epoch_seconds,
                        received_at_epoch_seconds,
                        bundle_id,
                        app_transaction_environment,
                        app_version,
                        build_number,
                        flavor,
                        platform,
                        payload_json
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    "#,
                )?;

                for event in &events {
                    insert_event.execute(params![
                        &event.event_id,
                        &user_key_hash,
                        &device_id,
                        event.event_type.as_str(),
                        event.occurred_at_epoch_seconds,
                        now,
                        &bundle_id,
                        &app_transaction_environment,
                        &app_version,
                        &build_number,
                        &flavor,
                        &platform,
                        &event.payload_json,
                    ])?;
                }

                drop(insert_event);
                let mut insert_sensitive_context = tx.prepare(
                    r#"
                    INSERT INTO analytics_sensitive_event_context (
                        event_id,
                        raw_detected_username,
                        detected_username_hash,
                        raw_selected_candidate_value,
                        selected_candidate_value_hash,
                        raw_candidate_values_json,
                        candidate_values_hashes_json,
                        raw_disconnect_reason,
                        disconnect_reason_hash,
                        raw_error_detail,
                        error_detail_hash,
                        created_at_epoch_seconds,
                        redacted_at_epoch_seconds
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                    ON CONFLICT(event_id) DO NOTHING
                    "#,
                )?;

                for event in &events {
                    let Some(sensitive_context) = &event.sensitive_context else {
                        continue;
                    };
                    let raw_detected_username =
                        sensitive_context.raw_detected_username.as_deref();
                    let raw_selected_candidate_value =
                        sensitive_context.raw_selected_candidate_value.as_deref();
                    let raw_candidate_values_json =
                        sensitive_context.raw_candidate_values_json.as_deref();
                    let raw_disconnect_reason =
                        sensitive_context.raw_disconnect_reason.as_deref();
                    let raw_error_detail = sensitive_context.raw_error_detail.as_deref();

                    let candidate_values_hashes_json = sensitive_context
                        .raw_candidate_values_json
                        .as_ref()
                        .and_then(|value| serde_json::from_str::<Vec<String>>(value).ok())
                        .and_then(|values| {
                            serde_json::to_string(
                                &values
                                    .into_iter()
                                    .map(|value| hash_text(&value))
                                    .collect::<Vec<_>>(),
                            )
                            .ok()
                        });

                    insert_sensitive_context.execute(params![
                        &event.event_id,
                        raw_detected_username,
                        raw_detected_username.map(hash_text),
                        raw_selected_candidate_value,
                        raw_selected_candidate_value.map(hash_text),
                        raw_candidate_values_json,
                        candidate_values_hashes_json,
                        raw_disconnect_reason,
                        raw_disconnect_reason.map(hash_text),
                        raw_error_detail,
                        raw_error_detail.map(hash_text),
                        now,
                    ])?;
                }

                drop(insert_sensitive_context);
                redact_expired_sensitive_event_context(&tx, now)?;
                tx.commit()
            })
            .await
            .context("failed to ingest analytics batch")
    }

    pub async fn record_analytics_ingest_failure(
        &self,
        mut failure: AnalyticsIngestFailureRecord,
    ) -> Result<()> {
        for value in [
            &mut failure.device_id,
            &mut failure.error,
            &mut failure.event_diagnostics,
        ] {
            *value = value.chars().take(1024).collect();
        }
        for value in [
            &mut failure.user_key_hash,
            &mut failure.bundle_id,
            &mut failure.app_transaction_environment,
            &mut failure.app_version,
            &mut failure.build_number,
            &mut failure.flavor,
            &mut failure.platform,
            &mut failure.failed_event_id,
            &mut failure.failed_event_type,
            &mut failure.validation_field,
            &mut failure.validation_rule,
            &mut failure.redacted_payload_shape_json,
        ] {
            if let Some(text) = value {
                *text = text.chars().take(1024).collect();
            }
        }
        let device_id = normalize_device_id(&failure.device_id);
        let now = current_epoch_seconds();

        self.connection
            .call(move |connection| -> rusqlite::Result<()> {
                let tx = connection
                    .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
                tx.execute(
                    r#"
                    INSERT INTO analytics_ingest_failures (
                        received_at_epoch_seconds,
                        device_id,
                        user_key_hash,
                        bundle_id,
                        app_transaction_environment,
                        app_version,
                        build_number,
                        flavor,
                        platform,
                        error,
                        event_count,
                        event_diagnostics,
                        failed_event_id,
                        failed_event_type,
                        validation_field,
                        validation_rule,
                        payload_version,
                        redacted_payload_shape_json
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    "#,
                    params![
                        now,
                        device_id,
                        failure.user_key_hash,
                        failure.bundle_id,
                        failure.app_transaction_environment,
                        failure.app_version,
                        failure.build_number,
                        failure.flavor,
                        failure.platform,
                        failure.error,
                        failure.event_count,
                        failure.event_diagnostics,
                        failure.failed_event_id,
                        failure.failed_event_type,
                        failure.validation_field,
                        failure.validation_rule,
                        failure.payload_version,
                        failure.redacted_payload_shape_json,
                    ],
                )?;
                prune_ingest_failures(&tx, now)?;
                tx.commit()?;
                Ok(())
            })
            .await
            .context("failed to record analytics ingest failure")
    }
}

fn authenticate_device(
    connection: &rusqlite::Connection,
    device_id: &str,
    device_secret_hash: &str,
) -> rusqlite::Result<bool> {
    let device_id = normalize_device_id(device_id);
    let stored_hash: Option<String> = connection
        .query_row(
            "SELECT device_secret_hash FROM devices WHERE device_id = ?",
            params![device_id],
            |row| row.get(0),
        )
        .optional()?;

    let Some(stored_hash) = stored_hash else {
        return Ok(false);
    };

    Ok(stored_hash
        .as_bytes()
        .ct_eq(device_secret_hash.as_bytes())
        .unwrap_u8()
        == 1)
}

fn delete_expired_relay_sessions(
    connection: &rusqlite::Connection,
    now: i64,
) -> rusqlite::Result<()> {
    connection.execute(
        "DELETE FROM relay_sessions WHERE expires_at_epoch_seconds <= ?",
        params![now],
    )?;
    Ok(())
}

fn charge_relay_device_bandwidth(
    connection: &mut rusqlite::Connection,
    device_id: &str,
    bytes: usize,
    limits: &DictationLimits,
) -> rusqlite::Result<bool> {
    let day = current_epoch_seconds() / 86400;
    let tx = connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    let admitted: Option<(Option<String>, String)> = tx.query_row("SELECT a.identity_hash, d.device_secret_hash FROM devices d LEFT JOIN device_admissions a ON a.device_id = d.device_id WHERE d.device_id = ?", params![device_id], |row| Ok((row.get(0)?, row.get(1)?))).optional()?;
    let Some((identity, secret_hash)) = admitted else {
        return Ok(false);
    };
    let trusted = limits.trusted_devices.iter().any(|(id, hash)| {
        id == device_id && hash.as_bytes().ct_eq(secret_hash.as_bytes()).unwrap_u8() == 1
    });
    let subject = identity.as_deref().unwrap_or(device_id);
    let mut subjects = vec![
        ("operator".to_owned(), limits.relay_daily_bytes),
        (format!("device:{subject}"), limits.relay_device_daily_bytes),
    ];
    if identity.is_none() && !trusted {
        subjects.push(("legacy".to_owned(), limits.relay_legacy_daily_bytes));
    }
    for (subject, limit) in &subjects {
        let used: i64 = tx
            .query_row(
                "SELECT bytes FROM relay_bandwidth_daily WHERE subject = ? AND day = ?",
                params![subject, day],
                |row| row.get(0),
            )
            .optional()?
            .unwrap_or(0);
        if used >= *limit || bytes as i64 > *limit - used {
            tx.execute("INSERT INTO relay_bandwidth_daily VALUES (?, ?, ?) ON CONFLICT(subject, day) DO UPDATE SET bytes = MAX(bytes, excluded.bytes)", params![subject, day, limit])?;
            tx.commit()?;
            return Ok(false);
        }
    }
    if bytes > 0 {
        for (subject, _) in subjects {
            tx.execute("INSERT INTO relay_bandwidth_daily VALUES (?, ?, ?) ON CONFLICT(subject, day) DO UPDATE SET bytes = bytes + excluded.bytes", params![subject, day, bytes as i64])?;
        }
        tx.execute(
            "DELETE FROM relay_bandwidth_daily WHERE day < ?",
            params![day - 8],
        )?;
    }
    tx.commit()?;
    Ok(true)
}

fn prune_ingest_failures(connection: &rusqlite::Connection, now: i64) -> rusqlite::Result<()> {
    connection.execute(
        "DELETE FROM analytics_ingest_failures WHERE received_at_epoch_seconds < ?",
        params![now - 14 * 24 * 60 * 60],
    )?;
    connection.execute("DELETE FROM analytics_ingest_failures WHERE failure_id IN (SELECT failure_id FROM analytics_ingest_failures ORDER BY failure_id DESC LIMIT -1 OFFSET 10000)", [])?;
    Ok(())
}

fn expire_stale_pairing_sessions(
    connection: &rusqlite::Connection,
    now: i64,
) -> rusqlite::Result<()> {
    delete_expired_connector_bootstrap_tokens(connection, now)?;
    connection.execute(
        r#"
        UPDATE pairing_sessions
        SET status = ?
        WHERE expires_at_epoch_seconds <= ?
          AND status IN (?, ?)
        "#,
        params![
            PairingSessionStatus::Expired.as_str(),
            now,
            PairingSessionStatus::Pending.as_str(),
            PairingSessionStatus::Claimed.as_str(),
        ],
    )?;
    connection.execute(
        "DELETE FROM pairing_sessions WHERE expires_at_epoch_seconds < ?",
        params![now - 24 * 60 * 60],
    )?;
    Ok(())
}

fn delete_expired_connector_bootstrap_tokens(
    connection: &rusqlite::Connection,
    now: i64,
) -> rusqlite::Result<()> {
    connection.execute(
        "DELETE FROM connector_bootstrap_tokens WHERE expires_at_epoch_seconds <= ?",
        params![now],
    )?;
    Ok(())
}

fn delete_expired_relay_attach_tokens(
    connection: &rusqlite::Connection,
    now: i64,
) -> rusqlite::Result<()> {
    connection.execute(
        r#"
        DELETE FROM relay_attach_tokens
        WHERE expires_at_epoch_seconds <= ?
           OR consumed_at_epoch_seconds IS NOT NULL
        "#,
        params![now],
    )?;
    Ok(())
}

fn maybe_delete_expired_relay_attach_tokens(
    connection: &rusqlite::Connection,
    now: i64,
) -> rusqlite::Result<()> {
    let last_cleanup = LAST_RELAY_ATTACH_TOKEN_CLEANUP_EPOCH_SECONDS.load(Ordering::Relaxed);
    if last_cleanup > 0 && now - last_cleanup < RELAY_ATTACH_TOKEN_CLEANUP_INTERVAL_SECONDS {
        return Ok(());
    }

    let claimed_cleanup = LAST_RELAY_ATTACH_TOKEN_CLEANUP_EPOCH_SECONDS.compare_exchange(
        last_cleanup,
        now,
        Ordering::Relaxed,
        Ordering::Relaxed,
    );
    if claimed_cleanup.is_err() {
        return Ok(());
    }

    delete_expired_relay_attach_tokens(connection, now)
}

fn delete_expired_ssh_relay_sessions(
    connection: &rusqlite::Connection,
    now: i64,
) -> rusqlite::Result<()> {
    connection.execute(
        r#"
        DELETE FROM ssh_relay_sessions
        WHERE expires_at_epoch_seconds <= ?
          AND closed_at_epoch_seconds IS NOT NULL
        "#,
        params![now],
    )?;
    Ok(())
}

fn redact_expired_sensitive_event_context(
    connection: &rusqlite::Connection,
    now: i64,
) -> rusqlite::Result<()> {
    let redact_before = now - ANALYTICS_SENSITIVE_CONTEXT_RETENTION_SECONDS;
    connection.execute(
        r#"
        UPDATE analytics_sensitive_event_context
        SET
            raw_detected_username = NULL,
            raw_selected_candidate_value = NULL,
            raw_candidate_values_json = NULL,
            raw_disconnect_reason = NULL,
            raw_error_detail = NULL,
            redacted_at_epoch_seconds = COALESCE(redacted_at_epoch_seconds, ?)
        WHERE created_at_epoch_seconds <= ?
          AND redacted_at_epoch_seconds IS NULL
        "#,
        params![now, redact_before],
    )?;
    Ok(())
}

fn pairing_session_record_from_row(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<PairingSessionRecord> {
    let status_raw: String = row.get(2)?;
    let status = parse_pairing_session_status_column(&status_raw)?;
    let completion_json: Option<String> = row.get(3)?;

    Ok(PairingSessionRecord {
        session_id: row.get(0)?,
        public_key: row.get(1)?,
        status,
        completion: decode_pairing_completion_json(completion_json)?,
        expires_at_epoch_seconds: row.get(4)?,
        claimed_at_epoch_seconds: row.get(5)?,
        completed_at_epoch_seconds: row.get(6)?,
    })
}

fn decode_pairing_completion_json(
    completion_json: Option<String>,
) -> rusqlite::Result<Option<PairingCompletionPayload>> {
    completion_json
        .map(|value| {
            serde_json::from_str::<PairingCompletionPayload>(&value).map_err(|error| {
                rusqlite::Error::FromSqlConversionFailure(
                    3,
                    rusqlite::types::Type::Text,
                    Box::new(error),
                )
            })
        })
        .transpose()
}

fn parse_environment_column(value: &str) -> rusqlite::Result<PushEnvironment> {
    PushEnvironment::from_str(value).map_err(|_| {
        rusqlite::Error::FromSqlConversionFailure(
            0,
            rusqlite::types::Type::Text,
            Box::new(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("invalid push_environment {value}"),
            )),
        )
    })
}

fn parse_pairing_session_status_column(value: &str) -> rusqlite::Result<PairingSessionStatus> {
    PairingSessionStatus::from_str(value).map_err(|_| {
        rusqlite::Error::FromSqlConversionFailure(
            0,
            rusqlite::types::Type::Text,
            Box::new(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("invalid pairing_session status {value}"),
            )),
        )
    })
}

fn parse_analytics_issue_kind(value: &str) -> rusqlite::Result<AnalyticsIssueKind> {
    AnalyticsIssueKind::from_str(value).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(error))
    })
}

fn parse_analytics_issue_severity(value: &str) -> rusqlite::Result<AnalyticsIssueSeverity> {
    AnalyticsIssueSeverity::from_str(value).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(error))
    })
}

fn analytics_issue_candidate_from_row(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<AnalyticsIssueCandidate> {
    let issue_kind: String = row.get(2)?;
    let issue_severity: String = row.get(3)?;
    Ok(AnalyticsIssueCandidate {
        signature_key: row.get(0)?,
        user_key_hash: row.get(1)?,
        issue_kind: parse_analytics_issue_kind(&issue_kind)?,
        issue_severity: parse_analytics_issue_severity(&issue_severity)?,
        summary: row.get(4)?,
        first_seen_at_epoch_seconds: row.get(5)?,
        last_seen_at_epoch_seconds: row.get(6)?,
        occurrence_count: row.get(7)?,
    })
}

fn analytics_issue_alert_from_row(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<AnalyticsStoredIssueAlert> {
    let issue_kind: String = row.get(2)?;
    let issue_severity: String = row.get(3)?;
    Ok(AnalyticsStoredIssueAlert {
        signature_key: row.get(0)?,
        user_key_hash: row.get(1)?,
        issue_kind: parse_analytics_issue_kind(&issue_kind)?,
        issue_severity: parse_analytics_issue_severity(&issue_severity)?,
        summary: row.get(4)?,
        first_seen_at_epoch_seconds: row.get(5)?,
        last_seen_at_epoch_seconds: row.get(6)?,
        first_alerted_at_epoch_seconds: row.get(7)?,
        last_alerted_at_epoch_seconds: row.get(8)?,
        alert_count: row.get(9)?,
    })
}

fn current_epoch_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or_default()
}

pub(crate) fn hash_text(value: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(value.as_bytes());
    hex::encode(hasher.finalize())
}

fn is_unique_constraint(error: &rusqlite::Error) -> bool {
    matches!(
        error,
        rusqlite::Error::SqliteFailure(code, _)
            if code.extended_code == rusqlite::ffi::SQLITE_CONSTRAINT_PRIMARYKEY
                || code.extended_code == rusqlite::ffi::SQLITE_CONSTRAINT_UNIQUE
    )
}

fn ensure_pairing_sessions_schema(connection: &rusqlite::Connection) -> rusqlite::Result<()> {
    if pairing_sessions_schema_is_current(connection)? {
        connection.execute_batch(
            r#"
            CREATE INDEX IF NOT EXISTS idx_pairing_sessions_device_id
            ON pairing_sessions(device_id);

            CREATE INDEX IF NOT EXISTS idx_pairing_sessions_expires_at
            ON pairing_sessions(expires_at_epoch_seconds);
            "#,
        )?;
        return Ok(());
    }

    connection.execute("DROP TABLE IF EXISTS pairing_sessions", [])?;
    connection.execute_batch(
        r#"
        CREATE TABLE pairing_sessions (
            session_id TEXT PRIMARY KEY,
            device_id TEXT,
            public_key TEXT,
            code_hash TEXT NOT NULL UNIQUE,
            host_token_hash TEXT NOT NULL,
            status TEXT NOT NULL,
            completion_json TEXT,
            expires_at_epoch_seconds INTEGER NOT NULL,
            created_at_epoch_seconds INTEGER NOT NULL,
            claimed_at_epoch_seconds INTEGER,
            completed_at_epoch_seconds INTEGER,
            FOREIGN KEY(device_id) REFERENCES devices(device_id)
        );

        CREATE INDEX idx_pairing_sessions_device_id
        ON pairing_sessions(device_id);

        CREATE INDEX idx_pairing_sessions_expires_at
        ON pairing_sessions(expires_at_epoch_seconds);
        "#,
    )?;

    Ok(())
}

fn ensure_relay_connector_schema(connection: &rusqlite::Connection) -> rusqlite::Result<()> {
    connection.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS relay_hosts (
            relay_host_id TEXT PRIMARY KEY,
            machine_id TEXT NOT NULL,
            ssh_username TEXT NOT NULL,
            platform TEXT NOT NULL,
            port INTEGER NOT NULL,
            created_at_epoch_seconds INTEGER NOT NULL,
            updated_at_epoch_seconds INTEGER NOT NULL,
            UNIQUE(machine_id, ssh_username)
        );

        CREATE TABLE IF NOT EXISTS device_relay_host_grants (
            relay_host_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            created_at_epoch_seconds INTEGER NOT NULL,
            PRIMARY KEY(relay_host_id, device_id),
            FOREIGN KEY(relay_host_id) REFERENCES relay_hosts(relay_host_id),
            FOREIGN KEY(device_id) REFERENCES devices(device_id)
        );

        CREATE TABLE IF NOT EXISTS connectors (
            connector_id TEXT PRIMARY KEY,
            relay_host_id TEXT NOT NULL UNIQUE,
            connector_secret_hash TEXT NOT NULL,
            created_at_epoch_seconds INTEGER NOT NULL,
            updated_at_epoch_seconds INTEGER NOT NULL,
            FOREIGN KEY(relay_host_id) REFERENCES relay_hosts(relay_host_id)
        );

        CREATE TABLE IF NOT EXISTS connector_bootstrap_tokens (
            token_hash TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            expires_at_epoch_seconds INTEGER NOT NULL,
            created_at_epoch_seconds INTEGER NOT NULL,
            consumed_at_epoch_seconds INTEGER,
            FOREIGN KEY(session_id) REFERENCES pairing_sessions(session_id),
            FOREIGN KEY(device_id) REFERENCES devices(device_id)
        );

        CREATE TABLE IF NOT EXISTS ssh_relay_sessions (
            relay_session_id TEXT PRIMARY KEY,
            relay_host_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            expires_at_epoch_seconds INTEGER NOT NULL,
            created_at_epoch_seconds INTEGER NOT NULL,
            closed_at_epoch_seconds INTEGER,
            close_reason TEXT,
            FOREIGN KEY(relay_host_id) REFERENCES relay_hosts(relay_host_id),
            FOREIGN KEY(device_id) REFERENCES devices(device_id)
        );

        CREATE TABLE IF NOT EXISTS relay_attach_tokens (
            token_hash TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            relay_host_id TEXT NOT NULL,
            relay_session_id TEXT,
            connector_id TEXT,
            expires_at_epoch_seconds INTEGER NOT NULL,
            created_at_epoch_seconds INTEGER NOT NULL,
            consumed_at_epoch_seconds INTEGER,
            FOREIGN KEY(relay_host_id) REFERENCES relay_hosts(relay_host_id)
        );

        CREATE INDEX IF NOT EXISTS idx_connector_bootstrap_tokens_expires_at
        ON connector_bootstrap_tokens(expires_at_epoch_seconds);

        CREATE INDEX IF NOT EXISTS idx_device_relay_host_grants_device_id
        ON device_relay_host_grants(device_id);

        CREATE INDEX IF NOT EXISTS idx_ssh_relay_sessions_expires_at
        ON ssh_relay_sessions(expires_at_epoch_seconds);

        CREATE INDEX IF NOT EXISTS idx_relay_attach_tokens_expires_at
        ON relay_attach_tokens(expires_at_epoch_seconds);
        "#,
    )?;

    Ok(())
}

fn ensure_dictation_usage_schema(connection: &rusqlite::Connection) -> rusqlite::Result<()> {
    connection.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS dictation_usage_weekly (
            device_id TEXT NOT NULL,
            week_start_epoch_seconds INTEGER NOT NULL,
            used_seconds INTEGER NOT NULL,
            created_at_epoch_seconds INTEGER NOT NULL,
            updated_at_epoch_seconds INTEGER NOT NULL,
            PRIMARY KEY (device_id, week_start_epoch_seconds),
            FOREIGN KEY(device_id) REFERENCES devices(device_id)
        );

        CREATE TABLE IF NOT EXISTS dictation_monthly_usage (
            subject_hash TEXT NOT NULL,
            month_start_epoch_seconds INTEGER NOT NULL,
            used_seconds INTEGER NOT NULL CHECK(used_seconds >= 0),
            PRIMARY KEY(subject_hash, month_start_epoch_seconds)
        );
        CREATE TABLE IF NOT EXISTS dictation_operator_daily (
            day INTEGER PRIMARY KEY,
            used_seconds INTEGER NOT NULL CHECK(used_seconds >= 0)
        );
        CREATE TABLE IF NOT EXISTS dictation_operator_usage (
            week_start_epoch_seconds INTEGER PRIMARY KEY,
            used_seconds INTEGER NOT NULL CHECK(used_seconds >= 0),
            legacy_seconds INTEGER NOT NULL CHECK(legacy_seconds >= 0)
        );
        INSERT INTO dictation_operator_usage
        SELECT week_start_epoch_seconds, SUM(used_seconds), SUM(used_seconds)
        FROM dictation_usage_weekly GROUP BY week_start_epoch_seconds
        ON CONFLICT(week_start_epoch_seconds) DO NOTHING;
        CREATE INDEX IF NOT EXISTS idx_dictation_usage_weekly_device_id
        ON dictation_usage_weekly(device_id);
        "#,
    )?;

    Ok(())
}

fn ensure_analytics_schema(connection: &rusqlite::Connection) -> rusqlite::Result<()> {
    connection.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS analytics_users (
            user_key_hash TEXT PRIMARY KEY,
            first_seen_at_epoch_seconds INTEGER NOT NULL,
            last_seen_at_epoch_seconds INTEGER NOT NULL,
            original_purchase_date_epoch_seconds INTEGER NOT NULL,
            last_bundle_id TEXT NOT NULL,
            last_app_transaction_environment TEXT NOT NULL,
            last_app_version TEXT NOT NULL,
            last_build_number TEXT NOT NULL,
            last_flavor TEXT NOT NULL,
            last_platform TEXT NOT NULL,
            last_access_state_at_epoch_seconds INTEGER,
            last_has_lifetime_access INTEGER NOT NULL,
            last_trial_expired INTEGER NOT NULL,
            last_trial_consumed_usage_seconds REAL NOT NULL,
            last_trial_remaining_usage_seconds REAL NOT NULL,
            updated_at_epoch_seconds INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS analytics_device_user_links (
            device_id TEXT NOT NULL,
            user_key_hash TEXT NOT NULL,
            first_seen_at_epoch_seconds INTEGER NOT NULL,
            last_seen_at_epoch_seconds INTEGER NOT NULL,
            PRIMARY KEY (device_id, user_key_hash),
            FOREIGN KEY(device_id) REFERENCES devices(device_id),
            FOREIGN KEY(user_key_hash) REFERENCES analytics_users(user_key_hash)
        );

        CREATE INDEX IF NOT EXISTS idx_analytics_device_user_links_user_key_hash
        ON analytics_device_user_links(user_key_hash);

        CREATE TABLE IF NOT EXISTS analytics_events (
            event_id TEXT PRIMARY KEY,
            user_key_hash TEXT NOT NULL,
            device_id TEXT NOT NULL,
            event_type TEXT NOT NULL,
            occurred_at_epoch_seconds INTEGER NOT NULL,
            received_at_epoch_seconds INTEGER NOT NULL,
            bundle_id TEXT NOT NULL,
            app_transaction_environment TEXT NOT NULL,
            app_version TEXT NOT NULL,
            build_number TEXT NOT NULL,
            flavor TEXT NOT NULL,
            platform TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            FOREIGN KEY(device_id) REFERENCES devices(device_id),
            FOREIGN KEY(user_key_hash) REFERENCES analytics_users(user_key_hash)
        );

        CREATE INDEX IF NOT EXISTS idx_analytics_events_user_key_hash
        ON analytics_events(user_key_hash);

        CREATE INDEX IF NOT EXISTS idx_analytics_events_device_id
        ON analytics_events(device_id);

        CREATE INDEX IF NOT EXISTS idx_analytics_events_type_occurred_at
        ON analytics_events(event_type, occurred_at_epoch_seconds);

        CREATE TABLE IF NOT EXISTS analytics_sensitive_event_context (
            event_id TEXT PRIMARY KEY,
            raw_detected_username TEXT,
            detected_username_hash TEXT,
            raw_selected_candidate_value TEXT,
            selected_candidate_value_hash TEXT,
            raw_candidate_values_json TEXT,
            candidate_values_hashes_json TEXT,
            raw_disconnect_reason TEXT,
            disconnect_reason_hash TEXT,
            raw_error_detail TEXT,
            error_detail_hash TEXT,
            created_at_epoch_seconds INTEGER NOT NULL,
            redacted_at_epoch_seconds INTEGER,
            FOREIGN KEY(event_id) REFERENCES analytics_events(event_id)
        );

        CREATE INDEX IF NOT EXISTS idx_analytics_sensitive_event_context_created_at
        ON analytics_sensitive_event_context(created_at_epoch_seconds);

        CREATE TABLE IF NOT EXISTS analytics_issue_alerts (
            signature_key TEXT PRIMARY KEY,
            user_key_hash TEXT NOT NULL,
            issue_kind TEXT NOT NULL,
            issue_severity TEXT NOT NULL,
            summary TEXT NOT NULL,
            first_seen_at_epoch_seconds INTEGER NOT NULL,
            last_seen_at_epoch_seconds INTEGER NOT NULL,
            first_alerted_at_epoch_seconds INTEGER,
            last_alerted_at_epoch_seconds INTEGER,
            alert_count INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS analytics_ingest_failures (
            failure_id INTEGER PRIMARY KEY AUTOINCREMENT,
            received_at_epoch_seconds INTEGER NOT NULL,
            device_id TEXT NOT NULL,
            user_key_hash TEXT,
            bundle_id TEXT,
            app_transaction_environment TEXT,
            app_version TEXT,
            build_number TEXT,
            flavor TEXT,
            platform TEXT,
            error TEXT NOT NULL,
            event_count INTEGER NOT NULL,
            event_diagnostics TEXT NOT NULL,
            failed_event_id TEXT,
            failed_event_type TEXT,
            validation_field TEXT,
            validation_rule TEXT,
            payload_version INTEGER,
            redacted_payload_shape_json TEXT
        );
        "#,
    )?;

    ensure_table_has_columns(
        connection,
        "analytics_ingest_failures",
        &[
            ("failed_event_id", "TEXT"),
            ("failed_event_type", "TEXT"),
            ("validation_field", "TEXT"),
            ("validation_rule", "TEXT"),
            ("payload_version", "INTEGER"),
            ("redacted_payload_shape_json", "TEXT"),
        ],
    )?;

    ensure_table_has_columns(
        connection,
        "analytics_device_user_links",
        &[
            ("last_system_version", "TEXT"),
            ("last_device_model_identifier", "TEXT"),
            ("last_device_family", "TEXT"),
            ("last_locale_identifier", "TEXT"),
            ("last_preferred_languages_json", "TEXT"),
            ("last_saved_host_count", "INTEGER"),
        ],
    )?;

    connection.execute_batch(
        r#"
        DROP VIEW IF EXISTS analytics_paid_conversion_summary;
        DROP VIEW IF EXISTS analytics_current_user_summary;
        DROP VIEW IF EXISTS analytics_retention_summary;
        DROP VIEW IF EXISTS analytics_paywall_summary;
        DROP VIEW IF EXISTS analytics_onboarding_funnel;
        DROP VIEW IF EXISTS analytics_user_engagement_summary;
        DROP VIEW IF EXISTS analytics_user_paywall_summary;
        DROP VIEW IF EXISTS analytics_user_host_setup_summary;
        DROP VIEW IF EXISTS analytics_user_flow_timeline;
        DROP VIEW IF EXISTS analytics_blocked_user_candidates;
        DROP VIEW IF EXISTS analytics_host_setup_issue_signatures;
        DROP VIEW IF EXISTS analytics_host_setup_failure_summary;
        DROP VIEW IF EXISTS analytics_ssh_failure_summary;
        DROP VIEW IF EXISTS analytics_key_import_issue_summary;
        DROP VIEW IF EXISTS analytics_candidate_quality_summary;
        DROP VIEW IF EXISTS analytics_alert_digest_queue;
        DROP VIEW IF EXISTS analytics_recent_issue_alerts;
        DROP VIEW IF EXISTS analytics_recent_ingest_failures;
        DROP VIEW IF EXISTS analytics_ingest_failure_summary;
        DROP VIEW IF EXISTS analytics_latest_device_user_link;
        DROP VIEW IF EXISTS analytics_first_terminal_input;
        DROP VIEW IF EXISTS analytics_first_successful_ssh;
        DROP VIEW IF EXISTS analytics_installs_per_user;
        DROP VIEW IF EXISTS analytics_user_daily_activity;

        CREATE VIEW analytics_user_daily_activity AS
        SELECT
            user_key_hash,
            date(occurred_at_epoch_seconds, 'unixepoch') AS activity_date
        FROM analytics_events
        WHERE event_type IN ('app_session_completed', 'ssh_session_completed')
        GROUP BY user_key_hash, activity_date;

        DROP VIEW IF EXISTS analytics_installs_per_user;
        CREATE VIEW analytics_installs_per_user AS
        SELECT
            user_key_hash,
            COUNT(*) AS install_count,
            MIN(first_seen_at_epoch_seconds) AS first_seen_at_epoch_seconds,
            MAX(last_seen_at_epoch_seconds) AS last_seen_at_epoch_seconds
        FROM analytics_device_user_links
        GROUP BY user_key_hash;

        DROP VIEW IF EXISTS analytics_first_successful_ssh;
        CREATE VIEW analytics_first_successful_ssh AS
        SELECT
            user_key_hash,
            MIN(occurred_at_epoch_seconds) AS first_successful_ssh_at_epoch_seconds
        FROM analytics_events
        WHERE event_type = 'ssh_session_completed'
          AND json_extract(payload_json, '$.session.was_ready') = 1
        GROUP BY user_key_hash;

        CREATE VIEW analytics_first_terminal_input AS
        SELECT
            user_key_hash,
            MIN(occurred_at_epoch_seconds) AS first_terminal_input_at_epoch_seconds
        FROM analytics_events
        WHERE event_type = 'ssh_session_completed'
          AND COALESCE(json_extract(payload_json, '$.input.had_terminal_input'), 0) = 1
        GROUP BY user_key_hash;

        CREATE VIEW analytics_latest_device_user_link AS
        SELECT
            device_id,
            user_key_hash,
            first_seen_at_epoch_seconds,
            last_seen_at_epoch_seconds,
            last_system_version,
            last_device_model_identifier,
            last_device_family,
            last_locale_identifier,
            last_preferred_languages_json,
            last_saved_host_count
        FROM (
            SELECT
                analytics_device_user_links.*,
                ROW_NUMBER() OVER (
                    PARTITION BY user_key_hash
                    ORDER BY last_seen_at_epoch_seconds DESC, device_id DESC
                ) AS device_rank
            FROM analytics_device_user_links
        )
        WHERE device_rank = 1;

        CREATE VIEW analytics_user_flow_timeline AS
        SELECT
            e.user_key_hash,
            e.device_id,
            e.event_id,
            e.event_type,
            e.occurred_at_epoch_seconds,
            COALESCE(
                json_extract(e.payload_json, '$.context.app_session_id'),
                CASE e.event_type
                    WHEN 'app_session_completed' THEN json_extract(e.payload_json, '$.session.id')
                    ELSE NULL
                END
            ) AS app_session_id,
            CASE e.event_type
                WHEN 'host_setup_flow_event' THEN json_extract(e.payload_json, '$.flow.id')
                WHEN 'ssh_session_completed' THEN json_extract(e.payload_json, '$.session.id')
                ELSE NULL
            END AS correlation_id,
            COALESCE(
                json_extract(e.payload_json, '$.flow.stage'),
                json_extract(e.payload_json, '$.stage'),
                json_extract(e.payload_json, '$.state'),
                json_extract(e.payload_json, '$.reason')
            ) AS primary_state,
            json_extract(e.payload_json, '$.flow.method') AS setup_method,
            json_extract(e.payload_json, '$.error.category') AS error_category,
            json_extract(e.payload_json, '$.error.reason') AS failure_reason,
            json_extract(e.payload_json, '$.disconnect.category') AS disconnect_category,
            COALESCE(
                json_extract(e.payload_json, '$.disconnect.failure_stage'),
                json_extract(e.payload_json, '$.verification.failure_stage')
            ) AS failure_stage,
            s.raw_detected_username,
            s.raw_selected_candidate_value,
            s.raw_disconnect_reason,
            s.raw_error_detail
        FROM analytics_events e
        LEFT JOIN analytics_sensitive_event_context s USING (event_id);

        CREATE VIEW analytics_host_setup_failure_summary AS
        SELECT
            e.user_key_hash,
            COALESCE(json_extract(e.payload_json, '$.flow.method'), 'unknown') AS method,
            COALESCE(json_extract(e.payload_json, '$.flow.stage'), 'unknown') AS stage,
            COALESCE(json_extract(e.payload_json, '$.error.category'), 'unknown') AS error_category,
            COALESCE(json_extract(e.payload_json, '$.verification.failure_stage'), 'unknown') AS verification_failure_stage,
            COALESCE(json_extract(e.payload_json, '$.verification.disconnect_category'), 'unknown') AS verification_disconnect_category,
            COALESCE(json_extract(e.payload_json, '$.host_environment.platform'), 'unknown') AS host_platform,
            COUNT(*) AS failure_count,
            SUM(CASE WHEN s.raw_error_detail IS NOT NULL THEN 1 ELSE 0 END) AS failures_with_detail,
            MIN(e.occurred_at_epoch_seconds) AS first_seen_at_epoch_seconds,
            MAX(e.occurred_at_epoch_seconds) AS last_seen_at_epoch_seconds
        FROM analytics_events e
        LEFT JOIN analytics_sensitive_event_context s USING (event_id)
        WHERE e.event_type = 'host_setup_flow_event'
          AND json_extract(e.payload_json, '$.flow.stage') IN ('failed', 'verification_failed')
        GROUP BY
            e.user_key_hash,
            COALESCE(json_extract(e.payload_json, '$.flow.method'), 'unknown'),
            COALESCE(json_extract(e.payload_json, '$.flow.stage'), 'unknown'),
            COALESCE(json_extract(e.payload_json, '$.error.category'), 'unknown'),
            COALESCE(json_extract(e.payload_json, '$.verification.failure_stage'), 'unknown'),
            COALESCE(json_extract(e.payload_json, '$.verification.disconnect_category'), 'unknown'),
            COALESCE(json_extract(e.payload_json, '$.host_environment.platform'), 'unknown');

        CREATE VIEW analytics_candidate_quality_summary AS
        SELECT
            user_key_hash,
            COUNT(*) AS host_setup_event_count,
            SUM(CASE
                WHEN json_extract(payload_json, '$.flow.method') = 'automatic'
                THEN 1 ELSE 0
            END) AS automatic_host_setup_event_count,
            SUM(CASE
                WHEN json_extract(payload_json, '$.flow.method') = 'automatic'
                 AND COALESCE(json_extract(payload_json, '$.candidates.all_low_confidence'), 0) = 1
                THEN 1 ELSE 0
            END) AS automatic_all_low_confidence_event_count,
            SUM(CASE
                WHEN json_extract(payload_json, '$.flow.method') = 'automatic'
                 AND COALESCE(json_extract(payload_json, '$.detected_username.suspicious'), 0) = 1
                THEN 1 ELSE 0
            END) AS automatic_username_suspicious_event_count,
            MAX(COALESCE(json_extract(payload_json, '$.candidates.count'), 0)) AS max_candidate_count,
            MAX(COALESCE(
                json_extract(payload_json, '$.candidates.high_confidence_count'),
                0
            )) AS max_high_confidence_candidate_count
        FROM analytics_events
        WHERE event_type = 'host_setup_flow_event'
        GROUP BY user_key_hash;

        CREATE VIEW analytics_ssh_failure_summary AS
        SELECT
            user_key_hash,
            COALESCE(json_extract(payload_json, '$.disconnect.failure_stage'), 'unknown') AS failure_stage,
            COALESCE(json_extract(payload_json, '$.disconnect.category'), 'unknown') AS disconnect_category,
            COALESCE(json_extract(payload_json, '$.auth.mode'), 'unknown') AS auth_mode,
            COUNT(*) AS failure_count,
            MIN(occurred_at_epoch_seconds) AS first_seen_at_epoch_seconds,
            MAX(occurred_at_epoch_seconds) AS last_seen_at_epoch_seconds
        FROM analytics_events
        WHERE event_type = 'ssh_session_completed'
          AND COALESCE(json_extract(payload_json, '$.session.was_ready'), 0) = 0
        GROUP BY user_key_hash, failure_stage, disconnect_category, auth_mode;

        CREATE VIEW analytics_key_import_issue_summary AS
        SELECT
            user_key_hash,
            COALESCE(json_extract(payload_json, '$.error.reason'), 'unknown') AS failure_reason,
            COUNT(*) AS failure_count,
            MIN(occurred_at_epoch_seconds) AS first_seen_at_epoch_seconds,
            MAX(occurred_at_epoch_seconds) AS last_seen_at_epoch_seconds
        FROM analytics_events
        WHERE event_type = 'key_material_event'
          AND json_extract(payload_json, '$.stage') = 'failed'
        GROUP BY user_key_hash, failure_reason;

        CREATE VIEW analytics_host_setup_issue_signatures AS
        WITH host_setup_events AS (
            SELECT
                user_key_hash,
                event_id,
                occurred_at_epoch_seconds,
                COALESCE(json_extract(payload_json, '$.flow.id'), event_id) AS flow_key,
                json_extract(payload_json, '$.flow.method') AS method,
                json_extract(payload_json, '$.flow.stage') AS stage,
                json_extract(payload_json, '$.error.category') AS error_category,
                COALESCE(json_extract(payload_json, '$.candidates.all_low_confidence'), 0) AS all_low_confidence_candidates,
                COALESCE(json_extract(payload_json, '$.detected_username.suspicious'), 0) AS username_suspicious,
                COALESCE(json_extract(payload_json, '$.reachability.attempt_count'), 0) AS probe_attempt_count,
                COALESCE(json_extract(payload_json, '$.verification.attempt_count'), 0) AS verification_attempt_count,
                json_extract(payload_json, '$.host.id_hash') AS host_id_hash
            FROM analytics_events
            WHERE event_type = 'host_setup_flow_event'
        ),
        host_setup_flow_summary AS (
            SELECT
                user_key_hash,
                flow_key,
                MIN(occurred_at_epoch_seconds) AS first_seen_at_epoch_seconds,
                MAX(occurred_at_epoch_seconds) AS last_seen_at_epoch_seconds,
                MAX(method) AS method,
                MAX(CASE WHEN stage = 'pairing_completed' THEN 1 ELSE 0 END) AS has_pairing_completed,
                MAX(CASE WHEN stage = 'review_presented' THEN 1 ELSE 0 END) AS has_review_presented,
                MAX(CASE WHEN stage = 'save_succeeded' THEN 1 ELSE 0 END) AS has_save_succeeded,
                MAX(CASE WHEN stage = 'save_succeeded_unreachable' THEN 1 ELSE 0 END) AS has_save_succeeded_unreachable,
                MAX(CASE
                    WHEN stage = 'failed' AND error_category = 'reachability'
                    THEN 1 ELSE 0
                END) AS has_reachability_failure,
                MAX(CASE
                    WHEN stage = 'verification_failed'
                      OR (stage = 'failed' AND error_category = 'connection_verification')
                    THEN 1 ELSE 0
                END) AS has_verification_failure,
                MAX(CASE
                    WHEN stage = 'failed' AND error_category = 'pairing'
                    THEN 1 ELSE 0
                END) AS has_pairing_failure,
                MAX(all_low_confidence_candidates) AS all_low_confidence_candidates,
                MAX(username_suspicious) AS username_suspicious,
                MAX(probe_attempt_count) AS probe_attempt_count,
                MAX(verification_attempt_count) AS verification_attempt_count,
                MAX(host_id_hash) AS host_id_hash
            FROM host_setup_events
            GROUP BY user_key_hash, flow_key
        ),
        saved_host_without_ready_ssh AS (
            SELECT
                host_saves.user_key_hash,
                host_saves.host_id_hash,
                host_saves.saved_at_epoch_seconds
            FROM (
                SELECT
                    user_key_hash,
                    json_extract(payload_json, '$.host.id_hash') AS host_id_hash,
                    MIN(occurred_at_epoch_seconds) AS saved_at_epoch_seconds
                FROM analytics_events
                WHERE event_type = 'host_setup_flow_event'
                  AND json_extract(payload_json, '$.flow.stage') IN (
                    'save_succeeded',
                    'save_succeeded_unreachable',
                    'save_succeeded_unverified'
                  )
                  AND json_extract(payload_json, '$.host.id_hash') IS NOT NULL
                GROUP BY user_key_hash, host_id_hash
            ) AS host_saves
            LEFT JOIN (
                SELECT
                    user_key_hash,
                    COALESCE(
                        json_extract(payload_json, '$.host.id_hash'),
                        json_extract(payload_json, '$.host.key_hash')
                    ) AS host_reference,
                    MIN(occurred_at_epoch_seconds) AS ready_at_epoch_seconds
                FROM analytics_events
                WHERE event_type = 'ssh_session_completed'
                  AND COALESCE(json_extract(payload_json, '$.session.was_ready'), 0) = 1
                GROUP BY user_key_hash, host_reference
            ) AS ready_ssh
                ON ready_ssh.user_key_hash = host_saves.user_key_hash
               AND ready_ssh.host_reference = host_saves.host_id_hash
            WHERE ready_ssh.ready_at_epoch_seconds IS NULL
               OR ready_ssh.ready_at_epoch_seconds > host_saves.saved_at_epoch_seconds + 900
        )
        SELECT
            user_key_hash,
            printf('host_setup:%s:automatic_all_low_confidence_candidates', flow_key) AS signature_key,
            'automatic_all_low_confidence_candidates' AS issue_kind,
            'warning' AS issue_severity,
            'Automatic setup completed with only low-confidence host candidates.' AS summary,
            first_seen_at_epoch_seconds,
            last_seen_at_epoch_seconds,
            1 AS occurrence_count
        FROM host_setup_flow_summary
        WHERE method = 'automatic'
          AND has_pairing_completed = 1
          AND all_low_confidence_candidates = 1
        UNION ALL
        SELECT
            user_key_hash,
            printf('host_setup:%s:automatic_username_resolution_unreliable', flow_key) AS signature_key,
            'automatic_username_resolution_unreliable' AS issue_kind,
            'warning' AS issue_severity,
            'Automatic setup had to fall back while resolving the remote username.' AS summary,
            first_seen_at_epoch_seconds,
            last_seen_at_epoch_seconds,
            1 AS occurrence_count
        FROM host_setup_flow_summary
        WHERE method = 'automatic'
          AND username_suspicious = 1
        UNION ALL
        SELECT
            user_key_hash,
            printf('host_setup:%s:automatic_reachability_failure_after_pairing', flow_key) AS signature_key,
            'automatic_reachability_failure_after_pairing' AS issue_kind,
            'blocked' AS issue_severity,
            'Automatic pairing completed, but AgenTTY could not verify a ready connection afterward.' AS summary,
            first_seen_at_epoch_seconds,
            last_seen_at_epoch_seconds,
            CASE
                WHEN verification_attempt_count > 0 THEN verification_attempt_count
                WHEN probe_attempt_count > 0 THEN probe_attempt_count
                ELSE 1
            END AS occurrence_count
        FROM host_setup_flow_summary
        WHERE method = 'automatic'
          AND has_pairing_completed = 1
          AND (has_reachability_failure = 1 OR has_verification_failure = 1)
        UNION ALL
        SELECT
            user_key_hash,
            printf('host_save:%s:saved_host_without_ready_ssh', host_id_hash) AS signature_key,
            'saved_host_without_ready_ssh' AS issue_kind,
            'blocked' AS issue_severity,
            'A host was saved, but no ready SSH session was observed afterward.' AS summary,
            saved_at_epoch_seconds AS first_seen_at_epoch_seconds,
            saved_at_epoch_seconds AS last_seen_at_epoch_seconds,
            1 AS occurrence_count
        FROM saved_host_without_ready_ssh;

        CREATE VIEW analytics_user_host_setup_summary AS
        SELECT
            user_key_hash,
            MIN(CASE
                WHEN event_type = 'host_setup_flow_event'
                 AND json_extract(payload_json, '$.flow.stage') IN ('attempt_started', 'started')
                THEN occurred_at_epoch_seconds
            END) AS first_host_setup_started_at_epoch_seconds,
            MIN(CASE
                WHEN event_type = 'host_setup_flow_event'
                 AND json_extract(payload_json, '$.flow.stage') IN (
                    'save_succeeded',
                    'save_succeeded_unreachable',
                    'save_succeeded_unverified'
                 )
                THEN occurred_at_epoch_seconds
            END) AS first_host_setup_completed_at_epoch_seconds,
            SUM(CASE
                WHEN event_type = 'host_setup_flow_event'
                 AND json_extract(payload_json, '$.flow.stage') IN ('attempt_started', 'started')
                THEN 1 ELSE 0
            END) AS host_setup_started_count,
            SUM(CASE
                WHEN event_type = 'host_setup_flow_event'
                 AND json_extract(payload_json, '$.flow.stage') = 'pairing_completed'
                THEN 1 ELSE 0
            END) AS host_setup_pairing_completed_count,
            SUM(CASE
                WHEN event_type = 'host_setup_flow_event'
                 AND json_extract(payload_json, '$.flow.stage') IN (
                    'save_succeeded',
                    'save_succeeded_unreachable',
                    'save_succeeded_unverified'
                 )
                THEN 1 ELSE 0
            END) AS host_setup_completed_count,
            SUM(CASE
                WHEN event_type = 'host_setup_flow_event'
                 AND json_extract(payload_json, '$.flow.stage') IN ('failed', 'verification_failed')
                THEN 1 ELSE 0
            END) AS host_setup_failed_count
        FROM analytics_events
        GROUP BY user_key_hash;

        CREATE VIEW analytics_blocked_user_candidates AS
        SELECT
            user_key_hash,
            signature_key,
            issue_kind,
            issue_severity,
            summary,
            first_seen_at_epoch_seconds,
            last_seen_at_epoch_seconds,
            occurrence_count
        FROM analytics_host_setup_issue_signatures
        UNION ALL
        SELECT
            user_key_hash,
            printf('ssh:%s:%s:%s', failure_stage, disconnect_category, auth_mode) AS signature_key,
            'repeated_pre_ready_ssh_failure' AS issue_kind,
            'blocked' AS issue_severity,
            printf(
                'Pre-ready SSH failed %d times at stage %s using %s auth.',
                failure_count,
                failure_stage,
                auth_mode
            ) AS summary,
            first_seen_at_epoch_seconds,
            last_seen_at_epoch_seconds,
            failure_count AS occurrence_count
        FROM analytics_ssh_failure_summary
        WHERE failure_count >= 2
        UNION ALL
        SELECT
            user_key_hash,
            printf('key_material:%s', failure_reason) AS signature_key,
            CASE
                WHEN failure_reason = 'rsa_unsupported'
                THEN 'rsa_key_below_minimum_size'
                ELSE 'repeated_key_material_failure'
            END AS issue_kind,
            CASE
                WHEN failure_reason = 'rsa_unsupported' THEN 'blocked'
                WHEN failure_count >= 2 THEN 'blocked'
                ELSE 'warning'
            END AS issue_severity,
            CASE
                WHEN failure_reason = 'rsa_unsupported'
                THEN 'A user attempted to import an RSA private key below AgenTTY''s 2048-bit minimum. Larger RSA keys import normally.'
                ELSE printf(
                    'Key import or generation failed %d times (%s).',
                    failure_count,
                    failure_reason
                )
            END AS summary,
            first_seen_at_epoch_seconds,
            last_seen_at_epoch_seconds,
            failure_count AS occurrence_count
        FROM analytics_key_import_issue_summary;

        CREATE VIEW analytics_alert_digest_queue AS
        SELECT
            date(last_seen_at_epoch_seconds, 'unixepoch') AS digest_date,
            issue_kind,
            issue_severity,
            COUNT(DISTINCT user_key_hash) AS affected_user_count,
            SUM(occurrence_count) AS total_occurrence_count,
            MIN(first_seen_at_epoch_seconds) AS first_seen_at_epoch_seconds,
            MAX(last_seen_at_epoch_seconds) AS last_seen_at_epoch_seconds
        FROM analytics_blocked_user_candidates
        GROUP BY digest_date, issue_kind, issue_severity;

        CREATE VIEW analytics_recent_issue_alerts AS
        SELECT
            signature_key,
            user_key_hash,
            issue_kind,
            issue_severity,
            summary,
            first_seen_at_epoch_seconds,
            last_seen_at_epoch_seconds,
            first_alerted_at_epoch_seconds,
            last_alerted_at_epoch_seconds,
            alert_count
        FROM analytics_issue_alerts
        WHERE last_alerted_at_epoch_seconds IS NOT NULL
        ORDER BY last_alerted_at_epoch_seconds DESC, signature_key ASC;

        CREATE VIEW analytics_recent_ingest_failures AS
        SELECT
            failure_id,
            received_at_epoch_seconds,
            device_id,
            user_key_hash,
            bundle_id,
            app_transaction_environment,
            app_version,
            build_number,
            flavor,
            platform,
            error,
            event_count,
            event_diagnostics,
            failed_event_id,
            failed_event_type,
            validation_field,
            validation_rule,
            payload_version,
            redacted_payload_shape_json
        FROM analytics_ingest_failures
        ORDER BY received_at_epoch_seconds DESC, failure_id DESC;

        CREATE VIEW analytics_ingest_failure_summary AS
        SELECT
            error,
            COALESCE(failed_event_id, 'unknown') AS failed_event_id,
            COALESCE(failed_event_type, 'unknown') AS failed_event_type,
            COALESCE(validation_field, 'unknown') AS validation_field,
            COALESCE(validation_rule, 'unknown') AS validation_rule,
            COALESCE(CAST(payload_version AS TEXT), 'unknown') AS payload_version,
            COALESCE(redacted_payload_shape_json, 'unknown') AS redacted_payload_shape_json,
            COALESCE(bundle_id, 'unknown') AS bundle_id,
            COALESCE(app_transaction_environment, 'unknown') AS app_transaction_environment,
            COALESCE(app_version, 'unknown') AS app_version,
            COALESCE(build_number, 'unknown') AS build_number,
            COUNT(*) AS failure_count,
            COUNT(DISTINCT user_key_hash) AS affected_user_count,
            SUM(event_count) AS total_rejected_events,
            MIN(received_at_epoch_seconds) AS first_seen_at_epoch_seconds,
            MAX(received_at_epoch_seconds) AS last_seen_at_epoch_seconds
        FROM analytics_ingest_failures
        GROUP BY
            error,
            COALESCE(failed_event_id, 'unknown'),
            COALESCE(failed_event_type, 'unknown'),
            COALESCE(validation_field, 'unknown'),
            COALESCE(validation_rule, 'unknown'),
            COALESCE(CAST(payload_version AS TEXT), 'unknown'),
            COALESCE(redacted_payload_shape_json, 'unknown'),
            COALESCE(bundle_id, 'unknown'),
            COALESCE(app_transaction_environment, 'unknown'),
            COALESCE(app_version, 'unknown'),
            COALESCE(build_number, 'unknown');

        CREATE VIEW analytics_user_paywall_summary AS
        SELECT
            user_key_hash,
            SUM(CASE
                WHEN event_type = 'paywall_event'
                 AND json_extract(payload_json, '$.stage') = 'shown'
                THEN 1 ELSE 0
            END) AS paywall_shown_count,
            SUM(CASE
                WHEN event_type = 'paywall_event'
                 AND json_extract(payload_json, '$.stage') = 'purchase_tapped'
                THEN 1 ELSE 0
            END) AS purchase_tap_count,
            SUM(CASE
                WHEN event_type = 'paywall_event'
                 AND json_extract(payload_json, '$.stage') = 'restore_tapped'
                THEN 1 ELSE 0
            END) AS restore_tap_count,
            SUM(CASE
                WHEN event_type = 'paywall_event'
                 AND json_extract(payload_json, '$.stage') = 'retry_lookup_tapped'
                THEN 1 ELSE 0
            END) AS retry_lookup_tap_count
        FROM analytics_events
        GROUP BY user_key_hash;

        CREATE VIEW analytics_user_engagement_summary AS
        SELECT
            user_key_hash,
            SUM(CASE WHEN event_type = 'app_session_completed' THEN 1 ELSE 0 END) AS app_session_count,
            COALESCE(SUM(CASE
                WHEN event_type = 'app_session_completed'
                THEN json_extract(payload_json, '$.session.duration_seconds')
                ELSE 0
            END), 0) AS total_app_session_duration_seconds,
            SUM(CASE WHEN event_type = 'ssh_session_completed' THEN 1 ELSE 0 END) AS ssh_session_count,
            SUM(CASE
                WHEN event_type = 'ssh_session_completed'
                 AND json_extract(payload_json, '$.session.was_ready') = 1
                THEN 1 ELSE 0
            END) AS ready_ssh_session_count,
            COALESCE(SUM(CASE
                WHEN event_type = 'ssh_session_completed'
                THEN json_extract(payload_json, '$.session.duration_seconds')
                ELSE 0
            END), 0) AS total_ssh_session_duration_seconds,
            SUM(CASE
                WHEN event_type = 'ssh_session_completed'
                 AND COALESCE(json_extract(payload_json, '$.input.had_terminal_input'), 0) = 1
                THEN 1 ELSE 0
            END) AS terminal_input_ssh_session_count,
            COUNT(DISTINCT CASE
                WHEN event_type = 'ssh_session_completed'
                THEN COALESCE(
                    json_extract(payload_json, '$.host.id_hash'),
                    json_extract(payload_json, '$.host.key_hash')
                )
            END) AS distinct_hosts_used,
            COUNT(DISTINCT CASE
                WHEN event_type IN ('app_session_completed', 'ssh_session_completed')
                THEN date(occurred_at_epoch_seconds, 'unixepoch')
            END) AS days_active
        FROM analytics_events
        GROUP BY user_key_hash;

        CREATE VIEW analytics_onboarding_funnel AS
        SELECT
            COUNT(*) AS total_users,
            SUM(CASE WHEN COALESCE(h.host_setup_started_count, 0) > 0 THEN 1 ELSE 0 END) AS users_started_host_setup,
            SUM(CASE WHEN h.first_host_setup_completed_at_epoch_seconds IS NOT NULL THEN 1 ELSE 0 END) AS users_completed_host_setup,
            SUM(CASE WHEN s.first_successful_ssh_at_epoch_seconds IS NOT NULL THEN 1 ELSE 0 END) AS users_with_successful_ssh,
            SUM(CASE WHEN t.first_terminal_input_at_epoch_seconds IS NOT NULL THEN 1 ELSE 0 END) AS users_with_terminal_input
        FROM analytics_users u
        LEFT JOIN analytics_user_host_setup_summary h USING (user_key_hash)
        LEFT JOIN analytics_first_successful_ssh s USING (user_key_hash)
        LEFT JOIN analytics_first_terminal_input t USING (user_key_hash);

        CREATE VIEW analytics_paywall_summary AS
        SELECT
            COUNT(*) AS total_users,
            SUM(CASE WHEN COALESCE(p.paywall_shown_count, 0) > 0 THEN 1 ELSE 0 END) AS users_shown_paywall,
            COALESCE(SUM(p.paywall_shown_count), 0) AS paywall_show_events,
            COALESCE(SUM(p.purchase_tap_count), 0) AS purchase_tap_events,
            COALESCE(SUM(p.restore_tap_count), 0) AS restore_tap_events,
            COALESCE(SUM(p.retry_lookup_tap_count), 0) AS retry_lookup_tap_events,
            SUM(CASE WHEN u.last_has_lifetime_access = 1 THEN 1 ELSE 0 END) AS paid_users
        FROM analytics_users u
        LEFT JOIN analytics_user_paywall_summary p USING (user_key_hash);

        CREATE VIEW analytics_retention_summary AS
        SELECT
            COUNT(*) AS total_users,
            SUM(CASE WHEN COALESCE(e.days_active, 0) >= 2 THEN 1 ELSE 0 END) AS users_active_multiple_days,
            SUM(CASE
                WHEN s.first_successful_ssh_at_epoch_seconds IS NOT NULL
                 AND COALESCE(e.days_active, 0) >= 2
                THEN 1 ELSE 0
            END) AS users_with_successful_ssh_and_returned
        FROM analytics_users u
        LEFT JOIN analytics_user_engagement_summary e USING (user_key_hash)
        LEFT JOIN analytics_first_successful_ssh s USING (user_key_hash);

        CREATE VIEW analytics_current_user_summary AS
        SELECT
            u.user_key_hash,
            u.first_seen_at_epoch_seconds,
            u.last_seen_at_epoch_seconds,
            u.original_purchase_date_epoch_seconds,
            u.last_bundle_id,
            u.last_app_transaction_environment,
            u.last_app_version,
            u.last_build_number,
            u.last_flavor,
            u.last_platform,
            u.last_has_lifetime_access,
            u.last_trial_expired,
            u.last_trial_consumed_usage_seconds,
            u.last_trial_remaining_usage_seconds,
            COALESCE(i.install_count, 0) AS install_count,
            l.device_id AS latest_device_id,
            l.last_system_version,
            l.last_device_model_identifier,
            l.last_device_family,
            l.last_locale_identifier,
            l.last_preferred_languages_json,
            l.last_saved_host_count,
            s.first_successful_ssh_at_epoch_seconds,
            t.first_terminal_input_at_epoch_seconds,
            COALESCE(h.host_setup_started_count, 0) AS host_setup_started_count,
            COALESCE(h.host_setup_pairing_completed_count, 0) AS host_setup_pairing_completed_count,
            COALESCE(h.host_setup_completed_count, 0) AS host_setup_completed_count,
            COALESCE(h.host_setup_failed_count, 0) AS host_setup_failed_count,
            h.first_host_setup_started_at_epoch_seconds,
            h.first_host_setup_completed_at_epoch_seconds,
            COALESCE(p.paywall_shown_count, 0) AS paywall_shown_count,
            COALESCE(p.purchase_tap_count, 0) AS paywall_purchase_tap_count,
            COALESCE(p.restore_tap_count, 0) AS paywall_restore_tap_count,
            COALESCE(p.retry_lookup_tap_count, 0) AS paywall_retry_lookup_tap_count,
            COALESCE(e.app_session_count, 0) AS app_session_count,
            COALESCE(e.total_app_session_duration_seconds, 0) AS total_app_session_duration_seconds,
            COALESCE(e.ssh_session_count, 0) AS ssh_session_count,
            COALESCE(e.ready_ssh_session_count, 0) AS ready_ssh_session_count,
            COALESCE(e.total_ssh_session_duration_seconds, 0) AS total_ssh_session_duration_seconds,
            COALESCE(e.terminal_input_ssh_session_count, 0) AS terminal_input_ssh_session_count,
            COALESCE(e.distinct_hosts_used, 0) AS distinct_hosts_used,
            COALESCE(e.days_active, 0) AS days_active
        FROM analytics_users u
        LEFT JOIN analytics_installs_per_user i USING (user_key_hash)
        LEFT JOIN analytics_latest_device_user_link l USING (user_key_hash)
        LEFT JOIN analytics_first_successful_ssh s USING (user_key_hash)
        LEFT JOIN analytics_first_terminal_input t USING (user_key_hash)
        LEFT JOIN analytics_user_host_setup_summary h USING (user_key_hash)
        LEFT JOIN analytics_user_paywall_summary p USING (user_key_hash)
        LEFT JOIN analytics_user_engagement_summary e USING (user_key_hash);

        CREATE VIEW analytics_paid_conversion_summary AS
        SELECT
            COUNT(*) AS total_users,
            SUM(CASE WHEN last_has_lifetime_access = 1 THEN 1 ELSE 0 END) AS paid_users,
            SUM(CASE WHEN first_successful_ssh_at_epoch_seconds IS NOT NULL THEN 1 ELSE 0 END) AS users_with_successful_ssh,
            SUM(CASE WHEN paywall_shown_count > 0 THEN 1 ELSE 0 END) AS users_shown_paywall
        FROM analytics_current_user_summary;
        "#,
    )?;

    Ok(())
}

fn ensure_table_has_columns(
    connection: &rusqlite::Connection,
    table: &str,
    columns: &[(&str, &str)],
) -> rusqlite::Result<()> {
    let pragma = format!("PRAGMA table_info({table})");
    let mut statement = connection.prepare(&pragma)?;
    let existing_columns = statement.query_map([], |row| row.get::<_, String>(1))?;
    let existing_columns = existing_columns.collect::<rusqlite::Result<Vec<_>>>()?;

    for (name, definition) in columns {
        if existing_columns.iter().any(|column| column == name) {
            continue;
        }

        let alter = format!("ALTER TABLE {table} ADD COLUMN {name} {definition}");
        connection.execute(&alter, [])?;
    }

    Ok(())
}

fn invalid_data_error(message: impl Into<String>) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(io::Error::new(
        io::ErrorKind::InvalidData,
        message.into(),
    )))
}

fn normalize_legacy_device_ids(connection: &mut rusqlite::Connection) -> rusqlite::Result<()> {
    let duplicate_device_id: Option<String> = connection
        .query_row(
            r#"
            SELECT lower(device_id)
            FROM devices
            GROUP BY lower(device_id)
            HAVING COUNT(*) > 1
            LIMIT 1
            "#,
            [],
            |row| row.get(0),
        )
        .optional()?;

    if let Some(device_id) = duplicate_device_id {
        return Err(invalid_data_error(format!(
            "multiple device rows collapse to the same canonical id: {device_id}"
        )));
    }

    let duplicate_dictation_key: Option<String> = connection
        .query_row(
            r#"
            SELECT printf('%s@%lld', lower(device_id), week_start_epoch_seconds)
            FROM dictation_usage_weekly
            GROUP BY lower(device_id), week_start_epoch_seconds
            HAVING COUNT(*) > 1
            LIMIT 1
            "#,
            [],
            |row| row.get(0),
        )
        .optional()?;

    if let Some(canonical_key) = duplicate_dictation_key {
        return Err(invalid_data_error(format!(
            "multiple dictation usage rows collapse to the same canonical key: {canonical_key}"
        )));
    }

    let duplicate_analytics_link_key: Option<String> = connection
        .query_row(
            r#"
            SELECT printf('%s@%s', lower(device_id), user_key_hash)
            FROM analytics_device_user_links
            GROUP BY lower(device_id), user_key_hash
            HAVING COUNT(*) > 1
            LIMIT 1
            "#,
            [],
            |row| row.get(0),
        )
        .optional()?;

    if let Some(canonical_key) = duplicate_analytics_link_key {
        return Err(invalid_data_error(format!(
            "multiple analytics device-user links collapse to the same canonical key: {canonical_key}"
        )));
    }

    let needs_normalization: bool = connection.query_row(
        r#"
        SELECT EXISTS (
            SELECT 1 FROM devices WHERE device_id != lower(device_id)
            UNION ALL
            SELECT 1 FROM relay_sessions WHERE device_id != lower(device_id)
            UNION ALL
            SELECT 1 FROM pairing_sessions WHERE device_id IS NOT NULL AND device_id != lower(device_id)
            UNION ALL
            SELECT 1 FROM dictation_usage_weekly WHERE device_id != lower(device_id)
            UNION ALL
            SELECT 1 FROM analytics_device_user_links WHERE device_id != lower(device_id)
            UNION ALL
            SELECT 1 FROM analytics_events WHERE device_id != lower(device_id)
        )
        "#,
        [],
        |row| row.get(0),
    )?;

    if !needs_normalization {
        return ensure_foreign_key_integrity(connection);
    }

    let foreign_keys_enabled: i64 =
        connection.query_row("PRAGMA foreign_keys", [], |row| row.get(0))?;
    if foreign_keys_enabled == 1 {
        connection.execute_batch("PRAGMA foreign_keys = OFF;")?;
    }

    let result = (|| -> rusqlite::Result<()> {
        let tx = connection.transaction()?;

        for statement in LEGACY_DEVICE_ID_NORMALIZATION_STATEMENTS {
            tx.execute(statement, [])?;
        }

        tx.commit()
    })();

    if foreign_keys_enabled == 1 {
        connection.execute_batch("PRAGMA foreign_keys = ON;")?;
    }

    result?;
    ensure_foreign_key_integrity(connection)
}

fn ensure_foreign_key_integrity(connection: &rusqlite::Connection) -> rusqlite::Result<()> {
    let violation: Option<(String, Option<i64>, String)> = connection
        .query_row("PRAGMA foreign_key_check", [], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        })
        .optional()?;

    if let Some((table, rowid, parent)) = violation {
        let rowid = rowid
            .map(|value| value.to_string())
            .unwrap_or_else(|| "unknown".to_owned());
        return Err(invalid_data_error(format!(
            "foreign key violation in {table} rowid {rowid} referencing {parent}"
        )));
    }

    Ok(())
}

fn latest_access_state_from_events(
    events: &[AnalyticsEventRecord],
) -> Option<(i64, AnalyticsAccessStatePayload)> {
    events
        .iter()
        .filter_map(|event| {
            event
                .access_state
                .clone()
                .map(|payload| (event.occurred_at_epoch_seconds, payload))
        })
        .max_by_key(|(occurred_at_epoch_seconds, _)| *occurred_at_epoch_seconds)
}

fn latest_saved_host_count_from_events(events: &[AnalyticsEventRecord]) -> Option<i64> {
    events
        .iter()
        .filter_map(|event| {
            event
                .saved_host_count
                .map(|saved_host_count| (event.occurred_at_epoch_seconds, saved_host_count))
        })
        .max_by_key(|(occurred_at_epoch_seconds, _)| *occurred_at_epoch_seconds)
        .map(|(_, saved_host_count)| saved_host_count)
}

fn pairing_sessions_schema_is_current(connection: &rusqlite::Connection) -> rusqlite::Result<bool> {
    let mut statement = connection.prepare("PRAGMA table_info(pairing_sessions)")?;
    let columns = statement.query_map([], |row| row.get::<_, String>(1))?;
    let column_names = columns.collect::<rusqlite::Result<Vec<_>>>()?;

    if column_names.is_empty() {
        return Ok(false);
    }

    Ok(column_names
        .iter()
        .any(|column| column == "host_token_hash"))
}

#[cfg(test)]
mod retention_tests {
    use super::*;

    #[test]
    fn diagnostic_retention_bounds_both_age_and_row_count() {
        let connection = rusqlite::Connection::open_in_memory().unwrap();
        ensure_analytics_schema(&connection).unwrap();
        let now = 2_000_000_i64;
        connection.execute("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10005) INSERT INTO analytics_ingest_failures(received_at_epoch_seconds, device_id, error, event_count, event_diagnostics) SELECT ?, 'authenticated-device', 'invalid', 1, '' FROM n", params![now]).unwrap();
        connection.execute("INSERT INTO analytics_ingest_failures(received_at_epoch_seconds, device_id, error, event_count, event_diagnostics) VALUES (?, 'authenticated-device', 'expired', 1, '')", params![now - 14 * 86400 - 1]).unwrap();
        prune_ingest_failures(&connection, now).unwrap();
        let (count, oldest): (i64, i64) = connection
            .query_row(
                "SELECT COUNT(*), MIN(received_at_epoch_seconds) FROM analytics_ingest_failures",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(count, 10_000);
        assert_eq!(oldest, now);
    }
}
