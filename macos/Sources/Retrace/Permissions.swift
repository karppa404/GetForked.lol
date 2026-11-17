import AppKit
import ApplicationServices
import CoreGraphics

/// Permission checks. The `granted` properties never prompt; the `request…` functions are
/// called only from explicit button presses in the UI.
enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}

/// Live permission status shared by every view that shows it. macOS sends no notification when a
/// grant changes in System Settings, so status is re-read when Retrace becomes active, when one of
/// its windows (including the menu bar panel) becomes key, and every 1.5 s while a permission view
/// is on screen and something is still missing. Polling stops once everything is granted.
@MainActor
final class PermissionMonitor: ObservableObject {
    static let shared = PermissionMonitor()

    @Published private(set) var accessibility = Permissions.accessibilityGranted
    @Published private(set) var screenRecording = Permissions.screenRecordingGranted
    /// True once the user has asked for Screen Recording (Request or Settings) and come back to
    /// Retrace while it still reads as missing. macOS frequently applies that grant only after the
    /// app restarts, and `CGPreflightScreenCaptureAccess` keeps returning false until then.
    @Published private(set) var screenRecordingMayNeedRelaunch = false

    var allGranted: Bool { accessibility && screenRecording }

    private var visibleViews = 0
    private var timer: Timer?
    private var screenRequestedAt: Date?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    self?.refresh(returnedToApp: note.name == NSApplication.didBecomeActiveNotification)
                }
            })
        }
    }

    func refresh(returnedToApp: Bool = false) {
        let ax = Permissions.accessibilityGranted
        let screen = Permissions.screenRecordingGranted
        if ax != accessibility { accessibility = ax }
        if screen != screenRecording { screenRecording = screen }
        if screen {
            screenRequestedAt = nil
            screenRecordingMayNeedRelaunch = false
        } else if let at = screenRequestedAt, returnedToApp || Date().timeIntervalSince(at) > 8 {
            // Back from System Settings (or the system prompt has had time) and still not
            // visible to this process: the grant most likely needs a restart to apply.
            screenRecordingMayNeedRelaunch = true
        }
        updateTimer()
    }

    func requestAccessibility() {
        Permissions.requestAccessibility()
        refresh()
    }

    func requestScreenRecording() {
        screenRequestedAt = Date()
        Permissions.requestScreenRecording()
        refresh()
    }

    func openScreenRecordingSettings() {
        screenRequestedAt = Date()
        Permissions.openScreenRecordingSettings()
    }

    /// Call from `onAppear` / `onDisappear` of views that show permission status.
    func viewAppeared() {
        visibleViews += 1
        refresh()
    }

    func viewDisappeared() {
        visibleViews = max(0, visibleViews - 1)
        updateTimer()
    }

    private func updateTimer() {
        let shouldPoll = visibleViews > 0 && !allGranted
        if shouldPoll, timer == nil {
            let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !shouldPoll, let t = timer {
            t.invalidate()
            timer = nil
        }
    }

    /// Starts a fresh instance of the app bundle after this process exits, then quits.
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundleURL.path]
        do {
            try task.run()
        } catch {
            NSLog("Retrace: relaunch failed: \(error)")
            return
        }
        NSApp.terminate(nil)
    }
}
