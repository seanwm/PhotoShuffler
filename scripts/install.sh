#!/bin/bash
# Builds PhotoShuffler.app, installs it to ~/Applications, installs the nightly
# launchd agent, and asks macOS for Photos access.
#
# Options (environment variables):
#   HOUR=3 MINUTE=0     When the nightly run happens (default 3:00 AM)
#   SIGN_IDENTITY=...   Code-signing identity (default: ad hoc). See scripts/build.sh.
#   SKIP_BUILD=1        Install the existing build/PhotoShuffler.app as is
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
HOUR="${HOUR:-3}"
MINUTE="${MINUTE:-0}"
LABEL="local.photoshuffler.nightly"
APP_DEST="$HOME/Applications/PhotoShuffler.app"
SUPPORT="$HOME/Library/Application Support/PhotoShuffler"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

[[ "$HOUR" =~ ^[0-9]+$ && "$HOUR" -le 23 ]] || { echo "HOUR must be 0-23"; exit 1; }
[[ "$MINUTE" =~ ^[0-9]+$ && "$MINUTE" -le 59 ]] || { echo "MINUTE must be 0-59"; exit 1; }

if [[ -z "${SKIP_BUILD:-}" ]]; then
  scripts/build.sh
fi

echo "Installing app to $APP_DEST"
mkdir -p "$HOME/Applications"
rm -rf "$APP_DEST"
cp -R build/PhotoShuffler.app "$APP_DEST"

mkdir -p "$SUPPORT" "$HOME/Library/Logs/PhotoShuffler"
if [[ ! -f "$SUPPORT/config.json" ]]; then
  cp config/config.sample.json "$SUPPORT/config.json"
  echo "Created $SUPPORT/config.json from the sample. Check albumName before the first real run."
else
  echo "Keeping existing $SUPPORT/config.json"
fi

echo "Installing launchd agent ($LABEL) for $(printf '%02d:%02d' "$HOUR" "$MINUTE") nightly"
mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|__APP__|$APP_DEST|g" \
    -e "s|__HOME__|$HOME|g" \
    -e "s|__HOUR__|$HOUR|g" \
    -e "s|__MINUTE__|$MINUTE|g" \
    "launchd/$LABEL.plist" > "$AGENT"
plutil -lint "$AGENT" >/dev/null
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$AGENT"

echo
echo "Requesting Photos access (a macOS prompt may appear: choose Allow Full Access)..."
scripts/authorize.sh || true

cat <<EOF

Installed.
  App:     $APP_DEST
  Agent:   $AGENT
  Config:  $SUPPORT/config.json
  Log:     $HOME/Library/Logs/PhotoShuffler/PhotoShuffler.log

Next:
  scripts/run.sh --dry-run                       # preview without changing anything
  launchctl kickstart $DOMAIN/$LABEL   # run the real job now
EOF
