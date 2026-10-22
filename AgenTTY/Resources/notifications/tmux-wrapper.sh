#!/bin/sh
set -eu

agentty_root="$HOME/.agentty"
socket_dir="$agentty_root/state/tmux"
socket_path="$socket_dir/socket"
tmux_bin="$agentty_root/libexec/tmux"
terminfo_root="$agentty_root/share/terminfo"

mkdir -p "$socket_dir"
export TERMINFO_DIRS="$terminfo_root${TERMINFO_DIRS:+:$TERMINFO_DIRS}"
exec "$tmux_bin" -u -S "$socket_path" "$@"
