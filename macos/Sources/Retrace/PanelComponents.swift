import AppKit
import RetraceCore
import SwiftUI

/// Where a group's "last captured screen" comes from.
enum ScreenSource: Equatable {
    case remote(sessionId: String, frameId: String)
    case local(URL)
    case none
}

extension WorkspaceModel {
    /// The newest recording's last screen: from the server when uploaded, else from this Mac.
    func screen(for g: AppGroup, local: [LocalSession]) -> ScreenSource {
        for r in g.recordings {
            if let rid = r.remoteId, let d = details[rid], let f = d.lastFrame, !imageFailed(rid, f.id) {
                return .remote(sessionId: rid, frameId: f.id)
            }
            if let lid = r.localId, let s = local.first(where: { $0.id == lid }),
               let f = s.manifest.frames.last(where: { !s.review.omittedFrameIds.contains($0.id) }) {
                return .local(s.url(for: f))
            }
        }
        return .none
    }
}

/// A captured screen, filled and clipped to a continuous rounded rectangle.
struct ScreenImage: View {
    @EnvironmentObject var workspace: WorkspaceModel
    let source: ScreenSource
    var cornerRadius: CGFloat
    var contentMode: ContentMode = .fill
    var bundleId: String?
    @State private var localImage: NSImage?
    @State private var localFailed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else if loading {
                ProgressView().controlSize(.small)
            } else {
                placeholder
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .task(id: source) { await load() }
        .accessibilityHidden(true)
    }

    private var image: NSImage? {
        switch source {
        case .remote(let s, let f): return workspace.image(s, f)
        case .local: return localImage
        case .none: return nil
        }
    }

    private var loading: Bool {
        if case .remote(let s, let f) = source { return !workspace.imageFailed(s, f) }
        if case .local = source { return localImage == nil && !localFailed }
        return false
    }

    @ViewBuilder private var placeholder: some View {
        if let bundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit).padding(6)
        } else {
            Image(systemName: "macwindow").foregroundStyle(.tertiary)
        }
    }

    private func load() async {
        switch source {
        case .remote(let s, let f): await workspace.loadImage(s, f)
        case .local(let url):
            localImage = await Task.detached { () -> NSImage? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return WorkspaceModel.thumbnail(data, maxPixels: 1200)
            }.value
            localFailed = localImage == nil
        case .none: break
        }
    }
}

/// Analysis status of a recording, as text with a symbol in a matching tint.
struct StatusLabel: View {
    let status: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            if active { ProgressView().controlSize(.mini) } else { Image(systemName: symbol) }
        }
        .foregroundStyle(tint)
        .labelStyle(.titleAndIcon)
    }

    private var active: Bool { status == "queued" || status == "analyzing" || status == "running" }

    var title: String {
        switch status {
        case "analyzed", "succeeded": return "Analyzed"
        case "analyzing", "running": return "Analyzing…"
        case "queued": return "Queued"
        case "failed": return "Analysis failed"
        case "uploaded": return "Not analyzed"
        case "reviewed": return "Reviewed, not uploaded"
        case "local": return "Not uploaded"
        default: return status.capitalized
        }
    }

    private var symbol: String {
        switch status {
        case "analyzed", "succeeded": return "checkmark.circle.fill"
        case "failed": return "exclamationmark.triangle.fill"
        case "uploaded": return "icloud"
        case "reviewed": return "checkmark.seal"
        case "local": return "internaldrive"
        default: return "circle"
        }
    }

    private var tint: Color {
        switch status {
        case "analyzed", "succeeded": return .green
        case "failed": return .red
        case "queued", "analyzing", "running": return .accentColor
        default: return .secondary
        }
    }
}

struct NoticeText: View {
    let notice: WorkspaceModel.Notice

    var body: some View {
        Label(notice.text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var symbol: String {
        switch notice.tone {
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch notice.tone {
        case .info: return .secondary
        case .success: return .green
        case .error: return .red
        }
    }
}

/// Back button and title for a view pushed inside the panel.
struct PanelNavBar<Trailing: View>: View {
    let back: String
    let title: String
    let onBack: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                Label(back, systemImage: "chevron.left").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back to \(back)")
            Spacer(minLength: 8)
            trailing
        }
        .overlay {
            Text(title).font(.headline).lineLimit(1).frame(maxWidth: 220)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// Grey rounded placeholder bars for loading states.
struct SkeletonBar: View {
    var width: CGFloat?
    var height: CGFloat = 10
    var body: some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(.quaternary)
            .frame(width: width, height: height)
    }
}

enum PanelFormat {
    static func date(_ iso: String) -> String {
        guard let d = SessionClock.parseISO8601(iso) else { return iso }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    static func relative(_ iso: String) -> String {
        guard let d = SessionClock.parseISO8601(iso) else { return iso }
        return d.formatted(.relative(presentation: .named))
    }

    static func duration(_ ms: Int) -> String {
        let s = Int((Double(ms) / 1000).rounded())
        return s < 60 ? "\(s)s" : "\(s / 60)m \(String(format: "%02d", s % 60))s"
    }

    static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n.formatted()) \(n == 1 ? one : (many ?? one + "s"))"
    }
}

/// Engine status with Retry and a diagnostics disclosure (redacted engine output).
struct EngineStatusRow: View {
    @EnvironmentObject var model: AppModel
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                switch model.serverState {
                case .ready:
                    Label("Running", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .starting, .stopped:
                    ProgressView().controlSize(.mini)
                    Text("Starting analysis engine…").foregroundStyle(.secondary)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Analysis engine stopped")
                }
                Spacer()
                if case .failed = model.serverState {
                    Button("Retry") { model.retryServer() }.controlSize(.small)
                }
            }
            .font(.caption)
            if case .failed(let reason) = model.serverState {
                DisclosureGroup(isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(reason).fixedSize(horizontal: false, vertical: true)
                        if !model.serverDiagnostics.isEmpty {
                            ScrollView {
                                Text(model.serverDiagnostics.joined(separator: "\n"))
                                    .font(.caption2.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 120)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } label: {
                    Text("Details").font(.caption)
                }
                .onAppear { model.refreshDiagnostics() }
            }
        }
    }
}
