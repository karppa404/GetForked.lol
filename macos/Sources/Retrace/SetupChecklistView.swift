import AppKit
import RetraceCore
import SwiftUI

/// Runs the Codex-side setup checks off the main thread, with timeouts, and keeps the last
/// answers. Permissions and the analysis engine are read live from `PermissionMonitor` and
/// `AppModel`. Results are re-read when a Retrace window (the panel) becomes key, at most once a
/// minute, and on Re-check.
@MainActor
final class SetupChecker: ObservableObject {
    static let shared = SetupChecker()
    static let codexBundleID = "com.openai.codex"

    @Published private(set) var codex: [SetupItem: SetupCheck] =
        [.codexCLI: .checking, .subscription: .checking, .computerUse: .checking, .browser: .checking]
    @Published private(set) var isChecking = false
    /// The user opened the checklist from the panel header.
    @Published var requested = false

    private var lastRun: Date?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshIfStale() }
            })
        }
        recheck()
    }

    func refreshIfStale(maxAge: TimeInterval = 60) {
        if let lastRun, Date().timeIntervalSince(lastRun) < maxAge { return }
        recheck()
    }

    /// Keeps the previous answers on screen while checking, so the gate doesn't flicker.
    func recheck() {
        guard !isChecking else { return }
        isChecking = true
        lastRun = Date()
        Task {
            let results = await Task.detached(priority: .userInitiated) { await SetupProbe.run() }.value
            self.codex = results
            self.isChecking = false
        }
    }

    /// Whether the panel shows the checklist instead of its content (see `SetupChecklist.shouldShow`).
    func shouldShow(model: AppModel, permissions: PermissionMonitor, completed: Bool, scanning: Bool) -> Bool {
        SetupChecklist.shouldShow(checks(permissions: permissions, model: model), completed: completed,
                                  requested: requested, scanning: scanning)
    }

    func checks(permissions: PermissionMonitor, model: AppModel) -> [SetupItem: SetupCheck] {
        var all = codex
        all[.permissions] = SetupChecklist.permissionsCheck(accessibility: permissions.accessibility,
                                                            screenRecording: permissions.screenRecording)
        var failure: String?
        if case .failed(let reason) = model.serverState { failure = reason }
        all[.analysis] = SetupChecklist.analysisCheck(serverReady: model.isServerReady, failure: failure,
                                                      analysisConfigured: model.health?.analysisConfigured)
        return all
    }
}

/// The Codex probes themselves. Nothing here starts a model turn, so no tokens are spent.
enum SetupProbe {
    static func run() async -> [SetupItem: SetupCheck] {
        let browsers = browserCheck()
        guard let codex = CodexScan.executable() else {
            let none = SetupCheck.missing("Needs the Codex CLI.")
            return [.codexCLI: SetupChecklist.cliCheck(executable: nil, login: nil),
                    .subscription: none, .computerUse: none, .browser: browsers]
        }
        async let login = runProcess(codex, ["login", "status"], timeout: 10)
        async let servers = runProcess(codex, ["mcp", "list", "--json"], timeout: 15)
        async let account = AppServerProbe(executable: codex, timeout: 15).run()
        let loginOutput = await login
        let parsed = loginOutput.map {
            SetupChecklist.login(exitCode: $0.status, output: String(decoding: $0.stderr + $0.stdout, as: UTF8.self))
        }
        let serverOutput = await servers
        let probe = await account
        return [
            .codexCLI: SetupChecklist.cliCheck(executable: codex, login: parsed),
            .subscription: SetupChecklist.subscriptionCheck(account: probe.account, rateLimits: probe.rateLimits, error: probe.error),
            .computerUse: SetupChecklist.computerUseCheck(servers: serverOutput.flatMap { $0.status == 0 ? $0.stdout : nil }),
            .browser: browsers,
        ]
    }

    /// Installed browsers (any app that opens https links) against Codex computer use's "Always allow" list.
    static func browserCheck() -> SetupCheck {
        var installed: [String: String] = [:]
        for url in NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!) {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            installed[id] = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return SetupChecklist.browserCheck(installed: installed, approved: CodexScan.approvedBundleIDs())
    }

    struct Output {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    /// nil if it couldn't start or didn't exit within `timeout` (then it's killed).
    static func runProcess(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async -> Output? {
        let dir = FileManager.default.temporaryDirectory
        let out = dir.appendingPathComponent("retrace-setup-\(UUID().uuidString).out")
        let err = dir.appendingPathComponent("retrace-setup-\(UUID().uuidString).err")
        for file in [out, err] { FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        defer { for file in [out, err] { try? FileManager.default.removeItem(at: file) } }
        guard let outHandle = try? FileHandle(forWritingTo: out), let errHandle = try? FileHandle(forWritingTo: err) else { return nil }
        defer { try? outHandle.close(); try? errHandle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = outHandle
        process.standardError = errHandle
        process.standardInput = FileHandle.nullDevice
        let exited = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let once = Once()
            process.terminationHandler = { _ in once.run { done.resume(returning: true) } }
            do { try process.run() } catch { return once.run { done.resume(returning: false) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.run {
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                    done.resume(returning: false)
                }
            }
        }
        guard exited else { return nil }
        return Output(status: process.terminationStatus, stdout: (try? Data(contentsOf: out)) ?? Data(),
                      stderr: (try? Data(contentsOf: err)) ?? Data())
    }
}

/// Runs a block at most once, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ block: () -> Void) {
        lock.lock()
        guard !done else { return lock.unlock() }
        done = true
        lock.unlock()
        block()
    }
}

/// Asks `codex app-server` for the signed-in account and its Codex usage (`account/read`,
/// `account/rateLimits/read`), then stops it. No thread or turn is started.
final class AppServerProbe: @unchecked Sendable {
    struct Result {
        var account: [String: Any]?
        var rateLimits: [String: Any]?
        var error: String?
    }

    private let executable: URL
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var buffer = Data()
    private var result = Result()
    private var answered = 0
    private let once = Once()

    init(executable: URL, timeout: TimeInterval) {
        self.executable = executable
        self.timeout = timeout
    }

    func run() async -> Result {
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let requests = SetupChecklist.accountRequests()
        let timeout = self.timeout
        return await withCheckedContinuation { (done: CheckedContinuation<Result, Never>) in
            let finish: @Sendable (String?) -> Void = { [self] error in
                once.run {
                    output.fileHandleForReading.readabilityHandler = nil
                    try? input.fileHandleForWriting.close()
                    if process.isRunning { process.terminate() }
                    let result = lock.withLock { () -> Result in
                        var r = self.result
                        if r.account == nil { r.error = r.error ?? error }
                        return r
                    }
                    done.resume(returning: result)
                }
            }
            @Sendable func send(_ message: [String: Any]) {
                var object = message
                object["jsonrpc"] = "2.0"
                guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
                data.append(10)
                try? input.fileHandleForWriting.write(contentsOf: data)
            }
            output.fileHandleForReading.readabilityHandler = { [self] handle in
                let chunk = handle.availableData
                if chunk.isEmpty { return finish("Codex app-server exited before answering.") }
                for line in lines(chunk) {
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          message["method"] == nil, let id = message["id"] as? Int else { continue }
                    if id == 1 {
                        if let error = message["error"] as? [String: Any] {
                            return finish("Codex app-server refused to start: \(error["message"] as? String ?? "unknown error")")
                        }
                        send(["method": "initialized"])
                        for (i, request) in requests.enumerated() {
                            send(["id": i + 2, "method": request.method, "params": request.params])
                        }
                        continue
                    }
                    let value = message["result"] as? [String: Any]
                    let error = (message["error"] as? [String: Any])?["message"] as? String
                    let complete = lock.withLock { () -> Bool in
                        if id == 2 {
                            result.account = value
                            if value == nil { result.error = "Codex couldn't read the account: \(error ?? "no answer")" }
                        }
                        if id == 3 { result.rateLimits = value }
                        answered += 1
                        return answered >= requests.count
                    }
                    if complete { return finish(nil) }
                }
            }
            process.terminationHandler = { _ in
                // Let any final output drain through the handler first.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { finish("Codex app-server exited before answering.") }
            }
            // A reply after Codex exits must fail the write, not terminate Retrace.
            signal(SIGPIPE, SIG_IGN)
            do { try process.run() } catch { return finish("Couldn't start codex app-server: \(error.localizedDescription)") }
            send(["id": 1, "method": "initialize",
                  "params": ["clientInfo": ["name": "retrace", "title": "Retrace", "version": "1"]]])
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish("Codex app-server didn't answer within \(Int(timeout)) s.")
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }

    /// Complete lines from the stream; a partial line waits for the next chunk.
    private func lines(_ chunk: Data) -> [Data] {
        lock.withLock {
            buffer.append(chunk)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 10) {
                lines.append(Data(buffer[..<newline]))
                buffer.removeSubrange(...newline)
            }
            if buffer.count > 4_000_000 { buffer.removeAll() }
            return lines
        }
    }
}

// MARK: - View

/// First-run setup checklist, shown in place of the panel's content until every item passes.
struct SetupChecklistView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var setup = SetupChecker.shared
    @ObservedObject private var permissions = PermissionMonitor.shared
    @AppStorage(SetupChecklist.completedKey) private var completed = false

    var body: some View {
        let checks = setup.checks(permissions: permissions, model: model)
        let passed = SetupChecklist.allPassed(checks)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(completed ? "Setup checklist" : "Set up Retrace").font(.headline)
                Text(passed ? "Everything a scan needs is ready." : "Fix anything missing, then press Re-check.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(SetupItem.allCases) { item in
                        row(item, checks[item] ?? .checking)
                    }
                }
            }
            HStack {
                Button {
                    setup.recheck()
                    permissions.refresh()
                    model.refreshHealth()
                } label: {
                    Label(setup.isChecking ? "Checking…" : "Re-check", systemImage: "arrow.clockwise")
                }
                .disabled(setup.isChecking)
                Spacer()
                Button("Continue") {
                    completed = true
                    setup.requested = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(!passed)
                .help(passed ? "Open Retrace" : "Every item must pass first")
            }
        }
        .padding(14)
        .frame(height: MenuContent.detailHeight)
        .onAppear { setup.refreshIfStale() }
    }

    private func row(_ item: SetupItem, _ check: SetupCheck) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                switch check.status {
                case .checking: ProgressView().controlSize(.mini)
                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .missing: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.caption.bold())
                Text(item.why).font(.caption2).foregroundStyle(.secondary)
                if let detail = check.detail {
                    Text(detail).font(.caption2)
                        .foregroundStyle(check.status == .missing ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .textSelection(.enabled)
                }
                if check.status == .missing { fix(item, check) }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.title): \(statusText(check.status))")
    }

    private func statusText(_ status: SetupStatus) -> String {
        switch status {
        case .checking: return "checking"
        case .ok: return "ready"
        case .missing: return "missing"
        }
    }

    @ViewBuilder private func fix(_ item: SetupItem, _ check: SetupCheck) -> some View {
        switch item {
        case .codexCLI:
            if CodexScan.executable() == nil {
                hint("Install the Codex CLI in Terminal, then Re-check:")
                CommandRow(command: SetupChecklist.installCommand)
            } else {
                hint("Sign in with ChatGPT in Terminal, then Re-check:")
                CommandRow(command: SetupChecklist.loginCommand)
            }
            terminalButton
        case .subscription:
            if check.detail?.contains("usage limit") == true {
                hint("Wait for the reset, or add usage to your plan.")
                Button("ChatGPT Plans") { open("https://chatgpt.com/pricing") }.controlSize(.small)
            } else {
                hint("Scans need a ChatGPT sign-in with a plan that includes Codex:")
                CommandRow(command: SetupChecklist.loginCommand)
            }
        case .computerUse:
            hint("Turn on computer use in Codex, then Re-check. `codex mcp list` should show it enabled.")
            HStack(spacing: 6) { codexButton; terminalButton }
        case .browser:
            hint("Open Codex, ask it to use your browser, choose Always allow, then Re-check.")
            codexButton
        case .permissions:
            permissionRow("Accessibility", granted: permissions.accessibility,
                          request: permissions.requestAccessibility, settings: Permissions.openAccessibilitySettings)
            permissionRow("Screen Recording", granted: permissions.screenRecording,
                          request: permissions.requestScreenRecording, settings: permissions.openScreenRecordingSettings)
            if !permissions.screenRecording && permissions.screenRecordingMayNeedRelaunch {
                HStack(spacing: 6) {
                    Text("Already turned on Screen Recording? Relaunch Retrace to apply it.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Relaunch") { PermissionMonitor.relaunch() }.controlSize(.small)
                }
            }
        case .analysis:
            if case .failed = model.serverState {
                Button("Retry Engine") { model.retryServer() }.controlSize(.small)
            } else {
                hint("Add your NVIDIA API key to the Keychain (paste it at the prompt), then restart the engine:")
                CommandRow(command: SetupChecklist.addKeyCommand)
                HStack(spacing: 6) {
                    Button("Restart Engine") { model.retryServer() }.controlSize(.small)
                    terminalButton
                }
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(.init(text)).font(.caption2).fixedSize(horizontal: false, vertical: true)
    }

    private func permissionRow(_ name: String, granted: Bool, request: @escaping () -> Void,
                               settings: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            Text(name).font(.caption2)
            Spacer(minLength: 0)
            if !granted {
                Button("Request") { request() }.controlSize(.small)
                Button("Settings") { settings() }.controlSize(.small)
            }
        }
    }

    @ViewBuilder private var codexButton: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SetupChecker.codexBundleID) {
            Button("Open Codex") { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }.controlSize(.small)
        }
    }

    private var terminalButton: some View {
        Button("Open Terminal") {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
        }
        .controlSize(.small)
    }

    private func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}

/// A shell command to copy, in monospace, with a Copy button.
struct CommandRow: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(command)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy command")
            .accessibilityLabel("Copy \(command)")
        }
        .padding(6)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
