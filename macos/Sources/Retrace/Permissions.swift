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
