#!/bin/sh
# Smoke test: starts the service with a valid environment and checks
# /healthz and /config, then starts it with PORT=0 and no DATABASE_URL and
# checks that it refuses to start. Run it from anywhere; it builds first.
set -eu
cd "$(dirname "$0")"
gleam export erlang-shipment >/dev/null
app=build/erlang-shipment/entrypoint.sh
# A port nothing listens on yet, so the checks cannot reach another process.
port=${SMOKE_PORT:-$((20000 + $$ % 20000))}
while curl -s -o /dev/null "http://127.0.0.1:$port/"; [ $? -ne 7 ]; do
  port=$((port + 1))
done
secret='postgres://orders:smoke-s3cret@localhost:5432/orders'
log=$(mktemp)
pid=
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; rm -f "$log"' EXIT

fail() {
  echo "smoke: FAIL: $*" >&2
  cat "$log" >&2
  exit 1
}

# 1. A valid environment: the service starts and serves both routes.
PORT=$port DATABASE_URL=$secret "$app" run >"$log" 2>&1 &
pid=$!
health=
for _ in $(seq 1 60); do
  health=$(curl -fsS "http://127.0.0.1:$port/healthz" 2>/dev/null) && break
  kill -0 "$pid" 2>/dev/null || fail "the service exited during startup"
  sleep 0.5
done
[ "$health" = ok ] || fail "GET /healthz returned '$health', want 'ok'"
config=$(curl -fsS "http://127.0.0.1:$port/config") || fail "GET /config failed"
case $config in *smoke-s3cret*) fail "GET /config leaks the secret: $config" ;; esac
case $config in *'"database_url":"***"'*) ;; *) fail "GET /config does not redact database_url: $config" ;; esac
echo "smoke: GET /healthz -> $health"
echo "smoke: GET /config -> $config"
kill "$pid"
wait "$pid" 2>/dev/null || true
pid=

# 2. PORT=0 and no DATABASE_URL: startup fails and names both problems.
status=0
env -u DATABASE_URL PORT=0 "$app" run >"$log" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail "the service started with an invalid environment"
grep -q missing_required "$log" || fail "no missing_required in the startup output"
grep -q out_of_range "$log" || fail "no out_of_range in the startup output"
echo "smoke: invalid environment -> exit $status"
sed 's/^/  /' "$log"
echo "smoke: ok"
