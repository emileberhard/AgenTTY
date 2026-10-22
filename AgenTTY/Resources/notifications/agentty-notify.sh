#!/bin/sh
set -eu

exec "$HOME/.agentty/libexec/agentty-notify" "$@"
