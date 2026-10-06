#!/bin/sh
# Runs the tests where Hex (repo.hex.pm) is unreachable: copies the project
# to a temporary directory and points its dependencies at source checkouts
# of the same packages (path dependencies cannot be published, so gleam.toml
# itself keeps the Hex requirements).
#
#   VENDOR=/path/with/stdlib,envoy,gleeunit scripts/offline-test.sh [--target erlang|javascript]
#
# Clone them with, for example:
#   git clone --depth 1 --branch v1.0.5 https://github.com/gleam-lang/stdlib $VENDOR/stdlib
#   git clone --depth 1 --branch v1.2.0 https://github.com/lpil/envoy $VENDOR/envoy
#   git clone --depth 1 --branch v1.11.0 https://github.com/lpil/gleeunit $VENDOR/gleeunit
set -eu
: "${VENDOR:?set VENDOR to the directory holding stdlib, envoy and gleeunit}"
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r "$here/src" "$here/test" "$here/gleam.toml" "$work/"
[ -d "$here/examples" ] && cp -r "$here/examples" "$work/"
sed -i \
  -e "s|^gleam_stdlib = .*|gleam_stdlib = { path = \"$VENDOR/stdlib\" }|" \
  -e "s|^envoy = .*|envoy = { path = \"$VENDOR/envoy\" }|" \
  -e "s|^gleeunit = .*|gleeunit = { path = \"$VENDOR/gleeunit\" }|" \
  "$work/gleam.toml"
# envoy's own gleam.toml asks Hex for gleam_stdlib; point it at the checkout.
for dep in envoy gleeunit; do
  sed -i "s|^gleam_stdlib = .*|gleam_stdlib = { path = \"$VENDOR/stdlib\" }|" "$VENDOR/$dep/gleam.toml"
done
export DOCUCONF_SPEC_CUE="${DOCUCONF_SPEC_CUE:-$here/../docuconf-go/spec/cue}"
cd "$work"
status=0
gleam build --warnings-as-errors "$@"
gleam test "$@" || status=$?
# Golden files written with UPDATE_GOLDEN=1 are copied back.
if [ "${UPDATE_GOLDEN:-}" = "1" ]; then cp -r "$work/test/golden/." "$here/test/golden/"; fi
exit $status
