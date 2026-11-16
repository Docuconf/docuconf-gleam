#!/usr/bin/env bash
# Writes contract.cue from contract.json: the same contract in CUE, unified
# with the meta-schema's contract.#Contract so `cue vet -c` checks it.
# contract.json is the source; CI runs this and fails if contract.cue changes.
# Needs cue (cuelang.org/go/cmd/cue); CUE overrides its path.
set -euo pipefail
cd "$(dirname "$0")"
cue="${CUE:-cue}"
body="$("$cue" import -p shop -o - contract.json | sed '1d' | sed '/./,$!d')"
{
  printf '// Generated from contract.json by contract-cue.sh. DO NOT EDIT.\npackage shop\n\nimport "docuconf.dev/contract"\n\n'
  printf 'contract.#Contract & {\n%s\n}\n' "$(printf '%s\n' "$body" | sed 's/^/\t/')"
} >contract.cue
"$cue" fmt contract.cue
