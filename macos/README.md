# Clone workflow for macOS

Retrace's menu bar panel follows four steps: **Select → Scan → Requirements → Build**.
The current workflow calls the signed-in Codex CLI directly. It does not need the old
Python analysis server or a separate API key.

## Run

```sh
macos/scripts/test.sh
macos/scripts/build-app.sh
open macos/dist/Retrace.app
```

Install prerequisites in Terminal if needed:

```sh
brew install gh
brew install --cask codex
gh auth login
codex login
```

The panel checks both CLI installations and sign-in states, plus the configured local
Codex computer-use MCP. Click **Check Again** after changing setup. Custom executable
paths can be supplied with `RETRACE_GH_BIN` and `RETRACE_CODEX_BIN`.
Accessibility and Screen Recording must be granted to Retrace in macOS settings.
For web scans, start a browser. Codex asks permission to control the selected app for the scan.

## Use

1. Select a running Mac app, or a web app URL and its running browser. Optionally narrow
   the scan to a particular feature.
2. Review the capture disclosure and start the scan. Codex receives the selected app's
   screen contents while exploring it. Retrace saves app-only screenshots around
   interactions and at checkpoints, with timestamps. Network capture is optional and
   supported only for Chromium/Electron apps; unsupported or unavailable capture is
   reported explicitly. **Finish Scan** asks for a report; **Cancel Scan** retains partial
   evidence. Plugin discovery can take up to a minute before exploration begins.
3. Review the evidence and coverage gaps. **Generate Requirements** sends recorded text,
   sanitized network metadata and up to six sampled screenshots to Codex. Review the
   generated user stories, acceptance criteria, proposed stack and unknowns, then approve.
4. Choose a parent folder and repository name. **Create Repository** creates a new local
   Git repository and its initial commit. Existing folders are never overwritten.

The repository contains `REQUIREMENTS.md`, `PLAN.json`, `TASKS.md`, individual prompts in
`tasks/`, and `AGENTS.md` with implementation/test/compare/iterate instructions. Task
IDs, evidence references and acyclic dependencies are validated before use. These are
prepared tasks, not completed implementations. No coding agents are launched automatically,
and no GitHub repository is published. GitHub authentication is checked in preparation
for the later development workflow.

Raw screenshots and network evidence remain in Retrace's private session storage rather
than being copied into the generated repository. Generated requirements can still contain
information inferred from the source app, so review them before sharing. Coverage is
always partial; the proposed stack does not claim to identify the original implementation.

## Verification

`macos/scripts/test.sh` includes plan validation, safe repository naming, real local Git
initialization, existing-folder refusal, subprocess timeout/cancellation, prompt filtering,
and CLI readiness tests. To additionally spend Codex usage on the synthetic image planning
integration test:

```sh
RETRACE_TEST_LIVE_CODEX=1 macos/scripts/test.sh --filter cloneLiveCodexStructuredPlan
```

Closing the panel retains the active workflow for the life of the app. Scan evidence and
generated `clone-plan.json` are saved in the session folder; automatic workflow restoration
after quitting is not implemented.
