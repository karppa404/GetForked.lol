# Retrace

Understand an existing app before you rebuild it. A native macOS recorder observes a demonstrated task, then a shared workspace turns the evidence into workflows and API dependency graphs.

**[Website](https://retrace-hackutd-2026.vercel.app) · [Preview dashboard](https://retrace-hackutd-2026.vercel.app/dashboard) · [Downloads](https://github.com/karppa404/HackUTD-2026/releases) · [Local setup](docs/LOCAL_DEMO.md)**

## Try the developer build

Download `Retrace-macOS-arm64.zip` from Releases, unzip it and move Retrace.app into Applications. The build targets Apple Silicon and macOS 14+. It is ad hoc signed and not notarized; macOS may require first-launch approval in Privacy & Security.

For a connected recording session, start the local dashboard, FastAPI service and SpacetimeDB using the [local demo guide](docs/LOCAL_DEMO.md). Create an app project, generate a room code, connect the recorder, and approve it in the dashboard. Select an app and demonstrate a task yourself. Stop, review and omit sensitive evidence, then explicitly upload.

The public dashboard currently opens a clearly labeled sample workspace. Google login and hosted analysis services are not configured. Live Nemotron analysis needs working inference credentials; the supplied Brev endpoint currently returns 401. The local development provider is explicitly labeled and makes no model calls.

## Source

- [web/](web/): Next.js landing page and React Flow review workspace, with authorized SpacetimeDB subscriptions.
- [macos/](macos/): Swift menu bar recorder, local privacy review, Keychain pairing and explicit upload.
- [backend/](backend/): FastAPI/Pydantic, authenticated pairing, evidence ingestion and bounded four-stage analysis.
- [spacetimedb/](spacetimedb/): private shared state, per-viewer views, incremental jobs and preserved human corrections.
- [figjam-plugin/](figjam-plugin/): graph JSON importer creating editable FigJam shapes/connectors.
- [network-helper/](network-helper/): optional local mitmproxy capture and sanitized evidence export.

Website work is maintained on `feat/retrace-website`; native recorder work on `t3/implement-macos-retrace`; `integration/retrace-v1` combines the product. Release tags point to the integrated source on `main`.

Recordings stay local until explicit upload. Agents analyze evidence; they never operate the recorded application. Actual macOS permission/capture behavior and Figma runtime import still require manual verification; passing compilation and synthetic tests do not establish those behaviors.
