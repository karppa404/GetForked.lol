Retrace v0.1.0-alpha.4 is a localhost developer prerelease for Apple Silicon Macs running macOS 14 or later.

## What changed

- Original imagegen Retrace logo, Finder/Dock app icon, adaptive menu-bar mark, and matching web/favicons. [Masters and exact prompts](https://github.com/karppa404/HackUTD-2026/blob/main/assets/brand/README.md) are included in source.

- Observe activity in a selected application without typing a task or reason.
- Connect the recorder to Local workspace with one click. No room code or sign-in wall.
- Local-only workspace and API; old saved hosted URLs migrate to localhost.
- Redesigned landing page and three-panel evidence workspace, with a captioned 22-second FFmpeg demo.
- Readable vertical workflow graphs, visible edges and graph code loaded on demand.
- Initial and bounded periodic foreground screenshots also retain output evidence without input events. Capture errors are visible.

## Use

Start SpacetimeDB, the API and the site using [the local guide](https://github.com/karppa404/HackUTD-2026/blob/main/docs/LOCAL_DEMO.md). Open http://localhost:3000/dashboard. In Retrace choose Connection → Connect to Local workspace, select an application, and start observing. Stop, review and omit sensitive evidence, then explicitly choose Upload & Analyze.

Unzip Retrace-macOS-arm64.zip and move Retrace.app into Applications. The app is ad hoc signed and not notarized. macOS may require first-launch approval and renewed Accessibility/Screen Recording grants after updates.

Retrace-FigJam-plugin.zip imports validated graph JSON as editable shapes and connectors. Register it as a development plugin and replace the placeholder manifest ID. Saving a FigJam board URL in the session makes it easy to return to the board later.

## Verified

- 37 Swift tests, app compilation and signature verification.
- 95 backend tests pass; two disposable-SpacetimeDB tests skip without their fixture.
- 42 web tests pass, one optional live-subscription test skipped; TypeScript and production build pass.
- Four FigJam validator tests and importer build pass.
- Actual one-click local connection, Keychain save, permission handling, foreground pause, app-scoped Mail screenshot and local review ran on a Mac.
- A bounded live Brev/Nemotron synthetic run completed in five calls (17,197 reported tokens): five nodes and four edges. Publisher output was rejected; the validated reconciliation graph was retained with an explicit ambiguity.

## Limits

The supplied endpoint serves NVIDIA-Nemotron-Nano-9B-v2, a text-only model. It does not interpret screenshot pixels. The Mail capture was kept local; the video's analysis segment uses a separate, clearly labeled synthetic fixture.

Computer Use automation can bypass passive macOS input monitors. Physical mouse/keyboard capture still needs a manual check; the automated Mail walkthrough established screen capture and foreground filtering, not complete physical-input coverage.

The recorder is capped at 300 frames per session and continues interactions after that limit. It observes one selected app while frontmost, rather than the entire Mac. Network evidence requires the separate mitmproxy helper; the native recorder reports Network not captured. The helper runtime and Figma runtime import remain unverified.

Configured remote inference receives sanitized evidence after explicit upload/analysis; localhost is not an offline inference promise. No hosted API, site deployment or Google account configuration is required for this release. Token/call limits are enforced; dollar enforcement requires configured provider prices and cannot stop an hourly GPU instance.
