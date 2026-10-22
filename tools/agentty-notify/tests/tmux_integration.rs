#![cfg(unix)]

use std::env;
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use agentty_notify::ShellTitleHostState;

static HARNESS_COUNTER: AtomicU64 = AtomicU64::new(0);

struct TmuxHarness {
    home: PathBuf,
    tmux_path: PathBuf,
    socket_name: String,
    pane_id: String,
    session_created: String,
    window_id: i32,
}

impl TmuxHarness {
    fn new() -> Self {
        let tmux_path = command_path("tmux");
        let nonce = format!(
            "{}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
            HARNESS_COUNTER.fetch_add(1, Ordering::Relaxed)
        );
        let home = env::temp_dir().join(format!("agentty-notify-{nonce}"));
        let agentty_dir = home.join(".agentty");
        fs::create_dir_all(agentty_dir.join("bin")).unwrap();
        fs::create_dir_all(agentty_dir.join("config")).unwrap();
        fs::write(agentty_dir.join("config/tmux-session-name"), "agentty-main").unwrap();

        let socket_name = format!("agentty-notify-{nonce}");
        let wrapper_path = agentty_dir.join("bin/tmux");
        fs::write(
            &wrapper_path,
            format!(
                "#!/bin/sh\nexec {} -L {} \"$@\"\n",
                shell_quote(&tmux_path),
                shell_quote(Path::new(&socket_name))
            ),
        )
        .unwrap();
        fs::set_permissions(&wrapper_path, fs::Permissions::from_mode(0o700)).unwrap();

        assert!(
            Command::new(&tmux_path)
                .args([
                    "-L",
                    &socket_name,
                    "new-session",
                    "-d",
                    "-s",
                    "agentty-main"
                ])
                .status()
                .unwrap()
                .success()
        );
        let context = tmux_output(
            &tmux_path,
            &socket_name,
            [
                "display-message",
                "-t",
                "agentty-main",
                "-p",
                "#{session_created}\t#{window_id}\t#{pane_id}",
            ],
        );
        let fields = context.split('\t').collect::<Vec<_>>();
        assert_eq!(fields.len(), 3);

        Self {
            home,
            tmux_path,
            socket_name,
            session_created: fields[0].to_owned(),
            window_id: fields[1].trim_start_matches('@').parse().unwrap(),
            pane_id: fields[2].to_owned(),
        }
    }

    fn run_with_stdin(&self, subcommand: Option<&str>, payload: &str) {
        let mut command = self.notify_command();
        if let Some(subcommand) = subcommand {
            command.arg(subcommand);
        }
        let mut child = command.stdin(Stdio::piped()).spawn().unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(payload.as_bytes())
            .unwrap();
        assert!(child.wait().unwrap().success());
    }

    fn spawn_with_argument(&self, payload: &str) -> Child {
        let mut command = self.notify_command();
        command.arg(payload).spawn().unwrap()
    }

    fn notify_command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_agentty-notify"));
        command
            .env("HOME", &self.home)
            .env("TMUX", "agentty-test")
            .env("TMUX_PANE", &self.pane_id);
        command
    }

    fn state(&self) -> ShellTitleHostState {
        let data = fs::read(
            self.home
                .join(".agentty/state/shell-title")
                .join(&self.session_created)
                .join(format!("window-{}.json", self.window_id)),
        )
        .unwrap();
        serde_json::from_slice(&data).unwrap()
    }

    fn option(&self, name: &str) -> String {
        tmux_output(
            &self.tmux_path,
            &self.socket_name,
            [
                "show-options",
                "-w",
                "-v",
                "-t",
                &format!("@{}", self.window_id),
                name,
            ],
        )
    }
}

impl Drop for TmuxHarness {
    fn drop(&mut self) {
        let _ = Command::new(&self.tmux_path)
            .args(["-L", &self.socket_name, "kill-server"])
            .status();
        let _ = fs::remove_dir_all(&self.home);
    }
}

#[test]
fn claude_hooks_record_context_without_notification_configuration() {
    let harness = TmuxHarness::new();
    harness.run_with_stdin(
        Some("record-prompt"),
        r#"{
            "hook_event_name":"UserPromptSubmit",
            "session_id":"claude-session",
            "prompt_id":"prompt-1",
            "prompt":"Implement a reliable title scheduler"
        }"#,
    );
    harness.run_with_stdin(
        None,
        r#"{
            "hook_event_name":"Stop",
            "session_id":"claude-session",
            "prompt_id":"prompt-1",
            "last_assistant_message":"Implemented it with an integration test",
            "stop_hook_active":false
        }"#,
    );

    let state = harness.state();
    assert_eq!(state.completed_turn_count, 1);
    assert_eq!(
        state.recent_turns[0].prompt,
        "Implement a reliable title scheduler"
    );
    assert_eq!(harness.option("@agentty_title_provider"), "claude");
    assert_eq!(harness.option("@agentty_title_session"), "claude-session");
    assert_eq!(harness.option("@agentty_title_turn_count"), "1");
    assert_eq!(harness.option("@agentty_title_revision"), "2");

    harness.run_with_stdin(
        None,
        r#"{
            "hook_event_name":"Stop",
            "session_id":"claude-session",
            "prompt_id":"prompt-1",
            "last_assistant_message":"Implemented it with an integration test",
            "stop_hook_active":false
        }"#,
    );
    assert_eq!(harness.state().completed_turn_count, 1);
}

#[test]
fn concurrent_codex_notifications_are_serialized_without_losing_turns() {
    let harness = TmuxHarness::new();
    let mut children = (0..12)
        .map(|turn| {
            harness.spawn_with_argument(&format!(
                r#"{{"type":"agent-turn-complete","thread-id":"codex-thread","turn-id":"turn-{turn}","input-messages":["request {turn}"],"last-assistant-message":"answer {turn}"}}"#
            ))
        })
        .collect::<Vec<_>>();
    for child in &mut children {
        assert!(child.wait().unwrap().success());
    }

    let state = harness.state();
    assert_eq!(state.completed_turn_count, 12);
    assert_eq!(state.recent_turns.len(), 5);
    assert_eq!(harness.option("@agentty_title_provider"), "codex");
    assert_eq!(harness.option("@agentty_title_session"), "codex-thread");
    assert_eq!(harness.option("@agentty_title_turn_count"), "12");
    assert_eq!(harness.option("@agentty_title_revision"), "12");
}

fn command_path(command: &str) -> PathBuf {
    let output = Command::new("sh")
        .args(["-c", &format!("command -v {command}")])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{command} is required for this test"
    );
    PathBuf::from(String::from_utf8(output.stdout).unwrap().trim())
}

fn tmux_output<const N: usize>(tmux_path: &Path, socket_name: &str, args: [&str; N]) -> String {
    let output = Command::new(tmux_path)
        .args(["-L", socket_name])
        .args(args)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "tmux failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}

fn shell_quote(path: &Path) -> String {
    format!("'{}'", path.display().to_string().replace('\'', "'\"'\"'"))
}
