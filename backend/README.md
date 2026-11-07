# Retrace API (backend)

Python 3.11+ FastAPI service: browser auth, local device connection, private evidence ingestion,
bounded four-stage Nemotron analysis, and shared state in SpacetimeDB.

```bash
cd backend
uv sync
uv run pytest                       # 88 tests; no network, no model credits
RETRACE_DEV_AUTH=1 RETRACE_LLM_PROVIDER=offline_heuristic uv run python -m retrace   # http://127.0.0.1:8000
```

`python -m retrace` binds `RETRACE_HOST` (default `127.0.0.1`) and `RETRACE_PORT` (8000) and
never trusts `X-Forwarded-*` headers. All configuration is environment variables; see
[`.env.example`](.env.example). Secrets are never logged or returned by any endpoint.

## Security decisions (explicit)

| Topic | Decision |
|---|---|
| Browser auth | `POST /v1/auth/google` verifies a Google ID token (signature via Google certs, `aud` = `RETRACE_GOOGLE_CLIENT_ID`, issuer, expiry, `email_verified`, optional domain allowlist). Returns 503 `google_login_not_configured` until the client ID is set. |
| Dev auth | `POST /v1/auth/dev` exists only with `RETRACE_DEV_AUTH=1`; config refuses it with `RETRACE_ENV=production` or a non-loopback `RETRACE_HOST`. Each request must come from a loopback client, with a loopback `Host` header (blocks DNS rebinding), and no forwarding headers. Otherwise 403/404. |
| Tokens | Opaque random 256-bit bearer tokens, stored only as SHA-256 hashes. Browser tokens are `rta_…` (12 h, revocable via logout). Device tokens are `rtd_…`, scoped to one project, revocable, and are never returned by claim, only once by a matching poll. Token kinds are not interchangeable. No cookies → no CSRF surface. CORS is limited to `RETRACE_CORS_ORIGINS`. |
| Authorization | Projects belong to one owner user. Anything outside your scope returns 404 (existence is not leaked). Devices can upload into their own project, start analysis, and read session status. They cannot read evidence, graphs or corrections. |
| Evidence | Frames are stored under `RETRACE_DATA_DIR/artifacts/<project>/<session>/frames/<frame_id>.<ext>` (dirs 0700, files 0600). Names come from validated UUIDs, never from client filenames. Frames are served only to the owning browser, with `Cache-Control: private, no-store`. Network evidence is redacted again on ingest. |
| SpacetimeDB | Every module table is **private**. Only identities in `trusted_writer` (the publishing backend owner) can call reducers. Only the owner token can SQL-read tables, and that token stays in the backend. Browsers get data only through per-viewer `my_*` views, after the backend grants their SpacetimeDB identity on a project they own (`POST /v1/projects/{id}/realtime-viewers`). Nothing private is in a public table. There is no public demo table yet. |
| Local fallback | `RETRACE_STATE_BACKEND=local` (default) uses a SQLite file reported as `local-dev-sqlite`, `realtime: "unavailable"`. It is never called SpacetimeDB and is refused in production unless explicitly overridden. |
| Model spend | No live calls in tests. Caps are listed under Analysis. The dollar stop is enforced only when per-token prices are configured. |

## HTTP API v1: implemented contract

Errors are always `{"error": "<code>", "message": "...", "details"?: [...]}`.

### Health and auth
- `GET /health` → `{status: "ok"|"degraded", version, environment, state: {backend, label, ready, realtime, error?, note?}, auth: {google_configured, dev_login_enabled}, analysis: {provider, configured, base_url_configured, api_key_configured, models: {workflow, network, reconcile, publish}, vision_enabled, budget}}`. Always 200. `status` reflects shared-state readiness.
- `POST /v1/auth/google` `{credential}` → `{access_token, token_type: "bearer", expires_at, user: {id, email, name}}`
- `POST /v1/auth/dev` `{email?, name?}` (body may be `{}`) → same shape as Google login.
- `GET /v1/auth/me` → `{user}`; `POST /v1/auth/logout` → 204.

### Projects and devices (browser)
- `GET /v1/projects` → `{projects: [{id, name, created_at}]}`
- `POST /v1/projects` `{name}` → 201 `{id, name, created_at}`
- `GET /v1/projects/{project_id}/sessions` → `{sessions: [SessionSummary]}`, newest first
- `GET /v1/projects/{project_id}/devices` → `{devices: [{device_id, project_id, device_name, created_at, last_used_at, revoked}]}`
- `DELETE /v1/devices/{device_id}` → 204 (browser owner). Device self-service: `GET /v1/devices/me`, `DELETE /v1/devices/me`.

### Local connection (recorder, development only)
- `POST /v1/local/connect` `{device_name}` (no auth) → 201 `{device_token, device_id, project_id, project_name: "Local workspace", api_base_url}`.
  Finds or creates one `Local workspace` project owned by the developer sign-in account (`dev@localhost`, the `/v1/auth/dev` default), so the dashboard sees uploads.
  404 unless `RETRACE_DEV_AUTH=1` (never in production). 403 unless the TCP peer and `Host` are loopback, no forwarding headers are present, and `Origin` is absent or loopback (blocks cross-site requests from web pages). Each call issues a new device token.

### Pairing (legacy compatibility; no longer used by the recorder)
- `POST /v1/pairings` `{project_id}` (browser) → 201 `{pairing_id, code: "ABCD-EFGH", expires_at}`. 10 min TTL, single use. Codes are 8 chars from a 30-letter unambiguous alphabet; case, spaces and dashes are ignored.
- `GET /v1/pairings/{pairing_id}` (browser) → `{pairing_id, project_id, status: "open"|"claimed"|"expired", expires_at, claims: [{claim_id, device_name, status: "pending"|"approved"|"rejected"|"completed"|"expired"}]}`. The code is not returned again.
- `POST /v1/pairings/claim` `{code, device_name}` (no auth, 10/min/IP) → 201 `{claim_id, claim_secret, status: "pending"}`. Unknown, expired and used codes all return 400 `invalid_or_expired_code`.
- `POST /v1/pairings/{pairing_id}/approve` and `/reject` `{claim_id}` (browser) → `{claim_id, status}`. 404 unknown, 409 already decided, 410 claim expired.
- `POST /v1/pairings/claims/{claim_id}/poll` `{claim_secret}` →
  - pending: 200 `{status: "pending", poll_after_ms}`
  - approved: 200 `{status: "approved", device_token, project_id}`, issued **once**
  - replay after issue: 410 `{status: "consumed"}`; expired (TTL or 900 polls): 410 `{status: "expired"}`; rejected: 403 `{status: "rejected"}`
  - wrong secret or unknown claim: 404; polling faster than 1/s: 429 with `Retry-After`

### Sessions
- `POST /v1/sessions` (device) multipart: one text field `manifest` (JSON string) and repeated `files` parts whose filenames are the manifest's frame basenames.
  - 201 `{id, status: "uploaded", server_redactions}`.
  - An **identical** re-upload (same manifest bytes, same project) returns 200 `{…, duplicate: true}` and writes nothing new. This is a safe client retry, and it also repairs shared state if a previous attempt crashed. A different manifest under the same id, or the same id in another project, returns 409.
  - Errors: 400 file-level (`unsafe_filename`, `unreferenced_file`, `missing_files`, `duplicate_file`, `sha256_mismatch`, `bad_image`, `empty_file`, `unexpected_fields`), 403 `project_mismatch`, 413 limits, 415 not multipart, 422 `invalid_manifest` with `details`.
- `GET /v1/sessions/{id}` (browser owner, or a device of the project):
  ```
  SessionSummary & {
    job: Job | null,                  // latest job, with stages
    jobs: [Job without stages],
    graph_meta: {graph_id, version, job_id, published_at, network_status, node_count, edge_count, url} | null,
    // browser only:
    frames: [Frame & {image_url: "/v1/sessions/{id}/frames/{frame_id}"}],
    interactions: [...], network: [...redacted], redaction: {...},
    graph: Graph | null,               // latest agent graph, corrections NOT applied
    corrections: [{element_id, label, updated_at, author}],
    board_url: string | null
  }
  SessionSummary = {id, project_id, status: "uploaded"|"queued"|"analyzing"|"analyzed"|"failed",
    app: {name, bundle_id}, task /* legacy, usually "" */, started_at, duration_ms,
    counts: {frames, interactions, network}, network_status, uploaded_at, uploaded_by_device}
  Job = {id, status: "queued"|"running"|"succeeded"|"failed", stage, error,
    usage: {calls, prompt_tokens, completion_tokens, estimated}, created_at, updated_at,
    stages: [{name: "workflow"|"network"|"reconcile"|"publish", label,
              status: "pending"|"running"|"done"|"failed"|"skipped", detail, updated_at}]}
  ```
- `GET /v1/sessions/{id}/evidence` (browser) → `{id, network_status, frames, interactions, network, redaction}`
- `GET /v1/sessions/{id}/frames/{frame_id}` (browser) → image bytes
- `POST /v1/sessions/{id}/analyze` body `{}` or `{"rerun": true}` (browser or device):
  - 202 `{job_id, status: "queued"}` when a new job starts.
  - 200 `{job_id, status, existing: true}` when the request reuses a job: always for a queued/running job, and, without `rerun`, for a succeeded job or any job created within 120 s. Client retries therefore never start duplicate jobs, and the dashboard must send `{"rerun": true}` to re-analyze.
  - 503 `analysis_not_configured`.
- `GET /v1/sessions/{id}/graph[?version=N&corrections=true&download=1]` (browser or device) → Graph with corrections applied (default). 404 `graph_not_found` until one is published.
- `GET /v1/sessions/{id}/corrections` (browser) → `{corrections, version}` plus `ETag`. Poll this cheaply while no job is running.
- `PUT /v1/sessions/{id}/corrections/{element_id}` `{label}` (browser) → `{element_id, label, updated_at, author}`. The element must exist in some published version (404 `unknown_element`).
- `DELETE /v1/sessions/{id}/corrections/{element_id}` (browser) → 204. The agent label returns.
- `PUT /v1/sessions/{id}/board` `{board_url}` (browser) → `{session_id, board_url}`. Only `https://*.figma.com/…` URLs are accepted; `null` clears it.

### Realtime (SpacetimeDB)
- `GET /v1/realtime` (browser) → `{backend, ready, realtime}`, plus `{uri, database, views}` when SpacetimeDB is in use.
- `POST|DELETE /v1/projects/{id}/realtime-viewers` `{identity}` (browser owner) grants or revokes a browser SpacetimeDB identity (64 hex) on the per-viewer views. With local state it returns 409 `realtime_unavailable`.

### Graph v1 as published
```
{schema_version: 1, session_id, graph_version, generated_at,
 generated_by: {pipeline, provider, job_id, models},
 nodes: [{id: "<type>:<primary evidence id>", type: "screen"|"action"|"api_call", label, evidence_ids,
          network_status? (actions), agent_label?/corrected? (with corrections)}],
 edges: [{id: "edge:<hash>", source, target, label, evidence_ids,
          association: "observed"|"candidate", basis: "interaction"|"timing"|"inferred"}],
 network_status: "observed"|"none_observed"|"not_captured",
 ambiguities: [{message, element_id?}],
 suggestions: [{id, kind: "suggestion", label, rationale, related_element_ids}],
 corrections?: [{element_id, label, updated_at, applied}]}
```
Deterministic rules applied before publishing (`retrace/graph.py`):
- Every node and edge cites evidence captured in the session; unknown IDs are removed and elements left without evidence are dropped.
- Screens need a frame, actions an interaction, api_calls a network entry.
- Edges touching an api_call are always `candidate` (passive capture shows timing, not causation).
- Workflow edges are `observed` only with interaction evidence.
- `network_status` comes from the recorder's declaration, never from the model. `none_observed` means capture ran and found nothing; with `not_captured` no api nodes can exist.
- Suggestions never appear as nodes or edges.
- IDs are stable across reruns, so corrections (a separate table keyed by `(session_id, element_id)`) survive agent reruns.

### Manifest (matches `macos/Sources/RetraceCore/Models.swift`)
Strict (unknown fields rejected). Additions beyond `docs/INTEGRATION.md`:
- required `network_status`: must be consistent with `network`.
- `Interaction.delayed_frame_id`.
- `kind` ∈ click, double_click, right_click, other_click, scroll, key, text_input, focus_lost, focus_regained.
- `key` must be `redacted` or a macOS-named key/shortcut with modifiers in {ctrl, opt, shift, cmd} (letters and digits need cmd or ctrl); `text_input` requires `redacted`.
- `accessibility` = {role, subrole, title, label, identifier, window_title, secure}. Secure fields must not carry title, label or identifier.
- `redaction` = {reviewed: true, omitted_frames?, omitted_interactions?, window_titles_removed?}.
- Limits: 2 MB manifest, 300 frames, 5000 interactions, 2000 network entries, 10 MB per frame, 250 MB per upload. PNG/JPEG magic bytes and SHA-256 are verified.

## Analysis (four bounded stages)

1. Workflow analyst: frames (images only if `RETRACE_LLM_VISION=1`) and interactions → screens and actions.
2. Network analyst: runs in parallel with stage 1 and only if capture ran with entries; it is skipped, without spending, otherwise. Produces API calls and timing associations.
3. Reconciliation: refines a deterministic merge of stages 1 and 2. If it fails, the validated mechanical draft is used.
4. Publisher: final labels, ambiguities and suggestions. Its output is re-validated; if it is invalid, the validated reconciliation is published, with an ambiguity note.

Each stage result is written to shared state as it completes (`job_stage`), so dashboards see progress.

Bounds (env, defaults):

| Variable | Default | Meaning |
|---|---|---|
| `RETRACE_LLM_MAX_CALLS_PER_JOB` | 8 | Every HTTP attempt counts, including retries and repairs |
| `RETRACE_LLM_MAX_RETRIES` | 2 | Retries on 429/5xx/timeouts, with exponential backoff honoring `Retry-After` (≤10 s) |
| `RETRACE_LLM_TIMEOUT_S` | 60 | Per request |
| `RETRACE_LLM_MAX_OUTPUT_TOKENS` | 2048 | Per call |
| `RETRACE_LLM_MAX_PROMPT_CHARS` | 60000 | Evidence is truncated to fit |
| `RETRACE_LLM_MAX_FRAMES` | 4 | Images per job, ≤1.5 MB each |
| `RETRACE_LLM_MAX_TOKENS_PER_JOB` | 150000 | Reservation = estimated prompt + max output |
| `RETRACE_LLM_MAX_JOB_SECONDS` | 600 | Wall-clock cap, which matters for hourly-billed GPUs |
| `RETRACE_LLM_MAX_CONCURRENCY` | 2 | Process-wide |
| `RETRACE_MAX_CONCURRENT_JOBS` | 1 | |
| `RETRACE_BUDGET_TOTAL_TOKENS` | 3,000,000 | Persistent ledger (`auth.sqlite3`, `llm_usage`) |
| `RETRACE_BUDGET_USD` + `RETRACE_PRICE_INPUT_PER_MTOK`/`RETRACE_PRICE_OUTPUT_PER_MTOK` | 45 | Dollar stop **only** when prices are set |

The ledger uses provider-reported usage when present and conservative estimates otherwise. Failed attempts are booked at their estimated prompt size. **Exact dollar enforcement is not possible** without real provider prices and usage, and `/health` reports `usd_enforcement: "unavailable_prices_not_configured"` in that case. For a self-hosted GPU (for example a Brev L40S at about $1.77/h) cost is uptime, not tokens: the per-job wall-clock cap and the call caps bound GPU time per job. Stop the instance when you are not testing.

### Endpoint configuration
- `RETRACE_LLM_BASE_URL`: OpenAI-compatible base including `/v1`. It must be `https`, unless it is a loopback port forward such as `http://127.0.0.1:8001/v1` from `brev port-forward` or `ssh -L`.
- `RETRACE_LLM_API_KEY`: optional only for loopback endpoints.
- Model IDs: `RETRACE_LLM_MODEL` (default for all stages) and optional `RETRACE_LLM_MODEL_WORKFLOW`, `_NETWORK`, `_RECONCILE`, `_PUBLISH`. For a Nano VL model set `RETRACE_LLM_VISION=1`.
- Redirects are not followed, and HTML (tunnel login) responses fail fast with a hint. Browser-authenticated Brev tunnels therefore do not work as API endpoints; use a local port forward instead.
- `RETRACE_LLM_PROVIDER=offline_heuristic` gives deterministic, credit-free development analysis. Graphs are labeled `generated_by.provider = "offline_heuristic"`, and this provider is refused in production.

Probe without spending (lists models and checks the configured IDs; output is masked):
```bash
uv run python scripts/probe_model_endpoint.py
uv run python scripts/probe_model_endpoint.py --chat --allow-spend   # ONE call, max 8 output tokens
```

## SpacetimeDB

```bash
spacetime start --listen-addr 127.0.0.1:3000          # separate terminal
backend/scripts/spacetime_local_dev.sh http://127.0.0.1:3000 retrace-dev
export RETRACE_STATE_BACKEND=spacetimedb RETRACE_SPACETIME_URI=http://127.0.0.1:3000 \
       RETRACE_SPACETIME_DATABASE=retrace-dev RETRACE_SPACETIME_TOKEN_FILE=backend/.secrets/spacetime_token
```
The script creates a dedicated owner identity, keeps the token in `backend/.secrets/` (0600, gitignored, never printed), uses a separate CLI config, and publishes `spacetimedb/`. `/health` then reports `state.backend = "spacetimedb"` with `ready`. When the server is unreachable, `ready` is false with an `error`, and data endpoints return 503 `state_unavailable`. They never fall back silently.

Live integration tests run against a disposable database:
```bash
RETRACE_TEST_SPACETIME_URI=http://127.0.0.1:3000 RETRACE_TEST_SPACETIME_DATABASE=retrace-dev \
RETRACE_TEST_SPACETIME_TOKEN_FILE=backend/.secrets/spacetime_token uv run pytest tests/test_spacetime_state.py
```

Dashboard realtime flow:
1. Connect with the SpacetimeDB TS SDK to `uri`/`database` from `GET /v1/realtime`.
2. Send the connection's identity to `POST /v1/projects/{id}/realtime-viewers`.
3. Subscribe to `my_projects`, `my_sessions`, `my_jobs`, `my_job_stages`, `my_graphs`, `my_corrections`, `my_session_boards` and `my_evidence_refs`.

All writes still go through the HTTP API. The identity grant is not proof of possession: an owner who submits someone else's identity shares their own project with that identity.

## Layout
`retrace/app.py` routes · `authstore.py` hashed credentials and usage ledger · `ingest.py` multipart validation · `models.py` manifest · `graph.py` validator · `analysis/` pipeline, bounded client, offline provider · `state/` SpacetimeDB and local fallback · `redaction.py` (shared with `network-helper/`).
