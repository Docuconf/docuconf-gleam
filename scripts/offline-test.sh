#!/bin/sh
# Runs the tests where Hex (repo.hex.pm) is unreachable: copies the project
# to a temporary directory and points its dependencies at source checkouts
# of the same packages (path dependencies cannot be published, so gleam.toml
# itself keeps the Hex requirements).
#
#   VENDOR=/path/to/checkouts scripts/offline-test.sh [--target erlang|javascript]
#
# VENDOR holds one checkout per package, named after the package (`stdlib`
# is accepted for gleam_stdlib). For the SDK, clone:
#   git clone --depth 1 --branch v1.0.5 https://github.com/gleam-lang/stdlib $VENDOR/gleam_stdlib
#   git clone --depth 1 --branch v1.2.0 https://github.com/lpil/envoy $VENDOR/envoy
#   git clone --depth 1 --branch v1.11.0 https://github.com/lpil/gleeunit $VENDOR/gleeunit
#
# When VENDOR also holds wisp and mist with their dependencies (wisp's
# manifest.toml lists them), the script then checks examples/orders as CI
# does: build, test, re-export contract.cue and compare, cue vet, and
# smoke.sh.
# A rebar3 checkout (hpack_erl) is wrapped as a Gleam package on the fly.
set -eu
: "${VENDOR:?set VENDOR to the directory holding the package checkouts}"
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r "$here/src" "$here/test" "$here/gleam.toml" "$here/README.md" "$work/"
[ -d "$here/examples" ] && cp -r "$here/examples" "$work/"
rm -rf "$work/examples/orders/build" "$work/examples/orders/manifest.toml"

# Copy the checkouts, so their gleam.toml files can be rewritten.
mkdir "$work/vendor"
for dir in "$VENDOR"/*/; do
  pkg=$(basename "$dir")
  [ "$pkg" = stdlib ] && pkg=gleam_stdlib
  cp -r "$dir" "$work/vendor/$pkg"
  rm -rf "$work/vendor/$pkg/build" "$work/vendor/$pkg/manifest.toml"
  if [ ! -f "$work/vendor/$pkg/gleam.toml" ] && [ -f "$work/vendor/$pkg/rebar.config" ]; then
    rm -f "$work/vendor/$pkg"/src/*.app.src
    printf 'name = "%s"\nversion = "0.0.0"\ntarget = "erlang"\n' "$pkg" >"$work/vendor/$pkg/gleam.toml"
  fi
done
for toml in "$work/gleam.toml" "$work"/examples/*/gleam.toml "$work"/vendor/*/gleam.toml; do
  [ -f "$toml" ] || continue
  for dir in "$work"/vendor/*/; do
    pkg=$(basename "$dir")
    sed -i "s|^$pkg = .*|$pkg = { path = \"$work/vendor/$pkg\" }|" "$toml"
  done
done
# The checkouts' own dev dependencies are not needed, and may not be vendored.
for toml in "$work"/vendor/*/gleam.toml; do
  sed -i '/^\[dev[-_]dependencies\]/,/^\[/{/^[a-z_]* = /d}' "$toml"
done

export DOCUCONF_SPEC_CUE="${DOCUCONF_SPEC_CUE:-$here/../docuconf-go/spec/cue}"
export DOCUCONF_CONFORMANCE="${DOCUCONF_CONFORMANCE:-$here/../docuconf-go/conformance/cases.json}"
cd "$work"
status=0
gleam format --check src test
gleam build --warnings-as-errors "$@"
gleam test "$@" || status=$?
# Golden files written with UPDATE_GOLDEN=1 are copied back.
if [ "${UPDATE_GOLDEN:-}" = "1" ]; then cp -r "$work/test/golden/." "$here/test/golden/"; fi

if [ -d "$work/vendor/wisp" ] && [ -d "$work/examples/orders" ]; then
  cd "$work/examples/orders"
  gleam format --check src dev test
  gleam build --warnings-as-errors
  gleam test
  gleam run -m orders/contract
  # UPDATE_GOLDEN=1 also takes the freshly exported contract.
  if [ "${UPDATE_GOLDEN:-}" = "1" ]; then cp contract.cue "$here/examples/orders/contract.cue"; fi
  # Ignores metadata.generator.version, which release PRs bump.
  "$here/scripts/check-generated.sh" --files "$here/examples/orders/contract.cue" contract.cue
  if command -v cue >/dev/null && [ -d "$DOCUCONF_SPEC_CUE" ]; then
    vet=$(mktemp -d "$work/vet.XXXX")
    cp -r "$DOCUCONF_SPEC_CUE/cue.mod" "$DOCUCONF_SPEC_CUE/contract" "$vet/"
    mkdir "$vet/orders" && cp contract.cue "$vet/orders/"
    # Not `a && b`: set -e ignores a failure on the left of &&.
    (cd "$vet" && cue vet -c ./orders)
    echo "orders: cue vet -c ok"
  fi
  ./smoke.sh
fi
exit $status
