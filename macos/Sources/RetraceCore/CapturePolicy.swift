import Foundation

/// The strict acceptance rules applied to every observed event and frame. Kept pure so the
/// rules are unit-tested independently of AppKit and permissions.
public enum CapturePolicy {
    public enum Decision: Equatable, Sendable {
        case accept
        case dropPaused
        case dropNotFrontmost
        case dropOutsideTarget
        case dropUnverified
    }

    public enum EventClass: Sendable { case pointer, key }

    /// - Parameters:
    ///   - recording: session is actively recording (not paused/stopping/idle)
    ///   - frontmostPID: NSWorkspace frontmost application at handling time
    ///   - ownerPID: pointer events: owner of the element/window under the pointer;
    ///     key events: Accessibility-focused application. `nil` = could not be determined.
    public static func evaluate(recording: Bool, targetPID: Int32, frontmostPID: Int32?, ownerPID: Int32?, kind: EventClass) -> Decision {
        guard recording else { return .dropPaused }
        guard frontmostPID == targetPID else { return .dropNotFrontmost }
        guard let ownerPID else { return .dropUnverified }
        return ownerPID == targetPID ? .accept : .dropOutsideTarget
    }

    /// Max age of the in-memory frame that may serve as an action's "before" evidence.
    public static let maxBeforeFrameAge: TimeInterval = 3.0

    /// Whether a cached frame captured at `frameUptime` can be the before frame of an event at `eventUptime`.
    public static func isUsableBeforeFrame(frameUptime: TimeInterval, eventUptime: TimeInterval) -> Bool {
        frameUptime <= eventUptime && eventUptime - frameUptime < maxBeforeFrameAge
    }

    /// Captures whose target times fall in the same 200 ms bucket share one frame.
    public static func coalescingBucket(forUptime t: TimeInterval) -> Int { Int((t * 5).rounded()) }

    public static let afterDelay: TimeInterval = 0.35
    public static let settledDelay: TimeInterval = 1.5
}
