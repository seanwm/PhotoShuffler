#!/bin/bash
# Runs the unit tests. Uses `swift test` when SwiftPM works; otherwise compiles
# the tests with swiftc and runs them through Swift Testing's entry point.
set -euo pipefail

cd "$(dirname "$0")/.."

if swift package describe >/dev/null 2>&1; then
  exec swift test
fi

echo "SwiftPM unavailable; building tests with swiftc"
DEV="$(xcode-select -p)"
case "$DEV" in
  */CommandLineTools) FRAMEWORKS="$DEV/Library/Developer/Frameworks"; PLUGINS="$DEV/usr/lib/swift/host/plugins/testing" ;;
  *) FRAMEWORKS="$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks"; PLUGINS="$DEV/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing" ;;
esac

OBJ="build/test-obj"
rm -rf "$OBJ"
mkdir -p "$OBJ"

swiftc -swift-version 5 -parse-as-library -enable-testing \
  -module-name ShufflerCore \
  -emit-module -emit-module-path "$OBJ/ShufflerCore.swiftmodule" \
  -emit-library -static -o "$OBJ/libShufflerCore.a" \
  Sources/ShufflerCore/*.swift

cat > "$OBJ/TestMain.swift" <<'EOF'
import Foundation
import Testing

@main struct TestMain {
    static func main() async {
        exit(await Testing.__swiftPMEntryPoint(passing: nil))
    }
}
EOF

swiftc -swift-version 5 -parse-as-library \
  -module-name ShufflerCoreTests \
  -I "$OBJ" -L "$OBJ" -lShufflerCore \
  -F "$FRAMEWORKS" -framework Testing \
  -plugin-path "$PLUGINS" \
  -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$FRAMEWORKS/../usr/lib" \
  -o "$OBJ/run-tests" \
  Tests/ShufflerCoreTests/*.swift "$OBJ/TestMain.swift"

"$OBJ/run-tests"
