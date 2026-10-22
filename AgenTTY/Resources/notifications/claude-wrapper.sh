#!/bin/sh
set -eu

logs_dir="$HOME/.agentty/logs"
mkdir -p "$logs_dir"
log_file="$logs_dir/wrappers.log"
max_log_bytes=262144
. "$HOME/.agentty/bin/agentty-log"

agentty_log_line "event=wrapper_start tool=claude args=$# tmux_pane=${TMUX_PANE:-none}"

real_path_file="$HOME/.agentty/state/claude-realpath"
settings_file="$HOME/.agentty/config/claude-settings.json"
if [ ! -f "$real_path_file" ]; then
  agentty_log_line "event=wrapper_error tool=claude reason=missing_realpath_file"
  echo "agentty: missing Claude path file" >&2
  exit 127
fi
if [ ! -f "$settings_file" ]; then
  agentty_log_line "event=wrapper_error tool=claude reason=missing_settings_file"
  echo "agentty: missing Claude settings file" >&2
  exit 127
fi

real_claude="$(cat "$real_path_file")"

# Claude subcommands (`claude mcp`, `claude remote-control`, ...) have their own
# argument parsers and reject --settings. Ask the binary whether the command
# behind this invocation accepts the flag, and cache the answer per Claude build.
command_accepts_settings() {
  cache_file="$HOME/.agentty/state/claude-settings-support"
  signature="$(ls -ln "$real_claude" 2>/dev/null | awk '{print $5, $6, $7, $8}')"
  cached=""
  if [ -f "$cache_file" ] && [ "$(head -n 1 "$cache_file")" = "$signature" ]; then
    cached="$(grep -m 1 "^$1=" "$cache_file" | cut -d = -f 2)"
  else
    printf '%s\n' "$signature" > "$cache_file"
  fi

  if [ -z "$cached" ]; then
    if ! help_text="$("$real_claude" "$1" --help 2>&1)" || [ -z "$help_text" ]; then
      # Claude did not answer, so it is mid-update or broken. Passing a flag a
      # subcommand rejects turns a working command into a hard failure, so drop
      # the settings this once and leave the cache untouched to probe again.
      agentty_log_line "event=wrapper_probe_unanswered tool=claude subcommand=$1"
      return 1
    fi
    case "$help_text" in
      *--settings*) cached=1 ;;
      *) cached=0 ;;
    esac
    printf '%s=%s\n' "$1" "$cached" >> "$cache_file"
  fi

  [ "$cached" = "1" ]
}

# Only a bare lowercase token can name a subcommand; anything else is a prompt.
case "${1:-}" in
  ""|-*|[!a-z]*|*[!a-z0-9-]*) ;;
  *)
    if ! command_accepts_settings "$1"; then
      agentty_log_line "event=wrapper_exec tool=claude realpath=$real_claude subcommand=$1 settings=unsupported"
      exec "$real_claude" "$@"
    fi
    ;;
esac

agentty_log_line "event=wrapper_exec tool=claude realpath=$real_claude settings=$settings_file"
exec "$real_claude" --settings "$settings_file" "$@"
