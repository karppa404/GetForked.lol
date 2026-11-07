#!/bin/bash
# Builds dist/Retrace.app from the SwiftPM executable. Reproducible: the bundle contains
# the release binary, branding resources and Info.plist. Signing defaults to ad hoc ("-"); set
# RETRACE_SIGN_IDENTITY to a real identity for a signature (and TCC grants) that survive rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
IDENTITY="${RETRACE_SIGN_IDENTITY:--}"
APP="dist/Retrace.app"
BUILD_ARGS=()
if [[ -n "${RETRACE_ARCH:-}" ]]; then
  case "$RETRACE_ARCH" in arm64|x86_64) ;; *) echo "Unsupported RETRACE_ARCH" >&2; exit 2 ;; esac
  BUILD_ARGS+=(--arch "$RETRACE_ARCH")
fi

swift build -c "$CONFIG" ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} --product Retrace
BIN="$(swift build -c "$CONFIG" ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} --show-bin-path)/Retrace"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/Retrace"
cp Packaging/Retrace.icns "$APP/Contents/Resources/"
cp -R "$(dirname "$BIN")/Retrace_Retrace.bundle" "$APP/Contents/Resources/"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --sign "$IDENTITY" --identifier dev.retrace.recorder \
  --entitlements Packaging/Retrace.entitlements --options runtime --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (signed with: $IDENTITY)"
