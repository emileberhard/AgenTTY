use std::path::Path;
use std::sync::Arc;

use async_trait::async_trait;
use axum::Router;
use axum::body::{Body, to_bytes};
use axum::http::{Request, StatusCode};
use axum::response::IntoResponse;
use serde_json::{Value, json};
use tempfile::NamedTempFile;
use tower::ServiceExt;

use agentty_backend::apns::{ApnsPushRequest, PushSendSuccess, PushSender};
use agentty_backend::config::DictationLimits;
use agentty_backend::create_test_app;
use agentty_backend::dictation::{
    DictationTier, SpeechResponse, SpeechUpload, SpeechUpstream, SpeechUpstreamUnavailable,
};
use agentty_backend::error::{ApiError, PushSendError};
use agentty_backend::models::{
    DictationSessionRequest, PairingDetectedUsernameSource, PairingHostCandidateKind,
    PairingHostCandidateSource, PairingHostEnvironmentFlag, PairingSessionStatus,
    RelaySessionResponse, SshRelaySessionCreateResponse,
};
use agentty_backend::storage::Database;

struct NoPush;

#[async_trait]
impl PushSender for NoPush {
    async fn send(&self, _: ApnsPushRequest) -> Result<PushSendSuccess, PushSendError> {
        Ok(PushSendSuccess { apns_id: None })
    }
}

struct NoSpeech;

#[async_trait]
impl SpeechUpstream for NoSpeech {
    async fn transcribe(
        &self,
        _: SpeechUpload,
    ) -> Result<SpeechResponse, SpeechUpstreamUnavailable> {
        unreachable!("contract tests never forward speech")
    }
}

fn fixture(path: &str) -> Value {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../contract-fixtures");
    let bytes = std::fs::read(root.join(path)).unwrap_or_else(|error| panic!("{path}: {error}"));
    serde_json::from_slice(&bytes).unwrap_or_else(|error| panic!("{path}: {error}"))
}

fn with(mut value: Value, key: &str, replacement: &Value) -> Value {
    value[key] = replacement.clone();
    value
}

fn shape(value: &Value) -> Value {
    match value {
        Value::Object(map) => map.iter().map(|(key, value)| (key.clone(), shape(value))).collect(),
        Value::Array(items) => items.iter().map(shape).collect(),
        Value::String(_) => json!("string"),
        Value::Number(_) => json!("number"),
        Value::Bool(_) => json!("bool"),
        Value::Null => Value::Null,
    }
}

async fn open_database() -> Database {
    let path = NamedTempFile::new().unwrap().into_temp_path().keep().unwrap();
    Database::open(path).await.unwrap()
}

fn app(database: Database, limits: DictationLimits) -> Router {
    create_test_app(database, Arc::new(NoPush), Arc::new(NoSpeech), Vec::new(), limits)
}

async fn post(app: &Router, path: &str, body: &Value) -> (StatusCode, Value) {
    let request = Request::builder()
        .method("POST")
        .uri(path)
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), usize::MAX).await.unwrap();
    let body = if bytes.is_empty() { Value::Null } else { serde_json::from_slice(&bytes).unwrap() };
    (status, body)
}

#[tokio::test]
async fn pairing_and_relay_routes_honor_client_fixtures() {
    let database = open_database().await;
    let app = app(database.clone(), DictationLimits::default());

    let (status, _) = post(&app, "/v1/devices/ensure", &fixture("devices-ensure/request/ensure.json")).await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    for request in ["notify.json", "unsigned-dictation.json"] {
        let (status, relay_session) = post(&app, "/v1/relay-sessions", &fixture(&format!("relay-sessions/request/{request}"))).await;
        assert_eq!(status, StatusCode::OK, "{request}");
        assert_eq!(shape(&relay_session), shape(&fixture("relay-sessions/response/session.json")), "{request}");
    }

    let (status, pairing) = post(&app, "/v1/pairing-sessions", &json!({})).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(shape(&pairing), shape(&fixture("pairing-sessions/response/session.json")));
    let session_id = pairing["session_id"].as_str().unwrap();

    let claim = fixture("pairing-claim/request/claim.json");
    assert_ne!(claim["code"], pairing["pairing_code"]);
    let (status, rejected) = post(&app, "/v1/pairing-sessions/claim", &claim).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(rejected, fixture("pairing-claim/response/invalid-code-error.json"));

    let (status, claimed) = post(&app, "/v1/pairing-sessions/claim", &with(claim, "code", &pairing["pairing_code"])).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(shape(&claimed), shape(&fixture("pairing-claim/response/claimed.json")));

    let host_status_path = format!("/v1/pairing-sessions/{session_id}/host-status");
    let host_status_request = fixture("pairing-host-status/request/host-status.json");
    let (status, rejected) = post(&app, &host_status_path, &host_status_request).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(rejected, fixture("pairing-host-status/response/invalid-host-token-error.json"));

    let host_status_request = with(host_status_request, "host_token", &pairing["host_token"]);
    let (status, host_status) = post(&app, &host_status_path, &host_status_request).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(shape(&host_status), shape(&fixture("pairing-host-status/response/claimed.json")));

    let register = with(
        fixture("connectors-register/request/register.json"),
        "bootstrap_token",
        &host_status["connector_bootstrap"]["token"],
    );
    let (status, connector) = post(&app, "/v1/connectors/register", &register).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(shape(&connector), shape(&fixture("connectors-register/response/registered.json")));
    let relay_host_id = &connector["relay_host_id"];

    let complete = with(fixture("pairing-complete/request/complete.json"), "host_token", &pairing["host_token"]);
    let complete = with(complete, "relay_host_id", relay_host_id);
    let (status, _) = post(&app, &format!("/v1/pairing-sessions/{session_id}/complete"), &complete).await;
    assert_eq!(status, StatusCode::OK);

    let status_path = format!("/v1/pairing-sessions/{session_id}/status");
    let expected = fixture("pairing-status/response/completed.json");
    for request in ["status.json", "status-before-2.13.9.json"] {
        let (status, body) = post(&app, &status_path, &fixture(&format!("pairing-status/request/{request}"))).await;
        assert_eq!(status, StatusCode::OK, "{request}");
        assert_eq!(shape(&body), shape(&expected), "{request}");
        assert_eq!(body["completion"], with(expected["completion"].clone(), "relay_host_id", relay_host_id), "{request}");
    }

    let relay_request = fixture("ssh-relay-sessions/request/session.json");
    assert_ne!(&relay_request["relay_host_id"], relay_host_id);
    let (status, body) = post(&app, "/v1/ssh-relay-sessions", &relay_request).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(body, fixture("ssh-relay-sessions/response/not-allowed-error.json"));

    let relay_request = with(relay_request, "relay_host_id", relay_host_id);
    let (status, body) = post(&app, "/v1/ssh-relay-sessions", &relay_request).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(body, fixture("ssh-relay-sessions/response/connector-offline-error.json"));

    let strict = self::app(database, DictationLimits { require_verified_devices: true, ..Default::default() });
    let (status, body) = post(&strict, "/v1/ssh-relay-sessions", &relay_request).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(body, fixture("ssh-relay-sessions/response/verification-required-error.json"));
}

#[test]
fn backend_responses_serialize_to_client_fixtures() {
    let session = SshRelaySessionCreateResponse {
        relay_session_id: "relay-session-1".into(),
        expires_at_epoch_seconds: 1_800_000_000,
        authorization_token: "relay-authorization-token".into(),
        websocket_url: "wss://relay.example.test/v1/ssh-relay-sessions/relay-session-1/ws".into(),
    };
    assert_eq!(serde_json::to_value(session).unwrap(), fixture("ssh-relay-sessions/response/session.json"));

    serde_json::from_value::<DictationSessionRequest>(fixture("dictation-sessions/request/signed.json")).unwrap();
    for tier in [DictationTier::Free, DictationTier::Lifetime] {
        let name = match tier {
            DictationTier::Free => "free",
            DictationTier::Lifetime => "lifetime",
        };
        let response = RelaySessionResponse {
            relay_token: "relay-token".into(),
            expires_at_epoch_seconds: 1_800_000_000,
            dictation_tier: Some(tier.as_str()),
        };
        assert_eq!(serde_json::to_value(response).unwrap(), fixture(&format!("dictation-sessions/response/{name}.json")));
    }
}

#[tokio::test]
async fn analytics_rejections_serialize_to_the_client_fixture() {
    let response = ApiError::analytics_validation(
        "Analytics host-setup payload is invalid.",
        Some("event-1".into()),
        Some("host_setup_flow_event".into()),
        Some("saved_host_count".into()),
        Some("positive".into()),
    )
    .into_response();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body: Value = serde_json::from_slice(&to_bytes(response.into_body(), usize::MAX).await.unwrap()).unwrap();
    assert_eq!(body, fixture("analytics-events/response/validation-error.json"));
}

#[test]
fn strict_response_enums_match_the_values_clients_decode() {
    use PairingDetectedUsernameSource::*;
    use PairingHostEnvironmentFlag::*;
    use PairingSessionStatus::*;
    let statuses = [Pending, Claimed, Completed, Failed, Expired].map(|status| match status {
        Pending | Claimed | Completed | Failed | Expired => status,
    });
    let sources = [AccountLookup, IdCommand, EnvUser, WhoamiCommand].map(|source| match source {
        AccountLookup | IdCommand | EnvUser | WhoamiCommand => source,
    });
    let flags = [Container, Wsl].map(|flag| match flag {
        Container | Wsl => flag,
    });
    let kinds = {
        use PairingHostCandidateKind::*;
        [TailscaleShort, TailscaleFqdn, Fqdn, SingleLabel, LocalDomain].map(|kind| match kind {
            TailscaleShort | TailscaleFqdn | Fqdn | SingleLabel | LocalDomain => kind,
        })
    };
    let candidate_sources = {
        use PairingHostCandidateSource::*;
        [
            ScutilHostname,
            ScutilLocalhostname,
            HostnameFqdn,
            Hostname,
            OsHostname,
            EnvHostname,
            TailscaleShort,
            TailscaleMagicdns,
            LegacyHostnameCandidates,
        ]
        .map(|source| match source {
            ScutilHostname | ScutilLocalhostname | HostnameFqdn | Hostname | OsHostname
            | EnvHostname | TailscaleShort | TailscaleMagicdns | LegacyHostnameCandidates => source,
        })
    };
    let expected = fixture("pairing-status/response/enum-values.json");
    assert_eq!(serde_json::to_value(statuses).unwrap(), expected["status"]);
    assert_eq!(serde_json::to_value(sources).unwrap(), expected["detected_username_source"]);
    assert_eq!(serde_json::to_value(flags).unwrap(), expected["host_environment_flags"]);
    assert_eq!(serde_json::to_value(kinds).unwrap(), expected["host_candidate_kind"]);
    assert_eq!(serde_json::to_value(candidate_sources).unwrap(), expected["host_candidate_source"]);
}

#[tokio::test]
async fn rate_limited_speech_requests_keep_the_speech_rejection_protocol() {
    let app = app(open_database().await, DictationLimits::default());
    let request = |path: &str| Request::builder().method("POST").uri(path).body(Body::empty()).unwrap();
    for _ in 0..600 {
        let response = app.clone().oneshot(request("/v1/ssh-relay-sessions")).await.unwrap();
        assert_ne!(response.status(), StatusCode::TOO_MANY_REQUESTS);
    }
    let response = app.oneshot(request(agentty_backend::api::DICTATION_STREAM_PATH)).await.unwrap();
    assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(response.headers()["x-speech-relay-rejection"], "busy");
}
