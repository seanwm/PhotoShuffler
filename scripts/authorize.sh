#!/bin/bash
# Asks macOS to grant PhotoShuffler.app read/write Photos access.
#
# The app is launched through LaunchServices (`open`) so that macOS attributes
# the request to PhotoShuffler itself. Running the binary from Terminal would
# attribute it to Terminal instead, and the launchd job wouldn't get the grant.
#
# Re-run this after every rebuild if you sign ad hoc (the default): the grant is
# tied to the code signature, which changes with each build.
set -euo pipefail

APP="${APP:-$HOME/Applications/PhotoShuffler.app}"
LOG="$HOME/Library/Logs/PhotoShuffler/PhotoShuffler.log"

[[ -d "$APP" ]] || { echo "Not found: $APP (run scripts/install.sh first)"; exit 1; }

open -W -n "$APP" --args --authorize

result="$(grep "authorize: Photos access is now" "$LOG" 2>/dev/null | tail -1 || true)"
echo "${result:-No result in $LOG}"
if [[ "$result" != *"authorized (full access)"* ]]; then
  cat <<EOF

PhotoShuffler doesn't have full Photos access yet.
Open System Settings > Privacy & Security > Photos and set PhotoShuffler to
"Full Access", then run this script again to confirm.
EOF
  exit 3
fi
