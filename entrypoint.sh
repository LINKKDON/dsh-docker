#!/bin/sh
# dsh web refuses to bind a wildcard address ("--host 0.0.0.0 ... would expose
# remote code execution to the network"), so the container is split in two:
#   1. dsh listens on 127.0.0.1:$DSH_INTERNAL_PORT, reachable only from inside
#   2. socat forwards $DSH_PORT -> that loopback port, which is what -p publishes
#   3. --public-url makes the printed token URL name the host-facing port.
#      The auth cookie is named for the request authority (hash of the Host
#      header), so the announced port must be the one the browser really
#      connects to; otherwise the URL in the log is unusable and the cookie it
#      sets is never read back.
# The host side must still be published to loopback only (see docker-compose.yml).
set -eu

INTERNAL_PORT="${DSH_INTERNAL_PORT:-3081}"
BRIDGE_PORT="${DSH_PORT:-3080}"
PUBLIC_URL="${DSH_PUBLIC_URL:-http://127.0.0.1:${BRIDGE_PORT}/}"
# Seconds to wait for the listener. A cold start on an emulated arm64 host (or a
# slow disk) does not fit into the 10s this used to allow, and the failure mode
# was a container that refused to start at all.
TIMEOUT=30

# Probe with node instead of /dev/tcp: /dev/tcp is a bash extension, and this
# script runs under dash (Debian's /bin/sh), where the probe can never succeed
# and startup would stall for the whole timeout. node is always present here.
listening() {
  node -e 'const s=require("net").connect(+process.argv[1],"127.0.0.1");s.on("connect",()=>{s.end();process.exit(0)});s.on("error",()=>process.exit(1))' "$1" 2>/dev/null
}

# Not a bare `kill -0`: a shell reaps a background child only when it calls
# `wait`, and until then the PID of an already-exited child still answers
# signal 0 (zombie), so a crashed dsh would look alive. The state letter in
# /proc/<pid>/stat ("Z") settles it; this image is Linux-only, /proc is always
# mounted. Same helper guards the socat check further down.
alive() {
  kill -0 "$1" 2>/dev/null || return 1
  line=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  case "${line##*) }" in
    ''|Z*) return 1 ;;
  esac
  return 0
}

case "${1:-web}" in
web)
  # `case` allows the zero-argument path, but `shift` with nothing to shift is a
  # dash error, so guard it rather than rely on CMD always being present.
  if [ "$#" -gt 0 ]; then
    shift
  fi
  dsh web --no-open --port "$INTERNAL_PORT" --public-url "$PUBLIC_URL" "$@" &
  dsh_pid=$!
  # Wait for the listener, but treat an early exit as fatal: otherwise socat
  # keeps the container "up" with a reachable port and no UI behind it, and the
  # only symptom is one line in `docker logs`.
  ready=0
  i=0
  while [ "$i" -lt "$TIMEOUT" ]; do
    alive "$dsh_pid" || { echo "dsh web exited during startup; see the error above" >&2; exit 1; }
    if listening "$INTERNAL_PORT"; then
      ready=1
      break
    fi
    i=$((i + 1))
    sleep 1
  done
  [ "$ready" = 1 ] || { echo "dsh web did not listen on 127.0.0.1:${INTERNAL_PORT} within ${TIMEOUT}s" >&2; exit 1; }
  # The "dsh web: http://...?token=..." line printed by dsh above already carries
  # the host-facing port, thanks to --public-url, so it opens as-is.
  echo "dsh web: forwarding :${BRIDGE_PORT} -> 127.0.0.1:${INTERNAL_PORT}"
  # Bridge in the background and supervise dsh, rather than `exec socat`: exec'd,
  # a dsh crash left the container running forever with a bridge to a dead port.
  # No trap: tini -g delivers SIGTERM to this whole process group.
  socat "TCP-LISTEN:${BRIDGE_PORT},fork,reuseaddr" "TCP:127.0.0.1:${INTERNAL_PORT}" &
  socat_pid=$!
  # socat exits immediately if it cannot bind. Without this check the bridge
  # failure is silent until the HEALTHCHECK notices ~90s later. `alive`, not a
  # bare `kill -0`: a dead socat is a zombie here too (see the helper above).
  sleep 1
  alive "$socat_pid" || { echo "socat failed to listen on :${BRIDGE_PORT}" >&2; exit 1; }
  rc=0
  wait "$dsh_pid" || rc=$?
  echo "dsh exited (code ${rc}); shutting the bridge down" >&2
  kill "$socat_pid" 2>/dev/null || true
  exit "$rc"
  ;;
sh | bash | /bin/sh | /bin/bash)
  # `docker run -it <image> bash` should open a shell, not run `dsh bash`.
  exec "$@"
  ;;
*)
  # Anything else is a dsh invocation, e.g. `--version` or a headless task.
  exec dsh "$@"
  ;;
esac
