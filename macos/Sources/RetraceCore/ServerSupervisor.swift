import Foundation

/// The single stdout line the engine prints once it listens: `RETRACE_READY {"port":N,"version":"x"}`.
public struct ServerReady: Equatable, Sendable {
    public static let prefix = "RETRACE_READY "
    public var port: Int
    public var version: String?
    public var baseURL: APIBaseURL

    public init(baseURL: APIBaseURL, port: Int, version: String? = nil) {
        self.baseURL = baseURL
        self.port = port
        self.version = version
    }

    public init?(line: String) {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix(Self.prefix) else { return nil }
        struct Payload: Decodable { let port: Int; let version: String? }
        guard let p = try? JSONDecoder().decode(Payload.self, from: Data(t.dropFirst(Self.prefix.count).utf8)),
              (1...65535).contains(p.port),
              let base = try? APIBaseURL("http://127.0.0.1:\(p.port)") else { return nil }
        port = p.port
        version = p.version.map { String($0.prefix(64)) }
        baseURL = base
    }
}

public enum ServerState: Equatable, Sendable {
    case stopped
    case starting
    case ready(ServerReady)
    case failed(String)

    public var baseURL: APIBaseURL? { if case .ready(let r) = self { return r.baseURL } else { return nil } }
}

public struct SupervisorPolicy: Sendable {
    public var readyTimeout: Duration
    /// Unexpected exits retried before giving up (a run that stayed up `stableAfter` resets the count).
    public var maxQuickRetries: Int
    public var baseDelay: Duration
    public var maxDelay: Duration
    public var stableAfter: Duration
    /// SIGTERM, then SIGKILL after this long.
    public var terminateGrace: Duration
    public var diagnosticLines: Int

    public init(readyTimeout: Duration = .seconds(15), maxQuickRetries: Int = 3, baseDelay: Duration = .milliseconds(500),
                maxDelay: Duration = .seconds(4), stableAfter: Duration = .seconds(30), terminateGrace: Duration = .seconds(3),
                diagnosticLines: Int = 50) {
        self.readyTimeout = readyTimeout
        self.maxQuickRetries = maxQuickRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.stableAfter = stableAfter
        self.terminateGrace = terminateGrace
        self.diagnosticLines = diagnosticLines
    }

    /// Delay before retry number `failures` (1-based), or nil once retries are exhausted.
    public func retryDelay(afterFailures failures: Int) -> Duration? {
        guard failures >= 1, failures <= maxQuickRetries else { return nil }
        return min(baseDelay * (1 << min(failures - 1, 10)), maxDelay)
    }
}

/// Scrubs secrets from engine output before it is kept for diagnostics.
public enum DiagnosticRedactor {
    public static let mask = "‹redacted›"
    static let patterns: [NSRegularExpression] = [
        #"(?i)(bearer\s+)[A-Za-z0-9._~+/=\-]+"#,
        #"(?i)((?:api[_-]?key|token|secret|password|authorization)["']?\s*[:=]\s*["']?)[^\s"',}]+"#,
        #"\b(?:nvapi|sk|rtd)[-_][A-Za-z0-9._\-]{6,}"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    public static func redact(_ line: String, secrets: [String] = [], maxLength: Int = 500) -> String {
        var s = String(line.prefix(maxLength))
        for secret in secrets where secret.count >= 4 { s = s.replacingOccurrences(of: secret, with: mask) }
        for re in patterns {
            let range = NSRange(s.startIndex..., in: s)
            let template = re.numberOfCaptureGroups > 0 ? "$1\(mask)" : mask
            s = re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
        }
        return s
    }
}

/// Launches the analysis engine, waits for its ready line, restarts it with backoff when it exits
/// unexpectedly and stops it on request. The engine also exits on its own when its stdin reaches
/// EOF, so it never outlives the app even if the app crashes.
@MainActor
public final class ServerSupervisor {
    public private(set) var state: ServerState = .stopped {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public var onStateChange: (@MainActor (ServerState) -> Void)?
    /// Last stderr lines (redacted), newest last.
    public private(set) var diagnostics: [String] = []
    public private(set) var launchCount = 0

    public let policy: SupervisorPolicy
    private let prepare: @MainActor () throws -> ServerLaunchSpec

    private final class Run {
        let id: Int
        let process: Process
        let stdin: Pipe
        let spec: ServerLaunchSpec
        var readyAt: ContinuousClock.Instant?
        var stopRequested = false
        var timedOut = false
        var stdinClosed = false
        var stderrReader: Task<Void, Never>?
        var exitWaiters: [CheckedContinuation<Void, Never>] = []
        init(id: Int, process: Process, stdin: Pipe, spec: ServerLaunchSpec) {
            self.id = id; self.process = process; self.stdin = stdin; self.spec = spec
        }
    }

    private var run: Run?
    private var nextId = 0
    private var failures = 0
    private var retryTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var operation: Task<Void, Never>?

    public init(policy: SupervisorPolicy = SupervisorPolicy(), prepare: @escaping @MainActor () throws -> ServerLaunchSpec) {
        self.policy = policy
        self.prepare = prepare
    }

    public var isRunning: Bool { run != nil }
    public var pid: Int32? { run?.process.processIdentifier }

    // MARK: Control

    /// Starts the engine unless it is already running or about to retry. Clears a failed state.
    public func start() {
        guard run == nil, retryTask == nil, operation == nil else { return }
        failures = 0
        launch()
    }

    /// Stops the current engine (if any) and starts a fresh one, e.g. after settings change.
    public func restart() {
        let previous = operation
        operation = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.stopRun()
            guard !Task.isCancelled else { return }
            self.failures = 0
            self.operation = nil
            self.launch()
        }
    }

    /// Graceful stop: close stdin, SIGTERM, SIGKILL after the grace period.
    public func stop() async {
        operation?.cancel()
        operation = nil
        await stopRun()
        state = .stopped
    }

    /// Synchronous stop for `applicationWillTerminate`; blocks up to the grace period.
    public func terminateNow() {
        retryTask?.cancel(); retryTask = nil
        timeoutTask?.cancel(); timeoutTask = nil
        operation?.cancel(); operation = nil
        guard let r = run else { state = .stopped; return }
        r.stopRequested = true
        closeStdin(r)
        let pid = r.process.processIdentifier
        if r.process.isRunning { kill(pid, SIGTERM) }
        let deadline = ContinuousClock.now + policy.terminateGrace
        while r.process.isRunning && ContinuousClock.now < deadline { usleep(20_000) }
        if r.process.isRunning { kill(pid, SIGKILL); r.process.waitUntilExit() }
        removeTransientFiles(r)
        run = nil
        r.exitWaiters.forEach { $0.resume() }
        r.exitWaiters = []
        state = .stopped
    }

    private func stopRun() async {
        retryTask?.cancel(); retryTask = nil
        timeoutTask?.cancel(); timeoutTask = nil
        guard let r = run else { return }
        r.stopRequested = true
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            r.exitWaiters.append(c)
            signal(r)
        }
    }

    /// SIGTERM now (and stdin EOF), SIGKILL if still running after the grace period.
    private func closeStdin(_ r: Run) {
        guard !r.stdinClosed else { return }
        r.stdinClosed = true
        try? r.stdin.fileHandleForWriting.close()
    }

    private func signal(_ r: Run) {
        closeStdin(r)
        guard r.process.isRunning else { return }
        let pid = r.process.processIdentifier
        kill(pid, SIGTERM)
        let grace = policy.terminateGrace
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard let self, self.run === r, r.process.isRunning else { return }
            kill(pid, SIGKILL)
        }
    }

    // MARK: Launch

    private func launch() {
        retryTask = nil
        state = .starting
        let spec: ServerLaunchSpec
        do { spec = try prepare() } catch {
            state = .failed("Could not prepare the analysis engine: \(error.localizedDescription)")
            return
        }
        nextId += 1
        let id = nextId
        let p = Process()
        p.executableURL = spec.executable
        p.arguments = spec.arguments
        p.environment = spec.environment
        if let dir = spec.currentDirectory { p.currentDirectoryURL = dir }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let uncaught = proc.terminationReason == .uncaughtSignal
            Task { @MainActor [weak self] in await self?.exited(id, status: status, signaled: uncaught) }
        }
        let r = Run(id: id, process: p, stdin: stdin, spec: spec)
        do {
            try p.run()
        } catch {
            removeTransientFiles(r)
            failed("Could not start the analysis engine: \(error.localizedDescription)")
            return
        }
        run = r
        launchCount += 1
        let secrets = spec.secrets
        let outLines = Self.lines(stdout.fileHandleForReading), errLines = Self.lines(stderr.fileHandleForReading)
        Task { [weak self] in
            for await line in outLines { self?.stdoutLine(id, line) }
        }
        r.stderrReader = Task { [weak self] in
            for await line in errLines { self?.stderrLine(id, DiagnosticRedactor.redact(line, secrets: secrets)) }
        }
        let timeout = policy.readyTimeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.readyTimedOut(id)
        }
    }

    /// Lines read from a pipe without blocking a thread (dispatch-driven), finishing at EOF.
    nonisolated static func lines(_ handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let splitter = LineSplitter()
            handle.readabilityHandler = { h in
                let data = h.availableData
                if data.isEmpty {
                    h.readabilityHandler = nil
                    if let rest = splitter.finish() { continuation.yield(rest) }
                    continuation.finish()
                    return
                }
                for line in splitter.feed(data) { continuation.yield(line) }
            }
        }
    }

    private func stdoutLine(_ id: Int, _ line: String) {
        guard let r = run, r.id == id else { return }
        guard let ready = ServerReady(line: line) else {
            appendDiagnostic(DiagnosticRedactor.redact(line, secrets: r.spec.secrets))
            return
        }
        guard r.readyAt == nil, !r.stopRequested else { return }
        r.readyAt = .now
        timeoutTask?.cancel(); timeoutTask = nil
        removeTransientFiles(r)
        state = .ready(ready)
    }

    private func stderrLine(_ id: Int, _ line: String) {
        guard run?.id == id || run == nil else { return }
        appendDiagnostic(line)
    }

    private func appendDiagnostic(_ line: String) {
        guard !line.isEmpty else { return }
        diagnostics.append(line)
        if diagnostics.count > policy.diagnosticLines { diagnostics.removeFirst(diagnostics.count - policy.diagnosticLines) }
    }

    private func readyTimedOut(_ id: Int) {
        guard let r = run, r.id == id, r.readyAt == nil, !r.stopRequested else { return }
        r.timedOut = true
        signal(r)
    }

    private func exited(_ id: Int, status: Int32, signaled: Bool) async {
        guard let r = run, r.id == id else { return }
        // Let stderr drain briefly so the failure reason can quote the engine's last words.
        if let reader = r.stderrReader {
            await withTaskGroup(of: Void.self) { g in
                g.addTask { await reader.value }
                g.addTask { try? await Task.sleep(for: .milliseconds(500)) }
                await g.next()
                g.cancelAll()
            }
        }
        guard run === r else { return }
        run = nil
        timeoutTask?.cancel(); timeoutTask = nil
        removeTransientFiles(r)
        let waiters = r.exitWaiters
        r.exitWaiters = []
        defer { waiters.forEach { $0.resume() } }
        if r.stopRequested && !r.timedOut {
            state = .stopped
            return
        }
        if let readyAt = r.readyAt, ContinuousClock.now - readyAt >= policy.stableAfter { failures = 0 }
        let what: String
        if r.timedOut {
            what = "The analysis engine didn't start within \(Int(policy.readyTimeout.components.seconds)) s."
        } else if signaled {
            what = "The analysis engine stopped unexpectedly (signal \(status))."
        } else {
            what = "The analysis engine stopped unexpectedly (exit code \(status))."
        }
        failed(what)
    }

    private func failed(_ reason: String) {
        failures += 1
        guard let delay = policy.retryDelay(afterFailures: failures) else {
            let last = diagnostics.last.map { " Last message: \($0)" } ?? ""
            state = .failed(reason + last)
            return
        }
        state = .starting
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.retryTask != nil else { return }
            self.launch()
        }
    }

    private func removeTransientFiles(_ r: Run) {
        for f in r.spec.transientFiles { try? FileManager.default.removeItem(at: f) }
    }
}

/// Splits a byte stream into lines (LF or CRLF); not thread-safe, used from one readability handler.
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    static let maxLine = 64 * 1024

    func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var out: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            out.append(Self.decode(buffer[buffer.startIndex..<nl]))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        if buffer.count > Self.maxLine {
            out.append(Self.decode(buffer))
            buffer.removeAll()
        }
        return out
    }

    func finish() -> String? {
        defer { buffer.removeAll() }
        return buffer.isEmpty ? nil : Self.decode(buffer)
    }

    static func decode(_ d: Data) -> String {
        var s = String(decoding: d, as: UTF8.self)
        if s.hasSuffix("\r") { s.removeLast() }
        return s
    }
}
