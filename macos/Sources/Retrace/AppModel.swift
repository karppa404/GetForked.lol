import AppKit
import Combine
import RetraceCore

enum ConnectionPhase: Equatable {
    case disconnected, connecting, connected
    case failed(String)
}

/// App-wide state: settings, local connection, local sessions and explicit uploads.
@MainActor
final class AppModel: ObservableObject {
    static let defaultsBaseURLKey = "apiBaseURL"
    static let defaultsDeviceNameKey = "deviceName"

    @Published var apiBaseURLString: String
    @Published var deviceName: String
    @Published private(set) var connection: ConnectionPhase = .disconnected
    @Published private(set) var credential: DeviceCredential?
    @Published private(set) var credentialLoaded = false
    @Published private(set) var sessions: [LocalSession] = []
    @Published var selectedSessionId: String?
    @Published private(set) var busySessionIds: Set<String> = []
    @Published var sessionMessages: [String: String] = [:]
    @Published var lastError: String?

    let store: SessionStore
    let recorder: Recorder
    let credentialStore: CredentialStore
    private var connectTask: Task<Void, Never>?

    init(store: SessionStore = SessionStore(root: SessionStore.defaultRoot()),
         credentialStore: CredentialStore = KeychainCredentialStore()) {
        self.store = store
        self.credentialStore = credentialStore
        self.recorder = Recorder(store: store)
        let defaults = UserDefaults.standard
        apiBaseURLString = defaults.string(forKey: Self.defaultsBaseURLKey) ?? APIBaseURL.development
        deviceName = defaults.string(forKey: Self.defaultsDeviceNameKey) ?? (Host.current().localizedName ?? "Mac")
        recorder.onAutoStop = { [weak self] session in
            self?.didFinishRecording(session)
        }
        refreshSessions()
    }

    // MARK: Settings

    var baseURL: APIBaseURL? { try? APIBaseURL(apiBaseURLString) }

    /// Validates and saves the base URL, then loads the credential bound to that server.
    func saveBaseURL() {
        do {
            let url = try APIBaseURL(apiBaseURLString)
            apiBaseURLString = url.description
            UserDefaults.standard.set(url.description, forKey: Self.defaultsBaseURLKey)
            lastError = nil
            connectTask?.cancel()
            connectTask = nil
            reloadCredential()
        } catch {
            lastError = String(describing: error)
        }
    }

    func saveDeviceName() {
        UserDefaults.standard.set(deviceName, forKey: Self.defaultsDeviceNameKey)
    }

    // MARK: Credential (Keychain)

    /// Loads lazily (on opening Connection or Review), so launching the app never touches the Keychain.
    func loadCredentialIfNeeded() {
        if !credentialLoaded { reloadCredential() }
    }

    private func reloadCredential() {
        credentialLoaded = true
        guard let base = baseURL else { credential = nil; connection = .disconnected; return }
        do {
            credential = try credentialStore.load(apiBaseURL: base.description)
            connection = credential == nil ? .disconnected : .connected
        } catch {
            credential = nil
            connection = .failed("Could not read Keychain: \(error)")
        }
    }

    // MARK: Local connection

    func connect() {
        guard connectTask == nil else { return }
        let base: APIBaseURL
        do { base = try APIBaseURL(apiBaseURLString) } catch { connection = .failed(String(describing: error)); return }
        saveDeviceName()
        let service = LocalConnectionService(client: APIClient(baseURL: base))
        let name = deviceName
        connection = .connecting
        connectTask = Task { [weak self] in
            let result: Result<DeviceCredential, Error>
            do { result = .success(try await service.connect(deviceName: name)) } catch { result = .failure(error) }
            await MainActor.run {
                // Disconnect or a base URL change cancels this attempt; never store its credential.
                guard let self, !Task.isCancelled else { return }
                self.connectTask = nil
                switch result {
                case .success(let cred):
                    do {
                        try self.credentialStore.save(cred)
                        self.credential = cred
                        self.credentialLoaded = true
                        self.connection = .connected
                    } catch {
                        self.connection = .failed("Connected, but saving to Keychain failed: \(error). Not connected.")
                    }
                case .failure(let error):
                    self.connection = .failed(Self.connectError(error, base))
                }
            }
        }
    }

    private static func connectError(_ error: Error, _ base: APIBaseURL) -> String {
        switch error as? APIError {
        case .transport?: return "No Retrace server answered at \(base). Start it locally, then try again."
        case .http(404, _)?: return "This server does not allow local connections (development sign-in is off)."
        default: return String(describing: error)
        }
    }

    func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        guard let base = baseURL else { return }
        do {
            try credentialStore.delete(apiBaseURL: base.description)
            credential = nil
            connection = .disconnected
        } catch {
            connection = .failed("Could not remove Keychain item: \(error)")
        }
    }

    // MARK: Sessions

    func refreshSessions() {
        sessions = store.list()
        if let sel = selectedSessionId, !sessions.contains(where: { $0.id == sel }) { selectedSessionId = nil }
    }

    func session(_ id: String) -> LocalSession? { sessions.first { $0.id == id } }

    func didFinishRecording(_ session: LocalSession?) {
        refreshSessions()
        if let session { selectedSessionId = session.id }
        NotificationCenter.default.post(name: .retraceOpenReview, object: nil)
    }

    /// Persists a review change. Any change to what's kept revokes a prior confirmation.
    func updateReview(_ id: String, keepConfirmation: Bool = false, _ change: (inout ReviewState) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        var review = sessions[i].review
        change(&review)
        if !keepConfirmation { review.confirmedAt = nil }
        sessions[i].review = review
        do { try store.save(review: review, sessionId: id) } catch { lastError = "Could not save review: \(error)" }
    }

    func setConfirmed(_ id: String, _ confirmed: Bool) {
        updateReview(id, keepConfirmation: true) { $0.confirmedAt = confirmed ? SessionClock.iso8601(Date()) : nil }
    }

    func delete(_ id: String) {
        do { try store.delete(id: id) } catch { lastError = "Could not delete: \(error)" }
        refreshSessions()
    }

    func reveal(_ id: String) {
        guard let s = session(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([s.directory])
    }

    // MARK: Upload & Analyze (explicit user action only)

    func uploadAndAnalyze(_ id: String) {
        guard !busySessionIds.contains(id), let session = session(id) else { return }
        guard let base = baseURL else { sessionMessages[id] = "Invalid API base URL."; return }
        guard let cred = credential, cred.apiBaseURL == base.description else {
            sessionMessages[id] = "Connect this Mac to the Local workspace at \(base) first."
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
        Task { [weak self] in
            var record = session.upload
            do {
                let remoteId: String
                if let existing = alreadyUploaded, record.apiBaseURL == base.description {
                    remoteId = existing
                } else {
                    self?.setMessage(id, "Uploading \(manifest.frames.count) frames and \(manifest.interactions.count) events…")
                    let files = try await Task.detached { try SessionStore.frameFiles(for: manifest, in: session.directory) }.value
                    let resp = try await uploader.upload(manifest: manifest, files: files, credential: cred)
                    remoteId = resp.id
                    record = UploadRecord(remoteSessionId: resp.id, uploadedAt: SessionClock.iso8601(Date()), apiBaseURL: base.description)
                    try? store.save(upload: record, sessionId: id)
                }
                self?.setMessage(id, "Uploaded. Requesting analysis…")
                let job = try await uploader.analyze(sessionId: remoteId, credential: cred)
                record.jobId = job.jobId
                record.jobStatus = job.status
                try? store.save(upload: record, sessionId: id)
                self?.setMessage(id, "Analysis requested (job \(job.jobId), status \(job.status)).")
            } catch {
                self?.setMessage(id, "Failed: \(error)")
            }
            await MainActor.run {
                self?.busySessionIds.remove(id)
                self?.refreshSessions()
            }
        }
    }

    private func setMessage(_ id: String, _ m: String) { sessionMessages[id] = m }
}

extension Notification.Name {
    static let retraceOpenReview = Notification.Name("RetraceOpenReview")
}
