import RetraceCore
import SwiftUI

/// Screens, actions and API calls of the latest graph, in step order. Click a label to correct it
/// (Return saves, Esc cancels); corrected labels carry a pencil and can be reverted to the agent's.
struct GraphLabelEditor: View {
    @EnvironmentObject var workspace: WorkspaceModel
    let detail: RemoteSessionDetail
    /// An analysis is queued or running: the graph is about to change.
    let locked: Bool

    @State private var editing: String?
    @State private var draft = ""
    @State private var errors: [String: String] = [:]
    @State private var expanded: Set<String> = []
    @FocusState private var focused: Bool

    static let collapsedCount = 8

    private var sections: [GraphLabels.Section] { GraphLabels.sections(detail) }

    var body: some View {
        let sections = self.sections
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Labels").font(.headline)
                Spacer()
                let n = sections.reduce(0) { $0 + $1.items.filter(\.corrected).count }
                if n > 0 { Text("\(n) corrected").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            if locked {
                Text("Labels can be corrected once the analysis finishes.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Click a label to correct it. Corrections are used by API docs and the UI flow export.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(section.title) · \(section.items.count)")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.top, 2)
                    let all = expanded.contains(section.id)
                    ForEach(Array((all ? section.items : Array(section.items.prefix(Self.collapsedCount))).enumerated()), id: \.element.id) { i, item in
                        row(item, step: i + 1)
                    }
                    if section.items.count > Self.collapsedCount {
                        Button(all ? "Show fewer" : "Show all \(section.items.count)") {
                            if all { expanded.remove(section.id) } else { expanded.insert(section.id) }
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
        .onChange(of: locked) { _, now in if now { cancel() } }
        .onChange(of: detail.id) { _, _ in cancel(); errors = [:] }
    }

    @ViewBuilder private func row(_ item: GraphLabels.Item, step: Int) -> some View {
        let saving = workspace.busy.contains(WorkspaceModel.correctionToken(detail.id, item.id))
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("\(step)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary).frame(minWidth: 16, alignment: .trailing)
                if editing == item.id {
                    TextField(item.agentLabel, text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .focused($focused)
                        .onAppear { focused = true }
                        .onSubmit { save(item) }
                        .onExitCommand { cancel() }
                        .onChange(of: focused) { _, f in if !f && editing == item.id { cancel() } }
                } else {
                    Button { begin(item) } label: {
                        Text(item.label.isEmpty ? "Untitled" : item.label)
                            .font(.callout)
                            .foregroundStyle(item.label.isEmpty ? .secondary : .primary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(locked || saving)
                    .help(item.corrected ? "Corrected. The agent named it “\(item.agentLabel)”." : "Click to correct this label")
                    if item.corrected {
                        Image(systemName: "pencil")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel("Corrected")
                    }
                }
                if saving {
                    ProgressView().controlSize(.mini)
                } else if item.corrected && editing != item.id {
                    Button { revert(item) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless).font(.caption)
                        .disabled(locked)
                        .help("Revert to the agent’s label “\(item.agentLabel)”")
                        .accessibilityLabel("Revert to agent label")
                }
            }
            if let e = errors[item.id] {
                Text(e).font(.caption).foregroundStyle(.red).padding(.leading, 22)
            }
        }
        .padding(.vertical, 1)
    }

    private func begin(_ item: GraphLabels.Item) {
        guard !locked else { return }
        editing = item.id
        draft = item.label
        errors[item.id] = nil
        focused = true
    }

    private func cancel() {
        editing = nil
        focused = false
    }

    private func save(_ item: GraphLabels.Item) {
        guard let clean = GraphLabels.clean(draft) else {
            errors[item.id] = "Enter a label of 1–\(GraphLabels.maxLabel) characters."
            return
        }
        cancel()
        // Typing the agent's own label back is a revert, not a correction.
        let label: String? = clean == item.agentLabel ? nil : clean
        guard label != (item.corrected ? item.label : nil) else { return }
        submit(item, label)
    }

    private func revert(_ item: GraphLabels.Item) { submit(item, nil) }

    private func submit(_ item: GraphLabels.Item, _ label: String?) {
        errors[item.id] = nil
        let sessionId = detail.id
        Task {
            let error = await workspace.saveCorrection(sessionId: sessionId, elementId: item.id, label: label)
            errors[item.id] = error
        }
    }
}
