# Observability and Debugging

Where to find every log and debug surface AgenTTY produces, and how to reconstruct
what happened after a failure. Read this before triaging instability, crashes, dead
shells, or notification problems.

## Quick map

| Symptom | Primary surface |
| --- | --- |
| iOS app crash / hang | Sentry issue + on-device `.ips` crash log |
| Connection drops / reconnect loops | iOS unified log (`ssh`, `terminal` categories) + host `sshd` state + host load |
| All shells died at once | tmux server crash: host `~/.agentty/logs/tmux-server.log` + DiagnosticReports + archived shell manifest |
| Notifications missing | `attempt_id` trace across app, extension, relay, and host `notify.log` |
| Shell titles wrong/stale | host `~/.agentty/state/shell-title/<session_created>/window-N.json` |
| Host runtime drift | `~/.agentty/state/host-runtime.sha256` + version stamp files under `~/.agentty/state/` |

## iOS app logs

Subsystem `dev.tuist.agentty`, categories `app`, `ghostty`, `notifications`, `ssh`, `terminal`.

```bash
log stream --style compact --level debug --predicate 'subsystem == "dev.tuist.agentty"'
log show --style compact --last 30m --predicate 'subsystem == "dev.tuist.agentty" AND category == "ssh"'
```

SSH attempts emit monotonic route/ready/disconnect timing through Points of Interest and
privacy-safe logs; the same events become Sentry breadcrumbs. App + Notification Service
Extension share the notification trace layer and an end-to-end `attempt_id` that also
appears in the relay logs and the host-side `notify.log`.

## Crashes

**Sentry** owns crash, app-hang, and selected operational-failure reporting for all three
flavors. Resolve credentials from the operator shared env (`SENTRY_ORG` /
`AGENTTY_SENTRY_ORG`; project defaults to `agentty`) — never hardcode them. A handled
connection event is captured only when manual recovery is actually presented, so Sentry
noise stays low; reconnect churn lives in the unified log instead.

**Full symbolicated crash logs from a paired iPhone** (richer than Sentry when frames are
missing, and works for terminations Sentry cannot catch):

```bash
xcrun devicectl manage devices                       # find the device UDID
xcrun devicectl device info files --device <udid> --domain-type systemCrashLogs
xcrun devicectl device copy from --device <udid> --domain-type systemCrashLogs \
  --source <name>.ips --destination ./
```

Local Mac crash reports (tmux, simulators, helpers) land in
`~/Library/Logs/DiagnosticReports/*.ips`.

## Host runtime (per SSH host, under `~/.agentty/`)

- `logs/notify.log` — notification helper activity, keyed by `attempt_id`.
- `logs/wrappers.log` — claude/codex wrapper and shell wrapper events.
- `logs/tmux-server.log` — one line per managed tmux server start. A start while shells
  were expected to be alive means the previous server died (crash or host reboot); the
  line names the archived manifest from that generation.
- `logs/shell-manifest-<timestamp>.tsv` — archived shell manifests (newest 20 kept),
  written by the bootstrap whenever it finds no session and must start a fresh server.
- `state/shell-manifest.tsv` — live window list, refreshed by tmux hooks
  (`window-linked`, `window-unlinked`, `client-attached`, `client-detached`,
  `session-window-changed`) via `~/.agentty/bin/agentty-manifest`. Columns:
  `session_created`, `window_index`, `window_id`, `pane_current_command`,
  `pane_current_path`, `window_name`.
- `state/shell-title/<session_created>/window-N.json` — per-window agent turn state,
  where `N` is the numeric part of the tmux window ID (`@7` → `window-7.json`), not
  the window index:
  `provider` (`claude`/`codex`), `provider_session_id`, turn counts, recent turns. The
  `session_created` value matches column 1 of the manifest. mtime only updates on turn
  completion, so idle-but-open windows look stale — never use mtime to decide whether a
  window was open; use the manifest.
- tmux server crashes on macOS hosts appear in `~/Library/Logs/DiagnosticReports/tmux-*.ips`.
  The managed tmux is built with `scripts/patches/tmux-3.6a-focus-null-session.patch` and
  `scripts/patches/tmux-3.6a-copy-mode-refresh-oy-clamp.patch`. Known signatures on
  pre-patch servers: `tty_keys_next` SIGSEGV at `0xd8` = the focus NULL-session crash;
  `grid_line_length` SIGBUS at a wild address (unallocated reserved VM) via `cmdq_next`
  = the copy-mode `refresh-from-pane` scroll-offset underflow. Either signature means
  the host was still running an old server in memory — a runtime sync replaces the
  binary file but only the next server start executes it. Static frames in an `.ips`
  can be attributed by bracketing the image offsets with `nm -n` global symbols and
  disassembling around the return addresses with `llvm-objdump`.

## Restoring shells after a tmux server death

1. Read the archived manifest named in the latest `tmux-server.log` line (or
   `state/shell-manifest.tsv` if the server died without restarting).
2. For each window row, read `state/shell-title/<session_created>/window-<id-number>.json`
   (from the `window_id` column, e.g. `@7` → `window-7.json`) for `provider` and
   `provider_session_id`.
3. Claude windows: the session file lives at
   `~/.claude/projects/<encoded-cwd>/<provider_session_id>.jsonl`. Recreate with
   `tmux new-window -d -t agentty-main -c <pane_current_path>` and run
   `claude --resume <provider_session_id>` there (use `~/.agentty/bin/tmux`). If the
   resume picker appears, Emil wants "Resume full session as-is".
4. Codex windows: rollout files live under `~/.codex/sessions/<yyyy>/<mm>/<dd>/`
   matching the session id; resume with codex's resume flow.
5. Windows without shell-title state were plain shells — recreate with the manifest cwd.

## Relay / backend

Relay deployment files and logs are operator-owned and live outside the public tree.
On the relay host: structured connection logs (connector websocket durations, disconnect
reasons, rejected SSH relay requests) plus the SQLite analytics database (production
`AgenTTY-iOS` only — dev/exp builds and side-loaded main builds do not emit analytics,
so their connection history is only visible in device logs and Sentry). Host-connector
logs on each SSH host: `~/.agentty/logs/host-connector.{stdout,stderr}.log` where the
connector is operator-managed.

Surface lifecycle and channel transport records contain the scoped caller,
bundle, environment and explicit outcome (`accepted`, `rejected`, `unknown` or
`not_sent`). They omit bearer tokens, device tokens, channel IDs and payload
content. Surface owns the persistent lifecycle receipts and APNs reason details;
the broker owns no activity state. Accepted transport does not prove device
display. The strict request and response contracts are in `../backend.md`.

## Host load matters

A heavily loaded or swapping host slows `sshd` handshakes past the app's 5s connect
timeout and starves existing sessions into keepalive death — which presents in the app
as transient reconnect loops with no code defect. When diagnosing "AgenTTY keeps
reconnecting", check `uptime`, `sysctl vm.swapusage`, and what is running on the host
(simulators, Instruments, big builds) before suspecting the transport.
