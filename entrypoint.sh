#!/bin/sh
# dsh web refuses to bind 0.0.0.0, so:
#   1. start dsh on 127.0.0.1:3081 inside the container
#   2. socat forwards container port 3080 -> 127.0.0.1:3081
# Host port must still be bound to 127.0.0.1 only (see docker-compose.yml).
set -eu

INTERNAL_PORT="${DSH_INTERNAL_PORT:-3081}"
BRIDGE_PORT="${DSH_PORT:-3080}"

if [ "$1" = "web" ]; then
  shift
  dsh web --no-open --port "$INTERNAL_PORT" "$@" &
  DSH_PID=$!
  # Wait until dsh is listening before opening the bridge.
  for i in $(seq 1 50); do
    if (echo > /dev/tcp/127.0.0.1/"$INTERNAL_PORT") 2>/dev/null; then
      break
    fi
    sleep 0.2
  done
  echo "dsh web: http://127.0.0.1:${BRIDGE_PORT}/ (token URL is in the dsh log, port ${INTERNAL_PORT} -> use ${BRIDGE_PORT})"
  exec socat "TCP-LISTEN:${BRIDGE_PORT},fork,reuseaddr" "TCP:127.0.0.1:${INTERNAL_PORT}"
fi

# Any other command (e.g. `dsh --version`, headless task) runs as-is.
exec dsh "$@"
