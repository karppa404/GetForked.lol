import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct CapturedImage: @unchecked Sendable {
    let image: CGImage
    let uptime: TimeInterval
}

enum CaptureError: LocalizedError {
    case appNotShareable
    case noDisplay
    var errorDescription: String? {
        switch self {
        case .appNotShareable: return "The target app has no capturable windows (is it running with a visible window, and is Screen Recording allowed?)."
        case .noDisplay: return "No display found for the target app."
        }
    }
}

/// Application-scoped still capture with ScreenCaptureKit. The content filter includes only
/// the target application's windows on one display, so other apps, the desktop, notifications
/// and Retrace itself are not in frames. Frames are rendered at point resolution, so pixel
/// coordinates in a frame equal display-relative point coordinates of interactions.
actor FrameCapturer {
    let pid: pid_t
    private var filter: SCContentFilter?
    private var configuration: SCStreamConfiguration?
    private var displayID: CGDirectDisplayID?
    private(set) var displayFrame: CGRect = .zero

    init(pid: pid_t) { self.pid = pid }

    /// Picks the display holding most of the target's on-screen windows and builds the filter.
    /// Calling this is what may make macOS show its Screen Recording prompt, so it runs only
    /// after the user presses Start.
    @discardableResult
    func prepare() async throws -> CGRect {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let app = content.applications.first(where: { $0.processID == pid }) else { throw CaptureError.appNotShareable }
        let windows = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.isOnScreen }
        guard !windows.isEmpty else { throw CaptureError.appNotShareable }
        let display: SCDisplay?
        if let fixed = displayID, let d = content.displays.first(where: { $0.displayID == fixed }) {
            display = d
        } else {
            display = content.displays.max { a, b in
                coverage(of: a.frame, by: windows) < coverage(of: b.frame, by: windows)
            }
        }
        guard let display else { throw CaptureError.noDisplay }
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.scalesToFit = true
        config.showsCursor = true
        config.capturesAudio = false
        filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        configuration = config
        displayID = display.displayID
        displayFrame = display.frame
        return display.frame
    }

    private func coverage(of rect: CGRect, by windows: [SCWindow]) -> CGFloat {
        windows.reduce(0) { sum, w in
            let i = rect.intersection(w.frame)
            return sum + (i.isNull ? 0 : i.width * i.height)
        }
    }

    func capture() async throws -> CapturedImage {
        if filter == nil { try await prepare() }
        guard let filter, let configuration else { throw CaptureError.appNotShareable }
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let end = ProcessInfo.processInfo.systemUptime
            return CapturedImage(image: image, uptime: (start + end) / 2)
        } catch {
            self.filter = nil // refresh on next attempt (window/app set may have changed)
            throw error
        }
    }

    nonisolated static func jpegData(_ image: CGImage, quality: Double = 0.78) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
