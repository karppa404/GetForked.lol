# Retrace web

Next.js App Router, React, TypeScript. Node 22.23.4+, 24.22.1+, or 26.12.1+ is recommended by the SpacetimeDB SDK.

```sh
cd web
npm ci
npm run dev
npm run build
npm run typecheck
npm test          # vitest: HTTP client, preview storage, graph validation, dashboard flows (jsdom)
```

The landing page is at `/`. The workflow graphic on it is illustrative and the demo cards are placeholders for future videos. The landing page collects no recording evidence or personal information.

## Dashboard (`/dashboard`)

A client-rendered app with hash routes (`#/`, `#/projects/:id`, `#/projects/:id/sessions/:id`), so it deploys as a static page and supports deep links and the back button.

- **Projects**: list, create.
- **Project**: sessions with analysis status and network capture state, plus **Connect a recorder**: generate a single-use room code, see the expiry countdown, wait for a claim, then review and explicitly approve the device by name.
- **Session**: evidence timeline (interactions, screenshots, requests, filterable); **Workflow** and **API & network** graph tabs (React Flow canvas, or an accessible keyboard-friendly outline); inspector showing a selected element's supporting evidence, before/after screenshots, connections, open questions and observed vs. candidate status; inline label correction (double-click a canvas node, or Rename in the outline/inspector) with "Restore agent label"; analysis run/re-run with stage-by-stage progress; **Download graph JSON** (validated Graph v1 for the future FigJam plugin); FigJam board link.
- Network states are distinct: *Network observed*, *No requests observed* (capture was on, nothing happened), and *Network not captured* (capture was off). API graphs appear only when network was observed.

### Configuration

Copy `.env.example` to `.env.local`. Both values are public and inlined at build time — never put secrets in them.

| Variable | Effect |
| --- | --- |
| `NEXT_PUBLIC_API_BASE_URL` | Retrace API. Unset: pages on `localhost` use `http://127.0.0.1:8000`; any other host has no backend. |
| `NEXT_PUBLIC_GOOGLE_CLIENT_ID` | Enables Google Identity Services sign-in → `POST /v1/auth/google {credential}`. Pending configuration. |

Developer sign-in (`POST /v1/auth/dev`) is offered only when both the page and the API are on loopback. Both sign-in endpoints return `{access_token, user}`. The token is held in memory and mirrored to `sessionStorage` (per API base URL, gone when the tab closes); it is sent as `Authorization: Bearer` with `credentials: "omit"`. A 401 clears it and returns to sign-in.

### Modes

- **Backend mode** — after a real sign-in. All data comes from the API. Errors are shown with Retry; the app never falls back to sample data on its own (a clearly labeled "Open the preview workspace instead" button is offered). No pairing approval is ever generated.
- **Preview workspace** — opened automatically when no sign-in method is available (e.g. the public deployment today), or explicitly from the sign-in screen. A persistent banner says it is sample data and that nothing was recorded or analyzed. Deterministic fictional projects/sessions/evidence/graphs (`lib/dashboard/demo-data.ts`); screenshots are drawn illustrations marked *SAMPLE*. Local edits (projects, label corrections, board links, simulated analysis runs) persist in `localStorage` under `retrace.preview-workspace.v1` with a `demo` marker, and sync between tabs via `storage` events. "Reset sample data" clears them. Pairing claims can only be produced with the explicit *Simulate a recorder claim* button.

### API usage (contract v1 + assumptions)

`GET/POST /v1/projects`, `GET /v1/projects/{id}/sessions`, `GET /v1/sessions/{id}`, `POST /v1/sessions/{id}/analyze`, `PUT /v1/sessions/{id}/corrections/{element_id} {label}`, `GET /v1/sessions/{id}/graph`, `POST /v1/pairings {project_id}`, `GET /v1/pairings/{id}`, `POST /v1/pairings/{id}/approve {claim_id}`.

Responses are normalized defensively (`lib/dashboard/backend.ts`). Assumptions the backend should confirm:

- `GET /v1/sessions/{id}` returns manifest fields (`interactions`, `frames`, `network`) plus `job {id, status, stages:[{name, label?, status, detail?}], error?}`, `graph`, `corrections` (array of `{element_id, label}` or a map), optional `board_url`. Nesting under `analysis`/`manifest` is also accepted.
- Screenshots: frames may carry `image_url` (absolute pre-signed, or API-relative fetched with the bearer token into a blob URL). Without it a placeholder is shown.
- `GET /v1/pairings/{id}` returns `{claims|pending_claims: [{claim_id, device_name, status}], expires_at}`.
- Clearing a correction writes the agent label back via PUT (no DELETE in v1).
- Board links: `PUT /v1/sessions/{id}/board {board_url}` is attempted; 404/405/501 is reported as "this API doesn't store board links yet".
- Graph export is validated client-side before download (schema version, unique ids, edge endpoints, evidence references resolve against the session, no network nodes unless `network_status` is `observed`).

### Real-time updates: bounded polling, not SpacetimeDB (yet)

SpacetimeDB subscriptions are **not** wired in v1 — the backend owns the module and its bindings aren't ready. Instead:

- Session detail polls `GET /v1/sessions/{id}` every 2.5 s while a job is queued/running and the tab is visible, capped at 144 polls (~6 min) per job. Completed backend sessions refresh every 5 s, capped at 144 polls (~12 min), so reviewers see each other's corrections. The user can explicitly resume updates after the budget is exhausted. Errors halt polling and show Retry.
- Pairings poll `GET /v1/pairings/{id}` every 3 s while visible, until approved or expired.
- Every request has a 15 s timeout and is cancelled on navigation/unmount. No automatic retries.
- In backend mode, a correction made in one visible window appears in another within the next review refresh (normally 5 s); direct subscriptions will replace polling when SpacetimeDB integration is ready. In the preview workspace, two windows sync immediately through `storage` events.

## Deployment

Run `vercel --prod` from this directory. Existing Vercel project: `retrace-hackutd-2026`. Without `NEXT_PUBLIC_*` configuration, the deployed dashboard opens the Preview workspace.
