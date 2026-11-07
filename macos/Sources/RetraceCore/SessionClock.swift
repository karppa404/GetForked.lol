import Foundation

/// One clock per session. `started_at` is wall-clock UTC; every evidence timestamp is
/// milliseconds since start measured on the monotonic system-uptime clock (the same base
/// as `NSEvent.timestamp`), so wall-clock adjustments can't reorder evidence.
public struct SessionClock: Sendable, Equatable {
    public let startUptime: TimeInterval
    public let startDate: Date

    public init(startUptime: TimeInterval = ProcessInfo.processInfo.systemUptime, startDate: Date = Date()) {
        self.startUptime = startUptime
        self.startDate = startDate
    }

    /// Milliseconds since session start for a monotonic uptime value. Never negative.
    public func milliseconds(atUptime uptime: TimeInterval) -> Int {
        let ms = ((uptime - startUptime) * 1000).rounded()
        guard ms.isFinite, ms > 0 else { return 0 }
        return Int(ms)
    }

    public func nowMilliseconds(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Int {
        milliseconds(atUptime: uptime)
    }

    public var startedAtISO8601: String { Self.iso8601(startDate) }

    public static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    public static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
