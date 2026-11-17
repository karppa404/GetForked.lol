import AppKit
import Darwin
import RetraceCore
import SwiftUI

enum NetworkCaptureFailure: LocalizedError {
    case cancelled
    case helperMissing
    case proxyFailed(String)
    case relaunchFailed(String)
    var errorDescription: String? {
        switch self {
        case .cancelled: return "Recording cancelled."
        case .helperMissing: return "Network capture helper (network-helper/retrace_capture.py) not found. Set RETRACE_NETWORK_HELPER to its folder."
        case .proxyFailed(let m): return "Could not start the capture proxy: \(m)"
        case .relaunchFailed(let m): return m
        }
    }
}

/// Per-recording network capture for Electron/Chromium apps, including Chromium browsers
/// used for SaaS web scans (Chrome, Edge, Brave, Arc, Helium…).
///
/// With the user's confirmation it starts `mitmdump` with network-helper/retrace_capture.py
/// on a free loopback port, quits the target app and reopens it with
/// `--proxy-server=127.0.0.1:<port> --ignore-certificate-errors-spki-list=<capture CA pin>`.
/// Only that process is proxied, and it trusts only the capture CA's key; system proxy
/// settings and the keychain are never touched, and mitmproxy still verifies upstream TLS.
/// On stop the redacted JSONL is merged into the manifest and deleted, and the user is
/// offered to reopen the app without the proxy.
///
/// For a web scan the browser is reopened with its same profile (so cookies and sign-ins
/// survive) and its last session restored, and only the scan target's site is recorded;
/// every other host is tunneled undecrypted. When capture can't run (Safari, Firefox, a
/// native app, mitmproxy missing, declined) `skipNote` says why and lands in the manifest.
@MainActor
final class NetworkCaptureController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting(String)
        case capturing(app: String, port: Int, hosts: [String])
    }

    @Published private(set) var phase: Phase = .idle
    /// Why the current/last recording has no network capture; nil while capture runs.
    @Published private(set) var skipNote: String?

    private var process: Process?
    private var outputURL: URL?
    private var log = Data()
    private var proxied: (app: NSRunningApplication, bundleURL: URL, name: String, restoreArguments: [String])?
    private var terminateObserver: NSObjectProtocol?

    init() {
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopProxy(deleteOutput: true) }
        }
    }

    var isCapturing: Bool { if case .capturing = phase { return true } else { return false } }

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Retrace/NetworkCapture", isDirectory: true)
    }

    // MARK: Start

    /// Returns the app instance to record: `app` itself when network capture is not used,
    /// or the relaunched, proxied instance. Throws `.cancelled` if the user cancels.
    /// `targetURL` marks a SaaS web scan in a browser: capture is scoped to its site.
    func prepare(_ app: NSRunningApplication, targetURL: URL? = nil) async throws -> NSRunningApplication {
        skipNote = nil
        guard phase == .idle else { return app }
        let name = app.localizedName ?? app.bundleIdentifier ?? "The app"
        guard let bundleURL = app.bundleURL, let bundleId = app.bundleIdentifier else {
            skipNote = "\(name) has no app bundle, so it can't be relaunched through the capture proxy."
            return app
        }
        let web = targetURL != nil
        let without = web ? "Scan Without Network" : "Record Without Network"
        let hosts: [String]
        switch NetworkCapturePlan.make(runtime: AppRuntimeDetector.detect(bundleURL: bundleURL), appName: name,
                                       bundleId: bundleId, targetURL: targetURL) {
        case .unavailable(let reason):
            skipNote = reason
            // A web scan is where the user expects endpoints: say so before scanning.
            if web, Self.ask("API endpoints can't be recorded in \(name)", reason
                             + "\n\nThe scan can still record screens and interactions; the session will note why network wasn't captured.",
                             [without, "Cancel"]) != 0 { throw NetworkCaptureFailure.cancelled }
            return app
        case .capture(let h): hosts = h
        }

        guard let mitmdump = MitmproxyLocator.find() else {
            skipNote = "mitmproxy (mitmdump) is not installed, so network requests were not captured. Install it with: \(MitmproxyLocator.installHint)"
            switch Self.ask("Network capture needs mitmproxy",
                            "\(name) can be recorded with its API requests, but mitmdump was not found. Install it, then record again:\n\n    \(MitmproxyLocator.installHint)",
                            [without, "Copy Install Command", "Cancel"]) {
            case 0: return app
            case 1:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(MitmproxyLocator.installHint, forType: .string)
                throw NetworkCaptureFailure.cancelled
            default: throw NetworkCaptureFailure.cancelled
            }
        }
        let consent: (title: String, message: String)
        if web {
            let scope = hosts.joined(separator: ", ")
            consent = ("Record \(scope) API calls in \(name)?",
                       "Retrace will quit \(name) (all of its windows) and reopen it with the same profile, so you stay signed in and your tabs are restored. Finish anything unsaved first.\n\n"
                       + "While the scan runs, \(name) goes through a local proxy on this Mac. Only requests to \(scope) and its subdomains are recorded, redacted: tokens, cookies and bodies are never stored. Other sites pass through without being decrypted. System proxy and certificate settings are not changed.\n\n"
                       + "\(name) may show a warning about an unsupported command-line flag; that is the capture certificate pin and goes away when Retrace reopens \(name) normally after the scan.")
        } else {
            consent = ("Capture \(name)'s network requests?",
                       "Retrace will quit \(name) and reopen it through a local proxy on this Mac so its API calls are recorded (redacted: tokens, cookies and bodies are never stored). Only \(name) is proxied; system proxy and certificate settings are not changed.")
        }
        switch Self.ask(consent.title, consent.message, [web ? "Relaunch \(name) & Capture" : "Relaunch & Capture", without, "Cancel"]) {
        case 0: break
        case 1:
            skipNote = "Network capture was declined for this recording."
            return app
        default: throw NetworkCaptureFailure.cancelled
        }
        guard let addon = Self.locateAddon() else { throw NetworkCaptureFailure.helperMissing }

        // Browsers keep their profile and get their tabs back on both relaunches.
        let current = Self.processArguments(pid: app.processIdentifier) ?? []
        let extra = web || Self.isBrowser(bundleURL) ? ProxyLaunch.browserRelaunchArguments(currentArguments: current) : []
        phase = .starting("Starting capture proxy…")
        do {
            let (port, spki) = try await startProxy(mitmdump: mitmdump, addon: addon, hosts: hosts)
            let args = try ProxyLaunch.arguments(port: port, spkiHash: spki) + extra
            phase = .starting("Relaunching \(name) through the proxy…")
            let relaunched = try await Self.relaunch(app, bundleURL: bundleURL, arguments: args, verify: true)
            proxied = (relaunched, bundleURL, name, extra)
            phase = .starting("Waiting for \(name)'s window…")
            await Self.waitForWindow(pid: relaunched.processIdentifier, timeout: 45)
            phase = .capturing(app: name, port: port, hosts: NetworkCaptureHosts.normalize(hosts))
            return relaunched
        } catch {
            stopProxy(deleteOutput: true)
            phase = .idle
            if proxied != nil { offerRestore() }
            throw error
        }
    }

    /// Apps that open web links (Chrome, Helium…), as opposed to Electron/CEF apps.
    private static func isBrowser(_ bundleURL: URL) -> Bool {
        guard let probe = URL(string: "https://example.com") else { return false }
        let target = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        return NSWorkspace.shared.urlsForApplications(toOpen: probe).contains { $0.resolvingSymlinksInPath().standardizedFileURL == target }
    }

    private func startProxy(mitmdump: String, addon: URL, hosts: [String]) async throws -> (Int, String) {
        let dir = Self.supportDirectory
        let conf = dir.appendingPathComponent("mitmproxy", isDirectory: true)
        for d in [dir, conf] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: d.path)
        }
        let out = dir.appendingPathComponent("capture-\(UUID().uuidString.lowercased()).jsonl")
        guard let port = Self.freeLoopbackPort() else { throw NetworkCaptureFailure.proxyFailed("no free port") }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: mitmdump)
        p.arguments = MitmproxyLocator.mitmdumpArguments(port: port, confDir: conf.path, addon: addon.path, output: out.path, hosts: hosts)
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        log = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            Task { @MainActor in
                guard let self, self.log.count < 16_384 else { return }
                self.log.append(chunk)
            }
        }
        try p.run()
        process = p
        outputURL = out

        let ca = conf.appendingPathComponent("mitmproxy-ca-cert.pem")
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            guard p.isRunning else {
                let tail = String(decoding: log.suffix(600), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw NetworkCaptureFailure.proxyFailed(tail.isEmpty ? "mitmdump exited (\(p.terminationStatus))" : tail)
            }
            if FileManager.default.fileExists(atPath: ca.path), Self.canConnect(port: port) {
                let pem = try String(contentsOf: ca, encoding: .utf8)
                return (port, try SPKI.sha256Base64(certificatePEM: pem))
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        throw NetworkCaptureFailure.proxyFailed("mitmdump did not start listening within 20 s")
    }

    // MARK: Stop

    /// Stops the proxy and returns the session's network evidence, or nil when no capture ran
    /// for this recording (the manifest then stays `not_captured`).
    func finish(startedAt: String, durationMs: Int) async -> [NetworkEvent]? {
        guard process != nil, let out = outputURL else { return nil }
        if let p = process, p.isRunning {
            p.interrupt()
            let deadline = Date().addingTimeInterval(3)
            while p.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        }
        let data = (try? Data(contentsOf: out)) ?? Data()
        stopProxy(deleteOutput: true)
        phase = .idle
        return NetworkEvidenceExport.events(fromJSONL: data, startedAt: startedAt, durationMs: durationMs)
    }

    /// Called when recording could not start after the app was relaunched.
    func abort() {
        stopProxy(deleteOutput: true)
        phase = .idle
        offerRestore()
    }

    private func stopProxy(deleteOutput: Bool) {
        if let p = process {
            (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if p.isRunning { p.terminate() }
            let pid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        }
        process = nil
        if deleteOutput, let out = outputURL { try? FileManager.default.removeItem(at: out) }
        outputURL = nil
    }

    /// The proxied app cannot reach the network once the proxy stops; offer a normal relaunch.
    func offerRestore() {
        guard let p = proxied else { return }
        proxied = nil
        guard !p.app.isTerminated else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            let tabs = p.restoreArguments.isEmpty ? "" : " Your profile and tabs are kept."
            let choice = Self.ask("Reopen \(p.name) without the proxy?",
                                  "Network capture has stopped, so \(p.name) can't reach the network until it is reopened normally.\(tabs)",
                                  ["Reopen Normally", "Not Now"])
            guard choice == 0 else { return }
            _ = try? await Self.relaunch(p.app, bundleURL: p.bundleURL, arguments: p.restoreArguments, verify: false)
        }
    }

    // MARK: App relaunch

    private static func relaunch(_ app: NSRunningApplication, bundleURL: URL, arguments: [String], verify: Bool) async throws -> NSRunningApplication {
        let name = app.localizedName ?? "The app"
        let bundleId = app.bundleIdentifier ?? ""
        for attempt in 0..<2 {
            for running in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) { running.terminate() }
            guard await waitForExit(bundleId: bundleId, bundleURL: bundleURL, timeout: 20) else {
                throw NetworkCaptureFailure.relaunchFailed("\(name) did not quit. Quit it yourself, then record again.")
            }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.arguments = arguments
            cfg.activates = true
            cfg.addsToRecentItems = false
            let launched: NSRunningApplication
            do { launched = try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: cfg) }
            catch { throw NetworkCaptureFailure.relaunchFailed("Could not reopen \(name): \(error.localizedDescription)") }
            guard verify else { return launched }
            try? await Task.sleep(for: .milliseconds(500))
            if let argv = processArguments(pid: launched.processIdentifier), ProxyLaunch.hasProxyFlags(argv) { return launched }
            if attempt == 0 { continue }  // handed to a still-exiting instance; quit and try once more
        }
        throw NetworkCaptureFailure.relaunchFailed("\(name) reopened without the proxy settings, so its traffic can't be captured.")
    }

    /// Waits until no app with the bundle id and no process from inside the bundle remains.
    private static func waitForExit(bundleId: String, bundleURL: URL, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let prefix = bundleURL.resolvingSymlinksInPath().path + "/"
        while Date() < deadline {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).filter { !$0.isTerminated }
            if apps.isEmpty, !pidsExecuting(under: prefix) {
                try? await Task.sleep(for: .milliseconds(300))
                return true
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private static func waitForWindow(pid: pid_t, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            if info.contains(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }) {
                try? await Task.sleep(for: .milliseconds(500))
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: Low-level helpers

    private static func pidsExecuting(under prefix: String) -> Bool {
        var pids = [pid_t](repeating: 0, count: 8192)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return false }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(n)) where pid > 0 {
            if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0, String(cString: buf).hasPrefix(prefix) { return true }
        }
        return false
    }

    static func processArguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return ProcArgs.parse(Data(buf.prefix(size)))
    }

    private static func freeLoopbackPort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        return ok ? Int(UInt16(bigEndian: addr.sin_port)) : nil
    }

    private static func canConnect(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    /// network-helper/retrace_capture.py, which imports backend/retrace/redaction.py via
    /// `../backend`. Looked up in: $RETRACE_NETWORK_HELPER, the app's Resources (bundled
    /// layout Resources/network-helper + Resources/backend/retrace), the source checkout this
    /// copy was built from, and folders above the app bundle.
    static func locateAddon() -> URL? {
        var dirs: [URL] = []
        if let env = ProcessInfo.processInfo.environment["RETRACE_NETWORK_HELPER"] { dirs.append(URL(fileURLWithPath: env)) }
        if let res = Bundle.main.resourceURL { dirs.append(res.appendingPathComponent("network-helper")) }
        // macos/Sources/Retrace/<this file> → repository root.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        dirs.append(repo.appendingPathComponent("network-helper"))
        var up = Bundle.main.bundleURL
        for _ in 0..<4 { up.deleteLastPathComponent(); dirs.append(up.appendingPathComponent("network-helper")) }
        let fm = FileManager.default
        return dirs.lazy.map { $0.appendingPathComponent("retrace_capture.py") }.first { addon in
            fm.fileExists(atPath: addon.path) && fm.fileExists(atPath: addon.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("backend/retrace/redaction.py").path)
        }
    }

    /// Returns the index of the chosen button (first is the default).
    private static func ask(_ title: String, _ message: String, _ buttons: [String]) -> Int {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        for b in buttons { alert.addButton(withTitle: b) }
        if buttons.last == "Cancel" { alert.buttons.last?.keyEquivalent = "\u{1b}" }
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }
}

/// One-line capture status for the recorder panel: progress while capture starts or runs,
/// and why the current/last recording has no network capture.
struct NetworkCaptureStatusView: View {
    @ObservedObject var controller: NetworkCaptureController

    var body: some View {
        switch controller.phase {
        case .idle:
            if let note = controller.skipNote {
                Label("Network not captured: \(note)", systemImage: "network.slash")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        case .starting(let step):
            Label(step, systemImage: "network").font(.caption).foregroundStyle(.secondary)
        case .capturing(let app, _, let hosts):
            Label(hosts.isEmpty ? "Capturing \(app)'s network requests through a local proxy (redacted)"
                                : "Capturing \(hosts.joined(separator: ", ")) requests in \(app) through a local proxy (redacted)",
                  systemImage: "network")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
