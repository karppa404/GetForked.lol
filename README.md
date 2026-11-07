# Retrace

Understand an existing app before you rebuild it. A native macOS recorder observes activity in a selected app while you work. A local workspace turns reviewed evidence into workflows and applicable API dependency graphs.

**[Local setup](docs/LOCAL_DEMO.md) · [Downloads](https://github.com/karppa404/HackUTD-2026/releases)**

Current product: localhost only. Start the site at http://localhost:3000 and open http://localhost:3000/dashboard for the workspace. Older hosted previews are not the current application.

## Try the developer build

Download `Retrace-macOS-arm64.zip` from Releases, unzip it and move Retrace.app into Applications. The build targets Apple Silicon and macOS 14+. It is ad hoc signed and not notarized; macOS may require first-launch approval in Privacy & Security.

For a connected recording session, start the local dashboard, FastAPI service and SpacetimeDB using the [local demo guide](docs/LOCAL_DEMO.md). Choose Connection → Connect to Local workspace in the recorder. Select an app, start observing, and work normally; no task or reason is required. Stop, review and omit sensitive evidence, then explicitly upload.

The dashboard signs in locally without a room code or account setup. The supplied Brev endpoint has authenticated successfully and serves `nvidia/NVIDIA-Nemotron-Nano-9B-v2` (text only); screenshot vision still needs a compatible vision endpoint. The local development provider is explicitly labeled and makes no model calls.

## Source

- [web/](web/): Next.js landing page and React Flow review workspace, with authorized SpacetimeDB subscriptions.
- [macos/](macos/): Swift menu bar recorder, local privacy review, Keychain local connection and explicit upload.
- [backend/](backend/): FastAPI/Pydantic, loopback connection, evidence ingestion and bounded four-stage analysis.
- [spacetimedb/](spacetimedb/): private shared state, per-viewer views, incremental jobs and preserved human corrections.
- [figjam-plugin/](figjam-plugin/): graph JSON importer creating editable FigJam shapes/connectors.
- [network-helper/](network-helper/): optional local mitmproxy capture and sanitized evidence export.

Current frontend changes: `t3/retrace-local-workspace-ui`. Current recorder/backend changes: `t3/localhost-observation`. Integrated code and subsequent fixes are on `main`. Older download tags predate this localhost redesign; build from source for the latest version.

Recordings stay local until explicit upload. Agents analyze evidence; they never operate the recorded application. Actual macOS permission/capture behavior and Figma runtime import still require manual verification; passing compilation and synthetic tests do not establish those behaviors.
