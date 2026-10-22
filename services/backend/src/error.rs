use anyhow::Error as AnyhowError;
use axum::Json;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde::Serialize;
use thiserror::Error;

use crate::models::{AnalyticsValidationError, InternalRequestValidationError, TimestampField};

#[derive(Debug, Error)]
pub enum PushSendError {
    #[error("failed to send APNs request")]
    Request(#[source] reqwest::Error),
    #[error("failed to encode APNs auth token")]
    AuthToken(#[source] jsonwebtoken::errors::Error),
    #[error("APNs rejected notification with status {status}")]
    Rejected {
        status: StatusCode,
        apns_id: Option<String>,
        apns_reason: Option<String>,
        detail: String,
    },
}

#[derive(Debug, Error)]
pub enum ApiError {
    #[error("{detail}")]
    ResourceLimit {
        code: &'static str,
        detail: &'static str,
    },
    #[error("{detail}")]
    Http {
        status: StatusCode,
        detail: String,
        event_id: Option<String>,
        event_type: Option<String>,
        field: Option<String>,
        rule: Option<String>,
    },
    #[error("{detail}")]
    DictationQuotaExceeded {
        detail: &'static str,
        remaining_seconds_this_week: i64,
        quota_resets_at_epoch_seconds: i64,
    },
    #[error("APNs rejected notification with status {status}")]
    PushRejected {
        status: StatusCode,
        detail: String,
        apns_reason: Option<String>,
        apns_id: Option<String>,
    },
    #[error("internal server error")]
    Internal(#[from] AnyhowError),
}

#[derive(Debug, Serialize)]
struct ErrorBody {
    detail: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    remaining_seconds_this_week: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    quota_resets_at_epoch_seconds: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    apns_status: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    apns_reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    apns_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    event_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    event_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    field: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    rule: Option<String>,
}

impl ApiError {
    pub fn bad_request(detail: impl Into<String>) -> Self {
        Self::Http {
            status: StatusCode::BAD_REQUEST,
            detail: detail.into(),
            event_id: None,
            event_type: None,
            field: None,
            rule: None,
        }
    }

    pub fn unauthorized(detail: impl Into<String>) -> Self {
        Self::Http {
            status: StatusCode::UNAUTHORIZED,
            detail: detail.into(),
            event_id: None,
            event_type: None,
            field: None,
            rule: None,
        }
    }

    pub fn forbidden(detail: impl Into<String>) -> Self {
        Self::Http {
            status: StatusCode::FORBIDDEN,
            detail: detail.into(),
            event_id: None,
            event_type: None,
            field: None,
            rule: None,
        }
    }

    pub fn too_many_requests_dictation(
        remaining_seconds_this_week: i64,
        quota_resets_at_epoch_seconds: i64,
    ) -> Self {
        Self::DictationQuotaExceeded {
            detail: "Weekly dictation limit reached.",
            remaining_seconds_this_week,
            quota_resets_at_epoch_seconds,
        }
    }

    pub fn not_found(detail: impl Into<String>) -> Self {
        Self::Http {
            status: StatusCode::NOT_FOUND,
            detail: detail.into(),
            event_id: None,
            event_type: None,
            field: None,
            rule: None,
        }
    }

    pub fn analytics_validation(
        detail: impl Into<String>,
        event_id: Option<String>,
        event_type: Option<String>,
        field: Option<String>,
        rule: Option<String>,
    ) -> Self {
        Self::Http {
            status: StatusCode::BAD_REQUEST,
            detail: detail.into(),
            event_id,
            event_type,
            field,
            rule,
        }
    }
}

impl From<PushSendError> for ApiError {
    fn from(error: PushSendError) -> Self {
        match error {
            PushSendError::Rejected {
                status,
                detail,
                apns_reason,
                apns_id,
            } => Self::PushRejected {
                status,
                detail,
                apns_reason,
                apns_id,
            },
            other => Self::Internal(other.into()),
        }
    }
}

impl From<InternalRequestValidationError> for ApiError {
    fn from(error: InternalRequestValidationError) -> Self {
        match error {
            InternalRequestValidationError::InvalidCallIdentity => {
                Self::bad_request("call_id and host_id must be UUIDs.")
            }
            InternalRequestValidationError::ReservedApsPayloadKey => {
                Self::bad_request("custom_data may not contain reserved key aps.")
            }
            InternalRequestValidationError::NonPositiveTimestamp(field) => match field {
                TimestampField::ExpiresAt => Self::bad_request("expires_at must be positive."),
                TimestampField::Expiration => Self::bad_request("expiration must be positive."),
                TimestampField::Timestamp => Self::bad_request("timestamp must be positive."),
                TimestampField::StaleDate => Self::bad_request("stale_date must be positive."),
                TimestampField::DismissalDate => {
                    Self::bad_request("dismissal_date must be positive.")
                }
            },
            InternalRequestValidationError::ContentStateMustBeObject => {
                Self::bad_request("content_state must be a JSON object.")
            }
        }
    }
}

impl From<AnalyticsValidationError> for ApiError {
    fn from(error: AnalyticsValidationError) -> Self {
        match error {
            AnalyticsValidationError::EmptyEventBatch => {
                Self::bad_request("Analytics batch must contain at least one event.")
            }
            AnalyticsValidationError::NonPositiveOriginalPurchaseDate => {
                Self::bad_request("original_purchase_date_epoch_seconds must be positive.")
            }
            AnalyticsValidationError::UnsupportedBundle => {
                Self::bad_request("Analytics ingestion requires the main production bundle.")
            }
            AnalyticsValidationError::UnsupportedFlavor => {
                Self::bad_request("Analytics ingestion requires the main flavor.")
            }
            AnalyticsValidationError::NonPositiveEventTimestamp => {
                Self::bad_request("Analytics event timestamps must be positive.")
            }
            AnalyticsValidationError::UnsupportedPayloadVersion(_) => {
                Self::bad_request("Analytics payload_version is unsupported.")
            }
            AnalyticsValidationError::PayloadMustBeObject => {
                Self::bad_request("Analytics event payloads must be JSON objects.")
            }
            AnalyticsValidationError::InvalidAccessStatePayload => {
                Self::bad_request("Analytics access-state payload is invalid.")
            }
            AnalyticsValidationError::InvalidAppSessionPayload => {
                Self::bad_request("Analytics app-session payload is invalid.")
            }
            AnalyticsValidationError::InvalidAccessStateSnapshotPayload => {
                Self::bad_request("Analytics access-state snapshot payload is invalid.")
            }
            AnalyticsValidationError::InvalidSshSessionPayload => {
                Self::bad_request("Analytics SSH session payload is invalid.")
            }
            AnalyticsValidationError::InvalidPurchaseFlowPayload => {
                Self::bad_request("Analytics purchase-flow payload is invalid.")
            }
            AnalyticsValidationError::InvalidHostSetupPayload { .. } => {
                Self::bad_request("Analytics host-setup payload is invalid.")
            }
            AnalyticsValidationError::InvalidPaywallPayload => {
                Self::bad_request("Analytics paywall payload is invalid.")
            }
            AnalyticsValidationError::InvalidKeyMaterialPayload => {
                Self::bad_request("Analytics key-material payload is invalid.")
            }
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        match self {
            Self::ResourceLimit { code, detail } => (
                StatusCode::TOO_MANY_REQUESTS,
                Json(serde_json::json!({"detail": detail, "code": code})),
            )
                .into_response(),
            Self::Http {
                status,
                detail,
                event_id,
                event_type,
                field,
                rule,
            } => (
                status,
                Json(ErrorBody {
                    detail,
                    remaining_seconds_this_week: None,
                    quota_resets_at_epoch_seconds: None,
                    apns_status: None,
                    apns_reason: None,
                    apns_id: None,
                    event_id,
                    event_type,
                    field,
                    rule,
                }),
            )
                .into_response(),
            Self::DictationQuotaExceeded {
                detail,
                remaining_seconds_this_week,
                quota_resets_at_epoch_seconds,
            } => (
                StatusCode::TOO_MANY_REQUESTS,
                Json(ErrorBody {
                    detail: detail.to_owned(),
                    remaining_seconds_this_week: Some(remaining_seconds_this_week),
                    quota_resets_at_epoch_seconds: Some(quota_resets_at_epoch_seconds),
                    apns_status: None,
                    apns_reason: None,
                    apns_id: None,
                    event_id: None,
                    event_type: None,
                    field: None,
                    rule: None,
                }),
            )
                .into_response(),
            Self::PushRejected {
                status,
                detail,
                apns_reason,
                apns_id,
            } => (
                status,
                Json(ErrorBody {
                    detail,
                    remaining_seconds_this_week: None,
                    quota_resets_at_epoch_seconds: None,
                    apns_status: Some(status.as_u16()),
                    apns_reason,
                    apns_id,
                    event_id: None,
                    event_type: None,
                    field: None,
                    rule: None,
                }),
            )
                .into_response(),
            Self::Internal(error) => {
                if let Some(capacity) = error
                    .chain()
                    .find_map(|cause| cause.downcast_ref::<crate::storage::RelayCapacityError>())
                {
                    return Self::ResourceLimit {
                        code: capacity.0,
                        detail: "Relay capacity reached. Please try again later.",
                    }
                    .into_response();
                }
                if error.chain().any(|cause| matches!(cause.downcast_ref::<rusqlite::Error>(), Some(rusqlite::Error::SqliteFailure(error, _)) if error.code == rusqlite::ErrorCode::DiskFull)) {
                    tracing::error!("relay database capacity reached; operator must archive retained analytics or raise the storage cap");
                    return Self::ResourceLimit { code: "relay_storage", detail: "Relay storage capacity reached. Please try again later." }.into_response();
                }
                tracing::error!("agentty_backend internal_error detail={error:#}");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ErrorBody {
                        detail: "Internal server error.".to_owned(),
                        remaining_seconds_this_week: None,
                        quota_resets_at_epoch_seconds: None,
                        apns_status: None,
                        apns_reason: None,
                        apns_id: None,
                        event_id: None,
                        event_type: None,
                        field: None,
                        rule: None,
                    }),
                )
                    .into_response()
            }
        }
    }
}
