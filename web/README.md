# Retrace web

The local Retrace workspace: a landing page at `/` and the workspace at `/dashboard`. Next.js App Router, React, TypeScript. **Localhost only**: there is no hosted site, sign-in screen or room code.

## Run it locally

You need the Retrace API on this Mac (see `docs/LOCAL_DEMO.md` for SpacetimeDB and model options). Node 22.23.4+, 24.22.1+ or 26.12.1+.

```sh
# 1. API (loopback, development login enabled)
cd backend
RETRACE_DEV_AUTH=1 uv run python -m retrace        # http://127.0.0.1:8000

# 2. Web
cd web
npm ci
npm run dev -- --hostname 127.0.0.1                # http://127.0.0.1:3000
```

Open http://127.0.0.1:3000 and choose **Open workspace**, or go straight to http://127.0.0.1:3000/dashboard.

In the Retrace menu bar app, choose **Connect to this Mac**. It joins the shared **Local workspace** project under the same local developer account. Select the app to observe and work in it as usual. When you stop, review the captured evidence. Nothing is uploaded or analyzed until you choose to.

```sh
npm test            # vitest: HTTP client, local login, sample data, graph validation, dashboard flows (jsdom)
npm run typecheck
npm run build
```

## Landing page and demo video

`/` is made of static server components. Its only client code is the demo player. The player shows `public/demo/poster.webp` and mounts `public/demo/retrace-demo.mp4` (`controls`, `playsInline`, `preload="none"`) only after you press **Play demo**, so the page downloads no video until then. If either file is missing at build time, the section says so instead of showing a broken player. Fonts are system fonts, and nothing loads from a remote host. React Flow loads only when a graph canvas renders.

## How the workspace connects

- The page and the API must both be on loopback (`localhost`, `127.0.0.1`, `::1`). Anything else shows "Retrace runs on this Mac only". `NEXT_PUBLIC_API_BASE_URL` may only point to another loopback port.
- On load the workspace calls `POST /v1/auth/dev`, which the API accepts only from loopback with `RETRACE_DEV_AUTH=1`. The token stays in memory and is sent as `Authorization: Bearer` with `credentials: "omit"`. Nothing is written to storage.
- If the API is stopped or rejects the login, you get a connection error that shows the start command and a **Try again** button. A 401 later (for example after an API restart) returns to that screen.
- The default project is the one named **Local workspace**, otherwise the first project. Other projects appear in the sidebar, and you can create more there.

### Sample data (optional, explicit)

On the connection error screen, **View sample data** opens fictional recordings for exploring the interface. A banner stays visible the whole time. Edits persist in `localStorage` under `retrace.preview-workspace.v1`, which carries a `demo` marker. The workspace never switches to sample data on its own.

## Workspace

Hash routes (`#/`, `#/projects/:id`, `#/projects/:id/sessions/:id`) support deep links and the back button.

- **Project**: a table of recordings showing app, start time, length, analysis status and network capture state.
- **Recording**: evidence timeline (actions, screenshots, requests, with filters) · **Workflow** and **API & network** graphs (React Flow canvas, or a keyboard-friendly outline) · inspector with supporting evidence, before/after screenshots, connections, open questions, and observed vs. candidate status · label corrections with "Restore agent label" · run and re-run analysis with stage progress · **Download graph JSON** (validated Graph v1 for the FigJam plugin) · FigJam board link.
- Network states are distinct: *Network observed*, *No requests observed* (capture was on but nothing happened), and *Network not captured*.

### Live updates

The workspace reads `GET /v1/realtime`. When SpacetimeDB is ready it subscribes to the private `my_*` views, and any change re-fetches the affected API snapshot. All writes still go through the API. If subscriptions are unavailable, the workspace polls instead. Running jobs poll every 2.5 s, completed recordings every 5 s, each capped at 144 polls while the tab is visible, and you can resume polling by hand. Requests time out after 15 s and are never retried automatically.

### API usage

`POST /v1/auth/dev`, `GET/POST /v1/projects`, `GET /v1/projects/{id}/sessions`, `GET /v1/sessions/{id}`, `POST /v1/sessions/{id}/analyze`, `PUT|DELETE /v1/sessions/{id}/corrections/{element_id}`, `GET /v1/sessions/{id}/graph`, `PUT /v1/sessions/{id}/board` (a 404, 405 or 501 response is reported as unsupported), `GET /v1/realtime`, `POST|DELETE /v1/projects/{id}/realtime-viewers`. Responses are normalized defensively in `lib/dashboard/backend.ts`.

## Rebuild the edited demo

`web/public/demo/retrace-demo.mp4` is a silent 22-second H.264 edit with fast-start metadata, a WebP poster, and English captions. It combines reviewed native UI captures, an actual app-scoped Mail settings frame, and a clearly labeled separate synthetic fixture analyzed by Nemotron. Mail evidence was not sent to inference. The original UI captures remain in the ignored `release/demo-source/` directory.

To reproduce on macOS with FFmpeg installed: `uv run --with pillow python scripts/edit-demo.py release/demo-source` from the repository root. The renderer checks codec, size and duration with ffprobe. Rebuild Next.js after replacing the assets.
