use std::fs;
use std::sync::Arc;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use async_trait::async_trait;
use jsonwebtoken::{Algorithm, EncodingKey, Header, encode};
use reqwest::Client;
use serde::Deserialize;
use serde_json::{Map, Value, json};

use crate::activity_transport::{
    ActivityTransportResponse, ApnsFailureClass, PreparedActivityRequest, classify_apns_reason,
    validate_channel_id,
};
use crate::config::InternalCaller;
use crate::config::Settings;
use crate::error::PushSendError;
use crate::logging::{log_value, option_display};
use crate::models::{
    DeviceRecord, InternalAlertRequest, InternalLiveActivityRequest, InternalLocationRequest,
    InternalVoipRequest, NonEmptyString, NotifyRequest, PushEnvironment, PushType,
};

const DEVELOPMENT_APNS_URL: &str = "https://api.sandbox.push.apple.com";
const PRODUCTION_APNS_URL: &str = "https://api.push.apple.com";
const AUTH_TOKEN_CACHE_TTL_SECONDS: u64 = 50 * 60;
const MAX_SEND_ATTEMPTS: usize = 2;

#[derive(Debug, Clone)]
pub struct ApnsPushRequest {
    pub caller: String,
    pub push_environment: PushEnvironment,
    pub device_token: String,
    pub topic: String,
    pub push_type: PushType,
    pub collapse_id: Option<String>,
    pub expiration: Option<i64>,
    pub payload: Value,
    pub attempt_id: Option<String>,
    pub source: Option<String>,
    pub tmux_window_id: Option<i32>,
}

impl ApnsPushRequest {
    pub fn internal_voip(caller: InternalCaller, request: InternalVoipRequest) -> Self {
        Self {
            caller: caller.as_str().to_owned(),
            push_environment: request.push_environment,
            device_token: request.device_token.into_inner(),
            topic: format!("{}.voip", request.bundle_id),
            push_type: PushType::Voip,
            collapse_id: None,
            // A ring is ephemeral: APNs must never store it for later delivery.
            expiration: Some(0),
            payload: json!({
                "aps": {},
                "agentCall": {
                    "callId": request.call_id.as_str(),
                    "hostId": request.host_id.as_str(),
                    "expiresAt": request.expires_at,
                },
            }),
            attempt_id: None,
            source: None,
            tmux_window_id: None,
        }
    }

    pub fn agentty_notification(device: DeviceRecord, notification: NotifyRequest) -> Self {
        Self {
            caller: "agentty".to_owned(),
            push_environment: device.push_environment,
            device_token: device.apns_token,
            topic: device.bundle_id,
            push_type: PushType::Alert,
            collapse_id: None,
            expiration: None,
            payload: build_notification_payload(&notification),
            attempt_id: Some(notification.attempt_id.as_str().to_owned()),
            source: Some(notification.source.as_str().to_owned()),
            tmux_window_id: notification.tmux_window_id,
        }
    }

    pub fn internal_alert(caller: InternalCaller, request: InternalAlertRequest) -> Self {
        let InternalAlertRequest {
            topic,
            push_environment,
            device_token,
            title,
            body,
            subtitle,
            sound,
            collapse_id,
            mutable_content,
            custom_data,
        } = request;

        Self {
            caller: caller.as_str().to_owned(),
            push_environment,
            device_token: device_token.into_inner(),
            topic: topic.into_inner(),
            push_type: PushType::Alert,
            collapse_id: collapse_id.map(NonEmptyString::into_inner),
            expiration: None,
            payload: build_internal_alert_payload_parts(
                title,
                body,
                subtitle,
                sound,
                mutable_content,
                custom_data,
            ),
            attempt_id: None,
            source: None,
            tmux_window_id: None,
        }
    }

    pub fn internal_live_activity(
        caller: InternalCaller,
        request: InternalLiveActivityRequest,
    ) -> Self {
        let topic = request.live_activity_topic();
        let InternalLiveActivityRequest {
            bundle_id: _,
            push_environment,
            device_token,
            event,
            timestamp,
            content_state,
            stale_date,
            dismissal_date,
            alert,
        } = request;

        Self {
            caller: caller.as_str().to_owned(),
            push_environment,
            device_token: device_token.into_inner(),
            topic,
            push_type: PushType::LiveActivity,
            collapse_id: None,
            expiration: None,
            payload: build_live_activity_payload_parts(
                event,
                timestamp,
                content_state,
                stale_date,
                dismissal_date,
                alert,
            ),
            attempt_id: None,
            source: None,
            tmux_window_id: None,
        }
    }

    pub fn internal_location(caller: InternalCaller, request: InternalLocationRequest) -> Self {
        let topic = request.topic();
        let InternalLocationRequest {
            bundle_id: _,
            push_environment,
            device_token,
            expiration,
            custom_data,
        } = request;

        Self {
            caller: caller.as_str().to_owned(),
            push_environment,
            device_token: device_token.into_inner(),
            topic,
            push_type: PushType::Location,
            collapse_id: None,
            expiration: Some(expiration),
            payload: build_location_payload(custom_data),
            attempt_id: None,
            source: None,
            tmux_window_id: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushSendSuccess {
    pub apns_id: Option<String>,
}

#[async_trait]
pub trait PushSender: Send + Sync {
    async fn send(
        &self,
        request: ApnsPushRequest,
    ) -> std::result::Result<PushSendSuccess, PushSendError>;

    async fn send_activity(&self, request: PreparedActivityRequest) -> ActivityTransportResponse;
}

pub struct ApnsPushSender {
    client: Client,
    activity_client: Client,
    key_id: String,
    team_id: String,
    encoding_key: Arc<EncodingKey>,
    auth_token_cache: Mutex<Option<CachedAuthToken>>,
}

#[derive(Clone)]
struct CachedAuthToken {
    value: String,
    issued_at_epoch_seconds: u64,
}

impl ApnsPushSender {
    pub fn new(settings: &Settings) -> Result<Self> {
        let private_key = fs::read(&settings.apns_key_path).with_context(|| {
            format!(
                "failed to read APNs private key {}",
                settings.apns_key_path.display()
            )
        })?;
        let client = Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .context("failed to build APNs HTTP client")?;
        let activity_client = Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .build()
            .context("failed to build APNs activity HTTP client")?;

        Ok(Self {
            client,
            activity_client,
            key_id: settings.apns_key_id.clone(),
            team_id: settings.apns_team_id.clone(),
            encoding_key: Arc::new(
                EncodingKey::from_ec_pem(&private_key)
                    .context("failed to parse APNs private key")?,
            ),
            auth_token_cache: Mutex::new(None),
        })
    }

    fn auth_token(&self) -> std::result::Result<String, PushSendError> {
        let issued_at_epoch_seconds = current_epoch_seconds();
        let mut cache = self
            .auth_token_cache
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        if let Some(cached) = cache.as_ref()
            && issued_at_epoch_seconds.saturating_sub(cached.issued_at_epoch_seconds)
                < AUTH_TOKEN_CACHE_TTL_SECONDS
        {
            return Ok(cached.value.clone());
        }

        let token = self.make_auth_token(issued_at_epoch_seconds)?;
        *cache = Some(CachedAuthToken {
            value: token.clone(),
            issued_at_epoch_seconds,
        });

        Ok(token)
    }

    fn make_auth_token(
        &self,
        issued_at_epoch_seconds: u64,
    ) -> std::result::Result<String, PushSendError> {
        #[derive(serde::Serialize)]
        struct Claims<'a> {
            iss: &'a str,
            iat: u64,
        }

        let mut header = Header::new(Algorithm::ES256);
        header.kid = Some(self.key_id.clone());

        encode(
            &header,
            &Claims {
                iss: &self.team_id,
                iat: issued_at_epoch_seconds,
            },
            &self.encoding_key,
        )
        .map_err(PushSendError::AuthToken)
    }
}

#[async_trait]
impl PushSender for ApnsPushSender {
    async fn send_activity(&self, request: PreparedActivityRequest) -> ActivityTransportResponse {
        let token = match self.auth_token() {
            Ok(token) => token,
            Err(_) => {
                return ActivityTransportResponse::NotSent {
                    reason: "provider_authentication_failed",
                    failure_class: ApnsFailureClass::Authorization,
                };
            }
        };
        let mut builder = self
            .activity_client
            .request(request.method, request.url)
            .version(reqwest::Version::HTTP_2)
            .header("authorization", format!("bearer {token}"));
        for (name, value) in request.headers {
            builder = builder.header(name, value);
        }
        if let Some(body) = request.body {
            builder = builder
                .header("content-type", "application/json")
                .body(body);
        }
        let http_request = match builder.build() {
            Ok(value) => value,
            Err(_) => {
                return ActivityTransportResponse::NotSent {
                    reason: "request_construction_failed",
                    failure_class: ApnsFailureClass::Content,
                };
            }
        };
        let response = match self.activity_client.execute(http_request).await {
            Ok(value) => value,
            Err(_) => {
                return ActivityTransportResponse::Unknown {
                    reason: "transport_failed_after_dispatch",
                };
            }
        };
        let status = response.status();
        let apns_id = ["apns-request-id", "apns-id", "apns-unique-id"]
            .into_iter()
            .find_map(|name| {
                response
                    .headers()
                    .get(name)
                    .and_then(|value| value.to_str().ok())
            })
            .map(str::to_owned);
        if status == request.expected_status {
            let channel_id = if request.creates_channel {
                let Some(value) = response
                    .headers()
                    .get("apns-channel-id")
                    .and_then(|value| value.to_str().ok())
                    .filter(|value| validate_channel_id(value).is_ok())
                else {
                    return ActivityTransportResponse::Unknown {
                        reason: "accepted_channel_without_valid_identifier",
                    };
                };
                Some(value.to_owned())
            } else {
                None
            };
            return ActivityTransportResponse::Accepted {
                apns_id,
                channel_id,
            };
        }
        if status.is_success() || status.is_redirection() {
            return ActivityTransportResponse::Unknown {
                reason: "unexpected_apns_response_status",
            };
        }
        let retry_after_seconds = parse_retry_after(response.headers(), SystemTime::now());
        let apns_reason = bounded_apns_reason(response).await;
        let failure_class = classify_apns_reason(apns_reason.as_deref());
        ActivityTransportResponse::Rejected {
            apns_status: status.as_u16(),
            apns_id,
            apns_reason,
            retry_after_seconds,
            failure_class,
        }
    }

    async fn send(
        &self,
        request: ApnsPushRequest,
    ) -> std::result::Result<PushSendSuccess, PushSendError> {
        let token = self.auth_token()?;
        let base_url = match request.push_environment {
            PushEnvironment::Development => DEVELOPMENT_APNS_URL,
            PushEnvironment::Production => PRODUCTION_APNS_URL,
        };

        for attempt in 1..=MAX_SEND_ATTEMPTS {
            let mut builder = self
                .client
                .post(format!("{base_url}/3/device/{}", request.device_token))
                .header("authorization", format!("bearer {token}"))
                .header("apns-topic", &request.topic)
                .header("apns-push-type", request.push_type.as_str())
                .header("apns-priority", "10")
                .json(&request.payload);

            if let Some(collapse_id) = request.collapse_id.as_ref() {
                builder = builder.header("apns-collapse-id", collapse_id);
            }
            if let Some(expiration) = request.expiration {
                builder = builder.header("apns-expiration", expiration.to_string());
            }

            let response = match builder.send().await {
                Ok(response) => response,
                Err(error) => {
                    let detail = error.to_string();
                    tracing::error!(
                        "agentty_backend apns_send_failed caller={} push_type={} topic={} env={} attempt_id={} source={} tmux_window_id={} reason=request_failed detail={} send_attempt={}",
                        log_value(&request.caller),
                        request.push_type.as_str(),
                        log_value(&request.topic),
                        request.push_environment.as_str(),
                        log_optional_value(request.attempt_id.as_deref()),
                        log_optional_value(request.source.as_deref()),
                        option_display(request.tmux_window_id),
                        log_value(&detail),
                        attempt,
                    );
                    return Err(PushSendError::Request(error));
                }
            };

            let status = response.status();
            let apns_id = response
                .headers()
                .get("apns-id")
                .and_then(|value| value.to_str().ok())
                .map(str::to_owned);

            if status.is_success() {
                tracing::info!(
                    "agentty_backend apns_send caller={} push_type={} topic={} env={} attempt_id={} source={} tmux_window_id={} status={} apns_id={}",
                    log_value(&request.caller),
                    request.push_type.as_str(),
                    log_value(&request.topic),
                    request.push_environment.as_str(),
                    log_optional_value(request.attempt_id.as_deref()),
                    log_optional_value(request.source.as_deref()),
                    option_display(request.tmux_window_id),
                    status.as_u16(),
                    log_optional_value(apns_id.as_deref()),
                );
                return Ok(PushSendSuccess { apns_id });
            }

            let detail = response.text().await.unwrap_or_default();
            let apns_reason = parse_apns_reason(&detail);
            tracing::error!(
                "agentty_backend apns_send_failed caller={} push_type={} topic={} env={} attempt_id={} source={} tmux_window_id={} status={} apns_id={} apns_reason={} detail={} send_attempt={}",
                log_value(&request.caller),
                request.push_type.as_str(),
                log_value(&request.topic),
                request.push_environment.as_str(),
                log_optional_value(request.attempt_id.as_deref()),
                log_optional_value(request.source.as_deref()),
                option_display(request.tmux_window_id),
                status.as_u16(),
                log_optional_value(apns_id.as_deref()),
                log_optional_value(apns_reason.as_deref()),
                log_value(detail.trim()),
                attempt,
            );

            if attempt < MAX_SEND_ATTEMPTS
                && matches!(
                    status,
                    reqwest::StatusCode::INTERNAL_SERVER_ERROR
                        | reqwest::StatusCode::SERVICE_UNAVAILABLE
                )
            {
                continue;
            }

            return Err(PushSendError::Rejected {
                status,
                apns_id,
                apns_reason,
                detail,
            });
        }

        unreachable!("send loop must return within max attempts")
    }
}

pub fn build_location_payload(custom_data: Map<String, Value>) -> Value {
    let mut payload = custom_data;
    payload.insert("aps".to_owned(), json!({}));
    Value::Object(payload)
}

pub fn build_notification_payload(notification: &NotifyRequest) -> Value {
    let mut payload = Map::new();
    payload.insert(
        "aps".to_owned(),
        json!({
            "alert": build_alert_object(
                notification.title.as_str(),
                notification.body.as_str(),
                None,
            ),
            "sound": "default",
            "mutable-content": 1,
        }),
    );
    payload.insert(
        "attempt_id".to_owned(),
        Value::String(notification.attempt_id.as_str().to_owned()),
    );
    payload.insert(
        "source".to_owned(),
        Value::String(notification.source.as_str().to_owned()),
    );
    if let Some(tmux_window_id) = notification.tmux_window_id {
        payload.insert("tmux_window_id".to_owned(), Value::from(tmux_window_id));
    }
    Value::Object(payload)
}

pub fn build_internal_alert_payload(request: &InternalAlertRequest) -> Value {
    build_internal_alert_payload_parts(
        request.title.clone(),
        request.body.clone(),
        request.subtitle.clone(),
        request.sound.clone(),
        request.mutable_content,
        request.custom_data.clone(),
    )
}

fn build_internal_alert_payload_parts(
    title: NonEmptyString,
    body: NonEmptyString,
    subtitle: Option<NonEmptyString>,
    sound: Option<NonEmptyString>,
    mutable_content: bool,
    custom_data: Option<Map<String, Value>>,
) -> Value {
    let mut aps = Map::new();
    aps.insert(
        "alert".to_owned(),
        Value::Object(build_alert_object(
            title.as_str(),
            body.as_str(),
            subtitle.as_ref().map(NonEmptyString::as_str),
        )),
    );
    if let Some(sound) = sound {
        aps.insert("sound".to_owned(), Value::String(sound.into_inner()));
    }
    if mutable_content {
        aps.insert("mutable-content".to_owned(), Value::from(1));
    }

    let mut payload = Map::new();
    payload.insert("aps".to_owned(), Value::Object(aps));
    if let Some(custom_data) = custom_data {
        payload.extend(custom_data);
    }
    Value::Object(payload)
}

pub fn build_live_activity_payload(request: &InternalLiveActivityRequest) -> Value {
    build_live_activity_payload_parts(
        request.event,
        request.timestamp,
        request.content_state.clone(),
        request.stale_date,
        request.dismissal_date,
        request.alert.clone(),
    )
}

fn build_live_activity_payload_parts(
    event: crate::models::LiveActivityEvent,
    timestamp: i64,
    content_state: Value,
    stale_date: Option<i64>,
    dismissal_date: Option<i64>,
    alert: Option<crate::models::InternalLiveActivityAlert>,
) -> Value {
    let mut aps = Map::new();
    aps.insert("timestamp".to_owned(), Value::from(timestamp));
    aps.insert("event".to_owned(), Value::String(event.as_str().to_owned()));
    aps.insert("content-state".to_owned(), content_state);
    if let Some(stale_date) = stale_date {
        aps.insert("stale-date".to_owned(), Value::from(stale_date));
    }
    if let Some(dismissal_date) = dismissal_date {
        aps.insert("dismissal-date".to_owned(), Value::from(dismissal_date));
    }
    if let Some(alert) = alert {
        aps.insert(
            "alert".to_owned(),
            Value::Object(build_alert_object(
                alert.title.as_str(),
                alert.body.as_str(),
                alert.subtitle.as_ref().map(NonEmptyString::as_str),
            )),
        );
    }

    let mut payload = Map::new();
    payload.insert("aps".to_owned(), Value::Object(aps));
    Value::Object(payload)
}

#[derive(Debug, Deserialize)]
struct ApnsErrorBody {
    reason: Option<String>,
}

fn parse_apns_reason(detail: &str) -> Option<String> {
    serde_json::from_str::<ApnsErrorBody>(detail)
        .ok()
        .and_then(|body| body.reason)
}

pub(crate) fn build_alert_object(
    title: &str,
    body: &str,
    subtitle: Option<&str>,
) -> Map<String, Value> {
    let mut alert = Map::new();
    alert.insert("title".to_owned(), Value::String(title.to_owned()));
    alert.insert("body".to_owned(), Value::String(body.to_owned()));
    if let Some(subtitle) = subtitle {
        alert.insert("subtitle".to_owned(), Value::String(subtitle.to_owned()));
    }
    alert
}

async fn bounded_apns_reason(mut response: reqwest::Response) -> Option<String> {
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.ok()? {
        if bytes.len() + chunk.len() > 4096 {
            return None;
        }
        bytes.extend_from_slice(&chunk);
    }
    let body: ApnsErrorBody = serde_json::from_slice(&bytes).ok()?;
    body.reason.filter(|value| value.len() <= 128)
}

fn parse_retry_after(headers: &reqwest::header::HeaderMap, received_at: SystemTime) -> Option<u64> {
    let mut values = headers.get_all(reqwest::header::RETRY_AFTER).iter();
    let value = values.next()?;
    if values.next().is_some() {
        return None;
    }
    let value = value.to_str().ok()?.trim();
    if !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit()) {
        return value.parse().ok();
    }
    let deadline = httpdate::parse_http_date(value).ok()?;
    let delay = match deadline.duration_since(received_at) {
        Ok(delay) => delay,
        Err(_) => return Some(0),
    };
    delay
        .as_secs()
        .checked_add(u64::from(delay.subsec_nanos() != 0))
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use reqwest::header::{HeaderMap, HeaderValue, RETRY_AFTER};

    use super::{UNIX_EPOCH, parse_retry_after};

    #[test]
    fn retry_after_preserves_delta_seconds_and_absence() {
        let received_at = UNIX_EPOCH + Duration::from_secs(60);
        assert_eq!(parse_retry_after(&HeaderMap::new(), received_at), None);
        for (value, expected) in [
            ("60", Some(60)),
            ("0", Some(0)),
            (" 120 ", Some(120)),
            ("", None),
            ("-1", None),
            ("+1", None),
            ("1.5", None),
            ("not a date", None),
            ("18446744073709551616", None),
        ] {
            let mut headers = HeaderMap::new();
            headers.insert(RETRY_AFTER, HeaderValue::from_static(value));
            assert_eq!(parse_retry_after(&headers, received_at), expected);
        }
        let mut headers = HeaderMap::new();
        headers.append(RETRY_AFTER, HeaderValue::from_static("60"));
        headers.append(RETRY_AFTER, HeaderValue::from_static("120"));
        assert_eq!(parse_retry_after(&headers, received_at), None);
    }

    #[test]
    fn retry_after_http_date_honors_deadline_with_fractional_seconds() {
        let mut headers = HeaderMap::new();
        headers.insert(
            RETRY_AFTER,
            HeaderValue::from_static("Thu, 01 Jan 1970 00:02:00 GMT"),
        );
        for (received_at, expected) in [
            (UNIX_EPOCH + Duration::from_secs(60), Some(60)),
            (UNIX_EPOCH + Duration::new(60, 1), Some(60)),
            (UNIX_EPOCH + Duration::from_secs(120), Some(0)),
            (UNIX_EPOCH + Duration::from_secs(121), Some(0)),
        ] {
            assert_eq!(parse_retry_after(&headers, received_at), expected);
        }
    }
}

fn log_optional_value(value: Option<&str>) -> String {
    value.map(log_value).unwrap_or_else(|| "none".to_owned())
}

fn current_epoch_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or_default()
}
