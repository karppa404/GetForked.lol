import RetraceCore
import SwiftUI

/// Latest analysis of an app: status, stages, token usage and the Nemotron agent's plan and tool calls.
struct AnalysisSummaryView: View {
    let job: RemoteJob

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusLabel(status: job.status).font(.callout)
                Spacer()
                if let u = job.usage, u.calls > 0 {
                    Text("\(PanelFormat.plural(u.calls, "call")) · \((u.promptTokens + u.completionTokens).formatted()) tokens\(u.estimated ? " (est.)" : "")")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .help("\(u.promptTokens.formatted()) prompt + \(u.completionTokens.formatted()) completion tokens")
                }
            }
            if let error = job.error, job.status == "failed" {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if job.hasAgentTrace {
                AgentTraceView(job: job)
            } else if !job.stages.isEmpty {
                StagesView(stages: job.stages)
            }
        }
    }
}

/// The classic staged pipeline (or pending stages before a trace exists).
struct StagesView: View {
    let stages: [JobStage]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(stages, id: \.name) { s in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    StageMarker(status: s.status)
                    Text(s.label ?? s.name.capitalized).font(.caption)
                    if let d = s.detail { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(d) }
                }
            }
        }
    }
}

private struct StageMarker: View {
    let status: String
    var body: some View {
        switch status {
        case "done": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case "running": ProgressView().controlSize(.mini)
        case "failed": Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
        case "skipped": Image(systemName: "minus.circle").foregroundStyle(.tertiary).font(.caption)
        default: Image(systemName: "circle").foregroundStyle(.tertiary).font(.caption)
        }
    }
}

/// Plan + tool-call timeline. Expands by itself when a run starts; never collapses what the user opened.
struct AgentTraceView: View {
    let job: RemoteJob
    @State private var expanded: Bool

    init(job: RemoteJob) {
        self.job = job
        _expanded = State(initialValue: job.isActive)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if job.isFallback {
                    Label {
                        Text("The agent didn’t finish, so the classic staged pipeline produced this graph." + (job.agentStage?.detail ?? job.error).map { " \($0)" }.orEmpty)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: { Image(systemName: "arrow.triangle.branch") }
                    .font(.caption)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                if !job.plan.isEmpty { plan }
                steps
                if !job.isActive && job.validationFixes > 0 {
                    Text("The agent self-corrected after \(PanelFormat.plural(job.validationFixes, "failed validation")).")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Text(job.mode == "staged" ? "Staged pipeline" : "Nemotron agent").font(.callout.weight(.semibold))
                if job.isFallback {
                    Text("Fallback: staged pipeline")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer()
                if job.isActive { ProgressView().controlSize(.mini) }
                Text(PanelFormat.plural(job.agentTrace.count, "step")).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
        }
        .onChange(of: job.isActive) { wasActive, active in
            if active && !wasActive { expanded = true }
        }
    }

    private var plan: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Plan").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(job.plan.enumerated()), id: \.offset) { i, p in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(i + 1).").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 16, alignment: .trailing)
                    Text(p).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var steps: some View {
        if job.agentTrace.isEmpty && !job.isActive {
            Text("No agent steps were recorded for this run.").font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(job.agentTrace) { step in
                    StepRow(step: step, isLast: step == job.agentTrace.last && !job.isActive)
                }
                if job.isActive {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        ProgressView().controlSize(.mini).frame(width: 16)
                        Text(job.agentTrace.isEmpty ? "Starting the agent…" : "Choosing the next tool…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct StepRow: View {
    let step: AgentStep
    let isLast: Bool

    private enum Tone { case ok, invalid, error }
    private var tone: Tone { !step.ok ? .error : step.isValidationFailure ? .invalid : .ok }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 2) {
                marker.font(.caption).frame(width: 16, height: 16)
                if !isLast { Rectangle().fill(.separator).frame(width: 1).frame(maxHeight: .infinity) }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("#\(step.step)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Text(step.tool).font(.caption.monospaced().weight(.medium))
                    if tone != .ok {
                        Text(tone == .error ? "Tool error" : "Validation failed")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(tone == .error ? Color.red : Color.orange)
                    }
                }
                if let r = step.reason { Text(r).font(.caption).fixedSize(horizontal: false, vertical: true) }
                if let a = step.args {
                    Text(a).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.tail).help(a)
                }
                if let res = step.resultSummary {
                    Text(res).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 8)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(step.step): \(step.tool), \(tone == .ok ? "OK" : tone == .error ? "tool error" : "validation failed")")
    }

    @ViewBuilder private var marker: some View {
        switch tone {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .invalid: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
