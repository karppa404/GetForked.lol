import RetraceCore
import SwiftUI

/// Endpoints an app called while it was recorded, grouped by host, built from the uploaded recordings'
/// network evidence and linked to the UI actions the analysis graph connects them to.
struct APIDocsView: View {
    @EnvironmentObject var workspace: WorkspaceModel
    let group: AppGroup
    let onBack: () -> Void
    @State private var filter = ""

    private var observed: [RemoteSessionDetail] {
        workspace.loadedDetails(group).filter { $0.networkStatus == "observed" }
    }
    private var docs: APIDocs { APIDocs.build(observed.map(APIDocsInput.init)) }

    var body: some View {
        VStack(spacing: 0) {
            PanelNavBar(back: group.name, title: "API", onBack: onBack) { EmptyView() }
            Divider()
            ScrollView {
                content.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { workspace.loadGroup(group) }
    }

    @ViewBuilder private var content: some View {
        let docs = self.docs
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(group.name) API").font(.title3.weight(.semibold))
                if docs.requestCount > 0 {
                    Text("\(PanelFormat.plural(docs.endpointCount, "endpoint")) · \(PanelFormat.plural(docs.requestCount, "request")) across \(PanelFormat.plural(docs.sessionCount, "recording"))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if !workspace.allDetailsLoaded(group) && docs.requestCount == 0 {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach([0.62, 0.48, 0.7, 0.54], id: \.self) { w in
                        HStack(spacing: 8) { SkeletonBar(width: 44); SkeletonBar(width: 300 * w) }
                    }
                }
                .accessibilityLabel("Loading API traffic")
            } else if docs.requestCount == 0 {
                ContentUnavailableView {
                    Label("No network traffic recorded", systemImage: "network.slash")
                } description: {
                    Text("Recordings of \(group.name) don't include network requests. Record it again with network capture on to document the requests it makes.")
                }
            } else {
                TextField("Filter by path, method, status or action", text: $filter)
                    .textFieldStyle(.roundedBorder)
                let hosts = docs.filtered(filter)
                if hosts.isEmpty {
                    Text("No endpoints match “\(filter)”.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(hosts) { host in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(host.host).font(.callout.monospaced().weight(.semibold)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("\(PanelFormat.plural(host.endpoints.count, "endpoint")) · \(PanelFormat.plural(host.calls, "request"))")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        ForEach(host.endpoints) { EndpointRow(endpoint: $0) }
                    }
                }
            }
        }
    }
}

private struct EndpointRow: View {
    let endpoint: APIEndpoint
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if !endpoint.triggeredBy.isEmpty {
                    (Text("Triggered by ").foregroundStyle(.secondary) + Text(endpoint.triggeredBy.joined(separator: ", ")))
                        .font(.caption)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                    GridRow { fact("First seen"); fact("Last seen"); fact("Recordings") }
                    GridRow {
                        Text(endpoint.firstSeen.at?.formatted(date: .abbreviated, time: .standard) ?? "—")
                        Text(endpoint.lastSeen.at?.formatted(date: .abbreviated, time: .standard) ?? "—")
                        Text(endpoint.sessions.formatted())
                    }
                    .font(.caption).monospacedDigit()
                }
                Text(endpoint.examples.count == 1 ? "Example request" : "Example requests").font(.caption.weight(.semibold))
                ForEach(endpoint.examples, id: \.url) { x in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(x.url.split(separator: "?", maxSplits: 1).first.map(String.init) ?? x.url)
                            .font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if !x.query.isEmpty {
                            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 1) {
                                ForEach(Array(x.query.enumerated()), id: \.offset) { _, q in
                                    GridRow {
                                        Text(q.name).foregroundStyle(.secondary)
                                        Text(q.value).foregroundStyle(q.value == APIDocs.redacted ? .orange : .primary)
                                    }
                                }
                            }
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 6) {
                MethodBadge(method: endpoint.method)
                path.font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).help(endpoint.path)
                Spacer(minLength: 4)
                ForEach(endpoint.statuses, id: \.self) { StatusCode(code: $0) }
                Text(PanelFormat.plural(endpoint.calls, "call")).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
        }
    }

    private func fact(_ s: String) -> some View { Text(s).font(.caption2).foregroundStyle(.secondary) }

    /// `{id}` placeholders in the accent color.
    private var path: Text {
        endpoint.path.components(separatedBy: "{id}").enumerated().reduce(Text("")) { acc, part in
            let piece = Text(part.element)
            return part.offset == 0 ? acc + piece : acc + Text("{id}").foregroundColor(.accentColor) + piece
        }
    }
}

private struct MethodBadge: View {
    let method: String
    var body: some View {
        Text(method)
            .font(.caption2.monospaced().weight(.bold))
            .frame(minWidth: 40)
            .padding(.vertical, 1)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .foregroundStyle(tint)
    }
    private var tint: Color {
        switch method {
        case "GET": return .blue
        case "POST": return .green
        case "PUT", "PATCH": return .orange
        case "DELETE": return .red
        default: return .secondary
        }
    }
}

private struct StatusCode: View {
    let code: Int
    var body: some View {
        Text(String(code))
            .font(.caption2.monospaced())
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
    private var tint: Color {
        code >= 500 ? .red : code >= 400 ? .orange : code >= 300 ? .secondary : .green
    }
}
