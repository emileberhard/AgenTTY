use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use rusqlite::OptionalExtension;
use serde_json::Value;
use tempfile::NamedTempFile;
use tower::ServiceExt;

use agentty_backend::AppState;
use agentty_backend::api::build_router;
use agentty_backend::apns::{ApnsPushRequest, PushSendSuccess, PushSender};
use agentty_backend::build_info;
use agentty_backend::config::{AnalyticsAlertSettings, InternalCaller, InternalClientSettings};
use agentty_backend::create_test_app;
use agentty_backend::create_test_app_with_transcriber;
use agentty_backend::dictation::{
    DictationTranscriber, DictationTranscriberError, DictationTranscriptionInput,
};
use agentty_backend::error::PushSendError;
use agentty_backend::models::{AnalyticsEventType, MAIN_BUNDLE_ID, PushEnvironment, PushType};
use agentty_backend::relay_broker::RelayBroker;
use agentty_backend::relay_tokens::RelayTokenManager;
use agentty_backend::storage::{AnalyticsDeviceContextRecord, AnalyticsEventRecord, Database};

const MIXED_CASE_DEVICE_ID_UPPER: &str = "33D01743-A5F8-443B-A180-B5918096398C";
const MIXED_CASE_DEVICE_ID_LOWER: &str = "33d01743-a5f8-443b-a180-b5918096398c";

#[derive(Debug, Clone)]
enum FakePushOutcome {
    Success,
    Rejected {
        status: StatusCode,
        apns_id: Option<String>,
        apns_reason: Option<String>,
        detail: String,
    },
}

#[derive(Clone)]
struct FakePushSender {
    calls: Arc<Mutex<Vec<ApnsPushRequest>>>,
    outcome: Arc<Mutex<FakePushOutcome>>,
}

impl Default for FakePushSender {
    fn default() -> Self {
        Self {
            calls: Arc::new(Mutex::new(Vec::new())),
            outcome: Arc::new(Mutex::new(FakePushOutcome::Success)),
        }
    }
}

#[derive(Clone)]
struct FakeDictationTranscriber {
    calls: Arc<Mutex<Vec<DictationTranscriptionInput>>>,
    response_text: Arc<Mutex<String>>,
}

impl Default for FakeDictationTranscriber {
    fn default() -> Self {
        Self {
            calls: Arc::new(Mutex::new(Vec::new())),
            response_text: Arc::new(Mutex::new("transcribed text".to_owned())),
        }
    }
}

#[async_trait]
impl DictationTranscriber for FakeDictationTranscriber {
    async fn transcribe(
        &self,
        request: DictationTranscriptionInput,
    ) -> anyhow::Result<String, DictationTranscriberError> {
        self.calls
            .lock()
            .expect("fake dictation calls lock poisoned")
            .push(request);
        Ok(self
            .response_text
            .lock()
            .expect("fake dictation response lock poisoned")
            .clone())
    }
}

#[async_trait]
impl PushSender for FakePushSender {
    async fn send(
        &self,
        request: ApnsPushRequest,
    ) -> std::result::Result<PushSendSuccess, PushSendError> {
        self.calls
            .lock()
            .expect("fake sender lock poisoned")
            .push(request);

        match self
            .outcome
            .lock()
            .expect("fake sender outcome lock poisoned")
            .clone()
        {
            FakePushOutcome::Success => Ok(PushSendSuccess {
                apns_id: Some("apns-success-id".to_owned()),
            }),
            FakePushOutcome::Rejected {
                status,
                apns_id,
                apns_reason,
                detail,
            } => Err(PushSendError::Rejected {
                status,
                apns_id,
                apns_reason,
                detail,
            }),
        }
    }
}

#[tokio::test]
async fn healthz_reports_build_metadata() {
    let (app, _sender) = make_app(vec![]).await;

    let response = app
        .oneshot(
            Request::builder()
                .uri("/healthz")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = response_json(response).await;
    let expected = build_info::current_build_info();
    assert_eq!(body["status"], "ok");
    assert_eq!(body["version"], expected.version);
    assert_eq!(body["git_sha"], expected.git_sha);
    match expected.git_tag {
        Some(tag) => assert_eq!(body["git_tag"], tag),
        None => assert!(body["git_tag"].is_null()),
    }
}

#[tokio::test]
async fn register_issue_and_notify() {
    let (app, sender) = make_app(vec![]).await;

    let response = app
        .clone()
        .oneshot(json_request(
            "/v1/devices/register",
            serde_json::json!({
                "device_id": "device-1",
                "device_secret": "secret-1",
                "apns_token": "token-1",
                "bundle_id": "dev.tuist.agentty.iOS.dev",
                "push_environment": "development",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let session_response = app
        .clone()
        .oneshot(json_request(
            "/v1/relay-sessions",
            serde_json::json!({
                "device_id": "device-1",
                "device_secret": "secret-1",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(session_response.status(), StatusCode::OK);
    let session_body = response_json(session_response).await;
    let relay_token = session_body["relay_token"].as_str().unwrap().to_owned();

    let notify_response = app
        .oneshot(json_request(
            "/v1/notify",
            serde_json::json!({
                "attempt_id": "attempt-1",
                "source": "Codex",
                "title": "Codex",
                "body": "done",
                "tmux_window_id": 42,
            }),
            Some(format!("Bearer {relay_token}")),
        ))
        .await
        .unwrap();
    assert_eq!(notify_response.status(), StatusCode::NO_CONTENT);

    let calls = sender.calls.lock().unwrap();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].caller, "agentty");
    assert_eq!(calls[0].push_type, PushType::Alert);
    assert_eq!(calls[0].attempt_id.as_deref(), Some("attempt-1"));
    assert_eq!(calls[0].source.as_deref(), Some("Codex"));
    assert_eq!(calls[0].tmux_window_id, Some(42));
}

#[tokio::test]
async fn missing_attempt_id_is_generated() {
    let (app, sender) = make_app(vec![]).await;

    register_default_device(&app).await;
    let relay_token = issue_default_session(&app).await;

    let notify_response = app
        .oneshot(json_request(
            "/v1/notify",
            serde_json::json!({
                "source": "Claude Code",
                "title": "Claude Code",
                "body": "done",
            }),
            Some(format!("Bearer {relay_token}")),
        ))
        .await
        .unwrap();
    assert_eq!(notify_response.status(), StatusCode::NO_CONTENT);

    let calls = sender.calls.lock().unwrap();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].attempt_id.as_ref().unwrap().len(), 16);
}

#[tokio::test]
async fn public_notify_surfaces_apns_rejection_details() {
    let clients = vec![];
    let (app, sender) = make_app(clients).await;
    *sender.outcome.lock().unwrap() = FakePushOutcome::Rejected {
        status: StatusCode::TOO_MANY_REQUESTS,
        apns_id: Some("apns-rejected".to_owned()),
        apns_reason: Some("TooManyProviderTokenUpdates".to_owned()),
        detail: r#"{"reason":"TooManyProviderTokenUpdates"}"#.to_owned(),
    };

    register_default_device(&app).await;
    let relay_token = issue_default_session(&app).await;

    let response = app
        .oneshot(json_request(
            "/v1/notify",
            serde_json::json!({
                "attempt_id": "attempt-2",
                "source": "Claude Code",
                "title": "Claude Code",
                "body": "done",
            }),
            Some(format!("Bearer {relay_token}")),
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
    let body = response_json(response).await;
    assert_eq!(body["apns_status"], 429);
    assert_eq!(body["apns_reason"], "TooManyProviderTokenUpdates");
    assert_eq!(body["apns_id"], "apns-rejected");
}

#[tokio::test]
async fn dictation_transcription_accepts_valid_relay_token() {
    let transcriber = FakeDictationTranscriber::default();
    let (app, _sender) = make_app_with_dictation(vec![], transcriber.clone()).await;

    ensure_default_device(&app).await;
    let relay_token = issue_default_session(&app).await;

    let response = app
        .oneshot(json_request(
            "/v1/dictation/transcriptions",
            serde_json::json!({
                "audio_base64": pcm_wav_base64(3),
                "mime_type": "audio/wav",
                "file_name": "dictation.wav",
                "instructions": "Return only raw text.",
                "language_hints": ["en", "sv"]
            }),
            Some(format!("Bearer {relay_token}")),
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = response_json(response).await;
    assert_eq!(body["text"], "transcribed text");
    assert_eq!(body["seconds_charged"], 3);
    assert_eq!(body["remaining_seconds_this_week"], 1797);

    let calls = transcriber.calls.lock().unwrap();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].mime_type, "audio/wav");
    assert_eq!(calls[0].file_name, "dictation.wav");
}

#[tokio::test]
async fn dictation_transcription_accepts_large_request_body() {
    let transcriber = FakeDictationTranscriber::default();
    let (app, _sender) = make_app_with_dictation(vec![], transcriber.clone()).await;

    ensure_default_device(&app).await;
    let relay_token = issue_default_session(&app).await;

    let response = app
        .oneshot(json_request(
            "/v1/dictation/transcriptions",
            serde_json::json!({
                "audio_base64": pcm_wav_base64(180),
                "mime_type": "audio/wav",
                "file_name": "dictation.wav"
            }),
            Some(format!("Bearer {relay_token}")),
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = response_json(response).await;
    assert_eq!(body["seconds_charged"], 180);

    let calls = transcriber.calls.lock().unwrap();
    assert_eq!(calls.len(), 1);
    assert!(calls[0].audio_bytes.len() > 2 * 1024 * 1024);
}

#[tokio::test]
async fn dictation_transcription_rejects_when_weekly_quota_is_exhausted() {
    let transcriber = FakeDictationTranscriber::default();
    let (app, _sender) = make_app_with_dictation(vec![], transcriber).await;

    ensure_default_device(&app).await;
    let relay_token = issue_default_session(&app).await;

    for _ in 0..45 {
        let response = app
            .clone()
            .oneshot(json_request(
                "/v1/dictation/transcriptions",
                serde_json::json!({
                    "audio_base64": pcm_wav_base64(40),
                    "mime_type": "audio/wav",
                    "file_name": "dictation.wav"
                }),
                Some(format!("Bearer {relay_token}")),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
    }

    let response = app
        .oneshot(json_request(
            "/v1/dictation/transcriptions",
            serde_json::json!({
                "audio_base64": pcm_wav_base64(1),
                "mime_type": "audio/wav",
                "file_name": "dictation.wav"
            }),
            Some(format!("Bearer {relay_token}")),
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
    let body = response_json(response).await;
    assert_eq!(body["detail"], "Weekly dictation limit reached.");
    assert_eq!(body["remaining_seconds_this_week"], 0);
    assert!(body["quota_resets_at_epoch_seconds"].as_i64().unwrap() > 0);
}

#[tokio::test]
async fn internal_alert_accepts_authorized_caller() {
    let (app, sender) = make_app(default_internal_clients()).await;

    let response = app
        .oneshot(json_request(
            "/v1/internal/alert",
            serde_json::json!({
                "topic": "emileberhard.RemoteCoder",
                "push_environment": "production",
                "device_token": "device-token-1",
                "title": "RemoteCoder",
                "body": "done",
                "subtitle": "session",
                "sound": "remote-coder-notification.wav",
                "collapse_id": "collapse-1",
                "mutable_content": false,
                "custom_data": {
                    "remoteCoder.taskCompletionPayload": "{\"status\":\"done\"}"
                }
            }),
            Some("Bearer token-remotecoder".to_owned()),
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = response_json(response).await;
    assert_eq!(body["status"], "sent");
    assert_eq!(body["push_type"], "alert");
    assert_eq!(body["topic"], "emileberhard.RemoteCoder");

    let calls = sender.calls.lock().unwrap();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].caller, "remotecoder");
    assert_eq!(calls[0].push_type, PushType::Alert);
    assert_eq!(calls[0].topic, "emileberhard.RemoteCoder");
    assert_eq!(
        calls[0].payload["remoteCoder.taskCompletionPayload"],
        "{\"status\":\"done\"}"
    );
}

#[tokio::test]
async fn internal_alert_rejects_disallowed_topic() {
    let (app, _) = make_app(default_internal_clients()).await;

    let response = app
        .oneshot(json_request(
            "/v1/internal/alert",
            serde_json::json!({
                "topic": "emileberhard.PingBooks",
                "push_environment": "production",
                "device_token": "device-token-1",
                "title": "RemoteCoder",
                "body": "done",
                "mutable_content": false
            }),
            Some("Bearer token-remotecoder".to_owned()),
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn internal_live_activity_requires_allowed_push_type() {
    let (app, _) = make_app(default_internal_clients()).await;

    let response = app
        .oneshot(json_request(
            "/v1/internal/live-activity",
            serde_json::json!({
                "bundle_id": "emileberhard.PingBooks",
                "push_environment": "production",
                "device_token": "device-token-1",
                "event": "update",
                "timestamp": 1,
                "content_state": {
                    "count": 1
                }
            }),
            Some("Bearer token-pingbooks".to_owned()),
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn internal_live_activity_derives_topic_and_returns_json() {
    let (app, sender) = make_app(default_internal_clients()).await;

    let response = app
        .oneshot(json_request(
            "/v1/internal/live-activity",
            serde_json::json!({
                "bundle_id": "emileberhard.RemoteCoder",
                "push_environment": "production",
                "device_token": "device-token-1",
                "event": "end",
                "timestamp": 10,
                "content_state": {
                    "activeTaskCount": 0
                },
                "dismissal_date": 10
            }),
            Some("Bearer token-remotecoder".to_owned()),
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = response_json(response).await;
    assert_eq!(body["push_type"], "liveactivity");
    assert_eq!(
        body["topic"],
        "emileberhard.RemoteCoder.push-type.liveactivity"
    );

    let calls = sender.calls.lock().unwrap();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].caller, "remotecoder");
    assert_eq!(calls[0].push_type, PushType::LiveActivity);
    assert_eq!(
        calls[0].topic,
        "emileberhard.RemoteCoder.push-type.liveactivity"
    );
}

#[tokio::test]
async fn internal_location_derives_topic_and_preserves_command() {
    let (app, sender) = make_app(default_internal_clients()).await;

    let response = app
        .oneshot(json_request(
            "/v1/internal/location",
            serde_json::json!({
                "bundle_id": "emileberhard.RemoteCoder",
                "push_environment": "development",
                "device_token": "location-token-1",
                "expiration": 1_800_000_000,
                "custom_data": {
                    "remoteCoder.navigation": {
                        "sessionId": "session-1",
                        "profile": { "mode": "walking" }
                    }
                }
            }),
            Some("Bearer token-remotecoder".to_owned()),
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = response_json(response).await;
    assert_eq!(body["push_type"], "location");
    assert_eq!(body["topic"], "emileberhard.RemoteCoder.location-query");

    let calls = sender.calls.lock().unwrap();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].caller, "remotecoder");
    assert_eq!(calls[0].push_type, PushType::Location);
    assert_eq!(calls[0].topic, "emileberhard.RemoteCoder.location-query");
    assert_eq!(calls[0].expiration, Some(1_800_000_000));
    assert_eq!(calls[0].payload["aps"], serde_json::json!({}));
    assert_eq!(
        calls[0].payload["remoteCoder.navigation"]["sessionId"],
        "session-1"
    );
}

#[tokio::test]
async fn internal_voip_sends_only_call_identity_without_store_and_forward() {
    let (app, sender) = make_app(default_internal_clients()).await;
    let response = app
        .oneshot(json_request(
            "/v1/internal/voip",
            serde_json::json!({
                "bundle_id": "emileberhard.RemoteCoder",
                "push_environment": "development",
                "device_token": "voip-token",
                "call_id": "a8d0fd55-f9dc-48a2-8874-f49c08d728e1",
                "host_id": "33d01743-a5f8-443b-a180-b5918096398c",
                "expires_at": 1_800_000_000,
            }),
            Some("Bearer token-remotecoder".to_owned()),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let calls = sender.calls.lock().unwrap();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].push_type, PushType::Voip);
    assert_eq!(calls[0].topic, "emileberhard.RemoteCoder.voip");
    assert_eq!(calls[0].expiration, Some(0));
    assert_eq!(calls[0].collapse_id, None);
    assert_eq!(
        calls[0].payload,
        serde_json::json!({
            "aps": {},
            "agentCall": {
                "callId": "a8d0fd55-f9dc-48a2-8874-f49c08d728e1",
                "hostId": "33d01743-a5f8-443b-a180-b5918096398c",
                "expiresAt": 1_800_000_000,
            }
        })
    );
}

#[tokio::test]
async fn internal_voip_rejects_other_callers_topics_and_extra_payload() {
    for (token, bundle_id, extra, expected) in [
        (
            "token-pingbooks",
            "emileberhard.RemoteCoder",
            false,
            StatusCode::FORBIDDEN,
        ),
        (
            "token-remotecoder",
            "dev.tuist.agentty.iOS",
            false,
            StatusCode::FORBIDDEN,
        ),
        (
            "token-remotecoder",
            "emileberhard.RemoteCoder",
            true,
            StatusCode::UNPROCESSABLE_ENTITY,
        ),
    ] {
        let (app, sender) = make_app(default_internal_clients()).await;
        let mut payload = serde_json::json!({
            "bundle_id": bundle_id,
            "push_environment": "production",
            "device_token": "voip-token",
            "call_id": "a8d0fd55-f9dc-48a2-8874-f49c08d728e1",
            "host_id": "33d01743-a5f8-443b-a180-b5918096398c",
            "expires_at": 1_800_000_000,
        });
        if extra {
            payload["brief"] = serde_json::json!("Must never enter APNs");
        }
        let response = app
            .oneshot(json_request(
                "/v1/internal/voip",
                payload,
                Some(format!("Bearer {token}")),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), expected);
        assert!(sender.calls.lock().unwrap().is_empty());
    }
}

#[tokio::test]
async fn invalid_bundle_pair_is_rejected() {
    let (app, _) = make_app(vec![]).await;

    let response = app
        .oneshot(json_request(
            "/v1/devices/register",
            serde_json::json!({
                "device_id": "device-1",
                "device_secret": "secret-1",
                "apns_token": "token-1",
                "bundle_id": "dev.tuist.agentty.iOS.dev",
                "push_environment": "production",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn repeated_bundle_prefix_is_rejected() {
    let (app, _) = make_app(vec![]).await;

    let response = app
        .oneshot(json_request(
            "/v1/devices/register",
            serde_json::json!({
                "device_id": "device-1",
                "device_secret": "secret-1",
                "apns_token": "token-1",
                "bundle_id": "dev.tuist.agentty.iOSdev.tuist.agentty.iOS.dev",
                "push_environment": "development",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn invalid_device_credentials_are_rejected() {
    let (app, _) = make_app(vec![]).await;

    let response = app
        .oneshot(json_request(
            "/v1/relay-sessions",
            serde_json::json!({
                "device_id": "device-1",
                "device_secret": "secret-1",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn invalid_relay_token_is_rejected() {
    let (app, _) = make_app(vec![]).await;

    let response = app
        .oneshot(json_request(
            "/v1/notify",
            serde_json::json!({
                "attempt_id": "attempt-2",
                "source": "Claude Code",
                "title": "Claude Code",
                "body": "done",
            }),
            Some("Bearer invalid".to_owned()),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn repeated_bearer_prefix_is_rejected() {
    let (app, _) = make_app(vec![]).await;

    register_default_device(&app).await;
    let relay_token = issue_default_session(&app).await;

    let response = app
        .oneshot(json_request(
            "/v1/notify",
            serde_json::json!({
                "attempt_id": "attempt-2",
                "source": "Claude Code",
                "title": "Claude Code",
                "body": "done",
            }),
            Some(format!("Bearer Bearer {relay_token}")),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn empty_bearer_token_is_rejected() {
    let (app, _) = make_app(vec![]).await;

    register_default_device(&app).await;

    let response = app
        .oneshot(json_request(
            "/v1/notify",
            serde_json::json!({
                "attempt_id": "attempt-3",
                "source": "Claude Code",
                "title": "Claude Code",
                "body": "done",
            }),
            Some("Bearer ".to_owned()),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn pairing_session_create_claim_complete_and_fetch_status() {
    let (app, _, _) = make_app_with_db_path(vec![]).await;

    register_default_device(&app).await;

    let create_response = app
        .clone()
        .oneshot(json_request(
            "/v1/pairing-sessions",
            serde_json::json!({}),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(create_response.status(), StatusCode::OK);
    let create_body = response_json(create_response).await;
    let session_id = create_body["session_id"].as_str().unwrap().to_owned();
    let pairing_code = create_body["pairing_code"].as_str().unwrap().to_owned();
    let host_token = create_body["host_token"].as_str().unwrap().to_owned();
    assert_eq!(pairing_code.len(), 9);
    assert_eq!(
        create_body["qr_payload"],
        format!("agentty://pair?code={pairing_code}")
    );

    let pending_response = app
        .clone()
        .oneshot(json_request(
            &format!("/v1/pairing-sessions/{session_id}/host-status"),
            serde_json::json!({
                "host_token": host_token,
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(pending_response.status(), StatusCode::OK);
    let pending_body = response_json(pending_response).await;
    assert_eq!(pending_body["status"], "pending");
    assert!(pending_body["public_key"].is_null());

    let claim_response = app
        .clone()
        .oneshot(json_request(
            "/v1/pairing-sessions/claim",
            serde_json::json!({
                "code": pairing_code.to_lowercase(),
                "device_id": "device-1",
                "device_secret": "secret-1",
                "public_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkey agentty@test",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(claim_response.status(), StatusCode::OK);
    let claim_body = response_json(claim_response).await;
    assert_eq!(claim_body["session_id"], session_id.as_str());

    let claimed_host_response = app
        .clone()
        .oneshot(json_request(
            &format!("/v1/pairing-sessions/{session_id}/host-status"),
            serde_json::json!({
                "host_token": host_token,
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(
        response_json(claimed_host_response).await["public_key"],
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkey agentty@test"
    );

    let status_response = app
        .clone()
        .oneshot(json_request(
            &format!("/v1/pairing-sessions/{session_id}/status"),
            serde_json::json!({
                "device_id": "device-1",
                "device_secret": "secret-1",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(status_response.status(), StatusCode::OK);
    let status_body = response_json(status_response).await;
    assert_eq!(status_body["status"], "claimed");

    let reclaimed_while_claimed = app
        .clone()
        .oneshot(json_request(
            "/v1/pairing-sessions/claim",
            serde_json::json!({
                "code": pairing_code,
                "device_id": "device-1",
                "device_secret": "secret-1",
                "public_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkey agentty@test",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(reclaimed_while_claimed.status(), StatusCode::OK);
    assert_eq!(
        response_json(reclaimed_while_claimed).await["session_id"],
        session_id.as_str()
    );

    let complete_response = app
        .clone()
        .oneshot(json_request(
            &format!("/v1/pairing-sessions/{session_id}/complete"),
            serde_json::json!({
                "host_token": host_token,
                "detected_username": "developer",
                "detected_username_source": "id_command",
                "host_candidates": [
                    {
                        "value": "host",
                        "kind": "single_label",
                        "source": "hostname",
                        "rank": 2
                    },
                    {
                        "value": "host.local",
                        "kind": "fqdn",
                        "source": "hostname_fqdn",
                        "rank": 1
                    }
                ],
                "hostname_candidates": ["host.local", "host"],
                "uses_tailscale": true,
                "port": 22,
                "platform": "macos",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(complete_response.status(), StatusCode::OK);
    let complete_body = response_json(complete_response).await;
    assert_eq!(complete_body["status"], "completed");
    assert_eq!(
        complete_body["completion"]["detected_username"],
        "developer"
    );
    assert_eq!(
        complete_body["completion"]["detected_username_source"],
        "id_command"
    );
    assert_eq!(
        complete_body["completion"]["hostname_candidates"][0],
        "host.local"
    );
    assert_eq!(
        complete_body["completion"]["host_candidates"][0]["kind"],
        "single_label"
    );
    assert_eq!(complete_body["completion"]["uses_tailscale"], true);
    assert_eq!(complete_body["completion"]["port"], 22);
    assert_eq!(complete_body["completion"]["platform"], "macos");

    let reused_claim = app
        .clone()
        .oneshot(json_request(
            "/v1/pairing-sessions/claim",
            serde_json::json!({
                "code": pairing_code,
                "device_id": "device-1",
                "device_secret": "secret-1",
                "public_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkey agentty@test",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(reused_claim.status(), StatusCode::OK);
    assert_eq!(
        response_json(reused_claim).await["session_id"],
        session_id.as_str()
    );

    let rejected_claim = app
        .oneshot(json_request(
            "/v1/pairing-sessions/claim",
            serde_json::json!({
                "code": pairing_code,
                "device_id": "device-1",
                "device_secret": "secret-1",
                "public_key": "ssh-ed25519 AAAA reused@test",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(rejected_claim.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn pairing_session_status_returns_full_completion_payload_for_hardened_clients() {
    let (app, _, _) = make_app_with_db_path(vec![]).await;

    let create_response = app
        .clone()
        .oneshot(json_request(
            "/v1/pairing-sessions",
            serde_json::json!({}),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(create_response.status(), StatusCode::OK);
    let create_body = response_json(create_response).await;
    let session_id = create_body["session_id"].as_str().unwrap().to_owned();
    let pairing_code = create_body["pairing_code"].as_str().unwrap().to_owned();
    let host_token = create_body["host_token"].as_str().unwrap().to_owned();

    register_default_device(&app).await;

    let claim_response = app
        .clone()
        .oneshot(json_request(
            "/v1/pairing-sessions/claim",
            serde_json::json!({
                "code": pairing_code,
                "device_id": "device-1",
                "device_secret": "secret-1",
                "public_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkey agentty@test",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(claim_response.status(), StatusCode::OK);

    let complete_response = app
        .clone()
        .oneshot(json_request(
            &format!("/v1/pairing-sessions/{session_id}/complete"),
            serde_json::json!({
                "host_token": host_token,
                "detected_username": "developer",
                "detected_username_source": "whoami_command",
                "detected_username_suspicious": true,
                "host_environment_flags": ["wsl"],
                "hostname_candidates": ["agentty.local"],
                "uses_tailscale": false,
                "port": 22,
                "platform": "linux",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(complete_response.status(), StatusCode::OK);

    let status_response = app
        .oneshot(json_request(
            &format!("/v1/pairing-sessions/{session_id}/status"),
            serde_json::json!({
                "device_id": "device-1",
                "device_secret": "secret-1",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(status_response.status(), StatusCode::OK);
    let status_body = response_json(status_response).await;

    assert_eq!(status_body["completion"]["detected_username"], "developer");
    assert_eq!(
        status_body["completion"]["detected_username_source"],
        "whoami_command"
    );
    assert_eq!(
        status_body["completion"]["detected_username_suspicious"],
        true
    );
    assert_eq!(
        status_body["completion"]["host_environment_flags"][0],
        "wsl"
    );
}

#[tokio::test]
async fn register_device_rejects_secret_mismatch_without_overwriting_existing_device() {
    let (app, _, database_path) = make_app_with_db_path(vec![]).await;

    register_default_device(&app).await;

    let response = app
        .clone()
        .oneshot(json_request(
            "/v1/devices/register",
            serde_json::json!({
                "device_id": "device-1",
                "device_secret": "wrong-secret",
                "apns_token": "token-2",
                "bundle_id": "dev.tuist.agentty.iOS.dev",
                "push_environment": "development",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);

    let connection = rusqlite::Connection::open(&database_path).unwrap();
    let apns_token: String = connection
        .query_row(
            "SELECT apns_token FROM devices WHERE device_id = ?",
            ["device-1"],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(apns_token, "token-1");

    let original_secret_response = app
        .clone()
        .oneshot(json_request(
            "/v1/relay-sessions",
            serde_json::json!({
                "device_id": "device-1",
                "device_secret": "secret-1",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(original_secret_response.status(), StatusCode::OK);

    let wrong_secret_response = app
        .oneshot(json_request(
            "/v1/relay-sessions",
            serde_json::json!({
                "device_id": "device-1",
                "device_secret": "wrong-secret",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(wrong_secret_response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn pairing_session_claim_rejects_invalid_device_credentials() {
    let (app, _, _) = make_app_with_db_path(vec![]).await;

    let create_response = app
        .clone()
        .oneshot(json_request(
            "/v1/pairing-sessions",
            serde_json::json!({}),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(create_response.status(), StatusCode::OK);
    let pairing_code = response_json(create_response).await["pairing_code"]
        .as_str()
        .unwrap()
        .to_owned();

    let response = app
        .oneshot(json_request(
            "/v1/pairing-sessions/claim",
            serde_json::json!({
                "code": pairing_code,
                "device_id": "device-1",
                "device_secret": "secret-1",
                "public_key": "ssh-ed25519 AAAA test",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn pairing_session_status_rejects_invalid_device_credentials() {
    let (app, _, _) = make_app_with_db_path(vec![]).await;

    register_default_device(&app).await;
    let create_body = response_json(
        app.clone()
            .oneshot(json_request(
                "/v1/pairing-sessions",
                serde_json::json!({}),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    let session_id = create_body["session_id"].as_str().unwrap();

    let response = app
        .oneshot(json_request(
            &format!("/v1/pairing-sessions/{session_id}/status"),
            serde_json::json!({
                "device_id": "device-1",
                "device_secret": "wrong",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn pairing_session_complete_with_error_marks_failed() {
    let (app, _, _) = make_app_with_db_path(vec![]).await;

    register_default_device(&app).await;
    let create_body = response_json(
        app.clone()
            .oneshot(json_request(
                "/v1/pairing-sessions",
                serde_json::json!({}),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    let session_id = create_body["session_id"].as_str().unwrap().to_owned();
    let host_token = create_body["host_token"].as_str().unwrap().to_owned();
    let pairing_code = create_body["pairing_code"].as_str().unwrap().to_owned();

    let claim_response = app
        .clone()
        .oneshot(json_request(
            "/v1/pairing-sessions/claim",
            serde_json::json!({
                "code": pairing_code,
                "device_id": "device-1",
                "device_secret": "secret-1",
                "public_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIfailed failed@test",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(claim_response.status(), StatusCode::OK);

    let response = app
        .oneshot(json_request(
            &format!("/v1/pairing-sessions/{session_id}/complete"),
            serde_json::json!({
                "host_token": host_token,
                "platform": "linux",
                "error_message": "failed to install key",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = response_json(response).await;
    assert_eq!(body["status"], "failed");
    assert_eq!(body["completion"]["error_message"], "failed to install key");
    assert_eq!(body["completion"]["platform"], "linux");
    assert_eq!(body["completion"]["uses_tailscale"], false);
}

#[tokio::test]
async fn pairing_session_expired_session_cannot_be_claimed_and_reports_expired() {
    let (app, _, database_path) = make_app_with_db_path(vec![]).await;

    register_default_device(&app).await;
    let create_body = response_json(
        app.clone()
            .oneshot(json_request(
                "/v1/pairing-sessions",
                serde_json::json!({}),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    let session_id = create_body["session_id"].as_str().unwrap().to_owned();
    let host_token = create_body["host_token"].as_str().unwrap().to_owned();
    let pairing_code = create_body["pairing_code"].as_str().unwrap().to_owned();

    rusqlite::Connection::open(&database_path)
        .unwrap()
        .execute(
            "UPDATE pairing_sessions SET expires_at_epoch_seconds = unixepoch() - 1 WHERE session_id = ?",
            [&session_id],
        )
        .unwrap();

    let claim_response = app
        .clone()
        .oneshot(json_request(
            "/v1/pairing-sessions/claim",
            serde_json::json!({
                "code": pairing_code,
                "device_id": "device-1",
                "device_secret": "secret-1",
                "public_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexpired expired@test",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(claim_response.status(), StatusCode::BAD_REQUEST);

    let status_response = app
        .clone()
        .oneshot(json_request(
            &format!("/v1/pairing-sessions/{session_id}/status"),
            serde_json::json!({
                "device_id": "device-1",
                "device_secret": "secret-1",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(status_response.status(), StatusCode::NOT_FOUND);

    let host_status_response = app
        .clone()
        .oneshot(json_request(
            &format!("/v1/pairing-sessions/{session_id}/host-status"),
            serde_json::json!({
                "host_token": host_token,
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(host_status_response.status(), StatusCode::OK);
    assert_eq!(
        response_json(host_status_response).await["status"],
        "expired"
    );
}

#[tokio::test]
async fn analytics_ingest_persists_hashed_users_and_updates_views() {
    let (app, _, database_path) = make_app_with_db_path(vec![]).await;

    ensure_default_device(&app).await;

    let response = app
        .clone()
        .oneshot(json_request(
            "/v1/analytics/events",
            serde_json::json!({
                "device_id": "device-1",
                "device_secret": "secret-1",
                "app_transaction_id": "app-transaction-1",
                "original_purchase_date_epoch_seconds": 1_715_000_000_i64,
                "bundle_id": "dev.tuist.agentty.iOS",
                "app_transaction_environment": "production",
                "app_version": "1.2.3",
                "build_number": "45",
                "flavor": "main",
                "platform": "ios",
                "events": [
                    {
                        "event_id": "event-1",
                        "event_type": "access_state_snapshot",
                        "occurred_at_epoch_seconds": 1_715_000_010_i64,
                        "payload": {
                            "reason": "startup",
                            "has_finished_initial_access_load": true,
                            "has_lifetime_access": true,
                            "trial_expired": false,
                            "trial_consumed_usage_seconds": 12.0,
                            "trial_remaining_usage_seconds": 28_788.0,
                            "interactive_content_allowed": true,
                            "gate_blocking": false
                        }
                    },
                    {
                        "event_id": "event-2",
                        "event_type": "ssh_session_completed",
                        "occurred_at_epoch_seconds": 1_715_000_020_i64,
                        "payload": {
                            "session_id": "ssh-session-1",
                            "host_key_hash": "host-hash-1",
                            "duration_seconds": 120,
                            "was_ready": true,
                            "disconnect_reason": "network_error"
                        }
                    }
                ]
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let connection = rusqlite::Connection::open(&database_path).unwrap();

    let user_count: i64 = connection
        .query_row("SELECT COUNT(*) FROM analytics_users", [], |row| row.get(0))
        .unwrap();
    let link_count: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM analytics_device_user_links",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let event_count: i64 = connection
        .query_row("SELECT COUNT(*) FROM analytics_events", [], |row| {
            row.get(0)
        })
        .unwrap();
    let unhashed_user_count: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM analytics_users WHERE user_key_hash = ?",
            ["app-transaction-1"],
            |row| row.get(0),
        )
        .unwrap();
    let summary: (i64, i64, Option<i64>) = connection
        .query_row(
            r#"
            SELECT install_count, last_has_lifetime_access, first_successful_ssh_at_epoch_seconds
            FROM analytics_current_user_summary
            "#,
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();

    assert_eq!(user_count, 1);
    assert_eq!(link_count, 1);
    assert_eq!(event_count, 2);
    assert_eq!(unhashed_user_count, 0);
    assert_eq!(summary.0, 1);
    assert_eq!(summary.1, 1);
    assert_eq!(summary.2, Some(1_715_000_020_i64));
}

#[tokio::test]
async fn analytics_ingest_accepts_nested_app_session_payload_with_legacy_default_version() {
    let (app, _, database_path) = make_app_with_db_path(vec![]).await;

    ensure_default_device(&app).await;

    let response = app
        .clone()
        .oneshot(json_request(
            "/v1/analytics/events",
            analytics_ingest_body(
                "device-1",
                "secret-1",
                "app-transaction-nested-default-version",
                vec![serde_json::json!({
                    "event_id": "app-session-nested-default-version",
                    "event_type": "app_session_completed",
                    "occurred_at_epoch_seconds": 1_715_000_111_i64,
                    "payload": {
                        "session": {
                            "id": "app-session-1",
                            "duration_seconds": 42,
                            "saved_host_count": 1,
                            "active_host_present": true,
                            "had_paywall_visible": false,
                            "ssh_session_count": 2,
                            "ready_ssh_session_count": 1,
                            "had_terminal_input": true
                        },
                        "access_state": {
                            "has_finished_initial_access_load": true,
                            "has_lifetime_access": false,
                            "trial_expired": false,
                            "trial_consumed_usage_seconds": 120.0,
                            "trial_remaining_usage_seconds": 17_880.0,
                            "interactive_content_allowed": true,
                            "gate_blocking": false
                        }
                    }
                })],
            ),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let connection = rusqlite::Connection::open(&database_path).unwrap();
    let payload_json: String = connection
        .query_row(
            "SELECT payload_json FROM analytics_events WHERE event_id = 'app-session-nested-default-version'",
            [],
            |row| row.get(0),
        )
        .unwrap();

    assert!(payload_json.contains("\"access_state\""));
    assert!(payload_json.contains("\"session\""));
}

#[tokio::test]
async fn analytics_ingest_accepts_flat_app_session_payload_when_marked_v2() {
    let (app, _, database_path) = make_app_with_db_path(vec![]).await;

    ensure_default_device(&app).await;

    let response = app
        .clone()
        .oneshot(json_request(
            "/v1/analytics/events",
            analytics_ingest_body(
                "device-1",
                "secret-1",
                "app-transaction-flat-v2",
                vec![analytics_event_v2(
                    "app-session-flat-v2",
                    "app_session_completed",
                    1_715_000_222_i64,
                    serde_json::json!({
                        "app_session_id": "app-session-2",
                        "duration_seconds": 24,
                        "has_finished_initial_access_load": true,
                        "has_lifetime_access": true,
                        "trial_expired": false,
                        "trial_consumed_usage_seconds": 12.0,
                        "trial_remaining_usage_seconds": 28_788.0,
                        "interactive_content_allowed": true,
                        "gate_blocking": false,
                        "saved_host_count": 2,
                        "active_host_present": true,
                        "had_paywall_visible": false,
                        "ssh_session_count": 3,
                        "ready_ssh_session_count": 3,
                        "had_terminal_input": true
                    }),
                )],
            ),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let connection = rusqlite::Connection::open(&database_path).unwrap();
    let payload_json: String = connection
        .query_row(
            "SELECT payload_json FROM analytics_events WHERE event_id = 'app-session-flat-v2'",
            [],
            |row| row.get(0),
        )
        .unwrap();

    assert!(payload_json.contains("\"access_state\""));
    assert!(payload_json.contains("\"session\""));
}

#[tokio::test]
async fn analytics_ingest_persists_device_context_and_richer_summary_views() {
    let (app, _, database_path) = make_app_with_db_path(vec![]).await;

    ensure_default_device(&app).await;

    let response = app
        .clone()
        .oneshot(json_request(
            "/v1/analytics/events",
            serde_json::json!({
                "device_id": "device-1",
                "device_secret": "secret-1",
                "app_transaction_id": "app-transaction-rich-user",
                "original_purchase_date_epoch_seconds": 1_715_000_000_i64,
                "bundle_id": MAIN_BUNDLE_ID,
                "app_transaction_environment": "production",
                "app_version": "1.2.3",
                "build_number": "45",
                "flavor": "main",
                "platform": "ios",
                "device_context": {
                    "system_version": "26.2",
                    "device_model_identifier": "iPhone17,3",
                    "device_family": "phone",
                    "locale_identifier": "en_SE",
                    "preferred_languages": ["en-SE", "sv-SE"]
                },
                "events": [
                    {
                        "event_id": "rich-host-start",
                        "event_type": "host_setup_flow_event",
                        "occurred_at_epoch_seconds": 1_715_000_001_i64,
                        "payload": {
                            "method": "automatic",
                            "stage": "started",
                            "is_edit": false,
                            "uses_tailscale_address": false
                        }
                    },
                    {
                        "event_id": "rich-host-complete",
                        "event_type": "host_setup_flow_event",
                        "occurred_at_epoch_seconds": 1_715_000_002_i64,
                        "payload": {
                            "method": "automatic",
                            "stage": "save_succeeded",
                            "is_edit": false,
                            "uses_tailscale_address": true,
                            "saved_host_count": 1,
                            "host_id_hash": "host-id-hash-1"
                        }
                    },
                    {
                        "event_id": "rich-paywall-shown",
                        "event_type": "paywall_event",
                        "occurred_at_epoch_seconds": 1_715_000_003_i64,
                        "payload": {
                            "stage": "shown",
                            "has_finished_initial_access_load": true,
                            "has_lifetime_access": false,
                            "trial_expired": false,
                            "trial_consumed_usage_seconds": 300.0,
                            "trial_remaining_usage_seconds": 17_700.0,
                            "interactive_content_allowed": false,
                            "gate_blocking": true
                        }
                    },
                    {
                        "event_id": "rich-app-session",
                        "event_type": "app_session_completed",
                        "occurred_at_epoch_seconds": 1_715_000_004_i64,
                        "payload": {
                            "app_session_id": "app-session-rich-1",
                            "duration_seconds": 120,
                            "has_finished_initial_access_load": true,
                            "has_lifetime_access": false,
                            "trial_expired": false,
                            "trial_consumed_usage_seconds": 420.0,
                            "trial_remaining_usage_seconds": 17_580.0,
                            "interactive_content_allowed": true,
                            "gate_blocking": false,
                            "saved_host_count": 1,
                            "active_host_present": true,
                            "had_paywall_visible": true,
                            "ssh_session_count": 1,
                            "ready_ssh_session_count": 1,
                            "had_terminal_input": true
                        }
                    },
                    {
                        "event_id": "rich-ssh-session",
                        "event_type": "ssh_session_completed",
                        "occurred_at_epoch_seconds": 1_715_000_005_i64,
                        "payload": {
                            "session_id": "ssh-session-rich-1",
                            "host_id_hash": "host-id-hash-1",
                            "duration_seconds": 75,
                            "was_ready": true,
                            "disconnect_category": "shell_closed",
                            "had_terminal_input": true,
                            "input_event_count": 7,
                            "auth_mode": "key"
                        }
                    }
                ]
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let connection = rusqlite::Connection::open(&database_path).unwrap();
    let summary: (String, String, String, i64, i64, i64, i64, i64, i64) = connection
        .query_row(
            r#"
            SELECT
                last_system_version,
                last_device_model_identifier,
                last_device_family,
                last_saved_host_count,
                host_setup_completed_count,
                paywall_shown_count,
                app_session_count,
                ready_ssh_session_count,
                distinct_hosts_used
            FROM analytics_current_user_summary
            "#,
            [],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                    row.get(7)?,
                    row.get(8)?,
                ))
            },
        )
        .unwrap();

    let onboarding: (i64, i64, i64, i64, i64) = connection
        .query_row(
            r#"
            SELECT
                total_users,
                users_started_host_setup,
                users_completed_host_setup,
                users_with_successful_ssh,
                users_with_terminal_input
            FROM analytics_onboarding_funnel
            "#,
            [],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                ))
            },
        )
        .unwrap();

    let paywall_summary: (i64, i64) = connection
        .query_row(
            "SELECT paywall_show_events, paid_users FROM analytics_paywall_summary",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();

    assert_eq!(summary.0, "26.2");
    assert_eq!(summary.1, "iPhone17,3");
    assert_eq!(summary.2, "phone");
    assert_eq!(summary.3, 1);
    assert_eq!(summary.4, 1);
    assert_eq!(summary.5, 1);
    assert_eq!(summary.6, 1);
    assert_eq!(summary.7, 1);
    assert_eq!(summary.8, 1);

    assert_eq!(onboarding, (1, 1, 1, 1, 1));
    assert_eq!(paywall_summary, (1, 0));
}

#[tokio::test]
async fn analytics_ingest_moves_sensitive_fields_out_of_payload_json() {
    let (app, _, database_path) = make_app_with_db_path(vec![]).await;

    ensure_default_device(&app).await;

    let response = app
        .clone()
        .oneshot(json_request(
            "/v1/analytics/events",
            analytics_ingest_body(
                "device-1",
                "secret-1",
                "app-transaction-sensitive-context",
                vec![
                    serde_json::json!({
                        "event_id": "host-setup-sensitive",
                        "event_type": "host_setup_flow_event",
                        "occurred_at_epoch_seconds": 1_715_100_010_i64,
                        "payload": {
                            "app_session_id": "app-session-1",
                            "flow_id": "flow-sensitive-1",
                            "method": "automatic",
                            "stage": "failed",
                            "is_edit": false,
                            "uses_tailscale_address": false,
                            "error_category": "reachability",
                            "error_message": "connect failed: 100.64.0.12",
                            "detected_username": "developer",
                            "detected_username_source": "whoami_command",
                            "username_suspicious": true,
                            "selected_candidate_kind": "local_domain",
                            "selected_candidate_source": "hostname_fqdn",
                            "selected_candidate_rank": 1,
                            "selected_candidate_value": "agentty.local",
                            "candidate_values": ["agentty.local", "agentty"],
                            "candidate_count": 2,
                            "high_confidence_candidate_count": 0,
                            "all_low_confidence_candidates": true,
                            "probe_attempt_count": 2,
                            "reachability_failure_subtype": "dns"
                        }
                    }),
                    serde_json::json!({
                        "event_id": "ssh-sensitive",
                        "event_type": "ssh_session_completed",
                        "occurred_at_epoch_seconds": 1_715_100_020_i64,
                        "payload": {
                            "session_id": "ssh-sensitive-1",
                            "host_key_hash": "host-key-sensitive-1",
                            "duration_seconds": 3,
                            "was_ready": false,
                            "disconnect_category": "network_error",
                            "disconnect_reason": "dial tcp 100.64.0.12:22: no route to host",
                            "failure_stage": "tcp_connect",
                            "auth_mode": "key"
                        }
                    }),
                    serde_json::json!({
                        "event_id": "key-material-sensitive",
                        "event_type": "key_material_event",
                        "occurred_at_epoch_seconds": 1_715_100_030_i64,
                        "payload": {
                            "operation": "import",
                            "stage": "failed",
                            "failure_reason": "rsa_unsupported",
                            "failure_detail": "RSA private keys are not supported"
                        }
                    }),
                ],
            ),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let connection = rusqlite::Connection::open(&database_path).unwrap();
    let host_setup_payload: String = connection
        .query_row(
            "SELECT payload_json FROM analytics_events WHERE event_id = 'host-setup-sensitive'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let host_setup_payload: Value = serde_json::from_str(&host_setup_payload).unwrap();
    assert_eq!(
        host_setup_payload["detected_username"]["value"],
        Value::Null
    );
    assert_eq!(
        host_setup_payload["candidates"]["selected"]["value"],
        Value::Null
    );
    assert!(host_setup_payload["candidates"].get("all_values").is_none());
    assert_eq!(host_setup_payload["error"]["message"], Value::Null);

    let sensitive_context: (String, String, String, String, String) = connection
        .query_row(
            r#"
            SELECT
                raw_detected_username,
                raw_selected_candidate_value,
                raw_candidate_values_json,
                raw_disconnect_reason,
                raw_error_detail
            FROM analytics_sensitive_event_context
            WHERE event_id = 'host-setup-sensitive'
            "#,
            [],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get::<_, Option<String>>(3)?.unwrap_or_default(),
                    row.get(4)?,
                ))
            },
        )
        .unwrap();
    assert_eq!(sensitive_context.0, "developer");
    assert_eq!(sensitive_context.1, "agentty.local");
    assert_eq!(sensitive_context.2, r#"["agentty.local","agentty"]"#);
    assert_eq!(sensitive_context.3, "");
    assert_eq!(sensitive_context.4, "connect failed: 100.64.0.12");

    let ssh_sensitive_context: String = connection
        .query_row(
            r#"
            SELECT raw_disconnect_reason
            FROM analytics_sensitive_event_context
            WHERE event_id = 'ssh-sensitive'
            "#,
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        ssh_sensitive_context,
        "dial tcp 100.64.0.12:22: no route to host"
    );

    let key_material_sensitive_context: String = connection
        .query_row(
            r#"
            SELECT raw_error_detail
            FROM analytics_sensitive_event_context
            WHERE event_id = 'key-material-sensitive'
            "#,
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        key_material_sensitive_context,
        "RSA private keys are not supported"
    );
}

#[tokio::test]
async fn analytics_ingest_accepts_v2_payloads_and_persists_canonical_nested_json() {
    let (app, _, database_path) = make_app_with_db_path(vec![]).await;

    ensure_default_device(&app).await;

    let response = app
        .clone()
        .oneshot(json_request(
            "/v1/analytics/events",
            analytics_ingest_body(
                "device-1",
                "secret-1",
                "app-transaction-v2-analytics",
                vec![
                    analytics_event_v2(
                        "host-setup-v2",
                        "host_setup_flow_event",
                        1_715_100_100_i64,
                        serde_json::json!({
                            "context": { "app_session_id": "app-session-v2-1" },
                            "flow": {
                                "id": "flow-v2-1",
                                "method": "automatic",
                                "stage": "failed",
                                "is_edit": false,
                                "uses_tailscale_address": false
                            },
                            "host": {
                                "id_hash": "host-id-v2-1",
                                "saved_host_count": 1
                            },
                            "detected_username": {
                                "value": "developer",
                                "source": "whoami_command",
                                "suspicious": true
                            },
                            "candidates": {
                                "selected": {
                                    "value": "agentty.local",
                                    "kind": "local_domain",
                                    "source": "hostname_fqdn",
                                    "rank": 1
                                },
                                "all_values": ["agentty.local", "agentty"],
                                "count": 2,
                                "high_confidence_count": 0,
                                "all_low_confidence": true
                            },
                            "reachability": {
                                "attempt_count": 2,
                                "failure_subtype": "dns"
                            },
                            "error": {
                                "category": "reachability",
                                "message": "connect failed: 100.64.0.12"
                            }
                        }),
                    ),
                    analytics_event_v2(
                        "ssh-v2",
                        "ssh_session_completed",
                        1_715_100_110_i64,
                        serde_json::json!({
                            "context": { "app_session_id": "app-session-v2-1" },
                            "session": {
                                "id": "ssh-session-v2-1",
                                "duration_seconds": 3,
                                "was_ready": false
                            },
                            "host": {
                                "key_hash": "host-key-v2-1"
                            },
                            "auth": {
                                "mode": "key"
                            },
                            "disconnect": {
                                "category": "network_error",
                                "reason": "dial tcp 100.64.0.12:22: no route to host",
                                "failure_stage": "tcp_connect"
                            },
                            "input": {
                                "had_terminal_input": false,
                                "event_count": 0
                            }
                        }),
                    ),
                ],
            ),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let connection = rusqlite::Connection::open(&database_path).unwrap();
    let host_setup_payload: Value = connection
        .query_row(
            "SELECT payload_json FROM analytics_events WHERE event_id = 'host-setup-v2'",
            [],
            |row| row.get::<_, String>(0),
        )
        .map(|payload_json| serde_json::from_str(&payload_json).unwrap())
        .unwrap();
    assert_eq!(
        host_setup_payload["context"]["app_session_id"],
        "app-session-v2-1"
    );
    assert_eq!(host_setup_payload["flow"]["id"], "flow-v2-1");
    assert_eq!(host_setup_payload["flow"]["method"], "automatic");
    assert_eq!(
        host_setup_payload["candidates"]["selected"]["kind"],
        "local_domain"
    );
    assert_eq!(host_setup_payload["error"]["category"], "reachability");
    assert_eq!(
        host_setup_payload["detected_username"]["value"],
        Value::Null
    );
    assert_eq!(
        host_setup_payload["candidates"]["selected"]["value"],
        Value::Null
    );
    assert!(host_setup_payload["candidates"].get("all_values").is_none());
    assert_eq!(host_setup_payload["error"]["message"], Value::Null);

    let ssh_payload: Value = connection
        .query_row(
            "SELECT payload_json FROM analytics_events WHERE event_id = 'ssh-v2'",
            [],
            |row| row.get::<_, String>(0),
        )
        .map(|payload_json| serde_json::from_str(&payload_json).unwrap())
        .unwrap();
    assert_eq!(ssh_payload["session"]["id"], "ssh-session-v2-1");
    assert_eq!(ssh_payload["disconnect"]["category"], "network_error");
    assert_eq!(ssh_payload["disconnect"]["failure_stage"], "tcp_connect");
    assert_eq!(ssh_payload["disconnect"]["reason"], Value::Null);

    let flow_timeline: (String, String, String) = connection
        .query_row(
            r#"
            SELECT app_session_id, correlation_id, setup_method
            FROM analytics_user_flow_timeline
            WHERE event_id = 'host-setup-v2'
            "#,
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    assert_eq!(
        flow_timeline,
        (
            "app-session-v2-1".to_owned(),
            "flow-v2-1".to_owned(),
            "automatic".to_owned(),
        )
    );
}

#[tokio::test]
async fn analytics_ingest_accepts_mixed_v1_and_v2_batches() {
    let (app, _, database_path) = make_app_with_db_path(vec![]).await;

    ensure_default_device(&app).await;

    let response = app
        .clone()
        .oneshot(json_request(
            "/v1/analytics/events",
            analytics_ingest_body(
                "device-1",
                "secret-1",
                "app-transaction-mixed-v1-v2",
                vec![
                    serde_json::json!({
                        "event_id": "host-setup-v1-save",
                        "event_type": "host_setup_flow_event",
                        "occurred_at_epoch_seconds": 1_715_100_200_i64,
                        "payload": {
                            "flow_id": "flow-mixed-1",
                            "method": "manual",
                            "stage": "save_succeeded",
                            "is_edit": false,
                            "uses_tailscale_address": false,
                            "host_id_hash": "host-mixed-1",
                            "saved_host_count": 1
                        }
                    }),
                    analytics_event_v2(
                        "ssh-v2-ready",
                        "ssh_session_completed",
                        1_715_100_210_i64,
                        serde_json::json!({
                            "context": { "app_session_id": "app-session-mixed-1" },
                            "session": {
                                "id": "ssh-session-mixed-1",
                                "duration_seconds": 12,
                                "was_ready": true
                            },
                            "host": {
                                "id_hash": "host-mixed-1"
                            },
                            "auth": {
                                "mode": "key"
                            },
                            "disconnect": {
                                "category": "shell_closed",
                                "failure_stage": "post_ready_session"
                            },
                            "input": {
                                "had_terminal_input": true,
                                "event_count": 4
                            }
                        }),
                    ),
                ],
            ),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let connection = rusqlite::Connection::open(&database_path).unwrap();
    let engagement: (i64, i64, i64) = connection
        .query_row(
            r#"
            SELECT ready_ssh_session_count, terminal_input_ssh_session_count, distinct_hosts_used
            FROM analytics_user_engagement_summary
            "#,
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    assert_eq!(engagement, (1, 1, 1));

    let blocked_issue_count: i64 = connection
        .query_row(
            r#"
            SELECT COUNT(*)
            FROM analytics_blocked_user_candidates
            WHERE issue_kind = 'saved_host_without_ready_ssh'
            "#,
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(blocked_issue_count, 0);
}

#[tokio::test]
async fn analytics_blocked_user_views_surface_automatic_setup_blockers() {
    let (app, _, database_path) = make_app_with_db_path(vec![]).await;

    ensure_default_device(&app).await;

    let response = app
        .clone()
        .oneshot(json_request(
            "/v1/analytics/events",
            analytics_ingest_body(
                "device-1",
                "secret-1",
                "app-transaction-blocked-user",
                automatic_pairing_blocker_events("flow-blocked-1", "blocked-1", 1_715_200_000_i64),
            ),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let connection = rusqlite::Connection::open(&database_path).unwrap();
    let issue_rows: Vec<(String, String, i64)> = connection
        .prepare(
            r#"
            SELECT issue_kind, issue_severity, occurrence_count
            FROM analytics_blocked_user_candidates
            ORDER BY issue_kind ASC
            "#,
        )
        .unwrap()
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
        .unwrap()
        .collect::<rusqlite::Result<Vec<_>>>()
        .unwrap();

    assert!(issue_rows.iter().any(|row| {
        row.0 == "automatic_all_low_confidence_candidates" && row.1 == "warning" && row.2 == 1
    }));
    assert!(issue_rows.iter().any(|row| {
        row.0 == "automatic_reachability_failure_after_pairing" && row.1 == "blocked" && row.2 == 2
    }));
}

#[tokio::test]
async fn analytics_blocked_user_views_surface_verification_failed_automatic_setup_blockers() {
    let (app, _, database_path) = make_app_with_db_path(vec![]).await;

    ensure_default_device(&app).await;

    let response = app
        .clone()
        .oneshot(json_request(
            "/v1/analytics/events",
            analytics_ingest_body(
                "device-1",
                "secret-1",
                "app-transaction-verified-blocked-user",
                vec![
                    serde_json::json!({
                        "event_id": "verify-blocked-1-started",
                        "event_type": "host_setup_flow_event",
                        "occurred_at_epoch_seconds": 1_715_210_000_i64,
                        "payload": {
                            "flow_id": "flow-verify-blocked-1",
                            "method": "automatic",
                            "stage": "attempt_started",
                            "is_edit": false,
                            "uses_tailscale_address": false
                        }
                    }),
                    serde_json::json!({
                        "event_id": "verify-blocked-1-pairing-completed",
                        "event_type": "host_setup_flow_event",
                        "occurred_at_epoch_seconds": 1_715_210_010_i64,
                        "payload": {
                            "flow_id": "flow-verify-blocked-1",
                            "method": "automatic",
                            "stage": "pairing_completed",
                            "is_edit": false,
                            "uses_tailscale_address": false
                        }
                    }),
                    serde_json::json!({
                        "event_id": "verify-blocked-1-failed",
                        "event_type": "host_setup_flow_event",
                        "occurred_at_epoch_seconds": 1_715_210_020_i64,
                        "payload": {
                            "flow_id": "flow-verify-blocked-1",
                            "method": "automatic",
                            "stage": "verification_failed",
                            "is_edit": false,
                            "uses_tailscale_address": false,
                            "error_category": "connection_verification",
                            "error_message": "Public-key authentication was rejected by the server.",
                            "verification_attempt_count": 2,
                            "verification_failure_stage": "ssh_auth",
                            "verification_disconnect_category": "auth_failed"
                        }
                    }),
                ],
            ),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let connection = rusqlite::Connection::open(&database_path).unwrap();
    let issue_rows: Vec<(String, String, i64)> = connection
        .prepare(
            r#"
            SELECT issue_kind, issue_severity, occurrence_count
            FROM analytics_blocked_user_candidates
            ORDER BY issue_kind ASC
            "#,
        )
        .unwrap()
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
        .unwrap()
        .collect::<rusqlite::Result<Vec<_>>>()
        .unwrap();

    assert!(issue_rows.iter().any(|row| {
        row.0 == "automatic_reachability_failure_after_pairing" && row.1 == "blocked" && row.2 == 2
    }));
}

#[tokio::test]
async fn analytics_alerts_send_once_for_external_blocked_issues_and_respect_cooldown() {
    let (app, sender, database_path) = make_app_with_analytics_alerts(AnalyticsAlertSettings {
        destination_device_id: Some("alert-device-1".to_owned()),
        cooldown_seconds: 86_400,
        internal_device_ids: Vec::new(),
        internal_user_key_hashes: Vec::new(),
    })
    .await;

    let destination_response = app
        .clone()
        .oneshot(json_request(
            "/v1/devices/register",
            serde_json::json!({
                "device_id": "alert-device-1",
                "device_secret": "alert-secret-1",
                "apns_token": "alert-token-1",
                "bundle_id": "dev.tuist.agentty.iOS.dev",
                "push_environment": "development",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(destination_response.status(), StatusCode::NO_CONTENT);

    ensure_default_device(&app).await;

    let first_ingest = analytics_ingest_body(
        "device-1",
        "secret-1",
        "app-transaction-alert-user",
        automatic_pairing_blocker_events("flow-alert-1", "alert-run-1", 1_715_300_000_i64),
    );
    let first_response = app
        .clone()
        .oneshot(json_request("/v1/analytics/events", first_ingest, None))
        .await
        .unwrap();
    assert_eq!(first_response.status(), StatusCode::NO_CONTENT);

    let second_ingest = analytics_ingest_body(
        "device-1",
        "secret-1",
        "app-transaction-alert-user",
        automatic_pairing_blocker_events("flow-alert-1", "alert-run-2", 1_715_300_100_i64),
    );
    let second_response = app
        .clone()
        .oneshot(json_request("/v1/analytics/events", second_ingest, None))
        .await
        .unwrap();
    assert_eq!(second_response.status(), StatusCode::NO_CONTENT);

    let calls = sender.calls.lock().unwrap();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].topic, "dev.tuist.agentty.iOS.dev");
    assert_eq!(calls[0].device_token, "alert-token-1");
    assert_eq!(
        calls[0].payload["agentty.analytics"]["issue_kind"],
        "automatic_reachability_failure_after_pairing"
    );
    drop(calls);

    let connection = rusqlite::Connection::open(&database_path).unwrap();
    let alert_record: (String, i64) = connection
        .query_row(
            r#"
            SELECT issue_severity, alert_count
            FROM analytics_issue_alerts
            WHERE signature_key = 'host_setup:flow-alert-1:automatic_reachability_failure_after_pairing'
            "#,
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(alert_record.0, "blocked");
    assert_eq!(alert_record.1, 1);
}

#[tokio::test]
async fn analytics_alerts_skip_internal_source_devices() {
    let (app, sender, database_path) = make_app_with_analytics_alerts(AnalyticsAlertSettings {
        destination_device_id: Some("alert-device-1".to_owned()),
        cooldown_seconds: 86_400,
        internal_device_ids: vec!["device-1".to_owned()],
        internal_user_key_hashes: Vec::new(),
    })
    .await;

    let destination_response = app
        .clone()
        .oneshot(json_request(
            "/v1/devices/register",
            serde_json::json!({
                "device_id": "alert-device-1",
                "device_secret": "alert-secret-1",
                "apns_token": "alert-token-1",
                "bundle_id": "dev.tuist.agentty.iOS.dev",
                "push_environment": "development",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(destination_response.status(), StatusCode::NO_CONTENT);

    ensure_default_device(&app).await;

    let ingest = analytics_ingest_body(
        "device-1",
        "secret-1",
        "app-transaction-internal-user",
        automatic_pairing_blocker_events("flow-internal-1", "internal-run-1", 1_715_400_000_i64),
    );
    let response = app
        .clone()
        .oneshot(json_request("/v1/analytics/events", ingest, None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    assert!(sender.calls.lock().unwrap().is_empty());

    let connection = rusqlite::Connection::open(&database_path).unwrap();
    let stored_event_count: i64 = connection
        .query_row("SELECT COUNT(*) FROM analytics_events", [], |row| {
            row.get(0)
        })
        .unwrap();
    let alert_count: i64 = connection
        .query_row("SELECT COUNT(*) FROM analytics_issue_alerts", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(stored_event_count, 2);
    assert_eq!(alert_count, 0);
}

#[tokio::test]
async fn analytics_ingest_rejects_invalid_host_setup_payloads() {
    let (app, _) = make_app(vec![]).await;

    ensure_default_device(&app).await;

    let response = app
        .clone()
        .oneshot(json_request(
            "/v1/analytics/events",
            serde_json::json!({
                "device_id": "device-1",
                "device_secret": "secret-1",
                "app_transaction_id": "app-transaction-invalid-host-setup",
                "original_purchase_date_epoch_seconds": 1_715_000_000_i64,
                "bundle_id": MAIN_BUNDLE_ID,
                "app_transaction_environment": "production",
                "app_version": "1.2.3",
                "build_number": "45",
                "flavor": "main",
                "platform": "ios",
                "events": [
                    {
                        "event_id": "invalid-host-setup",
                        "event_type": "host_setup_flow_event",
                        "occurred_at_epoch_seconds": 1_715_000_010_i64,
                        "payload": {
                            "method": "manual",
                            "stage": "save_succeeded",
                            "is_edit": false,
                            "uses_tailscale_address": false,
                            "saved_host_count": -1,
                            "error_category": "reachability",
                            "error_message": "raw dns error for dev-host",
                            "detected_username": "developer",
                            "selected_candidate_kind": "single_label",
                            "selected_candidate_source": "hostname",
                            "selected_candidate_rank": 1,
                            "selected_candidate_value": "dev-host",
                            "candidate_values": ["dev-host", "100.64.0.1"],
                            "candidate_count": 2,
                            "high_confidence_candidate_count": 1,
                            "all_low_confidence_candidates": false
                        }
                    }
                ]
            }),
            None,
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn analytics_ingest_records_invalid_payload_failures_in_sqlite() {
    let (app, _, database_path) = make_app_with_db_path(vec![]).await;

    ensure_default_device(&app).await;

    let response = app
        .clone()
        .oneshot(json_request(
            "/v1/analytics/events",
            serde_json::json!({
                "device_id": "device-1",
                "device_secret": "secret-1",
                "app_transaction_id": "app-transaction-invalid-host-setup-recorded",
                "original_purchase_date_epoch_seconds": 1_715_000_000_i64,
                "bundle_id": MAIN_BUNDLE_ID,
                "app_transaction_environment": "production",
                "app_version": "1.2.3",
                "build_number": "45",
                "flavor": "main",
                "platform": "ios",
                "events": [
                    {
                        "event_id": "invalid-host-setup-recorded",
                        "event_type": "host_setup_flow_event",
                        "occurred_at_epoch_seconds": 1_715_000_010_i64,
                        "payload": {
                            "method": "manual",
                            "stage": "save_succeeded",
                            "is_edit": false,
                            "uses_tailscale_address": false,
                            "saved_host_count": -1
                        }
                    }
                ]
            }),
            None,
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let response_body = response_json(response).await;
    assert_eq!(
        response_body["detail"],
        "Analytics host-setup payload is invalid."
    );
    assert_eq!(response_body["event_id"], "invalid-host-setup-recorded");
    assert_eq!(response_body["event_type"], "host_setup_flow_event");
    assert_eq!(response_body["field"], "host.saved_host_count");
    assert_eq!(response_body["rule"], "non_negative");

    let connection = rusqlite::Connection::open(&database_path).unwrap();
    let failure_count: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM analytics_ingest_failures",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(failure_count, 1);

    let (
        stored_error,
        failed_event_id,
        failed_event_type,
        validation_field,
        validation_rule,
        payload_version,
        redacted_payload_shape_json,
    ): (
        String,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<i64>,
        Option<String>,
    ) = connection
        .query_row(
            r#"
            SELECT
                error,
                failed_event_id,
                failed_event_type,
                validation_field,
                validation_rule,
                payload_version,
                redacted_payload_shape_json
            FROM analytics_ingest_failures
            ORDER BY failure_id DESC
            LIMIT 1
            "#,
            [],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                ))
            },
        )
        .unwrap();
    assert_eq!(stored_error, "Analytics host-setup payload is invalid.");
    assert_eq!(
        failed_event_id.as_deref(),
        Some("invalid-host-setup-recorded")
    );
    assert_eq!(failed_event_type.as_deref(), Some("host_setup_flow_event"));
    assert_eq!(validation_field.as_deref(), Some("host.saved_host_count"));
    assert_eq!(validation_rule.as_deref(), Some("non_negative"));
    assert_eq!(payload_version, Some(1));

    let redacted_payload_shape_json = redacted_payload_shape_json.unwrap();
    assert!(redacted_payload_shape_json.contains("\"saved_host_count\":-1"));
    assert!(!redacted_payload_shape_json.contains("raw dns error"));
    assert!(!redacted_payload_shape_json.contains("developer"));
    assert!(!redacted_payload_shape_json.contains("dev-host"));
    assert!(!redacted_payload_shape_json.contains("100.64.0.1"));

    let recent_failure: (String, String, String, String, i64) = connection
        .query_row(
            r#"
            SELECT failed_event_id, failed_event_type, validation_field, validation_rule, payload_version
            FROM analytics_recent_ingest_failures
            ORDER BY failure_id DESC
            LIMIT 1
            "#,
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
        )
        .unwrap();
    assert_eq!(
        recent_failure,
        (
            "invalid-host-setup-recorded".to_owned(),
            "host_setup_flow_event".to_owned(),
            "host.saved_host_count".to_owned(),
            "non_negative".to_owned(),
            1,
        )
    );

    let summary_failure: (String, String, String, String, String) = connection
        .query_row(
            r#"
            SELECT failed_event_id, failed_event_type, validation_field, validation_rule, payload_version
            FROM analytics_ingest_failure_summary
            LIMIT 1
            "#,
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
        )
        .unwrap();
    assert_eq!(
        summary_failure,
        (
            "invalid-host-setup-recorded".to_owned(),
            "host_setup_flow_event".to_owned(),
            "host.saved_host_count".to_owned(),
            "non_negative".to_owned(),
            "1".to_owned(),
        )
    );
}

#[tokio::test]
async fn analytics_ingest_rejects_unknown_payload_version() {
    let (app, _sender) = make_app(vec![]).await;

    ensure_default_device(&app).await;

    let response = app
        .oneshot(json_request(
            "/v1/analytics/events",
            analytics_ingest_body(
                "device-1",
                "secret-1",
                "app-transaction-invalid-payload-version",
                vec![serde_json::json!({
                    "event_id": "host-setup-unsupported-version",
                    "event_type": "host_setup_flow_event",
                    "occurred_at_epoch_seconds": 1_715_000_000_i64,
                    "payload_version": 3,
                    "payload": {
                        "context": { "app_session_id": "app-session-1" },
                        "flow": {
                            "method": "manual",
                            "stage": "save_succeeded",
                            "is_edit": false,
                            "uses_tailscale_address": false
                        }
                    }
                })],
            ),
            None,
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn relay_session_issue_accepts_mixed_case_uuid_device_ids() {
    let (app, _, _) = make_app_with_db_path(vec![]).await;

    ensure_production_device(&app, MIXED_CASE_DEVICE_ID_UPPER, "secret-uuid").await;

    let response = app
        .clone()
        .oneshot(json_request(
            "/v1/relay-sessions",
            serde_json::json!({
                "device_id": MIXED_CASE_DEVICE_ID_LOWER,
                "device_secret": "secret-uuid",
            }),
            None,
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
}

#[tokio::test]
async fn analytics_ingest_accepts_mixed_case_uuid_device_ids() {
    let (app, _, database_path) = make_app_with_db_path(vec![]).await;

    ensure_production_device(&app, MIXED_CASE_DEVICE_ID_UPPER, "secret-uuid").await;

    let response = app
        .clone()
        .oneshot(json_request(
            "/v1/analytics/events",
            serde_json::json!({
                "device_id": MIXED_CASE_DEVICE_ID_LOWER,
                "device_secret": "secret-uuid",
                "app_transaction_id": "app-transaction-mixed-case",
                "original_purchase_date_epoch_seconds": 1_715_000_000_i64,
                "bundle_id": MAIN_BUNDLE_ID,
                "app_transaction_environment": "production",
                "app_version": "1.2.3",
                "build_number": "45",
                "flavor": "main",
                "platform": "ios",
                "events": [
                    {
                        "event_id": "event-mixed-case",
                        "event_type": "app_session_completed",
                        "occurred_at_epoch_seconds": 1_715_000_010_i64,
                        "payload": {
                            "app_session_id": "app-session-mixed-case-1",
                            "duration_seconds": 12,
                            "has_finished_initial_access_load": true,
                            "has_lifetime_access": false,
                            "trial_expired": false,
                            "trial_consumed_usage_seconds": 12.0,
                            "trial_remaining_usage_seconds": 17_988.0,
                            "interactive_content_allowed": true,
                            "gate_blocking": false
                        }
                    }
                ]
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let connection = rusqlite::Connection::open(&database_path).unwrap();
    let stored_device_id: String = connection
        .query_row(
            "SELECT device_id FROM devices WHERE device_id = ?",
            [MIXED_CASE_DEVICE_ID_LOWER],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(stored_device_id, MIXED_CASE_DEVICE_ID_LOWER);

    let event_count: i64 = connection
        .query_row("SELECT COUNT(*) FROM analytics_events", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(event_count, 1);
}

#[tokio::test]
async fn real_http_analytics_ingest_accepts_mixed_case_uuid_device_ids() {
    let (app, _, database_path) = make_app_with_db_path(vec![]).await;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });

    let client = reqwest::Client::new();

    let ensure_response = client
        .post(format!("http://{address}/v1/devices/ensure"))
        .json(&serde_json::json!({
            "device_id": MIXED_CASE_DEVICE_ID_UPPER,
            "device_secret": "secret-uuid-http",
            "bundle_id": MAIN_BUNDLE_ID,
            "push_environment": "production",
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(ensure_response.status(), StatusCode::NO_CONTENT);

    let analytics_response = client
        .post(format!("http://{address}/v1/analytics/events"))
        .json(&serde_json::json!({
            "device_id": MIXED_CASE_DEVICE_ID_LOWER,
            "device_secret": "secret-uuid-http",
            "app_transaction_id": "app-transaction-real-http",
            "original_purchase_date_epoch_seconds": 1_715_000_000_i64,
            "bundle_id": MAIN_BUNDLE_ID,
            "app_transaction_environment": "production",
            "app_version": "1.2.3",
            "build_number": "45",
            "flavor": "main",
            "platform": "ios",
            "events": [
                {
                    "event_id": "event-real-http",
                    "event_type": "access_state_snapshot",
                    "occurred_at_epoch_seconds": 1_715_000_010_i64,
                    "payload": {
                        "reason": "startup",
                        "has_finished_initial_access_load": true,
                        "has_lifetime_access": false,
                        "trial_expired": false,
                        "trial_consumed_usage_seconds": 3.0,
                        "trial_remaining_usage_seconds": 17_997.0,
                        "interactive_content_allowed": true,
                        "gate_blocking": false
                    }
                }
            ]
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(analytics_response.status(), StatusCode::NO_CONTENT);

    server.abort();
    let _ = server.await;

    let connection = rusqlite::Connection::open(&database_path).unwrap();
    let event_count: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM analytics_events WHERE event_id = ?",
            ["event-real-http"],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(event_count, 1);
}

#[tokio::test]
async fn reopening_database_prunes_expired_pairing_with_unconsumed_bootstrap() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("backend.sqlite3");
    let database = Database::open(path.clone()).await.unwrap();
    database
        .ensure_device_identity(
            "device".to_owned(),
            "secret".to_owned(),
            MAIN_BUNDLE_ID.to_owned(),
            PushEnvironment::Production,
        )
        .await
        .unwrap();
    let mut sessions = Vec::new();
    for _ in 0..2 {
        let pairing = database.create_pairing_session().await.unwrap();
        database
            .claim_pairing_session(
                pairing.pairing_code,
                "device".to_owned(),
                "ssh-ed25519 test".to_owned(),
            )
            .await
            .unwrap()
            .unwrap();
        database
            .issue_connector_bootstrap_token(pairing.session_id.clone(), pairing.host_token)
            .await
            .unwrap()
            .unwrap();
        sessions.push(pairing.session_id);
    }
    drop(database);
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection.execute("PRAGMA foreign_keys = ON", []).unwrap();
    connection.execute(
        "UPDATE connector_bootstrap_tokens SET expires_at_epoch_seconds = unixepoch() - 86401 WHERE session_id = ?",
        [&sessions[0]],
    ).unwrap();
    connection.execute(
        "UPDATE pairing_sessions SET status = 'failed', expires_at_epoch_seconds = unixepoch() - 86401 WHERE session_id = ?",
        [&sessions[0]],
    ).unwrap();
    let database = Database::open(path).await.unwrap();
    for table in ["pairing_sessions", "connector_bootstrap_tokens"] {
        let retained: Vec<String> = connection
            .prepare(&format!("SELECT session_id FROM {table}"))
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap();
        assert_eq!(retained, vec![sessions[1].clone()]);
    }
    assert!(
        connection
            .prepare("PRAGMA foreign_key_check")
            .unwrap()
            .query([])
            .unwrap()
            .next()
            .unwrap()
            .is_none()
    );
    drop(database);
}

#[tokio::test]
async fn reopening_database_normalizes_legacy_device_ids_across_tables() {
    let database_path = NamedTempFile::new()
        .unwrap()
        .into_temp_path()
        .keep()
        .unwrap();
    let database = Database::open(database_path.clone()).await.unwrap();

    assert!(
        database
            .ensure_device_identity(
                MIXED_CASE_DEVICE_ID_LOWER.to_owned(),
                "secret-uuid".to_owned(),
                MAIN_BUNDLE_ID.to_owned(),
                PushEnvironment::Production,
            )
            .await
            .unwrap()
    );
    assert!(
        database
            .issue_relay_session(
                MIXED_CASE_DEVICE_ID_LOWER.to_owned(),
                "secret-uuid".to_owned(),
                "legacy".to_owned(),
                None,
            )
            .await
            .unwrap()
            .is_some()
    );

    let pairing_session = database.create_pairing_session().await.unwrap();
    assert!(
        database
            .claim_pairing_session(
                pairing_session.pairing_code,
                MIXED_CASE_DEVICE_ID_LOWER.to_owned(),
                "ssh-ed25519 AAAAC3Nza legacy@test".to_owned(),
            )
            .await
            .unwrap()
            .is_some()
    );

    let quota_result = database
        .reserve_admitted_dictation(
            MIXED_CASE_DEVICE_ID_LOWER.to_owned(),
            None,
            Default::default(),
            1_715_000_000_i64,
            15,
            1_715_604_800_i64,
        )
        .await
        .unwrap();
    assert!(quota_result.is_ok());

    database
        .ingest_analytics_batch(
            MIXED_CASE_DEVICE_ID_LOWER.to_owned(),
            AnalyticsDeviceContextRecord {
                system_version: None,
                device_model_identifier: None,
                device_family: None,
                locale_identifier: None,
                preferred_languages_json: None,
            },
            "user-hash-1".to_owned(),
            1_715_000_000_i64,
            MAIN_BUNDLE_ID.to_owned(),
            "production".to_owned(),
            "1.2.3".to_owned(),
            "45".to_owned(),
            "main".to_owned(),
            "ios".to_owned(),
            vec![AnalyticsEventRecord {
                event_id: "event-legacy-migration".to_owned(),
                event_type: AnalyticsEventType::SshSessionCompleted,
                occurred_at_epoch_seconds: 1_715_000_020_i64,
                payload_json: serde_json::json!({
                    "session_id": "ssh-session-legacy",
                    "host_key_hash": "host-hash-legacy",
                    "duration_seconds": 120,
                    "was_ready": true,
                    "disconnect_reason": "network_error"
                })
                .to_string(),
                access_state: None,
                saved_host_count: None,
                sensitive_context: None,
            }],
        )
        .await
        .unwrap();

    drop(database);

    let connection = rusqlite::Connection::open(&database_path).unwrap();
    connection
        .execute_batch("PRAGMA foreign_keys = OFF;")
        .unwrap();
    connection
        .execute("UPDATE devices SET device_id = upper(device_id)", [])
        .unwrap();
    connection
        .execute("UPDATE relay_sessions SET device_id = upper(device_id)", [])
        .unwrap();
    connection
        .execute(
            "UPDATE pairing_sessions SET device_id = upper(device_id) WHERE device_id IS NOT NULL",
            [],
        )
        .unwrap();
    connection
        .execute(
            "UPDATE dictation_usage_weekly SET device_id = upper(device_id)",
            [],
        )
        .unwrap();
    connection
        .execute(
            "UPDATE analytics_device_user_links SET device_id = upper(device_id)",
            [],
        )
        .unwrap();
    connection
        .execute(
            "UPDATE analytics_events SET device_id = upper(device_id)",
            [],
        )
        .unwrap();
    drop(connection);

    let migrated_database = Database::open(database_path.clone()).await.unwrap();
    assert!(
        migrated_database
            .issue_relay_session(
                MIXED_CASE_DEVICE_ID_LOWER.to_owned(),
                "secret-uuid".to_owned(),
                "legacy".to_owned(),
                None,
            )
            .await
            .unwrap()
            .is_some()
    );
    drop(migrated_database);

    let connection = rusqlite::Connection::open(&database_path).unwrap();
    for table in [
        "devices",
        "relay_sessions",
        "dictation_usage_weekly",
        "analytics_device_user_links",
        "analytics_events",
    ] {
        let uppercase_count: i64 = connection
            .query_row(
                &format!(
                    "SELECT COUNT(*) FROM {table} WHERE device_id = ?",
                    table = table
                ),
                [MIXED_CASE_DEVICE_ID_UPPER],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            uppercase_count, 0,
            "table {table} retained uppercase device_id"
        );

        let lowercase_count: i64 = connection
            .query_row(
                &format!(
                    "SELECT COUNT(*) FROM {table} WHERE device_id = ?",
                    table = table
                ),
                [MIXED_CASE_DEVICE_ID_LOWER],
                |row| row.get(0),
            )
            .unwrap();
        assert!(
            lowercase_count > 0,
            "table {table} lost the canonical device_id"
        );
    }

    let pairing_uppercase_count: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM pairing_sessions WHERE device_id = ?",
            [MIXED_CASE_DEVICE_ID_UPPER],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(pairing_uppercase_count, 0);

    let pairing_lowercase_count: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM pairing_sessions WHERE device_id = ?",
            [MIXED_CASE_DEVICE_ID_LOWER],
            |row| row.get(0),
        )
        .unwrap();
    assert!(pairing_lowercase_count > 0);

    let foreign_key_violation: Option<String> = connection
        .query_row("PRAGMA foreign_key_check", [], |row| row.get(0))
        .optional()
        .unwrap();
    assert_eq!(foreign_key_violation, None);
}

#[tokio::test]
async fn reopening_database_rejects_orphaned_device_references() {
    let database_path = NamedTempFile::new()
        .unwrap()
        .into_temp_path()
        .keep()
        .unwrap();
    let database = Database::open(database_path.clone()).await.unwrap();
    drop(database);

    let connection = rusqlite::Connection::open(&database_path).unwrap();
    connection
        .execute_batch("PRAGMA foreign_keys = OFF;")
        .unwrap();
    connection
        .execute(
            r#"
            INSERT INTO relay_sessions (
                relay_token_hash,
                device_id,
                expires_at_epoch_seconds,
                created_at_epoch_seconds
            )
            VALUES (?, ?, ?, ?)
            "#,
            rusqlite::params![
                "orphan-relay-token-hash",
                "missing-device",
                1_715_000_060_i64,
                1_715_000_000_i64,
            ],
        )
        .unwrap();
    drop(connection);

    let error = match Database::open(database_path).await {
        Ok(_) => panic!("expected orphaned relay session to fail integrity checks"),
        Err(error) => error,
    };
    let error_text = format!("{error:#}");
    assert!(error_text.contains("foreign key violation in relay_sessions"));
}

#[tokio::test]
async fn reopening_database_rejects_case_colliding_dictation_rows() {
    let database_path = NamedTempFile::new()
        .unwrap()
        .into_temp_path()
        .keep()
        .unwrap();
    let database = Database::open(database_path.clone()).await.unwrap();

    assert!(
        database
            .ensure_device_identity(
                MIXED_CASE_DEVICE_ID_LOWER.to_owned(),
                "secret-uuid".to_owned(),
                MAIN_BUNDLE_ID.to_owned(),
                PushEnvironment::Production,
            )
            .await
            .unwrap()
    );
    let quota_result = database
        .reserve_admitted_dictation(
            MIXED_CASE_DEVICE_ID_LOWER.to_owned(),
            None,
            Default::default(),
            1_715_000_000_i64,
            15,
            1_715_604_800_i64,
        )
        .await
        .unwrap();
    assert!(quota_result.is_ok());
    drop(database);

    let connection = rusqlite::Connection::open(&database_path).unwrap();
    connection
        .execute_batch("PRAGMA foreign_keys = OFF;")
        .unwrap();
    connection
        .execute(
            r#"
            INSERT INTO dictation_usage_weekly (
                device_id,
                week_start_epoch_seconds,
                used_seconds,
                created_at_epoch_seconds,
                updated_at_epoch_seconds
            )
            VALUES (?, ?, ?, ?, ?)
            "#,
            rusqlite::params![
                MIXED_CASE_DEVICE_ID_UPPER,
                1_715_000_000_i64,
                30,
                1_715_000_000_i64,
                1_715_000_000_i64,
            ],
        )
        .unwrap();
    drop(connection);

    let error = match Database::open(database_path).await {
        Ok(_) => panic!("expected case-colliding dictation rows to fail normalization"),
        Err(error) => error,
    };
    let error_text = format!("{error:#}");
    assert!(error_text.contains("multiple dictation usage rows collapse"));
}

#[tokio::test]
async fn analytics_ingest_is_idempotent_and_links_multiple_devices_to_one_user() {
    let (app, _, database_path) = make_app_with_db_path(vec![]).await;

    ensure_default_device(&app).await;

    let device_two_response = app
        .clone()
        .oneshot(json_request(
            "/v1/devices/ensure",
            serde_json::json!({
                "device_id": "device-2",
                "device_secret": "secret-2",
                "bundle_id": "dev.tuist.agentty.iOS",
                "push_environment": "production",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(device_two_response.status(), StatusCode::NO_CONTENT);

    let first_ingest = serde_json::json!({
        "device_id": "device-1",
        "device_secret": "secret-1",
        "app_transaction_id": "shared-user-transaction",
        "original_purchase_date_epoch_seconds": 1_715_000_000_i64,
        "bundle_id": "dev.tuist.agentty.iOS",
        "app_transaction_environment": "production",
        "app_version": "1.2.3",
        "build_number": "45",
        "flavor": "main",
        "platform": "ios",
        "events": [
            {
                "event_id": "shared-event-1",
                "event_type": "app_session_completed",
                "occurred_at_epoch_seconds": 1_715_000_030_i64,
                "payload": {
                    "app_session_id": "shared-app-session-1",
                    "duration_seconds": 42,
                    "has_finished_initial_access_load": true,
                    "has_lifetime_access": false,
                    "trial_expired": false,
                    "trial_consumed_usage_seconds": 120.0,
                    "trial_remaining_usage_seconds": 28_680.0,
                    "interactive_content_allowed": true,
                    "gate_blocking": false
                }
            }
        ]
    });

    let response = app
        .clone()
        .oneshot(json_request(
            "/v1/analytics/events",
            first_ingest.clone(),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let duplicate_response = app
        .clone()
        .oneshot(json_request("/v1/analytics/events", first_ingest, None))
        .await
        .unwrap();
    assert_eq!(duplicate_response.status(), StatusCode::NO_CONTENT);

    let second_device_response = app
        .clone()
        .oneshot(json_request(
            "/v1/analytics/events",
            serde_json::json!({
                "device_id": "device-2",
                "device_secret": "secret-2",
                "app_transaction_id": "shared-user-transaction",
                "original_purchase_date_epoch_seconds": 1_715_000_000_i64,
                "bundle_id": "dev.tuist.agentty.iOS",
                "app_transaction_environment": "production",
                "app_version": "1.2.3",
                "build_number": "45",
                "flavor": "main",
                "platform": "ios",
                "events": [
                    {
                        "event_id": "shared-event-2",
                        "event_type": "purchase_flow_event",
                        "occurred_at_epoch_seconds": 1_715_000_040_i64,
                        "payload": {
                            "kind": "purchase",
                            "state": "success"
                        }
                    }
                ]
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(second_device_response.status(), StatusCode::NO_CONTENT);

    let connection = rusqlite::Connection::open(&database_path).unwrap();
    let user_count: i64 = connection
        .query_row("SELECT COUNT(*) FROM analytics_users", [], |row| row.get(0))
        .unwrap();
    let link_count: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM analytics_device_user_links",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let event_count: i64 = connection
        .query_row("SELECT COUNT(*) FROM analytics_events", [], |row| {
            row.get(0)
        })
        .unwrap();

    assert_eq!(user_count, 1);
    assert_eq!(link_count, 2);
    assert_eq!(event_count, 2);
}

#[tokio::test]
async fn analytics_ingest_rejects_non_production_devices_and_invalid_credentials() {
    let (app, _) = make_app(vec![]).await;

    register_default_device(&app).await;

    let forbidden_response = app
        .clone()
        .oneshot(json_request(
            "/v1/analytics/events",
            serde_json::json!({
                "device_id": "device-1",
                "device_secret": "secret-1",
                "app_transaction_id": "app-transaction-1",
                "original_purchase_date_epoch_seconds": 1_715_000_000_i64,
                "bundle_id": "dev.tuist.agentty.iOS",
                "app_transaction_environment": "production",
                "app_version": "1.2.3",
                "build_number": "45",
                "flavor": "main",
                "platform": "ios",
                "events": [
                    {
                        "event_id": "event-1",
                        "event_type": "access_state_snapshot",
                        "occurred_at_epoch_seconds": 1_715_000_010_i64,
                        "payload": {
                            "reason": "startup",
                            "has_finished_initial_access_load": true,
                            "has_lifetime_access": false,
                            "trial_expired": false,
                            "trial_consumed_usage_seconds": 0.0,
                            "trial_remaining_usage_seconds": 28_800.0,
                            "interactive_content_allowed": true,
                            "gate_blocking": false
                        }
                    }
                ]
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(forbidden_response.status(), StatusCode::FORBIDDEN);

    ensure_default_device(&app).await;
    let unauthorized_response = app
        .clone()
        .oneshot(json_request(
            "/v1/analytics/events",
            serde_json::json!({
                "device_id": "device-1",
                "device_secret": "wrong-secret",
                "app_transaction_id": "app-transaction-1",
                "original_purchase_date_epoch_seconds": 1_715_000_000_i64,
                "bundle_id": "dev.tuist.agentty.iOS",
                "app_transaction_environment": "production",
                "app_version": "1.2.3",
                "build_number": "45",
                "flavor": "main",
                "platform": "ios",
                "events": [
                    {
                        "event_id": "event-2",
                        "event_type": "purchase_flow_event",
                        "occurred_at_epoch_seconds": 1_715_000_010_i64,
                        "payload": {
                            "kind": "purchase",
                            "state": "failed"
                        }
                    }
                ]
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(unauthorized_response.status(), StatusCode::UNAUTHORIZED);
}

async fn make_app(internal_clients: Vec<InternalClientSettings>) -> (axum::Router, FakePushSender) {
    let (app, sender, _) = make_app_with_db_path(internal_clients).await;
    (app, sender)
}

async fn make_app_with_dictation(
    internal_clients: Vec<InternalClientSettings>,
    transcriber: FakeDictationTranscriber,
) -> (axum::Router, FakePushSender) {
    let database_path = NamedTempFile::new()
        .unwrap()
        .into_temp_path()
        .keep()
        .unwrap();
    let database = Database::open(database_path).await.unwrap();
    let sender = FakePushSender::default();

    (
        create_test_app_with_transcriber(
            database,
            Arc::new(sender.clone()),
            Arc::new(transcriber),
            internal_clients,
            test_limits(),
        ),
        sender,
    )
}

async fn make_app_with_db_path(
    internal_clients: Vec<InternalClientSettings>,
) -> (axum::Router, FakePushSender, PathBuf) {
    let database_path = NamedTempFile::new()
        .unwrap()
        .into_temp_path()
        .keep()
        .unwrap();
    let database = Database::open(database_path.clone()).await.unwrap();
    let sender = FakePushSender::default();
    (
        create_test_app(
            database,
            Arc::new(sender.clone()),
            internal_clients,
            test_limits(),
        ),
        sender,
        database_path,
    )
}

async fn make_app_with_analytics_alerts(
    analytics_alerts: AnalyticsAlertSettings,
) -> (axum::Router, FakePushSender, PathBuf) {
    let database_path = NamedTempFile::new()
        .unwrap()
        .into_temp_path()
        .keep()
        .unwrap();
    let database = Database::open(database_path.clone()).await.unwrap();
    let sender = FakePushSender::default();

    let app = build_router(AppState {
        admission: Arc::new(agentty_backend::admission::Admission::new(
            Default::default(),
        )),
        database,
        push_sender: Arc::new(sender.clone()),
        dictation_transcriber: Arc::new(FakeDictationTranscriber::default()),
        internal_clients: Arc::new(Vec::new()),
        analytics_alerts: Arc::new(analytics_alerts),
        relay_broker: RelayBroker::default(),
        relay_tokens: Arc::new(RelayTokenManager::for_test("https://agentty-notify.test").unwrap()),
    });

    (app, sender, database_path)
}

async fn register_default_device(app: &axum::Router) {
    let response = app
        .clone()
        .oneshot(json_request(
            "/v1/devices/register",
            serde_json::json!({
                "device_id": "device-1",
                "device_secret": "secret-1",
                "apns_token": "token-1",
                "bundle_id": "dev.tuist.agentty.iOS.dev",
                "push_environment": "development",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
}

async fn ensure_default_device(app: &axum::Router) {
    ensure_production_device(app, "device-1", "secret-1").await;
}

async fn ensure_production_device(app: &axum::Router, device_id: &str, device_secret: &str) {
    let response = app
        .clone()
        .oneshot(json_request(
            "/v1/devices/ensure",
            serde_json::json!({
                "device_id": device_id,
                "device_secret": device_secret,
                "bundle_id": MAIN_BUNDLE_ID,
                "push_environment": "production",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
}

async fn issue_default_session(app: &axum::Router) -> String {
    let response = app
        .clone()
        .oneshot(json_request(
            "/v1/relay-sessions",
            serde_json::json!({
                "device_id": "device-1",
                "device_secret": "secret-1",
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    response_json(response).await["relay_token"]
        .as_str()
        .unwrap()
        .to_owned()
}

fn json_request(path: &str, body: Value, authorization: Option<String>) -> Request<Body> {
    let mut builder = Request::builder()
        .method("POST")
        .uri(path)
        .header("content-type", "application/json");
    if let Some(authorization) = authorization {
        builder = builder.header("authorization", authorization);
    }

    builder.body(Body::from(body.to_string())).unwrap()
}

async fn response_json(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

fn analytics_ingest_body(
    device_id: &str,
    device_secret: &str,
    app_transaction_id: &str,
    events: Vec<Value>,
) -> Value {
    serde_json::json!({
        "device_id": device_id,
        "device_secret": device_secret,
        "app_transaction_id": app_transaction_id,
        "original_purchase_date_epoch_seconds": 1_715_000_000_i64,
        "bundle_id": MAIN_BUNDLE_ID,
        "app_transaction_environment": "production",
        "app_version": "1.2.3",
        "build_number": "45",
        "flavor": "main",
        "platform": "ios",
        "events": events,
    })
}

fn analytics_event_v2(
    event_id: &str,
    event_type: &str,
    occurred_at_epoch_seconds: i64,
    payload: Value,
) -> Value {
    serde_json::json!({
        "event_id": event_id,
        "event_type": event_type,
        "occurred_at_epoch_seconds": occurred_at_epoch_seconds,
        "payload_version": 2,
        "payload": payload,
    })
}

fn automatic_pairing_blocker_events(
    flow_id: &str,
    event_id_prefix: &str,
    started_at_epoch_seconds: i64,
) -> Vec<Value> {
    vec![
        serde_json::json!({
            "event_id": format!("{event_id_prefix}-pairing-completed"),
            "event_type": "host_setup_flow_event",
            "occurred_at_epoch_seconds": started_at_epoch_seconds,
            "payload": {
                "app_session_id": "app-session-1",
                "flow_id": flow_id,
                "method": "automatic",
                "stage": "pairing_completed",
                "is_edit": false,
                "uses_tailscale_address": false,
                "detected_username": "developer",
                "detected_username_source": "whoami_command",
                "username_suspicious": true,
                "selected_candidate_kind": "single_label",
                "selected_candidate_source": "hostname",
                "selected_candidate_rank": 1,
                "selected_candidate_value": "agentty",
                "candidate_values": ["agentty"],
                "candidate_count": 1,
                "high_confidence_candidate_count": 0,
                "all_low_confidence_candidates": true
            }
        }),
        serde_json::json!({
            "event_id": format!("{event_id_prefix}-reachability-failed"),
            "event_type": "host_setup_flow_event",
            "occurred_at_epoch_seconds": started_at_epoch_seconds + 5,
            "payload": {
                "app_session_id": "app-session-1",
                "flow_id": flow_id,
                "method": "automatic",
                "stage": "failed",
                "is_edit": false,
                "uses_tailscale_address": false,
                "error_category": "reachability",
                "error_message": "dial tcp agentty: no route to host",
                "probe_attempt_count": 2,
                "reachability_failure_subtype": "dns"
            }
        }),
    ]
}

fn pcm_wav_base64(seconds: u32) -> String {
    use base64::Engine;

    let sample_rate = 16_000_u32;
    let channels = 1_u16;
    let bits_per_sample = 16_u16;
    let bytes_per_sample = u32::from(bits_per_sample / 8);
    let data_bytes = sample_rate * seconds * u32::from(channels) * bytes_per_sample;
    let block_align = channels * (bits_per_sample / 8);
    let byte_rate = sample_rate * u32::from(block_align);
    let chunk_size = 36 + data_bytes;

    let mut wav = Vec::new();
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&chunk_size.to_le_bytes());
    wav.extend_from_slice(b"WAVE");
    wav.extend_from_slice(b"fmt ");
    wav.extend_from_slice(&16_u32.to_le_bytes());
    wav.extend_from_slice(&1_u16.to_le_bytes());
    wav.extend_from_slice(&channels.to_le_bytes());
    wav.extend_from_slice(&sample_rate.to_le_bytes());
    wav.extend_from_slice(&byte_rate.to_le_bytes());
    wav.extend_from_slice(&block_align.to_le_bytes());
    wav.extend_from_slice(&bits_per_sample.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_bytes.to_le_bytes());
    wav.resize(wav.len() + data_bytes as usize, 0);

    base64::engine::general_purpose::STANDARD.encode(wav)
}

fn default_internal_clients() -> Vec<InternalClientSettings> {
    vec![
        InternalClientSettings {
            caller: InternalCaller::RemoteCoder,
            token: "token-remotecoder".to_owned(),
        },
        InternalClientSettings {
            caller: InternalCaller::PingBooks,
            token: "token-pingbooks".to_owned(),
        },
    ]
}

#[tokio::test]
async fn notification_scope_cannot_spend_dictation() {
    let transcriber = FakeDictationTranscriber::default();
    let (app, _) = make_app_with_dictation(vec![], transcriber.clone()).await;
    ensure_default_device(&app).await;
    let response = app.clone().oneshot(json_request("/v1/relay-sessions", serde_json::json!({"device_id":"device-1", "device_secret":"secret-1", "scope":"notify"}), None)).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let token = response_json(response).await["relay_token"]
        .as_str()
        .unwrap()
        .to_owned();
    let response = app.clone().oneshot(json_request("/v1/dictation/transcriptions", serde_json::json!({"audio_base64":pcm_wav_base64(1), "mime_type":"audio/wav", "file_name":"audio.wav"}), Some(format!("Bearer {token}")))).await.unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    assert!(transcriber.calls.lock().unwrap().is_empty());
}

#[tokio::test]
async fn unauthenticated_invalid_analytics_never_creates_durable_diagnostics() {
    let (app, _, path) = make_app_with_db_path(vec![]).await;
    let response = app
        .oneshot(json_request(
            "/v1/analytics/events",
            analytics_ingest_body(
                "unregistered",
                "wrong-secret",
                "untrusted-id",
                vec![analytics_event_v2(
                    "invalid-event",
                    "host_setup_flow_event",
                    1_715_000_000,
                    serde_json::json!({}),
                )],
            ),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    let connection = rusqlite::Connection::open(path).unwrap();
    let count: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM analytics_ingest_failures",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(count, 0);
}

#[tokio::test]
async fn identity_and_operator_budgets_survive_new_devices_and_restarts() {
    use agentty_backend::config::DictationLimits;
    let path = NamedTempFile::new()
        .unwrap()
        .into_temp_path()
        .keep()
        .unwrap();
    let database = Database::open(path.clone()).await.unwrap();
    let week = 1_790_000_000;
    let mut limits = DictationLimits::default();
    limits.weekly_seconds = 2000;
    limits.legacy_weekly_seconds = 50;
    for device in ["device-a", "device-b"] {
        assert!(
            database
                .ensure_device_identity(
                    device.to_owned(),
                    "secret".to_owned(),
                    MAIN_BUNDLE_ID.to_owned(),
                    PushEnvironment::Production
                )
                .await
                .unwrap()
        );
    }
    assert!(
        database
            .reserve_admitted_dictation(
                "device-a".to_owned(),
                Some("verified-identity".to_owned()),
                limits.clone(),
                week,
                1700,
                week + 604800
            )
            .await
            .unwrap()
            .is_ok()
    );
    drop(database);
    let database = Database::open(path).await.unwrap();
    let quota = database
        .reserve_admitted_dictation(
            "device-b".to_owned(),
            Some("verified-identity".to_owned()),
            limits.clone(),
            week,
            101,
            week + 604800,
        )
        .await
        .unwrap()
        .unwrap_err();
    assert!(!quota.operator_limit);
    assert_eq!(quota.remaining_seconds, 100);
    assert!(
        database
            .reserve_admitted_dictation(
                "device-a".to_owned(),
                None,
                limits.clone(),
                week,
                50,
                week + 604800
            )
            .await
            .unwrap()
            .is_ok()
    );
    assert!(
        database
            .reserve_admitted_dictation(
                "device-b".to_owned(),
                None,
                limits.clone(),
                week,
                1,
                week + 604800
            )
            .await
            .unwrap()
            .unwrap_err()
            .operator_limit
    );
    assert!(
        database
            .reserve_admitted_dictation(
                "device-b".to_owned(),
                Some("another-identity".to_owned()),
                limits.clone(),
                week,
                251,
                week + 604800
            )
            .await
            .unwrap()
            .unwrap_err()
            .operator_limit
    );
    assert!(
        database
            .reserve_admitted_dictation(
                "device-b".to_owned(),
                Some("another-identity".to_owned()),
                limits.clone(),
                week,
                250,
                week + 604800
            )
            .await
            .unwrap()
            .is_ok()
    );
    assert!(
        database
            .reserve_admitted_dictation(
                "device-b".to_owned(),
                Some("another-identity".to_owned()),
                limits,
                week,
                1,
                week + 604800
            )
            .await
            .unwrap()
            .unwrap_err()
            .operator_limit
    );
}

#[tokio::test]
async fn host_identity_alone_cannot_replace_a_connector_but_host_possession_can() {
    use agentty_backend::models::PairingPlatform;
    let path = NamedTempFile::new()
        .unwrap()
        .into_temp_path()
        .keep()
        .unwrap();
    let database = Database::open(path).await.unwrap();
    for device in ["owner", "new-phone"] {
        database
            .ensure_device_identity(
                device.to_owned(),
                "secret".to_owned(),
                MAIN_BUNDLE_ID.to_owned(),
                PushEnvironment::Production,
            )
            .await
            .unwrap();
    }
    async fn bootstrap(database: &Database, device: &str) -> String {
        let pairing = database.create_pairing_session().await.unwrap();
        database
            .claim_pairing_session(
                pairing.pairing_code,
                device.to_owned(),
                "ssh-ed25519 test".to_owned(),
            )
            .await
            .unwrap()
            .unwrap();
        database
            .issue_connector_bootstrap_token(pairing.session_id, pairing.host_token)
            .await
            .unwrap()
            .unwrap()
            .token
    }
    let first = database
        .register_connector_from_bootstrap(
            bootstrap(&database, "owner").await,
            "machine".to_owned(),
            "user".to_owned(),
            PairingPlatform::Macos,
            22,
            None,
            None,
            true,
        )
        .await
        .unwrap()
        .unwrap();
    let new_phone_token = bootstrap(&database, "new-phone").await;
    assert!(
        database
            .register_connector_from_bootstrap(
                new_phone_token.clone(),
                "machine".to_owned(),
                "user".to_owned(),
                PairingPlatform::Macos,
                22,
                None,
                None,
                true,
            )
            .await
            .unwrap()
            .is_none()
    );
    assert!(
        database
            .connector_for_credentials(first.connector_id.clone(), first.connector_secret.clone())
            .await
            .unwrap()
            .is_some()
    );
    let adopted = database
        .register_connector_from_bootstrap(
            new_phone_token,
            "machine".to_owned(),
            "user".to_owned(),
            PairingPlatform::Macos,
            22,
            Some(first.connector_id),
            Some(first.connector_secret),
            true,
        )
        .await
        .unwrap()
        .unwrap();
    assert_eq!(first.relay_host_id, adopted.relay_host_id);
    assert!(
        database
            .connector_for_credentials(adopted.connector_id, adopted.connector_secret)
            .await
            .unwrap()
            .is_some()
    );
    let first_session = database
        .create_ssh_relay_session(
            "owner".to_owned(),
            "secret".to_owned(),
            adopted.relay_host_id.clone(),
        )
        .await
        .unwrap()
        .unwrap();
    let second_session = database
        .create_ssh_relay_session(
            "new-phone".to_owned(),
            "secret".to_owned(),
            adopted.relay_host_id,
        )
        .await
        .unwrap()
        .unwrap();
    let limits = agentty_backend::config::DictationLimits {
        relay_daily_bytes: 100,
        relay_device_daily_bytes: 10,
        relay_legacy_daily_bytes: 5,
        ..Default::default()
    };
    assert!(
        database
            .charge_relay_bandwidth(first_session.relay_session_id, 3, limits.clone())
            .await
            .unwrap()
    );
    assert!(
        !database
            .charge_relay_bandwidth(second_session.relay_session_id, 3, limits.clone())
            .await
            .unwrap()
    );
    assert!(
        !database
            .relay_bandwidth_available("owner".to_owned(), limits.clone())
            .await
            .unwrap()
    );
    assert!(
        !database
            .relay_bandwidth_available("new-phone".to_owned(), limits)
            .await
            .unwrap()
    );
}

#[tokio::test]
async fn public_request_budget_leaves_companion_contracts_available() {
    let (app, _) = make_app(default_internal_clients()).await;
    for _ in 0..60 {
        let response = app
            .clone()
            .oneshot(json_request(
                "/v1/pairing-sessions",
                serde_json::json!({}),
                None,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
    }
    let response = app
        .clone()
        .oneshot(json_request(
            "/v1/pairing-sessions",
            serde_json::json!({}),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
    let response = app
        .oneshot(json_request(
            "/v1/internal/voip",
            serde_json::json!({}),
            None,
        ))
        .await
        .unwrap();
    assert_ne!(response.status(), StatusCode::TOO_MANY_REQUESTS);
}

fn test_limits() -> agentty_backend::config::DictationLimits {
    agentty_backend::config::DictationLimits {
        trusted_devices: [
            ("device-1", "secret-1"),
            ("device-2", "secret-2"),
            ("alert-device-1", "alert-secret-1"),
            (MIXED_CASE_DEVICE_ID_LOWER, "secret-uuid"),
            (MIXED_CASE_DEVICE_ID_LOWER, "secret-uuid-http"),
        ]
        .into_iter()
        .map(|(id, secret)| {
            (
                id.to_owned(),
                hex::encode(<sha2::Sha256 as sha2::Digest>::digest(secret.as_bytes())),
            )
        })
        .collect(),
        ..Default::default()
    }
}

#[tokio::test]
async fn legacy_onboarding_remains_available_until_operator_enables_verified_admission() {
    let path = NamedTempFile::new()
        .unwrap()
        .into_temp_path()
        .keep()
        .unwrap();
    let database = Database::open(path).await.unwrap();
    let legacy = create_test_app(
        database.clone(),
        Arc::new(FakePushSender::default()),
        vec![],
        Default::default(),
    );
    let body = serde_json::json!({"device_id":"new-legacy-device", "device_secret":"legacy-secret", "bundle_id":MAIN_BUNDLE_ID, "push_environment":"production"});
    let response = legacy
        .oneshot(json_request("/v1/devices/ensure", body.clone(), None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    let strict = create_test_app(
        database,
        Arc::new(FakePushSender::default()),
        vec![],
        agentty_backend::config::DictationLimits {
            require_verified_devices: true,
            ..Default::default()
        },
    );
    let response = strict
        .oneshot(json_request("/v1/devices/ensure", body, None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn concurrent_connections_cannot_double_spend_a_dictation_allowance() {
    let path = NamedTempFile::new()
        .unwrap()
        .into_temp_path()
        .keep()
        .unwrap();
    let first = Database::open(path.clone()).await.unwrap();
    let second = Database::open(path).await.unwrap();
    let week = 1_790_000_000;
    let (first_charge, second_charge) = tokio::join!(
        first.reserve_admitted_dictation(
            "device-a".to_owned(),
            Some("same-verified-account".to_owned()),
            Default::default(),
            week,
            1_200,
            week + 604800
        ),
        second.reserve_admitted_dictation(
            "device-b".to_owned(),
            Some("same-verified-account".to_owned()),
            Default::default(),
            week,
            1_200,
            week + 604800
        )
    );
    assert_eq!(
        [first_charge.unwrap(), second_charge.unwrap()]
            .into_iter()
            .filter(Result::is_ok)
            .count(),
        1
    );
}

#[tokio::test]
async fn daily_operator_spend_is_shared_and_not_refunded_with_the_personal_quota() {
    let path = NamedTempFile::new()
        .unwrap()
        .into_temp_path()
        .keep()
        .unwrap();
    let first = Database::open(path.clone()).await.unwrap();
    let limits = agentty_backend::config::DictationLimits {
        daily_seconds: 100,
        ..Default::default()
    };
    let week = 1_790_000_000;
    assert!(
        first
            .reserve_admitted_dictation(
                "a".to_owned(),
                Some("first".to_owned()),
                limits.clone(),
                week,
                80,
                week + 604800
            )
            .await
            .unwrap()
            .is_ok()
    );
    first
        .release_admitted_dictation("a".to_owned(), Some("first".to_owned()), week, 80)
        .await
        .unwrap();
    let second = Database::open(path).await.unwrap();
    assert!(
        second
            .reserve_admitted_dictation(
                "b".to_owned(),
                Some("second".to_owned()),
                limits.clone(),
                week,
                21,
                week + 604800
            )
            .await
            .unwrap()
            .unwrap_err()
            .operator_limit
    );
    assert!(
        second
            .reserve_admitted_dictation(
                "b".to_owned(),
                Some("second".to_owned()),
                limits,
                week,
                20,
                week + 604800
            )
            .await
            .unwrap()
            .is_ok()
    );
}

#[tokio::test]
async fn strict_admission_allows_an_existing_legacy_device_to_present_its_store_proof() {
    let path = NamedTempFile::new()
        .unwrap()
        .into_temp_path()
        .keep()
        .unwrap();
    let database = Database::open(path).await.unwrap();
    database
        .ensure_device_identity(
            "old-device".to_owned(),
            "secret".to_owned(),
            MAIN_BUNDLE_ID.to_owned(),
            PushEnvironment::Production,
        )
        .await
        .unwrap();
    let app = create_test_app(
        database,
        Arc::new(FakePushSender::default()),
        vec![],
        agentty_backend::config::DictationLimits {
            require_verified_devices: true,
            app_apple_id: 42,
            ..Default::default()
        },
    );
    let response = app.oneshot(json_request("/v1/dictation/sessions", serde_json::json!({"device_id":"old-device","device_secret":"secret","signed_app_transaction":"forged"}), None)).await.unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(
        response_json(response).await["detail"],
        "Invalid signed app transaction."
    );
}

#[tokio::test]
async fn a_trusted_device_id_without_the_matching_credential_stays_in_the_legacy_pool() {
    let path = NamedTempFile::new()
        .unwrap()
        .into_temp_path()
        .keep()
        .unwrap();
    let database = Database::open(path).await.unwrap();
    let transcriber = FakeDictationTranscriber::default();
    let app = create_test_app_with_transcriber(
        database,
        Arc::new(FakePushSender::default()),
        Arc::new(transcriber.clone()),
        vec![],
        agentty_backend::config::DictationLimits {
            legacy_weekly_seconds: 0,
            trusted_devices: vec![("device-1".to_owned(), "0".repeat(64))],
            ..Default::default()
        },
    );
    ensure_default_device(&app).await;
    let token = issue_default_session(&app).await;
    let response = app.oneshot(json_request("/v1/dictation/transcriptions", serde_json::json!({"audio_base64":pcm_wav_base64(1),"mime_type":"audio/wav","file_name":"audio.wav"}), Some(format!("Bearer {token}")))).await.unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    assert!(transcriber.calls.lock().unwrap().is_empty());
}
