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
echo "Before scanning, Retrace's setup checklist needs: Codex CLI signed in with ChatGPT (codex login),"
echo "Codex computer use on, a browser set to Always allow in Codex computer use, Accessibility and"
echo "Screen Recording for Retrace, and a Nemotron key in the Keychain. See macos/README.md."
