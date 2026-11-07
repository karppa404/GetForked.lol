#!/usr/bin/env bash
# Publish the Retrace module to a LOCAL SpacetimeDB and create a backend owner token.
#
# - Uses a separate CLI config (backend/.secrets/spacetime-cli.toml) so your normal
#   `spacetime login` is untouched.
# - The owner token is written to backend/.secrets/spacetime_token (0600) and never printed.
# - Start the server first, e.g.:  spacetime start --listen-addr 127.0.0.1:3000
#
# Usage: backend/scripts/spacetime_local_dev.sh [server_url] [database]
set -euo pipefail

SERVER="${1:-http://127.0.0.1:3000}"
DB="${2:-retrace-dev}"
SPACETIME="${SPACETIME_BIN:-spacetime}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SECRETS="$ROOT/backend/.secrets"
mkdir -p "$SECRETS" && chmod 700 "$SECRETS"
TOKEN_FILE="$SECRETS/spacetime_token"
CLI_CONFIG="$SECRETS/spacetime-cli.toml"

case "$SERVER" in
  http://127.0.0.1:*|http://localhost:*) ;;
  *) echo "refusing: this helper is for a loopback development server only" >&2; exit 2 ;;
esac

if [[ ! -s "$TOKEN_FILE" ]]; then
  umask 077
  curl -fsS -X POST "$SERVER/v1/identity" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])' > "$TOKEN_FILE"
  echo "created backend owner identity token at $TOKEN_FILE"
fi

"$SPACETIME" --config-path "$CLI_CONFIG" login --token "$(cat "$TOKEN_FILE")" >/dev/null
(cd "$ROOT/spacetimedb" && npm install --silent)
"$SPACETIME" --config-path "$CLI_CONFIG" publish "$DB" --server "$SERVER" --module-path "$ROOT/spacetimedb" --yes

cat <<EOF

Published $DB to $SERVER. Configure the API with:
  RETRACE_STATE_BACKEND=spacetimedb
  RETRACE_SPACETIME_URI=$SERVER
  RETRACE_SPACETIME_DATABASE=$DB
  RETRACE_SPACETIME_TOKEN_FILE=$TOKEN_FILE
EOF
