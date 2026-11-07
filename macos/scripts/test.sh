#!/bin/bash
# Runs RetraceCore unit tests. Tests never touch permissions, the Keychain, the network
# or the screen: HTTP is mocked and the fixture is a synthetic session.
set -euo pipefail
cd "$(dirname "$0")/.."
ARGS=()
DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
# With only Command Line Tools, swift-testing lives outside the default search path and the
# Foundation cross-import overlay module is not shipped; point the build at it explicitly.
if [[ "$DEV_DIR" == *CommandLineTools* ]]; then
  FW="$DEV_DIR/Library/Developer/Frameworks"
  ARGS+=(-Xswiftc -F -Xswiftc "$FW" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
         -Xlinker -F -Xlinker "$FW" -Xlinker -rpath -Xlinker "$FW")
fi
swift test ${ARGS[@]+"${ARGS[@]}"} "$@"
