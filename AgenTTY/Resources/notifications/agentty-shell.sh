#!/bin/sh
set -eu

real_shell_file="$HOME/.agentty/state/shell-realpath"
terminfo_root="$HOME/.agentty/share/terminfo"

export TERMINFO_DIRS="$terminfo_root${TERMINFO_DIRS:+:$TERMINFO_DIRS}"
if [ -f "$real_shell_file" ]; then
  real_shell="$(cat "$real_shell_file")"
else
  real_shell="${SHELL:-/bin/sh}"
fi

shell_name="$(basename "$real_shell")"
case "$shell_name" in
  zsh)
    export ZDOTDIR="$HOME/.agentty/config/shell/zsh"
    exec "$real_shell" -i
    ;;
  bash)
    exec "$real_shell" --rcfile "$HOME/.agentty/config/shell/bashrc" -i
    ;;
  *)
    case ":$PATH:" in
      *":$HOME/.agentty/bin:"*) ;;
      *) PATH="$HOME/.agentty/bin:$PATH"; export PATH ;;
    esac
    exec "$real_shell" -i
    ;;
esac
