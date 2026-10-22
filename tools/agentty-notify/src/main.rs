#![forbid(unsafe_code)]

use std::env;
use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::{self, IsTerminal, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{self, Command};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use agentty_notify::{
    AgentEvent, ShellTitleHostState, apply_agent_event, is_codex_turn_complete,
    normalize_notification, notification_source, parse_claude_prompt_event,
    parse_completed_agent_turn, parse_notify_config, parse_payload, preserved_codex_notify,
    should_skip_preserved_codex_notify_command, trim_log_contents, truncate_chars,
};
use reqwest::blocking::Client;
use time::OffsetDateTime;
use time::UtcOffset;
use time::format_description::FormatItem;
use time::format_description::well_known::iso8601;
use time::macros::format_description;

const LOG_MAX_BYTES: u64 = 262_144;
const LOG_MAX_LINES: usize = 1_000;
const NOTIFY_CONFIG_RELATIVE_PATH: &str = "config/notify.json";
const TMUX_SESSION_NAME_RELATIVE_PATH: &str = "config/tmux-session-name";
const ORIGINAL_CODEX_NOTIFY_RELATIVE_PATH: &str = "state/codex-original-notify.json";
const TMUX_WRAPPER_RELATIVE_PATH: &str = "bin/tmux";
const CODEX_CONFIG_FILE_NAME: &str = ".codex/config.toml";
const SHELL_TITLE_STATE_RELATIVE_PATH: &str = "state/shell-title";

static LOG_TIMESTAMP_FORMAT: &[FormatItem<'static>] =
    format_description!("[year]-[month]-[day] [hour]:[minute]:[second]");
static ATTEMPT_COUNTER: AtomicU64 = AtomicU64::new(0);

struct Logger {
    path: Option<PathBuf>,
}

impl Logger {
    fn new() -> Self {
        let path = agentty_dir().map(|path| path.join("logs").join("notify.log"));
        Self { path }
    }

    fn log(&self, message: &str) {
        let Some(path) = &self.path else {
            return;
        };

        if let Some(parent) = path.parent() {
            let _ = fs::create_dir_all(parent);
        }

        trim_log_file(path);

        if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
            let _ = writeln!(file, "{} {}", timestamp_now(), message);
        }
    }

    fn log_event(&self, event: &str, fields: Vec<(&str, String)>) {
        let mut message = format!("event={event}");
        for (key, value) in fields {
            if value.is_empty() {
                continue;
            }
            message.push(' ');
            message.push_str(key);
            message.push('=');
            message.push_str(&sanitize_log_value(&value));
        }
        self.log(&message);
    }
}

fn main() {
    if env::args().nth(1).as_deref() == Some("--version") {
        println!("{}", env!("AGENTTY_BUILD_VERSION"));
        return;
    }
    let exit_code = match dispatch() {
        Ok(()) => 0,
        Err(message) => {
            eprintln!("agentty-notify: {message}");
            2
        }
    };
    process::exit(exit_code);
}

fn dispatch() -> Result<(), String> {
    let mut args = env::args_os();
    let _program_name = args.next();

    match args.next() {
        Some(command) if command == "preserve-codex-notify" => {
            if args.next().is_some() {
                return Err("preserve-codex-notify does not accept arguments".to_owned());
            }
            preserve_codex_notify_file();
            Ok(())
        }
        Some(command) if command == "record-prompt" => {
            if args.next().is_some() {
                return Err("record-prompt does not accept arguments".to_owned());
            }
            run_record_prompt();
            Ok(())
        }
        Some(payload_arg) => {
            run_notify(Some(payload_arg));
            Ok(())
        }
        None => {
            run_notify(None);
            Ok(())
        }
    }
}

fn preserve_codex_notify_file() {
    let logger = Logger::new();
    let Some(agentty_dir) = agentty_dir() else {
        return;
    };

    let output_path = agentty_dir.join(ORIGINAL_CODEX_NOTIFY_RELATIVE_PATH);
    let Some(home_dir) = home_dir() else {
        remove_if_exists(&output_path);
        logger.log_event(
            "preserve_codex_notify",
            vec![
                ("result", "skipped".to_owned()),
                ("reason", "no_home".to_owned()),
            ],
        );
        return;
    };

    let config_path = home_dir.join(CODEX_CONFIG_FILE_NAME);
    let action = fs::read_to_string(&config_path)
        .ok()
        .and_then(|contents| preserved_codex_notify(&contents));

    match action {
        Some(command) => {
            if let Some(parent) = output_path.parent() {
                let _ = fs::create_dir_all(parent);
            }
            match serde_json::to_vec(&command)
                .ok()
                .and_then(|data| fs::write(&output_path, data).ok())
            {
                Some(()) => logger.log_event(
                    "preserve_codex_notify",
                    vec![("result", "written".to_owned())],
                ),
                None => logger.log_event(
                    "preserve_codex_notify",
                    vec![
                        ("result", "skipped".to_owned()),
                        ("reason", "write_failed".to_owned()),
                    ],
                ),
            }
        }
        None => {
            remove_if_exists(&output_path);
            logger.log_event(
                "preserve_codex_notify",
                vec![("result", "cleared".to_owned())],
            );
        }
    }
}

fn run_record_prompt() {
    let logger = Logger::new();
    let Some(payload) = read_payload(None) else {
        logger.log_event(
            "agent_event_skip",
            vec![("reason", "no_payload".to_owned())],
        );
        return;
    };
    let attempt_id = generate_attempt_id();
    let Ok(payload_json) = parse_payload(&payload) else {
        logger.log_event(
            "agent_event_skip",
            vec![
                ("attempt_id", attempt_id),
                ("reason", "invalid_payload".to_owned()),
            ],
        );
        return;
    };
    let Some(event) = parse_claude_prompt_event(&payload_json) else {
        logger.log_event(
            "agent_event_skip",
            vec![
                ("attempt_id", attempt_id),
                ("reason", "unsupported_prompt_payload".to_owned()),
            ],
        );
        return;
    };
    let Some((agentty_dir, tmux_context)) =
        validated_tmux_context(&logger, &attempt_id, "Claude Code")
    else {
        return;
    };

    record_shell_title_event(&agentty_dir, &tmux_context, event, &logger, &attempt_id);
}

fn run_notify(payload_arg: Option<OsString>) {
    let logger = Logger::new();
    let input = if payload_arg.is_some() {
        "argv"
    } else {
        "stdin"
    };

    let Some(payload) = read_payload(payload_arg) else {
        logger.log_event("attempt_skip", vec![("reason", "no_payload".to_owned())]);
        return;
    };
    let attempt_id = generate_attempt_id();
    logger.log_event(
        "attempt_start",
        vec![
            ("attempt_id", attempt_id.clone()),
            ("input", input.to_owned()),
            ("tmux_set", yes_no(env::var_os("TMUX").is_some()).to_owned()),
            ("payload_bytes", payload.len().to_string()),
        ],
    );

    let Ok(payload_json) = parse_payload(&payload) else {
        logger.log_event(
            "attempt_skip",
            vec![
                ("attempt_id", attempt_id),
                ("reason", "invalid_payload".to_owned()),
            ],
        );
        return;
    };

    let source = notification_source(&payload_json).to_owned();

    let validated_context = validated_tmux_context(&logger, &attempt_id, &source);
    if let (Some((agentty_dir, tmux_context)), Some(event)) = (
        validated_context.as_ref(),
        parse_completed_agent_turn(&payload_json),
    ) {
        record_shell_title_event(agentty_dir, tmux_context, event, &logger, &attempt_id);
    }
    if is_codex_turn_complete(&payload_json) {
        run_original_codex_notify(&logger, &attempt_id, &payload);
    }
    let Some((agentty_dir, tmux_context)) = validated_context else {
        return;
    };

    let Some(notify_config) = read_notify_config(&agentty_dir, &logger, &attempt_id, &source)
    else {
        return;
    };

    let current_epoch_seconds = current_epoch_seconds();
    if notify_config.expires_at_epoch_seconds <= current_epoch_seconds {
        logger.log_event(
            "attempt_skip",
            vec![
                ("attempt_id", attempt_id),
                ("source", source),
                ("reason", "expired_token".to_owned()),
                (
                    "expires_at",
                    notify_config.expires_at_epoch_seconds.to_string(),
                ),
                ("now", current_epoch_seconds.to_string()),
            ],
        );
        return;
    }

    let tmux_window_id = Some(tmux_context.window_id);
    let relay_notification =
        normalize_notification(&payload_json, tmux_window_id, attempt_id.clone());
    let notify_payload = match serde_json::to_vec(&relay_notification) {
        Ok(payload) => payload,
        Err(_) => {
            logger.log_event(
                "attempt_skip",
                vec![
                    ("attempt_id", attempt_id),
                    ("source", source),
                    ("reason", "serialization_failed".to_owned()),
                ],
            );
            return;
        }
    };
    let body_len = relay_notification.body.chars().count();

    let url = format!("{}/v1/notify", notify_config.url.trim_end_matches('/'));
    let client = match Client::builder().timeout(Duration::from_secs(10)).build() {
        Ok(client) => client,
        Err(error) => {
            logger.log_event(
                "attempt_result",
                vec![
                    ("attempt_id", attempt_id),
                    ("source", source),
                    ("result", "failed".to_owned()),
                    ("reason", "client_build_failed".to_owned()),
                    ("detail", error.to_string()),
                ],
            );
            return;
        }
    };

    let result = client
        .post(&url)
        .bearer_auth(&notify_config.relay_token)
        .body(notify_payload)
        .header("Content-Type", "application/json")
        .send();

    match result {
        Ok(response) if response.status().is_success() => logger.log_event(
            "attempt_result",
            vec![
                ("attempt_id", relay_notification.attempt_id),
                ("source", relay_notification.source),
                ("result", "posted".to_owned()),
                ("status_code", response.status().as_u16().to_string()),
                (
                    "tmux_window_id",
                    option_i32(relay_notification.tmux_window_id),
                ),
                ("body_len", body_len.to_string()),
            ],
        ),
        Ok(response) => {
            let status_code = response.status().as_u16().to_string();
            let detail = response
                .text()
                .map(|body| sanitize_log_value(&body))
                .unwrap_or_else(|error| format!("response_body_read_failed_{error}"));
            logger.log_event(
                "attempt_result",
                vec![
                    ("attempt_id", attempt_id),
                    ("source", source),
                    ("result", "failed".to_owned()),
                    ("reason", "relay_rejected".to_owned()),
                    ("status_code", status_code),
                    ("detail", detail),
                ],
            )
        }
        Err(error) => logger.log_event(
            "attempt_result",
            vec![
                ("attempt_id", attempt_id),
                ("source", source),
                ("result", "failed".to_owned()),
                ("reason", "relay_post_failed".to_owned()),
                ("detail", error.to_string()),
            ],
        ),
    }
}

fn run_original_codex_notify(logger: &Logger, attempt_id: &str, payload: &str) {
    let Some(agentty_dir) = agentty_dir() else {
        return;
    };
    let original_file_path = agentty_dir.join(ORIGINAL_CODEX_NOTIFY_RELATIVE_PATH);
    let Ok(contents) = fs::read_to_string(&original_file_path) else {
        return;
    };
    let Ok(original_command) = serde_json::from_str::<Vec<String>>(&contents) else {
        logger.log_event(
            "codex_original_notify_result",
            vec![
                ("attempt_id", attempt_id.to_owned()),
                ("result", "skipped".to_owned()),
                ("reason", "invalid_original_file".to_owned()),
            ],
        );
        return;
    };
    let Some(program) = original_command.first() else {
        return;
    };
    if should_skip_preserved_codex_notify_command(&original_command) {
        logger.log_event(
            "codex_original_notify_result",
            vec![
                ("attempt_id", attempt_id.to_owned()),
                ("result", "skipped".to_owned()),
                ("reason", "unsupported_command".to_owned()),
            ],
        );
        return;
    }

    logger.log_event(
        "codex_original_notify_start",
        vec![
            ("attempt_id", attempt_id.to_owned()),
            ("original_file", original_file_path.display().to_string()),
        ],
    );

    match Command::new(program)
        .args(original_command.iter().skip(1))
        .arg(payload)
        .status()
    {
        Ok(status) => logger.log_event(
            "codex_original_notify_result",
            vec![
                ("attempt_id", attempt_id.to_owned()),
                ("result", "finished".to_owned()),
                (
                    "exit_status",
                    status
                        .code()
                        .map(|value| value.to_string())
                        .unwrap_or_else(|| "signal".to_owned()),
                ),
            ],
        ),
        Err(error) => logger.log_event(
            "codex_original_notify_result",
            vec![
                ("attempt_id", attempt_id.to_owned()),
                ("result", "failed".to_owned()),
                ("reason", "spawn_failed".to_owned()),
                ("detail", error.to_string()),
            ],
        ),
    }
}

fn read_payload(payload_arg: Option<OsString>) -> Option<String> {
    if let Some(payload_arg) = payload_arg {
        return Some(payload_arg.to_string_lossy().into_owned());
    }

    if io::stdin().is_terminal() {
        return None;
    }

    let mut payload = String::new();
    io::stdin().read_to_string(&mut payload).ok()?;
    if payload.trim().is_empty() {
        return None;
    }
    Some(payload)
}

fn read_notify_config(
    agentty_dir: &Path,
    logger: &Logger,
    attempt_id: &str,
    source: &str,
) -> Option<agentty_notify::NotifyConfig> {
    let config_path = agentty_dir.join(NOTIFY_CONFIG_RELATIVE_PATH);
    let Ok(raw_config) = fs::read_to_string(&config_path) else {
        logger.log_event(
            "attempt_skip",
            vec![
                ("attempt_id", attempt_id.to_owned()),
                ("source", source.to_owned()),
                ("reason", "missing_notify_config".to_owned()),
            ],
        );
        return None;
    };

    match parse_notify_config(&raw_config) {
        Ok(config) => Some(config),
        Err(error) => {
            logger.log_event(
                "attempt_skip",
                vec![
                    ("attempt_id", attempt_id.to_owned()),
                    ("source", source.to_owned()),
                    ("reason", "invalid_notify_config".to_owned()),
                    ("detail", error),
                ],
            );
            None
        }
    }
}

fn read_tmux_session_name(
    agentty_dir: &Path,
    logger: &Logger,
    attempt_id: &str,
    source: &str,
) -> Option<String> {
    let session_path = agentty_dir.join(TMUX_SESSION_NAME_RELATIVE_PATH);
    let Ok(raw_session_name) = fs::read_to_string(&session_path) else {
        logger.log_event(
            "attempt_skip",
            vec![
                ("attempt_id", attempt_id.to_owned()),
                ("source", source.to_owned()),
                ("reason", "missing_tmux_session_name".to_owned()),
            ],
        );
        return None;
    };

    let session_name = raw_session_name.trim().to_owned();
    if session_name.is_empty() {
        logger.log_event(
            "attempt_skip",
            vec![
                ("attempt_id", attempt_id.to_owned()),
                ("source", source.to_owned()),
                ("reason", "empty_tmux_session_name".to_owned()),
            ],
        );
        return None;
    }

    Some(session_name)
}

#[derive(Debug)]
struct TmuxWindowContext {
    session_created: u64,
    window_id: i32,
}

fn validated_tmux_context(
    logger: &Logger,
    attempt_id: &str,
    source: &str,
) -> Option<(PathBuf, TmuxWindowContext)> {
    if env::var_os("TMUX").is_none() {
        logger.log_event(
            "attempt_skip",
            vec![
                ("attempt_id", attempt_id.to_owned()),
                ("source", source.to_owned()),
                ("reason", "no_tmux".to_owned()),
            ],
        );
        return None;
    }

    let Some(agentty_dir) = agentty_dir() else {
        logger.log_event(
            "attempt_skip",
            vec![
                ("attempt_id", attempt_id.to_owned()),
                ("source", source.to_owned()),
                ("reason", "no_home".to_owned()),
            ],
        );
        return None;
    };

    let expected_session_name = read_tmux_session_name(&agentty_dir, logger, attempt_id, source)?;
    let pane = env::var("TMUX_PANE").ok().filter(|value| !value.is_empty());
    let current_session = if let Some(pane) = pane.as_deref() {
        capture_tmux_output(&agentty_dir, ["display-message", "-t", pane, "-p", "#S"])
    } else {
        capture_tmux_output(&agentty_dir, ["display-message", "-p", "#S"])
    };
    let Some(current_session) = current_session else {
        logger.log_event(
            "attempt_skip",
            vec![
                ("attempt_id", attempt_id.to_owned()),
                ("source", source.to_owned()),
                ("reason", "session_lookup_failed".to_owned()),
            ],
        );
        return None;
    };
    if current_session != expected_session_name {
        logger.log_event(
            "attempt_skip",
            vec![
                ("attempt_id", attempt_id.to_owned()),
                ("source", source.to_owned()),
                ("reason", "wrong_session".to_owned()),
                ("current_session", current_session),
                ("expected_session", expected_session_name),
            ],
        );
        return None;
    }

    let output = if let Some(pane) = pane.as_deref() {
        capture_tmux_output(
            &agentty_dir,
            [
                "display-message",
                "-t",
                pane,
                "-p",
                "#{session_created}\t#{window_id}",
            ],
        )
    } else {
        capture_tmux_output(
            &agentty_dir,
            ["display-message", "-p", "#{session_created}\t#{window_id}"],
        )
    };
    let Some(output) = output else {
        logger.log_event(
            "attempt_skip",
            vec![
                ("attempt_id", attempt_id.to_owned()),
                ("source", source.to_owned()),
                ("reason", "window_lookup_failed".to_owned()),
            ],
        );
        return None;
    };
    let mut fields = output.split('\t');
    let session_created = fields.next()?.parse().ok()?;
    let window_id = fields.next()?.trim_start_matches('@').parse().ok()?;
    if fields.next().is_some() {
        return None;
    }

    Some((
        agentty_dir,
        TmuxWindowContext {
            session_created,
            window_id,
        },
    ))
}

fn record_shell_title_event(
    agentty_dir: &Path,
    tmux_context: &TmuxWindowContext,
    event: AgentEvent,
    logger: &Logger,
    attempt_id: &str,
) {
    let provider = event.provider();
    match persist_shell_title_event(agentty_dir, tmux_context, event) {
        Ok((state, changed)) => logger.log_event(
            if changed {
                "agent_event_recorded"
            } else {
                "agent_event_duplicate"
            },
            vec![
                ("attempt_id", attempt_id.to_owned()),
                ("provider", provider.as_str().to_owned()),
                ("tmux_window_id", tmux_context.window_id.to_string()),
                ("turn_count", state.completed_turn_count.to_string()),
                ("revision", state.revision.to_string()),
            ],
        ),
        Err(error) => logger.log_event(
            "agent_event_record_failed",
            vec![
                ("attempt_id", attempt_id.to_owned()),
                ("provider", provider.as_str().to_owned()),
                ("reason", error),
            ],
        ),
    }
}

fn persist_shell_title_event(
    agentty_dir: &Path,
    tmux_context: &TmuxWindowContext,
    event: AgentEvent,
) -> Result<(ShellTitleHostState, bool), String> {
    let state_dir = agentty_dir
        .join(SHELL_TITLE_STATE_RELATIVE_PATH)
        .join(tmux_context.session_created.to_string());
    fs::create_dir_all(&state_dir).map_err(|error| format!("create_state_dir_{error}"))?;
    set_private_directory_permissions(&state_dir);

    let state_path = state_dir.join(format!("window-{}.json", tmux_context.window_id));
    let lock_path = state_dir.join(format!("window-{}.lock", tmux_context.window_id));
    let lock_file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(&lock_path)
        .map_err(|error| format!("open_state_lock_{error}"))?;
    lock_file
        .lock()
        .map_err(|error| format!("lock_state_{error}"))?;

    let existing = match fs::read(&state_path) {
        Ok(data) => {
            Some(serde_json::from_slice(&data).map_err(|error| format!("decode_state_{error}"))?)
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(error) => return Err(format!("read_state_{error}")),
    };
    let (state, changed) = apply_agent_event(existing, event);
    if changed {
        let data = serde_json::to_vec(&state).map_err(|error| format!("encode_state_{error}"))?;
        write_atomic_file(&state_path, &data)?;
    }
    if !publish_shell_title_metadata(agentty_dir, tmux_context, &state) {
        return Err("tmux_metadata_failed".to_owned());
    }
    lock_file
        .unlock()
        .map_err(|error| format!("unlock_state_{error}"))?;
    Ok((state, changed))
}

fn write_atomic_file(path: &Path, data: &[u8]) -> Result<(), String> {
    let counter = ATTEMPT_COUNTER.fetch_add(1, Ordering::Relaxed);
    let temporary_path = path.with_extension(format!("json.tmp.{}.{}", process::id(), counter));
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&temporary_path)
        .map_err(|error| format!("create_state_temp_{error}"))?;
    set_private_file_permissions(&temporary_path);
    if let Err(error) = file.write_all(data).and_then(|()| file.sync_all()) {
        let _ = fs::remove_file(&temporary_path);
        return Err(format!("write_state_temp_{error}"));
    }
    if let Err(error) = fs::rename(&temporary_path, path) {
        let _ = fs::remove_file(&temporary_path);
        return Err(format!("replace_state_{error}"));
    }
    Ok(())
}

fn publish_shell_title_metadata(
    agentty_dir: &Path,
    tmux_context: &TmuxWindowContext,
    state: &ShellTitleHostState,
) -> bool {
    let target = format!("@{}", tmux_context.window_id);
    let values = [
        (
            "@agentty_title_provider",
            state.provider.as_str().to_owned(),
        ),
        ("@agentty_title_session", state.provider_session_id.clone()),
        (
            "@agentty_title_turn_count",
            state.completed_turn_count.to_string(),
        ),
        ("@agentty_title_revision", state.revision.to_string()),
    ];

    values.into_iter().all(|(name, value)| {
        run_tmux_command(
            agentty_dir,
            ["set-option", "-w", "-t", &target, name, &value],
        )
    })
}

#[cfg(unix)]
fn set_private_directory_permissions(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o700));
}

#[cfg(not(unix))]
fn set_private_directory_permissions(_path: &Path) {}

#[cfg(unix)]
fn set_private_file_permissions(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
}

#[cfg(not(unix))]
fn set_private_file_permissions(_path: &Path) {}

fn capture_process_output<I, S>(program: &Path, args: I) -> Option<String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<std::ffi::OsStr>,
{
    let output = Command::new(program).args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }

    let text = String::from_utf8(output.stdout).ok()?;
    let trimmed = text.trim().to_owned();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    }
}

fn capture_tmux_output<I, S>(agentty_dir: &Path, args: I) -> Option<String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<std::ffi::OsStr>,
{
    let tmux_wrapper = agentty_dir.join(TMUX_WRAPPER_RELATIVE_PATH);
    capture_process_output(&tmux_wrapper, args)
}

fn run_tmux_command<I, S>(agentty_dir: &Path, args: I) -> bool
where
    I: IntoIterator<Item = S>,
    S: AsRef<std::ffi::OsStr>,
{
    Command::new(agentty_dir.join(TMUX_WRAPPER_RELATIVE_PATH))
        .args(args)
        .status()
        .is_ok_and(|status| status.success())
}

fn trim_log_file(path: &Path) {
    let Ok(metadata) = fs::metadata(path) else {
        return;
    };
    if metadata.len() <= LOG_MAX_BYTES {
        return;
    }

    let Ok(contents) = fs::read_to_string(path) else {
        return;
    };

    let trimmed = trim_log_contents(&contents, LOG_MAX_LINES);
    let _ = fs::write(path, trimmed);
}

fn timestamp_now() -> String {
    let offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
    let now = OffsetDateTime::now_utc().to_offset(offset);
    now.format(LOG_TIMESTAMP_FORMAT).unwrap_or_else(|_| {
        now.format(&iso8601::Iso8601::DEFAULT)
            .unwrap_or_else(|_| "1970-01-01 00:00:00".to_owned())
    })
}

fn current_epoch_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or_default()
}

fn remove_if_exists(path: &Path) {
    let _ = fs::remove_file(path);
}

fn home_dir() -> Option<PathBuf> {
    env::var_os("HOME").map(PathBuf::from)
}

fn agentty_dir() -> Option<PathBuf> {
    home_dir().map(|path| path.join(".agentty"))
}

fn yes_no(value: bool) -> &'static str {
    if value { "yes" } else { "no" }
}

fn option_i32(value: Option<i32>) -> String {
    value
        .map(|value| value.to_string())
        .unwrap_or_else(|| "none".to_owned())
}

fn sanitize_log_value(value: &str) -> String {
    let collapsed = value.split_whitespace().collect::<Vec<_>>().join("_");
    truncate_chars(&collapsed, 160)
}

fn generate_attempt_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or_default();
    let counter = ATTEMPT_COUNTER.fetch_add(1, Ordering::Relaxed);
    let pid = u64::from(process::id());
    format!("{:016x}", nanos ^ pid.rotate_left(13) ^ counter)
}
