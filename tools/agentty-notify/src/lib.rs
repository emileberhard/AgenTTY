#![forbid(unsafe_code)]

use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const AGENTTY_NOTIFY_SUFFIXES: [&str; 2] = [
    "/.agentty/bin/agentty-notify",
    "/.agentty/libexec/agentty-notify",
];
pub const MAX_NOTIFICATION_BODY_CHARS: usize = 200;
pub const MAX_SHELL_TITLE_PROMPT_CHARS: usize = 2_000;
pub const MAX_SHELL_TITLE_ASSISTANT_CHARS: usize = 4_000;
pub const MAX_SHELL_TITLE_RECENT_TURNS: usize = 5;
pub const MAX_SHELL_TITLE_RECENT_EVENT_IDS: usize = 32;
const SKY_COMPUTER_USE_CLIENT_BASENAME: &str = "SkyComputerUseClient";
const SKY_COMPUTER_USE_TURN_ENDED_ARG: &str = "turn-ended";

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum AgentProvider {
    Claude,
    Codex,
}

impl AgentProvider {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AgentEvent {
    PromptSubmitted {
        provider: AgentProvider,
        session_id: String,
        event_id: String,
        prompt: String,
    },
    TurnCompleted {
        provider: AgentProvider,
        session_id: String,
        event_id: String,
        prompt: Option<String>,
        assistant_message: String,
    },
}

impl AgentEvent {
    pub fn provider(&self) -> AgentProvider {
        match self {
            Self::PromptSubmitted { provider, .. } | Self::TurnCompleted { provider, .. } => {
                *provider
            }
        }
    }

    pub fn session_id(&self) -> &str {
        match self {
            Self::PromptSubmitted { session_id, .. } | Self::TurnCompleted { session_id, .. } => {
                session_id
            }
        }
    }

    fn deduplication_id(&self) -> String {
        match self {
            Self::PromptSubmitted { event_id, .. } => format!("prompt:{event_id}"),
            Self::TurnCompleted { event_id, .. } => format!("turn:{event_id}"),
        }
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
pub struct PendingAgentPrompt {
    pub event_id: String,
    pub prompt: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
pub struct ShellTitleTurn {
    pub event_id: String,
    pub prompt: String,
    pub assistant_message: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
pub struct ShellTitleHostState {
    pub schema_version: u8,
    pub provider: AgentProvider,
    pub provider_session_id: String,
    pub completed_turn_count: u64,
    pub revision: u64,
    pub recent_event_ids: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pending_prompt: Option<PendingAgentPrompt>,
    pub recent_turns: Vec<ShellTitleTurn>,
}

impl ShellTitleHostState {
    fn new(provider: AgentProvider, session_id: String, revision: u64) -> Self {
        Self {
            schema_version: 1,
            provider,
            provider_session_id: session_id,
            completed_turn_count: 0,
            revision,
            recent_event_ids: Vec::new(),
            pending_prompt: None,
            recent_turns: Vec::new(),
        }
    }
}

pub fn parse_claude_prompt_event(payload: &Value) -> Option<AgentEvent> {
    if payload.get("hook_event_name")?.as_str()? != "UserPromptSubmit" {
        return None;
    }

    Some(AgentEvent::PromptSubmitted {
        provider: AgentProvider::Claude,
        session_id: nonempty_payload_string(payload, "session_id")?,
        event_id: nonempty_payload_string(payload, "prompt_id")?,
        prompt: truncate_chars(
            &nonempty_payload_string(payload, "prompt")?,
            MAX_SHELL_TITLE_PROMPT_CHARS,
        ),
    })
}

pub fn parse_completed_agent_turn(payload: &Value) -> Option<AgentEvent> {
    if payload
        .get("hook_event_name")
        .and_then(Value::as_str)
        .is_some_and(|event| event == "Stop")
    {
        return Some(AgentEvent::TurnCompleted {
            provider: AgentProvider::Claude,
            session_id: nonempty_payload_string(payload, "session_id")?,
            event_id: nonempty_payload_string(payload, "prompt_id")?,
            prompt: None,
            assistant_message: truncate_chars(
                &nonempty_payload_string(payload, "last_assistant_message")?,
                MAX_SHELL_TITLE_ASSISTANT_CHARS,
            ),
        });
    }

    if !is_codex_turn_complete(payload) {
        return None;
    }

    let prompt = payload
        .get("input-messages")
        .or_else(|| payload.get("input_messages"))
        .and_then(Value::as_array)
        .map(|messages| {
            messages
                .iter()
                .filter_map(Value::as_str)
                .filter(|message| !message.is_empty())
                .collect::<Vec<_>>()
                .join("\n")
        })
        .filter(|prompt| !prompt.is_empty())
        .map(|prompt| truncate_chars(&prompt, MAX_SHELL_TITLE_PROMPT_CHARS));

    Some(AgentEvent::TurnCompleted {
        provider: AgentProvider::Codex,
        session_id: nonempty_payload_string(payload, "thread-id")
            .or_else(|| nonempty_payload_string(payload, "thread_id"))?,
        event_id: nonempty_payload_string(payload, "turn-id")
            .or_else(|| nonempty_payload_string(payload, "turn_id"))?,
        prompt,
        assistant_message: truncate_chars(
            &nonempty_payload_string(payload, "last-assistant-message")
                .or_else(|| nonempty_payload_string(payload, "last_assistant_message"))?,
            MAX_SHELL_TITLE_ASSISTANT_CHARS,
        ),
    })
}

pub fn apply_agent_event(
    existing: Option<ShellTitleHostState>,
    event: AgentEvent,
) -> (ShellTitleHostState, bool) {
    let provider = event.provider();
    let session_id = event.session_id().to_owned();
    let next_revision = existing
        .as_ref()
        .map_or(1, |state| state.revision.saturating_add(1));
    let mut state = match existing {
        Some(state) if state.provider == provider && state.provider_session_id == session_id => {
            state
        }
        _ => ShellTitleHostState::new(provider, session_id, next_revision.saturating_sub(1)),
    };

    let deduplication_id = event.deduplication_id();
    if state.recent_event_ids.contains(&deduplication_id) {
        return (state, false);
    }

    match event {
        AgentEvent::PromptSubmitted {
            event_id, prompt, ..
        } => {
            state.pending_prompt = Some(PendingAgentPrompt { event_id, prompt });
        }
        AgentEvent::TurnCompleted {
            event_id,
            prompt,
            assistant_message,
            ..
        } => {
            let pending_prompt = state.pending_prompt.take();
            let resolved_prompt = prompt
                .or_else(|| {
                    pending_prompt
                        .filter(|pending| pending.event_id == event_id)
                        .map(|pending| pending.prompt)
                })
                .unwrap_or_default();
            state.completed_turn_count = state.completed_turn_count.saturating_add(1);
            state.recent_turns.push(ShellTitleTurn {
                event_id,
                prompt: resolved_prompt,
                assistant_message,
            });
            trim_front(&mut state.recent_turns, MAX_SHELL_TITLE_RECENT_TURNS);
        }
    }

    state.recent_event_ids.push(deduplication_id);
    trim_front(
        &mut state.recent_event_ids,
        MAX_SHELL_TITLE_RECENT_EVENT_IDS,
    );
    state.revision = state.revision.saturating_add(1);
    (state, true)
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
pub struct NotifyConfig {
    pub url: String,
    pub relay_token: String,
    pub expires_at_epoch_seconds: i64,
}

#[derive(Debug, PartialEq, Eq, Serialize)]
pub struct RelayNotification {
    pub attempt_id: String,
    pub source: String,
    pub title: String,
    pub body: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tmux_window_id: Option<i32>,
}

pub fn parse_notify_config(raw_json: &str) -> Result<NotifyConfig, String> {
    let config: NotifyConfig = serde_json::from_str(raw_json).map_err(|error| error.to_string())?;
    if config.url.is_empty() {
        return Err("notify config has empty url".to_owned());
    }
    if config.relay_token.is_empty() {
        return Err("notify config has empty relay_token".to_owned());
    }
    if config.expires_at_epoch_seconds <= 0 {
        return Err("notify config has non-positive expires_at_epoch_seconds".to_owned());
    }
    Ok(config)
}

pub fn parse_payload(payload: &str) -> Result<Value, serde_json::Error> {
    serde_json::from_str(payload)
}

pub fn is_codex_turn_complete(payload: &Value) -> bool {
    payload
        .get("type")
        .and_then(Value::as_str)
        .is_some_and(|value| value == "agent-turn-complete")
}

pub fn notification_source(payload: &Value) -> &'static str {
    if is_codex_turn_complete(payload) {
        "Codex"
    } else if payload.get("stop_hook_active").is_some() {
        "Claude Code"
    } else {
        "Agent"
    }
}

pub fn is_agentty_notify_command(value: &[String]) -> bool {
    value.iter().any(|item| {
        AGENTTY_NOTIFY_SUFFIXES
            .iter()
            .any(|suffix| item.ends_with(suffix))
    })
}

pub fn should_skip_preserved_codex_notify_command(command: &[String]) -> bool {
    if is_agentty_notify_command(command) {
        return true;
    }

    command
        .first()
        .is_some_and(|program| program.rsplit('/').next() == Some(SKY_COMPUTER_USE_CLIENT_BASENAME))
        && command
            .get(1)
            .is_some_and(|arg| arg == SKY_COMPUTER_USE_TURN_ENDED_ARG)
}

pub fn preserved_codex_notify(raw_toml: &str) -> Option<Vec<String>> {
    let value: toml::Value = toml::from_str(raw_toml).ok()?;
    let notify = value.get("notify")?.as_array()?;

    let command: Vec<String> = notify
        .iter()
        .map(|item| item.as_str().map(str::to_owned))
        .collect::<Option<Vec<_>>>()?;

    if command.is_empty() || should_skip_preserved_codex_notify_command(&command) {
        return None;
    }

    Some(command)
}

pub fn normalize_notification(
    payload: &Value,
    tmux_window_id: Option<i32>,
    attempt_id: String,
) -> RelayNotification {
    let source = notification_source(payload);

    let body = payload_text(payload, "last_assistant_message")
        .or_else(|| payload_text(payload, "last-assistant-message"))
        .or_else(|| payload_text(payload, "message"))
        .or_else(|| latest_input_message(payload))
        .unwrap_or_else(|| "done".to_owned());

    RelayNotification {
        attempt_id,
        source: source.to_owned(),
        title: source.to_owned(),
        body: truncate_chars(&body, MAX_NOTIFICATION_BODY_CHARS),
        tmux_window_id,
    }
}

pub fn trim_log_contents(contents: &str, max_lines: usize) -> String {
    let mut lines = contents.lines().rev().take(max_lines).collect::<Vec<_>>();
    lines.reverse();
    if lines.is_empty() {
        String::new()
    } else {
        format!("{}\n", lines.join("\n"))
    }
}

pub fn truncate_chars(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect()
}

fn nonempty_payload_string(payload: &Value, key: &str) -> Option<String> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

fn trim_front<T>(values: &mut Vec<T>, maximum_count: usize) {
    if values.len() > maximum_count {
        values.drain(..values.len() - maximum_count);
    }
}

fn json_value_to_text(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        _ => value.to_string(),
    }
}

fn payload_text(payload: &Value, key: &str) -> Option<String> {
    let value = payload.get(key)?;
    match value {
        Value::Null => None,
        Value::String(text) if text.is_empty() => None,
        Value::String(text) => Some(text.clone()),
        other => Some(json_value_to_text(other)),
    }
}

fn latest_input_message(payload: &Value) -> Option<String> {
    let messages = payload
        .get("input_messages")
        .or_else(|| payload.get("input-messages"))?
        .as_array()?;

    messages.iter().rev().find_map(|value| match value {
        Value::String(text) if !text.is_empty() => Some(text.clone()),
        _ => None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn preserves_non_agentty_codex_notify() {
        let raw_toml = r#"
notify = ["python3", "/tmp/notify.py"]
"#;

        assert_eq!(
            preserved_codex_notify(raw_toml),
            Some(vec!["python3".to_owned(), "/tmp/notify.py".to_owned()])
        );
    }

    #[test]
    fn ignores_agentty_codex_notify() {
        let raw_toml = r#"
notify = ["/home/user/.agentty/bin/agentty-notify"]
"#;

        assert_eq!(preserved_codex_notify(raw_toml), None);
    }

    #[test]
    fn ignores_agentty_codex_notify_from_libexec() {
        let raw_toml = r#"
notify = ["/home/user/.agentty/libexec/agentty-notify"]
"#;

        assert_eq!(preserved_codex_notify(raw_toml), None);
    }

    #[test]
    fn ignores_openai_computer_use_turn_ended_notify() {
        let raw_toml = r#"
notify = ["/Users/example/.codex/plugins/cache/openai-bundled/computer-use/1.0.750/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient", "turn-ended"]
"#;

        assert_eq!(preserved_codex_notify(raw_toml), None);
    }

    #[test]
    fn ignores_non_string_notify_entries() {
        let raw_toml = r#"
notify = ["python3", 1]
"#;

        assert_eq!(preserved_codex_notify(raw_toml), None);
    }

    #[test]
    fn parses_valid_notify_config() {
        let raw_json = r#"{
  "url": "https://example.com",
  "relay_token": "token",
  "expires_at_epoch_seconds": 123
}"#;

        assert_eq!(
            parse_notify_config(raw_json).unwrap(),
            NotifyConfig {
                url: "https://example.com".to_owned(),
                relay_token: "token".to_owned(),
                expires_at_epoch_seconds: 123,
            }
        );
    }

    #[test]
    fn rejects_notify_config_with_empty_url() {
        let raw_json = r#"{
  "url": "",
  "relay_token": "token",
  "expires_at_epoch_seconds": 123
}"#;

        assert_eq!(
            parse_notify_config(raw_json).unwrap_err(),
            "notify config has empty url"
        );
    }

    #[test]
    fn rejects_notify_config_with_non_positive_expiry() {
        let raw_json = r#"{
  "url": "https://example.com",
  "relay_token": "token",
  "expires_at_epoch_seconds": 0
}"#;

        assert_eq!(
            parse_notify_config(raw_json).unwrap_err(),
            "notify config has non-positive expires_at_epoch_seconds"
        );
    }

    #[test]
    fn normalizes_codex_payload() {
        let payload = json!({
            "type": "agent-turn-complete",
            "last_assistant_message": "all done"
        });

        assert_eq!(
            normalize_notification(&payload, Some(17), String::new()),
            RelayNotification {
                attempt_id: String::new(),
                source: "Codex".to_owned(),
                title: "Codex".to_owned(),
                body: "all done".to_owned(),
                tmux_window_id: Some(17),
            }
        );
    }

    #[test]
    fn normalizes_claude_payload() {
        let payload = json!({
            "stop_hook_active": true,
            "message": "finished"
        });

        assert_eq!(
            normalize_notification(&payload, None, String::new()),
            RelayNotification {
                attempt_id: String::new(),
                source: "Claude Code".to_owned(),
                title: "Claude Code".to_owned(),
                body: "finished".to_owned(),
                tmux_window_id: None,
            }
        );
    }

    #[test]
    fn falls_back_to_done_for_unknown_payload() {
        let payload = json!({
            "foo": "bar"
        });

        assert_eq!(
            normalize_notification(&payload, None, String::new()),
            RelayNotification {
                attempt_id: String::new(),
                source: "Agent".to_owned(),
                title: "Agent".to_owned(),
                body: "done".to_owned(),
                tmux_window_id: None,
            }
        );
    }

    #[test]
    fn codex_plan_mode_null_message_falls_back_to_latest_prompt() {
        let payload = json!({
            "type": "agent-turn-complete",
            "last_assistant_message": null,
            "input_messages": [
                "inspect repo",
                "make a plan for the fix"
            ]
        });

        assert_eq!(
            normalize_notification(&payload, None, String::new()),
            RelayNotification {
                attempt_id: String::new(),
                source: "Codex".to_owned(),
                title: "Codex".to_owned(),
                body: "make a plan for the fix".to_owned(),
                tmux_window_id: None,
            }
        );
    }

    #[test]
    fn null_message_without_prompt_falls_back_to_done() {
        let payload = json!({
            "type": "agent-turn-complete",
            "last_assistant_message": null
        });

        assert_eq!(
            normalize_notification(&payload, None, String::new()),
            RelayNotification {
                attempt_id: String::new(),
                source: "Codex".to_owned(),
                title: "Codex".to_owned(),
                body: "done".to_owned(),
                tmux_window_id: None,
            }
        );
    }

    #[test]
    fn truncates_notification_body_by_character_count() {
        let payload = json!({
            "message": "a".repeat(MAX_NOTIFICATION_BODY_CHARS + 10)
        });

        assert_eq!(
            normalize_notification(&payload, None, String::new())
                .body
                .chars()
                .count(),
            MAX_NOTIFICATION_BODY_CHARS
        );
    }

    #[test]
    fn trims_log_to_last_lines() {
        let contents = "1\n2\n3\n4\n";

        assert_eq!(trim_log_contents(contents, 2), "3\n4\n");
    }

    #[test]
    fn parses_and_applies_modern_claude_prompt_and_stop_payloads() {
        let prompt = parse_claude_prompt_event(&json!({
            "hook_event_name": "UserPromptSubmit",
            "session_id": "session-1",
            "prompt_id": "prompt-1",
            "prompt": "Fix the shell title"
        }))
        .unwrap();
        let (state, changed) = apply_agent_event(None, prompt);
        assert!(changed);
        assert_eq!(state.completed_turn_count, 0);
        assert_eq!(state.revision, 1);

        let stop = parse_completed_agent_turn(&json!({
            "hook_event_name": "Stop",
            "session_id": "session-1",
            "prompt_id": "prompt-1",
            "last_assistant_message": "Implemented and tested it",
            "stop_hook_active": false
        }))
        .unwrap();
        let (state, changed) = apply_agent_event(Some(state), stop.clone());
        assert!(changed);
        assert_eq!(state.provider, AgentProvider::Claude);
        assert_eq!(state.completed_turn_count, 1);
        assert_eq!(state.revision, 2);
        assert_eq!(state.recent_turns[0].prompt, "Fix the shell title");
        assert_eq!(
            state.recent_turns[0].assistant_message,
            "Implemented and tested it"
        );

        let (duplicate_state, duplicate_changed) = apply_agent_event(Some(state.clone()), stop);
        assert!(!duplicate_changed);
        assert_eq!(duplicate_state, state);
    }

    #[test]
    fn parses_and_applies_modern_codex_notify_payload() {
        let event = parse_completed_agent_turn(&json!({
            "type": "agent-turn-complete",
            "thread-id": "thread-1",
            "turn-id": "turn-1",
            "cwd": "/tmp/project",
            "input-messages": ["Inspect the bug", "Implement the fix"],
            "last-assistant-message": "The fix is complete"
        }))
        .unwrap();
        let (state, changed) = apply_agent_event(None, event);

        assert!(changed);
        assert_eq!(state.provider, AgentProvider::Codex);
        assert_eq!(state.provider_session_id, "thread-1");
        assert_eq!(state.completed_turn_count, 1);
        assert_eq!(
            state.recent_turns[0].prompt,
            "Inspect the bug\nImplement the fix"
        );
    }

    #[test]
    fn changing_provider_session_resets_turn_history_but_keeps_revision_monotonic() {
        let first_event = AgentEvent::TurnCompleted {
            provider: AgentProvider::Codex,
            session_id: "thread-1".to_owned(),
            event_id: "turn-1".to_owned(),
            prompt: Some("first".to_owned()),
            assistant_message: "done".to_owned(),
        };
        let (first_state, _) = apply_agent_event(None, first_event);
        let second_event = AgentEvent::TurnCompleted {
            provider: AgentProvider::Codex,
            session_id: "thread-2".to_owned(),
            event_id: "turn-1".to_owned(),
            prompt: Some("second".to_owned()),
            assistant_message: "done again".to_owned(),
        };
        let (second_state, changed) = apply_agent_event(Some(first_state), second_event);

        assert!(changed);
        assert_eq!(second_state.provider_session_id, "thread-2");
        assert_eq!(second_state.completed_turn_count, 1);
        assert_eq!(second_state.revision, 2);
        assert_eq!(second_state.recent_turns.len(), 1);
        assert_eq!(second_state.recent_turns[0].prompt, "second");
    }

    #[test]
    fn shell_title_state_retains_only_bounded_recent_context() {
        let mut state = None;
        for turn in 0..40 {
            let event = AgentEvent::TurnCompleted {
                provider: AgentProvider::Codex,
                session_id: "thread-1".to_owned(),
                event_id: format!("turn-{turn}"),
                prompt: Some(format!("prompt-{turn}")),
                assistant_message: format!("answer-{turn}"),
            };
            state = Some(apply_agent_event(state, event).0);
        }

        let state = state.unwrap();
        assert_eq!(state.completed_turn_count, 40);
        assert_eq!(state.recent_turns.len(), MAX_SHELL_TITLE_RECENT_TURNS);
        assert_eq!(
            state.recent_event_ids.len(),
            MAX_SHELL_TITLE_RECENT_EVENT_IDS
        );
        assert_eq!(state.recent_turns[0].event_id, "turn-35");
    }
}
