# First integration contract

Product name: Retrace. One Mac, one target application, one demonstrated task.

## HTTP API, version 1

Base URL is configurable on every client. Development: http://127.0.0.1:8000.
All request/response JSON uses snake_case. Evidence timestamps are milliseconds from session start, with session `started_at` an ISO 8601 UTC timestamp. Evidence IDs are UUID strings. Credentials must never be included in evidence or source.

- POST /v1/pairings: authenticated browser creates an expiring, single-use pairing. Response: `{pairing_id, code, expires_at}`.
- POST /v1/pairings/claim: recorder sends `{code, device_name}`. Response: `{claim_id, claim_secret, status:"pending"}`. Code is consumed atomically. Never return a device token from the claim itself.
- POST /v1/pairings/{pairing_id}/approve: authenticated browser approves `{claim_id}` after showing device name.
- POST /v1/pairings/claims/{claim_id}/poll: recorder sends `{claim_secret}`. Pending response `{status:"pending"}`; approved `{status:"approved", device_token, project_id}`. Credential is issued to only the matching claim secret.
- POST /v1/sessions: device bearer auth, multipart `manifest` JSON string and `files` attachments. Manifest has `schema_version:1`, `id`, `project_id`, `app:{name,bundle_id,pid}`, `task`, `started_at`, `duration_ms`, `interactions:[]`, `frames:[]`, `network:[]`, `redaction:{reviewed:true}`. Response `{id,status:"uploaded"}`. Never upload without explicit local user action.
- POST /v1/sessions/{id}/analyze: authorized browser or paired device starts bounded analysis. Response `{job_id,status}`.
- GET /v1/sessions/{id}: authorized browser/device reads metadata and analysis.
- GET /v1/projects: browser's projects.
- POST /v1/projects: `{name}` creates project.
- GET /health: reports readiness without secrets.

Interaction: `{id,timestamp_ms,kind,x?,y?,key?,scroll_dx?,scroll_dy?,accessibility?,before_frame_id?,after_frame_id?}`. Never capture typed text/passwords by default; key values should be named controls or redacted.
Frame: `{id,timestamp_ms,filename,width,height,sha256}`. File `filename` must be safe relative basename, never path traversal.
Network: `{id,timestamp_ms,method,url,status?,request_headers?,response_headers?,request_body?,response_body?}`. Sanitize auth headers, query secrets, bodies before upload.

Graph v1: `{schema_version:1,nodes:[{id,type,label,evidence_ids:[]}],edges:[{id,source,target,label,evidence_ids:[],association:"observed"|"candidate"}],network_status:"observed"|"none_observed"|"not_captured",ambiguities:[]}`. Validate evidence references and node references before publishing. Human corrections are separate records and survive agent reruns. Proposed modernization suggestions must never be labeled observed.

## Auth and deployment

Google login is pending configuration. The public landing site's Sign in is deliberately a link to a blank `/dashboard`. No fake authentication. Any development-only auth backend must bind to loopback by default and reject insecure mode in hosted production. The macOS recorder only talks to the API using a paired device token, stored in Keychain.

Use SpacetimeDB for shared sessions, job state, published graph records and corrections. Never expose private projects in public tables. A public marketing demo table can be used for placeholder/video metadata. The landing page must continue to render if the database is unconfigured or unavailable.

## Model access and budget

NVIDIA access needs actual endpoint validation; sponsor-issued keys may require a sponsor/Brev gateway instead of integrate.api.nvidia.com. Configure endpoint and model identifiers via environment. Never hardcode or print secrets. Spending ceiling: $60 total; require bounded concurrency, calls, retries, token and frame budgets. Do not claim reliable dollar enforcement unless endpoint usage/prices are available. Default automated verification uses mocks; live calls require a valid configured endpoint and a bounded smoke test.
