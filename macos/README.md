# Retrace for macOS

Menu bar recorder that observes **one** target app while you demonstrate a task, keeps the
evidence on this Mac, lets you review and omit anything sensitive, and uploads only when
you press **Upload & Analyze**.

- SwiftPM package, Swift 6.2 toolchain, deployment target **macOS 14+**.
- `RetraceCore`: pure logic (manifest v1, timestamps, key naming, validation, review and
  redaction, local store, Keychain credential, pairing, multipart upload). No permissions needed.
- `Retrace`: SwiftUI `MenuBarExtra` app (AppKit, ScreenCaptureKit, Accessibility).
- `retrace-cli`: headless validator for session folders.

## Build, test, run

Full Xcode is not required. Everything works with the Command Line Tools.

```sh
cd macos
swift build                      # debug build of all targets
scripts/test.sh                  # swift-testing suite (handles CLT-only setups)
scripts/build-app.sh             # dist/Retrace.app (release, ad hoc signed)
scripts/run.sh                   # build + open
scripts/install.sh               # build + copy to ~/Applications
swift run retrace-cli validate Tests/RetraceCoreTests/Fixtures/synthetic-session
swift run retrace-cli list       # local sessions on this Mac
```

`scripts/test.sh` adds the CLT `Testing.framework` search path and disables the Foundation
cross-import overlay, which the CLT doesn't ship. Tests use mocked HTTP and a synthetic
fixture. They never touch permissions, the Keychain, the network or the screen.

Set `RETRACE_SIGN_IDENTITY="Developer ID Application: …"` to sign with a real identity. With
the default ad hoc signature, macOS treats each rebuild as a new app, so the Accessibility and
Screen Recording grants (and Keychain access) must be approved again.

## Using it

1. Click the **!** in the menu bar. Choose a running app; Retrace never lists itself.
2. Enter the task you will demonstrate. Grant **Accessibility** and **Screen Recording**
   with the Request/Settings buttons. Nothing is requested until you press them.
3. Press **Start Recording**. Retrace brings the app forward. Perform the task.
4. Press **Stop & Review**. The Sessions window opens with thumbnails and an event list.
5. Omit frames or events. Optionally strip window titles or element titles/labels.
   Then tick the confirmation box.
6. Pair once (**Pair…**), then press **Upload & Analyze**.

## Exact capture scope

| What | Captured | Notes |
|---|---|---|
| Target | One running Dock app (by PID) per session | Retrace itself is excluded |
| When | Only while the target is frontmost | Other app frontmost, screen lock, sleep or user switch pauses capture and logs `focus_lost`/`focus_regained` |
| Clicks | left/double/right/other with display-relative point coordinates | Kept only if the AX element (or topmost window) under the pointer belongs to the target PID |
| Scroll | One event per gesture, summed `scroll_dx/dy` | Same pointer ownership check |
| Keys | Named keys only: `return`, `enter`, `tab`, `escape`, `delete`, `forward_delete`, arrows, `home/end/page_up/page_down`, `f1`–`f12`, plus cmd/ctrl shortcuts such as `cmd+s`, `shift+cmd+z` | Kept only if Accessibility's focused app is the target |
| Typing | One `text_input` event per burst, `key: "redacted"` | Characters are never recorded (key codes are classified without reading characters) |
| Accessibility | role, subrole, title, description/placeholder, identifier, window title | `AXValue` (field contents) is never read. Secure fields keep role only |
| Frames | ScreenCaptureKit stills of **only the target app's windows** on one display, JPEG at point resolution | before (latest in-memory frame ≤3 s old), after (+0.35 s), settled (+1.5 s). Unused in-memory frames are never written. Max 300 frames (matching the API upload limit) |
| Network | **Not captured** | No helper ships in v1. Manifest says `network_status: "not_captured"`, `network: []` |

Not captured: audio, other apps, desktop, notifications, other displays. If the target moves
a window to another display mid-session, those frames show nothing from that window.
Opening the Retrace menu or any other app's window pauses capture.

### Permissions you must still grant at runtime

- **Accessibility** (System Settings › Privacy & Security › Accessibility): global
  mouse/key monitor and element queries. Some macOS versions also list Retrace under
  **Input Monitoring**. Allow it there if key events don't appear.
- **Screen Recording** (Privacy & Security › Screen & System Audio Recording):
  ScreenCaptureKit frames. macOS may require reopening Retrace after granting, and may
  periodically ask you to re-confirm.
- **Keychain**: macOS may ask to allow Retrace access to its stored device credential,
  especially after a rebuild.

### Timestamps and IDs

`started_at` is ISO 8601 UTC with milliseconds. Every `timestamp_ms` is measured from session
start on the monotonic uptime clock (the same base as `NSEvent.timestamp`), so wall-clock changes
can't reorder evidence. All evidence IDs are lowercase UUIDs. Frame files are named
`<frame-id>.jpg` and the manifest stores only that basename plus its SHA-256. The validator
(`ManifestValidator`) checks UUIDs, ordering, ranges, safe filenames, frame references and
before/after ordering, the key allow-list and secure-field stripping.

## Local storage and the privacy boundary

Sessions live in `~/Library/Application Support/Retrace/Sessions/<id>/` (`manifest.json`,
`review.json`, `upload.json`, `frames/`), with directories `0700`, files `0600`, excluded from
backups. The raw manifest always has `redaction.reviewed: false`.

**Review is the redaction step. Retrace does not detect sensitive content.** Upload builds a
new manifest from your review: omitted frames are removed and references to them cleared,
omitted events are removed, and title stripping is applied. It sets `redaction.reviewed: true`
(with omission counts) only after you tick the confirmation. Changing any omission clears it.
Only the kept frames' files are attached, and each is re-hashed against the manifest first.

## Room pairing and API (docs/INTEGRATION.md v1)

- API base URL is configurable in **Pair…** (default `http://127.0.0.1:8000`). Plain `http`
  is rejected for non-loopback hosts so the device token never crosses a network unencrypted.
- `POST /v1/pairings/claim {code, device_name}` → `{claim_id, claim_secret, status}`. This is
  never retried automatically, because the code is single use.
- `POST /v1/pairings/claims/{claim_id}/poll {claim_secret}` every 2 s until `approved`
  (`device_token`, `project_id`). The wait is bounded: 10 min max. 404/410 or `expired`
  count as expired, 401/403 or `rejected` as declined. Transient errors back off and give up
  after 5 in a row. The claim secret is held only in memory.
- The device token and project ID are stored in the Keychain (generic password, service
  `dev.retrace.recorder.device-credential`, account = API base URL,
  `WhenUnlockedThisDeviceOnly`), so they are bound to the server that issued them.
- `POST /v1/sessions` (Bearer device token, multipart: `manifest` JSON string field and one
  `files` part per kept frame) → `{id, status}`. `POST /v1/sessions/{id}/analyze` → `{job_id, status}`.
  Both run only on the Upload & Analyze click. 429/5xx/transport errors are retried up to 3
  times with backoff. Other 4xx errors are reported without a retry.

### Additive manifest fields (beyond the v1 contract)

- `network_status` (`"not_captured"` from this recorder), so an empty `network` array is never
  read as "no activity".
- `interactions[].delayed_frame_id`: the settled frame (~1.5 s after the action).
- `redaction.omitted_frames`, `redaction.omitted_interactions`, `redaction.window_titles_removed`.
- Interaction `kind` values: `click`, `double_click`, `right_click`, `other_click`, `scroll`,
  `key`, `text_input`, `focus_lost`, `focus_regained`. `accessibility` is
  `{role, subrole, title, label, identifier, window_title, secure}` (all optional).

A server that rejects unknown fields needs to accept these.

## Verification status

Automated: `swift build`, `scripts/test.sh` (manifest/fixture validation, timestamps, key
naming, review and redaction, store hashing and permissions, capture policy, base URL rules,
pairing state machine, upload multipart and retry bounds), plus `retrace-cli validate` on the fixture.
The real capture path (event monitor, Accessibility, ScreenCaptureKit) and real Keychain
access need the runtime permissions above and a manual run. They are not covered by
automated tests.
