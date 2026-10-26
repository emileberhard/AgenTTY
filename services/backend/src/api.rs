use std::time::{Duration, Instant};

use axum::Json;
use axum::Router;
use axum::body::Bytes;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{DefaultBodyLimit, FromRequest, Multipart, Path, Request, State};
use axum::http::{HeaderMap, HeaderName, HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use futures_util::{SinkExt, StreamExt};
use serde_json::json;
use subtle::ConstantTimeEq;
use tokio::sync::mpsc;
use tokio::time::{MissedTickBehavior, interval};

use crate::AppState;
use crate::apns::{ApnsPushRequest, PushSendSuccess, PushSender};
use crate::build_info;
use crate::config::InternalClientSettings;
use crate::dictation::{
    AudioStream, Definition, DictationSubject, DictationTier, DictationWindows,
    STREAM_BYTES_PER_SECOND, SpeechResponse, SpeechUpload, SpeechUpstreamUnavailable,
    StreamWavLength, WAV_HEADER_BYTES, open_stream_wav_header, parse_audio_payload,
    parse_stream_wav_header, transcript_text,
};
use crate::error::ApiError;
use crate::logging::{log_value, option_display, token_tail};
use crate::models::{
    AnalyticsIngestRequest, BrokerSendResponse, ConnectorRegisterRequest,
    ConnectorRegisterResponse, ConnectorSessionTokenRequest, ConnectorSessionTokenResponse,
    DeviceIdentityEnsureRequest, DeviceRecord, DeviceRegistrationRequest,
    DictationTranscriptionRequest, DictationTranscriptionResponse, InternalAlertRequest,
    InternalLiveActivityRequest, InternalLocationRequest, InternalVoipRequest, MAIN_BUNDLE_ID,
    NotifyRequest, PairingSessionClaimRequest, PairingSessionClaimResponse,
    PairingSessionCompleteRequest, PairingSessionHostStatusRequest,
    PairingSessionHostStatusResponse, PairingSessionResponse, PairingSessionStatusRequest,
    PairingSessionStatusResponse, PushEnvironment, PushType, RelaySessionRequest,
    SshRelaySessionCreateRequest, SshRelaySessionCreateResponse, ValidatedAnalyticsEvent,
    normalize_pairing_code,
};
use crate::relay_broker::{RelayBrokerError, relay_peer_channel};
use crate::relay_tokens::RelayTokenKind;
use crate::storage::{
    AnalyticsDeviceContextRecord, AnalyticsEventRecord, AnalyticsIngestFailureRecord,
    AnalyticsIssueCandidate, AnalyticsIssueSeverity, AnalyticsSensitiveEventContextInput,
    CompletePairingSessionResult, HostPairingSessionLookupResult, hash_text,
};

// The relay receives dictation audio as base64-encoded JSON, so the request
// body must be materially larger than the upstream raw-file limit.
const MAX_DICTATION_REQUEST_BODY_BYTES: usize = 33_400_000;
pub const DICTATION_STREAM_PATH: &str =
    "/v1/dictation/azure-speech/speechtotext/transcriptions:transcribe";
const DICTATION_STREAM_MAX_SECONDS: u64 = 15 * 60;
const MAX_DICTATION_STREAM_BODY_BYTES: usize =
    (DICTATION_STREAM_MAX_SECONDS * STREAM_BYTES_PER_SECOND) as usize + 64 * 1024;
const DICTATION_STREAM_RESERVATION_SECONDS: i64 = 30;
const DICTATION_STREAM_IDLE: Duration = Duration::from_secs(30);
const DICTATION_STREAM_DEADLINE: Duration = Duration::from_secs(15 * 60);
const DICTATION_UPSTREAM_RESPONSE_TIMEOUT: Duration = Duration::from_secs(45);
const MAX_DICTATION_DEFINITION_BYTES: usize = 8 * 1024;
const CONNECTOR_CONTROL_PROBE_HEADER: &str = "x-agentty-probe";
const CONNECTOR_CONTROL_PROBE_VALUE: &str = "connector-control";
const CONNECTOR_CONTROL_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(30);

pub fn build_router(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route("/v1/devices/ensure", post(ensure_device_identity))
        .route("/v1/devices/register", post(register_device))
        .route("/v1/relay-sessions", post(issue_relay_session))
        .route("/v1/dictation/sessions", post(issue_dictation_session))
        .route("/v1/connectors/register", post(register_connector))
        .route(
            "/v1/connectors/session-token",
            post(issue_connector_session_token),
        )
        .route("/v1/connectors/ws", get(connector_control_websocket))
        .route(
            "/v1/connectors/sessions/{relay_session_id}/ws",
            get(connector_session_websocket),
        )
        .route("/v1/ssh-relay-sessions", post(create_ssh_relay_session))
        .route(
            "/v1/ssh-relay-sessions/{relay_session_id}/ws",
            get(app_ssh_relay_session_websocket),
        )
        .route("/v1/analytics/events", post(ingest_analytics_events))
        .route(
            DICTATION_STREAM_PATH,
            post(dictation_stream).layer(DefaultBodyLimit::max(MAX_DICTATION_STREAM_BODY_BYTES)),
        )
        .route(
            "/v1/dictation/transcriptions",
            post(dictation_transcription)
                .layer(DefaultBodyLimit::max(MAX_DICTATION_REQUEST_BODY_BYTES)),
        )
        .route("/v1/pairing-sessions", post(create_pairing_session))
        .route("/v1/pairing-sessions/claim", post(claim_pairing_session))
        .route(
            "/v1/pairing-sessions/{session_id}/status",
            post(pairing_session_status),
        )
        .route(
            "/v1/pairing-sessions/{session_id}/host-status",
            post(host_pairing_session_status),
        )
        .route(
            "/v1/pairing-sessions/{session_id}/complete",
            post(complete_pairing_session),
        )
        .route("/v1/notify", post(notify))
        .route("/v1/internal/alert", post(internal_alert))
        .route("/v1/internal/live-activity", post(internal_live_activity))
        .route("/v1/internal/location", post(internal_location))
        .route("/v1/internal/voip", post(internal_voip))
        .layer(DefaultBodyLimit::max(256 * 1024))
        .layer(axum::middleware::from_fn_with_state(
            state.clone(),
            crate::admission::limit,
        ))
        .with_state(state)
}

async fn healthz() -> Json<serde_json::Value> {
    let build_info = build_info::current_build_info();
    Json(json!({
        "status": "ok",
        "version": build_info.version,
        "git_sha": build_info.git_sha,
        "git_tag": build_info.git_tag,
    }))
}

async fn ensure_device_identity(
    State(state): State<AppState>,
    Json(request): Json<DeviceIdentityEnsureRequest>,
) -> Result<StatusCode, ApiError> {
    if request.device_id.as_str().len() > 128 || request.device_secret.as_str().len() > 256 {
        return Err(ApiError::bad_request(
            "Device credentials exceed supported bounds.",
        ));
    }
    request
        .validate_bundle_environment()
        .map_err(|_| ApiError::bad_request("Unsupported bundle/environment pair."))?;

    let admission = registration_admission(
        &state,
        request.device_id.as_str(),
        request.device_secret.as_str(),
        request
            .signed_app_transaction
            .as_ref()
            .map(|value| value.as_str()),
    )
    .await?;
    let ensured = state
        .database
        .ensure_device_identity(
            request.device_id.as_str().to_owned(),
            request.device_secret.as_str().to_owned(),
            request.bundle_id.as_str().to_owned(),
            request.push_environment,
        )
        .await
        .map_err(ApiError::from)?;

    if !ensured {
        tracing::warn!(
            "agentty_backend device_ensure_rejected device_id={}",
            log_value(request.device_id.as_str()),
        );
        return Err(ApiError::unauthorized("Invalid device credentials."));
    }

    if let Some(identity) = admission {
        state
            .database
            .admit_verified_device(request.device_id.as_str().to_owned(), identity)
            .await
            .map_err(ApiError::from)?;
    }
    tracing::info!(
        "agentty_backend device_ensure_ready device_id={} bundle_id={} env={}",
        log_value(request.device_id.as_str()),
        request.bundle_id,
        request.push_environment.as_str(),
    );

    Ok(StatusCode::NO_CONTENT)
}

async fn register_device(
    State(state): State<AppState>,
    Json(request): Json<DeviceRegistrationRequest>,
) -> Result<StatusCode, ApiError> {
    if request.device_id.as_str().len() > 128 || request.device_secret.as_str().len() > 256 {
        return Err(ApiError::bad_request(
            "Device credentials exceed supported bounds.",
        ));
    }
    if request.apns_token.as_str().len() > 512 {
        return Err(ApiError::bad_request("Invalid push token length."));
    }
    request
        .validate_bundle_environment()
        .map_err(|_| ApiError::bad_request("Unsupported bundle/environment pair."))?;

    let admission = registration_admission(
        &state,
        request.device_id.as_str(),
        request.device_secret.as_str(),
        request
            .signed_app_transaction
            .as_ref()
            .map(|value| value.as_str()),
    )
    .await?;
    let registered = state
        .database
        .register_device(
            request.device_id.as_str().to_owned(),
            request.device_secret.as_str().to_owned(),
            request.apns_token.as_str().to_owned(),
            request.bundle_id.as_str().to_owned(),
            request.push_environment,
        )
        .await
        .map_err(ApiError::from)?;

    if !registered {
        tracing::warn!(
            "agentty_backend device_register_rejected device_id={}",
            log_value(request.device_id.as_str()),
        );
        return Err(ApiError::unauthorized("Invalid device credentials."));
    }

    if let Some(identity) = admission {
        state
            .database
            .admit_verified_device(request.device_id.as_str().to_owned(), identity)
            .await
            .map_err(ApiError::from)?;
    }
    tracing::info!(
        "agentty_backend device_register device_id={} bundle_id={} env={} apns_token_tail={}",
        log_value(request.device_id.as_str()),
        request.bundle_id,
        request.push_environment.as_str(),
        token_tail(request.apns_token.as_str()),
    );

    Ok(StatusCode::NO_CONTENT)
}

async fn issue_relay_session(
    State(state): State<AppState>,
    Json(request): Json<RelaySessionRequest>,
) -> Result<Json<crate::models::RelaySessionResponse>, ApiError> {
    let relay_session = issue_relay_session_for_request(&state, &request).await?;

    tracing::info!(
        "agentty_backend relay_session_issued device_id={} expires_at={} relay_token_tail={}",
        log_value(request.device_id.as_str()),
        relay_session.expires_at_epoch_seconds,
        token_tail(&relay_session.relay_token),
    );

    Ok(Json(relay_session))
}

async fn issue_dictation_session(
    State(state): State<AppState>,
    Json(request): Json<crate::models::DictationSessionRequest>,
) -> Result<Json<crate::models::RelaySessionResponse>, ApiError> {
    authenticate_device_credentials(
        &state,
        request.device_id.as_str(),
        request.device_secret.as_str(),
    )
    .await?;
    let limits = &state.admission.dictation_limits;
    let app_id = limits.app_apple_id;
    if app_id == 0 {
        return Err(ApiError::forbidden(
            "App Store dictation admission is not configured.",
        ));
    }
    let signed = request.signed_app_transaction.into_inner();
    let lifetime = request
        .signed_lifetime_transaction
        .map(|value| value.into_inner())
        .zip(limits.lifetime_product_id.clone());
    let device_id = request.device_id.as_str().to_owned();
    let (app, purchase) = tokio::task::spawn_blocking(move || {
        let app = crate::app_transaction::verify(&signed, app_id)?;
        let purchase = lifetime.map(|(signed, product_id)| {
            crate::app_transaction::verify_lifetime_purchase(&signed, &app, &product_id)
        });
        anyhow::Ok((app, purchase))
    })
    .await
    .map_err(|error| ApiError::from(anyhow::Error::from(error)))?
    .map_err(|_| ApiError::unauthorized("Invalid signed app transaction."))?;
    let dictation = match purchase {
        Some(Ok(purchase)) => (purchase, DictationTier::Lifetime),
        Some(Err(error)) => {
            tracing::warn!(
                "agentty_backend dictation_lifetime_rejected device_id={} reason={error}",
                log_value(&device_id),
            );
            (app.identity.clone(), DictationTier::Free)
        }
        None => (app.identity.clone(), DictationTier::Free),
    };
    state
        .database
        .admit_verified_device(device_id, app.identity)
        .await
        .map_err(ApiError::from)?;
    authorize_device(&state, request.device_id.as_str()).await?;
    let session = state
        .database
        .issue_relay_session(
            request.device_id.into_inner(),
            request.device_secret.into_inner(),
            "dictation".to_owned(),
            Some(dictation),
        )
        .await
        .map_err(ApiError::from)?
        .ok_or_else(|| ApiError::unauthorized("Invalid device credentials."))?;
    Ok(Json(session))
}

async fn ingest_analytics_events(
    State(state): State<AppState>,
    Json(request): Json<AnalyticsIngestRequest>,
) -> Result<StatusCode, ApiError> {
    let Some(device) = state
        .database
        .device_for_credentials(
            request.device_id.as_str().to_owned(),
            request.device_secret.as_str().to_owned(),
        )
        .await
        .map_err(ApiError::from)?
    else {
        tracing::warn!(
            "agentty_backend analytics_auth_rejected device_id={}",
            log_value(request.device_id.as_str()),
        );
        return Err(ApiError::unauthorized("Invalid device credentials."));
    };

    if device.bundle_id != MAIN_BUNDLE_ID || device.push_environment != PushEnvironment::Production
    {
        tracing::warn!(
            "agentty_backend analytics_forbidden device_id={} bundle_id={} env={}",
            log_value(&device.device_id),
            log_value(&device.bundle_id),
            device.push_environment.as_str(),
        );
        return Err(ApiError::forbidden(
            "Analytics ingestion is only available for production AgenTTY installs.",
        ));
    }

    authorize_device(&state, &device.device_id).await?;
    let raw_device_id = request.device_id.as_str().to_owned();
    let request_event_diagnostics = request
        .events
        .iter()
        .take(10)
        .map(|event| format!("{}:{}", event.event_type.as_str(), event.event_id.as_str()))
        .collect::<Vec<_>>()
        .join(",");
    let raw_user_key_hash = Some(hash_text(request.app_transaction_id.as_str()));
    let raw_bundle_id = Some(request.bundle_id.as_str().to_owned());
    let raw_app_transaction_environment =
        Some(request.app_transaction_environment.as_str().to_owned());
    let raw_app_version = Some(request.app_version.as_str().to_owned());
    let raw_build_number = Some(request.build_number.as_str().to_owned());
    let raw_flavor = Some(request.flavor.as_str().to_owned());
    let raw_platform = Some(request.platform.as_str().to_owned());
    let raw_event_count = i64::try_from(request.events.len()).unwrap_or(i64::MAX);
    let validation_diagnostic_source = request.clone();
    let request = match request.validate() {
        Ok(request) => request,
        Err(error) => {
            let validation_diagnostic = validation_diagnostic_source.validation_diagnostic(&error);
            let failure_record = AnalyticsIngestFailureRecord {
                device_id: raw_device_id.clone(),
                user_key_hash: raw_user_key_hash,
                bundle_id: raw_bundle_id,
                app_transaction_environment: raw_app_transaction_environment,
                app_version: raw_app_version,
                build_number: raw_build_number,
                flavor: raw_flavor,
                platform: raw_platform,
                error: error.to_string(),
                event_count: raw_event_count,
                event_diagnostics: request_event_diagnostics.clone(),
                failed_event_id: validation_diagnostic.failed_event_id.clone(),
                failed_event_type: validation_diagnostic.failed_event_type.clone(),
                validation_field: validation_diagnostic.validation_field.clone(),
                validation_rule: validation_diagnostic.validation_rule.clone(),
                payload_version: validation_diagnostic.payload_version,
                redacted_payload_shape_json: validation_diagnostic
                    .redacted_payload_shape_json
                    .clone(),
            };

            tracing::warn!(
                "agentty_backend analytics_validation_failed device_id={} error={} events={} failed_event_id={} failed_event_type={} field={} rule={}",
                log_value(&raw_device_id),
                log_value(&error.to_string()),
                log_value(&request_event_diagnostics),
                log_value(
                    validation_diagnostic
                        .failed_event_id
                        .as_deref()
                        .unwrap_or("none")
                ),
                log_value(
                    validation_diagnostic
                        .failed_event_type
                        .as_deref()
                        .unwrap_or("none")
                ),
                log_value(
                    validation_diagnostic
                        .validation_field
                        .as_deref()
                        .unwrap_or("none")
                ),
                log_value(
                    validation_diagnostic
                        .validation_rule
                        .as_deref()
                        .unwrap_or("none")
                ),
            );

            if let Err(record_error) = state
                .database
                .record_analytics_ingest_failure(failure_record)
                .await
            {
                tracing::error!(
                    "agentty_backend analytics_validation_failure_record_failed device_id={} error={}",
                    log_value(&raw_device_id),
                    log_value(&record_error.to_string()),
                );
            }

            return Err(ApiError::analytics_validation(
                error.to_string(),
                validation_diagnostic.failed_event_id,
                validation_diagnostic.failed_event_type,
                validation_diagnostic.validation_field,
                validation_diagnostic.validation_rule,
            ));
        }
    };

    let user_key_hash = hash_text(request.app_transaction_id.as_str());
    let event_count = request.events.len();
    let events = request
        .events
        .into_iter()
        .map(analytics_event_record)
        .collect::<Result<Vec<_>, _>>()?;

    state
        .database
        .ingest_analytics_batch(
            device.device_id.clone(),
            analytics_device_context_record(request.device_context.as_ref()),
            user_key_hash.clone(),
            request.original_purchase_date_epoch_seconds,
            request.bundle_id.into_inner(),
            request.app_transaction_environment.as_str().to_owned(),
            request.app_version.into_inner(),
            request.build_number.into_inner(),
            request.flavor.as_str().to_owned(),
            request.platform.as_str().to_owned(),
            events,
        )
        .await
        .map_err(ApiError::from)?;

    if let Err(error) = process_analytics_alerts(&state, &device.device_id, &user_key_hash).await {
        tracing::error!(
            "agentty_backend analytics_alert_processing_failed source_device_id={} user_key_hash_tail={} error={}",
            log_value(&device.device_id),
            token_tail(&user_key_hash),
            log_value(&error.to_string()),
        );
    }

    tracing::info!(
        "agentty_backend analytics_ingested device_id={} user_key_hash_tail={} events={}",
        log_value(&device.device_id),
        token_tail(&user_key_hash),
        event_count,
    );

    Ok(StatusCode::NO_CONTENT)
}

fn analytics_device_context_record(
    device_context: Option<&crate::models::AnalyticsDeviceContext>,
) -> AnalyticsDeviceContextRecord {
    AnalyticsDeviceContextRecord {
        system_version: device_context.map(|value| value.system_version.as_str().to_owned()),
        device_model_identifier: device_context
            .map(|value| value.device_model_identifier.as_str().to_owned()),
        device_family: device_context.map(|value| value.device_family.as_str().to_owned()),
        locale_identifier: device_context.map(|value| value.locale_identifier.as_str().to_owned()),
        preferred_languages_json: device_context.map(|value| {
            serde_json::Value::Array(
                value
                    .preferred_languages
                    .iter()
                    .map(|language| serde_json::Value::String(language.as_str().to_owned()))
                    .collect(),
            )
            .to_string()
        }),
    }
}

fn analytics_event_record(
    event: ValidatedAnalyticsEvent,
) -> Result<AnalyticsEventRecord, ApiError> {
    let saved_host_count = event.parsed_payload.saved_host_count();
    let access_state = event
        .parsed_payload
        .access_state()
        .map_err(ApiError::from)?;
    let stored_payload = event
        .parsed_payload
        .into_storage_payload()
        .map_err(ApiError::from)?;
    let sensitive_context =
        stored_payload
            .sensitive_context
            .map(|context| AnalyticsSensitiveEventContextInput {
                raw_detected_username: context.raw_detected_username,
                raw_selected_candidate_value: context.raw_selected_candidate_value,
                raw_candidate_values_json: context.raw_candidate_values_json,
                raw_disconnect_reason: context.raw_disconnect_reason,
                raw_error_detail: context.raw_error_detail,
            });
    Ok(AnalyticsEventRecord {
        event_id: event.event_id.into_inner(),
        event_type: event.event_type,
        occurred_at_epoch_seconds: event.occurred_at_epoch_seconds,
        payload_json: stored_payload.payload_json,
        access_state,
        saved_host_count,
        sensitive_context,
    })
}

async fn process_analytics_alerts(
    state: &AppState,
    source_device_id: &str,
    user_key_hash: &str,
) -> Result<(), ApiError> {
    let Some(destination_device_id) = state.analytics_alerts.destination_device_id.as_deref()
    else {
        return Ok(());
    };

    if state
        .analytics_alerts
        .internal_device_ids
        .iter()
        .any(|device_id| device_id == source_device_id)
        || state
            .analytics_alerts
            .internal_user_key_hashes
            .iter()
            .any(|candidate| candidate == user_key_hash)
    {
        return Ok(());
    }

    let issues = state
        .database
        .analytics_issue_candidates_for_user(user_key_hash.to_owned())
        .await
        .map_err(ApiError::from)?;
    if issues.is_empty() {
        return Ok(());
    }

    let Some(destination_device) = state
        .database
        .device_by_id(destination_device_id.to_owned())
        .await
        .map_err(ApiError::from)?
    else {
        return Ok(());
    };
    if destination_device.apns_token.is_empty() {
        return Ok(());
    }

    let now = current_epoch_seconds();
    for issue in issues {
        let decision = state
            .database
            .upsert_analytics_issue_candidate(
                issue.clone(),
                state.analytics_alerts.cooldown_seconds,
                now,
            )
            .await
            .map_err(ApiError::from)?;
        if !decision.should_send_alert {
            continue;
        }
        if !matches!(issue.issue_severity, AnalyticsIssueSeverity::Blocked) {
            continue;
        }

        let request = analytics_alert_push_request(&destination_device, &issue);
        state
            .push_sender
            .send(request)
            .await
            .map_err(ApiError::from)?;
        state
            .database
            .mark_analytics_issue_alert_sent(issue.signature_key.clone(), now)
            .await
            .map_err(ApiError::from)?;

        tracing::info!(
            "agentty_backend analytics_alert_sent user_key_hash_tail={} issue_kind={} signature_key_tail={}",
            token_tail(user_key_hash),
            issue.issue_kind.as_str(),
            token_tail(&issue.signature_key),
        );
    }

    Ok(())
}

fn analytics_alert_push_request(
    device: &DeviceRecord,
    issue: &AnalyticsIssueCandidate,
) -> ApnsPushRequest {
    ApnsPushRequest {
        caller: "agentty-analytics".to_owned(),
        push_environment: device.push_environment,
        device_token: device.apns_token.clone(),
        topic: device.bundle_id.clone(),
        push_type: PushType::Alert,
        collapse_id: Some(format!(
            "analytics-{}",
            &hash_text(&issue.signature_key)[..24]
        )),
        expiration: None,
        payload: json!({
            "aps": {
                "alert": {
                    "title": "AgenTTY blocker detected",
                    "body": issue.summary,
                },
                "sound": "default",
            },
            "agentty.analytics": {
                "signature_key": issue.signature_key,
                "issue_kind": issue.issue_kind.as_str(),
                "issue_severity": issue.issue_severity.as_str(),
                "user_key_hash_tail": token_tail(&issue.user_key_hash),
                "occurrence_count": issue.occurrence_count,
            }
        }),
        attempt_id: None,
        source: None,
        tmux_window_id: None,
    }
}

fn current_epoch_seconds() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or_default()
}

async fn create_pairing_session(
    State(state): State<AppState>,
) -> Result<Json<PairingSessionResponse>, ApiError> {
    ensure_pairing_admission(&state)?;
    let pairing_session = state
        .database
        .create_pairing_session()
        .await
        .map_err(ApiError::from)?;

    tracing::info!(
        "agentty_backend pairing_session_created session_id={} expires_at={} host_token_tail={}",
        log_value(&pairing_session.session_id),
        pairing_session.expires_at_epoch_seconds,
        token_tail(&pairing_session.host_token),
    );

    Ok(Json(pairing_session))
}

async fn pairing_session_status(
    State(state): State<AppState>,
    Path(session_id): Path<String>,
    Json(request): Json<PairingSessionStatusRequest>,
) -> Result<Json<PairingSessionStatusResponse>, ApiError> {
    authenticate_device_request(
        &state,
        request.device_id.as_str(),
        request.device_secret.as_str(),
    )
    .await?;

    let Some(pairing_session) = state
        .database
        .pairing_session_for_device(session_id.clone(), request.device_id.as_str().to_owned())
        .await
        .map_err(ApiError::from)?
    else {
        tracing::warn!(
            "agentty_backend pairing_session_status_missing device_id={} session_id={}",
            log_value(request.device_id.as_str()),
            log_value(&session_id),
        );
        return Err(ApiError::not_found("Pairing session was not found."));
    };

    tracing::info!(
        "agentty_backend pairing_session_status device_id={} session_id={} status={}",
        log_value(request.device_id.as_str()),
        log_value(&session_id),
        pairing_session.status.as_str(),
    );

    Ok(Json(pairing_session.into()))
}

async fn claim_pairing_session(
    State(state): State<AppState>,
    Json(request): Json<PairingSessionClaimRequest>,
) -> Result<Json<PairingSessionClaimResponse>, ApiError> {
    ensure_pairing_admission(&state)?;
    if request.public_key.as_str().len() > 8192 {
        return Err(ApiError::bad_request(
            "SSH public key exceeds supported bounds.",
        ));
    }
    authenticate_device_request(
        &state,
        request.device_id.as_str(),
        request.device_secret.as_str(),
    )
    .await?;

    let Some(code) = normalize_pairing_code(request.code.as_str()) else {
        return Err(ApiError::bad_request("Pairing code must be 8 characters."));
    };

    let Some(pairing_session) = state
        .database
        .claim_pairing_session(
            code,
            request.device_id.as_str().to_owned(),
            request.public_key.as_str().to_owned(),
        )
        .await
        .map_err(ApiError::from)?
    else {
        tracing::warn!("agentty_backend pairing_session_claim_rejected");
        return Err(ApiError::bad_request(
            "Invalid or unavailable pairing code.",
        ));
    };

    tracing::info!(
        "agentty_backend pairing_session_claimed device_id={} session_id={} expires_at={}",
        log_value(request.device_id.as_str()),
        log_value(&pairing_session.session_id),
        pairing_session.expires_at_epoch_seconds,
    );

    Ok(Json(pairing_session))
}

async fn host_pairing_session_status(
    State(state): State<AppState>,
    Path(session_id): Path<String>,
    Json(request): Json<PairingSessionHostStatusRequest>,
) -> Result<Json<PairingSessionHostStatusResponse>, ApiError> {
    let host_token = request.host_token.as_str().to_owned();
    match state
        .database
        .pairing_session_for_host(session_id.clone(), host_token.clone())
        .await
        .map_err(ApiError::from)?
    {
        HostPairingSessionLookupResult::Found(pairing_session) => {
            tracing::info!(
                "agentty_backend host_pairing_session_status session_id={} status={}",
                log_value(&session_id),
                pairing_session.status.as_str(),
            );
            let mut response: PairingSessionHostStatusResponse = (*pairing_session).into();
            if matches!(
                response.status,
                crate::models::PairingSessionStatus::Claimed
            ) {
                response.connector_bootstrap = state
                    .database
                    .issue_connector_bootstrap_token(session_id, host_token)
                    .await
                    .map_err(ApiError::from)?;
            }
            Ok(Json(response))
        }
        HostPairingSessionLookupResult::NotFound => {
            Err(ApiError::not_found("Pairing session was not found."))
        }
        HostPairingSessionLookupResult::InvalidHostToken => {
            Err(ApiError::unauthorized("Invalid host token."))
        }
    }
}

async fn register_connector(
    State(state): State<AppState>,
    Json(request): Json<ConnectorRegisterRequest>,
) -> Result<Json<ConnectorRegisterResponse>, ApiError> {
    if request.machine_id.as_str().len() > 256
        || request.ssh_username.as_str().len() > 256
        || request.port == 0
    {
        return Err(ApiError::bad_request("Invalid connector host details."));
    }
    let Some(record) = state
        .database
        .register_connector_from_bootstrap(
            request.bootstrap_token.as_str().to_owned(),
            request.machine_id.as_str().to_owned(),
            request.ssh_username.as_str().to_owned(),
            request.platform,
            request.port,
            request
                .existing_connector_id
                .map(|value| value.into_inner()),
            request
                .existing_connector_secret
                .map(|value| value.into_inner()),
            state.admission.dictation_limits.require_host_adoption_proof,
        )
        .await
        .map_err(ApiError::from)?
    else {
        return Err(ApiError::bad_request("Invalid connector bootstrap token."));
    };

    tracing::info!(
        "agentty_backend connector_registered relay_host_id={} connector_id={}",
        log_value(&record.relay_host_id),
        log_value(&record.connector_id),
    );

    Ok(Json(ConnectorRegisterResponse {
        connector_id: record.connector_id,
        connector_secret: record.connector_secret,
        relay_host_id: record.relay_host_id,
    }))
}

async fn issue_connector_session_token(
    State(state): State<AppState>,
    Json(request): Json<ConnectorSessionTokenRequest>,
) -> Result<Json<ConnectorSessionTokenResponse>, ApiError> {
    let Some(record) = state
        .database
        .connector_for_credentials(
            request.connector_id.as_str().to_owned(),
            request.connector_secret.as_str().to_owned(),
        )
        .await
        .map_err(ApiError::from)?
    else {
        return Err(ApiError::unauthorized("Invalid connector credentials."));
    };
    state
        .database
        .touch_connector(record.connector_id.clone())
        .await
        .map_err(ApiError::from)?;
    let issue = state.relay_tokens.issue_connector_control();
    state
        .database
        .store_relay_attach_token(
            issue.authorization_token.clone(),
            RelayTokenKind::ConnectorControl,
            record.relay_host_id.clone(),
            None,
            Some(record.connector_id.clone()),
            issue.expires_at_epoch_seconds,
        )
        .await
        .map_err(ApiError::from)?;

    tracing::info!(
        "agentty_backend connector_session_token_issued relay_host_id={} connector_id={} expires_at={}",
        log_value(&record.relay_host_id),
        log_value(&record.connector_id),
        issue.expires_at_epoch_seconds,
    );

    Ok(Json(ConnectorSessionTokenResponse {
        expires_at_epoch_seconds: issue.expires_at_epoch_seconds,
        authorization_token: issue.authorization_token,
        websocket_url: issue.websocket_url,
    }))
}

fn relay_limit_error(headers: &HeaderMap, code: &'static str, detail: &'static str) -> ApiError {
    if headers
        .get("x-agentty-resource-errors")
        .is_some_and(|value| value == "1")
    {
        ApiError::ResourceLimit { code, detail }
    } else {
        ApiError::unauthorized(detail)
    }
}

async fn create_ssh_relay_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<SshRelaySessionCreateRequest>,
) -> Result<Json<SshRelaySessionCreateResponse>, ApiError> {
    authenticate_device_request(
        &state,
        request.device_id.as_str(),
        request.device_secret.as_str(),
    )
    .await?;
    if state.relay_broker.drain_status().draining {
        return Err(relay_limit_error(
            &headers,
            "relay_maintenance",
            "Relay maintenance is in progress. Please reconnect shortly.",
        ));
    }
    if !state
        .database
        .relay_bandwidth_available(
            request.device_id.as_str().to_owned(),
            state.admission.dictation_limits.clone(),
        )
        .await
        .map_err(ApiError::from)?
    {
        return Err(relay_limit_error(
            &headers,
            "relay_bandwidth",
            "Relay data allowance reached. Use a direct SSH connection or try again after the daily reset.",
        ));
    }
    let Some(record) = state
        .database
        .create_ssh_relay_session(
            request.device_id.as_str().to_owned(),
            request.device_secret.as_str().to_owned(),
            request.relay_host_id.as_str().to_owned(),
        )
        .await
        .map_err(ApiError::from)?
    else {
        return Err(ApiError::forbidden(
            "This device is not allowed to use relay access for that host.",
        ));
    };

    if !state
        .relay_broker
        .is_connector_online(&record.relay_host_id)
    {
        tracing::warn!(
            "agentty_backend ssh_relay_session_rejected reason=connector_offline relay_host_id={} relay_session_id={} device_id={}",
            log_value(&record.relay_host_id),
            log_value(&record.relay_session_id),
            log_value(&record.device_id),
        );
        state
            .database
            .close_ssh_relay_session(
                record.relay_session_id.clone(),
                "connector_offline".to_owned(),
            )
            .await
            .map_err(ApiError::from)?;
        return Err(ApiError::forbidden(
            "Relay connector is offline for that host.",
        ));
    }

    let app_issue = state
        .relay_tokens
        .issue_app_session(&record.relay_session_id);
    let connector_issue = state
        .relay_tokens
        .issue_connector_session(&record.relay_session_id);
    state
        .database
        .store_relay_attach_token(
            app_issue.authorization_token.clone(),
            RelayTokenKind::AppSession,
            record.relay_host_id.clone(),
            Some(record.relay_session_id.clone()),
            None,
            app_issue.expires_at_epoch_seconds,
        )
        .await
        .map_err(ApiError::from)?;
    state
        .database
        .store_relay_attach_token(
            connector_issue.authorization_token.clone(),
            RelayTokenKind::ConnectorSession,
            record.relay_host_id.clone(),
            Some(record.relay_session_id.clone()),
            None,
            connector_issue.expires_at_epoch_seconds,
        )
        .await
        .map_err(ApiError::from)?;

    state
        .relay_broker
        .create_session(
            record.relay_host_id.clone(),
            record.relay_session_id.clone(),
            record.expires_at_epoch_seconds,
            connector_issue.authorization_token,
            connector_issue.websocket_url,
        )
        .map_err(|_| {
            relay_limit_error(
                &headers,
                "relay_capacity",
                "Relay session capacity reached. Please try again shortly.",
            )
        })?;

    tracing::info!(
        "agentty_backend ssh_relay_session_created relay_host_id={} relay_session_id={} device_id={} expires_at={}",
        log_value(&record.relay_host_id),
        log_value(&record.relay_session_id),
        log_value(&record.device_id),
        record.expires_at_epoch_seconds,
    );

    Ok(Json(SshRelaySessionCreateResponse {
        relay_session_id: record.relay_session_id,
        expires_at_epoch_seconds: app_issue.expires_at_epoch_seconds,
        authorization_token: app_issue.authorization_token,
        websocket_url: app_issue.websocket_url,
    }))
}

async fn connector_control_websocket(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let permit = state.admission.socket_permit()?;
    let ws = ws.max_message_size(125).max_frame_size(125);
    let is_probe = headers
        .get(CONNECTOR_CONTROL_PROBE_HEADER)
        .and_then(|value| value.to_str().ok())
        .map(|value| value == CONNECTOR_CONTROL_PROBE_VALUE)
        .unwrap_or(false);
    let Some(token) = state
        .database
        .consume_relay_attach_token(bearer_token(&headers)?, RelayTokenKind::ConnectorControl)
        .await
        .map_err(ApiError::from)?
    else {
        return Err(ApiError::unauthorized("Invalid relay websocket token."));
    };
    let Some(connector_id) = token.connector_id else {
        return Err(ApiError::unauthorized("Invalid relay websocket token."));
    };
    state
        .database
        .touch_connector(connector_id.clone())
        .await
        .map_err(ApiError::from)?;
    Ok(ws.on_upgrade(move |socket| async move {
        let _permit = permit;
        if is_probe {
            let _ = tokio::time::timeout(
                Duration::from_secs(15),
                handle_connector_control_probe_socket(socket),
            )
            .await;
        } else {
            handle_connector_control_socket(state, socket, token.relay_host_id, connector_id).await;
        }
    }))
}

async fn app_ssh_relay_session_websocket(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
    Path(relay_session_id): Path<String>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let permit = state.admission.socket_permit()?;
    let ws = ws.max_message_size(64 * 1024).max_frame_size(64 * 1024);
    let Some(token) = state
        .database
        .consume_relay_attach_token(bearer_token(&headers)?, RelayTokenKind::AppSession)
        .await
        .map_err(ApiError::from)?
    else {
        return Err(ApiError::unauthorized("Invalid relay websocket token."));
    };
    let Some(token_relay_session_id) = token.relay_session_id else {
        return Err(ApiError::unauthorized("Invalid relay websocket token."));
    };
    if token_relay_session_id != relay_session_id {
        return Err(ApiError::unauthorized("Invalid relay websocket token."));
    }
    Ok(ws.on_upgrade(move |socket| async move {
        let _permit = permit;
        handle_app_session_socket(state, socket, token_relay_session_id).await
    }))
}

async fn connector_session_websocket(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
    Path(relay_session_id): Path<String>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let permit = state.admission.socket_permit()?;
    let ws = ws.max_message_size(64 * 1024).max_frame_size(64 * 1024);
    let Some(token) = state
        .database
        .consume_relay_attach_token(bearer_token(&headers)?, RelayTokenKind::ConnectorSession)
        .await
        .map_err(ApiError::from)?
    else {
        return Err(ApiError::unauthorized("Invalid relay websocket token."));
    };
    let Some(token_relay_session_id) = token.relay_session_id else {
        return Err(ApiError::unauthorized("Invalid relay websocket token."));
    };
    if token_relay_session_id != relay_session_id {
        return Err(ApiError::unauthorized("Invalid relay websocket token."));
    }
    Ok(ws.on_upgrade(move |socket| async move {
        let _permit = permit;
        handle_connector_session_socket(state, socket, token_relay_session_id).await
    }))
}

async fn complete_pairing_session(
    State(state): State<AppState>,
    Path(session_id): Path<String>,
    Json(request): Json<PairingSessionCompleteRequest>,
) -> Result<Json<PairingSessionStatusResponse>, ApiError> {
    let host_token = request.host_token.as_str().to_owned();
    let host_token_tail = token_tail(&host_token).to_owned();
    let completion = request.into_completion();
    let result = state
        .database
        .complete_pairing_session(session_id.clone(), host_token, completion)
        .await
        .map_err(ApiError::from)?;

    match result {
        CompletePairingSessionResult::Updated(pairing_session) => {
            tracing::info!(
                "agentty_backend pairing_session_completed session_id={} status={} host_token_tail={}",
                log_value(&session_id),
                pairing_session.status.as_str(),
                host_token_tail,
            );
            Ok(Json((*pairing_session).into()))
        }
        CompletePairingSessionResult::NotFound => {
            Err(ApiError::not_found("Pairing session was not found."))
        }
        CompletePairingSessionResult::InvalidHostToken => {
            Err(ApiError::unauthorized("Invalid host token."))
        }
        CompletePairingSessionResult::Unavailable => Err(ApiError::bad_request(
            "Pairing session is no longer available.",
        )),
    }
}

async fn notify(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<NotifyRequest>,
) -> Result<StatusCode, ApiError> {
    let relay_token = bearer_token(&headers)?;
    let device = authenticate_relay_token(&state, &relay_token).await?;

    if device.apns_token.is_empty() {
        tracing::warn!(
            "agentty_backend notify_rejected attempt_id={} device_id={} reason=missing_apns_token",
            log_value(request.attempt_id.as_str()),
            log_value(&device.device_id),
        );
        return Err(ApiError::forbidden(
            "Push token unavailable for this device.",
        ));
    }

    tracing::info!(
        "agentty_backend notify_received attempt_id={} device_id={} bundle_id={} env={} source={} body_len={} tmux_window_id={} relay_token_tail={}",
        log_value(request.attempt_id.as_str()),
        log_value(&device.device_id),
        log_value(&device.bundle_id),
        log_value(device.push_environment.as_str()),
        log_value(request.source.as_str()),
        request.body.as_str().chars().count(),
        option_display(request.tmux_window_id),
        token_tail(&relay_token),
    );

    let send_request = ApnsPushRequest::agentty_notification(device, request);
    state
        .push_sender
        .send(send_request)
        .await
        .map_err(ApiError::from)?;

    Ok(StatusCode::NO_CONTENT)
}

async fn dictation_transcription(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<DictationTranscriptionRequest>,
) -> Result<Json<DictationTranscriptionResponse>, ApiError> {
    let relay_token = bearer_token(&headers)?;
    let (device, dictation) = state
        .database
        .dictation_authorization(relay_token.clone())
        .await
        .map_err(ApiError::from)?
        .ok_or_else(|| ApiError::unauthorized("Invalid dictation token."))?;
    if device.bundle_id != MAIN_BUNDLE_ID {
        return Err(ApiError::forbidden(
            "Dictation proxy is only available for the main app.",
        ));
    }
    if request.file_name.as_str().len() > 256
        || request
            .instructions
            .as_ref()
            .is_some_and(|value| value.as_str().len() > 16_000)
        || request.language_hints.len() > 8
        || request
            .language_hints
            .iter()
            .any(|value| value.as_str().len() > 16)
    {
        return Err(ApiError::bad_request(
            "Dictation metadata exceeds supported bounds.",
        ));
    }
    authorize_device(&state, &device.device_id).await?;
    let limits = &state.admission.dictation_limits;
    let subject = match dictation {
        Some((hash, tier)) => DictationSubject::Ledger {
            hash,
            monthly_seconds: tier.monthly_seconds(limits),
        },
        None => match trusted_dictation_identity(&state, &device.device_id).await? {
            Some(hash) => DictationSubject::Ledger {
                hash,
                monthly_seconds: limits.lifetime_monthly_seconds,
            },
            None => DictationSubject::LegacyDevice(device.device_id.clone()),
        },
    };
    let (audio_bytes, seconds) = parse_audio_payload(
        request.audio_base64.as_str(),
        request.mime_type.as_str(),
    )
    .map_err(|error| {
        tracing::warn!(
            "agentty_backend dictation_rejected device_id={} reason=invalid_audio detail={}",
            log_value(&device.device_id),
            error,
        );
        ApiError::bad_request("Invalid audio payload.")
    })?;
    let windows = DictationWindows::now();
    let grant = match state
        .database
        .reserve_dictation(subject.clone(), limits.clone(), windows, seconds, seconds)
        .await
        .map_err(ApiError::from)?
    {
        Ok(grant) => grant,
        Err(exhausted) if exhausted.operator_limit => {
            return Err(ApiError::forbidden(
                "The relay dictation budget is exhausted. Please try again after the daily or weekly reset.",
            ));
        }
        Err(exhausted) => {
            tracing::warn!(
                "agentty_backend dictation_rejected device_id={} reason=quota_exhausted remaining_seconds={} reset_at={}",
                log_value(&device.device_id),
                exhausted.remaining_seconds,
                exhausted.quota_resets_at_epoch_seconds,
            );
            return Err(ApiError::too_many_requests_dictation(
                exhausted.remaining_seconds,
                exhausted.quota_resets_at_epoch_seconds,
            ));
        }
    };
    let upload = SpeechUpload {
        definition: Definition::clean_transcript(),
        wav: futures_util::stream::once(async move { Ok(Bytes::from(audio_bytes)) }).boxed(),
    };
    let text = match state.speech.transcribe(upload).await {
        Ok(SpeechResponse { status, body }) if status.is_success() => {
            transcript_text(&body).map_err(ApiError::from)?
        }
        Ok(SpeechResponse { status, .. }) if status.is_client_error() => {
            return Err(ApiError::bad_request("Invalid dictation request."));
        }
        failure => {
            if let Err(error) = &failure {
                tracing::warn!("agentty_backend dictation_upstream_failed error={error:#}");
            }
            if let Err(release_error) = state
                .database
                .release_dictation(subject, windows, seconds, 0)
                .await
            {
                tracing::error!(
                    "agentty_backend dictation_quota_release_failed device_id={} error={release_error:#}",
                    log_value(&device.device_id),
                );
            }
            return Err(ApiError::Internal(anyhow::anyhow!(
                "dictation provider failed"
            )));
        }
    };
    tracing::info!(
        "agentty_backend dictation_transcribed device_id={} seconds_charged={} remaining_seconds={} relay_token_tail={}",
        log_value(&device.device_id),
        seconds,
        grant.remaining_seconds,
        token_tail(&relay_token),
    );
    Ok(Json(DictationTranscriptionResponse {
        text,
        seconds_charged: seconds,
        remaining_seconds_this_week: grant.remaining_seconds,
        quota_resets_at_epoch_seconds: grant.resets_at_epoch_seconds,
    }))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StreamRejection {
    Unauthorized,
    VerificationRequired,
    QuotaExhausted,
    ServiceLimit,
    Busy,
    InvalidRequest,
    AudioTooLong,
    UpstreamUnavailable,
}

impl StreamRejection {
    fn kind(self) -> &'static str {
        match self {
            Self::Unauthorized => "unauthorized",
            Self::VerificationRequired => "verification_required",
            Self::QuotaExhausted => "quota_exhausted",
            Self::ServiceLimit => "service_limit",
            Self::Busy => "busy",
            Self::InvalidRequest => "invalid_request",
            Self::AudioTooLong => "audio_too_long",
            Self::UpstreamUnavailable => "upstream_unavailable",
        }
    }

    fn status(self) -> StatusCode {
        match self {
            Self::Unauthorized => StatusCode::UNAUTHORIZED,
            Self::VerificationRequired => StatusCode::FORBIDDEN,
            Self::QuotaExhausted | Self::Busy => StatusCode::TOO_MANY_REQUESTS,
            Self::ServiceLimit => StatusCode::SERVICE_UNAVAILABLE,
            Self::InvalidRequest => StatusCode::BAD_REQUEST,
            Self::AudioTooLong => StatusCode::PAYLOAD_TOO_LARGE,
            Self::UpstreamUnavailable => StatusCode::BAD_GATEWAY,
        }
    }
}

impl IntoResponse for StreamRejection {
    fn into_response(self) -> Response {
        (
            self.status(),
            [(
                HeaderName::from_static("x-speech-relay-rejection"),
                HeaderValue::from_static(self.kind()),
            )],
            Json(json!({ "code": self.kind() })),
        )
            .into_response()
    }
}

struct AbortOnDrop<T>(tokio::task::JoinHandle<T>);

impl<T> Drop for AbortOnDrop<T> {
    fn drop(&mut self) {
        self.0.abort();
    }
}

enum StreamChunk {
    Audio(Bytes),
    End,
}

fn stream_audio(receiver: mpsc::Receiver<StreamChunk>) -> AudioStream {
    let pcm = futures_util::stream::unfold(Some(receiver), |receiver| async move {
        let mut receiver = receiver?;
        match receiver.recv().await {
            Some(StreamChunk::Audio(bytes)) => Some((Ok(bytes), Some(receiver))),
            Some(StreamChunk::End) => None,
            None => Some((
                Err(std::io::Error::other("dictation audio ended early")),
                None,
            )),
        }
    });
    futures_util::stream::once(async { Ok(open_stream_wav_header()) })
        .chain(pcm)
        .boxed()
}

struct StreamMeter {
    database: crate::storage::Database,
    limits: crate::config::DictationLimits,
    subject: DictationSubject,
    windows: DictationWindows,
    reserved_seconds: i64,
    audio_bytes: u64,
    settled: bool,
}

impl StreamMeter {
    fn charged_seconds(&self) -> i64 {
        self.audio_bytes.div_ceil(STREAM_BYTES_PER_SECOND) as i64
    }

    async fn admit(&mut self, bytes: usize) -> Result<(), StreamRejection> {
        let total = self.audio_bytes + bytes as u64;
        if total > DICTATION_STREAM_MAX_SECONDS * STREAM_BYTES_PER_SECOND {
            return Err(StreamRejection::AudioTooLong);
        }
        let needed = total.div_ceil(STREAM_BYTES_PER_SECOND) as i64;
        if needed > self.reserved_seconds {
            let deficit = needed - self.reserved_seconds;
            self.reserved_seconds += self
                .reserve(deficit, deficit.max(DICTATION_STREAM_RESERVATION_SECONDS))
                .await?;
        }
        self.audio_bytes = total;
        Ok(())
    }

    async fn reserve(&self, minimum: i64, preferred: i64) -> Result<i64, StreamRejection> {
        match self
            .database
            .reserve_dictation(
                self.subject.clone(),
                self.limits.clone(),
                self.windows,
                minimum,
                preferred,
            )
            .await
        {
            Ok(Ok(grant)) => Ok(grant.seconds),
            Ok(Err(exhausted)) if exhausted.operator_limit => Err(StreamRejection::ServiceLimit),
            Ok(Err(_)) => Err(StreamRejection::QuotaExhausted),
            Err(error) => {
                tracing::error!("agentty_backend dictation_reservation_failed error={error:#}");
                Err(StreamRejection::UpstreamUnavailable)
            }
        }
    }

    async fn settle(mut self, refund_audio: bool) {
        self.settled = true;
        let charged = self.charged_seconds();
        let unused = self.reserved_seconds - charged;
        let personal = unused + if refund_audio { charged } else { 0 };
        if let Err(error) = self
            .database
            .release_dictation(self.subject.clone(), self.windows, personal, unused)
            .await
        {
            tracing::error!("agentty_backend dictation_settlement_failed error={error:#}");
        }
    }
}

impl Drop for StreamMeter {
    fn drop(&mut self) {
        if self.settled {
            return;
        }
        let unused = self.reserved_seconds - self.charged_seconds();
        let database = self.database.clone();
        let subject = self.subject.clone();
        let windows = self.windows;
        tokio::spawn(async move {
            if let Err(error) = database
                .release_dictation(subject, windows, unused, unused)
                .await
            {
                tracing::error!("agentty_backend dictation_settlement_failed error={error:#}");
            }
        });
    }
}

async fn dictation_stream(
    State(state): State<AppState>,
    headers: HeaderMap,
    request: Request,
) -> Response {
    match relay_dictation_stream(state, headers, request).await {
        Ok(response) => response,
        Err(rejection) => rejection.into_response(),
    }
}

async fn relay_dictation_stream(
    state: AppState,
    headers: HeaderMap,
    request: Request,
) -> Result<Response, StreamRejection> {
    let deadline = tokio::time::Instant::now() + DICTATION_STREAM_DEADLINE;
    let token = bearer_token(&headers).map_err(|_| StreamRejection::Unauthorized)?;
    let (device, dictation) = state
        .database
        .dictation_authorization(token)
        .await
        .map_err(|_| StreamRejection::UpstreamUnavailable)?
        .ok_or(StreamRejection::Unauthorized)?;
    if device.bundle_id != MAIN_BUNDLE_ID {
        return Err(StreamRejection::VerificationRequired);
    }
    authorize_device(&state, &device.device_id)
        .await
        .map_err(|error| match error {
            ApiError::ResourceLimit { .. } => StreamRejection::Busy,
            _ => StreamRejection::VerificationRequired,
        })?;
    let limits = state.admission.dictation_limits.clone();
    let (hash, tier) = match dictation {
        Some(dictation) => dictation,
        None => (
            trusted_dictation_identity(&state, &device.device_id)
                .await
                .map_err(|_| StreamRejection::UpstreamUnavailable)?
                .ok_or(StreamRejection::VerificationRequired)?,
            DictationTier::Lifetime,
        ),
    };
    let _permit = state
        .admission
        .begin_dictation_stream(&hash)
        .ok_or(StreamRejection::Busy)?;
    let mut multipart = Multipart::from_request(request, &())
        .await
        .map_err(|_| StreamRejection::InvalidRequest)?;
    let definition = {
        let mut field = next_stream_field(&mut multipart, deadline, "definition").await?;
        let mut json = Vec::new();
        while let Some(chunk) = next_stream_chunk(&mut field, deadline).await? {
            if json.len() + chunk.len() > MAX_DICTATION_DEFINITION_BYTES {
                return Err(StreamRejection::InvalidRequest);
            }
            json.extend_from_slice(&chunk);
        }
        Definition::parse(&json).map_err(|_| StreamRejection::InvalidRequest)?
    };
    let mut audio = next_stream_field(&mut multipart, deadline, "audio").await?;
    let mut header = Vec::with_capacity(WAV_HEADER_BYTES);
    while header.len() < WAV_HEADER_BYTES {
        let chunk = next_stream_chunk(&mut audio, deadline)
            .await?
            .ok_or(StreamRejection::InvalidRequest)?;
        header.extend_from_slice(&chunk);
    }
    let first_audio = Bytes::from(header.split_off(WAV_HEADER_BYTES));
    let declared_length =
        parse_stream_wav_header(&header).map_err(|_| StreamRejection::InvalidRequest)?;
    let windows = DictationWindows::now();
    let mut meter = StreamMeter {
        database: state.database.clone(),
        subject: DictationSubject::Ledger {
            hash,
            monthly_seconds: tier.monthly_seconds(&limits),
        },
        limits,
        windows,
        reserved_seconds: 0,
        audio_bytes: 0,
        settled: false,
    };
    meter.reserved_seconds = meter
        .reserve(1, DICTATION_STREAM_RESERVATION_SECONDS)
        .await?;
    let (sender, receiver) = mpsc::channel(16);
    let upload = SpeechUpload {
        definition,
        wav: stream_audio(receiver),
    };
    let speech = state.speech.clone();
    let mut upstream = AbortOnDrop(tokio::spawn(async move { speech.transcribe(upload).await }));
    let fed = match feed_dictation_audio(
        audio,
        first_audio,
        declared_length,
        &sender,
        &mut meter,
        deadline,
    )
    .await
    {
        Ok(()) => finish_dictation_upload(&mut multipart, &sender, deadline).await,
        Err(error) => Err(error),
    };
    let upstream_result = match fed {
        Ok(()) => tokio::time::timeout(DICTATION_UPSTREAM_RESPONSE_TIMEOUT, &mut upstream.0)
            .await
            .ok(),
        Err(FeedError::UpstreamClosed) => {
            tokio::time::timeout(DICTATION_UPSTREAM_RESPONSE_TIMEOUT, &mut upstream.0)
                .await
                .ok()
        }
        Err(FeedError::UpstreamStalled) => None,
        Err(FeedError::Rejected(rejection)) => {
            upstream.0.abort();
            tracing::warn!(
                "agentty_backend dictation_stream_rejected device_id={} reason={} seconds={}",
                log_value(&device.device_id),
                rejection.kind(),
                meter.charged_seconds(),
            );
            meter.settle(false).await;
            return Err(rejection);
        }
    };
    let response = match upstream_result {
        Some(Ok(Ok(response))) => Ok(response),
        Some(Ok(Err(SpeechUpstreamUnavailable(error)))) => Err(error),
        Some(Err(error)) => Err(error.into()),
        None => Err(anyhow::anyhow!("speech upstream timed out")),
    };
    let seconds = meter.charged_seconds();
    match response {
        Ok(SpeechResponse { status, body }) => {
            meter.settle(status.is_server_error()).await;
            tracing::info!(
                "agentty_backend dictation_stream_finished device_id={} status={} seconds={}",
                log_value(&device.device_id),
                status.as_u16(),
                seconds,
            );
            let body = if status.is_success() {
                body
            } else {
                Bytes::from_static(b"{}")
            };
            Ok((status, [(header::CONTENT_TYPE, "application/json")], body).into_response())
        }
        Err(error) => {
            meter.settle(true).await;
            tracing::warn!(
                "agentty_backend dictation_stream_upstream_failed device_id={} seconds={} error={error:#}",
                log_value(&device.device_id),
                seconds,
            );
            Err(StreamRejection::UpstreamUnavailable)
        }
    }
}

enum FeedError {
    Rejected(StreamRejection),
    UpstreamClosed,
    UpstreamStalled,
}

impl From<StreamRejection> for FeedError {
    fn from(rejection: StreamRejection) -> Self {
        Self::Rejected(rejection)
    }
}

async fn feed_dictation_audio(
    mut audio: axum::extract::multipart::Field<'_>,
    first_audio: Bytes,
    declared_length: StreamWavLength,
    sender: &mpsc::Sender<StreamChunk>,
    meter: &mut StreamMeter,
    deadline: tokio::time::Instant,
) -> Result<(), FeedError> {
    let mut pending = Some(first_audio).filter(|bytes| !bytes.is_empty());
    loop {
        let chunk = match pending.take() {
            Some(chunk) => chunk,
            None => match next_stream_chunk(&mut audio, deadline).await? {
                Some(chunk) => chunk,
                None => break,
            },
        };
        meter.admit(chunk.len()).await?;
        send_upstream(sender, StreamChunk::Audio(chunk), deadline).await?;
    }
    let complete = meter.audio_bytes > 0
        && meter.audio_bytes.is_multiple_of(2)
        && match declared_length {
            StreamWavLength::Open => true,
            StreamWavLength::Exact(length) => length == meter.audio_bytes,
        };
    if complete {
        Ok(())
    } else {
        Err(StreamRejection::InvalidRequest.into())
    }
}

async fn finish_dictation_upload(
    multipart: &mut Multipart,
    sender: &mpsc::Sender<StreamChunk>,
    deadline: tokio::time::Instant,
) -> Result<(), FeedError> {
    if tokio::time::timeout_at(deadline, multipart.next_field())
        .await
        .map_err(|_| StreamRejection::InvalidRequest)?
        .map_err(|_| StreamRejection::InvalidRequest)?
        .is_some()
    {
        return Err(StreamRejection::InvalidRequest.into());
    }
    send_upstream(sender, StreamChunk::End, deadline).await
}

async fn send_upstream(
    sender: &mpsc::Sender<StreamChunk>,
    chunk: StreamChunk,
    deadline: tokio::time::Instant,
) -> Result<(), FeedError> {
    let idle = (tokio::time::Instant::now() + DICTATION_STREAM_IDLE).min(deadline);
    match tokio::time::timeout_at(idle, sender.send(chunk)).await {
        Ok(Ok(())) => Ok(()),
        Ok(Err(_)) => Err(FeedError::UpstreamClosed),
        Err(_) => Err(FeedError::UpstreamStalled),
    }
}

async fn next_stream_field<'a>(
    multipart: &'a mut Multipart,
    deadline: tokio::time::Instant,
    name: &str,
) -> Result<axum::extract::multipart::Field<'a>, StreamRejection> {
    let idle = (tokio::time::Instant::now() + DICTATION_STREAM_IDLE).min(deadline);
    let field = tokio::time::timeout_at(idle, multipart.next_field())
        .await
        .map_err(|_| StreamRejection::InvalidRequest)?
        .map_err(|_| StreamRejection::InvalidRequest)?
        .ok_or(StreamRejection::InvalidRequest)?;
    if field.name() != Some(name) {
        return Err(StreamRejection::InvalidRequest);
    }
    Ok(field)
}

async fn next_stream_chunk(
    field: &mut axum::extract::multipart::Field<'_>,
    deadline: tokio::time::Instant,
) -> Result<Option<Bytes>, StreamRejection> {
    let idle = (tokio::time::Instant::now() + DICTATION_STREAM_IDLE).min(deadline);
    tokio::time::timeout_at(idle, field.chunk())
        .await
        .map_err(|_| StreamRejection::InvalidRequest)?
        .map_err(|_| StreamRejection::InvalidRequest)
}

async fn trusted_dictation_identity(
    state: &AppState,
    device_id: &str,
) -> Result<Option<String>, ApiError> {
    let Some((secret_hash, _)) = state
        .database
        .device_admission(device_id.to_owned())
        .await
        .map_err(ApiError::from)?
    else {
        return Ok(None);
    };
    let trusted = state
        .admission
        .dictation_limits
        .trusted_devices
        .iter()
        .any(|(id, expected)| {
            id == device_id
                && expected
                    .as_bytes()
                    .ct_eq(secret_hash.as_bytes())
                    .unwrap_u8()
                    == 1
        });
    Ok(trusted.then(|| crate::storage::hash_text(&format!("trusted:{device_id}"))))
}

async fn internal_alert(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<InternalAlertRequest>,
) -> Result<Json<BrokerSendResponse>, ApiError> {
    request.validate().map_err(ApiError::from)?;
    let caller = authenticate_internal_caller(&state, &headers, PushType::Alert)?;

    if !caller.caller.allows_topic(request.topic.as_str()) {
        tracing::warn!(
            "agentty_backend internal_alert_rejected caller={} topic={} reason=disallowed_topic",
            caller.caller.as_str(),
            log_value(request.topic.as_str()),
        );
        return Err(ApiError::forbidden(
            "Caller not allowed to send to this topic.",
        ));
    }

    tracing::info!(
        "agentty_backend internal_alert_received caller={} topic={} env={} body_len={} mutable_content={} collapse_id={} device_token_tail={}",
        caller.caller.as_str(),
        log_value(request.topic.as_str()),
        request.push_environment.as_str(),
        request.body.as_str().chars().count(),
        request.mutable_content,
        request
            .collapse_id
            .as_ref()
            .map(|value| log_value(value.as_str()))
            .unwrap_or_else(|| "none".to_owned()),
        token_tail(request.device_token.as_str()),
    );

    let result = send_and_wrap_response(
        &state.push_sender,
        ApnsPushRequest::internal_alert(caller.caller, request),
    )
    .await?;

    Ok(Json(result))
}

async fn internal_live_activity(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<InternalLiveActivityRequest>,
) -> Result<Json<BrokerSendResponse>, ApiError> {
    request.validate().map_err(ApiError::from)?;
    let caller = authenticate_internal_caller(&state, &headers, PushType::LiveActivity)?;

    if !caller.caller.allows_topic(request.bundle_id.as_str()) {
        tracing::warn!(
            "agentty_backend internal_live_activity_rejected caller={} bundle_id={} reason=disallowed_topic",
            caller.caller.as_str(),
            log_value(request.bundle_id.as_str()),
        );
        return Err(ApiError::forbidden(
            "Caller not allowed to send to this topic.",
        ));
    }

    let topic = request.live_activity_topic();
    tracing::info!(
        "agentty_backend internal_live_activity_received caller={} topic={} env={} event={} device_token_tail={}",
        caller.caller.as_str(),
        log_value(&topic),
        request.push_environment.as_str(),
        request.event.as_str(),
        token_tail(request.device_token.as_str()),
    );

    let result = send_and_wrap_response(
        &state.push_sender,
        ApnsPushRequest::internal_live_activity(caller.caller, request),
    )
    .await?;

    Ok(Json(result))
}

async fn internal_location(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<InternalLocationRequest>,
) -> Result<Json<BrokerSendResponse>, ApiError> {
    request.validate().map_err(ApiError::from)?;
    let caller = authenticate_internal_caller(&state, &headers, PushType::Location)?;

    if !caller.caller.allows_topic(request.bundle_id.as_str()) {
        tracing::warn!(
            "agentty_backend internal_location_rejected caller={} bundle_id={} reason=disallowed_topic",
            caller.caller.as_str(),
            log_value(request.bundle_id.as_str()),
        );
        return Err(ApiError::forbidden(
            "Caller not allowed to send to this topic.",
        ));
    }

    let topic = request.topic();
    tracing::info!(
        "agentty_backend internal_location_received caller={} topic={} env={} expiration={} device_token_tail={}",
        caller.caller.as_str(),
        log_value(&topic),
        request.push_environment.as_str(),
        request.expiration,
        token_tail(request.device_token.as_str()),
    );

    let result = send_and_wrap_response(
        &state.push_sender,
        ApnsPushRequest::internal_location(caller.caller, request),
    )
    .await?;

    Ok(Json(result))
}

async fn internal_voip(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<InternalVoipRequest>,
) -> Result<Json<BrokerSendResponse>, ApiError> {
    request.validate().map_err(ApiError::from)?;
    let caller = authenticate_internal_caller(&state, &headers, PushType::Voip)?;
    if !caller.caller.allows_topic(request.bundle_id.as_str()) {
        tracing::warn!(
            caller = caller.caller.as_str(),
            "internal_voip rejected: disallowed topic"
        );
        return Err(ApiError::forbidden(
            "Caller not allowed to send to this topic.",
        ));
    }
    tracing::info!(caller = caller.caller.as_str(), call_id = %request.call_id,
        host_id = %request.host_id, environment = request.push_environment.as_str(),
        "internal_voip received");
    let result = send_and_wrap_response(
        &state.push_sender,
        ApnsPushRequest::internal_voip(caller.caller, request),
    )
    .await?;
    Ok(Json(result))
}

async fn send_and_wrap_response(
    push_sender: &std::sync::Arc<dyn PushSender>,
    request: ApnsPushRequest,
) -> Result<BrokerSendResponse, ApiError> {
    let push_environment = request.push_environment;
    let push_type = request.push_type;
    let topic = request.topic.clone();
    let PushSendSuccess { apns_id } = push_sender.send(request).await.map_err(ApiError::from)?;

    Ok(BrokerSendResponse {
        status: "sent",
        apns_id,
        push_environment,
        push_type,
        topic,
    })
}

fn authenticate_internal_caller<'a>(
    state: &'a AppState,
    headers: &HeaderMap,
    push_type: PushType,
) -> Result<&'a InternalClientSettings, ApiError> {
    let token = bearer_token(headers)?;
    let Some(client) = state
        .internal_clients
        .iter()
        .find(|client| client.token.as_bytes().ct_eq(token.as_bytes()).unwrap_u8() == 1)
    else {
        tracing::warn!(
            "agentty_backend internal_auth_rejected push_type={}",
            push_type.as_str(),
        );
        return Err(ApiError::unauthorized("Invalid internal broker token."));
    };

    if !client.caller.allows_push_type(push_type) {
        tracing::warn!(
            "agentty_backend internal_auth_rejected caller={} push_type={} reason=disallowed_push_type",
            client.caller.as_str(),
            push_type.as_str(),
        );
        return Err(ApiError::forbidden(
            "Caller not allowed to send this push type.",
        ));
    }

    Ok(client)
}

fn bearer_token(headers: &HeaderMap) -> Result<String, ApiError> {
    let authorization = headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .filter(|value| value.starts_with("Bearer "))
        .ok_or_else(|| ApiError::unauthorized("Missing bearer token."))?;

    authorization
        .strip_prefix("Bearer ")
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| ApiError::unauthorized("Missing bearer token."))
}

async fn registration_admission(
    state: &AppState,
    device_id: &str,
    secret: &str,
    signed: Option<&str>,
) -> Result<Option<String>, ApiError> {
    if let Some((stored_hash, _)) = state
        .database
        .device_admission(device_id.to_owned())
        .await
        .map_err(ApiError::from)?
    {
        if stored_hash
            .as_bytes()
            .ct_eq(hash_text(secret).as_bytes())
            .unwrap_u8()
            != 1
        {
            return Err(ApiError::unauthorized("Invalid device credentials."));
        }
    }
    if let Some(signed) = signed {
        let app_id = state.admission.dictation_limits.app_apple_id;
        if app_id == 0 {
            return Err(ApiError::forbidden(
                "App Store admission is not configured.",
            ));
        }
        let signed = signed.to_owned();
        let app =
            tokio::task::spawn_blocking(move || crate::app_transaction::verify(&signed, app_id))
                .await
                .map_err(|error| ApiError::from(anyhow::Error::from(error)))?
                .map_err(|_| ApiError::unauthorized("Invalid signed app transaction."))?;
        return Ok(Some(app.identity));
    }
    let trusted = state
        .admission
        .dictation_limits
        .trusted_devices
        .iter()
        .any(|(id, hash)| {
            id == &device_id.to_ascii_lowercase()
                && hash
                    .as_bytes()
                    .ct_eq(hash_text(secret).as_bytes())
                    .unwrap_u8()
                    == 1
        });
    if trusted {
        if !state.admission.admit_device(device_id) {
            return Err(ApiError::ResourceLimit {
                code: "device_request_limit",
                detail: "Device request limit reached. Please try again shortly.",
            });
        }
        return Ok(None);
    }
    if !state.admission.dictation_limits.require_verified_devices {
        return Ok(None);
    }
    authorize_device(state, device_id).await?;
    Ok(None)
}

async fn authorize_device(state: &AppState, device_id: &str) -> Result<(), ApiError> {
    let Some((secret_hash, identity)) = state
        .database
        .device_admission(device_id.to_owned())
        .await
        .map_err(ApiError::from)?
    else {
        return Err(ApiError::forbidden(
            "This relay requires a verified App Store installation or an operator-authorized device.",
        ));
    };
    let trusted = state
        .admission
        .dictation_limits
        .trusted_devices
        .iter()
        .any(|(id, hash)| {
            id == &device_id.to_ascii_lowercase()
                && hash.as_bytes().ct_eq(secret_hash.as_bytes()).unwrap_u8() == 1
        });
    if !trusted && identity.is_none() && state.admission.dictation_limits.require_verified_devices {
        return Err(ApiError::forbidden(
            "This relay requires a verified App Store installation or an operator-authorized device. Please update AgenTTY.",
        ));
    }
    if !state.admission.admit_device(device_id) {
        return Err(ApiError::ResourceLimit {
            code: "device_request_limit",
            detail: "Device request limit reached. Please try again shortly.",
        });
    }
    Ok(())
}

async fn authenticate_relay_token(
    state: &AppState,
    relay_token: &str,
) -> Result<crate::models::DeviceRecord, ApiError> {
    let Some(device) = state
        .database
        .get_device_for_relay_token(relay_token)
        .await
        .map_err(ApiError::from)?
    else {
        tracing::warn!(
            "agentty_backend relay_token_rejected tail={}",
            token_tail(relay_token),
        );
        return Err(ApiError::unauthorized("Invalid relay token."));
    };

    authorize_device(state, &device.device_id).await?;
    Ok(device)
}

async fn authenticate_device_request(
    state: &AppState,
    device_id: &str,
    device_secret: &str,
) -> Result<(), ApiError> {
    authenticate_device_credentials(state, device_id, device_secret).await?;
    authorize_device(state, device_id).await
}

async fn authenticate_device_credentials(
    state: &AppState,
    device_id: &str,
    device_secret: &str,
) -> Result<(), ApiError> {
    let authenticated = state
        .database
        .authenticate_device_credentials(device_id.to_owned(), device_secret.to_owned())
        .await
        .map_err(ApiError::from)?;

    if authenticated {
        Ok(())
    } else {
        tracing::warn!(
            "agentty_backend device_auth_rejected device_id={}",
            log_value(device_id),
        );
        Err(ApiError::unauthorized("Invalid device credentials."))
    }
}

async fn issue_relay_session_for_request(
    state: &AppState,
    request: &RelaySessionRequest,
) -> Result<crate::models::RelaySessionResponse, ApiError> {
    authenticate_device_request(
        state,
        request.device_id.as_str(),
        request.device_secret.as_str(),
    )
    .await?;
    let Some(relay_session) = state
        .database
        .issue_relay_session(
            request.device_id.as_str().to_owned(),
            request.device_secret.as_str().to_owned(),
            match request.scope {
                crate::models::NotificationTokenScope::Legacy => "legacy",
                crate::models::NotificationTokenScope::Notify => "notify",
            }
            .to_owned(),
            None,
        )
        .await
        .map_err(ApiError::from)?
    else {
        tracing::warn!(
            "agentty_backend relay_session_rejected device_id={}",
            request.device_id
        );
        return Err(ApiError::unauthorized("Invalid device credentials."));
    };

    Ok(relay_session)
}

#[derive(Clone, Copy)]
enum RelaySessionSocketSide {
    App,
    Connector,
}

impl RelaySessionSocketSide {
    fn attach(
        self,
        state: &AppState,
        relay_session_id: &str,
        session_tx: crate::relay_broker::RelayPeerTx,
    ) -> Result<(), RelayBrokerError> {
        match self {
            Self::App => state.relay_broker.attach_app(relay_session_id, session_tx),
            Self::Connector => state
                .relay_broker
                .attach_connector(relay_session_id, session_tx),
        }
    }

    fn forward(
        self,
        state: &AppState,
        relay_session_id: &str,
        data: Vec<u8>,
    ) -> Result<(), RelayBrokerError> {
        match self {
            Self::App => state.relay_broker.forward_from_app(relay_session_id, data),
            Self::Connector => state
                .relay_broker
                .forward_from_connector(relay_session_id, data),
        }
    }

    fn close_reason(self) -> &'static str {
        match self {
            Self::App => "app_socket_closed",
            Self::Connector => "connector_socket_closed",
        }
    }

    fn socket_error_reason(self) -> &'static str {
        match self {
            Self::App => "app_socket_error",
            Self::Connector => "connector_socket_error",
        }
    }

    fn peer_closed_reason(self) -> &'static str {
        match self {
            Self::App => "connector_socket_closed",
            Self::Connector => "app_socket_closed",
        }
    }

    fn forward_error_reason(self, error: RelayBrokerError) -> &'static str {
        match error {
            RelayBrokerError::Draining => "relay_maintenance",
            RelayBrokerError::CapacityReached => "relay_session_capacity",
            RelayBrokerError::BufferLimitExceeded => "relay_buffer_limit",
            RelayBrokerError::PeerClosed => self.peer_closed_reason(),
            RelayBrokerError::SessionNotFound => "relay_session_missing",
            RelayBrokerError::AlreadyAttached => "relay_session_already_attached",
        }
    }
}

async fn handle_connector_control_socket(
    state: AppState,
    socket: WebSocket,
    relay_host_id: String,
    connector_id: String,
) {
    let (mut sink, mut stream) = socket.split();
    let (control_tx, mut control_rx) = mpsc::unbounded_channel();
    let control_connection_id = state.relay_broker.register_connector_control(
        relay_host_id.clone(),
        connector_id.clone(),
        control_tx,
    );
    let connected_at = Instant::now();
    tracing::info!(
        "agentty_backend connector_control_connected relay_host_id={} connector_id={} connection_id={}",
        log_value(&relay_host_id),
        log_value(&connector_id),
        control_connection_id,
    );

    let writer = async move {
        let mut heartbeat = interval(CONNECTOR_CONTROL_HEARTBEAT_INTERVAL);
        heartbeat.set_missed_tick_behavior(MissedTickBehavior::Delay);
        heartbeat.tick().await;

        loop {
            tokio::select! {
                _ = heartbeat.tick() => {
                    if sink.send(Message::Ping(Vec::new().into())).await.is_err() {
                        return "heartbeat_write_failed";
                    }
                }
                next_control_message = control_rx.recv() => {
                    let Some(control_message) = next_control_message else {
                        return "control_channel_closed";
                    };
                    let Ok(encoded_message) = serde_json::to_string(&control_message) else {
                        return "control_encode_failed";
                    };
                    if sink.send(Message::Text(encoded_message.into())).await.is_err() {
                        return "control_write_failed";
                    }
                }
            }
        }
    };

    let reader = async move {
        let mut heartbeats = (Instant::now(), 0);
        while let Some(next_message) = stream.next().await {
            match next_message {
                Ok(Message::Close(_)) => return "peer_close",
                Ok(Message::Ping(_)) | Ok(Message::Pong(_)) => {
                    if !admit_heartbeat(&mut heartbeats) {
                        return "heartbeat_limit";
                    }
                }
                Ok(Message::Text(_)) | Ok(Message::Binary(_)) => {
                    return "unsupported_control_message";
                }
                Err(_) => return "read_failed",
            }
        }
        "peer_eof"
    };

    let disconnect_reason = tokio::select! {
        reason = writer => reason,
        reason = reader => reason,
    };
    state
        .relay_broker
        .unregister_connector_control(&relay_host_id, control_connection_id);
    tracing::info!(
        "agentty_backend connector_control_disconnected relay_host_id={} connector_id={} connection_id={} connected_for_ms={} reason={}",
        log_value(&relay_host_id),
        log_value(&connector_id),
        control_connection_id,
        connected_at.elapsed().as_millis(),
        disconnect_reason,
    );
}

async fn handle_connector_control_probe_socket(socket: WebSocket) {
    let (_sink, mut stream) = socket.split();
    let mut heartbeats = (Instant::now(), 0);
    while let Some(next_message) = stream.next().await {
        match next_message {
            Ok(Message::Close(_)) => break,
            Ok(Message::Ping(_)) | Ok(Message::Pong(_)) => {
                if !admit_heartbeat(&mut heartbeats) {
                    break;
                }
            }
            Ok(Message::Text(_)) | Ok(Message::Binary(_)) => break,
            Err(_) => break,
        }
    }
}

async fn handle_app_session_socket(state: AppState, socket: WebSocket, relay_session_id: String) {
    handle_relay_session_socket(state, socket, relay_session_id, RelaySessionSocketSide::App).await;
}

async fn handle_connector_session_socket(
    state: AppState,
    socket: WebSocket,
    relay_session_id: String,
) {
    handle_relay_session_socket(
        state,
        socket,
        relay_session_id,
        RelaySessionSocketSide::Connector,
    )
    .await;
}

async fn handle_relay_session_socket(
    state: AppState,
    socket: WebSocket,
    relay_session_id: String,
    side: RelaySessionSocketSide,
) {
    let (mut sink, mut stream) = socket.split();
    let (session_tx, mut session_rx) = relay_peer_channel();
    if side
        .attach(&state, &relay_session_id, session_tx.clone())
        .is_err()
    {
        let _ = sink.send(Message::Close(None)).await;
        return;
    }

    let writer_tx = session_tx.clone();
    let writer = tokio::spawn(async move {
        while let Some(outbound_message) = session_rx.recv().await {
            let send_result = sink.send(outbound_message.message).await;
            writer_tx.release_queue_bytes(outbound_message.byte_cost);
            if send_result.is_err() {
                break;
            }
        }
    });

    let mut heartbeats = (Instant::now(), 0);
    let close_reason = loop {
        match stream.next().await {
            Some(Ok(Message::Binary(data))) => {
                if data.is_empty() {
                    break "empty_relay_message".to_owned();
                }
                match state
                    .database
                    .charge_relay_bandwidth(
                        relay_session_id.clone(),
                        data.len().max(256),
                        state.admission.dictation_limits.clone(),
                    )
                    .await
                {
                    Ok(true) => {}
                    Ok(false) => break "relay_bandwidth_limit".to_owned(),
                    Err(error) => {
                        tracing::error!("relay bandwidth admission failed: {error:#}");
                        break "relay_bandwidth_unavailable".to_owned();
                    }
                }
                if let Err(error) = side.forward(&state, &relay_session_id, data.to_vec()) {
                    break side.forward_error_reason(error).to_owned();
                }
            }
            Some(Ok(Message::Close(_))) | None => break side.close_reason().to_owned(),
            Some(Ok(Message::Ping(_))) | Some(Ok(Message::Pong(_))) => {
                if !admit_heartbeat(&mut heartbeats) {
                    break "heartbeat_limit".to_owned();
                }
            }
            Some(Ok(Message::Text(_))) => break "unsupported_relay_message".to_owned(),
            Some(Err(_)) => break side.socket_error_reason().to_owned(),
        }
    };

    writer.abort();
    state
        .relay_broker
        .close_session(&relay_session_id, &close_reason);
    let _ = state
        .database
        .close_ssh_relay_session(relay_session_id, close_reason)
        .await;
}

fn ensure_pairing_admission(state: &AppState) -> Result<(), ApiError> {
    if state.relay_broker.drain_status().draining {
        Err(ApiError::ResourceLimit {
            code: "relay_maintenance",
            detail: "Relay maintenance is in progress. Please try pairing again shortly.",
        })
    } else {
        Ok(())
    }
}

fn admit_heartbeat(window: &mut (Instant, u32)) -> bool {
    if window.0.elapsed() >= Duration::from_secs(60) {
        *window = (Instant::now(), 0);
    }
    if window.1 >= 64 {
        return false;
    }
    window.1 += 1;
    true
}
