#!/bin/bash
# Builds PhotoShuffler.app in ./build and signs it.
#
# Compiles with swiftc directly rather than `swift build`, so it works even when
# SwiftPM is unavailable or broken. Package.swift is still there for `swift test`.
#
# Signing: ad hoc by default. macOS ties the Photos permission to the code
# signature, and an ad hoc signature changes on every rebuild, so after a rebuild
# you'll need to grant access again (scripts/authorize.sh). If you have an
# "Apple Development" or "Developer ID Application" certificate, set
# SIGN_IDENTITY to its name and the grant survives rebuilds.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD="$ROOT/build"
APP="$BUILD/PhotoShuffler.app"
OBJ="$BUILD/obj"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
# Minimum macOS, matching LSMinimumSystemVersion in Info.plist and Package.swift.
# Without this, swiftc targets the build machine's macOS version.
TARGET="$(uname -m)-apple-macos14.0"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"

rm -rf "$APP" "$OBJ"
mkdir -p "$OBJ" "$APP/Contents/MacOS"

echo "Compiling ShufflerCore..."
swiftc -O -swift-version 5 -target "$TARGET" -parse-as-library \
  -module-name ShufflerCore \
  -emit-module -emit-module-path "$OBJ/ShufflerCore.swiftmodule" \
  -emit-library -static -o "$OBJ/libShufflerCore.a" \
  Sources/ShufflerCore/*.swift

echo "Compiling PhotoShuffler..."
swiftc -O -swift-version 5 -target "$TARGET" \
  -module-name PhotoShuffler \
  -I "$OBJ" -L "$OBJ" -lShufflerCore \
  -framework Photos \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$ROOT/Resources/Info.plist" \
  -o "$APP/Contents/MacOS/PhotoShuffler" \
  Sources/PhotoShuffler/*.swift

cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "Signing ($SIGN_IDENTITY)..."
codesign --force --timestamp=none \
  --identifier "$BUNDLE_ID" --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "Built $APP"
