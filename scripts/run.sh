#!/bin/bash
# Runs the installed PhotoShuffler.app with the given options and shows its output,
# e.g. scripts/run.sh --dry-run --seed 1
#
# Goes through `open` so Photos access is checked against PhotoShuffler.app, the
# same identity the launchd job uses (not Terminal's). Note: `open` doesn't pass
# the exit code back; read the output.
set -euo pipefail

APP="${APP:-$HOME/Applications/PhotoShuffler.app}"
[[ -d "$APP" ]] || { echo "Not found: $APP (run scripts/install.sh first)"; exit 1; }

OUT="$(mktemp -t photoshuffler)"
trap 'rm -f "$OUT"' EXIT
open -W -n --stdout "$OUT" --stderr "$OUT" "$APP" --args "$@"
cat "$OUT"
