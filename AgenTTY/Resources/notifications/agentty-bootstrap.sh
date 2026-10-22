#!/bin/sh
set -eu

tmux_cmd="$HOME/.agentty/bin/tmux"
session_name_file="$HOME/.agentty/config/tmux-session-name"
attach_retry_delay_seconds=1
attach_failure_limit=3
attach_spin_limit=5

if [ ! -x "$tmux_cmd" ]; then
  echo "agentty: missing tmux wrapper" >&2
  exit 127
fi

if [ ! -f "$session_name_file" ]; then
  echo "agentty: missing tmux session name file" >&2
  exit 1
fi

session_name="$(cat "$session_name_file")"
if [ -z "$session_name" ]; then
  echo "agentty: empty tmux session name" >&2
  exit 1
fi

export TERM="${TERM:-xterm-256color}"
export TERMINFO_DIRS="$HOME/.agentty/share/terminfo${TERMINFO_DIRS:+:$TERMINFO_DIRS}"
if [ -z "${LANG:-}" ]; then
  export LANG="en_US.UTF-8"
fi
if [ -z "${LC_CTYPE:-}" ]; then
  export LC_CTYPE="$LANG"
fi

for var in CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_MAX_OUTPUT_TOKENS CLAUDE_CODE_OAUTH_TOKEN; do
  "$tmux_cmd" set-environment -gu "$var" >/dev/null 2>&1 || true
done

if ! "$tmux_cmd" has-session -t "$session_name" 2>/dev/null; then
  # A missing session at bootstrap means the tmux server is starting fresh —
  # either first use or a server death. Archive the previous shell manifest so
  # the shells that were open remain recoverable, and log the start.
  logs_dir="$HOME/.agentty/logs"
  manifest_file="$HOME/.agentty/state/shell-manifest.tsv"
  mkdir -p "$logs_dir" 2>/dev/null || true
  previous_manifest="none"
  if [ -s "$manifest_file" ]; then
    previous_manifest="$logs_dir/shell-manifest-$(date +%Y%m%d-%H%M%S).tsv"
    mv -f "$manifest_file" "$previous_manifest" 2>/dev/null || previous_manifest="none"
  fi
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') server-start session=$session_name previous_manifest=$previous_manifest" >> "$logs_dir/tmux-server.log" 2>/dev/null || true
  ls -t "$logs_dir"/shell-manifest-*.tsv 2>/dev/null | tail -n +21 | while IFS= read -r old_manifest; do
    rm -f "$old_manifest"
  done
  "$tmux_cmd" start-server \; \
    set-environment -g PATH "$HOME/.agentty/bin:$PATH" \; \
    set-environment -g TERMINFO_DIRS "$TERMINFO_DIRS" \; \
    set-option -q -g default-command "$HOME/.agentty/bin/agentty-shell" \; \
    set-option -q -g default-terminal "tmux-256color" \; \
    new-session -d -s "$session_name" "$HOME/.agentty/bin/agentty-shell"
fi

"$tmux_cmd" set-environment -g PATH "$HOME/.agentty/bin:$PATH"
"$tmux_cmd" set-environment -g TERMINFO_DIRS "$TERMINFO_DIRS"
"$tmux_cmd" set-option -q -g default-command "$HOME/.agentty/bin/agentty-shell"
"$tmux_cmd" set-option -q -g default-terminal "tmux-256color"
"$tmux_cmd" set-environment -t "$session_name" PATH "$HOME/.agentty/bin:$PATH"
"$tmux_cmd" set-environment -t "$session_name" TERMINFO_DIRS "$TERMINFO_DIRS"
"$tmux_cmd" set-option -q -t "$session_name" default-command "$HOME/.agentty/bin/agentty-shell"
"$tmux_cmd" set-option -q -t "$session_name" default-terminal "tmux-256color"
"$tmux_cmd" set-option -q -t "$session_name" mouse on
"$tmux_cmd" set-option -q -g -t "$session_name" focus-events on
"$tmux_cmd" set-option -q -g -t "$session_name" status off
"$tmux_cmd" bind-key -T copy-mode WheelUpPane send-keys -X -N 1 scroll-up
"$tmux_cmd" bind-key -T copy-mode WheelDownPane send-keys -X -N 1 scroll-down
"$tmux_cmd" bind-key -T copy-mode-vi WheelUpPane send-keys -X -N 1 scroll-up
"$tmux_cmd" bind-key -T copy-mode-vi WheelDownPane send-keys -X -N 1 scroll-down
# refresh-from-pane crashes servers running a tmux binary without the
# copy-mode oy-clamp patch (stale scroll offset against a re-cloned backing
# screen underflows into a wild grid read). Servers outlive binary upgrades,
# so unbind it on every connect rather than trusting the installed binary.
"$tmux_cmd" unbind-key -T copy-mode r 2>/dev/null || true
"$tmux_cmd" unbind-key -T copy-mode-vi r 2>/dev/null || true
"$tmux_cmd" set-window-option -q -g -t "$session_name" cursor-style blinking-bar
"$tmux_cmd" set-window-option -q -g -t "$session_name" mode-style "bg=colour8,fg=white"
"$tmux_cmd" set-window-option -q -g -t "$session_name" copy-mode-position-format ""
"$tmux_cmd" list-windows -t "$session_name" -F "#{window_id}" | while IFS= read -r window_id; do
  "$tmux_cmd" set-window-option -q -t "$window_id" cursor-style blinking-bar
done

# Keep ~/.agentty/state/shell-manifest.tsv current so a server crash leaves a
# record of the open shells. run-shell -b keeps dumps off the server's command
# loop; the helper writes atomically so a crash mid-dump cannot corrupt it.
manifest_hook_command="run-shell -b \"$HOME/.agentty/bin/agentty-manifest\""
for manifest_hook in window-linked window-unlinked client-attached client-detached session-window-changed; do
  "$tmux_cmd" set-hook -g "$manifest_hook" "$manifest_hook_command" 2>/dev/null || true
done
"$HOME/.agentty/bin/agentty-manifest" 2>/dev/null || true

attach_failure_count=0
attach_rapid_loop_count=0
while "$tmux_cmd" has-session -t "$session_name" 2>/dev/null; do
  attach_started_at="$(date +%s 2>/dev/null || echo 0)"
  if "$tmux_cmd" attach-session -t "$session_name"; then
    attach_status=0
  else
    attach_status="$?"
  fi
  attach_ended_at="$(date +%s 2>/dev/null || echo 0)"

  if [ "$attach_status" -ne 0 ]; then
    attach_failure_count=$((attach_failure_count + 1))
    if [ "$attach_failure_count" -ge "$attach_failure_limit" ]; then
      break
    fi
    sleep "$attach_retry_delay_seconds"
    continue
  fi

  attach_failure_count=0
  if [ "$attach_started_at" = "$attach_ended_at" ]; then
    attach_rapid_loop_count=$((attach_rapid_loop_count + 1))
    if [ "$attach_rapid_loop_count" -ge "$attach_spin_limit" ]; then
      break
    fi
  else
    attach_rapid_loop_count=0
  fi
  sleep "$attach_retry_delay_seconds"
done

exit 0
