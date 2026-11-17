import Foundation

// Pure aggregation of recorded network traffic into a minimal API reference for one app.
// Groups requests by host, then by method + normalized path (IDs collapsed to `{id}`).
// Ported from the former web dashboard (web/lib/dashboard/api-docs.ts), which this replaces.

public struct APIQueryParam: Hashable, Sendable {
    public var name: String
    public var value: String
}

public struct APIExample: Hashable, Sendable {
    /// Full URL with secret query values redacted (no fragment, no credentials).
    public var url: String
    public var query: [APIQueryParam]
    public var status: Int?
    public var sessionId: String
}

public struct APISighting: Hashable, Sendable {
    public var sessionId: String
    /// Absolute time when the session start is known.
    public var at: Date?
    public var timestampMs: Int
    var sortKey: Double { at.map { $0.timeIntervalSince1970 * 1000 } ?? Double(timestampMs) }
}

public struct APIEndpoint: Hashable, Identifiable, Sendable {
    /// `METHOD host path`
    public var id: String
    public var method: String
    public var host: String
    /// Normalized path, e.g. `/api/invoices/{id}/send`.
    public var path: String
    public var calls: Int
    /// Distinct observed status codes, ascending.
    public var statuses: [Int]
    public var queryParams: [String]
    /// Up to `APIDocs.maxExamples` distinct redacted URLs, first seen first.
    public var examples: [APIExample]
    public var firstSeen: APISighting
    public var lastSeen: APISighting
    /// UI action labels the analysis graph links to this endpoint's requests.
    public var triggeredBy: [String]
    /// Distinct recordings that called this endpoint.
    public var sessions: Int
}

public struct APIHost: Hashable, Identifiable, Sendable {
    public var host: String
    public var calls: Int
    public var endpoints: [APIEndpoint]
    public var id: String { host }
}

public struct APIDocsInput: Sendable {
    public var id: String
    public var startedAt: String
    public var network: [RemoteNetworkEvent]
    public var graph: RemoteGraph?
    public var corrections: [RemoteCorrection]
    public init(id: String, startedAt: String, network: [RemoteNetworkEvent], graph: RemoteGraph? = nil, corrections: [RemoteCorrection] = []) {
        self.id = id; self.startedAt = startedAt; self.network = network; self.graph = graph; self.corrections = corrections
    }
    public init(_ d: RemoteSessionDetail) {
        self.init(id: d.id, startedAt: d.summary.startedAt, network: d.network, graph: d.graph, corrections: d.corrections)
    }
}

public struct APIDocs: Hashable, Sendable {
    public var hosts: [APIHost]
    public var endpointCount: Int
    public var requestCount: Int
    /// Recordings that contributed at least one request.
    public var sessionCount: Int

    public static let maxExamples = 3
    public static let unknownHost = "(unknown host)"
    public static let redacted = "[redacted]"
    static let methodOrder = ["GET", "POST", "PUT", "PATCH", "DELETE"]

    static let secretParam = #"token|secret|passw|pwd|api[-_]?key|apikey|^key$|access[-_]?key|private[-_]?key|auth|signature|^sig$|session|credential|^code$|^otp$"#

    public static func isSecretParam(_ name: String) -> Bool { matches(secretParam, name, caseInsensitive: true) }

    /// True for path segments that look like record identifiers rather than route names.
    public static func isIdSegment(_ seg: String) -> Bool {
        if seg.isEmpty || matches(#"^v\d+(\.\d+)*$"#, seg, caseInsensitive: true) { return false }
        let hasDigit = seg.contains(where: \.isNumber)
        if matches(#"^\d+$"#, seg) { return true }
        if matches(#"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, seg, caseInsensitive: true) { return true }
        if matches(#"^[0-9a-f]{8,}$"#, seg, caseInsensitive: true) && hasDigit { return true } // hashes, object ids
        if matches(#"^[a-z]{1,12}_[A-Za-z0-9]+$"#, seg) && hasDigit { return true } // prefixed ids: cus_123
        if matches(#"^[A-Za-z0-9_-]{16,}$"#, seg) && hasDigit && seg.contains(where: \.isLetter) { return true } // opaque tokens
        return false
    }

    public static func normalizePath(_ pathname: String) -> String {
        let segs = pathname.components(separatedBy: "/").map { s -> String in
            isIdSegment(s.removingPercentEncoding ?? s) ? "{id}" : s
        }
        var out = segs.joined(separator: "/")
        if out.isEmpty { out = "/" }
        if out.count > 1 && out.hasSuffix("/") { out.removeLast() }
        return out
    }

    public struct ParsedURL: Hashable, Sendable {
        public var host: String
        public var path: String
        public var query: [APIQueryParam]
        public var url: String
    }

    public static func parseRequestURL(_ raw: String) -> ParsedURL {
        guard let c = URLComponents(string: raw) else {
            return ParsedURL(host: unknownHost, path: raw.isEmpty ? "/" : raw, query: [], url: raw)
        }
        let absolute = c.scheme != nil && !(c.host ?? "").isEmpty
        let query = (c.queryItems ?? []).map { item -> APIQueryParam in
            // URLSearchParams treats `+` as a space.
            let name = item.name.replacingOccurrences(of: "+", with: " ")
            let value = (item.value ?? "").replacingOccurrences(of: "+", with: " ")
            return APIQueryParam(name: name, value: isSecretParam(name) ? redacted : value)
        }
        let qs = query.isEmpty ? "" : "?" + query.map { q in
            "\(encodeURIComponent(q.name))=\(q.value == redacted ? redacted : encodeURIComponent(q.value))"
        }.joined(separator: "&")
        var pathname = c.percentEncodedPath
        if pathname.isEmpty || !pathname.hasPrefix("/") { pathname = "/" + pathname }
        guard absolute, let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased() else {
            return ParsedURL(host: unknownHost, path: normalizePath(pathname), query: query, url: "\(pathname)\(qs)")
        }
        let defaultPort = (scheme == "https" && c.port == 443) || (scheme == "http" && c.port == 80)
        let hostPort = c.port.map { defaultPort ? host : "\(host):\($0)" } ?? host
        return ParsedURL(host: hostPort, path: normalizePath(pathname), query: query, url: "\(scheme)://\(hostPort)\(pathname)\(qs)")
    }

    /// Network event id → UI action labels linked to it through api_call nodes and their incoming edges.
    static func triggersByEvent(_ session: APIDocsInput) -> [String: [String]] {
        guard let raw = session.graph else { return [:] }
        let graph = raw.applying(session.corrections)
        let byId = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let eventIds = Set(session.network.map(\.id))
        var out: [String: [String]] = [:]
        for node in graph.nodes where node.isNetwork {
            let incoming = graph.edges.filter { e in e.target == node.id && byId[e.source].map { !$0.isNetwork } == true }
            for ev in node.evidenceIds where eventIds.contains(ev) {
                // Prefer edges that cite this exact request; fall back to every edge into the endpoint.
                let precise = incoming.filter { $0.evidenceIds.contains(ev) }
                var labels = out[ev] ?? []
                for e in (precise.isEmpty ? incoming : precise) {
                    let label = byId[e.source]!.label.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !label.isEmpty, !labels.contains(label) { labels.append(label) }
                }
                out[ev] = labels
            }
        }
        return out
    }

    public static func build(_ sessions: [APIDocsInput]) -> APIDocs {
        var order: [String] = []
        var endpoints: [String: APIEndpoint] = [:]
        var endpointSessions: [String: Set<String>] = [:]
        var contributing = Set<String>()
        var requests = 0

        for session in sessions {
            let triggers = triggersByEvent(session)
            let start = SessionClock.parseISO8601(session.startedAt)
            for ev in session.network {
                let method = (ev.method.isEmpty ? "GET" : ev.method).uppercased()
                let parsed = parseRequestURL(ev.url)
                let id = "\(method) \(parsed.host) \(parsed.path)"
                let sighting = APISighting(sessionId: session.id, at: start.map { $0.addingTimeInterval(Double(ev.timestampMs) / 1000) },
                                           timestampMs: ev.timestampMs)
                requests += 1
                contributing.insert(session.id)
                if endpoints[id] == nil {
                    order.append(id)
                    endpoints[id] = APIEndpoint(id: id, method: method, host: parsed.host, path: parsed.path, calls: 0, statuses: [],
                                                queryParams: [], examples: [], firstSeen: sighting, lastSeen: sighting, triggeredBy: [], sessions: 0)
                }
                var ep = endpoints[id]!
                ep.calls += 1
                endpointSessions[id, default: []].insert(session.id)
                if let s = ev.status, !ep.statuses.contains(s) { ep.statuses.append(s) }
                for q in parsed.query where !ep.queryParams.contains(q.name) { ep.queryParams.append(q.name) }
                if ep.examples.count < maxExamples, !ep.examples.contains(where: { $0.url == parsed.url }) {
                    ep.examples.append(APIExample(url: parsed.url, query: parsed.query, status: ev.status, sessionId: session.id))
                }
                if sighting.sortKey < ep.firstSeen.sortKey { ep.firstSeen = sighting }
                if sighting.sortKey > ep.lastSeen.sortKey { ep.lastSeen = sighting }
                for label in triggers[ev.id] ?? [] where !ep.triggeredBy.contains(label) { ep.triggeredBy.append(label) }
                endpoints[id] = ep
            }
        }

        var hostOrder: [String] = []
        var hosts: [String: APIHost] = [:]
        for id in order {
            var ep = endpoints[id]!
            ep.sessions = endpointSessions[id]?.count ?? 0
            ep.statuses.sort()
            if hosts[ep.host] == nil { hostOrder.append(ep.host); hosts[ep.host] = APIHost(host: ep.host, calls: 0, endpoints: []) }
            hosts[ep.host]!.calls += ep.calls
            hosts[ep.host]!.endpoints.append(ep)
        }
        func rank(_ m: String) -> Int { methodOrder.firstIndex(of: m) ?? methodOrder.count }
        var list = hostOrder.map { hosts[$0]! }
        for i in list.indices {
            list[i].endpoints.sort { a, b in
                if a.path != b.path { return a.path.localizedCompare(b.path) == .orderedAscending }
                if rank(a.method) != rank(b.method) { return rank(a.method) < rank(b.method) }
                return a.method < b.method
            }
        }
        list.sort { $0.calls != $1.calls ? $0.calls > $1.calls : $0.host.localizedCompare($1.host) == .orderedAscending }
        return APIDocs(hosts: list, endpointCount: order.count, requestCount: requests, sessionCount: contributing.count)
    }

    /// Case-insensitive filter over method, host, path, query params, statuses and triggering actions.
    public func filtered(_ query: String) -> [APIHost] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return hosts }
        let terms = q.split(whereSeparator: \.isWhitespace).map(String.init)
        return hosts.compactMap { h in
            let eps = h.endpoints.filter { ep in
                let hay = ([ep.method, ep.host, ep.path] + ep.queryParams + ep.triggeredBy + ep.statuses.map(String.init))
                    .joined(separator: " ").lowercased()
                return terms.allSatisfy { hay.contains($0) }
            }
            return eps.isEmpty ? nil : APIHost(host: h.host, calls: eps.reduce(0) { $0 + $1.calls }, endpoints: eps)
        }
    }

    static func matches(_ pattern: String, _ s: String, caseInsensitive: Bool = false) -> Bool {
        s.range(of: pattern, options: caseInsensitive ? [.regularExpression, .caseInsensitive] : .regularExpression) != nil
    }

    /// JavaScript's encodeURIComponent.
    static func encodeURIComponent(_ s: String) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        allowed.insert(charactersIn: "-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
