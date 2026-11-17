import AppKit
import Combine
import RetraceCore

@MainActor
final class CodexScanner: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    @Published private(set) var report = ""
    private var process: Process?
    private var task: Task<Void, Never>?
    private var buffer = Data()
    private var cancelled = false
    /// Completed computer-use steps in the current scan.
    @Published private(set) var steps = 0
    /// True once Codex has been asked to stop exploring and write its report.
    @Published private(set) var isWrappingUp = false
    private lazy var overlay = ScanOverlay(scanner: self)
    /// Steer/interrupt/budget decisions; nil until the scan turn starts.
    private var governor: ScanGovernor?
    private var threadID: String?
    private var turnID: String?
    private var scanHost: String?
    /// Retrace ended the app server on purpose (budget or wrap-up), so a non-zero exit is not a failure.
    private var stoppedByGovernor = false
    private var declined: [String] = []
    private var failure: String?
    private var input: FileHandle?
    private var nextID = 0
    private var pending: [Int: String] = [:]
    private var scanConfiguration: [String: Any] = [:]
    private var scanPrompt = ""
    private var scanTarget = (bundleID: "", name: "")
    private var turnFinished = false

    /// `scope` is the user's optional focus area; it steers the prompt but never relaxes its rules.
    func start(app: NSRunningApplication, recorder: Recorder, targetURL: URL? = nil, scope: String? = nil,
               completed: @escaping (LocalSession?) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        cancelled = false
        steps = 0
        isWrappingUp = false
        governor = nil
        scanHost = targetURL?.host?.lowercased()
        declined = []
        failure = nil
        report = ""
        status = "Checking Codex computer use…"
        task = Task { [weak self] in
            guard let self else { return }
            var session: LocalSession?
            var endReason = ScanEndReason.error("The scan did not start.")
            do {
                guard let executable = CodexScan.executable() else {
                    throw APIError.invalidInput("Install and sign in to Codex CLI, then enable its computer-use MCP. Set RETRACE_CODEX_BIN for a custom installation.")
                }
                let listing = try await self.listConfiguration(executable, arguments: ["mcp", "list", "--json"])
                self.status = "Checking installed Codex plugins (this can take up to a minute)…"
                let plugins = try await self.listConfiguration(executable, arguments: ["plugin", "list", "--json"])
                let configuration = try CodexScan.configuration(servers: listing, plugins: plugins)
                try Task.checkCancellation()
                try await recorder.start(app: app, targetURL: targetURL)
                // Network opt-in may have relaunched the app; always use its current identity.
                guard let target = NSRunningApplication(processIdentifier: recorder.activeTargetPID) else {
                    throw APIError.invalidInput("The selected app is no longer running.")
                }
                self.status = "Codex is exploring \(target.localizedName ?? "the app")…"
                self.overlay.show(targetName: target.localizedName ?? "the app")
                await recorder.scanCheckpoint()
                let exit = try await self.run(executable, configuration: configuration, prompt: CodexScan.prompt(
                    name: target.localizedName ?? "App", bundleID: target.bundleIdentifier ?? "unknown", pid: target.processIdentifier, targetURL: targetURL, scope: scope),
                    target: (target.bundleIdentifier ?? "unknown", target.localizedName ?? "App"), recorder: recorder)
                let ended = self.endReason(exit: exit)
                endReason = ended
                recorder.scanReport = self.report.isEmpty ? nil : String("Scan ended (\(ended.label)): \(ended.summary)\n\n\(self.report)".prefix(12_000))
                session = await recorder.stop()
                if self.cancelled {
                    self.status = "Scan cancelled. Partial evidence saved for review."
                } else if !self.declined.isEmpty, self.steps == 0 {
                    self.status = "Computer use was not allowed to control \(target.localizedName ?? "the app"), so nothing was scanned. Start the scan again and choose Allow."
                } else if exit != 0 {
                    self.status = self.failure ?? "Codex stopped (exit \(exit)). Partial evidence saved. Check Codex sign-in and computer-use setup."
                } else if self.steps == 0 {
                    self.status = "No computer-use steps ran. Check the report and Codex computer-use setup; no functionality was verified."
                } else {
                    self.status = "Scan finished. \(ended.summary) Review partial coverage and evidence."
                }
            } catch {
                if recorder.isActive { session = await recorder.stop() }
                self.status = self.cancelled ? "Scan cancelled. Partial evidence saved." : error.localizedDescription
                endReason = self.cancelled ? .userStopped : .error(error.localizedDescription)
            }
            self.overlay.hide()
            self.governor = nil
            self.isWrappingUp = false
            self.process = nil
            self.task = nil
            self.isRunning = false
            if let session {
                let content = "# Codex exploratory scan\n\n\(self.status)\n\nScan ended: \(endReason.label). \(endReason.summary)\n\nCoverage: partial; unreachable, unsafe and hidden workflows are not verified.\n\n\(self.report)\n"
                let file = session.directory.appendingPathComponent("scan-report.md")
                do {
                    try Data(content.utf8).write(to: file, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                } catch { self.status += " Could not save coverage report: \(error.localizedDescription)" }
            }
            if session != nil { completed(session) }
        }
    }

    /// Ask Codex to stop exploring and write its report now, instead of `cancel()`, which loses it.
    func wrapUp() {
        guard isRunning else { return }
        guard let governor, threadID != nil, turnID != nil else { return cancel() }
        guard !governor.isWrappingUp else {
            status = "Already wrapping up; Codex is writing the report…"
            return
        }
        drive { $0.requestWrapUp(now: Date()) }
    }

    private func endReason(exit: Int32) -> ScanEndReason {
        let failure = failure ?? (exit != 0 ? "Codex stopped (exit \(exit))." : nil)
        return governor?.endReason(cancelled: cancelled, failure: failure)
            ?? (cancelled ? .userStopped : .error(failure ?? "Codex never started the scan turn."))
    }

    /// Applies a governor decision: steer, interrupt, report-only turn or stop the app server.
    private func perform(_ action: ScanGovernor.Action) {
        switch action {
        case .none: return
        case .steer(let text):
            isWrappingUp = true
            status = "Wrapping up: \(governor?.wrapUpReason?.detail ?? "finishing"). Codex is writing the report…"
            guard let threadID, let turnID else { return drive { $0.steerFailed(now: Date()) } }
            request("turn/steer", CodexScan.steerParams(threadId: threadID, turnId: turnID, text: text))
        case .interrupt:
            isWrappingUp = true
            status = "Codex did not wrap up in time; interrupting to collect the report…"
            guard let threadID, let turnID else { return perform(.terminate) }
            request("turn/interrupt", CodexScan.interruptParams(threadId: threadID, turnId: turnID))
        case .startReportTurn(let text):
            status = "Asking Codex for the final report…"
            guard let threadID else { return perform(.terminate) }
            request("turn/start", ["threadId": threadID, "input": [["type": "text", "text": text]]])
        case .terminate:
            stoppedByGovernor = true
            stopProcess()
        }
    }

    /// Runs one governor transition and performs the resulting action.
    private func drive(_ transition: (inout ScanGovernor) -> ScanGovernor.Action) {
        guard var governor else { return }
        let action = transition(&governor)
        self.governor = governor
        perform(action)
    }

    func cancel() {
        cancelled = true
        status = "Stopping Codex and saving partial evidence…"
        task?.cancel()
        stopProcess()
    }

    private func stopProcess() {
        guard let process, process.isRunning else { return }
        process.terminate()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private static var cliEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        return environment
    }

    private func listConfiguration(_ executable: URL, arguments: [String]) async throws -> Data {
        let result = try await CloneCommand().run(executable: executable, arguments: arguments,
            directory: FileManager.default.temporaryDirectory,
            timeout: arguments.first == "plugin" ? 60 : 15, captureStandardError: false)
        guard result.status == 0 else {
            throw APIError.invalidInput("codex \(arguments.joined(separator: " ")) failed (exit \(result.status)). Check Codex sign-in and configuration.")
        }
        return Data(result.text.utf8)
    }

    private func run(_ executable: URL, configuration: [String: Any], prompt: String,
                     target: (bundleID: String, name: String), recorder: Recorder) async throws -> Int32 {
        let process = Process()
        let output = Pipe(), input = Pipe()
        process.executableURL = executable
        process.arguments = CodexScan.arguments()
        process.environment = Self.cliEnvironment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        buffer = Data()
        nextID = 0
        pending = [:]
        turnFinished = false
        stoppedByGovernor = false
        threadID = nil
        turnID = nil
        scanConfiguration = configuration
        scanPrompt = prompt
        scanTarget = target
        self.input = input.fileHandleForWriting
        output.fileHandleForReading.readabilityHandler = { [weak self, weak recorder] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in
                guard let self, let recorder else { return }
                self.consume(chunk, recorder: recorder)
            }
        }
        self.process = process
        // A late reply after Codex exits must fail the write, not terminate Retrace.
        signal(SIGPIPE, SIG_IGN)
        try process.run()
        request("initialize", ["clientInfo": ["name": "retrace", "title": "Retrace", "version": "1"],
                               "capabilities": ["experimentalApi": true]])
        while process.isRunning {
            if Task.isCancelled { stopProcess() }
            drive { $0.tick(now: Date()) }
            try? await Task.sleep(for: .milliseconds(150))
        }
        output.fileHandleForReading.readabilityHandler = nil
        consume(output.fileHandleForReading.readDataToEndOfFile(), recorder: recorder)
        if !buffer.isEmpty { consume(Data([10]), recorder: recorder) }
        try? self.input?.close()
        self.input = nil
        // The app server is stopped on purpose once the turn ends or a budget runs out; that is a clean finish.
        return turnFinished || stoppedByGovernor ? 0 : process.terminationStatus
    }

    private func send(_ message: [String: Any]) {
        var object = message
        object["jsonrpc"] = "2.0"
        guard let input, process?.isRunning == true,
              var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(10)
        try? input.write(contentsOf: data)
    }

    private func request(_ method: String, _ params: [String: Any]) {
        nextID += 1
        pending[nextID] = method
        send(["id": nextID, "method": method, "params": params])
    }

    private func consume(_ data: Data, recorder: Recorder) {
        buffer.append(data)
        // A tool response can be large; only retain complete JSON lines within a bounded buffer.
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(message, recorder: recorder)
        }
        if buffer.count > 2_000_000 { buffer.removeAll() }
    }

    private func handle(_ message: [String: Any], recorder: Recorder) {
        let method = message["method"] as? String
        let params = message["params"] as? [String: Any] ?? [:]
        if let method, let id = message["id"] {
            serverRequest(id: id, method: method, params: params)
            return
        }
        if method == nil, let id = message["id"] as? Int, let call = pending.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                // A rejected steer (turn already ending) falls back to interrupt; a rejected interrupt to terminate.
                if call == "turn/steer" { return drive { $0.steerFailed(now: Date()) } }
                if call == "turn/interrupt" { return perform(.terminate) }
                // The scan turn already ran; only the report-only follow-up turn was refused.
                if call == "turn/start", governor != nil { return perform(.terminate) }
                failure = "Codex could not start the scan: \(error["message"] as? String ?? call)"
                stopProcess()
                return
            }
            let result = message["result"] as? [String: Any] ?? [:]
            switch call {
            case "initialize":
                send(["method": "initialized"])
                request("model/list", [:])
            case "model/list":
                let model = CodexScan.model()
                request("thread/start", CodexScan.threadStartParams(
                    configuration: scanConfiguration, cwd: FileManager.default.temporaryDirectory.path,
                    model: model, serviceTier: CodexScan.fastestServiceTier(models: result, model: model)))
            case "thread/start":
                guard let thread = (result["thread"] as? [String: Any])?["id"] as? String else {
                    failure = "Codex did not create a scan thread."
                    stopProcess()
                    return
                }
                threadID = thread
                request("turn/start", ["threadId": thread, "input": [["type": "text", "text": scanPrompt]]])
            case "turn/start":
                if let id = (result["turn"] as? [String: Any])?["id"] as? String { turnID = id }
                if governor == nil {
                    governor = ScanGovernor(coverage: ScanCoverage(host: scanHost))
                }
            default: break
            }
            return
        }
        guard let method, let event = CodexScan.event(method: method, params: params) else { return }
        if let id = event.turnID { turnID = id }
        // Keep the wrap-up notice visible rather than overwriting it with step titles.
        if let message = event.message, !isWrappingUp || event.finished != nil { status = String(message.prefix(500)) }
        if let text = event.report { report = String(text.prefix(100_000)) }
        if event.checkpoint {
            Task { await recorder.scanCheckpoint() }
        }
        guard var governor else {
            if event.checkpoint { steps += 1 }
            if event.finished != nil { turnFinished = true; stopProcess() }
            return
        }
        var action = ScanGovernor.Action.none
        if let commentary = event.commentary { governor.observe(commentary: commentary) }
        if event.toolStarted { action = governor.toolStarted() }
        if let tool = event.tool {
            action = governor.observe(tool, now: Date())
            steps = governor.steps
        }
        if let finished = event.finished {
            if finished == "failed" { failure = event.message.map { "Codex scan failed: \($0)" } ?? "Codex scan failed." }
            action = governor.turnCompleted(status: finished, hasReport: !report.isEmpty, now: Date())
            if action == .terminate { turnFinished = true }
        }
        self.governor = governor
        perform(action)
    }

    private func serverRequest(id: Any, method: String, params: [String: Any]) {
        guard method == "mcpServer/elicitation/request" else {
            send(["id": id, "error": ["code": -32601, "message": "Retrace scans do not grant \(method)."]])
            return
        }
        let approval = CodexScan.approvalRequest(params)
        switch CodexScan.decision(for: approval, target: scanTarget.bundleID, name: scanTarget.name) {
        case .decline(let reason):
            declined.append(reason)
            status = reason
            send(["id": id, "result": ["action": "decline"]])
        case .askUser:
            status = "Waiting for you to allow computer use…"
            let allowed = askUser(approval)
            if allowed {
                var result: [String: Any] = ["action": "accept", "content": [String: Any]()]
                if approval.canPersistForSession { result["_meta"] = ["persist": "session"] }
                send(["id": id, "result": result])
                status = "Codex is exploring \(scanTarget.name)…"
            } else {
                declined.append(approval.message)
                status = "You declined computer use for \(approval.app ?? scanTarget.name)."
                send(["id": id, "result": ["action": "decline"]])
            }
        }
    }

    /// Codex computer use needs explicit consent per app; headless runs used to decline this silently.
    private func askUser(_ approval: CodexScan.ApprovalRequest) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = approval.message
        alert.informativeText = [
            "Retrace's scan asks Codex computer use to operate \(scanTarget.name). Allowing it applies to this scan only.",
            approval.detail,
        ].compactMap { $0 }.joined(separator: "\n\n")
        alert.addButton(withTitle: "Allow for This Scan")
        alert.addButton(withTitle: "Don't Allow")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
