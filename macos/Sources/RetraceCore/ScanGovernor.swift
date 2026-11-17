import Foundation

/// One completed computer-use tool call, reduced to what stop rules need.
public struct ScanToolCall: Sendable, Equatable {
    public var title: String?
    /// Tool plus normalized arguments (without the title): identical signatures mean the same action.
    public var signature: String
    public var failed: Bool
    /// Arguments and result text, searched for page URLs.
    public var text: String

    public init(title: String?, signature: String, failed: Bool, text: String = "") {
        self.title = title; self.signature = signature; self.failed = failed; self.text = text
    }

    /// Builds the observation from an `mcpToolCall` thread item.
    public init(item: [String: Any]) {
        var arguments = item["arguments"] as? [String: Any] ?? [:]
        title = arguments.removeValue(forKey: "title") as? String
        failed = item["status"] as? String == "failed"
        let args = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        signature = "\(item["tool"] as? String ?? "")|\(args)".lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var parts = [args]
        let result = item["result"] as? [String: Any] ?? [:]
        for content in result["content"] as? [[String: Any]] ?? [] {
            if let text = content["text"] as? String { parts.append(text) }
        }
        if let structured = result["structuredContent"], !(structured is NSNull),
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.fragmentsAllowed]) {
            parts.append(String(decoding: data, as: UTF8.self))
        }
        if let message = (item["error"] as? [String: Any])?["message"] as? String { parts.append(message) }
        text = String(parts.joined(separator: "\n").prefix(20_000))
    }
}

public enum ScanSaturation: Equatable, Sendable {
    /// No new page, route or feature for this many consecutive calls.
    case noNewCoverage(steps: Int)
    /// The same action ran this many times without revealing anything new.
    case repeatedAction(times: Int)
    case repeatedFailures(count: Int)

    public var detail: String {
        switch self {
        case .noNewCoverage(let steps): "coverage saturated: the last \(steps) steps found no new pages, routes or features"
        case .repeatedAction(let times): "coverage saturated: the same action was repeated \(times) times without new results"
        case .repeatedFailures(let count): "the last \(count) computer-use steps failed"
        }
    }
}

/// Detects when a scan stops finding anything new, from the observable event stream only.
///
/// A call is *novel* when it succeeds and either shows a page URL not seen before (restricted to the
/// scan host for web scans) or its title names a feature word not used before. Failed calls are never
/// novel. Commentary can contribute new URLs too.
public struct ScanCoverage: Sendable {
    public struct Thresholds: Sendable, Equatable {
        /// Consecutive non-novel calls that count as saturation.
        public var stallSteps = 8
        /// Stall detection waits until the scan has made this many calls.
        public var minimumCalls = 12
        /// Same action this many times among the non-novel calls since the last discovery…
        public var repeatCount = 3
        /// …looking at most this many calls back.
        public var repeatWindow = 6
        public var failureStreak = 5
        public init() {}
    }

    public let thresholds: Thresholds
    /// Lowercased host of a web scan; nil for native apps (any URL counts).
    public let host: String?
    public private(set) var calls = 0
    public private(set) var callsSinceNovelty = 0
    public private(set) var urls: Set<String> = []
    public private(set) var vocabulary: Set<String> = []
    private var recentSignatures: [String] = []
    private var failureStreak = 0
    private var lastRepeat = 0

    public init(host: String? = nil, thresholds: Thresholds = Thresholds()) {
        self.host = host?.lowercased()
        self.thresholds = thresholds
    }

    /// Records a tool call; returns whether it was novel.
    @discardableResult
    public mutating func observe(_ call: ScanToolCall) -> Bool {
        calls += 1
        failureStreak = call.failed ? failureStreak + 1 : 0
        var novel = false
        if !call.failed {
            let newURLs = Self.pageURLs(in: call.text, host: host).subtracting(urls)
            let newWords = Self.featureWords(call.title).subtracting(vocabulary)
            urls.formUnion(newURLs)
            vocabulary.formUnion(newWords)
            novel = !newURLs.isEmpty || !newWords.isEmpty
        }
        if novel {
            callsSinceNovelty = 0
            recentSignatures = []
        } else {
            callsSinceNovelty += 1
            recentSignatures.append(call.signature)
            if recentSignatures.count > thresholds.repeatWindow { recentSignatures.removeFirst() }
        }
        lastRepeat = Dictionary(recentSignatures.map { ($0, 1) }, uniquingKeysWith: +).values.max() ?? 0
        return novel
    }

    /// Commentary only adds URLs (the agent naming a page it reached); it never adds feature words.
    public mutating func observe(commentary: String) {
        let found = Self.pageURLs(in: commentary, host: host).subtracting(urls)
        guard !found.isEmpty else { return }
        urls.formUnion(found)
        callsSinceNovelty = 0
        recentSignatures = []
        lastRepeat = 0
    }

    public var saturation: ScanSaturation? {
        if failureStreak >= thresholds.failureStreak { return .repeatedFailures(count: failureStreak) }
        if lastRepeat >= thresholds.repeatCount { return .repeatedAction(times: lastRepeat) }
        if calls >= thresholds.minimumCalls, callsSinceNovelty >= thresholds.stallSteps {
            return .noNewCoverage(steps: callsSinceNovelty)
        }
        return nil
    }

    /// Page identities in text: host + path (+ hash route), without query strings.
    public static func pageURLs(in text: String, host: String?) -> Set<String> {
        let pattern: String
        if let host, !host.isEmpty {
            pattern = "(?<![A-Za-z0-9.-])" + NSRegularExpression.escapedPattern(for: host) + "(?::[0-9]+)?(?:[/#][^\\s\"'<>\\\\`)\\]]*)?"
        } else {
            pattern = "https?://[^\\s\"'<>\\\\`)\\]]+"
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return Set(regex.matches(in: text, range: range).compactMap { match -> String? in
            guard let r = Range(match.range, in: text) else { return nil }
            var value = String(text[r])
            while let last = value.last, ".,;:!?".contains(last) { value.removeLast() }
            if !value.contains("://") { value = "https://" + value }
            guard let parts = URLComponents(string: value), let found = parts.host?.lowercased() else { return nil }
            var path = parts.path
            while path.hasSuffix("/") { path.removeLast() }
            var key = found + (parts.port.map { ":\($0)" } ?? "") + path
            if let fragment = parts.fragment, fragment.hasPrefix("/") || fragment.hasPrefix("!") { key += "#" + fragment }
            return key
        })
    }

    /// Generic UI verbs and nouns that say nothing about which feature a step touched.
    static let genericWords: Set<String> = [
        "the", "and", "for", "with", "into", "onto", "from", "then", "that", "this", "its", "again", "still", "now",
        "new", "next", "previous", "current", "first", "last", "one", "all", "any", "more", "some", "back", "after",
        "before", "while", "via", "using", "use", "there", "what", "which", "whether", "available", "visible",
        "click", "tap", "press", "open", "close", "check", "recheck", "verify", "confirm", "inspect", "view", "look",
        "see", "read", "take", "capture", "screenshot", "scroll", "select", "choose", "return", "navigate",
        "retry", "try", "test", "wait", "focus", "hover", "type", "enter", "find", "get", "show", "list", "go",
        "explore", "examine", "observe", "review", "state", "page", "screen", "window", "app", "button", "tab",
        "menu", "item", "element", "control", "result", "results", "ui", "accessibility", "tree", "url", "address",
        "bar", "browser", "dialog", "panel", "section", "area", "content", "detail", "details", "option", "options",
        "down", "top", "bottom", "left", "right", "main", "home", "link", "field",
    ]

    /// Distinct feature words in a step title: lowercased, crudely stemmed, generic words removed.
    public static func featureWords(_ title: String?) -> Set<String> {
        guard let title else { return [] }
        return Set(title.lowercased().split(whereSeparator: { !$0.isLetter }).compactMap { raw -> String? in
            var word = String(raw)
            if word.hasSuffix("s"), !word.hasSuffix("ss"), word.count >= 4 { word.removeLast() }
            for suffix in ["ing", "ed"] where word.hasSuffix(suffix) && word.count - suffix.count >= 3 {
                word.removeLast(suffix.count); break
            }
            guard word.count >= 3, ![word, word + "e", String(raw)].contains(where: genericWords.contains) else { return nil }
            return word
        })
    }
}

/// Step and time budgets: a soft limit steers Codex to wrap up, a hard limit stops it.
public struct ScanBudget: Sendable, Equatable {
    public var maxSteps = 80
    public var maxSeconds: TimeInterval = 600
    /// Fraction of each budget at which Codex is asked to write its report.
    public var softFraction = 0.8
    /// After a wrap-up request, Codex may take this many more steps or seconds before it is interrupted.
    public var graceSteps = 6
    public var graceSeconds: TimeInterval = 90
    /// Time allowed for an interrupt to land before the app server is terminated.
    public var interruptSeconds: TimeInterval = 10
    /// Time allowed for the report-only follow-up turn after an interrupt.
    public var reportSeconds: TimeInterval = 90
    public init() {}

    public var softSteps: Int { Int((Double(maxSteps) * softFraction).rounded()) }
    public var softSeconds: TimeInterval { maxSeconds * softFraction }
}

public enum ScanWrapUpReason: Equatable, Sendable {
    case saturated(ScanSaturation)
    case stepBudget(used: Int, limit: Int)
    case timeBudget(elapsed: TimeInterval, limit: TimeInterval)
    case user

    public var detail: String {
        switch self {
        case .saturated(let saturation): saturation.detail
        case .stepBudget(let used, let limit): "the step budget is nearly spent (\(used) of \(limit) steps)"
        case .timeBudget(let elapsed, let limit): "the time budget is nearly spent (\(Int(elapsed / 60)) of \(Int(limit / 60)) minutes)"
        case .user: "the user asked to wrap up the scan now"
        }
    }
}

/// Why a scan ended, recorded in the scan report.
public enum ScanEndReason: Equatable, Sendable {
    case agentFinished
    case saturated(String)
    case budget(String)
    case userWrapUp
    case userStopped
    case error(String)

    public var label: String {
        switch self {
        case .agentFinished: "agent finished"
        case .saturated: "saturated"
        case .budget: "budget"
        case .userWrapUp: "user wrap-up"
        case .userStopped: "user stopped"
        case .error: "error"
        }
    }

    public var summary: String {
        switch self {
        case .agentFinished: "Codex finished exploring on its own."
        case .saturated(let detail): "Codex was asked to wrap up early because \(detail)."
        case .budget(let detail): "Codex was asked to wrap up because \(detail)."
        case .userWrapUp: "You asked Codex to wrap up."
        case .userStopped: "You stopped the scan before Codex wrote its report."
        case .error(let message): message
        }
    }
}

/// Decides when to steer, interrupt or stop a scan. Pure: the caller feeds events and the clock and
/// performs the returned action.
public struct ScanGovernor: Sendable {
    public enum Phase: Equatable, Sendable {
        case exploring
        /// Codex was steered to write its report at this time and step count.
        case wrappingUp(since: Date, atStep: Int)
        case interrupting(since: Date)
        /// A report-only turn runs after an interrupt that left no report.
        case reporting(since: Date)
        case finished
    }

    public enum Action: Equatable, Sendable {
        case none
        /// Send `turn/steer` with this text.
        case steer(String)
        case interrupt
        /// Send a new `turn/start` asking only for the report.
        case startReportTurn(String)
        case terminate
    }

    public let budget: ScanBudget
    public private(set) var coverage: ScanCoverage
    public private(set) var phase: Phase = .exploring
    public private(set) var wrapUpReason: ScanWrapUpReason?
    /// Completed (non-failed) computer-use steps.
    public private(set) var steps = 0
    public let started: Date

    public init(budget: ScanBudget = ScanBudget(), coverage: ScanCoverage = ScanCoverage(), started: Date = Date()) {
        self.budget = budget
        self.coverage = coverage
        self.started = started
    }

    public var isWrappingUp: Bool { phase != .exploring }

    public mutating func observe(_ call: ScanToolCall, now: Date) -> Action {
        if !call.failed { steps += 1 }
        coverage.observe(call)
        return tick(now: now)
    }

    public mutating func observe(commentary: String) { coverage.observe(commentary: commentary) }

    /// A computer-use call is starting. During the report-only turn Codex must not act, so stop.
    public mutating func toolStarted() -> Action {
        guard case .reporting = phase else { return .none }
        phase = .finished
        return .terminate
    }

    public mutating func requestWrapUp(now: Date) -> Action {
        guard phase == .exploring else { return .none }
        return beginWrapUp(.user, now: now)
    }

    public mutating func tick(now: Date) -> Action {
        let elapsed = now.timeIntervalSince(started)
        let overHard = steps >= budget.maxSteps || elapsed >= budget.maxSeconds
        switch phase {
        case .exploring:
            if overHard {
                wrapUpReason = steps >= budget.maxSteps ? .stepBudget(used: steps, limit: budget.maxSteps)
                    : .timeBudget(elapsed: elapsed, limit: budget.maxSeconds)
                phase = .interrupting(since: now)
                return .interrupt
            }
            if steps >= budget.softSteps { return beginWrapUp(.stepBudget(used: steps, limit: budget.maxSteps), now: now) }
            if elapsed >= budget.softSeconds { return beginWrapUp(.timeBudget(elapsed: elapsed, limit: budget.maxSeconds), now: now) }
            if let saturation = coverage.saturation { return beginWrapUp(.saturated(saturation), now: now) }
            return .none
        case .wrappingUp(let since, let atStep):
            guard overHard || steps - atStep >= budget.graceSteps || now.timeIntervalSince(since) >= budget.graceSeconds else { return .none }
            phase = .interrupting(since: now)
            return .interrupt
        case .interrupting(let since):
            guard now.timeIntervalSince(since) >= budget.interruptSeconds else { return .none }
            phase = .finished
            return .terminate
        case .reporting(let since):
            guard now.timeIntervalSince(since) >= budget.reportSeconds else { return .none }
            phase = .finished
            return .terminate
        case .finished:
            return .none
        }
    }

    /// `turn/steer` was rejected (for example the turn already ended): interrupt instead.
    public mutating func steerFailed(now: Date) -> Action {
        guard case .wrappingUp = phase else { return .none }
        phase = .interrupting(since: now)
        return .interrupt
    }

    /// The scan turn ended. Returns `.startReportTurn` when Retrace interrupted Codex before any report.
    public mutating func turnCompleted(status: String, hasReport: Bool, now: Date) -> Action {
        if case .interrupting = phase, status == "interrupted", !hasReport {
            phase = .reporting(since: now)
            return .startReportTurn(CodexScan.reportOnlyMessage(wrapUpReason ?? .user))
        }
        phase = .finished
        return .terminate
    }

    public func endReason(cancelled: Bool, failure: String?) -> ScanEndReason {
        if cancelled { return .userStopped }
        if let failure { return .error(failure) }
        switch wrapUpReason {
        case .saturated(let saturation)?: return .saturated(saturation.detail)
        case .stepBudget?, .timeBudget?: return .budget(wrapUpReason!.detail)
        case .user?: return .userWrapUp
        case nil: return .agentFinished
        }
    }

    private mutating func beginWrapUp(_ reason: ScanWrapUpReason, now: Date) -> Action {
        wrapUpReason = reason
        phase = .wrappingUp(since: now, atStep: steps)
        return .steer(CodexScan.wrapUpMessage(reason))
    }
}

extension CodexScan {
    /// Steer text sent mid-turn so Codex stops exploring but still writes the report.
    public static func wrapUpMessage(_ reason: ScanWrapUpReason) -> String {
        """
        Retrace scan control: \(reason.detail). Stop exploring now and do not call any more tools. \
        Write the final report immediately from what you have already observed, in the required report \
        format, and list every pending branch you did not reach as untested.
        """
    }

    /// First turn after an interrupt that left no report.
    public static func reportOnlyMessage(_ reason: ScanWrapUpReason) -> String {
        """
        Retrace stopped the scan (\(reason.detail)). Do not call any tools. Write the final report now \
        from what you already observed, in the required report format, and list every pending branch \
        you did not reach as untested.
        """
    }

    public static func steerParams(threadId: String, turnId: String, text: String) -> [String: Any] {
        ["threadId": threadId, "expectedTurnId": turnId, "input": [["type": "text", "text": text]]]
    }

    public static func interruptParams(threadId: String, turnId: String) -> [String: Any] {
        ["threadId": threadId, "turnId": turnId]
    }
}
