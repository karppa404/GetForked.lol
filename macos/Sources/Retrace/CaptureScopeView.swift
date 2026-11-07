import SwiftUI

/// In-app explanation of exactly what is captured. Keep in sync with macos/README.md.
struct CaptureScopeView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("What Retrace captures").font(.title2.bold())
                section("Scope", [
                    "One target app per session, chosen from running Dock apps. Retrace never records itself.",
                    "Capture runs only while the target app is frontmost. When another app comes forward, the screen locks or the Mac sleeps, Retrace pauses, logs a focus_lost event and records nothing until the target is frontmost again.",
                    "Clicks and scrolls count only if the element under the pointer belongs to the target app. Keys count only if Accessibility reports the target app as focused. Everything else is dropped and only counted as \"ignored\".",
                ])
                section("Events", [
                    "Clicks (single, double, right, other) with coordinates relative to the captured display, and scrolls with summed deltas.",
                    "Named keys and shortcuts only: return, tab, escape, delete, arrows, F-keys, and command/control shortcuts such as cmd+s. Printable typing becomes a single \"text_input\" event with key \"redacted\". Characters are never recorded, including passwords.",
                    "Accessibility structure of the clicked or focused element: role, subrole, title, description or placeholder, identifier, window title. Field values are never read. For secure (password) fields only the role is kept.",
                ])
                section("Evidence frames", [
                    "Still images from ScreenCaptureKit, filtered to the target app's windows on one display. Other apps, the desktop and notifications are excluded.",
                    "For each action: a before frame (the latest in-memory frame, at most 3 s old), an after frame (~0.35 s later) and a settled frame (~1.5 s later). In-memory frames that no action uses are discarded and never written to disk.",
                    "Frames are JPEGs at display point resolution, so frame pixels match event coordinates. Up to 900 frames per session.",
                ])
                section("Not captured", [
                    "Network traffic. No network helper ships with v1, so sessions are marked network_status \"not_captured\". That does not mean the app made no requests.",
                    "Audio, video, other apps, other displays, and windows the target app moves to another display mid-session (those frames will be blank).",
                ])
                section("Storage and upload", [
                    "Sessions are stored in ~/Library/Application Support/Retrace/Sessions (folders 0700, excluded from backups).",
                    "Nothing leaves this Mac until you open a session, omit what must not be shared, confirm the review and press Upload & Analyze. Only kept frames and events are uploaded. Retrace does not detect sensitive content automatically.",
                    "Uploads use a device token from the one-click local connection to the Retrace server on this Mac, stored in the Keychain and tied to that server URL.",
                ])
                section("Permissions", [
                    "Accessibility: observe input events and read element roles. Grant it in System Settings › Privacy & Security › Accessibility.",
                    "Screen Recording: capture app-only frames. Grant it in System Settings › Privacy & Security › Screen & System Audio Recording. macOS may ask you to quit and reopen Retrace, and may ask again periodically.",
                    "Locally built copies are ad hoc signed, so macOS may ask for these permissions again after each rebuild.",
                ])
            }
            .padding(20)
        }
    }

    private func section(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                    Text(item).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
        }
    }
}
