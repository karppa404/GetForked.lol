#!/usr/bin/env bash
# Packages a permission-free build. Never starts capture or includes local data/credentials.
set -euo pipefail
cd "$(dirname "$0")/.."
RETRACE_ARCH="${RETRACE_ARCH:-arm64}" macos/scripts/build-app.sh
npm --prefix figjam-plugin run build
mkdir -p release
APP_ARCH="${RETRACE_ARCH:-arm64}"
ditto -c -k --sequesterRsrc --keepParent macos/dist/Retrace.app "release/Retrace-macOS-$APP_ARCH.zip"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Retrace-FigJam-plugin/dist"
cp figjam-plugin/dist/code.js "$STAGING/Retrace-FigJam-plugin/dist/"
cp figjam-plugin/manifest.json figjam-plugin/ui.html figjam-plugin/README.md "$STAGING/Retrace-FigJam-plugin/"
ditto -c -k --keepParent "$STAGING/Retrace-FigJam-plugin" release/Retrace-FigJam-plugin.zip
(cd release && shasum -a 256 "Retrace-macOS-$APP_ARCH.zip" Retrace-FigJam-plugin.zip > SHA256SUMS.txt)
codesign --verify --strict macos/dist/Retrace.app
unzip -t "release/Retrace-macOS-$APP_ARCH.zip" >/dev/null
unzip -t release/Retrace-FigJam-plugin.zip >/dev/null
printf 'Release archives ready in release/\n'
