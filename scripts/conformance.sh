#!/usr/bin/env bash
# Runs the shared conformance suite (docuconf-go conformance/cases.json) and
# the tests that `cue vet` exported contracts against the meta-schema
# (docuconf-go spec/cue). Not the full suite. Used by this repo's CI and by
# docuconf-go's downstream gate.
#
#   DOCUCONF_GO_DIR=/path/to/docuconf-go scripts/conformance.sh
#
# GLEAM_TARGET picks the target (erlang, the default, or javascript). Needs
# gleam, Erlang/OTP (and Node for javascript) and cue on PATH.
#
# gleeunit runs every test module, so the project is copied to a temporary
# directory with only the modules that matter here: conformance_test (the
# shared suite) and docuconf_test (export_cue_vet_test and the golden export),
# plus the modules and FFI files they use.
set -euo pipefail

: "${DOCUCONF_GO_DIR:?set DOCUCONF_GO_DIR to a docuconf-go checkout}"
DOCUCONF_GO_DIR=$(cd "$DOCUCONF_GO_DIR" && pwd)
export DOCUCONF_GO_DIR
export DOCUCONF_CONFORMANCE="${DOCUCONF_CONFORMANCE:-$DOCUCONF_GO_DIR/conformance/cases.json}"
export DOCUCONF_SPEC_CUE="${DOCUCONF_SPEC_CUE:-$DOCUCONF_GO_DIR/spec/cue}"
export DOCUCONF_REQUIRE_CONFORMANCE=1
export DOCUCONF_REQUIRE_VET=1

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r "$here/gleam.toml" "$here/src" "$work/"
if [ -f "$here/manifest.toml" ]; then cp "$here/manifest.toml" "$work/"; fi
mkdir "$work/test"
for f in docuconf_gleam_test conformance_test docuconf_test support sample; do
  cp "$here/test/$f.gleam" "$work/test/"
done
cp -r "$here/test/golden" "$here"/test/*.erl "$here"/test/*.mjs "$work/test/"

cd "$work"
gleam deps download
gleam test --target "${GLEAM_TARGET:-erlang}"
