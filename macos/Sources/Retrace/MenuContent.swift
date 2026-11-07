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

struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var recorder: Recorder
    @Environment(\.openWindow) private var openWindow

    @State private var apps: [TargetApp] = []
    @State private var selectedPID: pid_t?
    @State private var task = ""
    @State private var axGranted = Permissions.accessibilityGranted
    @State private var screenGranted = Permissions.screenRecordingGranted
    @State private var error: String?
    @State private var starting = false

    private var open: WindowOpener { WindowOpener(openWindow: openWindow) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Retrace").font(.headline)
                Spacer()
                statusBadge
            }
            Divider()
            if recorder.state == .idle {
                idleSection
            } else {
                recordingSection
            }
            if let notice = recorder.notice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Divider()
            HStack {
                Button("Sessions…") { open(WindowID.review) }
                Button("Pair…") { open(WindowID.pairing) }
                Button("Scope & Privacy…") { open(WindowID.scope) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.disabled(recorder.isActive)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(14)
        .frame(width: 380)
        .onAppear(perform: refresh)
    }

    private var statusBadge: some View {
        Group {
            switch recorder.state {
            case .idle: Label("Idle", systemImage: "circle")
            case .recording: Label("Recording", systemImage: "record.circle.fill").foregroundStyle(.red)
            case .paused: Label("Paused", systemImage: "pause.circle").foregroundStyle(.orange)
            case .stopping: Label("Saving…", systemImage: "ellipsis.circle")
            }
        }
        .font(.caption)
    }

    @ViewBuilder private var idleSection: some View {
        HStack {
            Picker("App", selection: $selectedPID) {
                Text("Choose an app…").tag(pid_t?.none)
                ForEach(apps) { a in Text(a.name).tag(pid_t?.some(a.id)) }
            }
            Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh running apps")
        }
        TextField("Task you will demonstrate (e.g. \"Create an invoice\")", text: $task, axis: .vertical)
            .lineLimit(1...3)
            .textFieldStyle(.roundedBorder)

        VStack(alignment: .leading, spacing: 6) {
            permissionRow("Accessibility", granted: axGranted, why: "clicks, named keys, element roles",
                          request: Permissions.requestAccessibility, settings: Permissions.openAccessibilitySettings)
            permissionRow("Screen Recording", granted: screenGranted, why: "app-only evidence frames",
                          request: Permissions.requestScreenRecording, settings: Permissions.openScreenRecordingSettings)
        }

        Text("Only the chosen app's windows are captured, and only while it is frontmost. Typed text is never recorded. Everything stays on this Mac until you review it and press Upload & Analyze.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Button {
            startRecording()
        } label: {
            Label(starting ? "Starting…" : "Start Recording", systemImage: "record.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canStart)
    }

    private var canStart: Bool {
        selectedPID != nil && !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && axGranted && screenGranted && !starting
    }

    @ViewBuilder private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Target: \(recorder.targetName ?? "—")").font(.subheadline.bold())
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
                .font(.caption).foregroundStyle(.secondary)
        }
        Button(role: .destructive) {
            Task {
                let s = await recorder.stop()
                model.didFinishRecording(s)
            }
        } label: {
            Label("Stop & Review", systemImage: "stop.circle").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(recorder.state == .stopping)
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
                Button("Request") { request(); refreshPermissionsSoon() }.controlSize(.small)
                Button("Settings") { settings() }.controlSize(.small)
            }
        }
    }

    private func refresh() {
        apps = TargetApp.candidates()
        if let sel = selectedPID, !apps.contains(where: { $0.id == sel }) { selectedPID = nil }
        axGranted = Permissions.accessibilityGranted
        screenGranted = Permissions.screenRecordingGranted
    }

    private func refreshPermissionsSoon() {
        Task { @MainActor in
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(1))
                axGranted = Permissions.accessibilityGranted
                screenGranted = Permissions.screenRecordingGranted
            }
        }
    }

    private func startRecording() {
        guard let pid = selectedPID, let target = apps.first(where: { $0.id == pid }) else { return }
        error = nil
        starting = true
        Task {
            defer { starting = false }
            do {
                try await recorder.start(app: target.app, task: task.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
