agentty_trim_log_file() {
  if [ ! -f "$log_file" ]; then
    return 0
  fi

  agentty_current_size="$(wc -c < "$log_file" | tr -d '[:space:]')"
  if [ -z "$agentty_current_size" ]; then
    return 0
  fi

  if [ "$agentty_current_size" -le "$max_log_bytes" ]; then
    return 0
  fi

  tail -n 1000 "$log_file" > "$log_file.tmp"
  mv "$log_file.tmp" "$log_file"
}

agentty_log_line() {
  agentty_trim_log_file
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$log_file"
}
