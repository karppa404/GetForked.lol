import AppKit
import RetraceCore
import SwiftUI

struct ReviewWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedSessionId) {
                ForEach(model.sessions) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(s.manifest.app.name) activity").lineLimit(1)
                        Text(Self.date(s.manifest.startedAt))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            if s.upload.remoteSessionId != nil { tag("Uploaded", .blue) }
                            else if s.review.isConfirmed { tag("Reviewed", .green) }
                            else { tag("Local only", .secondary) }
                        }
                    }
                    .tag(s.id)
                }
            }
            .overlay {
                if model.sessions.isEmpty {
                    Text("No local sessions yet.\nStart observing an app from the menu bar.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar { Button { model.refreshSessions() } label: { Image(systemName: "arrow.clockwise") } }
        } detail: {
            if let id = model.selectedSessionId, let s = model.session(id) {
                SessionReviewView(session: s).id(s.id)
            } else {
                Text("Select a session to review").foregroundStyle(.secondary)
            }
        }
        .onAppear {
            model.refreshSessions()
            model.loadCredentialIfNeeded()
        }
    }

    private func tag(_ s: String, _ c: Color) -> some View {
        Text(s).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
            .background(c.opacity(0.15), in: Capsule()).foregroundStyle(c)
    }

    static func date(_ iso: String) -> String {
        guard let d = SessionClock.parseISO8601(iso) else { return iso }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}

struct SessionReviewView: View {
    @EnvironmentObject var model: AppModel
    let session: LocalSession
    @State private var preview: Frame?
    @State private var confirmDelete = false

    private var review: ReviewState { session.review }
    private var manifest: SessionManifest { session.manifest }
    private var keptFrames: Int { manifest.frames.filter { !review.omittedFrameIds.contains($0.id) }.count }
    private var keptEvents: Int { manifest.interactions.filter { !review.omittedInteractionIds.contains($0.id) }.count }
    private var locked: Bool { session.upload.remoteSessionId != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                privacyNotice
                framesSection
                eventsSection
                uploadSection
            }
            .padding(20)
        }
        .sheet(item: $preview) { f in
            FramePreview(url: session.url(for: f), frame: f, events: manifest.interactions.filter {
                $0.beforeFrameId == f.id || $0.afterFrameId == f.id || $0.delayedFrameId == f.id
            })
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(manifest.app.name) activity").font(.title2.bold())
            Text("\(manifest.app.name) (\(manifest.app.bundleId)) · started \(ReviewWindow.date(manifest.startedAt)) · \(MenuContent.format(Double(manifest.durationMs) / 1000))")
                .foregroundStyle(.secondary)
            Text("\(manifest.frames.count) frames · \(manifest.interactions.count) events · session \(manifest.id)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Label("Network: not captured. No network helper was running, so the absence of network events says nothing about the app's traffic.",
                  systemImage: "network.slash")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private var privacyNotice: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label("You are the redaction step", systemImage: "eye.trianglebadge.exclamationmark").font(.headline)
                Text("Retrace does not detect, blur or remove sensitive content on its own. Frames show everything that was visible in \(manifest.app.name)'s windows, including names, emails, account numbers or document contents. Typed characters were never recorded, but text you typed may be visible in later frames. Omit every frame or event you are not allowed to share. Only what you keep is uploaded.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Toggle("Remove window titles from all events", isOn: binding(\.removeWindowTitles))
                Toggle("Remove element titles and labels from all events (keep roles only)", isOn: binding(\.removeAccessibilityText))
            }
            .padding(4)
        }
        .disabled(locked)
    }

    private func binding(_ kp: WritableKeyPath<ReviewState, Bool>) -> Binding<Bool> {
        Binding(get: { review[keyPath: kp] }, set: { v in model.updateReview(session.id) { $0[keyPath: kp] = v } })
    }

    private var framesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Frames (\(keptFrames) of \(manifest.frames.count) kept)").font(.headline)
                Spacer()
                Button("Keep all") { model.updateReview(session.id) { $0.omittedFrameIds = [] } }.disabled(locked)
                Button("Omit all") { model.updateReview(session.id) { $0.omittedFrameIds = Set(manifest.frames.map(\.id)) } }.disabled(locked)
            }
            if manifest.frames.isEmpty {
                Text("No frames were captured.").foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                ForEach(manifest.frames) { f in
                    let omitted = review.omittedFrameIds.contains(f.id)
                    VStack(spacing: 4) {
                        Thumbnail(url: session.url(for: f))
                            .frame(height: 112)
                            .overlay {
                                if omitted {
                                    ZStack {
                                        Color.black.opacity(0.65)
                                        Label("Omitted", systemImage: "eye.slash").foregroundStyle(.white)
                                    }
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .onTapGesture { preview = f }
                        HStack {
                            Text("+\(Double(f.timestampMs) / 1000, specifier: "%.1f")s").font(.caption).monospacedDigit()
                            Spacer()
                            Toggle("Omit", isOn: Binding(
                                get: { omitted },
                                set: { v in model.updateReview(session.id) { if v { $0.omittedFrameIds.insert(f.id) } else { $0.omittedFrameIds.remove(f.id) } } }
                            ))
                            .toggleStyle(.checkbox).font(.caption).disabled(locked)
                        }
                    }
                }
            }
        }
    }

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Events (\(keptEvents) of \(manifest.interactions.count) kept)").font(.headline)
            ForEach(manifest.interactions) { it in
                let omitted = review.omittedInteractionIds.contains(it.id)
                HStack(alignment: .top) {
                    Toggle("", isOn: Binding(
                        get: { !omitted },
                        set: { keep in model.updateReview(session.id) { if keep { $0.omittedInteractionIds.remove(it.id) } else { $0.omittedInteractionIds.insert(it.id) } } }
                    ))
                    .toggleStyle(.checkbox).labelsHidden().disabled(locked)
                    .help(omitted ? "Omitted" : "Kept")
                    Text("+\(Double(it.timestampMs) / 1000, specifier: "%.2f")s").monospacedDigit().frame(width: 70, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.describe(it)).strikethrough(omitted)
                        if let ax = it.accessibility {
                            Text(Self.describe(ax, review: review)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    frameLinks(it)
                }
                .opacity(omitted ? 0.5 : 1)
                Divider()
            }
        }
    }

    private func frameLinks(_ it: Interaction) -> some View {
        HStack(spacing: 4) {
            ForEach([("before", it.beforeFrameId), ("after", it.afterFrameId), ("settled", it.delayedFrameId)], id: \.0) { name, id in
                if let id, let f = manifest.frames.first(where: { $0.id == id }) {
                    Button(name) { preview = f }.buttonStyle(.link).font(.caption)
                        .strikethrough(review.omittedFrameIds.contains(id))
                }
            }
        }
    }

    private var uploadSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if locked {
                    Label("Uploaded as \(session.upload.remoteSessionId ?? "") to \(session.upload.apiBaseURL ?? "")", systemImage: "checkmark.icloud")
                    if let job = session.upload.jobId {
                        Text("Analysis job \(job) (\(session.upload.jobStatus ?? "unknown"))").font(.caption)
                    }
                } else {
                    Toggle(isOn: Binding(get: { review.isConfirmed }, set: { model.setConfirmed(session.id, $0) })) {
                        Text("I reviewed all \(keptFrames) kept frames and \(keptEvents) kept events, and I am allowed to share them.")
                    }
                    .toggleStyle(.checkbox)
                    Text("Changing any omission clears this confirmation.").font(.caption).foregroundStyle(.secondary)
                }
                pairingStatus
                if let msg = model.sessionMessages[session.id] {
                    Text(msg).font(.callout).textSelection(.enabled)
                }
                HStack {
                    Button {
                        model.uploadAndAnalyze(session.id)
                    } label: {
                        Label(locked ? (session.upload.jobId == nil ? "Request Analysis" : "Request Analysis Again") : "Upload & Analyze",
                              systemImage: "icloud.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canUpload)
                    if model.busySessionIds.contains(session.id) { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Show in Finder") { model.reveal(session.id) }
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                }
            }
            .padding(4)
        }
        .confirmationDialog("Delete this local session and all its frames?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.delete(session.id) }
        }
    }

    @ViewBuilder private var pairingStatus: some View {
        if let cred = model.credential {
            Text("Destination: project \(cred.projectId) at \(cred.apiBaseURL)").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Not paired with \(model.apiBaseURLString). Use Pair… in the menu first.").font(.caption).foregroundStyle(.orange)
        }
    }

    private var canUpload: Bool {
        guard model.credential != nil, !model.busySessionIds.contains(session.id) else { return false }
        return locked || review.isConfirmed
    }

    static func describe(_ it: Interaction) -> String {
        switch it.kind {
        case .click, .doubleClick, .rightClick, .otherClick:
            let pos = it.x.map { x in " at (\(Int(x)), \(Int(it.y ?? 0)))" } ?? ""
            return it.kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized + pos
        case .scroll: return "Scroll (dx \(Int(it.scrollDx ?? 0)), dy \(Int(it.scrollDy ?? 0)))"
        case .key: return "Key \(it.key ?? "?")"
        case .textInput: return "Typing (characters not recorded)"
        case .focusLost: return "App lost focus. Capture paused."
        case .focusRegained: return "App frontmost again. Capture resumed."
        }
    }

    static func describe(_ ax: AccessibilitySnapshot, review: ReviewState) -> String {
        var parts: [String] = []
        if let r = ax.role { parts.append(r) }
        if ax.secure == true { parts.append("secure field") }
        if !review.removeAccessibilityText {
            if let t = ax.title { parts.append("“\(t)”") }
            if let l = ax.label { parts.append("label “\(l)”") }
        }
        if let i = ax.identifier { parts.append("#\(i)") }
        if !review.removeWindowTitles, let w = ax.windowTitle { parts.append("in window “\(w)”") }
        return parts.joined(separator: " · ")
    }
}

struct Thumbnail: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
            else { ProgressView().controlSize(.small) }
        }
        .task(id: url) {
            image = await Task.detached { () -> NSImage? in
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                            kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary)
                else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }.value
        }
    }
}

struct FramePreview: View {
    let url: URL
    let frame: Frame
    let events: [Interaction]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Frame +\(Double(frame.timestampMs) / 1000, specifier: "%.2f")s · \(frame.width)×\(frame.height)").font(.headline)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .frame(minWidth: 640, maxWidth: 1200, minHeight: 360, maxHeight: 760)
            }
            ForEach(events) { e in
                Text("Linked: \(SessionReviewView.describe(e)) at +\(Double(e.timestampMs) / 1000, specifier: "%.2f")s").font(.caption)
            }
        }
        .padding()
    }
}
