import RetraceCore
import SwiftUI

/// Every recorded app (or, in website mode, every scanned site), newest first, as a collapsible
/// list of compact rows with the last captured screen.
struct AppsListView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var workspace: WorkspaceModel
    /// Follows the recorder's Mac app / SaaS website toggle.
    let web: Bool
    let onSelect: (String) -> Void
    @AppStorage("appsExpanded") private var expanded = false

    /// Rows shown before the list scrolls.
    static let visibleRows = 5
    static let rowHeight: CGFloat = 58

    var body: some View {
        let groups = workspace.groups.filter { $0.isWeb == web }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Apps").font(.headline)
                        if !groups.isEmpty {
                            Text(groups.count.formatted()).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Apps, \(groups.count)")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint(expanded ? "Collapse the list" : "Expand the list")
                if workspace.listState == .loading && !groups.isEmpty { ProgressView().controlSize(.mini) }
                if workspace.isConnected {
                    Button { workspace.refresh(); model.refreshSessions() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh")
                        .disabled(workspace.listState == .loading)
                }
            }
            // Errors stay visible while collapsed.
            connectionNotice
            if expanded {
                Group {
                    if groups.isEmpty {
                        if workspace.listState == .loading { skeleton } else { empty }
                    } else if groups.count <= Self.visibleRows {
                        rows(groups)
                    } else {
                        ScrollView { rows(groups) }
                            .frame(height: Self.rowHeight * (CGFloat(Self.visibleRows) + 0.5))
                            .scrollIndicators(.automatic)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func rows(_ groups: [AppGroup]) -> some View {
        VStack(spacing: 0) {
            ForEach(groups) { g in AppRow(group: g) { onSelect(g.key) } }
        }
    }

    @ViewBuilder private var connectionNotice: some View {
        switch workspace.listState {
        case .failed(let message, let reconnect):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if reconnect {
                    Button("Connect Again") { model.reconnect() }.controlSize(.small)
                } else {
                    Button("Retry") { workspace.refresh() }.controlSize(.small)
                }
            }
        default:
            // The engine status itself is shown in the panel header; only a failed connection shows here.
            if model.isServerReady, case .failed(let m) = model.connection {
                HStack(spacing: 6) {
                    Label(m, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Retry") { model.connect() }.controlSize(.small)
                }
            }
        }
    }


    private var empty: some View {
        VStack(spacing: 4) {
            Image(systemName: web ? "globe" : "rectangle.stack.badge.plus").font(.title2).foregroundStyle(.secondary)
            Text(web ? "No website scans yet" : "No app scans yet").font(.callout.weight(.medium))
            Text(web ? "Enter a site URL above, choose a browser and press Scan Site. It shows up here once the scan ends."
                     : "Choose an app above and press Scan App. It shows up here once the scan ends.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var skeleton: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: AppRow.innerRadius, style: .continuous).fill(.quaternary)
                        .frame(width: AppRow.thumbSize.width, height: AppRow.thumbSize.height)
                    VStack(alignment: .leading, spacing: 6) { SkeletonBar(width: 120); SkeletonBar(width: 170, height: 8) }
                    Spacer()
                }
                .padding(AppRow.padding)
            }
        }
        .accessibilityLabel("Loading apps")
    }
}

private struct AppRow: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var workspace: WorkspaceModel
    let group: AppGroup
    let action: () -> Void
    @State private var hovering = false

    static let outerRadius: CGFloat = 12
    static let padding: CGFloat = 6
    /// Concentric with the row's hover background.
    static let innerRadius: CGFloat = outerRadius - padding
    static let thumbSize = CGSize(width: 72, height: 45)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ScreenImage(source: workspace.screen(for: group, local: model.sessions), cornerRadius: Self.innerRadius, bundleId: group.bundleId)
                    .frame(width: Self.thumbSize.width, height: Self.thumbSize.height)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name).font(.callout.weight(.medium)).lineLimit(1)
                    HStack(spacing: 4) {
                        StatusLabel(status: status)
                        Text("·").foregroundStyle(.secondary)
                        Text(PanelFormat.plural(group.recordings.count, "recording")).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(Self.padding)
            .background(hovering ? Color.primary.opacity(0.07) : .clear,
                        in: RoundedRectangle(cornerRadius: Self.outerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Self.outerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .deleteAllRecordingsMenu(group)
        .accessibilityLabel("\(group.name), \(StatusLabel(status: status).title), \(PanelFormat.plural(group.recordings.count, "recording"))")
    }

    /// The latest analysis job's status when known (it updates while polling), else the newest
    /// upload's, else the newest local recording's.
    private var status: String {
        if let job = workspace.latestJobDetail(group)?.job { return job.status }
        return group.recordings.first { $0.remoteId != nil }?.status ?? group.newest.status
    }
}
