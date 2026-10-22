#!/bin/sh
set -eu

logs_dir="$HOME/.agentty/logs"
mkdir -p "$logs_dir"
log_file="$logs_dir/wrappers.log"
max_log_bytes=262144
. "$HOME/.agentty/bin/agentty-log"

agentty_log_line "event=wrapper_start tool=codex args=$# tmux_pane=${TMUX_PANE:-none}"

real_path_file="$HOME/.agentty/state/codex-realpath"
if [ ! -f "$real_path_file" ]; then
  agentty_log_line "event=wrapper_error tool=codex reason=missing_realpath_file"
  echo "agentty: missing Codex path file" >&2
  exit 127
fi

real_codex="$(cat "$real_path_file")"
notify_script="$HOME/.agentty/bin/agentty-notify"
agentty_log_line "event=wrapper_exec tool=codex realpath=$real_codex notify_path=$notify_script"
exec "$real_codex" -c "notify=[\"$notify_script\"]" "$@"
