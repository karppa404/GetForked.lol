import AppKit
import RetraceCore
import SwiftUI

struct TargetApp: Identifiable, Hashable {
    let id: pid_t
    let name: String
    let bundleId: String
    let app: NSRunningApplication

    /// Regular (Dock) apps, excluding Retrace itself.
    static func candidates() -> [TargetApp] {
        let me = getpid()
        let myBundle = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated }
            .filter { myBundle == nil || $0.bundleIdentifier != myBundle }
            .map { TargetApp(id: $0.processIdentifier, name: $0.localizedName ?? $0.bundleIdentifier ?? "pid \($0.processIdentifier)",
                             bundleId: $0.bundleIdentifier ?? "unknown", app: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Pushed views inside the menu bar panel (a stack, not a sidebar).
enum PanelRoute: Hashable {
    case app(String)
    case apiDocs(String)
}

/// The menu bar panel, which is the whole app: status and Scan up top, then every recorded app.
/// Selecting an app pushes its detail (and from there its API docs) within the panel.
struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var scanner: CodexScanner

    @State private var apps: [TargetApp] = []
    @State private var browserIDs: Set<String> = []
    @State private var codexApproved: Set<String>?
    @State private var selectedPID: pid_t?
    /// Mac app vs SaaS website; the Apps list below follows it too.
    @AppStorage("scanWeb") private var scanWeb = false
    @State private var targetURLString = ""
    @State private var scopeText = ""
    @ObservedObject private var permissions = PermissionMonitor.shared
    @ObservedObject private var setup = SetupChecker.shared
    @AppStorage(SetupChecklist.completedKey) private var setupCompleted = false
    @State private var error: String?
    @State private var starting = false
    static let width: CGFloat = 400
    /// Height of pushed views; the root sizes to its content.
    static let detailHeight: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            engineBanner
            Divider()
            Group {
                if setup.shouldShow(model: model, permissions: permissions, completed: setupCompleted, scanning: recorder.isActive || scanner.isRunning) {
                    SetupChecklistView()
                } else if let route = model.panelPath.last {
                    pushed(route)
                        .frame(height: Self.detailHeight)
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)).combined(with: .opacity))
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        recorderCard
                        AppsListView(web: scanWeb) { key in push(.app(key)) }
                    }
                    .padding(14)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .environmentObject(model.workspace)
            .clipped()
        }
        .frame(width: Self.width)
        .onAppear {
            model.panelVisible = true
            refresh()
            permissions.viewAppeared()
            model.workspace.viewAppeared()
        }
        .onDisappear {
            model.panelVisible = false
            permissions.viewDisappeared()
            model.workspace.viewDisappeared()
        }
    }

    private func push(_ r: PanelRoute) { model.push(r) }
    private func pop() { model.pop() }

    @ViewBuilder private func pushed(_ route: PanelRoute) -> some View {
        switch route {
        case .app(let key):
            if let g = model.workspace.group(key) {
                AppDetailView(group: g, onBack: pop, onAPIDocs: { push(.apiDocs(key)) }).id(key)
            } else {
                missing
            }
        case .apiDocs(let key):
            if let g = model.workspace.group(key) {
                APIDocsView(group: g, onBack: pop).id("api:\(key)")
            } else {
                missing
            }
        }
    }

    private var missing: some View {
        VStack(spacing: 0) {
            PanelNavBar(back: "Apps", title: "", onBack: model.popToRoot) { EmptyView() }
            Divider()
            ContentUnavailableView("App not found", systemImage: "questionmark.app", description: Text("Its recordings were deleted or belong to another server."))
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            RetraceMark(size: 20, template: false)
            Text("Retrace").font(.headline)
            Spacer()
            statusBadge
            Button { setup.requested = true } label: { Image(systemName: "checklist") }
                .buttonStyle(.borderless)
                .disabled(recorder.isActive || scanner.isRunning)
                .help("Setup checklist")
                .accessibilityLabel("Setup")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless)
                .disabled(recorder.isActive)
                .help(recorder.isActive ? "Stop the scan before quitting" : "Quit Retrace")
                .accessibilityLabel("Quit Retrace")
        }
    }

    /// Only when something needs attention: the engine is starting or stopped, or analysis isn't set up.
    @ViewBuilder private var engineBanner: some View {
        if !model.isServerReady {
            EngineStatusRow()
                .padding(.horizontal, 14).padding(.bottom, 8)
        } else if model.analysisNeedsSetup {
            Label("Analysis isn't configured: the engine has no Nemotron key, so recordings can be uploaded but not analyzed.",
                  systemImage: "sparkles")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.bottom, 8)
        }
    }

    private var statusBadge: some View {
        Group {
            switch recorder.state {
            case .idle: Label("Idle", systemImage: "circle")
            case .recording: Label("Scanning", systemImage: "record.circle.fill").foregroundStyle(.red)
            case .paused: Label("Paused", systemImage: "pause.circle").foregroundStyle(.orange)
            case .stopping: Label("Saving…", systemImage: "ellipsis.circle")
            }
        }
        .font(.caption)
    }


    // MARK: Recorder

    @ViewBuilder private var recorderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if recorder.state == .idle && !scanner.isRunning {
                idleSection
                NetworkCaptureStatusView(controller: recorder.network)
            } else {
                recordingSection
            }
            if !scanner.status.isEmpty {
                Text(scanner.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let notice = recorder.notice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private var idleSection: some View {
        Picker("Scan target", selection: $scanWeb) {
            Text("Mac app").tag(false)
            Text("SaaS website").tag(true)
        }
        .pickerStyle(.segmented)
        .onChange(of: scanWeb) { _, _ in selectedPID = nil }
        if scanWeb {
            TextField("https://app.example.com", text: $targetURLString)
                .textFieldStyle(.roundedBorder)
            Text("Choose a running browser below; the scan uses its signed-in session. Close unrelated browser windows and tabs first: screenshots can include all of the browser's windows, not just this site. URL scope guides the agent; it does not restrict screen capture. Query strings and fragments are removed.")
                .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            if !targetURLString.isEmpty, (try? CodexScan.targetURL(targetURLString)) == nil {
                Text("Enter an HTTP(S) URL without a username or password.").font(.caption2).foregroundStyle(.red)
            }
            browserSetupNote
        }
        TextField("Scope (optional): e.g. only the checkout flow, or Settings → Billing", text: $scopeText, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...3)
            .help("Steers Codex toward one part of the \(scanWeb ? "site" : "app"). Safety rules still apply.")
        if scopeText.trimmingCharacters(in: .whitespacesAndNewlines).count > CodexScan.maxScopeLength {
            Text("Only the first \(CodexScan.maxScopeLength) characters are used.").font(.caption2).foregroundStyle(.secondary)
        }
        HStack(spacing: 6) {
            Picker("App", selection: $selectedPID) {
                Text(scanWeb ? "Choose a browser…" : "Choose an app…").tag(pid_t?.none)
                ForEach(selectableApps) { a in Text(a.name).tag(pid_t?.some(a.id)) }
            }
            .labelsHidden()
            Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh running apps")
            Button {
                startRecording()
            } label: {
                Label(starting ? "Starting…" : scanWeb ? "Scan Site" : "Scan App", systemImage: "sparkle.magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canStart)
            .help("Let Codex explore the chosen app")
        }
        if !permissions.allGranted {
            VStack(alignment: .leading, spacing: 6) {
                permissionRow("Accessibility", granted: permissions.accessibility, why: "clicks, named keys, element roles",
                              request: permissions.requestAccessibility, settings: Permissions.openAccessibilitySettings)
                permissionRow("Screen Recording", granted: permissions.screenRecording, why: "app-only evidence frames",
                              request: permissions.requestScreenRecording, settings: permissions.openScreenRecordingSettings)
                if !permissions.screenRecording && permissions.screenRecordingMayNeedRelaunch {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.blue)
                        Text("Already turned on Screen Recording? Relaunch Retrace to apply it.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Relaunch") { PermissionMonitor.relaunch() }
                            .controlSize(.small)
                            .disabled(recorder.isActive)
                    }
                }
            }
        }
        Text("Codex will control this app and send screenshots and UI information to your configured Codex provider during the scan. It explores safe reachable functionality, then saves partial coverage for review. Requires signed-in Codex CLI with computer use enabled.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var runningBrowsers: [TargetApp] { apps.filter { browserIDs.contains($0.bundleId) } }

    /// Web scans only offer browsers Codex computer use is set up to control ("Always allow" in Codex).
    private var selectableApps: [TargetApp] {
        guard scanWeb else { return apps }
        return runningBrowsers.filter { codexApproved?.contains($0.bundleId) == true }
    }

    @ViewBuilder private var browserSetupNote: some View {
        let missing = runningBrowsers.filter { codexApproved?.contains($0.bundleId) != true }.map(\.name)
        if codexApproved == nil {
            Text("Couldn't read which browsers Codex computer use may control. In Codex, ask it to use your browser and choose Always allow, then refresh.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if !missing.isEmpty {
            Text("Not set up with Codex computer use: \(missing.joined(separator: ", ")). To add one, ask Codex to use it and choose Always allow, then refresh.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var canStart: Bool {
        selectedPID != nil && permissions.allGranted && !starting && !scanner.isRunning
            && (!scanWeb || (try? CodexScan.targetURL(targetURLString)) != nil)
    }

    @ViewBuilder private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Scanning \(recorder.targetName ?? "—") with Codex").font(.subheadline.bold())
            NetworkCaptureStatusView(controller: recorder.network)
            if let start = recorder.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("Elapsed \(Self.format(ctx.date.timeIntervalSince(start)))").monospacedDigit()
                }
                .font(.caption)
            }
            if case .paused(let reason) = recorder.state {
                Label("Paused: \(reason). Capture resumes when the app is frontmost again.", systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("\(recorder.interactionCount) events · \(recorder.frameCount) frames · \(recorder.droppedCount) ignored (outside target)")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        if scanner.isRunning {
            Button { scanner.wrapUp() } label: {
                Label(scanner.isWrappingUp ? "Wrapping Up…" : "Wrap Up & Write Report", systemImage: "flag.checkered")
                    .frame(maxWidth: .infinity)
            }
            .disabled(scanner.isWrappingUp)
        }
        Button(role: .destructive) { stopRecording() } label: {
            Label("Cancel Scan & Review", systemImage: "stop.circle").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(recorder.state == .stopping)
    }

    private func stopRecording() {
        if scanner.isRunning { scanner.cancel() }
        else {
            Task {
                let s = await recorder.stop()
                model.didFinishRecording(s)
            }
        }
    }

    private func permissionRow(_ name: String, granted: Bool, why: String, request: @escaping () -> Void, settings: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.caption.bold())
                Text(why).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Request") { request() }.controlSize(.small)
                Button("Settings") { settings() }.controlSize(.small)
            }
        }
    }

    private func refresh() {
        apps = TargetApp.candidates()
        // Any installed app that opens web links is a browser (Helium, Arc, Safari…), not a fixed list.
        browserIDs = Set(NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!)
            .compactMap { Bundle(url: $0)?.bundleIdentifier })
        codexApproved = CodexScan.approvedBundleIDs()
        if let sel = selectedPID, !selectableApps.contains(where: { $0.id == sel }) { selectedPID = nil }
        permissions.refresh()
    }

    private func startRecording() {
        guard let pid = selectedPID, let target = apps.first(where: { $0.id == pid }) else { return }
        error = nil
        let url: URL?
        do { url = scanWeb ? try CodexScan.targetURL(targetURLString) : nil }
        catch { self.error = error.localizedDescription; return }
        scanner.start(app: target.app, recorder: recorder, targetURL: url, scope: CodexScan.scope(scopeText)) { session in
            model.didFinishRecording(session)
        }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
