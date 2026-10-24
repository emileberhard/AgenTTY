use std::env;
use std::path::PathBuf;

use anyhow::{Result, bail};

use crate::models::PushType;

// Remove these legacy aliases after the renamed backend deployment and iOS build are broadly
// distributed; they only exist to keep the live App Store rollout on the existing backend state.
const LEGACY_DATABASE_PATH_DEFAULT: &str = "~/.agentty/notify-relay.sqlite3";
const BACKEND_DATABASE_PATH_DEFAULT: &str = "~/.agentty/backend.sqlite3";

#[derive(Debug, Clone)]
pub struct Settings {
    pub database_path: PathBuf,
    pub control_socket_path: PathBuf,
    pub apns_key_path: PathBuf,
    pub apns_key_id: String,
    pub apns_team_id: String,
    pub openai_base_url: String,
    pub openai_api_key: String,
    pub public_base_url: String,
    pub internal_clients: Vec<InternalClientSettings>,
    pub analytics_alerts: AnalyticsAlertSettings,
    pub dictation_limits: DictationLimits,
}

#[derive(Debug, Clone)]
pub struct DictationLimits {
    pub app_apple_id: u64,
    pub weekly_seconds: i64,
    pub daily_seconds: i64,
    pub legacy_weekly_seconds: i64,
    pub require_verified_devices: bool,
    pub require_host_adoption_proof: bool,
    pub relay_legacy_daily_bytes: i64,
    pub concurrency: usize,
    pub trusted_devices: Vec<(String, String)>,
    pub relay_daily_bytes: i64,
    pub relay_device_daily_bytes: i64,
}

impl Default for DictationLimits {
    fn default() -> Self {
        Self {
            app_apple_id: 0,
            weekly_seconds: 14_400,
            daily_seconds: 3_600,
            legacy_weekly_seconds: 3_600,
            require_verified_devices: false,
            require_host_adoption_proof: false,
            relay_legacy_daily_bytes: 128 * 1024 * 1024,
            concurrency: 2,
            trusted_devices: Vec::new(),
            relay_daily_bytes: 1024 * 1024 * 1024,
            relay_device_daily_bytes: 128 * 1024 * 1024,
        }
    }
}

#[derive(Debug, Clone)]
pub struct AnalyticsAlertSettings {
    pub destination_device_id: Option<String>,
    pub cooldown_seconds: i64,
    pub internal_device_ids: Vec<String>,
    pub internal_user_key_hashes: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InternalCaller {
    RemoteCoder,
    PingBooks,
}

#[derive(Debug, Clone, Copy)]
pub struct InternalCallerSpec {
    pub env_key: &'static str,
    pub legacy_env_key: Option<&'static str>,
    pub name: &'static str,
    pub allowed_push_types: &'static [PushType],
    pub allowed_topics: &'static [&'static str],
}

impl InternalCaller {
    pub fn all() -> [Self; 2] {
        [Self::RemoteCoder, Self::PingBooks]
    }

    pub fn spec(self) -> InternalCallerSpec {
        match self {
            Self::RemoteCoder => InternalCallerSpec {
                env_key: "AGENTTY_BACKEND_REMOTECODER_TOKEN",
                legacy_env_key: Some("AGENTTY_NOTIFY_RELAY_REMOTECODER_TOKEN"),
                name: "remotecoder",
                allowed_push_types: &[
                    PushType::Alert,
                    PushType::LiveActivity,
                    PushType::Location,
                    PushType::Voip,
                ],
                allowed_topics: &["emileberhard.RemoteCoder"],
            },
            Self::PingBooks => InternalCallerSpec {
                env_key: "AGENTTY_BACKEND_PINGBOOKS_TOKEN",
                legacy_env_key: Some("AGENTTY_NOTIFY_RELAY_PINGBOOKS_TOKEN"),
                name: "pingbooks",
                allowed_push_types: &[PushType::Alert],
                allowed_topics: &["emileberhard.PingBooks"],
            },
        }
    }

    pub fn as_str(self) -> &'static str {
        self.spec().name
    }

    pub fn allows_push_type(self, push_type: PushType) -> bool {
        self.spec().allowed_push_types.contains(&push_type)
    }

    pub fn allows_topic(self, topic: &str) -> bool {
        self.spec().allowed_topics.contains(&topic)
    }
}

#[derive(Debug, Clone)]
pub struct InternalClientSettings {
    pub caller: InternalCaller,
    pub token: String,
}

impl Settings {
    pub fn from_env() -> Result<Self> {
        let database_path = if let Some(path) = optional_env_string_aliases(&[
            "AGENTTY_BACKEND_DATABASE_PATH",
            "AGENTTY_NOTIFY_RELAY_DATABASE_PATH",
        ]) {
            PathBuf::from(path).expand_home()?
        } else {
            default_database_path()?
        };

        let control_socket_path = PathBuf::from(
            optional_env_string("AGENTTY_BACKEND_CONTROL_SOCKET_PATH")
                .unwrap_or_else(|| "~/.agentty/backend-control/socket".to_owned()),
        )
        .expand_home()?;

        let apns_key_path = required_env_path_aliases(&[
            "AGENTTY_BACKEND_APNS_KEY_PATH",
            "AGENTTY_NOTIFY_RELAY_APNS_KEY_PATH",
        ])?;
        let apns_key_id = required_env_string_aliases(&[
            "AGENTTY_BACKEND_APNS_KEY_ID",
            "AGENTTY_NOTIFY_RELAY_APNS_KEY_ID",
        ])?;
        let apns_team_id = required_env_string_aliases(&[
            "AGENTTY_BACKEND_APNS_TEAM_ID",
            "AGENTTY_NOTIFY_RELAY_APNS_TEAM_ID",
        ])?;
        let openai_base_url = normalize_http_base_url(
            "AGENTTY_BACKEND_OPENAI_BASE_URL",
            &required_env_string_aliases(&["AGENTTY_BACKEND_OPENAI_BASE_URL"])?,
        )?;
        let openai_api_key = required_env_string_aliases(&["AGENTTY_BACKEND_OPENAI_API_KEY"])?;
        let public_base_url = optional_env_string_aliases(&[
            "AGENTTY_BACKEND_PUBLIC_BASE_URL",
            "AGENTTY_NOTIFY_RELAY_PUBLIC_BASE_URL",
        ])
        .unwrap_or_else(|| "https://agentty.esmadil.se".to_owned());
        let internal_clients: Vec<InternalClientSettings> = InternalCaller::all()
            .into_iter()
            .filter_map(|caller| {
                let spec = caller.spec();
                optional_env_string(spec.env_key)
                    .or_else(|| spec.legacy_env_key.and_then(optional_env_string))
                    .map(|token| InternalClientSettings { caller, token })
            })
            .collect();
        for client in &internal_clients {
            if client.token.len() < 32
                || client
                    .token
                    .bytes()
                    .collect::<std::collections::HashSet<_>>()
                    .len()
                    < 8
            {
                bail!(
                    "{} internal bearer token must be at least 32 characters",
                    client.caller.as_str()
                );
            }
        }
        let analytics_alerts = AnalyticsAlertSettings {
            destination_device_id: optional_env_string_aliases(&[
                "AGENTTY_BACKEND_ANALYTICS_ALERT_DEVICE_ID",
                "AGENTTY_NOTIFY_RELAY_ANALYTICS_ALERT_DEVICE_ID",
            ])
            .map(|value| value.to_ascii_lowercase()),
            cooldown_seconds: optional_env_string_aliases(&[
                "AGENTTY_BACKEND_ANALYTICS_ALERT_COOLDOWN_SECONDS",
                "AGENTTY_NOTIFY_RELAY_ANALYTICS_ALERT_COOLDOWN_SECONDS",
            ])
            .and_then(|value| value.parse::<i64>().ok())
            .filter(|value| *value > 0)
            .unwrap_or(6 * 60 * 60),
            internal_device_ids: optional_csv_aliases(&[
                "AGENTTY_BACKEND_INTERNAL_ANALYTICS_DEVICE_IDS",
                "AGENTTY_NOTIFY_RELAY_INTERNAL_ANALYTICS_DEVICE_IDS",
            ])
            .into_iter()
            .map(|value| value.to_ascii_lowercase())
            .collect(),
            internal_user_key_hashes: optional_csv_aliases(&[
                "AGENTTY_BACKEND_INTERNAL_ANALYTICS_USER_KEY_HASHES",
                "AGENTTY_NOTIFY_RELAY_INTERNAL_ANALYTICS_USER_KEY_HASHES",
            ]),
        };

        let defaults = DictationLimits::default();
        let trusted_devices = optional_csv_aliases(&["AGENTTY_BACKEND_TRUSTED_DEVICE_CREDENTIALS"])
            .into_iter()
            .map(|entry| {
                let (id, hash) = entry.split_once(':').ok_or_else(|| {
                    anyhow::anyhow!("trusted devices require device_id:sha256(device_secret)")
                })?;
                if id.is_empty()
                    || hash.len() != 64
                    || !hash.bytes().all(|byte| byte.is_ascii_hexdigit())
                {
                    bail!("invalid trusted device credential entry");
                }
                Ok((id.to_ascii_lowercase(), hash.to_ascii_lowercase()))
            })
            .collect::<Result<Vec<_>>>()?;
        let dictation_limits = DictationLimits {
            require_host_adoption_proof: env_number(
                "AGENTTY_BACKEND_REQUIRE_HOST_ADOPTION_PROOF",
                false,
            )?,
            trusted_devices,
            relay_daily_bytes: env_number(
                "AGENTTY_BACKEND_RELAY_DAILY_BYTES",
                defaults.relay_daily_bytes,
            )?,
            relay_device_daily_bytes: env_number(
                "AGENTTY_BACKEND_RELAY_DEVICE_DAILY_BYTES",
                defaults.relay_device_daily_bytes,
            )?,
            app_apple_id: env_number("AGENTTY_BACKEND_APP_APPLE_ID", defaults.app_apple_id)?,
            daily_seconds: env_number(
                "AGENTTY_BACKEND_DICTATION_DAILY_SECONDS",
                defaults.daily_seconds,
            )?,
            weekly_seconds: env_number(
                "AGENTTY_BACKEND_DICTATION_WEEKLY_SECONDS",
                defaults.weekly_seconds,
            )?,
            legacy_weekly_seconds: env_number(
                "AGENTTY_BACKEND_DICTATION_LEGACY_WEEKLY_SECONDS",
                defaults.legacy_weekly_seconds,
            )?,
            require_verified_devices: env_number(
                "AGENTTY_BACKEND_REQUIRE_VERIFIED_DEVICES",
                false,
            )?,
            relay_legacy_daily_bytes: env_number(
                "AGENTTY_BACKEND_RELAY_LEGACY_DAILY_BYTES",
                defaults.relay_legacy_daily_bytes,
            )?,
            concurrency: env_number(
                "AGENTTY_BACKEND_DICTATION_CONCURRENCY",
                defaults.concurrency,
            )?,
        };
        if dictation_limits.daily_seconds <= 0
            || dictation_limits.weekly_seconds <= 0
            || dictation_limits.legacy_weekly_seconds < 0
            || !(1..=8).contains(&dictation_limits.concurrency)
            || dictation_limits.relay_legacy_daily_bytes <= 0
            || dictation_limits.relay_daily_bytes <= 0
            || dictation_limits.relay_device_daily_bytes <= 0
            || dictation_limits.trusted_devices.len() > 128
        {
            bail!("invalid dictation limits");
        }
        Ok(Self {
            dictation_limits,
            database_path,
            control_socket_path,
            apns_key_path,
            apns_key_id,
            apns_team_id,
            openai_base_url,
            openai_api_key,
            public_base_url,
            internal_clients,
            analytics_alerts,
        })
    }
}

fn default_database_path() -> Result<PathBuf> {
    // Prefer the existing live database during the first renamed deployment so analytics,
    // device registrations, and pairing state survive the service rename unchanged.
    let legacy_path = PathBuf::from(LEGACY_DATABASE_PATH_DEFAULT).expand_home()?;
    if legacy_path.exists() {
        return Ok(legacy_path);
    }

    PathBuf::from(BACKEND_DATABASE_PATH_DEFAULT).expand_home()
}

fn required_env_string_aliases(keys: &[&str]) -> Result<String> {
    if let Some(value) = optional_env_string_aliases(keys) {
        return Ok(value);
    }
    bail!("{} is required", keys[0]);
}

fn normalize_http_base_url(key: &str, value: &str) -> Result<String> {
    let trimmed = value.trim_end_matches('/');
    if trimmed.starts_with("https://") || trimmed.starts_with("http://") {
        return Ok(trimmed.to_owned());
    }
    bail!("{key} must start with http:// or https://");
}

fn required_env_path_aliases(keys: &[&str]) -> Result<PathBuf> {
    let value = required_env_string_aliases(keys)?;
    PathBuf::from(value).expand_home()
}

fn optional_env_string_aliases(keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| optional_env_string(key))
}

fn optional_csv_aliases(keys: &[&str]) -> Vec<String> {
    optional_env_string_aliases(keys)
        .map(|value| {
            value
                .split(',')
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

fn optional_env_string(key: &str) -> Option<String> {
    env::var(key)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

trait ExpandHome {
    fn expand_home(self) -> Result<PathBuf>;
}

impl ExpandHome for PathBuf {
    fn expand_home(self) -> Result<PathBuf> {
        let Some(path) = self.to_str() else {
            return Ok(self);
        };

        if path == "~" || path.starts_with("~/") {
            let home = env::var("HOME").map_err(|_| anyhow::anyhow!("HOME is required"))?;
            let trimmed = path.trim_start_matches('~');
            return Ok(PathBuf::from(home).join(trimmed.trim_start_matches('/')));
        }

        Ok(self)
    }
}

fn env_number<T: std::str::FromStr>(key: &str, default: T) -> Result<T> {
    match optional_env_string(key) {
        Some(value) => value
            .parse()
            .map_err(|_| anyhow::anyhow!("{key} must be a valid number")),
        None => Ok(default),
    }
}
