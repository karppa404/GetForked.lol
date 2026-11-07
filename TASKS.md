# Retrace milestones

- [ ] Website: landing page, responsive workflow illustration, demo slots, blank dashboard route; production deployment.
- [ ] macOS: menu bar app picker, scoped capture, passive foreground-filtered interactions, before/after evidence, permission handling, local session review.
- [ ] macOS/API: room pairing, Keychain device credential, explicit redacted evidence upload.
- [ ] API: authenticated pairing, private ingestion, schema validation and job execution.
- [ ] Nemotron: validate sponsor endpoint and models; bounded workflow/network/reconciliation/publisher calls.
- [ ] Shared state: SpacetimeDB subscriptions, incremental job results, preserved human corrections.
- [ ] Dashboard: sessions, workflow/API graphs, evidence inspection, synchronized edits.
- [ ] FigJam: validated downloadable graph JSON and a plugin importing editable shapes/connectors.
- [ ] End-to-end verification: capture a real task, review/upload, analyze, inspect/export; verify two-window synchronization.

Commit working milestones on each branch. Do not commit credentials, recordings, private screenshots or generated build outputs.

## Verified milestones

- Landing page baseline: committed on `feat/retrace-website`; Next.js production build and TypeScript check pass. Deployed at https://retrace-hackutd-2026.vercel.app; unauthenticated HTTP check returns 200.
- Native recorder baseline: `t3/implement-macos-retrace`, merged into `integration/retrace-v1`. Core tests pass; parent integration adds lifecycle/cancellation regression coverage (37 tests total).
- Parent integration review: every scroll event is hit-tested; canceled/stale screenshot completions cannot attach to a different/finalized session; canceled pairing cannot retain approval; upload project must match device credential.
- Real screen capture, Accessibility and Keychain use remain unverified until macOS permissions are granted and the user demonstrates a task.
