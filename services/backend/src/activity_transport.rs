use base64::Engine;
use reqwest::{Method, StatusCode};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Map, Value, json};

use crate::apns::build_alert_object;
use crate::models::{InternalLiveActivityAlert, NonEmptyString, PushEnvironment};

const MAX_CHANNEL_ID_BYTES: usize = 1024;
const MAX_DEVICE_TOKEN_BYTES: usize = 2048;
const MAX_ACTIVITY_DATA_BYTES: usize = 4096;

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(try_from = "u8")]
pub enum ActivityPriority {
    Normal,
    Immediate,
}

impl TryFrom<u8> for ActivityPriority {
    type Error = &'static str;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            5 => Ok(Self::Normal),
            10 => Ok(Self::Immediate),
            _ => Err("priority must be 5 or 10"),
        }
    }
}

impl ActivityPriority {
    pub fn header_value(self) -> &'static str {
        match self {
            Self::Normal => "5",
            Self::Immediate => "10",
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum ActivityTarget {
    Device { device_token: NonEmptyString },
    Channel { channel_id: NonEmptyString },
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum ActivityUpdateRoute {
    Token {},
    Channel { channel_id: NonEmptyString },
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "event", rename_all = "lowercase", deny_unknown_fields)]
pub enum ActivityMessage {
    Start {
        device_token: NonEmptyString,
        timestamp: i64,
        content_state: Value,
        stale_date: Option<i64>,
        attributes_type: NonEmptyString,
        attributes: Map<String, Value>,
        alert: InternalLiveActivityAlert,
        update_route: ActivityUpdateRoute,
    },
    Update {
        target: ActivityTarget,
        timestamp: i64,
        content_state: Value,
        stale_date: Option<i64>,
        alert: Option<InternalLiveActivityAlert>,
    },
    End {
        target: ActivityTarget,
        timestamp: i64,
        content_state: Value,
        stale_date: Option<i64>,
        alert: Option<InternalLiveActivityAlert>,
        dismissal_date: Option<i64>,
    },
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ActivityDispatchRequest {
    pub bundle_id: NonEmptyString,
    pub push_environment: PushEnvironment,
    pub priority: ActivityPriority,
    pub expiration: i64,
    pub message: ActivityMessage,
}

#[derive(Debug, Clone, Copy)]
pub enum ChannelStoragePolicy {
    NoStorage,
    MostRecent,
}

impl<'de> Deserialize<'de> for ChannelStoragePolicy {
    fn deserialize<D: Deserializer<'de>>(decoder: D) -> Result<Self, D::Error> {
        match u8::deserialize(decoder)? {
            0 => Ok(Self::NoStorage),
            1 => Ok(Self::MostRecent),
            _ => Err(serde::de::Error::custom(
                "message_storage_policy must be 0 or 1",
            )),
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum ChannelOperation {
    Create {
        message_storage_policy: ChannelStoragePolicy,
    },
    Delete {
        channel_id: NonEmptyString,
    },
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ActivityChannelRequest {
    pub bundle_id: NonEmptyString,
    pub push_environment: PushEnvironment,
    pub operation: ChannelOperation,
}

#[derive(Debug, Clone)]
pub struct PreparedActivityRequest {
    pub method: Method,
    pub url: String,
    pub headers: Vec<(&'static str, String)>,
    pub body: Option<Vec<u8>>,
    pub expected_status: StatusCode,
    pub creates_channel: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ApnsFailureClass {
    Content,
    Authorization,
    Route,
    Throttled,
    Transient,
    Unknown,
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "outcome", rename_all = "snake_case")]
pub enum ActivityTransportResponse {
    Accepted {
        #[serde(skip_serializing_if = "Option::is_none")]
        apns_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        channel_id: Option<String>,
    },
    Rejected {
        apns_status: u16,
        #[serde(skip_serializing_if = "Option::is_none")]
        apns_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        apns_reason: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        retry_after_seconds: Option<u64>,
        failure_class: ApnsFailureClass,
    },
    Unknown {
        reason: &'static str,
    },
    NotSent {
        reason: &'static str,
        failure_class: ApnsFailureClass,
    },
}

impl ActivityTransportResponse {
    pub fn outcome_name(&self) -> &'static str {
        match self {
            Self::Accepted { .. } => "accepted",
            Self::Rejected { .. } => "rejected",
            Self::Unknown { .. } => "unknown",
            Self::NotSent { .. } => "not_sent",
        }
    }
}

impl ActivityDispatchRequest {
    pub fn prepare(&self) -> Result<PreparedActivityRequest, &'static str> {
        if self.expiration < 0 {
            return Err("expiration must be zero or positive Unix seconds");
        }
        let (event, timestamp, state, stale_date, alert) = match &self.message {
            ActivityMessage::Start {
                timestamp,
                content_state,
                stale_date,
                alert,
                ..
            } => ("start", *timestamp, content_state, *stale_date, Some(alert)),
            ActivityMessage::Update {
                timestamp,
                content_state,
                stale_date,
                alert,
                ..
            } => (
                "update",
                *timestamp,
                content_state,
                *stale_date,
                alert.as_ref(),
            ),
            ActivityMessage::End {
                timestamp,
                content_state,
                stale_date,
                alert,
                ..
            } => (
                "end",
                *timestamp,
                content_state,
                *stale_date,
                alert.as_ref(),
            ),
        };
        if timestamp <= 0 || stale_date.is_some_and(|value| value <= 0) {
            return Err("timestamp and stale_date must be positive Unix seconds");
        }
        if !state.is_object() {
            return Err("content_state must be a JSON object");
        }
        let state_bytes =
            serde_json::to_vec(state).map_err(|_| "could not encode content_state")?;
        if state_bytes.len() > MAX_ACTIVITY_DATA_BYTES {
            return Err("content_state exceeds the 4096-byte admission limit");
        }
        let mut aps = Map::from_iter([
            ("event".to_owned(), Value::from(event)),
            ("timestamp".to_owned(), Value::from(timestamp)),
            ("content-state".to_owned(), state.clone()),
        ]);
        if let Some(value) = stale_date {
            aps.insert("stale-date".to_owned(), Value::from(value));
        }
        if let Some(value) = alert {
            aps.insert(
                "alert".to_owned(),
                Value::Object(build_alert_object(
                    value.title.as_str(),
                    value.body.as_str(),
                    value.subtitle.as_ref().map(NonEmptyString::as_str),
                )),
            );
        }
        let mut headers = vec![
            ("apns-push-type", "liveactivity".to_owned()),
            ("apns-priority", self.priority.header_value().to_owned()),
            ("apns-expiration", self.expiration.to_string()),
        ];
        let target = match &self.message {
            ActivityMessage::Start {
                device_token,
                attributes_type,
                attributes,
                update_route,
                ..
            } => {
                validate_device_token(device_token.as_str())?;
                let type_name = attributes_type.as_str();
                if type_name.len() > 128
                    || !type_name
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.'))
                {
                    return Err("attributes_type must be a Swift type name of at most 128 bytes");
                }
                let attributes_bytes =
                    serde_json::to_vec(attributes).map_err(|_| "could not encode attributes")?;
                if state_bytes.len() + attributes_bytes.len() > MAX_ACTIVITY_DATA_BYTES {
                    return Err(
                        "content_state plus attributes exceeds the 4096-byte admission limit",
                    );
                }
                aps.insert("attributes-type".to_owned(), Value::from(type_name));
                aps.insert("attributes".to_owned(), Value::Object(attributes.clone()));
                match update_route {
                    ActivityUpdateRoute::Token {} => {
                        aps.insert("input-push-token".to_owned(), Value::from(1));
                    }
                    ActivityUpdateRoute::Channel { channel_id } => {
                        validate_channel_id(channel_id.as_str())?;
                        aps.insert(
                            "input-push-channel".to_owned(),
                            Value::from(channel_id.as_str()),
                        );
                    }
                }
                ActivityTarget::Device {
                    device_token: device_token.clone(),
                }
            }
            ActivityMessage::Update { target, .. } => target.clone(),
            ActivityMessage::End {
                target,
                dismissal_date,
                ..
            } => {
                if let Some(value) = dismissal_date {
                    if *value <= 0 {
                        return Err("dismissal_date must be positive Unix seconds");
                    }
                    aps.insert("dismissal-date".to_owned(), Value::from(*value));
                }
                target.clone()
            }
        };
        let (path, limit) = match target {
            ActivityTarget::Device { device_token } => {
                validate_device_token(device_token.as_str())?;
                headers.push((
                    "apns-topic",
                    format!("{}.push-type.liveactivity", self.bundle_id),
                ));
                (format!("/3/device/{device_token}"), 4096)
            }
            ActivityTarget::Channel { channel_id } => {
                validate_channel_id(channel_id.as_str())?;
                headers.push(("apns-channel-id", channel_id.into_inner()));
                (format!("/4/broadcasts/apps/{}", self.bundle_id), 5120)
            }
        };
        let body =
            serde_json::to_vec(&json!({ "aps": aps })).map_err(|_| "could not encode APNs body")?;
        if body.len() > limit {
            return Err("encoded APNs body exceeds its route's payload limit");
        }
        Ok(PreparedActivityRequest {
            method: Method::POST,
            url: format!("{}{path}", push_base_url(self.push_environment)),
            headers,
            body: Some(body),
            expected_status: StatusCode::OK,
            creates_channel: false,
        })
    }
}

impl ActivityChannelRequest {
    pub fn prepare(&self) -> Result<PreparedActivityRequest, &'static str> {
        let url = format!(
            "{}/1/apps/{}/channels",
            channel_base_url(self.push_environment),
            self.bundle_id
        );
        let (method, headers, body, expected_status, creates_channel) = match &self.operation {
            ChannelOperation::Create {
                message_storage_policy,
            } => {
                let policy = match message_storage_policy {
                    ChannelStoragePolicy::NoStorage => 0,
                    ChannelStoragePolicy::MostRecent => 1,
                };
                (
                    Method::POST,
                    Vec::new(),
                    Some(
                        serde_json::to_vec(
                            &json!({"message-storage-policy": policy, "push-type": "LiveActivity"}),
                        )
                        .map_err(|_| "could not encode channel configuration")?,
                    ),
                    StatusCode::CREATED,
                    true,
                )
            }
            ChannelOperation::Delete { channel_id } => {
                validate_channel_id(channel_id.as_str())?;
                (
                    Method::DELETE,
                    vec![("apns-channel-id", channel_id.as_str().to_owned())],
                    None,
                    StatusCode::NO_CONTENT,
                    false,
                )
            }
        };
        Ok(PreparedActivityRequest {
            method,
            url,
            headers,
            body,
            expected_status,
            creates_channel,
        })
    }
}

pub fn validate_channel_id(value: &str) -> Result<(), &'static str> {
    if value.len() > MAX_CHANNEL_ID_BYTES || value.is_empty() {
        return Err("channel_id must be nonempty and at most 1024 bytes");
    }
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(value)
        .map_err(|_| "channel_id must use standard base64 encoding")?;
    if decoded.is_empty() {
        return Err("channel_id must encode a nonempty value");
    }
    Ok(())
}

fn validate_device_token(value: &str) -> Result<(), &'static str> {
    if value.is_empty()
        || value.len() > MAX_DEVICE_TOKEN_BYTES
        || !value.len().is_multiple_of(2)
        || !value.bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        return Err("device_token must contain hexadecimal byte pairs and be at most 2048 bytes");
    }
    Ok(())
}

pub fn classify_apns_reason(reason: Option<&str>) -> ApnsFailureClass {
    match reason {
        Some(
            "BadDeviceToken"
            | "DeviceTokenNotForTopic"
            | "Unregistered"
            | "ChannelNotRegistered"
            | "BadChannelId",
        ) => ApnsFailureClass::Route,
        Some(
            "BadCertificate"
            | "BadCertificateEnvironment"
            | "ExpiredProviderToken"
            | "InvalidProviderToken"
            | "MissingProviderToken"
            | "Forbidden"
            | "TopicDisallowed"
            | "TopicMismatch"
            | "FeatureNotEnabled"
            | "BroadcastFeatureNotEnabled",
        ) => ApnsFailureClass::Authorization,
        Some("TooManyRequests" | "TooManyProviderTokenUpdates" | "CannotCreateChannelConfig") => {
            ApnsFailureClass::Throttled
        }
        Some("InternalServerError" | "ServiceUnavailable" | "Service Unavailable" | "Shutdown") => {
            ApnsFailureClass::Transient
        }
        Some(
            "PayloadTooLarge" | "PayloadEmpty" | "BadCollapseId" | "BadExpirationDate"
            | "BadMessageId" | "BadPriority" | "BadTopic" | "BadPath" | "MethodNotAllowed"
            | "BadRequestParams" | "BadRequestPayload" | "MissingChannelId" | "MissingDeviceToken"
            | "MissingTopic" | "MissingPushType" | "InvalidPushType" | "DuplicateHeaders",
        ) => ApnsFailureClass::Content,
        _ => ApnsFailureClass::Unknown,
    }
}

fn push_base_url(environment: PushEnvironment) -> &'static str {
    match environment {
        PushEnvironment::Development => "https://api.sandbox.push.apple.com",
        PushEnvironment::Production => "https://api.push.apple.com",
    }
}

fn channel_base_url(environment: PushEnvironment) -> &'static str {
    match environment {
        PushEnvironment::Development => "https://api-manage-broadcast.sandbox.push.apple.com:2195",
        PushEnvironment::Production => "https://api-manage-broadcast.push.apple.com:2196",
    }
}
