use serde_json::json;

use agentty_backend::apns::{
    build_internal_alert_payload, build_live_activity_payload, build_location_payload,
    build_notification_payload,
};
use agentty_backend::models::{
    AttemptId, InternalAlertRequest, InternalLiveActivityAlert, InternalLiveActivityRequest,
    LiveActivityEvent, NonEmptyString, NotifyRequest, PushEnvironment,
};

#[test]
fn build_location_payload_uses_empty_aps_and_custom_command() {
    let payload = build_location_payload(
        [(
            "remoteCoder.navigation".to_owned(),
            json!({ "sessionId": "session-1" }),
        )]
        .into_iter()
        .collect(),
    );

    assert_eq!(payload["aps"], json!({}));
    assert_eq!(payload["remoteCoder.navigation"]["sessionId"], "session-1");
}

#[test]
fn build_notification_payload_enables_mutable_content() {
    let notification = NotifyRequest {
        attempt_id: AttemptId::parse("attempt-1".to_owned()).unwrap(),
        source: NonEmptyString::new("Claude Code".to_owned()).unwrap(),
        title: NonEmptyString::new("Claude Code".to_owned()).unwrap(),
        body: NonEmptyString::new("done".to_owned()).unwrap(),
        tmux_window_id: Some(42),
    };

    let payload = build_notification_payload(&notification);

    assert_eq!(payload["aps"]["mutable-content"], 1);
    assert_eq!(payload["aps"]["alert"]["title"], "Claude Code");
    assert_eq!(payload["aps"]["alert"]["body"], "done");
    assert_eq!(payload["attempt_id"], "attempt-1");
    assert_eq!(payload["source"], "Claude Code");
    assert_eq!(payload["tmux_window_id"], 42);
}

#[test]
fn build_internal_alert_payload_preserves_optional_fields_and_custom_data() {
    let request = InternalAlertRequest {
        topic: NonEmptyString::new("emileberhard.RemoteCoder".to_owned()).unwrap(),
        push_environment: PushEnvironment::Production,
        device_token: NonEmptyString::new("device-token".to_owned()).unwrap(),
        title: NonEmptyString::new("RemoteCoder".to_owned()).unwrap(),
        body: NonEmptyString::new("done".to_owned()).unwrap(),
        subtitle: Some(NonEmptyString::new("session".to_owned()).unwrap()),
        sound: Some(NonEmptyString::new("remote-coder-notification.wav".to_owned()).unwrap()),
        collapse_id: Some(NonEmptyString::new("collapse-1".to_owned()).unwrap()),
        mutable_content: false,
        custom_data: Some(
            [(
                "remoteCoder.taskCompletionPayload".to_owned(),
                json!({ "status": "done" }),
            )]
            .into_iter()
            .collect(),
        ),
    };

    let payload = build_internal_alert_payload(&request);

    assert_eq!(payload["aps"]["alert"]["title"], "RemoteCoder");
    assert_eq!(payload["aps"]["alert"]["subtitle"], "session");
    assert_eq!(payload["aps"]["sound"], "remote-coder-notification.wav");
    assert!(payload["aps"].get("mutable-content").is_none());
    assert_eq!(
        payload["remoteCoder.taskCompletionPayload"],
        json!({ "status": "done" })
    );
}

#[test]
fn build_live_activity_payload_serializes_update_and_end_fields() {
    let update_request = InternalLiveActivityRequest {
        bundle_id: NonEmptyString::new("emileberhard.RemoteCoder".to_owned()).unwrap(),
        push_environment: PushEnvironment::Production,
        device_token: NonEmptyString::new("device-token".to_owned()).unwrap(),
        event: LiveActivityEvent::Update,
        timestamp: 10,
        content_state: json!({ "activeTaskCount": 1 }),
        stale_date: Some(20),
        dismissal_date: None,
        alert: Some(InternalLiveActivityAlert {
            title: NonEmptyString::new("Active task".to_owned()).unwrap(),
            body: NonEmptyString::new("One task running".to_owned()).unwrap(),
            subtitle: None,
        }),
    };

    let update_payload = build_live_activity_payload(&update_request);

    assert_eq!(update_payload["aps"]["event"], "update");
    assert_eq!(update_payload["aps"]["timestamp"], 10);
    assert_eq!(update_payload["aps"]["stale-date"], 20);
    assert_eq!(update_payload["aps"]["alert"]["title"], "Active task");

    let end_request = InternalLiveActivityRequest {
        bundle_id: NonEmptyString::new("emileberhard.RemoteCoder".to_owned()).unwrap(),
        push_environment: PushEnvironment::Production,
        device_token: NonEmptyString::new("device-token".to_owned()).unwrap(),
        event: LiveActivityEvent::End,
        timestamp: 30,
        content_state: json!({ "activeTaskCount": 0 }),
        stale_date: None,
        dismissal_date: Some(30),
        alert: None,
    };

    let end_payload = build_live_activity_payload(&end_request);

    assert_eq!(end_payload["aps"]["event"], "end");
    assert_eq!(end_payload["aps"]["dismissal-date"], 30);
    assert!(end_payload["aps"].get("alert").is_none());
}
