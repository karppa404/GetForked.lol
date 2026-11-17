#!/bin/bash
# Builds dist/Retrace.app from the SwiftPM executable. Reproducible: the bundle contains
# the release binary, branding resources and Info.plist. Signing defaults to ad hoc ("-") with an
# explicit identifier-only designated requirement, so the code identity (and the Accessibility /
# Screen Recording grants macOS keys to it) stays the same across rebuilds instead of changing with
# every new cdhash. Set RETRACE_SIGN_IDENTITY (or RETRACE_CODESIGN_IDENTITY) to a real identity to
# sign with it; its default designated requirement (identifier + certificate) is then kept.
#
# The clone workflow uses the signed-in Codex CLI directly; no analysis server is bundled.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
IDENTITY="${RETRACE_SIGN_IDENTITY:-${RETRACE_CODESIGN_IDENTITY:--}}"
BUNDLE_ID="dev.retrace.recorder"
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

BACKEND_DIR="$(cd .. && pwd)/backend"
# Network capture addon + its redaction module, so builds work outside this checkout.
mkdir -p "$APP/Contents/Resources/network-helper" "$APP/Contents/Resources/backend/retrace"
cp ../network-helper/retrace_capture.py "$APP/Contents/Resources/network-helper/"
cp "$BACKEND_DIR/retrace/__init__.py" "$BACKEND_DIR/retrace/redaction.py" "$APP/Contents/Resources/backend/retrace/"
SIGN_ARGS=(--force --sign "$IDENTITY" --identifier "$BUNDLE_ID"
  --entitlements Packaging/Retrace.entitlements --options runtime --timestamp=none)
if [[ "$IDENTITY" == "-" ]]; then
  # Ad hoc signatures otherwise get `designated => cdhash H"…"`, which changes on every build.
  SIGN_ARGS+=(-r="designated => identifier \"$BUNDLE_ID\"")
fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict "$APP"
if [[ "$IDENTITY" == "-" ]] && ! codesign -d -r- "$APP" 2>&1 | grep -qx "designated => identifier \"$BUNDLE_ID\""; then
  echo "Unexpected designated requirement on $APP" >&2
  codesign -d -r- "$APP" >&2
  exit 1
fi
echo "Built $APP (signed with: $IDENTITY)"
