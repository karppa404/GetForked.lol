import Foundation

/// Cached server state for one credential (server + device token).
///
/// Every request captures a `generation` (or a `DetailTicket`) when it starts. `reset()` runs on
/// every credential change or disconnect and bumps the generation, so results of requests started
/// under the old credential are dropped instead of repopulating the cleared cache. Detail requests
/// also carry a per-session sequence number: an older response never overwrites a newer one, and
/// `invalidate(_:)` drops every response already in flight for a session (used before a local edit).
public struct WorkspaceStore: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable { case stale, unchanged, changed }

    /// Identifies one detail request: its credential generation and per-session order.
    public struct DetailTicket: Equatable, Sendable {
        public let generation: Int
        public let sessionId: String
        public let seq: Int
    }

    public private(set) var generation = 0
    public private(set) var remote: [RemoteSessionSummary] = []
    public private(set) var projectName: String?
    public private(set) var details: [String: RemoteSessionDetail] = [:]
    public private(set) var detailErrors: [String: String] = [:]
    private var issued: [String: Int] = [:]
    /// Responses with a sequence at or below this are dropped.
    private var floor: [String: Int] = [:]

    public init() {}

    /// A different (or no) credential: forget everything and reject every in-flight response.
    public mutating func reset() {
        generation += 1
        remote = []; projectName = nil; details = [:]; detailErrors = [:]
        issued = [:]; floor = [:]
    }

    public func isCurrent(_ generation: Int) -> Bool { generation == self.generation }

    @discardableResult
    public mutating func setSessions(_ sessions: [RemoteSessionSummary], project: String?, generation: Int) -> Outcome {
        guard isCurrent(generation) else { return .stale }
        guard sessions != remote || project != projectName else { return .unchanged }
        remote = sessions; projectName = project
        return .changed
    }

    public mutating func issueDetailRequest(_ id: String) -> DetailTicket {
        let seq = (issued[id] ?? 0) + 1
        issued[id] = seq
        return DetailTicket(generation: generation, sessionId: id, seq: seq)
    }

    /// Drops every response for `id` that is already in flight.
    public mutating func invalidate(_ id: String) { floor[id] = issued[id] ?? 0 }

    private mutating func accept(_ t: DetailTicket) -> Bool {
        guard isCurrent(t.generation), t.seq > (floor[t.sessionId] ?? 0) else { return false }
        floor[t.sessionId] = t.seq
        return true
    }

    @discardableResult
    public mutating func setDetail(_ d: RemoteSessionDetail, ticket: DetailTicket) -> Outcome {
        guard ticket.sessionId == d.id, accept(ticket) else { return .stale }
        let hadError = detailErrors.removeValue(forKey: d.id) != nil
        guard details[d.id] != d else { return hadError ? .changed : .unchanged }
        details[d.id] = d
        return .changed
    }

    /// Errors are only shown for sessions that never loaded; a cached detail is kept on failure.
    @discardableResult
    public mutating func setDetailError(_ message: String, ticket: DetailTicket) -> Outcome {
        guard accept(ticket) else { return .stale }
        guard details[ticket.sessionId] == nil, detailErrors[ticket.sessionId] != message else { return .unchanged }
        detailErrors[ticket.sessionId] = message
        return .changed
    }

    /// Local edit of a cached detail (optimistic updates). Drops in-flight responses for it.
    @discardableResult
    public mutating func updateDetail(_ id: String, generation: Int, _ change: (inout RemoteSessionDetail) -> Void) -> Outcome {
        guard isCurrent(generation), var d = details[id] else { return .stale }
        invalidate(id)
        change(&d)
        guard d != details[id] else { return .unchanged }
        details[id] = d
        return .changed
    }

    /// Sessions deleted on the server: gone from the list and the caches at once, and any response
    /// still in flight for them is dropped.
    @discardableResult
    public mutating func removeSessions(_ ids: Set<String>, generation: Int) -> Outcome {
        guard isCurrent(generation) else { return .stale }
        ids.forEach { invalidate($0) }
        let before = (remote.count, details.count, detailErrors.count)
        remote.removeAll { ids.contains($0.id) }
        ids.forEach { details[$0] = nil; detailErrors[$0] = nil }
        return before == (remote.count, details.count, detailErrors.count) ? .unchanged : .changed
    }

    /// True only while this credential's data shows a queued or running analysis.
    public var needsPolling: Bool { !runningIds.isEmpty }

    /// Sessions whose analysis is queued or running.
    public var runningIds: Set<String> {
        Set(remote.filter(\.isAnalyzing).map(\.id)).union(details.values.filter { $0.job?.isActive == true }.map(\.id))
    }
}
