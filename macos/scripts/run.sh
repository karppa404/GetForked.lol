#!/bin/bash
# Builds and launches the menu bar app. Launching does not request any permission;
# prompts appear only when you press Request/Start in the menu.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh
open dist/Retrace.app
