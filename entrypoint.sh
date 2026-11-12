#!/bin/sh
# dsh web refuses to bind 0.0.0.0, so:
#   1. dsh listens on 127.0.0.1:${DSH_INTERNAL_PORT} inside the container
#   2. socat runs in background, forwarding ${DSH_PORT} -> internal port
#   3. dsh runs in foreground (exec), so container exits when dsh exits
# Host must bind the container port to 127.0.0.1 only for security.
set -eu

INTERNAL_PORT="${DSH_INTERNAL_PORT:-3081}"
BRIDGE_PORT="${DSH_PORT:-3080}"

if [ "$INTERNAL_PORT" = "$BRIDGE_PORT" ]; then
  echo "ERROR: DSH_INTERNAL_PORT and DSH_PORT must differ (got ${INTERNAL_PORT})" >&2
  exit 1
fi

# Refuse user-supplied --port or --host in web mode (they would break the bridge).
reject_web_args() {
  for arg in "$@"; do
    case "$arg" in
      --port|--port=*|--host|--host=*)
        echo "ERROR: $arg is managed by entrypoint; use DSH_INTERNAL_PORT / DSH_PORT env vars" >&2
        exit 1
        ;;
    esac
  done
}

if [ "${1:-}" = "web" ]; then
  shift
  reject_web_args "$@"

  # Start socat in background. Options:
  #   backlog=128  - larger listen queue for concurrent connections
  #   nodelay      - disable Nagle on listen socket
  #   nodelay      - disable Nagle on backend connection
  socat "TCP-LISTEN:${BRIDGE_PORT},fork,reuseaddr,backlog=128,nodelay" \
        "TCP:127.0.0.1:${INTERNAL_PORT},nodelay" &
  SOCAT_PID=$!

  # Verify socat started successfully
  sleep 0.1
  if ! kill -0 "$SOCAT_PID" 2>/dev/null; then
    echo "ERROR: socat failed to start" >&2
    exit 1
  fi

  # Run dsh in foreground with --public-url so token URLs use the bridge port
  echo "dsh web: http://127.0.0.1:${BRIDGE_PORT}/ (token URL in log will use port ${BRIDGE_PORT})"
  exec dsh web --no-open --port "$INTERNAL_PORT" \
    --public-url "${DSH_PUBLIC_URL:-http://127.0.0.1:${BRIDGE_PORT}/}" "$@"
fi

# Any other command (e.g. `dsh --version`, headless task) runs as-is.
exec dsh "$@"
