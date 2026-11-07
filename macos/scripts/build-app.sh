#!/bin/bash
# Builds dist/Retrace.app from the SwiftPM executable. Reproducible: the bundle contains
# only the release binary and Packaging/Info.plist. Signing defaults to ad hoc ("-"); set
# RETRACE_SIGN_IDENTITY to a real identity for a signature (and TCC grants) that survive rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
IDENTITY="${RETRACE_SIGN_IDENTITY:--}"
APP="dist/Retrace.app"

swift build -c "$CONFIG" --product Retrace
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Retrace"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/Retrace"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --sign "$IDENTITY" --identifier dev.retrace.recorder \
  --entitlements Packaging/Retrace.entitlements --options runtime --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (signed with: $IDENTITY)"
