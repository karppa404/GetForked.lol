import AppKit
import RetraceCore
import UniformTypeIdentifiers

/// Analyses of this Mac's recordings, read from the Local workspace with the device credential.
/// Session details and frame images are cached; while a job runs, the list and the running
/// sessions are re-read every 1.5 s, and polling stops once nothing is queued or running.
@MainActor
final class WorkspaceModel: ObservableObject {
    enum ListState: Equatable {
        case idle, loading, loaded
        case failed(String, needsReconnect: Bool)
    }

    struct Notice: Equatable {
        enum Tone { case info, success, error }
        var tone: Tone
        var text: String
    }

    /// Sessions, details and their errors for the current credential. Requests capture its
    /// generation and their results are dropped once the credential changes. Not `@Published`:
    /// `mutate` announces only visible changes (issuing request tickets is bookkeeping).
    private(set) var store = WorkspaceStore()
    @Published private(set) var listState: ListState = .idle
    @Published private(set) var images: [String: NSImage] = [:]
    @Published private(set) var busy: Set<String> = []
    /// Per app group key: the outcome of the last action (export, analyze, board link).
    @Published var notices: [String: Notice] = [:]

    static let pollInterval: Duration = .milliseconds(1500)
    /// About 20 minutes of polling per run, then the user refreshes by hand.
    static let maxPolls = 800

    private weak var app: AppModel?
    private var cachedClient: (key: String, client: WorkspaceClient)?
    private var observers = 0
    private var pollTask: Task<Void, Never>?
    /// Identifies the current poll task, so a cancelled one never clears its successor.
    private var pollGeneration = 0
    private var refreshTask: Task<Void, Never>?
    /// In-flight `loadGroup` work; cancelled on a credential change.
    private var groupTasks: [UUID: Task<Void, Never>] = [:]
    private var loadingImages: Set<String> = []
    private var loadingDetails: Set<String> = []
    private var failedImages: Set<String> = []

    var remote: [RemoteSessionSummary] { store.remote }
    var projectName: String? { store.projectName }
    var details: [String: RemoteSessionDetail] { store.details }
    var detailErrors: [String: String] { store.detailErrors }
    private var generation: Int { store.generation }

    /// Applies a store change, publishing only when something changed.
    @discardableResult
    private func mutate(_ change: (inout WorkspaceStore) -> WorkspaceStore.Outcome) -> WorkspaceStore.Outcome {
        var s = store
        let outcome = change(&s)
        if outcome == .changed { objectWillChange.send() }
        store = s
        return outcome
    }

    init(app: AppModel) { self.app = app }

    // MARK: Derived state

    /// One client (and URLSession) per server + token; views read this on every render.
    var client: WorkspaceClient? {
        guard let app, let base = app.baseURL, let cred = app.credential else { return nil }
        let key = "\(base)\n\(cred.deviceToken)"
        if let cached = cachedClient, cached.key == key { return cached.client }
        let made = try? WorkspaceClient(client: APIClient(baseURL: base), credential: cred)
        cachedClient = made.map { (key, $0) }
        return made
    }

    var isConnected: Bool {
        guard let app, let base = app.baseURL, let cred = app.credential else { return false }
        return cred.apiBaseURL == base.description
    }

    /// Uploaded and local-only recordings, one group per desktop app.
    var groups: [AppGroup] {
        let local = app?.sessions ?? []
        return AppGrouping.group(AppGrouping.recordings(remote: isConnected ? remote : [], local: local, apiBaseURL: app?.serverKey))
    }

    func group(_ key: String) -> AppGroup? { groups.first { $0.key == key } }

    /// Loaded details of a group's uploaded recordings, newest first.
    func loadedDetails(_ g: AppGroup) -> [RemoteSessionDetail] { g.remoteIds.compactMap { details[$0] } }

    /// Newest recording that has an analysis job (a run started on a newer recording takes over).
    func latestJobDetail(_ g: AppGroup) -> RemoteSessionDetail? { loadedDetails(g).first { $0.job != nil } }
    func graphDetail(_ g: AppGroup) -> RemoteSessionDetail? { loadedDetails(g).first { $0.graph != nil } }
    func boardDetail(_ g: AppGroup) -> RemoteSessionDetail? { loadedDetails(g).first { $0.boardUrl.flatMap(validBoardURL) != nil } }
    func boardURL(_ g: AppGroup) -> URL? { boardDetail(g)?.boardUrl.flatMap(validBoardURL) }
    func allDetailsLoaded(_ g: AppGroup) -> Bool { g.remoteIds.allSatisfy { details[$0] != nil || detailErrors[$0] != nil } }

    /// Only the current credential's data counts: the store is cleared and old results dropped on a change.
    var needsPolling: Bool { store.needsPolling }

    // MARK: Visibility-driven loading

    func viewAppeared() {
        observers += 1
        app?.loadCredentialIfNeeded()
        refresh()
    }

    func viewDisappeared() {
        observers = max(0, observers - 1)
        if observers == 0 { pollTask?.cancel(); pollTask = nil }
    }

    /// A different (or no) credential: cached sessions belong to another server or token.
    func credentialChanged() {
        refreshTask?.cancel(); refreshTask = nil
        pollTask?.cancel(); pollTask = nil
        groupTasks.values.forEach { $0.cancel() }; groupTasks = [:]
        objectWillChange.send()
        store.reset()
        images = [:]; failedImages = []; notices = [:]; busy = []
        loadingImages = []; loadingDetails = []
        listState = .idle
        if observers > 0 { refresh() }
    }

    /// Called after Upload & Analyze (or any action) starts a job.
    func jobStarted() {
        refresh()
    }

    func refresh() {
        guard let client else {
            listState = .idle
            mutate { $0.setSessions([], project: nil, generation: $0.generation) }
            return
        }
        refreshTask?.cancel()
        if listState != .loaded { listState = .loading }
        let gen = generation
        refreshTask = Task { [weak self] in
            await self?.reload(client, generation: gen, detailsFor: nil)
            guard let self, self.store.isCurrent(gen) else { return }
            self.startPollingIfNeeded()
        }
    }

    private func reload(_ client: WorkspaceClient, generation gen: Int, detailsFor ids: Set<String>?) async {
        do {
            let list = try await client.sessions()
            guard !Task.isCancelled, store.isCurrent(gen) else { return }
            mutate { $0.setSessions(list.sessions, project: list.project?.name, generation: gen) }
            listState = .loaded
        } catch {
            guard !Task.isCancelled, store.isCurrent(gen) else { return }
            // A rejected token is replaced once automatically; that resets this store.
            if Self.isAuthError(error), app?.credentialRejected() == true { return }
            listState = .failed(Self.describe(error, client), needsReconnect: Self.isAuthError(error))
            return
        }
        // Re-read cached details that changed or are running (and, on a manual refresh, every app's
        // newest upload); fetch each app's newest upload once for its thumbnail and status.
        let newest = Set(groups.compactMap { $0.remoteIds.first })
        var changed = ids ?? newest.filter { details[$0] != nil }
        for s in remote {
            if let c = details[s.id], c.summary.status != s.status || s.isAnalyzing || c.job?.isActive == true { changed.insert(s.id) }
        }
        guard !Task.isCancelled, store.isCurrent(gen) else { return }
        await loadDetails(Array(changed), client: client, generation: gen, force: true)
        await loadDetails(Array(newest), client: client, generation: gen, force: false)
    }

    /// Loads every uploaded recording of an app (the detail view and API docs need all of them).
    func loadGroup(_ g: AppGroup, force: Bool = false) {
        guard let client else { return }
        let gen = generation, key = UUID()
        groupTasks[key] = Task { [weak self] in
            await self?.loadDetails(g.remoteIds, client: client, generation: gen, force: force)
            self?.groupTasks[key] = nil
        }
    }

    /// Fetches session details. Forced loads always fetch (the store keeps only the newest response
    /// per session); others skip cached or already-loading sessions. Results of an older credential
    /// generation, or older than a later request or local edit, are dropped by the store.
    private func loadDetails(_ ids: [String], client: WorkspaceClient, generation gen: Int, force: Bool) async {
        guard store.isCurrent(gen) else { return }
        let todo = ids.filter { force || (!loadingDetails.contains($0) && details[$0] == nil) }
        guard !todo.isEmpty else { return }
        let tickets = todo.map { store.issueDetailRequest($0) }
        let fresh = Set(todo).subtracting(loadingDetails)
        loadingDetails.formUnion(fresh)
        defer { if store.isCurrent(gen) { loadingDetails.subtract(fresh) } }
        await withTaskGroup(of: (WorkspaceStore.DetailTicket, Result<RemoteSessionDetail, Error>).self) { group in
            for t in tickets {
                group.addTask {
                    do { return (t, .success(try await client.session(t.sessionId))) } catch { return (t, .failure(error)) }
                }
            }
            for await (t, result) in group {
                guard !Task.isCancelled else { continue }
                switch result {
                case .success(let d): mutate { $0.setDetail(d, ticket: t) }
                case .failure(let e): mutate { $0.setDetailError(Self.describe(e, client), ticket: t) }
                }
            }
        }
    }

    private func startPollingIfNeeded() {
        guard observers > 0, pollTask == nil, needsPolling else { return }
        pollGeneration += 1
        let generation = pollGeneration
        let gen = self.generation
        pollTask = Task { [weak self] in
            var polls = 0
            while !Task.isCancelled, polls < Self.maxPolls {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !Task.isCancelled, self.store.isCurrent(gen), let client = self.client else { break }
                polls += 1
                await self.reload(client, generation: gen, detailsFor: self.store.runningIds)
                guard self.store.isCurrent(gen) else { break }
                // Errors halt polling (no silent retry loop); Refresh or reopening the panel resumes.
                if case .failed = self.listState { break }
                if !self.needsPolling { break }
            }
            if self?.pollGeneration == generation { self?.pollTask = nil }
        }
    }

    // MARK: Images

    static func imageKey(_ sessionId: String, _ frameId: String) -> String { "\(sessionId)/\(frameId)" }

    func image(_ sessionId: String, _ frameId: String) -> NSImage? { images[Self.imageKey(sessionId, frameId)] }
    func imageFailed(_ sessionId: String, _ frameId: String) -> Bool { failedImages.contains(Self.imageKey(sessionId, frameId)) }

    func loadImage(_ sessionId: String, _ frameId: String) async {
        let key = Self.imageKey(sessionId, frameId)
        guard images[key] == nil, !loadingImages.contains(key), !failedImages.contains(key), let client else { return }
        let gen = generation
        loadingImages.insert(key)
        defer { if store.isCurrent(gen) { loadingImages.remove(key) } }
        let image: NSImage? = await {
            guard let data = try? await client.frame(sessionId: sessionId, frameId: frameId) else { return nil }
            return await Task.detached { Self.thumbnail(data, maxPixels: 1200) }.value
        }()
        // A frame fetched with an old credential never lands in the new credential's cache.
        guard store.isCurrent(gen) else { return }
        if let image { images[key] = image } else { failedImages.insert(key); objectWillChange.send() }
    }

    nonisolated static func thumbnail(_ data: Data, maxPixels: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: Actions

    /// Analyze the newest uploaded recording; re-runs when it already has a job.
    func analyze(_ g: AppGroup) {
        guard let client, let id = g.remoteIds.first else { return }
        let rerun = details[id]?.job != nil
        let token = "analyze:\(g.key)"
        guard !busy.contains(token) else { return }
        busy.insert(token)
        notices[g.key] = nil
        let gen = generation
        Task {
            defer { finish(token, gen) }
            do {
                let r = try await client.analyze(sessionId: id, rerun: rerun)
                notice(g.key, Notice(tone: .info, text: rerun ? "Analysis started again." : "Analysis started (\(r.status))."), gen)
                await reload(client, generation: gen, detailsFor: [id])
                if store.isCurrent(gen) { startPollingIfNeeded() }
            } catch {
                if case .http(503, _)? = error as? APIError { app?.refreshHealth() }
                notice(g.key, Notice(tone: .error, text: Self.describe(error, client)), gen)
            }
        }
    }

    /// Validated graph JSON with one screenshot per screen, saved where the user chooses, for the
    /// Retrace FigJam plugin. Screenshots that can't be loaded are skipped; that never fails the export.
    func exportFlow(_ g: AppGroup) {
        guard let client, let detail = graphDetail(g) else { return }
        let token = "export:\(g.key)"
        guard !busy.contains(token) else { return }
        busy.insert(token)
        notices[g.key] = nil
        let gen = generation
        Task {
            defer { finish(token, gen) }
            do {
                let graph = try FlowExport.parseGraph(try await client.graphExport(sessionId: detail.id))
                let validation = FlowExport.validate(graph, evidenceIds: detail.evidenceIds)
                guard validation.ok else { throw FlowExportError.invalid(validation) }
                let picks = FlowExport.screenFrames(graph, frames: detail.frames)
                var shots: [String: ExportScreenshot] = [:]
                await withTaskGroup(of: (String, ExportScreenshot?).self) { group in
                    for (nodeId, frame) in picks {
                        group.addTask {
                            guard let data = try? await client.frame(sessionId: detail.id, frameId: frame.id) else { return (nodeId, nil) }
                            return (nodeId, FlowExport.encodeScreenshot(data, frameId: frame.id))
                        }
                    }
                    for await (nodeId, shot) in group { if let shot { shots[nodeId] = shot } }
                }
                let doc = try FlowExport.document(graph: graph, screenshots: shots)
                let name = FlowExport.filename(appName: g.name, sessionId: detail.id)
                guard let url = await Self.chooseSaveURL(name, title: "Export UI Flow", message: "Import this file with the Retrace FigJam plugin.", type: .json) else { return }
                try doc.write(to: url, options: .atomic)
                let pictures = shots.isEmpty ? "" : " with \(shots.count) screenshot\(shots.count == 1 ? "" : "s")"
                notice(g.key, Notice(tone: .success, text: "Saved \(url.lastPathComponent)\(pictures). Import it with the Retrace FigJam plugin, then link the board."), gen)
            } catch {
                notice(g.key, Notice(tone: .error, text: Self.describe(error, client)), gen)
            }
        }
    }

    /// Zip a coding agent can start a clone repo from: spec, API contracts and replayable tests built
    /// from every analysed recording of this app.
    func exportSpec(_ g: AppGroup) {
        guard let client, let bundleId = g.bundleId else { return }
        let token = "spec:\(g.key)"
        guard !busy.contains(token) else { return }
        busy.insert(token)
        notices[g.key] = nil
        let gen = generation
        Task {
            defer { finish(token, gen) }
            do {
                let data = try await client.specBundle(bundleId: bundleId)
                let words = g.name.lowercased().split { !$0.isLetter && !$0.isNumber }
                let name = "\(words.isEmpty ? "app" : words.joined(separator: "-"))-clone-spec.zip"
                guard let url = await Self.chooseSaveURL(name, title: "Export Clone Spec",
                                                         message: "Unzip it as a new repo and point a coding agent at AGENTS.md.", type: .zip) else { return }
                try data.write(to: url, options: .atomic)
                notice(g.key, Notice(tone: .success, text: "Saved \(url.lastPathComponent). Unzip it as a new repo and give a coding agent AGENTS.md."), gen)
            } catch {
                notice(g.key, Notice(tone: .error, text: Self.describe(error, client)), gen)
            }
        }
    }

    private static func chooseSaveURL(_ name: String, title: String, message: String, type: UTType) async -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.message = message
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        NSApp.activate()
        return await panel.begin() == .OK ? panel.url : nil
    }

    /// Saves (or clears) the board link on the recording that has it, else the analyzed one, else the newest.
    func saveBoard(_ g: AppGroup, url: String?) async -> Bool {
        guard let client, let id = (boardDetail(g) ?? graphDetail(g))?.id ?? g.remoteIds.first else { return false }
        let token = "board:\(g.key)"
        let gen = generation
        busy.insert(token)
        defer { finish(token, gen) }
        do {
            // Clearing removes every stored link of this app so an older one doesn't take over.
            let targets = url == nil ? loadedDetails(g).filter { $0.boardUrl != nil }.map(\.id) : [id]
            for target in targets.isEmpty ? [id] : targets { _ = try await client.setBoard(sessionId: target, url: url) }
            guard store.isCurrent(gen) else { return false }
            notice(g.key, Notice(tone: .success, text: url == nil ? "FigJam board link removed." : "FigJam board linked."), gen)
            await loadDetails(g.remoteIds, client: client, generation: gen, force: true)
            return true
        } catch {
            notice(g.key, Notice(tone: .error, text: Self.describe(error, client)), gen)
            return false
        }
    }

    // MARK: Label corrections

    static func correctionToken(_ sessionId: String, _ elementId: String) -> String { "label:\(sessionId)/\(elementId)" }

    /// Saves (or with nil reverts) the human label of one graph element of `sessionId`. The label is
    /// shown at once and rolled back if the server refuses; on success the session is re-read so
    /// API docs and the export reflect it. Returns an error message, or nil on success.
    func saveCorrection(sessionId: String, elementId: String, label: String?) async -> String? {
        guard let client else { return "The analysis engine isn't ready yet." }
        if let label, GraphLabels.clean(label) == nil { return "Enter a label of 1–\(GraphLabels.maxLabel) characters." }
        let gen = generation
        let token = Self.correctionToken(sessionId, elementId)
        guard !busy.contains(token), let before = details[sessionId] else { return nil }
        if before.job?.isActive == true { return "Wait for the analysis to finish." }
        let previous = before.correction(elementId)
        busy.insert(token)
        defer { finish(token, gen) }
        let optimistic = label.flatMap(GraphLabels.clean)
        mutate { $0.updateDetail(sessionId, generation: gen) { $0 = $0.settingCorrection(elementId, label: optimistic) } }
        do {
            if let optimistic {
                let saved = try await client.putCorrection(sessionId: sessionId, elementId: elementId, label: optimistic)
                mutate { $0.updateDetail(sessionId, generation: gen) { $0 = $0.settingCorrection(elementId, label: saved.label) } }
            } else {
                try await client.deleteCorrection(sessionId: sessionId, elementId: elementId)
            }
        } catch {
            mutate { $0.updateDetail(sessionId, generation: gen) { $0 = $0.settingCorrection(elementId, label: previous?.label) } }
            return store.isCurrent(gen) ? Self.describe(error, client) : nil
        }
        await loadDetails([sessionId], client: client, generation: gen, force: true)
        return nil
    }

    // MARK: Deletion

    /// Not while it is being recorded, uploaded, analyzed or deleted; an uploaded copy needs the engine.
    func canDelete(_ r: Recording) -> Bool {
        guard let app, !r.isAnalyzing, !busy.contains("delete:\(r.id)") else { return false }
        if let rid = r.remoteId, client == nil || details[rid]?.job?.isActive == true { return false }
        if let lid = r.localId, app.busySessionIds.contains(lid) || app.recorder.activeSessionId == lid { return false }
        return true
    }

    /// Deletes each recording on the server (when uploaded), then its copy on this Mac, and refreshes.
    /// Stops at the first failure, which also becomes the group's notice. Returns that error, or nil.
    func delete(_ recordings: [Recording], in g: AppGroup) async -> String? {
        guard let app else { return nil }
        guard recordings.allSatisfy(canDelete) else { return "Wait until recording, upload and analysis finish." }
        let gen = generation
        let tokens = recordings.map { "delete:\($0.id)" }
        busy.formUnion(tokens)
        notices[g.key] = nil
        defer { tokens.forEach { finish($0, gen) } }
        var failure: String?
        for r in recordings {
            do {
                if let rid = r.remoteId, let client {
                    try await client.deleteSession(rid)
                    mutate { $0.removeSessions([rid], generation: gen) }
                }
                if let lid = r.localId {
                    try app.store.delete(id: lid)
                    app.sessionMessages[lid] = nil
                }
            } catch {
                failure = "Couldn't delete the recording of \(PanelFormat.date(r.startedAt)): "
                    + (client.map { Self.describe(error, $0) } ?? String(describing: error))
                break
            }
        }
        app.refreshSessions()
        refresh()
        if let failure { notice(g.key, Notice(tone: .error, text: failure), gen) }
        return failure
    }

    // MARK: Generation-guarded bookkeeping

    private func finish(_ token: String, _ gen: Int) { if store.isCurrent(gen) { busy.remove(token) } }
    private func notice(_ key: String, _ n: Notice, _ gen: Int) { if store.isCurrent(gen) { notices[key] = n } }

    func openBoard(_ g: AppGroup) {
        if let url = boardURL(g) { NSWorkspace.shared.open(url) }
    }

    // MARK: Errors

    static func isAuthError(_ error: Error) -> Bool {
        if case .http(let s, _)? = error as? APIError { return s == 401 || s == 403 }
        return false
    }

    static func describe(_ error: Error, _ client: WorkspaceClient) -> String {
        switch error as? APIError {
        case .transport?: return "The analysis engine isn't responding. Try again in a moment."
        case .http(401, _)?, .http(403, _)?: return "The analysis engine no longer accepts this Mac's connection. Connect again."
        case .http(404, _)?: return "Not found on the server."
        case .http(409, "analysis_in_progress")?: return "Wait for the analysis to finish."
        case .http(503, let d)? where d?.contains("not configured") == true || d == "analysis_not_configured":
            return "Analysis isn't set up. Add your Nemotron endpoint and API key in Settings."
        default: return String(describing: error)
        }
    }
}
