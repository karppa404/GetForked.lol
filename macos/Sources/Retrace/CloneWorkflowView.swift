import AppKit
import RetraceCore
import SwiftUI

/// The menu bar panel for the clone workflow:
/// Select an application → Scan it with Codex → Review requirements → Prepare a repository of agent tasks.
/// Everything runs locally with the signed-in Codex CLI; the analysis server is not involved.
struct CloneWorkflowView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var scanner: CodexScanner

    @EnvironmentObject var workflow: CloneWorkflowModel
    @StateObject private var readiness = ToolReadinessModel()
    @ObservedObject private var permissions = PermissionMonitor.shared

    // Target
    @State private var apps: [TargetApp] = []
    @State private var browserIDs: Set<String> = []
    @State private var selectedPID: pid_t?
    @AppStorage("cloneTargetIsWeb") private var targetIsWeb = false
    @State private var targetURLString = ""
    @State private var scopeText = ""

    // Scan
    @State private var scanAttempted = false
    @State private var scanError: String?

    // Requirements and build
    @State private var expandedStories: Set<String> = []
    @State private var expandedTasks: Set<String> = []
    @State private var showReport = false
    @State private var parentDirectory = CloneWorkflowView.defaultParentDirectory()
    @State private var lastAction: Action?
    @State private var confirmingReset = false

    private enum Action { case generate, createRepository }

    static let width: CGFloat = 460
    static let height: CGFloat = 640

    var body: some View {
        VStack(spacing: 0) {
            header
            CloneStageBar(current: workflow.stage, isDone: isDone, isReachable: isReachable) { go($0) }
                .padding(.horizontal, 10).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if confirmingReset { resetConfirmation }
                    if let error = workflow.error { errorBanner(error) }
                    stageContent
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(workflow.stage)
            Divider()
            footer
        }
        .frame(width: Self.width, height: Self.height)
        .tint(CloneTheme.fill)
        .onAppear {
            model.panelVisible = true
            refreshTargets()
            permissions.viewAppeared()
        }
        .onDisappear {
            model.panelVisible = false
            permissions.viewDisappeared()
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 10) {
            RetraceMark(size: 22, template: false)
            VStack(alignment: .leading, spacing: 0) {
                Text("Retrace").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Menu {
                Button("Start Over…") { confirmingReset = true }
                    .disabled(isBusy || !hasProgress)
                Divider()
                Button("Quit Retrace") { NSApp.terminate(nil) }
                    .disabled(isBusy)
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 12)
    }

    private var subtitle: String {
        switch workflow.stage {
        case .select: "Choose what to clone"
        case .scan: isScanning ? "Codex is exploring \(recorder.targetName ?? targetName)" : "Capture screens and network activity"
        case .requirements: workflow.plan == nil ? "Review the evidence" : "Review the requirements"
        case .build: workflow.repositoryURL == nil ? "Set up the repository" : "Ready for your agents"
        }
    }

    private var resetConfirmation: some View {
        CloneBanner(kind: .warning, text: "Start over? The scan stays saved on this Mac, but this plan and your place in the workflow are cleared.") {
            Button("Start Over", role: .destructive) {
                confirmingReset = false
                startOver()
            }
            .disabled(isBusy)
            Button("Keep Going") { confirmingReset = false }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        CloneBanner(kind: .error, text: message) {
            if let lastAction, !workflow.isWorking {
                Button("Try Again") { retry(lastAction) }.disabled(!canRetry(lastAction))
            }
            Button("Dismiss") { workflow.error = nil }
        }
    }

    @ViewBuilder private var stageContent: some View {
        switch workflow.stage {
        case .select: selectStage
        case .scan: scanStage
        case .requirements: requirementsStage
        case .build: buildStage
        }
    }

    // MARK: Stage 1 · Select

    @ViewBuilder private var selectStage: some View {
        CloneCard(title: "Application", symbol: "macwindow") {
            Picker("Kind of application", selection: $targetIsWeb) {
                Text("Mac app").tag(false)
                Text("Web app").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: targetIsWeb) { _, _ in
                selectedPID = nil
                refreshTargets()
            }
            if targetIsWeb {
                field("Address") {
                    TextField("https://app.example.com", text: $targetURLString)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Web app address")
                }
                if let problem = urlProblem {
                    Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            field(targetIsWeb ? "Browser" : "App") {
                HStack(spacing: 6) {
                    Picker(targetIsWeb ? "Browser" : "App", selection: $selectedPID) {
                        Text(targetIsWeb ? "Choose a running browser…" : "Choose a running app…").tag(pid_t?.none)
                        ForEach(selectableApps) { app in Text(app.name).tag(pid_t?.some(app.id)) }
                    }
                    .labelsHidden()
                    Button { refreshTargets() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh the list of running apps")
                        .accessibilityLabel("Refresh running apps")
                }
            }
            if targetIsWeb, selectableApps.isEmpty {
                Text("Open the browser where you're signed in to the web app, then refresh. Codex asks for permission when the scan starts.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if !targetIsWeb, apps.isEmpty {
                Text("Open the app you want to clone, then refresh.").font(.caption).foregroundStyle(.secondary)
            }
            field("Focus (optional)") {
                TextField("For example: only the checkout flow", text: $scopeText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .accessibilityLabel("Focus area, optional")
            }
            if scopeText.trimmingCharacters(in: .whitespacesAndNewlines).count > CodexScan.maxScopeLength {
                Text("Only the first \(CodexScan.maxScopeLength) characters are used.").font(.caption).foregroundStyle(.secondary)
            }
        }
        toolsCard
        if !permissions.allGranted { permissionsCard }
    }

    private var toolsCard: some View {
        CloneCard(title: "Tools", symbol: "wrench.and.screwdriver") {
            CloneReadinessRow(name: "Codex", purpose: "Runs the scan and writes the requirements.",
                              check: readiness.codex,
                              hint: codexInstalled ? "Sign in from Terminal, then check again." : "Install Codex and sign in from Terminal, then check again.",
                              commands: codexInstalled ? [SetupChecklist.loginCommand] : [SetupChecklist.installCommand, SetupChecklist.loginCommand])
            CloneReadinessRow(name: "Codex computer use", purpose: "Lets Codex click through the application.",
                              check: readiness.computerUse,
                              hint: "Turn on computer use in Codex, then check again. This command lists what's enabled.",
                              commands: [SetupChecklist.mcpListCommand])
            CloneReadinessRow(name: "GitHub CLI", purpose: "Needed in the Build step to set up the repository.",
                              check: readiness.github,
                              hint: githubInstalled ? "Sign in from Terminal, then check again." : "Install the GitHub CLI and sign in from Terminal, then check again.",
                              commands: githubInstalled ? ["gh auth login"] : ["brew install gh", "gh auth login"])
            HStack(spacing: 8) {
                Button {
                    readiness.refresh()
                } label: {
                    Label(readiness.isChecking ? "Checking…" : "Check Again", systemImage: "arrow.clockwise")
                }
                .disabled(readiness.isChecking)
                if anyToolMissing {
                    Button("Open Terminal") { Self.openTerminal() }
                }
                Spacer()
            }
            .controlSize(.small)
        }
    }

    private var permissionsCard: some View {
        CloneCard(title: "Mac permissions", symbol: "lock.shield", tint: .orange) {
            permissionRow("Accessibility", why: "Reads the controls Codex interacts with.", granted: permissions.accessibility,
                          request: permissions.requestAccessibility, settings: Permissions.openAccessibilitySettings)
            permissionRow("Screen Recording", why: "Saves screenshots of the selected app only.", granted: permissions.screenRecording,
                          request: permissions.requestScreenRecording, settings: permissions.openScreenRecordingSettings)
            if !permissions.screenRecording, permissions.screenRecordingMayNeedRelaunch {
                HStack(spacing: 8) {
                    Text("Already turned on Screen Recording? Relaunch Retrace to apply it.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Relaunch") { PermissionMonitor.relaunch() }.controlSize(.small).disabled(isBusy)
                }
            }
        }
    }

    private func permissionRow(_ name: String, why: String, granted: Bool,
                               request: @escaping () -> Void, settings: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? CloneTheme.accent : .orange)
                .frame(width: 16)
                .accessibilityLabel(granted ? "Allowed" : "Not allowed")
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout.weight(.medium))
                Text(why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if !granted {
                Button("Allow") { request() }.controlSize(.small).accessibilityLabel("Allow \(name)")
                Button("Settings") { settings() }.controlSize(.small).accessibilityLabel("Open \(name) settings")
            }
        }
    }

    // MARK: Stage 2 · Scan

    @ViewBuilder private var scanStage: some View {
        if isScanning {
            liveScanCard
        } else if let session = workflow.session {
            CloneCard(title: "Scan saved", symbol: "checkmark.seal.fill") {
                evidenceMetrics(session)
                Text("Scanning again replaces this evidence in the workflow. The earlier scan stays saved on this Mac.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            targetSummaryCard
            disclosureCard
        } else {
            if scanAttempted, let message = scanFailureMessage {
                CloneBanner(kind: .warning, text: message) { EmptyView() }
            }
            targetSummaryCard
            disclosureCard
            if !permissions.allGranted { permissionsCard }
            if readiness.codex.status != .ok || readiness.computerUse.status != .ok { toolsCard }
        }
    }

    private var targetSummaryCard: some View {
        CloneCard(title: "What gets scanned", symbol: "scope") {
            summaryRow(targetIsWeb ? "Web app" : "App", targetIsWeb ? (validURL?.absoluteString ?? "Not set") : targetName)
            if targetIsWeb { summaryRow("Browser", targetName) }
            summaryRow("Focus", CodexScan.scope(scopeText) ?? "The whole application")
        }
    }

    private var disclosureCard: some View {
        CloneCard(title: "Before you start", symbol: "hand.raised") {
            CloneBullet(text: "Codex takes control of \(targetIsWeb ? "the browser" : targetName) and explores it with computer use. Leave the mouse and keyboard alone while it works.")
            CloneBullet(text: "Codex receives what's on screen in that app — its controls, text and screenshots — through your Codex account. Close anything you don't want shared.")
            CloneBullet(text: "Retrace saves screenshots around interactions and at checkpoints. Supported Chromium apps can also capture timestamped network requests with secrets redacted; network capture is optional.")
            CloneBullet(text: "Codex is told not to submit, buy, send or delete. It asks you before any action it isn't sure about.")
        }
    }

    private var liveScanCard: some View {
        CloneCard {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 7) {
                    if recorder.state == .stopping || !scanner.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Circle().fill(CloneTheme.accent).frame(width: 8, height: 8).accessibilityHidden(true)
                    }
                    Text(liveTitle).font(.subheadline.weight(.semibold))
                }
                .accessibilityAddTraits(.isHeader)
                Spacer()
                if let start = recorder.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(CloneCopy.elapsed(context.date.timeIntervalSince(start)))
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            .accessibilityLabel("Elapsed \(CloneCopy.elapsed(context.date.timeIntervalSince(start)))")
                    }
                }
            }
            HStack(spacing: 6) {
                CloneMetric(value: scanner.steps, label: "steps")
                CloneMetric(value: recorder.frameCount, label: "screens")
                CloneMetric(value: recorder.interactionCount, label: "actions")
                CloneMetric(value: recorder.droppedCount, label: "ignored")
            }
            if !scanner.status.isEmpty {
                Text(scanner.status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            NetworkCaptureStatusView(controller: recorder.network)
            if case .paused(let reason) = recorder.state {
                Label("Paused: \(reason). Capture resumes when the app is in front again.", systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let notice = recorder.notice {
                Text(notice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("“Ignored” counts input outside the selected app. It is never recorded.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var liveTitle: String {
        if recorder.state == .stopping || !scanner.isRunning { return "Saving evidence…" }
        if scanner.isWrappingUp { return "Wrapping up \(recorder.targetName ?? targetName)" }
        return "Scanning \(recorder.targetName ?? targetName)"
    }

    /// Why the last scan produced nothing to review.
    private var scanFailureMessage: String? {
        if let scanError { return scanError }
        return scanner.status.isEmpty ? "The scan ended without saving any evidence. Try again." : scanner.status
    }

    // MARK: Stage 3 · Requirements

    @ViewBuilder private var requirementsStage: some View {
        if let session = workflow.session {
            if workflow.isWorking {
                workingCard("Writing requirements")
            } else if let plan = workflow.plan {
                planCards(plan)
            } else {
                evidenceCards(session)
            }
        } else {
            emptyState("No scan yet", "Scan an application first. Requirements are written from what the scan captured.")
        }
    }

    @ViewBuilder private func evidenceCards(_ session: LocalSession) -> some View {
        CloneCard(title: "Evidence from \(session.manifest.app.name)", symbol: "tray.full") {
            evidenceMetrics(session)
            Label(networkSummary(session.manifest), systemImage: session.manifest.networkStatus == .observed ? "network" : "network.slash")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.open(session.framesDirectory)
                } label: { Label("Review Screenshots", systemImage: "photo.on.rectangle") }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([session.directory])
                } label: { Label("Show Scan Folder", systemImage: "folder") }
            }
            .controlSize(.small)
        }
        CloneCard(title: "Coverage gaps", symbol: "exclamationmark.magnifyingglass", tint: .orange) {
            ForEach(coverageGaps(session.manifest), id: \.self) { CloneBullet(text: $0, symbol: "minus", tint: .orange) }
            if let report = session.manifest.scanReport, !report.isEmpty {
                DisclosureGroup("Codex's scan report", isExpanded: $showReport) {
                    Text(report).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.caption.weight(.medium))
            }
        }
        CloneCard(title: "Before you generate", symbol: "hand.raised") {
            CloneBullet(text: "Generating sends this scan's recorded text and up to six screenshots to Codex: control labels, on-screen text Codex noted, the scan report, and redacted network metadata.")
            CloneBullet(text: "Look through the screenshots first. If something private was captured, start over and scan again with it closed.")
            if workflow.status.contains("cancelled") {
                Text(workflow.status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func planCards(_ plan: ClonePlan) -> some View {
        CloneCard(title: plan.title, symbol: "doc.text") {
            Text(plan.summary).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Text("\(CloneCopy.count(plan.stories.count, "user story", "user stories")) · \(CloneCopy.count(plan.tasks.count, "build task", "build tasks"))")
                .font(.caption).foregroundStyle(.secondary)
        }
        CloneCard(title: "User stories", symbol: "person.text.rectangle") {
            ForEach(Array(plan.stories.enumerated()), id: \.element.id) { index, story in
                if index > 0 { Divider() }
                DisclosureGroup(isExpanded: expansion($expandedStories, story.id)) {
                    VStack(alignment: .leading, spacing: 5) {
                        sectionLabel("Done when")
                        ForEach(story.acceptanceCriteria, id: \.self) { CloneBullet(text: $0, symbol: "checkmark", tint: CloneTheme.accent) }
                        if !story.evidence.isEmpty {
                            sectionLabel("Evidence")
                            Text(story.evidence.joined(separator: ", "))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                    .padding(.top, 4).padding(.bottom, 2)
                } label: {
                    Text(story.title).font(.callout).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        CloneCard(title: "Not verified by the scan", symbol: "exclamationmark.magnifyingglass", tint: .orange) {
            if plan.unknowns.isEmpty {
                Text("Codex listed no open questions. Parts of the app the scan never reached are still unverified.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(plan.unknowns, id: \.self) { CloneBullet(text: $0, symbol: "minus", tint: .orange) }
            }
        }
        CloneCard {
            Toggle(isOn: $workflow.requirementsApproved) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("These requirements look right").font(.callout.weight(.medium))
                    Text("Build tasks are written from them, so fix anything wrong by generating again.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            Button {
                generate()
            } label: { Label("Generate Again", systemImage: "arrow.triangle.2.circlepath") }
                .controlSize(.small)
                .help("Sends the scan's recorded text to Codex again and replaces this plan")
        }
    }

    // MARK: Stage 4 · Build

    @ViewBuilder private var buildStage: some View {
        if let plan = workflow.plan {
            if let repository = workflow.repositoryURL {
                repositoryReadyCard(repository, plan)
            } else if workflow.isWorking {
                workingCard("Creating the repository")
            }
            CloneCard(title: "Stack", symbol: "square.stack.3d.up") {
                CloneChipLayout {
                    ForEach(plan.stack, id: \.self) { item in
                        Text(item).font(.caption.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(CloneTheme.wash, in: Capsule())
                            .overlay(Capsule().strokeBorder(CloneTheme.accent.opacity(0.35)))
                    }
                }
                Text("Chosen by Codex from what the scan observed.").font(.caption).foregroundStyle(.secondary)
            }
            tasksCard(plan)
            if workflow.repositoryURL == nil, !workflow.isWorking {
                repositorySetupCard
                if readiness.github.status != .ok { githubCard }
            }
        } else {
            emptyState("No requirements yet", "Generate and approve requirements first. Tasks are written from them.")
        }
    }

    private func tasksCard(_ plan: ClonePlan) -> some View {
        CloneCard(title: "Tasks for agents", symbol: "checklist") {
            Text(workflow.repositoryURL == nil
                 ? "Each task becomes a prompt file in the repository. Nothing runs until you hand them to an agent."
                 : "Prepared as prompt files. None have been started.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(plan.tasks.enumerated()), id: \.element.id) { index, task in
                Divider()
                DisclosureGroup(isExpanded: expansion($expandedTasks, task.id)) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(task.instructions).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        sectionLabel("Done when")
                        ForEach(task.acceptanceCriteria, id: \.self) { CloneBullet(text: $0, symbol: "checkmark", tint: CloneTheme.accent) }
                    }
                    .padding(.top, 4).padding(.bottom, 2)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1)").font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary).frame(minWidth: 16, alignment: .trailing)
                            .accessibilityLabel("Task \(index + 1)")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(task.title).font(.callout).fixedSize(horizontal: false, vertical: true)
                            Text(task.dependencies.isEmpty ? "Can start first" : "After \(dependencyNames(task, in: plan))")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var repositorySetupCard: some View {
        CloneCard(title: "Repository", symbol: "shippingbox") {
            field("Name") {
                TextField("app-clone", text: $workflow.repositoryName)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .accessibilityLabel("Repository name")
            }
            if let problem = repositoryNameProblem {
                Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            field("Location") {
                HStack(spacing: 8) {
                    Label(Self.displayPath(parentDirectory), systemImage: "folder")
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(parentDirectory.path)
                    Button("Change…") { chooseParentDirectory() }.controlSize(.small)
                }
            }
            Text("Creates a local Git repository with the requirements, the plan and one prompt file per task. Screenshots and network evidence are not copied into it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var githubCard: some View {
        CloneCard(title: "GitHub CLI needed", symbol: "exclamationmark.triangle.fill", tint: .orange) {
            CloneReadinessRow(name: "GitHub CLI", purpose: "Needed to set up the repository.",
                              check: readiness.github,
                              hint: githubInstalled ? "Sign in from Terminal, then check again." : "Install the GitHub CLI and sign in from Terminal, then check again.",
                              commands: githubInstalled ? ["gh auth login"] : ["brew install gh", "gh auth login"])
            HStack(spacing: 8) {
                Button {
                    readiness.refresh()
                } label: { Label(readiness.isChecking ? "Checking…" : "Check Again", systemImage: "arrow.clockwise") }
                    .disabled(readiness.isChecking)
                Button("Open Terminal") { Self.openTerminal() }
            }
            .controlSize(.small)
        }
    }

    private func repositoryReadyCard(_ repository: URL, _ plan: ClonePlan) -> some View {
        CloneCard(title: "Repository ready", symbol: "checkmark.seal.fill") {
            Text(Self.displayPath(repository)).font(.callout.monospaced())
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                .help(repository.path)
            Text("\(CloneCopy.count(plan.tasks.count, "task prompt is", "task prompts are")) waiting in the tasks folder. Give them to your coding agents in order — Retrace hasn't started any of them.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.open(repository)
                } label: { Label("Open in Finder", systemImage: "folder") }
                Button {
                    revealTaskDocs(in: repository)
                } label: { Label("Show Task Files", systemImage: "doc.text.magnifyingglass") }
            }
            .controlSize(.small)
        }
    }

    // MARK: Shared pieces

    private func workingCard(_ title: String) -> some View {
        CloneCard {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text(workflow.status).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func emptyState(_ title: String, _ message: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48).padding(.horizontal, 24)
    }

    private func evidenceMetrics(_ session: LocalSession) -> some View {
        HStack(spacing: 6) {
            CloneMetric(value: session.manifest.frames.count, label: "screens")
            CloneMetric(value: session.manifest.interactions.count, label: "actions")
            CloneMetric(value: session.manifest.network.count, label: "requests")
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
            Text(value).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
    }

    private func expansion(_ set: Binding<Set<String>>, _ id: String) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(id) },
                set: { if $0 { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) } })
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let blocker = blockers.first {
                Label(blocker, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                footerSecondary
                Spacer(minLength: 0)
                footerPrimary
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder private var footerSecondary: some View {
        if isScanning {
            Button("Cancel Scan", role: .destructive) { cancelScan() }
                .disabled(recorder.state == .stopping)
                .help("Stops Codex now and keeps whatever was captured so far")
        } else if workflow.isWorking {
            Button("Cancel") { workflow.cancel() }
        } else if let previous = previousStage {
            Button("Back") { go(previous) }
        }
    }

    @ViewBuilder private var footerPrimary: some View {
        switch workflow.stage {
        case .select:
            primary("Continue", enabled: targetValid) { go(.scan) }
        case .scan:
            if isScanning {
                primary(scanner.isWrappingUp ? "Wrapping Up…" : "Finish Scan", symbol: "flag.checkered",
                        enabled: scanner.isRunning && !scanner.isWrappingUp) { scanner.wrapUp() }
                    .help("Asks Codex to stop exploring and write its report")
            } else if workflow.session != nil {
                Button("Scan Again") { startScan() }.disabled(!canScan)
                primary("Review Evidence", enabled: true) { go(.requirements) }
            } else {
                primary(scanAttempted ? "Try Again" : "Start Scan", symbol: "sparkle.magnifyingglass", enabled: canScan) { startScan() }
            }
        case .requirements:
            if workflow.plan != nil {
                primary("Continue to Build", enabled: workflow.requirementsApproved && !workflow.isWorking) { go(.build) }
            } else {
                primary(workflow.isWorking ? "Generating…" : "Generate Requirements", symbol: "sparkles",
                        enabled: canGenerate) { generate() }
            }
        case .build:
            if workflow.repositoryURL != nil {
                primary("Clone Another App", enabled: !isBusy) { confirmingReset = true }
            } else {
                primary(workflow.isWorking ? "Creating…" : "Create Repository", symbol: "shippingbox",
                        enabled: canCreateRepository) { createRepository() }
            }
        }
    }

    private func primary(_ title: String, symbol: String? = nil, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
        }
        .buttonStyle(.borderedProminent)
        .tint(CloneTheme.fill)
        .disabled(!enabled)
        .keyboardShortcut(.defaultAction)
    }

    /// The first unmet requirement for the current stage's main action, in plain words.
    private var blockers: [String] {
        guard !isBusy else { return [] }
        switch workflow.stage {
        case .select:
            return targetBlockers
        case .scan:
            // With a scan already saved, the main action is reviewing it, which needs nothing.
            guard workflow.session == nil else { return [] }
            var list = targetBlockers
            if readiness.codex.status == .missing { list.append("Codex needs setup before scanning.") }
            else if readiness.computerUse.status == .missing { list.append("Codex computer use needs to be turned on before scanning.") }
            else if readiness.codex.status == .checking || readiness.computerUse.status == .checking { list.append("Checking Codex…") }
            if !permissions.allGranted { list.append("Allow Accessibility and Screen Recording to scan.") }
            return list
        case .requirements:
            if workflow.session == nil { return [] }
            if workflow.plan != nil { return workflow.requirementsApproved ? [] : ["Confirm the requirements look right to continue."] }
            return readiness.codex.status == .ok ? [] : ["Codex needs setup before it can write requirements."]
        case .build:
            guard workflow.plan != nil, workflow.repositoryURL == nil else { return [] }
            var list: [String] = []
            if !workflow.requirementsApproved { list.append("Approve the requirements in the previous step first.") }
            if repositoryNameProblem != nil { list.append("Fix the repository name.") }
            if readiness.github.status == .missing { list.append("The GitHub CLI needs setup before creating the repository.") }
            else if readiness.github.status == .checking { list.append("Checking the GitHub CLI…") }
            return list
        }
    }

    private var targetBlockers: [String] {
        var list: [String] = []
        if targetIsWeb, validURL == nil { list.append("Enter the web app's address.") }
        if selectedTarget == nil { list.append(targetIsWeb ? "Choose the browser to scan in." : "Choose an app to scan.") }
        return list
    }

    // MARK: State

    private var isScanning: Bool { scanner.isRunning || recorder.isActive }
    private var isBusy: Bool { isScanning || workflow.isWorking }
    private var hasProgress: Bool { workflow.session != nil || workflow.stage != .select }

    private var runningBrowsers: [TargetApp] { apps.filter { browserIDs.contains($0.bundleId) } }

    /// The scanner requests per-scan computer-use approval for the chosen browser.
    private var selectableApps: [TargetApp] {
        guard targetIsWeb else { return apps }
        return runningBrowsers
    }

    private var selectedTarget: TargetApp? {
        guard let selectedPID else { return nil }
        return selectableApps.first { $0.id == selectedPID && !$0.app.isTerminated }
    }

    private var targetName: String { selectedTarget?.name ?? "Not chosen" }
    private var validURL: URL? { try? CodexScan.targetURL(targetURLString) }

    private var urlProblem: String? {
        guard !targetURLString.trimmingCharacters(in: .whitespaces).isEmpty, validURL == nil else { return nil }
        return "Enter a full http:// or https:// address without a username or password."
    }

    private var targetValid: Bool { selectedTarget != nil && (!targetIsWeb || validURL != nil) }

    private var canScan: Bool {
        targetValid && !isBusy && permissions.allGranted
            && readiness.codex.status == .ok && readiness.computerUse.status == .ok
    }

    private var canGenerate: Bool {
        workflow.session != nil && !isBusy && readiness.codex.status == .ok
    }

    private var repositoryNameProblem: String? {
        do { try ClonePlan.validateRepositoryName(workflow.repositoryName); return nil }
        catch { return error.localizedDescription }
    }

    private var canCreateRepository: Bool {
        workflow.plan != nil && workflow.requirementsApproved && !isBusy
            && repositoryNameProblem == nil && readiness.github.status == .ok
    }

    private var codexInstalled: Bool { CodexScan.executable() != nil }
    private var githubInstalled: Bool { ToolReadiness.githubExecutable() != nil }
    private var anyToolMissing: Bool {
        [readiness.codex, readiness.computerUse, readiness.github].contains { $0.status == .missing }
    }

    private var previousStage: CloneStage? {
        let stages = CloneStage.allCases
        guard let index = stages.firstIndex(of: workflow.stage), index > 0 else { return nil }
        return stages[index - 1]
    }

    private func isDone(_ stage: CloneStage) -> Bool {
        switch stage {
        case .select: workflow.stage != .select || workflow.session != nil
        case .scan: workflow.session != nil
        case .requirements: workflow.plan != nil && workflow.requirementsApproved
        case .build: workflow.repositoryURL != nil
        }
    }

    /// Stages unlock in order, and nothing moves while a scan or Codex job is running.
    private func isReachable(_ stage: CloneStage) -> Bool {
        guard !isBusy else { return false }
        switch stage {
        case .select: return true
        case .scan: return targetValid || workflow.session != nil
        case .requirements: return workflow.session != nil
        case .build: return workflow.plan != nil && workflow.requirementsApproved
        }
    }

    // MARK: Actions

    private func go(_ stage: CloneStage) {
        guard isReachable(stage) else { return }
        confirmingReset = false
        withAnimation(.snappy(duration: 0.2)) { workflow.stage = stage }
    }

    private func refreshTargets() {
        apps = TargetApp.candidates()
        // Any installed app that opens web links counts as a browser, not a fixed list.
        browserIDs = Set(NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!)
            .compactMap { Bundle(url: $0)?.bundleIdentifier })
        if let selectedPID, !selectableApps.contains(where: { $0.id == selectedPID }) { self.selectedPID = nil }
        permissions.refresh()
    }

    private func startScan() {
        refreshTargets()
        guard canScan, let target = selectedTarget else { return }
        scanError = nil
        workflow.error = nil
        lastAction = nil
        let url: URL?
        do { url = targetIsWeb ? try CodexScan.targetURL(targetURLString) : nil }
        catch {
            scanError = error.localizedDescription
            scanAttempted = true
            return
        }
        scanAttempted = true
        scanner.start(app: target.app, recorder: recorder, targetURL: url, scope: CodexScan.scope(scopeText)) { session in
            model.refreshSessions()
            guard let session else { return }
            workflow.acceptScan(session)
            scanAttempted = false
            MenuBarPanel.open(unlessVisible: model.panelVisible)
        }
    }

    private func cancelScan() {
        if scanner.isRunning {
            scanner.cancel()
        } else {
            Task {
                let session = await recorder.stop()
                model.refreshSessions()
                if let session { workflow.acceptScan(session) }
            }
        }
    }

    private func generate() {
        guard canGenerate else { return }
        lastAction = .generate
        workflow.generateRequirements()
    }

    private func createRepository() {
        guard canCreateRepository else { return }
        lastAction = .createRepository
        workflow.createRepository(at: parentDirectory)
    }

    private func canRetry(_ action: Action) -> Bool {
        switch action {
        case .generate: canGenerate
        case .createRepository: canCreateRepository
        }
    }

    private func retry(_ action: Action) {
        switch action {
        case .generate: generate()
        case .createRepository: createRepository()
        }
    }

    private func startOver() {
        guard !isBusy else { return }
        workflow.reset()
        scanAttempted = false
        scanError = nil
        lastAction = nil
        expandedStories = []
        expandedTasks = []
        showReport = false
        refreshTargets()
    }

    private func chooseParentDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = parentDirectory
        panel.prompt = "Choose"
        panel.message = "Choose the folder that will contain the new repository."
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { parentDirectory = url }
        // The file dialog takes focus from the menu bar panel; bring it back.
        DispatchQueue.main.async { MenuBarPanel.open(unlessVisible: model.panelVisible) }
    }

    /// Selects the per-task prompt files in Finder, falling back to the task list, then the repository.
    private func revealTaskDocs(in repository: URL) {
        let fm = FileManager.default
        let folder = repository.appendingPathComponent("tasks", isDirectory: true)
        let prompts = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let list = repository.appendingPathComponent("TASKS.md")
        if !prompts.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(prompts)
        } else if fm.fileExists(atPath: list.path) {
            NSWorkspace.shared.activateFileViewerSelecting([list])
        } else {
            NSWorkspace.shared.open(repository)
        }
    }

    // MARK: Copy helpers

    private func networkSummary(_ manifest: SessionManifest) -> String {
        switch manifest.networkStatus {
        case .observed:
            return "\(CloneCopy.count(manifest.network.count, "network request", "network requests")) captured with timestamps. Secrets are redacted."
        case .noneObserved:
            return "Network capture ran, but the app made no requests during the scan."
        case .notCaptured:
            return "Network activity wasn't captured" + (manifest.networkNote.map { ": \($0)" } ?? ".")
        }
    }

    private func coverageGaps(_ manifest: SessionManifest) -> [String] {
        var gaps = ["A scan is a sample. Screens Codex didn't reach, and actions it was told not to take, are not covered."]
        if manifest.frames.isEmpty { gaps.append("No screenshots were saved, so requirements would rest on very little.") }
        switch manifest.networkStatus {
        case .observed: break
        case .noneObserved: gaps.append("No network requests were seen, so the backend's behavior is unknown.")
        case .notCaptured: gaps.append("Network activity wasn't captured, so API behavior will be inferred from screens only.")
        }
        if (manifest.scanReport ?? "").isEmpty { gaps.append("Codex didn't write a scan report, so there is no summary of what it skipped.") }
        return gaps
    }

    private func dependencyNames(_ task: CloneTask, in plan: ClonePlan) -> String {
        task.dependencies.map { id in
            plan.tasks.firstIndex { $0.id == id }.map { "task \($0 + 1)" } ?? id
        }.joined(separator: ", ")
    }

    private static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private static func defaultParentDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let developer = home.appendingPathComponent("Developer", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: developer.path, isDirectory: &isDirectory), isDirectory.boolValue { return developer }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? home
    }

    private static func findExecutable(_ name: String) -> Bool {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return (["/opt/homebrew/bin", "/usr/local/bin"] + path)
            .contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
    }

    private static func openTerminal() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
