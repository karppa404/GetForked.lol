# Ubuntu manual evidence capture (X11)

This is an initial GTK application and manual capture tool, not feature parity with the macOS recorder. It captures the selected X11 window after each action you describe. It does not observe clicks or keyboard input or record network traffic. The GTK application also supports explicit local workspace connection and reviewed upload. Descriptions are stored as interaction titles; they may contain sensitive information. The CLI is X11-only; see the GNOME/Wayland section below for portal capture in the GTK app.

Install Python 3, ImageMagick (`import`), and `x11-utils` (`xwininfo`). Log in to an X11 session. Run `xwininfo` and click the target window to find its ID, then:

```sh
python3 ubuntu/record.py --window 0x123456 --app 'Example' --app-id example.app --pid 1234 --output ./session
```

Perform each action in the target app, return to the terminal, and enter a description. Submit an empty description to finish. Review every screenshot and description before sharing. The generated manifest marks network as `not_captured` and review as incomplete. Window contents may include private data; obscured windows or protected content may not capture correctly.

## GTK application

Install `python3-gi`, `gir1.2-gtk-3.0`, ImageMagick and `x11-utils`, then run `/usr/bin/python3 ubuntu/app.py`. Use `xwininfo` to find the window ID and `ps` to find its PID. Start a session, perform each action, then use Capture action. Select each row to preview its screenshot; Remove selected deletes that screenshot and its action. Save session writes the manifest. Closing an active session hides the window; reopen it and save to finish. The output is an evidence collection, not an upload-ready reviewed session.

The GTK app does not implement automatic input observation, continuous screencast streams, network correlation. X11 window capture and the GUI require manual verification in a graphical Ubuntu session.

## GNOME top bar

GNOME Shell requires an extension to add a button to its top bar. For GNOME Shell 45–49, run `ubuntu/install-extension.sh`, log out and back in, then run `gnome-extensions enable retrace@local` (or enable Retrace in the Extensions app). The camera icon launches the GTK recorder. Re-run the installer after updating the app. Disable with `gnome-extensions disable retrace@local`. The button provides recorder status and manual capture controls (see below). GNOME Shell extension loading and the top bar have not been tested in a graphical session.

## GNOME/Wayland manual capture and controls

The GTK recorder now offers **GNOME desktop portal** capture on Wayland and X11.
Install `xdg-desktop-portal` and the GNOME portal backend (`xdg-desktop-portal-gnome`),
alongside the GTK dependencies above. Start `/usr/bin/python3 ubuntu/app.py`, choose
that backend, and enter application metadata and a new session directory. The X11
window ID is required only for the X11 backend. Application metadata is descriptive;
the portal does not enforce the entered app or PID as the capture boundary.

Each **Capture action…** first asks for a description, then opens the system's
interactive screenshot dialog. Select only the intended evidence. Portal screenshots
can include the desktop, notifications, or other applications: this is **not** macOS's
app-only capture policy. Cancel or deny the portal prompt to add no evidence. Retrace
accepts only local PNG files, copies them with mode 0600 into the private session
folder, and leaves portal-owned originals alone (the desktop may retain those).
No screenshots, input monitoring, or permission requests run on launch.

Reinstall the extension after updating. Its menu now shows Idle, Ready, Paused, or
Capturing and provides **Capture action…**, **Pause / Resume**, and **Stop & Save
locally**. Controls use the recorder's single-instance session D-Bus application;
status includes no app names, descriptions, screenshots, or paths. Closing an active
window hides it so evidence is not lost; reopen it from the top bar and save to finish.
Pausing blocks manual captures. Stop saves locally and does not mark review complete.

This advances capture and controls toward parity, but automatic click/scroll/key
observation, enforced Wayland app-only screenshots, lock/focus observation, before/after
frame timing, and automatic sensitive-content redaction remain
unimplemented. There is no network capture or automatic upload. The older X11 CLI
remains X11-only. Live portal consent/cancellation, GNOME Shell 45–49 extension loading,
and UI behavior require validation on a graphical Ubuntu GNOME session.

Run headless backend tests with `python3 -m unittest discover -s ubuntu/tests -v`.
For GTK control tests, use `/usr/bin/python3 -m unittest discover -s ubuntu/tests -v`
with `python3-gi` and GTK 3 installed. Tests never capture the screen or use the network.


## Local workspace connection and reviewed upload

Install `libsecret-tools` and run an unlocked desktop Secret Service (for example,
GNOME Keyring). Start the backend at `http://127.0.0.1:8000`. In GTK, choose
**Connect workspace**. The device token stays in Secret Service; failure to store it
blocks connection, with no plaintext fallback. Only loopback API URLs are accepted;
proxies and HTTP redirects are disabled, and credentials remain bound to the URL
that issued them.

Save a recording or use **Open saved session** to reopen an Ubuntu manual evidence
folder. Select every row to inspect the screenshot and description. **Remove selected**
deletes the action and screenshot locally and persists the change for saved sessions.
No sensitive content is detected automatically. The review UI supports Ubuntu manual
sessions only; recordings containing other event metadata must use their original
recorder for review.

**Upload & Analyze** requires an explicit sharing confirmation each time. It attaches
only remaining manifest frames, verifies their PNG signatures and SHA-256 hashes,
marks the outgoing copy reviewed, binds it to the connected project, uploads it,
then requests backend analysis. Analysis may send evidence to the backend's configured
external model provider. Network calls run outside the GTK main thread. Uploaded
content is locked by an owner-only atomic `upload.json` receipt. If analysis fails,
pressing Upload & Analyze again retries analysis without resending a completed upload.
An ambiguous upload failure can be retried using the backend's identical-payload
idempotency contract. There is no automatic background retry or job-status polling.

The Ubuntu client currently caps individual frames at 20 MiB and upload bodies at
100 MiB. Graphical GTK behavior, live Secret Service prompts, and a running backend
still require an end-to-end Ubuntu desktop check; automated integration tests use
fake transports and never transmit screenshots.

## ChatGPT subscription analysis

Install the official Codex CLI and use **Sign in with ChatGPT** to open its browser
login flow in a terminal. Retrace never reads or copies Codex credentials. Save a
session, review its screenshots and descriptions on disk, then check the explicit
OpenAI sharing consent and press **Generate user stories & spec with Codex**.
The resulting `user-stories-and-spec.md` is stored privately alongside the manifest.
Only listed screenshots and interaction metadata are staged; unrelated files are
excluded. Analysis is limited to 12 frames, 20 MB per frame, and a 240-second timeout.
Existing reports are not overwritten. Analysis uses subscription-backed Codex with
API-key logins rejected, user config excluded, and a read-only sandbox. Subscription
limits and workspace policies still apply. This local analysis login does not sign
users into the Retrace web dashboard or confer access to every Retrace feature.

Official documentation: https://learn.chatgpt.com/docs/auth.md and
https://learn.chatgpt.com/docs/non-interactive-mode .
