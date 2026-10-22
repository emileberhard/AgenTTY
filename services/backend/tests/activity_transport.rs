use agentty_backend::activity_transport::{
    ActivityChannelRequest, ActivityDispatchRequest, ApnsFailureClass, classify_apns_reason,
};
use reqwest::{Method, StatusCode};
use serde_json::{Value, json};

fn start_request() -> Value {
    json!({
        "bundle_id": "emileberhard.Surface", "push_environment": "development",
        "priority": 10, "expiration": 0,
        "message": {
            "event": "start", "device_token": "abcdef0123456789", "timestamp": 100,
            "content_state": {"r": 1}, "stale_date": 200,
            "attributes_type": "SurfaceAttributes", "attributes": {"activityID": "work-1"},
            "alert": {"title": "Work session", "body": "Started"},
            "update_route": {"kind": "token"}
        }
    })
}

#[test]
fn push_to_start_encodes_full_state_and_exclusive_update_route() {
    let mut input = start_request();
    for (route, wire_key, wire_value) in [
        (json!({"kind": "token"}), "input-push-token", json!(1)),
        (
            json!({"kind": "channel", "channel_id": "d29yay0x"}),
            "input-push-channel",
            json!("d29yay0x"),
        ),
    ] {
        input["message"]["update_route"] = route;
        let request: ActivityDispatchRequest = serde_json::from_value(input.clone()).unwrap();
        let prepared = request.prepare().unwrap();
        let body: Value = serde_json::from_slice(prepared.body.as_ref().unwrap()).unwrap();
        assert_eq!(
            prepared.url,
            "https://api.sandbox.push.apple.com/3/device/abcdef0123456789"
        );
        assert!(prepared.headers.contains(&(
            "apns-topic",
            "emileberhard.Surface.push-type.liveactivity".to_owned()
        )));
        assert!(
            prepared
                .headers
                .contains(&("apns-priority", "10".to_owned()))
        );
        assert_eq!(body["aps"]["content-state"], json!({"r": 1}));
        assert_eq!(body["aps"]["attributes"], json!({"activityID": "work-1"}));
        assert_eq!(body["aps"]["attributes-type"], "SurfaceAttributes");
        assert_eq!(body["aps"][wire_key], wire_value);
        let excluded = if wire_key == "input-push-token" {
            "input-push-channel"
        } else {
            "input-push-token"
        };
        assert!(body["aps"].get(excluded).is_none());
    }
}

#[test]
fn broadcast_end_uses_channel_headers_without_device_topic() {
    let request: ActivityDispatchRequest = serde_json::from_value(json!({
        "bundle_id": "emileberhard.Surface", "push_environment": "production",
        "priority": 5, "expiration": 300,
        "message": {"event": "end", "target": {"kind": "channel", "channel_id": "d29yay0x"},
            "timestamp": 100, "content_state": {"r": 2}, "dismissal_date": 101}
    }))
    .unwrap();
    let prepared = request.prepare().unwrap();
    assert_eq!(
        prepared.url,
        "https://api.push.apple.com/4/broadcasts/apps/emileberhard.Surface"
    );
    assert!(
        prepared
            .headers
            .contains(&("apns-channel-id", "d29yay0x".to_owned()))
    );
    assert!(
        prepared
            .headers
            .contains(&("apns-expiration", "300".to_owned()))
    );
    assert!(
        !prepared
            .headers
            .iter()
            .any(|(name, _)| *name == "apns-topic")
    );
    let body: Value = serde_json::from_slice(prepared.body.as_ref().unwrap()).unwrap();
    assert_eq!(body["aps"]["dismissal-date"], 101);
    assert_eq!(body["aps"]["content-state"], json!({"r": 2}));
}

#[test]
fn channel_management_preserves_environment_and_storage_policy() {
    for (environment, base_url) in [
        (
            "development",
            "https://api-manage-broadcast.sandbox.push.apple.com:2195",
        ),
        (
            "production",
            "https://api-manage-broadcast.push.apple.com:2196",
        ),
    ] {
        let create: ActivityChannelRequest = serde_json::from_value(json!({
            "bundle_id": "emileberhard.Surface", "push_environment": environment,
            "operation": {"kind": "create", "message_storage_policy": 1}
        }))
        .unwrap();
        let prepared = create.prepare().unwrap();
        assert_eq!(
            prepared.url,
            format!("{base_url}/1/apps/emileberhard.Surface/channels")
        );
        assert_eq!(prepared.method, Method::POST);
        assert_eq!(prepared.expected_status, StatusCode::CREATED);
        let body: Value = serde_json::from_slice(prepared.body.as_ref().unwrap()).unwrap();
        assert_eq!(
            body,
            json!({"message-storage-policy": 1, "push-type": "LiveActivity"})
        );
        let delete: ActivityChannelRequest = serde_json::from_value(json!({
            "bundle_id": "emileberhard.Surface", "push_environment": environment,
            "operation": {"kind": "delete", "channel_id": "d29yay0x"}
        }))
        .unwrap();
        let prepared = delete.prepare().unwrap();
        assert_eq!(prepared.method, Method::DELETE);
        assert_eq!(prepared.expected_status, StatusCode::NO_CONTENT);
        assert_eq!(
            prepared.headers,
            vec![("apns-channel-id", "d29yay0x".to_owned())]
        );
        assert!(prepared.body.is_none());
    }
}

#[test]
fn admission_rejects_conflicting_lifecycle_fields_and_route_bytes() {
    let mut input = start_request();
    input["message"]["dismissal_date"] = json!(200);
    assert!(serde_json::from_value::<ActivityDispatchRequest>(input).is_err());
    let mut input = start_request();
    input["message"]["update_route"] = json!({"kind": "token", "channel_id": "d29yay0x"});
    assert!(serde_json::from_value::<ActivityDispatchRequest>(input).is_err());
    let mut input = start_request();
    input["message"]["update_route"] = json!({"kind": "channel", "channel_id": "invalid\nheader"});
    let request: ActivityDispatchRequest = serde_json::from_value(input).unwrap();
    assert!(request.prepare().is_err());
    let mut input = start_request();
    input["message"]["content_state"] = json!({"value": "x".repeat(4100)});
    let request: ActivityDispatchRequest = serde_json::from_value(input).unwrap();
    assert!(request.prepare().is_err());
    let mut input = start_request();
    input["message"]["content_state"] = json!({"value": "x".repeat(3700)});
    input["message"]["alert"]["body"] = json!("x".repeat(500));
    let request: ActivityDispatchRequest = serde_json::from_value(input).unwrap();
    assert!(request.prepare().is_err());
}

#[test]
fn rejection_classification_uses_apns_reason_instead_of_http_status() {
    for (reason, expected) in [
        (Some("BadDeviceToken"), ApnsFailureClass::Route),
        (Some("ChannelNotRegistered"), ApnsFailureClass::Route),
        (Some("BadRequestPayload"), ApnsFailureClass::Content),
        (Some("FeatureNotEnabled"), ApnsFailureClass::Authorization),
        (
            Some("BroadcastFeatureNotEnabled"),
            ApnsFailureClass::Authorization,
        ),
        (
            Some("InvalidProviderToken"),
            ApnsFailureClass::Authorization,
        ),
        (Some("TooManyRequests"), ApnsFailureClass::Throttled),
        (Some("Shutdown"), ApnsFailureClass::Transient),
        (Some("FutureReason"), ApnsFailureClass::Unknown),
        (None, ApnsFailureClass::Unknown),
    ] {
        assert_eq!(classify_apns_reason(reason), expected);
    }
}
