#!/bin/sh
# Smoke test: runs the shop as a real process for three cases of the test
# matrix (see README.md) and checks its output and exit status:
#   1. web, with its origins: prints one line, exits 0;
#   2. worker, with its queues: prints one line, exits 0;
#   6. JSON logs without LOG_SCHEMA_URL: lists the problem, exits 1, and
#      never prints the database URL.
# SHOP_TARGET picks the target (erlang, the default, or javascript). Run it
# from anywhere; it builds first.
set -eu
cd "$(dirname "$0")"
target=${SHOP_TARGET:-erlang}
gleam build --target "$target" >/dev/null
out=$(mktemp)
err=$(mktemp)
root=$(mktemp -d)
trap 'rm -rf "$out" "$err" "$root"' EXIT
secret='postgres://shop:smoke-s3cret@db:5432/shop'

fail() {
  echo "smoke: FAIL: $*" >&2
  sed 's/^/  stdout: /' "$out" >&2
  sed 's/^/  stderr: /' "$err" >&2
  exit 1
}

# shop VAR=value...: runs the shop with only these variables (and PATH), a
# fresh empty file root and the database URL; sets $status.
shop() {
  status=0
  env -i PATH="$PATH" HOME="${HOME:-/tmp}" DOCUCONF_FILE_ROOT="$root" DATABASE_URL="$secret" "$@" \
    gleam run --no-print-progress --target "$target" >"$out" 2>"$err" || status=$?
}

# 1. web
shop DOCUCONF_ROLE=web ALLOWED_ORIGINS=https://shop.example
[ "$status" -eq 0 ] || fail "web: exit $status, want 0"
[ "$(cat "$out")" = "shop web: port 8080, origins https://shop.example" ] || fail "web: wrong output"
echo "smoke: web -> $(cat "$out")"

# 2. worker: needs no ALLOWED_ORIGINS
shop DOCUCONF_ROLE=worker QUEUES=default,mail
[ "$status" -eq 0 ] || fail "worker: exit $status, want 0"
[ "$(cat "$out")" = "shop worker: queues default,mail, webhooks off" ] || fail "worker: wrong output"
echo "smoke: worker -> $(cat "$out")"

# 6. JSON logs need LOG_SCHEMA_URL (requiredIf)
shop DOCUCONF_ROLE=worker QUEUES=default LOG_FORMAT=json
[ "$status" -eq 1 ] || fail "json logs without a schema: exit $status, want 1"
[ ! -s "$out" ] || fail "json logs without a schema: printed to stdout"
grep -q '^docuconf: 1 configuration problem:$' "$err" || fail "no problem count"
grep -q '^  - LOG_SCHEMA_URL \[missing_required\]: .*is required when LOG_FORMAT is "json"' "$err" ||
  fail "no LOG_SCHEMA_URL missing_required"
if grep -q smoke-s3cret "$out" "$err"; then fail "the output leaks the database URL"; fi
echo "smoke: json logs without a schema -> exit $status"
sed 's/^/  /' "$err"
echo "smoke: ok ($target)"
