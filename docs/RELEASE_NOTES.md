Retrace v0.1.0-alpha.1 is a developer prerelease for Apple Silicon Macs running macOS 14 or later.

## Downloads

- **Retrace-macOS-arm64.zip**: native menu bar recorder. Unzip and drag Retrace.app to Applications. It uses an ad hoc signature and is not notarized; macOS may require approval in System Settings → Privacy & Security before the first launch.
- **Retrace-FigJam-plugin.zip**: developer importer for editable FigJam shapes and connectors. Register a development plugin in Figma and replace the manifest's placeholder ID before loading it. Runtime import in Figma has not yet been verified.
- **Source code**: Next.js workspace, FastAPI worker, SpacetimeDB module, macOS recorder and mitmproxy helper.

## Using the connected app

Start the local API, SpacetimeDB and dashboard using [the local demo guide](https://github.com/karppa404/HackUTD-2026/blob/main/docs/LOCAL_DEMO.md). Create a project, generate a room code, enter it in the recorder, then approve the Mac in the dashboard. Grant Accessibility and Screen Recording permissions through the recorder. Demonstrate a task yourself, stop, review and omit sensitive evidence, and explicitly choose Upload & Analyze.

The public [website and preview dashboard](https://retrace-hackutd-2026.vercel.app/dashboard) use clearly labeled sample data until production auth/backend configuration is supplied. This release does not bundle a hosted analysis service.

## Verified

Native compilation, 37 Swift tests and app signature verification; 37 web tests plus a live two-viewer SpacetimeDB synchronization check; backend tests against real local SpacetimeDB; graph compatibility and four importer tests. Synthetic native evidence passes pairing, upload, four-stage deterministic development analysis, human corrections across reruns, and graph export.

## Remaining integration checks

- Real screen capture, Accessibility and Keychain behavior need permission checks on your Mac. Build/unit tests do not prove real recording works.
- The supplied Brev inference URL currently returns HTTP 401 with the supplied credential. Live Nemotron analysis is pending working authentication and model availability validation. Offline development analysis is explicitly labeled, and no live inference credits have been spent.
- Google OAuth and the hosted API/SpacetimeDB/private object storage are not configured. Local capture remains on the Mac until explicit upload; the current local API stores uploaded artifacts in private server-side files.
- Network capture is a separate optional mitmproxy helper. The recorder alone reports network as not captured.
