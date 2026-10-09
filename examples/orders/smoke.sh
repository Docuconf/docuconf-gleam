#!/bin/sh
# Smoke test: starts the service with a valid environment and checks
# /healthz and /config, then starts it with PORT=0 and no DATABASE_URL and
# checks that it refuses to start. With the valid environment it also posts
# webhooks signed with each key of a key set that is mid-rotation, and last
# it checks that an empty webhook key fails at boot without printing a key.
# Needs curl and openssl. Run it from anywhere; it builds first.
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
# Two webhook keys: the old one and, mid-rotation, the new one.
old_key='old-webhook-key-0123456789abcdef0123'
new_key='new-webhook-key-0123456789abcdef0123'
log=$(mktemp)
pid=
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; rm -f "$log"' EXIT

fail() {
  echo "smoke: FAIL: $*" >&2
  cat "$log" >&2
  exit 1
}

# 1. A valid environment: the service starts and serves both routes.
PORT=$port DATABASE_URL=$secret WEBHOOK_KEYS="$old_key,$new_key" "$app" run >"$log" 2>&1 &
pid=$!
health=
for _ in $(seq 1 60); do
  health=$(curl -fsS "http://127.0.0.1:$port/healthz" 2>/dev/null) && break
  kill -0 "$pid" 2>/dev/null || fail "the service exited during startup"
  sleep 0.5
done
[ "$health" = ok ] || fail "GET /healthz returned '$health', want 'ok'"
config=$(curl -fsS "http://127.0.0.1:$port/config") || fail "GET /config failed"
case $config in *smoke-s3cret* | *webhook-key*) fail "GET /config leaks a secret: $config" ;; esac
case $config in *'"database_url":"***"'*) ;; *) fail "GET /config does not redact database_url: $config" ;; esac
case $config in *'"webhook_keys":"***"'*) ;; *) fail "GET /config does not redact webhook_keys: $config" ;; esac
grep -q 'config: Config(' "$log" || fail "the startup log does not show the config"
if grep -q -e smoke-s3cret -e webhook-key "$log"; then fail "the startup log leaks a secret"; fi
echo "smoke: GET /healthz -> $health"
echo "smoke: GET /config -> $config"

# Mid-rotation, a webhook signed with either key is accepted, and one signed
# with any other key, or not at all, is not.
body='{"order":"42","status":"paid"}'
post() { curl -s -o /dev/null -w '%{http_code}' -X POST "$@" -d "$body" "http://127.0.0.1:$port/webhooks/payments"; }
code=$(post)
[ "$code" = 401 ] || fail "an unsigned webhook got $code, want 401"
for key in "$old_key" "$new_key" "other-webhook-key-0123456789abcdef"; do
  sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$key" | sed 's/.*= //')
  want=204
  case $key in other*) want=401 ;; esac
  code=$(post -H "X-Signature: $sig")
  [ "$code" = "$want" ] || fail "webhook signed with the ${key%%-*} key: got $code, want $want"
done
echo "smoke: POST /webhooks/payments -> old and new key accepted, any other rejected"
kill "$pid"
wait "$pid" 2>/dev/null || true
pid=

# 2. PORT=0 and no DATABASE_URL: startup fails and names both problems.
status=0
env -u DATABASE_URL PORT=0 "$app" run >"$log" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail "the service started with an invalid environment"
grep -q missing_required "$log" || fail "no missing_required in the startup output"
grep -q out_of_range "$log" || fail "no out_of_range in the startup output"
grep -q '^docuconf: 2 configuration problems:$' "$log" || fail "no problem count in the startup output"
grep -qi stacktrace "$log" && fail "the startup output has a stack trace"
echo "smoke: invalid environment -> exit $status"
sed 's/^/  /' "$log"

# 3. An empty second webhook key (a trailing comma): startup fails with
# out_of_range, without printing a key.
status=0
DATABASE_URL=$secret WEBHOOK_KEYS="$old_key," "$app" run >"$log" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail "the service started with an empty webhook key"
grep -q '^docuconf: 1 configuration problem:$' "$log" || fail "no problem count for an empty webhook key"
grep -q 'WEBHOOK_KEYS \[out_of_range\]' "$log" || fail "no WEBHOOK_KEYS out_of_range"
if grep -q webhook-key "$log"; then fail "the startup output leaks a webhook key"; fi
echo "smoke: empty webhook key -> exit $status"
sed 's/^/  /' "$log"
echo "smoke: ok"
