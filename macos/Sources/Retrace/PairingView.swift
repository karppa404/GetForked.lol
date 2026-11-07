import RetraceCore
import SwiftUI

struct PairingView: View {
    @EnvironmentObject var model: AppModel
    @State private var code = ""

    var body: some View {
        Form {
            Section("Server") {
                HStack {
                    TextField("API base URL", text: $model.apiBaseURLString)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.saveBaseURL() }
                    Button("Save") { model.saveBaseURL() }
                }
                Text("Default \(APIBaseURL.development). Plain http is accepted only for localhost; use https for anything else. Each server has its own credential.")
                    .font(.caption).foregroundStyle(.secondary)
                if let e = model.lastError { Text(e).font(.caption).foregroundStyle(.red) }
            }
            Section("This Mac") {
                TextField("Device name", text: $model.deviceName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isBusy)
                Text("Shown in the browser so the approver can check it is this Mac.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Pairing") {
                status
                switch model.pairing {
                case .claiming, .pending:
                    Button("Cancel") { model.cancelPairing() }
                case .paired:
                    Button("Unpair (remove credential from Keychain)", role: .destructive) { model.unpair() }
                case .unpaired, .failed:
                    HStack {
                        TextField("Pairing code from the browser", text: $code)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(pair)
                        Button("Pair", action: pair).disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .onAppear { model.loadCredentialIfNeeded() }
    }

    private var isBusy: Bool {
        switch model.pairing { case .claiming, .pending: return true; default: return false }
    }

    private func pair() {
        model.startPairing(code: code)
        code = ""
    }

    @ViewBuilder private var status: some View {
        switch model.pairing {
        case .unpaired:
            Label("Not paired with this server.", systemImage: "link.badge.plus")
        case .claiming:
            Label("Claiming code…", systemImage: "hourglass")
        case .pending(_, let name):
            VStack(alignment: .leading) {
                Label("Waiting for approval in the browser", systemImage: "hourglass")
                Text("Approve only if the browser shows the device name “\(name)”. Retrace stops checking after 10 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .paired(let project):
            VStack(alignment: .leading) {
                Label("Paired with project \(project)", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
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
