import AppKit
import RetraceCore
import SwiftUI

/// Emerald accent shared by the clone workflow. `accent` adapts for text and symbols;
/// `fill` stays dark enough for white button labels in both appearances.
enum CloneTheme {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.204, green: 0.827, blue: 0.600, alpha: 1)
            : NSColor(srgbRed: 0.016, green: 0.471, blue: 0.341, alpha: 1)
    })
    static let fill = Color(.sRGB, red: 0.016, green: 0.471, blue: 0.341, opacity: 1)
    static let wash = accent.opacity(0.12)
    static let cardRadius: CGFloat = 12
}

enum CloneCopy {
    static func title(_ stage: CloneStage) -> String {
        switch stage {
        case .select: "Select"
        case .scan: "Scan"
        case .requirements: "Requirements"
        case .build: "Build"
        }
    }

    static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
}

/// A titled surface. Titles are headers for VoiceOver so each card is a navigable section.
struct CloneCard<Content: View>: View {
    var title: String?
    var symbol: String?
    var tint: Color = CloneTheme.accent
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 6) {
                    if let symbol {
                        Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
                    }
                    Text(title).font(.subheadline.weight(.semibold))
                }
                .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: CloneTheme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CloneTheme.cardRadius, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

/// The four-stage progress bar: numbered nodes joined by a line that fills as stages complete.
struct CloneStageBar: View {
    let current: CloneStage
    let isDone: (CloneStage) -> Bool
    let isReachable: (CloneStage) -> Bool
    let select: (CloneStage) -> Void

    private var stages: [CloneStage] { CloneStage.allCases }
    private var currentIndex: Int { stages.firstIndex(of: current) ?? 0 }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(stages.enumerated()), id: \.element) { index, stage in
                Button { select(stage) } label: { node(index, stage) }
                    .buttonStyle(.plain)
                    .disabled(stage == current || !isReachable(stage))
                    .accessibilityLabel("Step \(index + 1) of \(stages.count), \(CloneCopy.title(stage))")
                    .accessibilityValue(stage == current ? "Current step" : isDone(stage) ? "Done" : "Not started")
            }
        }
    }

    private func node(_ index: Int, _ stage: CloneStage) -> some View {
        let active = stage == current
        let done = isDone(stage) && !active
        return VStack(spacing: 5) {
            ZStack {
                HStack(spacing: 0) {
                    line(filled: index <= currentIndex).opacity(index == 0 ? 0 : 1)
                    line(filled: index < currentIndex).opacity(index == stages.count - 1 ? 0 : 1)
                }
                Circle()
                    .fill(done ? AnyShapeStyle(CloneTheme.fill) : AnyShapeStyle(.background))
                    .overlay(Circle().fill(active ? CloneTheme.wash : .clear))
                    .overlay(Circle().strokeBorder(done || active ? AnyShapeStyle(CloneTheme.accent) : AnyShapeStyle(.tertiary),
                                                   lineWidth: active ? 2 : 1))
                    .frame(width: 24, height: 24)
                if done {
                    Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text("\(index + 1)").font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(active ? AnyShapeStyle(CloneTheme.accent) : AnyShapeStyle(.secondary))
                }
            }
            Text(CloneCopy.title(stage))
                .font(.caption.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? .primary : .secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private func line(filled: Bool) -> some View {
        Rectangle()
            .fill(filled ? AnyShapeStyle(CloneTheme.accent) : AnyShapeStyle(.quaternary))
            .frame(height: 2)
    }
}

/// A Terminal command with a copy button.
struct CloneCommandRow: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            }
            .controlSize(.small)
            .accessibilityLabel("Copy command \(command)")
        }
        .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 4)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

/// One tool's live check: name, what was found, and the commands that fix it when it's missing.
struct CloneReadinessRow: View {
    let name: String
    let purpose: String
    let check: SetupCheck
    var hint: String?
    var commands: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                icon.frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.callout.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(statusWord)
            if check.status == .missing {
                VStack(alignment: .leading, spacing: 5) {
                    if let hint {
                        Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(commands, id: \.self) { CloneCommandRow(command: $0) }
                }
                .padding(.leading, 24)
            }
        }
    }

    private var detail: String {
        switch check.status {
        case .checking: "Checking…"
        case .ok: check.detail ?? purpose
        case .missing: check.detail ?? "Not found. \(purpose)"
        }
    }

    private var statusWord: String {
        switch check.status {
        case .checking: "Checking"
        case .ok: "Ready"
        case .missing: "Needs setup"
        }
    }

    @ViewBuilder private var icon: some View {
        switch check.status {
        case .checking: ProgressView().controlSize(.mini)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(CloneTheme.accent)
        case .missing: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

/// A live number with a caption, read as one element ("12 screens").
struct CloneMetric: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(spacing: 1) {
            Text("\(value)").font(.title3.weight(.semibold).monospacedDigit()).contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }
}

/// An inline message: what happened, with optional actions beside it.
struct CloneBanner<Actions: View>: View {
    enum Kind { case error, warning, info }
    let kind: Kind
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(text).font(.caption).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            HStack(spacing: 8) { actions }.controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.35)))
    }

    private var symbol: String {
        switch kind {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .error: .red
        case .warning: .orange
        case .info: CloneTheme.accent
        }
    }
}

/// A bulleted line that wraps under its own text, not under the bullet.
struct CloneBullet: View {
    let text: String
    var symbol = "circle.fill"
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).font(.system(size: symbol == "circle.fill" ? 4 : 10)).foregroundStyle(tint)
                .frame(width: 12).accessibilityHidden(true)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

/// Wraps short chips onto as many rows as the width needs.
struct CloneChipLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if var last = rows.last, last.width + spacing + size.width <= width {
                last.indices.append(index)
                last.width += spacing + size.width
                last.height = max(last.height, size.height)
                rows[rows.count - 1] = last
            } else {
                let y = rows.last.map { $0.y + $0.height + spacing } ?? 0
                rows.append(([index], y, size.width, size.height))
            }
        }
        return rows
    }
}
