#!/bin/bash
# Builds and installs Retrace.app into ~/Applications (no sudo).
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh
DEST="$HOME/Applications"
mkdir -p "$DEST"
pkill -x Retrace 2>/dev/null || true
rm -rf "$DEST/Retrace.app"
ditto dist/Retrace.app "$DEST/Retrace.app"
echo "Installed $DEST/Retrace.app. Open it from Finder or: open \"$DEST/Retrace.app\""
