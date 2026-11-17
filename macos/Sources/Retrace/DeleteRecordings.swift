import RetraceCore
import SwiftUI

extension View {
    /// A context menu item that deletes every recording of `group`, behind a confirmation.
    func deleteAllRecordingsMenu(_ group: AppGroup) -> some View { modifier(DeleteAllRecordingsMenu(group: group)) }
}

private struct DeleteAllRecordingsMenu: ViewModifier {
    @EnvironmentObject var workspace: WorkspaceModel
    let group: AppGroup
    @State private var confirming = false
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Delete All Recordings of \(group.name)…", systemImage: "trash", role: .destructive) { confirming = true }
                    .disabled(!group.recordings.allSatisfy(workspace.canDelete))
            }
            .confirmationDialog("Delete all recordings of \(group.name)?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Delete \(PanelFormat.plural(group.recordings.count, "Recording"))", role: .destructive) {
                    Task { error = await workspace.delete(group.recordings, in: group) }
                }
            } message: {
                Text("This removes \(group.recordings.count == 1 ? "it" : "them") from this Mac and the server.")
            }
            .alert("Couldn't delete recordings", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
    }
}
