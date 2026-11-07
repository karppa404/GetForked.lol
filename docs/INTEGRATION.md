# First integration contract

Product name: Retrace. Localhost workspace, one selected application, ongoing observed activity. The user starts and stops capture; no task or reason is requested.

## HTTP API, version 1

Base URL is configurable on every client. Development: http://127.0.0.1:8000.
All request/response JSON uses snake_case. Evidence timestamps are milliseconds from session start, with session `started_at` an ISO 8601 UTC timestamp. Evidence IDs are UUID strings. Credentials must never be included in evidence or source.

- POST /v1/local/connect: native client sends `{device_name}`. Returns `{device_token, device_id, project_id, project_name, api_base_url}` for the default developer account's `Local workspace`. Available only in local development with loopback peer and Host; remote Origin and forwarding headers are rejected. Store the token in Keychain. No room code or approval screen.
- POST /v1/sessions: device bearer auth, multipart `manifest` JSON string and `files` attachments. Manifest has `schema_version:1`, `id`, `project_id`, `app:{name,bundle_id,pid}`, optional legacy `task`, `started_at`, `duration_ms`, `interactions:[]`, `frames:[]`, `network:[]`, `redaction:{reviewed:true}`. Response `{id,status:"uploaded"}`. Never upload without explicit local user action.
- POST /v1/sessions/{id}/analyze: authorized browser or connected device starts bounded analysis. Response `{job_id,status}`.
- GET /v1/sessions/{id}: authorized browser/device reads metadata and analysis.
- GET /v1/projects: browser's projects.
- POST /v1/projects: `{name}` creates project.
- GET /health: reports readiness without secrets.

Interaction: `{id,timestamp_ms,kind,x?,y?,key?,scroll_dx?,scroll_dy?,accessibility?,before_frame_id?,after_frame_id?}`. Never capture typed text/passwords by default; key values should be named controls or redacted.
Frame: `{id,timestamp_ms,filename,width,height,sha256}`. File `filename` must be safe relative basename, never path traversal.
Network: `{id,timestamp_ms,method,url,status?,request_headers?,response_headers?,request_body?,response_body?}`. Sanitize auth headers, query secrets, bodies before upload.

Graph v1: `{schema_version:1,nodes:[{id,type,label,evidence_ids:[]}],edges:[{id,source,target,label,evidence_ids:[],association:"observed"|"candidate"}],network_status:"observed"|"none_observed"|"not_captured",ambiguities:[]}`. Validate evidence references and node references before publishing. Human corrections are separate records and survive agent reruns. Proposed modernization suggestions must never be labeled observed.

## Local operation and export

Run the API on `127.0.0.1:8000`, the Next.js UI on localhost, and SpacetimeDB on loopback. The dashboard uses the default local developer login (`dev@localhost`). Native one-click connection creates the same account's Local workspace. Hosted deployment and Google sign-in are outside the current product flow; legacy pairing endpoints remain server compatibility only.

Capture stays on this Mac until explicit review and Upload & Analyze. The configured Nemotron inference service receives the sanitized evidence used by analysis; localhost does not mean inference is offline. Export validated graph JSON for the editable FigJam plugin and download the applicable network graph. No network capture means `not_captured`, not an assertion that the application made no requests.

Use SpacetimeDB for sessions, job state, graph records and human corrections. All private project data stays in private tables and authorized views. The landing page renders without the API; the dashboard displays connection errors instead of silently switching to sample data.

## Model access and budget

NVIDIA access needs actual endpoint validation; sponsor-issued keys may require a sponsor/Brev gateway instead of integrate.api.nvidia.com. Configure endpoint and model identifiers via environment. Never hardcode or print secrets. Spending ceiling: $60 total; require bounded concurrency, calls, retries, token and frame budgets. Do not claim reliable dollar enforcement unless endpoint usage/prices are available. Default automated verification uses mocks; live calls require a valid configured endpoint and a bounded smoke test.

## Recorder v1 additive fields

The native manifest additionally carries `network_status` (`observed`, `none_observed`, or `not_captured`), `interactions[].delayed_frame_id` for settled results, and optional `redaction.omitted_frames`, `omitted_interactions`, and `window_titles_removed`. These are accepted v1 fields, not reasons to reject the manifest. No running network helper must produce `not_captured`.

Interaction kinds: `click`, `double_click`, `right_click`, `other_click`, `scroll`, `key`, `text_input`, `focus_lost`, `focus_regained`. Accessibility fields: `role`, `subrole`, `title`, `label`, `identifier`, `window_title`, `secure`. `text_input` uses `key: "redacted"`; it never includes typed characters. The multipart `manifest` is a plain form field; each frame is a repeated `files` part whose filename matches the manifest's safe basename.

Session creation must be safely idempotent for a repeated identical session ID and payload; a conflicting payload must fail. Repeated analyze requests while a job is active must return the active job, not start duplicate paid work.
