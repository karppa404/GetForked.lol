import AppKit
import SwiftUI

@main
struct RetraceApp: App {
    @StateObject private var model = AppModel(startAnalysisEngine: false)

    /// The menu bar panel is the whole UI: everything else is a view pushed inside it.
    var body: some Scene {
        MenuBarExtra {
            CloneWorkflowView()
                .environmentObject(model)
                .environmentObject(model.cloneWorkflow)
                .environmentObject(model.recorder)
                .environmentObject(model.scanner)
        } label: {
            MenuBarLabel(recorder: model.recorder)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        HStack(spacing: 3) {
            // Template glyphs only, so the label tints like the system icons around it.
            RetraceMark(recording: recorder.state == .recording)
            switch recorder.state {
            case .idle, .recording: EmptyView()
            case .paused: Image(systemName: "pause.fill").font(.system(size: 8))
            case .stopping: Image(systemName: "ellipsis").font(.system(size: 8))
            }
        }
        .accessibilityLabel(statusDescription)
        .help(statusDescription)
        .onAppear {
            // Show the panel once at launch so it's clear where Retrace lives.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                MenuBarPanel.open(unlessVisible: false)
            }
        }
    }

    private var statusDescription: String {
        switch recorder.state {
        case .idle: return "Retrace — ready to scan"
        case .recording: return "Retrace — scanning app functionality"
        case .paused: return "Retrace — scan capture paused"
        case .stopping: return "Retrace — saving recording"
        }
    }
}

/// Opens the menu bar panel from code. `MenuBarExtra` has no API for that, so this clicks
/// Retrace's own status item. If the item can't be found nothing happens, and the panel still
/// shows the right view the next time it's opened.
@MainActor
enum MenuBarPanel {
    static func open(unlessVisible visible: Bool) {
        guard !visible, let button = statusButton() else { return }
        NSApp.activate()
        button.performClick(nil)
    }

    private static func statusButton() -> NSStatusBarButton? {
        for window in NSApp.windows where String(describing: type(of: window)) == "NSStatusBarWindow" {
            if let button = window.contentView.flatMap(find) { return button }
        }
        return nil
    }

    private static func find(_ view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews { if let b = find(sub) { return b } }
        return nil
    }
}
