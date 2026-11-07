import RetraceCore
import SwiftUI

/// One-click connection to the Retrace server running on this Mac.
struct ConnectionView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Local workspace") {
                status
                switch model.connection {
                case .connecting:
                    ProgressView().controlSize(.small)
                case .connected:
                    Button("Disconnect (remove credential from Keychain)", role: .destructive) { model.disconnect() }
                case .disconnected, .failed:
                    Button("Connect to Local workspace") { model.connect() }
                        .buttonStyle(.borderedProminent)
                }
                Text("Connecting only stores a device credential. Nothing is uploaded until you review a session and press Upload & Analyze.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("This Mac") {
                TextField("Device name", text: $model.deviceName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.connection == .connecting)
            }
            Section("Server") {
                HStack {
                    TextField("API base URL", text: $model.apiBaseURLString)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.saveBaseURL() }
                    Button("Save") { model.saveBaseURL() }
                }
                Text("Default \(APIBaseURL.development). Local connection works only with a server on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                if let e = model.lastError { Text(e).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .onAppear { model.loadCredentialIfNeeded() }
    }

    @ViewBuilder private var status: some View {
        switch model.connection {
        case .disconnected:
            Label("Not connected.", systemImage: "link.badge.plus")
        case .connecting:
            Label("Connecting…", systemImage: "hourglass")
        case .connected:
            VStack(alignment: .leading) {
                Label("Connected to \(model.credential?.projectName ?? "Local workspace")", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                if let c = model.credential {
                    Text("\(c.apiBaseURL) · as “\(c.deviceName)” · since \(ReviewWindow.date(c.pairedAt)). Token stored in Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .failed(let m):
            Label(m, systemImage: "xmark.octagon").foregroundStyle(.red)
        }
    }
}
