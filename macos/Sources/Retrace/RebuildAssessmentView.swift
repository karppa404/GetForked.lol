import RetraceCore
import SwiftUI

struct RebuildAssessmentView: View {
    let profile: RebuildProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rebuild assessment").font(.headline)
            section("Target platform", text: profile.targetPlatform.value)
            Text(profile.targetPlatform.limitations).font(.caption2).foregroundStyle(.secondary)
            section("Legacy stack", text: profile.legacyStack.components.isEmpty
                    ? "Unknown — source or build evidence needed"
                    : profile.legacyStack.components.map { "\($0.name) (\($0.layer))" }.joined(separator: ", "))
            DisclosureGroup("What the stack evidence establishes") {
                Text(profile.legacyStack.limitations)
                ForEach(profile.legacyStack.components, id: \.self) { component in
                    Text("\(component.name): \(component.basis)")
                }
            }
            .font(.caption)
            VStack(alignment: .leading, spacing: 5) {
                Text("Modern alternatives · proposed").font(.subheadline.bold())
                ForEach(profile.modernAlternatives, id: \.self) { alternative in
                    DisclosureGroup("\(alternative.name) · \(alternative.target)") {
                        Text(alternative.rationale)
                        Text(alternative.tradeoff).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Performance goals · proposed").font(.subheadline.bold())
                ForEach(profile.performanceGoals, id: \.self) { goal in
                    DisclosureGroup("\(goal.metric): ≤\(goal.target) \(goal.unit)") {
                        Text(goal.validation)
                    }
                    .font(.caption)
                }
                Text("These are starting targets, not measured legacy performance.")
                    .font(.caption2).foregroundStyle(.secondary)
                if let p95 = profile.observedTiming.p95Ms {
                    Text("Capture delay proxy p95: \(p95) ms (\(profile.observedTiming.sampleCount) samples)")
                        .font(.caption)
                }
                Text(profile.observedTiming.limitations).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
    }

    private func section(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.bold())
            Text(text).font(.caption)
        }
    }
}
