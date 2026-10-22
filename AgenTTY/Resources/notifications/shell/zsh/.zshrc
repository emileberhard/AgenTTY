if [ -f "$HOME/.zshrc" ]; then
  . "$HOME/.zshrc"
fi

_agentty_prioritize_bin() {
  local agentty_status=$?
  if [ "${path[1]-}" = "$HOME/.agentty/bin" ]; then
    return "$agentty_status"
  fi
  typeset -gU path
  path=("$HOME/.agentty/bin" "${path[@]}")
  export PATH
  rehash
  return "$agentty_status"
}

autoload -Uz add-zsh-hook
add-zsh-hook chpwd _agentty_prioritize_bin
add-zsh-hook precmd _agentty_prioritize_bin
add-zsh-hook preexec _agentty_prioritize_bin
_agentty_prioritize_bin
