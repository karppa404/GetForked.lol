import AppKit
import Combine
import RetraceCore

/// App-wide state: settings, pairing, local sessions and explicit uploads.
@MainActor
final class AppModel: ObservableObject {
    static let defaultsBaseURLKey = "apiBaseURL"
    static let defaultsDeviceNameKey = "deviceName"

    @Published var apiBaseURLString: String
    @Published var deviceName: String
    @Published private(set) var pairing: PairingPhase = .unpaired
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
    private var pairingTask: Task<Void, Never>?
    private var pairingAttemptId: UUID?

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
            cancelPairing()
            reloadCredential()
        } catch {
            lastError = String(describing: error)
        }
    }

    func saveDeviceName() {
        UserDefaults.standard.set(deviceName, forKey: Self.defaultsDeviceNameKey)
    }

    // MARK: Credential (Keychain)

    /// Loads lazily (on opening Pairing or Review), so launching the app never touches the Keychain.
    func loadCredentialIfNeeded() {
        if !credentialLoaded { reloadCredential() }
    }

    private func reloadCredential() {
        credentialLoaded = true
        guard let base = baseURL else { credential = nil; pairing = .unpaired; return }
        do {
            credential = try credentialStore.load(apiBaseURL: base.description)
            pairing = credential.map { .paired(projectId: $0.projectId) } ?? .unpaired
        } catch {
            credential = nil
            pairing = .failed("Could not read Keychain: \(error)")
        }
    }

    // MARK: Pairing

    func startPairing(code: String) {
        guard pairingTask == nil else { return }
        let base: APIBaseURL
        do { base = try APIBaseURL(apiBaseURLString) } catch { pairing = .failed(String(describing: error)); return }
        saveDeviceName()
        let name = deviceName
        let service = PairingService(client: APIClient(baseURL: base))
        pairing = .claiming
        let attemptId = UUID()
        pairingAttemptId = attemptId
        pairingTask = Task { [weak self] in
            defer {
                Task { @MainActor in
                    if self?.pairingAttemptId == attemptId {
                        self?.pairingTask = nil
                        self?.pairingAttemptId = nil
                    }
                }
            }
            let claim: ClaimResponse
            do {
                claim = try await service.claim(code: code, deviceName: name)
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled, self?.pairingAttemptId == attemptId else { return }
                    self?.pairing = .failed(String(describing: error))
                }
                return
            }
            guard !Task.isCancelled, self?.pairingAttemptId == attemptId else { return }
            await MainActor.run { self?.pairing = .pending(claimId: claim.claimId, deviceName: name) }
            let outcome = await service.waitForApproval(claim: claim, deviceName: name)
            await MainActor.run {
                guard !Task.isCancelled, self?.pairingAttemptId == attemptId else { return }
                self?.finishPairing(outcome)
            }
        }
    }

    private func finishPairing(_ outcome: PairingOutcome) {
        switch outcome {
        case .approved(let cred):
            do {
                try credentialStore.save(cred)
                credential = cred
                credentialLoaded = true
                pairing = .paired(projectId: cred.projectId)
            } catch {
                pairing = .failed("Approved, but saving to Keychain failed: \(error). Not paired.")
            }
        case .expired: pairing = .failed("Pairing code or claim expired. Create a new code in the browser.")
        case .rejected(let m), .failed(let m): pairing = .failed(m)
        case .cancelled: pairing = credential.map { .paired(projectId: $0.projectId) } ?? .unpaired
        }
    }

    func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        pairingAttemptId = nil
        if case .paired = pairing { return }
        pairing = credential.map { .paired(projectId: $0.projectId) } ?? .unpaired
    }

    func unpair() {
        cancelPairing()
        guard let base = baseURL else { return }
        do {
            try credentialStore.delete(apiBaseURL: base.description)
            credential = nil
            pairing = .unpaired
        } catch {
            pairing = .failed("Could not remove Keychain item: \(error)")
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
            sessionMessages[id] = "Pair this Mac with \(base) first."
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
