# Local verification — November 7, 2026

The current product runs on localhost. Source is integrated on main; frontend and recorder/backend implementation branches remain separate.

## Checks

- Swift: 37 tests pass; release app builds, signs ad hoc and verifies; release ZIP validates.
- Backend: 95 tests pass, two optional disposable-SpacetimeDB tests skip without their fixture.
- Web: 42 tests pass, one optional live fixture test skips; TypeScript and production build pass.
- FigJam plugin: four validation tests and build pass; runtime Figma import still needs checking.
- Real Mac: local connection and Keychain save succeeded. Accessibility and Screen Recording grants were exercised. Mail settings were captured through ScreenCaptureKit; the saved frame contained only the Mail window, with blank space outside it. Focus loss paused the recorder and the recording appeared in local review.
- Physical input remains a manual check. Computer Use can invoke accessibility actions without generating the passive hardware input events being monitored. Automated tab changes are not proof of click/keyboard capture.
- Mail evidence was not uploaded or sent to inference. The edited demo uses reviewed Mail settings UI captures and a separate, explicitly labeled synthetic analysis example.

## Live inference

The configured Brev endpoint serves `nvidia/NVIDIA-Nemotron-Nano-9B-v2`, a text-only model. One bounded synthetic fixture job made five calls, reporting 8,530 prompt tokens and 8,667 completion tokens (17,197 total), and published five nodes and four edges. Network analysis was skipped because the fixture had no network capture. Publisher output failed validation; the validated reconciliation graph was retained with an explicit ambiguity. This verifies the bounded integration, not screenshot vision or output quality on real application recordings.

## Production page and video

A fresh incognito load against the local production server recorded 28 ms TTFB, 87 ms DOM ready and 129 ms load. These are loopback measurements, not representative internet/mobile benchmarks. Resource timing reported 139,176 encoded JavaScript bytes and 3,842 CSS bytes, zero external requests, zero dashboard-prefetch requests, and zero MP4 requests or video elements before Play.

The 22-second, 1280×720 H.264/yuv420p silent edit is 738,097 bytes. Its WebP poster is 31,254 bytes. FFmpeg/ffprobe verified the codec, dimensions, duration and fast-start metadata placement. The production player reached readyState 4 and advanced past 13 seconds without errors, with one caption track. At a 430 px viewport the page had no horizontal overflow and the video retained its aspect ratio.

The landing and dashboard use system fonts. React Flow and its stylesheet load only for a graph canvas. Landing workspace links do not prefetch the dashboard. The video element mounts only after Play.
