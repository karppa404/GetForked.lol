import AppKit
import SwiftUI

@main
struct RetraceApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(model)
                .environmentObject(model.recorder)
        } label: {
            MenuBarLabel(recorder: model.recorder)
        }
        .menuBarExtraStyle(.window)

        Window("Retrace Recorder", id: WindowID.recorder) {
            MenuContent()
                .environmentObject(model)
                .environmentObject(model.recorder)
        }
        .windowResizability(.contentSize)

        Window("Retrace Sessions", id: WindowID.review) {
            ReviewWindow()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1100, height: 720)

        Window("Local Connection", id: WindowID.connection) {
            ConnectionView()
                .environmentObject(model)
                .frame(width: 520)
        }
        .windowResizability(.contentSize)

        Window("Capture Scope & Privacy", id: WindowID.scope) {
            CaptureScopeView()
                .frame(width: 620, height: 640)
        }
        .windowResizability(.contentSize)
    }
}

enum WindowID {
    static let recorder = "recorder"
    static let review = "review"
    static let connection = "connection"
    static let scope = "scope"
}

struct MenuBarLabel: View {
    @ObservedObject var recorder: Recorder
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            RetraceMark()
            switch recorder.state {
            case .idle: EmptyView()
            case .recording: Image(systemName: "circle.fill").foregroundStyle(.red).font(.system(size: 7))
            case .paused: Image(systemName: "pause.fill").font(.system(size: 8))
            case .stopping: Image(systemName: "ellipsis").font(.system(size: 8))
            }
        }
        .accessibilityLabel(statusDescription)
        .help(statusDescription)
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                WindowOpener(openWindow: openWindow)(WindowID.recorder)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .retraceOpenReview)) { _ in
            WindowOpener(openWindow: openWindow)(WindowID.review)
        }
    }

    private var statusDescription: String {
        switch recorder.state {
        case .idle: return "Retrace — ready to observe"
        case .recording: return "Retrace — observing app activity"
        case .paused: return "Retrace — observation paused"
        case .stopping: return "Retrace — saving recording"
        }
    }
}

/// Opens a window and brings this accessory (menu bar) app forward.
struct WindowOpener {
    let openWindow: OpenWindowAction
    func callAsFunction(_ id: String) {
        openWindow(id: id)
        NSApp.activate()
    }
}
