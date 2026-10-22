use std::time::{Duration, Instant};

use axum::Json;
use axum::Router;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::Response;
use axum::routing::{get, post};
use futures_util::{SinkExt, StreamExt};
use serde_json::json;
use subtle::ConstantTimeEq;
use tokio::sync::mpsc;
use tokio::time::{MissedTickBehavior, interval};

use crate::AppState;
use crate::activity_transport::{
    ActivityChannelRequest, ActivityDispatchRequest, ActivityTransportResponse,
};
use crate::apns::{ApnsPushRequest, PushSendSuccess, PushSender};
use crate::build_info;
use crate::config::InternalClientSettings;
use crate::dictation::{
    DictationTranscriberError, DictationTranscriptionInput, parse_audio_payload,
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
        .route(
            "/v1/internal/live-activity/dispatch",
            post(dispatch_live_activity).layer(DefaultBodyLimit::max(16 * 1024)),
        )
        .route(
            "/v1/internal/live-activity/channels",
            post(manage_live_activity_channel).layer(DefaultBodyLimit::max(4 * 1024)),
        )
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
    let app_id = state.admission.dictation_limits.app_apple_id;
    if app_id == 0 {
        return Err(ApiError::forbidden(
            "App Store dictation admission is not configured.",
        ));
    }
    let signed = request.signed_app_transaction.into_inner();
    let identity =
        tokio::task::spawn_blocking(move || crate::app_transaction::verify(&signed, app_id))
            .await
            .map_err(|error| ApiError::from(anyhow::Error::from(error)))?
            .map_err(|_| ApiError::unauthorized("Invalid signed app transaction."))?;
    state
        .database
        .admit_verified_device(request.device_id.as_str().to_owned(), identity.clone())
        .await
        .map_err(ApiError::from)?;
    authorize_device(&state, request.device_id.as_str()).await?;
    let session = state
        .database
        .issue_relay_session(
            request.device_id.into_inner(),
            request.device_secret.into_inner(),
            "dictation".to_owned(),
            Some(identity),
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
    let (device, mut identity) = state
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
    if identity.is_none() {
        if let Some((secret_hash, _)) = state
            .database
            .device_admission(device.device_id.clone())
            .await
            .map_err(ApiError::from)?
        {
            let trusted =
                state
                    .admission
                    .dictation_limits
                    .trusted_devices
                    .iter()
                    .any(|(id, expected)| {
                        id == &device.device_id
                            && expected
                                .as_bytes()
                                .ct_eq(secret_hash.as_bytes())
                                .unwrap_u8()
                                == 1
                    });
            if trusted {
                identity = Some(hash_text(&format!("trusted:{}", device.device_id)));
            }
        }
    }
    let content_length = headers
        .get(header::CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<usize>().ok());

    let (audio_bytes, charge_window) = parse_audio_payload(
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

    tracing::info!(
        "agentty_backend dictation_received device_id={} content_length={} audio_bytes={} charged_seconds={} relay_token_tail={}",
        log_value(&device.device_id),
        option_display(content_length),
        audio_bytes.len(),
        charge_window.charged_seconds,
        token_tail(&relay_token),
    );

    let quota_reservation = match state
        .database
        .reserve_admitted_dictation(
            device.device_id.clone(),
            identity.clone(),
            state.admission.dictation_limits.clone(),
            charge_window.week_start_epoch_seconds,
            charge_window.charged_seconds,
            charge_window.quota_resets_at_epoch_seconds,
        )
        .await
        .map_err(ApiError::from)?
    {
        Ok(reservation) => reservation,
        Err(exhausted) => {
            if exhausted.operator_limit {
                return Err(ApiError::forbidden(
                    "The relay dictation budget is exhausted. Please try again after the daily or weekly reset.",
                ));
            }
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

    let transcription_result = state
        .dictation_transcriber
        .transcribe(DictationTranscriptionInput {
            audio_bytes,
            mime_type: request.mime_type.into_inner(),
            file_name: request.file_name.into_inner(),
            instructions: request.instructions.map(|value| value.into_inner()),
            language_hints: request
                .language_hints
                .into_iter()
                .map(|value| value.into_inner())
                .collect(),
        })
        .await;

    let text = match transcription_result {
        Ok(text) => text,
        Err(error) => {
            if let Err(release_error) = state
                .database
                .release_admitted_dictation(
                    device.device_id.clone(),
                    identity,
                    quota_reservation.week_start_epoch_seconds,
                    quota_reservation.charged_seconds,
                )
                .await
            {
                tracing::error!(
                    "agentty_backend dictation_quota_release_failed device_id={} error={release_error:#}",
                    log_value(&device.device_id),
                );
            }
            return Err(map_dictation_error(error));
        }
    };

    tracing::info!(
        "agentty_backend dictation_transcribed device_id={} seconds_charged={} remaining_seconds={} relay_token_tail={}",
        log_value(&device.device_id),
        quota_reservation.charged_seconds,
        quota_reservation.remaining_seconds_after_charge,
        token_tail(&relay_token),
    );

    Ok(Json(DictationTranscriptionResponse {
        text,
        seconds_charged: quota_reservation.charged_seconds,
        remaining_seconds_this_week: quota_reservation.remaining_seconds_after_charge,
        quota_resets_at_epoch_seconds: quota_reservation.quota_resets_at_epoch_seconds,
    }))
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

async fn dispatch_live_activity(
    State(state): State<AppState>,
    headers: HeaderMap,
    request: Result<Json<ActivityDispatchRequest>, axum::extract::rejection::JsonRejection>,
) -> Result<Json<ActivityTransportResponse>, ApiError> {
    let Json(request) = request.map_err(|error| ApiError::bad_request(error.body_text()))?;
    let caller = authenticate_internal_caller(&state, &headers, PushType::LiveActivity)?;
    if !caller.caller.allows_topic(request.bundle_id.as_str()) {
        return Err(ApiError::forbidden(
            "Caller not allowed to send to this topic.",
        ));
    }
    let prepared = request.prepare().map_err(ApiError::bad_request)?;
    tracing::info!(
        caller = caller.caller.as_str(),
        bundle_id = request.bundle_id.as_str(),
        environment = request.push_environment.as_str(),
        "activity transport dispatch"
    );
    let response = state.push_sender.send_activity(prepared).await;
    tracing::info!(
        caller = caller.caller.as_str(),
        bundle_id = request.bundle_id.as_str(),
        environment = request.push_environment.as_str(),
        outcome = response.outcome_name(),
        "activity transport result"
    );
    Ok(Json(response))
}

async fn manage_live_activity_channel(
    State(state): State<AppState>,
    headers: HeaderMap,
    request: Result<Json<ActivityChannelRequest>, axum::extract::rejection::JsonRejection>,
) -> Result<Json<ActivityTransportResponse>, ApiError> {
    let Json(request) = request.map_err(|error| ApiError::bad_request(error.body_text()))?;
    let caller = authenticate_internal_caller(&state, &headers, PushType::LiveActivity)?;
    if !caller.caller.allows_topic(request.bundle_id.as_str()) {
        return Err(ApiError::forbidden(
            "Caller not allowed to manage channels for this topic.",
        ));
    }
    let prepared = request.prepare().map_err(ApiError::bad_request)?;
    tracing::info!(
        caller = caller.caller.as_str(),
        bundle_id = request.bundle_id.as_str(),
        environment = request.push_environment.as_str(),
        "activity channel transport dispatch"
    );
    let response = state.push_sender.send_activity(prepared).await;
    tracing::info!(
        caller = caller.caller.as_str(),
        bundle_id = request.bundle_id.as_str(),
        environment = request.push_environment.as_str(),
        outcome = response.outcome_name(),
        "activity channel transport result"
    );
    Ok(Json(response))
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

fn map_dictation_error(error: DictationTranscriberError) -> ApiError {
    match error {
        DictationTranscriberError::InvalidAudioPayload
        | DictationTranscriberError::InvalidRequest(_) => {
            ApiError::bad_request("Invalid dictation request.")
        }
        DictationTranscriberError::Request(_) | DictationTranscriberError::Rejected { .. } => {
            ApiError::Internal(error.into())
        }
    }
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
        let identity =
            tokio::task::spawn_blocking(move || crate::app_transaction::verify(&signed, app_id))
                .await
                .map_err(|error| ApiError::from(anyhow::Error::from(error)))?
                .map_err(|_| ApiError::unauthorized("Invalid signed app transaction."))?;
        return Ok(Some(identity));
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
