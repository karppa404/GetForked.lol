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
    @AppStorage("didShowRecorderSetup") private var didShowRecorderSetup = false

    var body: some View {
        Group {
            switch recorder.state {
            case .idle: Image(systemName: "exclamationmark")
            case .recording: Image(systemName: "record.circle.fill")
            case .paused: Image(systemName: "pause.circle")
            case .stopping: Image(systemName: "ellipsis.circle")
            }
        }
        .onAppear {
            guard !didShowRecorderSetup else { return }
            didShowRecorderSetup = true
            Task { @MainActor in
                await Task.yield()
                WindowOpener(openWindow: openWindow)(WindowID.recorder)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .retraceOpenReview)) { _ in
            WindowOpener(openWindow: openWindow)(WindowID.review)
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
