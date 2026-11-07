import Foundation

public struct ValidationIssue: Equatable, Sendable, CustomStringConvertible {
    public let path: String
    public let message: String
    public init(_ path: String, _ message: String) { self.path = path; self.message = message }
    public var description: String { "\(path): \(message)" }
}

public enum ManifestValidator {
    public enum Purpose: Sendable {
        /// A locally stored recording (not yet reviewed, project may be unknown).
        case local
        /// About to be uploaded: must be reviewed and bound to a project.
        case upload
    }

    public static func isUUID(_ s: String) -> Bool { UUID(uuidString: s) != nil }

    /// Safe relative basename: no separators, no traversal, no hidden files, limited charset.
    public static func isSafeFilename(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 128, !s.hasPrefix("."), s != "..", !s.contains("..") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func isSHA256Hex(_ s: String) -> Bool {
        s.count == 64 && s.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdef").contains($0) }
    }

    public static func validate(_ m: SessionManifest, purpose: Purpose) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func fail(_ p: String, _ msg: String) { issues.append(ValidationIssue(p, msg)) }

        if m.schemaVersion != SessionManifest.currentSchemaVersion { fail("schema_version", "must be 1") }
        if !isUUID(m.id) { fail("id", "must be a UUID") }
        if purpose == .upload {
            if (m.projectId ?? "").isEmpty { fail("project_id", "required for upload") }
            if !m.redaction.reviewed { fail("redaction.reviewed", "session must be reviewed before upload") }
        }
        if m.app.name.isEmpty { fail("app.name", "required") }
        if m.app.bundleId.isEmpty { fail("app.bundle_id", "required") }
        if m.app.pid <= 0 { fail("app.pid", "must be positive") }
        if SessionClock.parseISO8601(m.startedAt) == nil || !m.startedAt.hasSuffix("Z") {
            fail("started_at", "must be ISO 8601 UTC")
        }
        if m.durationMs < 0 { fail("duration_ms", "must be >= 0") }

        var ids = Set<String>()
        func checkId(_ id: String, _ path: String) {
            if !isUUID(id) { fail(path, "id must be a UUID") }
            if !ids.insert(id).inserted { fail(path, "duplicate evidence id \(id)") }
        }
        func checkTs(_ ts: Int, _ path: String) {
            if ts < 0 || ts > m.durationMs { fail(path, "timestamp_ms \(ts) outside 0...\(m.durationMs)") }
        }

        var frameById: [String: Frame] = [:]
        var filenames = Set<String>()
        for (i, f) in m.frames.enumerated() {
            let p = "frames[\(i)]"
            checkId(f.id, p + ".id")
            checkTs(f.timestampMs, p + ".timestamp_ms")
            if !isSafeFilename(f.filename) { fail(p + ".filename", "unsafe filename") }
            if !filenames.insert(f.filename).inserted { fail(p + ".filename", "duplicate filename") }
            if f.width <= 0 || f.height <= 0 { fail(p, "width/height must be positive") }
            if !isSHA256Hex(f.sha256) { fail(p + ".sha256", "must be lowercase hex SHA-256") }
            frameById[f.id] = f
        }
        for i in m.frames.indices.dropFirst() where m.frames[i].timestampMs < m.frames[i - 1].timestampMs {
            fail("frames[\(i)].timestamp_ms", "frames must be sorted by time")
        }

        for (i, it) in m.interactions.enumerated() {
            let p = "interactions[\(i)]"
            checkId(it.id, p + ".id")
            checkTs(it.timestampMs, p + ".timestamp_ms")
            if i > 0, it.timestampMs < m.interactions[i - 1].timestampMs { fail(p + ".timestamp_ms", "interactions must be sorted by time") }
            if let key = it.key, !KeyNaming.isSafeKeyValue(key) { fail(p + ".key", "key value is not a safe named key") }
            if it.kind == .textInput, it.key != KeyNaming.redacted { fail(p + ".key", "text_input must be redacted") }
            if it.accessibility?.secure == true, it.accessibility?.title != nil || it.accessibility?.label != nil {
                fail(p + ".accessibility", "secure field must not carry title/label")
            }
            let refs: [(String, String?)] = [("before_frame_id", it.beforeFrameId), ("after_frame_id", it.afterFrameId), ("delayed_frame_id", it.delayedFrameId)]
            for (name, ref) in refs {
                guard let ref else { continue }
                guard let f = frameById[ref] else { fail("\(p).\(name)", "references missing frame \(ref)"); continue }
                if name == "before_frame_id", f.timestampMs > it.timestampMs { fail("\(p).\(name)", "before frame is after the interaction") }
                if name != "before_frame_id", f.timestampMs < it.timestampMs { fail("\(p).\(name)", "after/delayed frame precedes the interaction") }
            }
        }

        switch m.networkStatus {
        case .notCaptured, .noneObserved:
            if !m.network.isEmpty { fail("network", "must be empty when network_status is \(m.networkStatus.rawValue)") }
        case .observed:
            if m.network.isEmpty { fail("network", "observed status requires events") }
        }
        for (i, n) in m.network.enumerated() {
            checkId(n.id, "network[\(i)].id")
            checkTs(n.timestampMs, "network[\(i)].timestamp_ms")
        }
        return issues
    }
}
