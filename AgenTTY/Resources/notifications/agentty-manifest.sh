#!/bin/sh
# Dumps the live AgenTTY tmux window list to ~/.agentty/state/shell-manifest.tsv.
# The bootstrap archives this file into ~/.agentty/logs/ before creating a fresh
# session, so after a tmux server crash the archive records exactly which shells
# were open (cwd, running command, and the session_created value that links each
# row to ~/.agentty/state/shell-title/<session_created>/) for restoration.
set -u

tmux_cmd="$HOME/.agentty/bin/tmux"
session_name_file="$HOME/.agentty/config/tmux-session-name"
manifest_file="$HOME/.agentty/state/shell-manifest.tsv"

[ -x "$tmux_cmd" ] || exit 0
[ -f "$session_name_file" ] || exit 0
session_name="$(cat "$session_name_file")"
[ -n "$session_name" ] || exit 0

tmp_file="$manifest_file.tmp.$$"
if "$tmux_cmd" list-windows -t "$session_name" \
  -F "#{session_created}	#{window_index}	#{window_id}	#{pane_current_command}	#{pane_current_path}	#{window_name}" \
  > "$tmp_file" 2>/dev/null; then
  mv -f "$tmp_file" "$manifest_file"
else
  rm -f "$tmp_file"
fi

exit 0
