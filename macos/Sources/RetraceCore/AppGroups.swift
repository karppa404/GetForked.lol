import Foundation

/// One recording of an app as the menu bar panel shows it: an uploaded session, a local session on
/// this Mac that hasn't been uploaded, or both (an uploaded session whose local copy still exists).
public struct Recording: Identifiable, Hashable, Sendable {
    public var appName: String
    public var bundleId: String?
    public var startedAt: String
    public var durationMs: Int
    /// Server status (uploaded | queued | analyzing | analyzed | failed), or `local` / `reviewed`
    /// for a recording that only exists on this Mac.
    public var status: String
    public var networkStatus: String?
    public var remoteId: String?
    public var localId: String?

    public var id: String { remoteId ?? "local:\(localId ?? "")" }
    public var isLocalOnly: Bool { remoteId == nil }
    public var isAnalyzing: Bool { status == "queued" || status == "analyzing" }

    public init(appName: String, bundleId: String?, startedAt: String, durationMs: Int, status: String,
                networkStatus: String? = nil, remoteId: String? = nil, localId: String? = nil) {
        self.appName = appName; self.bundleId = bundleId; self.startedAt = startedAt; self.durationMs = durationMs
        self.status = status; self.networkStatus = networkStatus; self.remoteId = remoteId; self.localId = localId
    }
}

/// Every recording of one app or website, newest first.
public struct AppGroup: Identifiable, Hashable, Sendable {
    /// Bundle id when known, else the lowercased app name.
    public var key: String
    public var name: String
    public var bundleId: String?
    public var recordings: [Recording]
    /// At least one recording observed network requests.
    public var hasNetwork: Bool
    public var lastRecordedAt: String

    public var id: String { key }
    public var newest: Recording { recordings[0] }
    public var remoteIds: [String] { recordings.compactMap(\.remoteId) }
    public var isAnalyzing: Bool { recordings.contains(where: \.isAnalyzing) }
    /// A SaaS website scan rather than a desktop app.
    public var isWeb: Bool { AppGrouping.isWebScan(bundleId: bundleId) }
}

public enum AppGrouping {
    /// Web scans record their target as `web.<host>` (in the manifest and on the server), so they
    /// group by site and never share a group with the browser that ran them.
    public static let webBundlePrefix = "web."

    public static func webBundleId(host: String) -> String { webBundlePrefix + host.lowercased() }

    public static func isWebScan(bundleId: String?) -> Bool {
        guard let b = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return b.hasPrefix(webBundlePrefix) && b.count > webBundlePrefix.count
    }

    public static func key(name: String, bundleId: String?) -> String {
        let b = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !b.isEmpty, b != "unknown" { return b }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return n.isEmpty ? "unknown" : n
    }

    /// Uploaded sessions first; a local session is attached to its uploaded copy when that copy is on
    /// this server, otherwise it is listed as local-only.
    public static func recordings(remote: [RemoteSessionSummary], local: [LocalSession], apiBaseURL: String?) -> [Recording] {
        var localByRemote: [String: String] = [:]
        for l in local {
            if let rid = l.upload.remoteSessionId, l.upload.apiBaseURL == apiBaseURL { localByRemote[rid] = l.id }
        }
        let remoteIds = Set(remote.map(\.id))
        var out = remote.map { s in
            Recording(appName: s.app.name, bundleId: s.app.bundleId, startedAt: s.startedAt, durationMs: s.durationMs,
                      status: s.status, networkStatus: s.networkStatus, remoteId: s.id, localId: localByRemote[s.id])
        }
        for l in local {
            if let rid = l.upload.remoteSessionId, l.upload.apiBaseURL == apiBaseURL, remoteIds.contains(rid) { continue }
            let m = l.manifest
            out.append(Recording(appName: m.app.name, bundleId: m.app.bundleId, startedAt: m.startedAt, durationMs: m.durationMs,
                                 status: l.review.isConfirmed ? "reviewed" : "local", networkStatus: m.networkStatus.rawValue,
                                 remoteId: nil, localId: l.id))
        }
        return out
    }

    /// One group per app, newest recording first, groups ordered by their newest recording.
    public static func group(_ recordings: [Recording]) -> [AppGroup] {
        let newest = recordings.sorted { date($0.startedAt) > date($1.startedAt) }
        var order: [String] = []
        var groups: [String: AppGroup] = [:]
        for r in newest {
            let k = key(name: r.appName, bundleId: r.bundleId)
            if groups[k] == nil {
                order.append(k)
                groups[k] = AppGroup(key: k, name: r.appName, bundleId: r.bundleId == "unknown" ? nil : r.bundleId,
                                     recordings: [], hasNetwork: false, lastRecordedAt: r.startedAt)
            }
            groups[k]!.recordings.append(r)
            if r.networkStatus == "observed" { groups[k]!.hasNetwork = true }
        }
        return order.map { groups[$0]! }
    }

    /// ISO 8601 with or without fractional seconds; unparseable strings sort last.
    static func date(_ s: String) -> Date { SessionClock.parseISO8601(s) ?? .distantPast }
}
