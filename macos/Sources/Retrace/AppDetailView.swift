import RetraceCore
import SwiftUI

/// One recorded app: last screen, actions, latest analysis with the agent trace, and its recordings.
struct AppDetailView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var workspace: WorkspaceModel
    let group: AppGroup
    let onBack: () -> Void
    let onAPIDocs: () -> Void
    @State private var linking = false
    /// The single confirmation that this scan may be uploaded; reset when a newer scan arrives.
    @State private var confirmedUpload: String?

    private var latestJob: RemoteSessionDetail? { workspace.latestJobDetail(group) }
    private var newestRemote: RemoteSessionDetail? { group.remoteIds.first.flatMap { workspace.details[$0] } }
    /// The newest scan that is only on this Mac, which Upload & Analyze sends.
    private var pendingUpload: LocalSession? {
        group.recordings.first.flatMap { $0.isLocalOnly ? $0.localId.flatMap(model.session) : nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelNavBar(back: "Apps", title: group.name, onBack: onBack) {
                Button { workspace.refresh(); workspace.loadGroup(group, force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ScreenImage(source: workspace.screen(for: group, local: model.sessions), cornerRadius: 10, contentMode: .fit, bundleId: group.bundleId)
                        .frame(height: 200)
                    header
                    if let s = pendingUpload { uploadCard(s) }
                    actions
                    if let n = workspace.notices[group.key] { NoticeText(notice: n) }
                    if linking { BoardLinkForm(group: group, onDone: { linking = false }) }
                    analysis
                    if let profile = workspace.graphDetail(group)?.graph?.rebuildProfile {
                        RebuildAssessmentView(profile: profile)
                    }
                    if let report = group.recordings.compactMap({ $0.localId }).compactMap({ model.session($0)?.manifest.scanReport }).first {
                        DisclosureGroup("Codex coverage report (partial)") {
                            Text(report).font(.caption).textSelection(.enabled)
                        }
                    }
                    if let g = workspace.graphDetail(group), g.graph?.nodes.isEmpty == false {
                        GraphLabelEditor(detail: g, locked: group.isAnalyzing || latestJob?.job?.isActive == true || g.job?.isActive == true)
                    }
                    recordings
                }
                .padding(14)
            }
        }
        .onAppear { workspace.loadGroup(group) }
        .onChange(of: group.remoteIds) { _, _ in workspace.loadGroup(group) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(group.name).font(.title3.weight(.semibold))
            HStack(spacing: 4) {
                if let b = group.bundleId { Text(b).font(.caption.monospaced()).textSelection(.enabled) ; Text("·") }
                Text(PanelFormat.plural(group.recordings.count, "recording")).monospacedDigit()
                Text("·")
                Text("last \(PanelFormat.relative(group.lastRecordedAt))")
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    // MARK: Actions

    private var actions: some View {
        let connected = workspace.isConnected
        let hasUpload = !group.remoteIds.isEmpty
        let running = group.isAnalyzing || latestJob?.job?.isActive == true
        let analyzing = workspace.busy.contains("analyze:\(group.key)")
        let exporting = workspace.busy.contains("export:\(group.key)")
        let exportingSpec = workspace.busy.contains("spec:\(group.key)")
        let graph = workspace.graphDetail(group)
        let board = workspace.boardURL(group)
        let detailsReady = workspace.allDetailsLoaded(group)

        return VStack(alignment: .leading, spacing: 8) {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    let needsSetup = model.analysisNeedsSetup && !running
                    Button { workspace.analyze(group) } label: {
                        Label(running ? "Analyzing…" : newestRemote?.job != nil ? "Re-run Analysis" : "Analyze",
                              systemImage: running ? "hourglass" : "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!connected || !hasUpload || running || analyzing || needsSetup)
                    .help(needsSetup ? "Analysis isn't configured: the engine has no Nemotron key"
                          : hasUpload ? "Analyze the newest uploaded recording with Nemotron" : "Upload a recording of this app first")

                    Button { workspace.exportFlow(group) } label: {
                        Label(exporting ? "Preparing…" : "Export UI Flow", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                    }
                    .disabled(graph == nil || exporting)
                    .help(graph == nil ? "Analyze a recording of this app first" : "Save the validated graph with screenshots for the Retrace FigJam plugin")
                }
                GridRow {
                    if let board {
                        Button { NSWorkspace.shared.open(board) } label: {
                            Label("Open FigJam Board", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity)
                        }
                        .help(board.absoluteString)
                    } else {
                        Button { linking = true } label: {
                            Label("Link FigJam Board…", systemImage: "link").frame(maxWidth: .infinity)
                        }
                        .disabled(!connected || !hasUpload || !detailsReady)
                        .help("Paste the FigJam board you imported the UI flow into")
                    }
                    Button(action: onAPIDocs) {
                        Label("API Docs", systemImage: "curlybraces").frame(maxWidth: .infinity)
                    }
                    .disabled(!group.hasNetwork)
                    .help(group.hasNetwork ? "Endpoints this app called while recorded" : "No network traffic recorded")
                }
                GridRow {
                    Button { workspace.exportSpec(group) } label: {
                        Label(exportingSpec ? "Preparing…" : "Export Clone Spec", systemImage: "shippingbox").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(graph == nil || group.bundleId == nil || exportingSpec)
                    .help(graph == nil ? "Analyze a recording of this app first"
                          : "Save a zip a coding agent can build a clone from: spec, API contracts and tests from every analysed recording")
                    .gridCellColumns(2)
                }
            }
            .controlSize(.regular)
            if board != nil && !linking {
                Button("Change board link…") { linking = true }.buttonStyle(.link).font(.caption)
            }
            if !connected {
                Text(model.isServerReady ? "Connecting this Mac to the analysis engine…" : "Waiting for the analysis engine to start…")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !hasUpload && pendingUpload == nil {
                Text("Scan \(group.name) again to upload and analyze it.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Upload

    /// Upload & Analyze for the newest local scan, behind one confirmation. Nothing leaves this Mac before it.
    private func uploadCard(_ s: LocalSession) -> some View {
        let frames = s.manifest.frames.filter { !s.review.omittedFrameIds.contains($0.id) }.count
        let busy = model.busySessionIds.contains(s.id)
        let confirmed = confirmedUpload == s.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("Newest scan is only on this Mac", systemImage: "internaldrive").font(.subheadline.bold())
                Spacer()
                Button("Show frames") { model.reveal(s.id) }.buttonStyle(.link).font(.caption)
                    .help("Open this scan's frames in Finder")
            }
            Text("Its frames show everything that was visible in \(s.manifest.app.name)'s windows. Retrace doesn't detect or remove sensitive content.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: Binding(get: { confirmed }, set: { confirmedUpload = $0 ? s.id : nil })) {
                Text("I reviewed this scan's \(PanelFormat.plural(frames, "frame")) and I'm allowed to share them.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .font(.callout)
            .disabled(busy)
            HStack {
                Button { model.confirmAndUpload(s.id) } label: {
                    Label("Upload & Analyze", systemImage: "icloud.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!confirmed || busy || model.credential == nil || !model.isServerReady)
                if busy { ProgressView().controlSize(.small) }
            }
            if let msg = model.sessionMessages[s.id] {
                Text(msg).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Analysis

    @ViewBuilder private var analysis: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Latest analysis").font(.headline)
            if let d = latestJob, let job = d.job {
                AnalysisSummaryView(job: job)
                if d.id != group.remoteIds.first {
                    Text("From the recording of \(PanelFormat.date(d.summary.startedAt)).").font(.caption).foregroundStyle(.secondary)
                }
            } else if !group.remoteIds.isEmpty && !workspace.allDetailsLoaded(group) {
                VStack(alignment: .leading, spacing: 6) { SkeletonBar(width: 140); SkeletonBar(width: 220); SkeletonBar(width: 180) }
                    .accessibilityLabel("Loading analysis")
            } else if let e = group.remoteIds.first.flatMap({ workspace.detailErrors[$0] }) {
                Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            } else {
                Text(group.remoteIds.isEmpty ? "Not uploaded yet." : "Not analyzed yet.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Recordings

    private var recordings: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recordings").font(.headline)
            ForEach(group.recordings) { r in RecordingRow(recording: r, group: group, onBack: onBack) }
        }
    }
}

private struct RecordingRow: View {
    @EnvironmentObject var workspace: WorkspaceModel
    let recording: Recording
    let group: AppGroup
    /// Back to the app list once the last recording of the app is deleted.
    let onBack: () -> Void
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(PanelFormat.date(recording.startedAt)).font(.callout)
                HStack(spacing: 4) {
                    Text(PanelFormat.duration(recording.durationMs)).monospacedDigit()
                    if recording.localId == nil { Text("· not on this Mac") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusLabel(status: recording.status).font(.caption)
            Button { confirming = true } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(!canDelete)
                .help(canDelete ? "Delete this recording" : "Wait until recording, upload and analysis finish")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .contextMenu {
            Button("Delete Recording…", systemImage: "trash", role: .destructive) { confirming = true }.disabled(!canDelete)
        }
        .confirmationDialog("Delete this recording?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    if await workspace.delete([recording], in: group) == nil, workspace.group(group.key) == nil { onBack() }
                }
            }
        } message: {
            Text(recording.isLocalOnly ? "This removes it from this Mac." : "This removes it from this Mac and the server.")
        }
    }

    private var canDelete: Bool { workspace.canDelete(recording) }
}

/// Inline "paste your FigJam link" form. Saves the link on one recording of the app.
private struct BoardLinkForm: View {
    @EnvironmentObject var workspace: WorkspaceModel
    let group: AppGroup
    let onDone: () -> Void
    @State private var value = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    private var busy: Bool { workspace.busy.contains("board:\(group.key)") }
    private var current: URL? { workspace.boardURL(group) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("https://www.figma.com/board/…", text: $value)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
                .disabled(busy)
            HStack {
                Button("Save", action: save).buttonStyle(.borderedProminent).disabled(busy || value.isEmpty)
                if current != nil {
                    Button("Remove") { Task { if await workspace.saveBoard(group, url: nil) { onDone() } } }.disabled(busy)
                }
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction).disabled(busy)
                if busy { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear {
            value = current?.absoluteString ?? ""
            focused = true
        }
    }

    private func save() {
        guard let url = validBoardURL(value) else {
            error = "Enter an https://www.figma.com/… link to your FigJam board."
            return
        }
        error = nil
        Task { if await workspace.saveBoard(group, url: url.absoluteString) { onDone() } }
    }
}
