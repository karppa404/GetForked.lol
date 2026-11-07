import Foundation

/// The user's local review decisions. Applying a review is the only way to produce an
/// uploadable manifest. Retrace does **not** detect sensitive content automatically: what is
/// removed is exactly what the user chose to omit, nothing more.
public struct ReviewState: Codable, Equatable, Sendable {
    public var omittedFrameIds: Set<String>
    public var omittedInteractionIds: Set<String>
    public var removeWindowTitles: Bool
    public var removeAccessibilityText: Bool
    /// Set only by an explicit confirmation in the review UI.
    public var confirmedAt: String?

    public init(omittedFrameIds: Set<String> = [], omittedInteractionIds: Set<String> = [],
                removeWindowTitles: Bool = false, removeAccessibilityText: Bool = false, confirmedAt: String? = nil) {
        self.omittedFrameIds = omittedFrameIds
        self.omittedInteractionIds = omittedInteractionIds
        self.removeWindowTitles = removeWindowTitles
        self.removeAccessibilityText = removeAccessibilityText
        self.confirmedAt = confirmedAt
    }

    public var isConfirmed: Bool { confirmedAt != nil }
}

public enum ReviewError: Error, Equatable, CustomStringConvertible {
    case notConfirmed
    case missingProject
    case invalid([ValidationIssue])

    public var description: String {
        switch self {
        case .notConfirmed: return "Review the session and confirm before uploading."
        case .missingProject: return "Connect this Mac to the Local workspace before uploading."
        case .invalid(let issues): return "Manifest failed validation: " + issues.map(\.description).joined(separator: "; ")
        }
    }
}

public enum ReviewApplier {
    /// Produces the redacted manifest that will be uploaded. Omitted frames are removed and
    /// every reference to them cleared; omitted interactions are removed entirely.
    public static func apply(_ review: ReviewState, to raw: SessionManifest, projectId: String?) throws -> SessionManifest {
        guard review.isConfirmed else { throw ReviewError.notConfirmed }
        guard let projectId, !projectId.isEmpty else { throw ReviewError.missingProject }

        var m = raw
        m.projectId = projectId
        m.frames = raw.frames.filter { !review.omittedFrameIds.contains($0.id) }
        let kept = Set(m.frames.map(\.id))
        m.interactions = raw.interactions
            .filter { !review.omittedInteractionIds.contains($0.id) }
            .map { item in
                var it = item
                if let id = it.beforeFrameId, !kept.contains(id) { it.beforeFrameId = nil }
                if let id = it.afterFrameId, !kept.contains(id) { it.afterFrameId = nil }
                if let id = it.delayedFrameId, !kept.contains(id) { it.delayedFrameId = nil }
                if var ax = it.accessibility?.sanitized() {
                    if review.removeWindowTitles { ax.windowTitle = nil }
                    if review.removeAccessibilityText { ax.title = nil; ax.label = nil }
                    it.accessibility = ax
                }
                return it
            }
        m.redaction = Redaction(
            reviewed: true,
            omittedFrames: raw.frames.count - m.frames.count,
            omittedInteractions: raw.interactions.count - m.interactions.count,
            windowTitlesRemoved: review.removeWindowTitles
        )
        let issues = ManifestValidator.validate(m, purpose: .upload)
        guard issues.isEmpty else { throw ReviewError.invalid(issues) }
        return m
    }
}
