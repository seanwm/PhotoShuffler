#!/bin/bash
# Removes the launchd agent and the installed app.
# Keeps your config, state, history and logs unless you pass --purge.
# Never touches the Photos library: the album and its photos stay as they are.
set -euo pipefail

LABEL="local.photoshuffler.nightly"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$HOME/Applications/PhotoShuffler.app"
SUPPORT="$HOME/Library/Application Support/PhotoShuffler"
LOGS="$HOME/Library/Logs/PhotoShuffler"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "Stopped $LABEL" || echo "$LABEL was not loaded"
rm -f "$AGENT" && echo "Removed $AGENT"
rm -rf "$APP" && echo "Removed $APP"

if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$SUPPORT" "$LOGS"
  echo "Removed $SUPPORT and $LOGS"
else
  echo "Kept $SUPPORT and $LOGS (use --purge to remove them)"
fi

cat <<EOF

The Photos album was left untouched. To also clear the Photos permission:
  tccutil reset Photos local.photoshuffler.app
EOF
