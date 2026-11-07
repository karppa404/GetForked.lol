# Run the integrated local demo

The public Vercel site remains a sample-data preview until Google login and hosted API configuration are available. The local workspace uses the actual API and SpacetimeDB.

## Terminals

1. Start the local shared state server (port 3100 leaves port 3000 for Next.js):

   ```sh
   ~/.local/bin/spacetime start --listen-addr 127.0.0.1:3100
   ```

2. From the repository root, bootstrap the private module and start the API:

   ```sh
   SPACETIME_BIN="$HOME/.local/bin/spacetime" backend/scripts/spacetime_local_dev.sh http://127.0.0.1:3100 retrace-integration
   cd backend
   RETRACE_DEV_AUTH=1 RETRACE_STATE_BACKEND=spacetimedb \
   RETRACE_SPACETIME_URI=http://127.0.0.1:3100 \
   RETRACE_SPACETIME_DATABASE=retrace-integration \
   RETRACE_SPACETIME_TOKEN_FILE=.secrets/spacetime_token \
   RETRACE_LLM_PROVIDER=offline_heuristic uv run python -m retrace
   ```

   `offline_heuristic` explicitly enables deterministic development analysis with zero model calls. The dashboard labels it as development analysis. To use Nemotron, omit that provider override and set `RETRACE_LLM_BASE_URL`, `RETRACE_LLM_MODEL`, `RETRACE_LLM_VISION=1`, and `RETRACE_LLM_API_KEY_FILE` pointing to a private key file (or use the key environment variable). The Brev endpoint must accept the configured credential before a live test can run.

3. Start the dashboard:

   ```sh
   cd web
   npm ci
   npm run dev -- --hostname 127.0.0.1
   ```

   Open http://127.0.0.1:3000/dashboard and choose **Developer sign-in**. Create a project and generate a room code. This bypass is limited to loopback development and cannot be enabled in production.

4. Build and open the native recorder:

   ```sh
   macos/scripts/run.sh
   ```

   Connect to `http://127.0.0.1:8000`, enter the room code, and approve the Mac in the dashboard. Grant macOS permissions through the app. Select a supported target app and demonstrate a task yourself. Stop, inspect and omit sensitive evidence, confirm review, then choose **Upload & Analyze**. Recordings remain local until this action.

5. Open the session in two local browser windows, signed into the same development account. The header should say **Live updates**. Rename a workflow node in one window and see the other update through SpacetimeDB. A bounded API refresh takes over if subscriptions are unavailable.

6. Download graph JSON, build/register the [FigJam plugin](../figjam-plugin/README.md), and import the graph into a board you own. Save that board's URL on the session for later access. Figma runtime import is a separate manual check; compilation and graph validation do not prove the plugin ran in Figma.

## Credit-free integration verification

With the API above running:

```sh
cd backend
uv run python scripts/smoke_local.py
cd ../web
RETRACE_LIVE_FIXTURE=../backend/.secrets/integration_fixture.json npm test -- --run lib/dashboard/__tests__/live.test.ts
```

The smoke creates a synthetic project using a separate `integration@localhost` account, uploads the committed native test frames, runs four deterministic stages, checks correction persistence across reruns and exports the graph. The web check opens two independent authorized SpacetimeDB subscriptions and verifies corrections reach both. This checks real HTTP/WebSocket interoperability, not actual screen recording, browser layout, Google authentication, or Nemotron quality. Generated tokens remain in the gitignored `backend/.secrets/` directory and are never printed.

## Hosted rollout

The API currently stores private artifacts on its own disk. A hosted deployment needs a persistent private volume or the planned private object-store adapter. The public landing/dashboard can remain on Vercel; deploy the Python worker/API separately with Google OAuth configuration, a SpacetimeDB instance, durable artifact storage and an authenticated inference endpoint. Never point the public site at localhost or enable development authentication on an internet-facing API.
