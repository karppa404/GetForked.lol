import AppKit
import Combine
import RetraceCore
import SwiftUI

enum ConnectionPhase: Equatable {
    case disconnected, connecting, connected
    case failed(String)
}

/// App-wide state: the analysis engine (launched and supervised here), this Mac's device credential
/// for it, model settings, local sessions and explicit uploads.
@MainActor
final class AppModel: ObservableObject {
    static let defaultsDeviceNameKey = "deviceName"
    static let defaultsModelSettingsKey = "modelSettings"
    static let apiKeyAccount = "nemotron"

    /// Shown in the engine's device list. A name saved by older versions is still used.
    let deviceName: String
    @Published private(set) var serverLocation: ServerLocation = .missing("")
    @Published private(set) var serverState: ServerState = .starting
    @Published private(set) var serverDiagnostics: [String] = []
    @Published private(set) var health: ServerHealth?
    /// Code defaults, unless an older version saved settings (and a Keychain key) for the engine.
    let modelSettings: ModelSettings
    @Published private(set) var connection: ConnectionPhase = .disconnected
    /// The stored credential, bound to the engine's current URL (its port changes every launch).
    @Published private(set) var credential: DeviceCredential?
    @Published private(set) var credentialLoaded = false
    @Published private(set) var sessions: [LocalSession] = []
    /// Views pushed inside the menu bar panel, which is the whole UI (a stack, not windows).
    @Published var panelPath: [PanelRoute] = []
    /// Whether the menu bar panel is on screen, so opening it never toggles it shut.
    var panelVisible = false
    @Published private(set) var busySessionIds: Set<String> = []
    @Published var sessionMessages: [String: String] = [:]

    let store: SessionStore
    let scanner = CodexScanner()
    let cloneWorkflow = CloneWorkflowModel()
    let recorder: Recorder
    let credentialStore: CredentialStore
    let secretStore: SecretStore
    private(set) var supervisor: ServerSupervisor!
    private var connectTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var externalProbe: Task<Void, Never>?
    /// A rejected token is replaced automatically once per engine launch, never in a loop.
    private var reconnectAttempted = false
    private var terminateObserver: NSObjectProtocol?
    /// Analyses from the Local workspace, shown in the menu bar panel.
    private(set) lazy var workspace = WorkspaceModel(app: self)

    init(store: SessionStore = SessionStore(root: SessionStore.defaultRoot()),
         credentialStore: CredentialStore = KeychainCredentialStore(),
         secretStore: SecretStore = KeychainSecretStore(), startAnalysisEngine: Bool = true) {
        self.store = store
        self.credentialStore = credentialStore
        self.secretStore = secretStore
        self.recorder = Recorder(store: store)
        let defaults = UserDefaults.standard
        deviceName = defaults.string(forKey: Self.defaultsDeviceNameKey) ?? (Host.current().localizedName ?? "Mac")
        modelSettings = defaults.data(forKey: Self.defaultsModelSettingsKey)
            .flatMap { try? JSONDecoder().decode(ModelSettings.self, from: $0) } ?? ModelSettings()
        supervisor = ServerSupervisor { [unowned self] in try self.launchSpec() }
        supervisor.onStateChange = { [weak self] state in self?.engineStateChanged(state) }
        recorder.onAutoStop = { [weak self] session in
            if self?.scanner.isRunning == true { self?.scanner.cancel() }
            self?.didFinishRecording(session)
        }
        // applicationWillTerminate: stop the engine (SIGTERM, then SIGKILL after 3 s).
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanner.cancel(); self?.supervisor.terminateNow() }
        }
        refreshSessions()
        if startAnalysisEngine { Task { @MainActor [weak self] in self?.startServer() } }
    }

    // MARK: Server identity

    /// The engine's current URL; nil until it is ready.
    var baseURL: APIBaseURL? {
        switch serverLocation {
        case .external(let url): return serverState.baseURL == nil ? nil : url
        case .binary: return serverState.baseURL
        case .missing: return nil
        }
    }

    /// What credentials and upload records are keyed by: a stable identity for the built-in engine.
    var serverKey: String {
        if case .external(let url) = serverLocation { return url.description }
        return DeviceCredential.embeddedServerKey
    }

    var isServerReady: Bool { baseURL != nil }
    /// Ready, but `/health` says no model is configured: uploads work, Analyze doesn't.
    var analysisNeedsSetup: Bool { isServerReady && health?.analysisConfigured == false }

    // MARK: Engine lifecycle

    func startServer() {
        let location = ServerLocation.resolve(environment: ProcessInfo.processInfo.environment, resources: Bundle.main.resourceURL)
        let changed = location != serverLocation
        serverLocation = location
        switch location {
        case .binary:
            if changed { Task { await supervisor.stop(); supervisor.start() } } else { supervisor.start() }
        case .external(let url):
            Task { await supervisor.stop() }
            probeExternal(url)
        case .missing(let reason):
            Task { await supervisor.stop() }
            setServerState(.failed(reason))
        }
    }

    /// Retry after a failure (re-reads the location, so a fixed `RETRACE_SERVER_BIN` is picked up).
    func retryServer() {
        if case .binary = serverLocation, supervisor.isRunning { supervisor.restart() } else { startServer() }
    }

    func refreshDiagnostics() { serverDiagnostics = supervisor.diagnostics }

    private func launchSpec() throws -> ServerLaunchSpec {
        guard case .binary(let bin) = serverLocation else { throw APIError.invalidInput("No engine binary.") }
        let dataDir = ServerEnvironment.defaultDataDirectory()
        try ServerEnvironment.prepareDataDirectory(dataDir)
        let keyFile = ServerEnvironment.keyFile(in: dataDir)
        try? FileManager.default.removeItem(at: keyFile)
        let settings = modelSettings
        var key: String?
        if !settings.offlineDemo, let k = try? secretStore.load(Self.apiKeyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            try ServerEnvironment.writeSecretFile(k, to: keyFile)
            key = k
        }
        let env = ServerEnvironment.make(inherited: ProcessInfo.processInfo.environment, dataDir: dataDir,
                                         settings: settings, apiKeyFile: key == nil ? nil : keyFile)
        return ServerLaunchSpec(executable: bin, environment: env, currentDirectory: dataDir,
                                transientFiles: key == nil ? [] : [keyFile], secrets: key.map { [$0] } ?? [])
    }

    private func engineStateChanged(_ state: ServerState) {
        guard case .binary = serverLocation else { return }
        refreshDiagnostics()
        setServerState(state)
    }

    /// A development server we don't launch: ready once `/health` answers.
    private func probeExternal(_ url: APIBaseURL) {
        externalProbe?.cancel()
        setServerState(.starting)
        externalProbe = Task { [weak self] in
            do {
                let h = try await APIClient(baseURL: url).health()
                guard let self, !Task.isCancelled, self.serverLocation == .external(url) else { return }
                self.health = h
                self.setServerState(.ready(ServerReady(baseURL: url, port: url.url.port ?? 0, version: h.version)))
            } catch {
                guard let self, !Task.isCancelled, self.serverLocation == .external(url) else { return }
                self.setServerState(.failed("No Retrace server answered at \(url)."))
            }
        }
    }

    private func setServerState(_ state: ServerState) {
        let wasURL = serverState.baseURL
        serverState = state
        guard state.baseURL != wasURL else { return }
        // The engine came up (or went away, or moved to a new port): rebind or drop the credential.
        connectTask?.cancel(); connectTask = nil
        healthTask?.cancel(); healthTask = nil
        if state.baseURL == nil {
            health = nil
            credential = nil
            connection = .disconnected
            workspace.credentialChanged()
        } else {
            reconnectAttempted = false
            refreshHealth()
            attachCredential()
        }
    }

    // MARK: Health

    func refreshHealth() {
        guard let base = baseURL else { return }
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            let h = try? await APIClient(baseURL: base).health()
            guard let self, !Task.isCancelled, self.baseURL == base, let h else { return }
            self.health = h
        }
    }

    // MARK: Credential (Keychain)

    func loadCredentialIfNeeded() {
        if !credentialLoaded { attachCredential() }
    }

    /// Loads the credential stored for this engine and binds it to the engine's current URL.
    /// None stored: connect automatically. Stored: check it still works (the engine's data may have
    /// been reset) and replace it once if it was rejected.
    private func attachCredential() {
        credentialLoaded = true
        guard let base = baseURL else { credential = nil; connection = .disconnected; return }
        do {
            credential = try credentialStore.load(apiBaseURL: serverKey)?.bound(to: base.description)
        } catch {
            credential = nil
            connection = .failed("Could not read Keychain: \(error)")
            workspace.credentialChanged()
            return
        }
        workspace.credentialChanged()
        guard let cred = credential else { connect(); return }
        connection = .connected
        Task { [weak self] in
            guard let client = try? WorkspaceClient(client: APIClient(baseURL: base), credential: cred) else { return }
            do { _ = try await client.sessions() } catch {
                guard let self, self.credential == cred, WorkspaceModel.isAuthError(error) else { return }
                _ = self.credentialRejected()
            }
        }
    }

    /// The engine rejected this Mac's token (for example its data folder was reset). Returns true
    /// if a new connection was started.
    @discardableResult
    func credentialRejected() -> Bool {
        guard !reconnectAttempted, isServerReady else { return false }
        reconnectAttempted = true
        reconnect()
        return true
    }

    // MARK: Local connection

    /// Asks the engine on this Mac for a device credential (`POST /v1/local/connect`, loopback only).
    func connect() {
        guard connectTask == nil, let base = baseURL else { return }
        let service = LocalConnectionService(client: APIClient(baseURL: base))
        let name = deviceName
        let key = serverKey
        connection = .connecting
        connectTask = Task { [weak self] in
            let result: Result<DeviceCredential, Error>
            do { result = .success(try await service.connect(deviceName: name)) } catch { result = .failure(error) }
            await MainActor.run {
                // An engine restart cancels this attempt; never store its credential.
                guard let self, !Task.isCancelled, self.baseURL == base else { return }
                self.connectTask = nil
                switch result {
                case .success(let cred):
                    do {
                        try self.credentialStore.save(cred.bound(to: key))
                        self.credential = cred
                        self.credentialLoaded = true
                        self.connection = .connected
                        self.workspace.credentialChanged()
                    } catch {
                        self.connection = .failed("Connected, but saving to Keychain failed: \(error). Not connected.")
                    }
                case .failure(let error):
                    self.connection = .failed(Self.connectError(error))
                }
            }
        }
    }

    private static func connectError(_ error: Error) -> String {
        switch error as? APIError {
        case .transport?: return "The analysis engine didn't answer. Try again in a moment."
        case .http(404, _)?: return "This server does not allow local connections."
        default: return String(describing: error)
        }
    }

    func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        do {
            try credentialStore.delete(apiBaseURL: serverKey)
            credential = nil
            connection = .disconnected
            workspace.credentialChanged()
        } catch {
            connection = .failed("Could not remove Keychain item: \(error)")
        }
    }

    /// Replace this Mac's token with a new one.
    func reconnect() {
        disconnect()
        connect()
    }

    // MARK: Sessions

    func refreshSessions() {
        sessions = store.list()
    }

    func session(_ id: String) -> LocalSession? { sessions.first { $0.id == id } }

    /// A finished scan lands on its app's page in the panel, opening the panel if it's closed.
    func didFinishRecording(_ session: LocalSession?) {
        refreshSessions()
        if let session { cloneWorkflow.acceptScan(session) }
        if let app = session?.manifest.app { panelPath = [.app(AppGrouping.key(name: app.name, bundleId: app.bundleId))] }
        MenuBarPanel.open(unlessVisible: panelVisible)
    }

    /// The one confirmation before upload: the person looked at this scan's frames and may share them.
    /// Records it on the session's review (nothing omitted unless an older version saved omissions),
    /// then uploads and requests analysis.
    func confirmAndUpload(_ id: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        if !sessions[i].review.isConfirmed {
            var review = sessions[i].review
            review.confirmedAt = SessionClock.iso8601(Date())
            do { try store.save(review: review, sessionId: id) } catch {
                sessionMessages[id] = "Could not save the confirmation: \(error)"
                return
            }
            sessions[i].review = review
        }
        uploadAndAnalyze(id)
    }

    func reveal(_ id: String) {
        guard let s = session(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([s.directory])
    }

    // MARK: Upload & Analyze (explicit user action only)

    private func uploadAndAnalyze(_ id: String) {
        guard !busySessionIds.contains(id), let session = session(id) else { return }
        guard let base = baseURL else { sessionMessages[id] = "The analysis engine isn't running yet."; return }
        guard let cred = credential, cred.apiBaseURL == base.description else {
            sessionMessages[id] = "This Mac isn't connected to the analysis engine yet."
            return
        }
        let manifest: SessionManifest
        do {
            manifest = try ReviewApplier.apply(session.review, to: session.manifest, projectId: cred.projectId)
        } catch {
            sessionMessages[id] = String(describing: error)
            return
        }
        busySessionIds.insert(id)
        let alreadyUploaded = session.upload.remoteSessionId
        let uploader = SessionUploader(client: APIClient(baseURL: base))
        let store = self.store
        let key = serverKey
        let skipAnalysis = analysisNeedsSetup
        Task { [weak self] in
            var record = session.upload
            do {
                let remoteId: String
                if let existing = alreadyUploaded, record.apiBaseURL == key {
                    remoteId = existing
                } else {
                    self?.setMessage(id, "Uploading \(manifest.frames.count) frames and \(manifest.interactions.count) events…")
                    let files = try await Task.detached { try SessionStore.frameFiles(for: manifest, in: session.directory) }.value
                    let resp = try await uploader.upload(manifest: manifest, files: files, credential: cred)
                    remoteId = resp.id
                    record = UploadRecord(remoteSessionId: resp.id, uploadedAt: SessionClock.iso8601(Date()), apiBaseURL: key)
                    try? store.save(upload: record, sessionId: id)
                }
                if skipAnalysis {
                    self?.setMessage(id, "Uploaded. Analysis isn't configured on this engine, so it wasn't requested.")
                } else {
                    self?.setMessage(id, "Uploaded. Requesting analysis…")
                    let job = try await uploader.analyze(sessionId: remoteId, credential: cred)
                    record.jobId = job.jobId
                    record.jobStatus = job.status
                    try? store.save(upload: record, sessionId: id)
                    self?.setMessage(id, "Analysis requested (job \(job.jobId), status \(job.status)).")
                }
                self?.workspace.jobStarted()
            } catch {
                if WorkspaceModel.isAuthError(error) { self?.credentialRejected() }
                self?.setMessage(id, "Failed: \(error)")
            }
            await MainActor.run {
                self?.busySessionIds.remove(id)
                self?.refreshSessions()
            }
        }
    }

    private func setMessage(_ id: String, _ m: String) { sessionMessages[id] = m }

    // MARK: Panel navigation

    /// Pushes a view in the panel; showing the view that's already on top does nothing.
    func push(_ route: PanelRoute) {
        guard panelPath.last != route else { return }
        withAnimation(.snappy(duration: 0.25)) { panelPath.append(route) }
    }

    func pop() { withAnimation(.snappy(duration: 0.25)) { _ = panelPath.popLast() } }

    func popToRoot() { withAnimation(.snappy(duration: 0.25)) { panelPath = [] } }
}
