import Foundation

// Read-side shapes of the Retrace API (backend/README.md). Decoding is lenient, like the old web
// dashboard's normalizers: missing optional fields get defaults instead of failing the whole payload.
// Keys are spelled out in snake_case and decoded with a plain `JSONDecoder` (`RemoteCoding`), because
// `.convertFromSnakeCase` would also rewrite the keys inside free-form values such as agent `args`.

public enum RemoteCoding {
    public static func decoder() -> JSONDecoder { JSONDecoder() }
}

/// Any JSON value. Used for fields whose shape the contract leaves open (agent tool `args`).
public enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var string: String? { if case .string(let s) = self { return s } else { return nil } }
    public var number: Double? { if case .number(let n) = self { return n } else { return nil } }
    public var array: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
    public subscript(key: String) -> JSONValue? { object?[key] }

    /// Compact single-line JSON (sorted keys), for display.
    public var compactText: String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

public struct RemoteApp: Codable, Hashable, Sendable {
    public var name: String
    public var bundleId: String?
    public init(name: String, bundleId: String? = nil) { self.name = name; self.bundleId = bundleId }
    enum CodingKeys: String, CodingKey { case name, bundleId = "bundle_id" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Unknown app"
        let b = (try? c.decodeIfPresent(String.self, forKey: .bundleId)) ?? nil
        bundleId = b?.isEmpty == false ? b : nil
    }
}

/// Session list entry (`SessionSummary`).
public struct RemoteSessionSummary: Decodable, Hashable, Identifiable, Sendable {
    public var id: String
    public var projectId: String
    public var app: RemoteApp
    public var startedAt: String
    public var durationMs: Int
    /// uploaded | queued | analyzing | analyzed | failed
    public var status: String
    public var networkStatus: String?

    public init(id: String, projectId: String = "p", app: RemoteApp, startedAt: String, durationMs: Int = 0,
                status: String = "uploaded", networkStatus: String? = nil) {
        self.id = id; self.projectId = projectId; self.app = app; self.startedAt = startedAt
        self.durationMs = durationMs; self.status = status; self.networkStatus = networkStatus
    }

    enum CodingKeys: String, CodingKey {
        case id, app, status
        case projectId = "project_id", startedAt = "started_at", durationMs = "duration_ms", networkStatus = "network_status"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        projectId = (try? c.decodeIfPresent(String.self, forKey: .projectId)) ?? ""
        app = (try? c.decodeIfPresent(RemoteApp.self, forKey: .app)) ?? RemoteApp(name: "Unknown app")
        startedAt = (try? c.decodeIfPresent(String.self, forKey: .startedAt)) ?? ""
        durationMs = (try? c.decodeIfPresent(Int.self, forKey: .durationMs)) ?? 0
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "uploaded"
        networkStatus = (try? c.decodeIfPresent(String.self, forKey: .networkStatus)) ?? nil
    }

    /// The server is still working on (or about to start) an analysis.
    public var isAnalyzing: Bool { status == "queued" || status == "analyzing" }
}

/// `GET /v1/devices/me/sessions`
public struct DeviceSessions: Decodable, Sendable {
    public struct Project: Decodable, Sendable { public var id: String; public var name: String }
    public var project: Project?
    public var sessions: [RemoteSessionSummary]
}

public struct RemoteFrame: Decodable, Hashable, Identifiable, Sendable {
    public var id: String
    public var timestampMs: Int
    public var width: Int
    public var height: Int
    public var imageUrl: String?
    public init(id: String, timestampMs: Int = 0, width: Int = 0, height: Int = 0, imageUrl: String? = nil) {
        self.id = id; self.timestampMs = timestampMs; self.width = width; self.height = height; self.imageUrl = imageUrl
    }
    enum CodingKeys: String, CodingKey { case id, width, height, timestampMs = "timestamp_ms", imageUrl = "image_url" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        timestampMs = (try? c.decodeIfPresent(Int.self, forKey: .timestampMs)) ?? 0
        width = (try? c.decodeIfPresent(Int.self, forKey: .width)) ?? 0
        height = (try? c.decodeIfPresent(Int.self, forKey: .height)) ?? 0
        let u = (try? c.decodeIfPresent(String.self, forKey: .imageUrl)) ?? nil
        imageUrl = u?.isEmpty == false ? u : nil
    }
}

public struct RemoteEvidenceRef: Decodable, Hashable, Sendable {
    public var id: String
    public var timestampMs: Int?
    public init(id: String, timestampMs: Int? = nil) { self.id = id; self.timestampMs = timestampMs }
    enum CodingKeys: String, CodingKey { case id, timestampMs = "timestamp_ms" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        timestampMs = (try? c.decodeIfPresent(Int.self, forKey: .timestampMs)) ?? nil
    }
}

public struct RemoteNetworkEvent: Decodable, Hashable, Identifiable, Sendable {
    public var id: String
    public var timestampMs: Int
    public var method: String
    public var url: String
    public var status: Int?
    public init(id: String, timestampMs: Int = 0, method: String = "GET", url: String, status: Int? = nil) {
        self.id = id; self.timestampMs = timestampMs; self.method = method; self.url = url; self.status = status
    }
    enum CodingKeys: String, CodingKey { case id, method, url, status, timestampMs = "timestamp_ms" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        timestampMs = (try? c.decodeIfPresent(Int.self, forKey: .timestampMs)) ?? 0
        method = (try? c.decodeIfPresent(String.self, forKey: .method)) ?? "GET"
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? ""
        status = (try? c.decodeIfPresent(Int.self, forKey: .status)) ?? nil
    }
}

public struct JobStage: Decodable, Hashable, Sendable {
    public var name: String
    public var label: String?
    /// pending | running | done | failed | skipped
    public var status: String
    public var detail: String?
    enum CodingKeys: String, CodingKey { case name, label, status, detail }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "stage"
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? nil
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "pending"
        detail = (try? c.decodeIfPresent(String.self, forKey: .detail)) ?? nil
    }
}

/// One tool call in the Nemotron agent's trace.
public struct AgentStep: Hashable, Sendable, Identifiable {
    public var step: Int
    public var tool: String
    public var reason: String?
    /// Usually only on the first step (or when the agent re-plans).
    public var plan: [String]?
    /// Compact, display-only rendering of the tool arguments.
    public var args: String?
    public var resultSummary: String?
    public var ok: Bool
    public var id: String { "\(step)-\(tool)" }

    public static let argsMax = 160

    /// Entries without a tool are dropped; a missing `ok` counts as success.
    public init?(json: JSONValue, index: Int) {
        guard let o = json.object else { return nil }
        let tool = (o["tool"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tool.isEmpty else { return nil }
        self.tool = tool
        step = o["step"]?.number.flatMap { $0.isFinite ? Int($0) : nil } ?? index
        reason = o["reason"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let plan = (o["plan"]?.array ?? []).compactMap { $0.string }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        self.plan = plan.isEmpty ? nil : plan
        args = o["args"].flatMap(Self.compactArgs)
        resultSummary = o["result_summary"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        if case .bool(false)? = o["ok"] { ok = false } else { ok = true }
    }

    public init(step: Int, tool: String, reason: String? = nil, plan: [String]? = nil, args: String? = nil,
                resultSummary: String? = nil, ok: Bool = true) {
        self.step = step; self.tool = tool; self.reason = reason; self.plan = plan; self.args = args
        self.resultSummary = resultSummary; self.ok = ok
    }

    static func compactArgs(_ v: JSONValue) -> String? {
        let raw: String
        switch v {
        case .string(let s): raw = s
        case .object, .array: raw = v.compactText
        default: return nil
        }
        let text = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty, text != "{}", text != "[]" else { return nil }
        return text.count > argsMax ? String(text.prefix(argsMax - 1)) + "…" : text
    }

    /// A validate_graph call that ran but reported problems with the draft.
    public var isValidationFailure: Bool {
        tool == "validate_graph" && (!ok || (resultSummary ?? "").trimmingCharacters(in: .whitespaces).lowercased().range(of: #"^invalid\b"#, options: .regularExpression) != nil)
    }
}

public struct JobUsage: Decodable, Hashable, Sendable {
    public var calls: Int
    public var promptTokens: Int
    public var completionTokens: Int
    public var estimated: Bool
    enum CodingKeys: String, CodingKey { case calls, estimated, promptTokens = "prompt_tokens", completionTokens = "completion_tokens" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calls = (try? c.decodeIfPresent(Int.self, forKey: .calls)) ?? 0
        promptTokens = (try? c.decodeIfPresent(Int.self, forKey: .promptTokens)) ?? 0
        completionTokens = (try? c.decodeIfPresent(Int.self, forKey: .completionTokens)) ?? 0
        estimated = (try? c.decodeIfPresent(Bool.self, forKey: .estimated)) ?? false
    }
}

public struct RemoteJob: Decodable, Hashable, Sendable {
    public var id: String
    /// queued | running | succeeded | failed
    public var status: String
    public var error: String?
    /// agent | staged | staged_fallback
    public var mode: String?
    public var stages: [JobStage]
    /// Sorted by step. Empty for staged runs and older payloads.
    public var agentTrace: [AgentStep]
    public var usage: JobUsage?

    enum CodingKeys: String, CodingKey { case id, status, error, mode, stages, usage, jobId = "job_id", agentTrace = "agent_trace" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? (try? c.decodeIfPresent(String.self, forKey: .jobId)) ?? ""
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "queued"
        error = (try? c.decodeIfPresent(String.self, forKey: .error)) ?? nil
        let m = (try? c.decodeIfPresent(String.self, forKey: .mode)) ?? nil
        mode = m?.isEmpty == false ? m : nil
        stages = (try? c.decodeIfPresent([JobStage].self, forKey: .stages)) ?? []
        let raw = (try? c.decodeIfPresent([JSONValue].self, forKey: .agentTrace)) ?? []
        agentTrace = raw.enumerated().compactMap { AgentStep(json: $1, index: $0) }.sorted { $0.step < $1.step }
        usage = (try? c.decodeIfPresent(JobUsage.self, forKey: .usage)) ?? nil
    }

    public var isActive: Bool { status == "queued" || status == "running" }
    public var isFallback: Bool { mode == "staged_fallback" }
    /// The latest plan wins, so a re-plan mid-run replaces the original.
    public var plan: [String] { agentTrace.last(where: { $0.plan?.isEmpty == false })?.plan ?? [] }
    public var validationFixes: Int { agentTrace.filter(\.isValidationFailure).count }
    public var agentStage: JobStage? { stages.first { $0.name == "agent" }}
    /// Whether there is anything agent-related to show.
    public var hasAgentTrace: Bool { !agentTrace.isEmpty || mode == "agent" || mode == "staged_fallback" }
}

public struct GraphNode: Decodable, Hashable, Sendable {
    public var id: String
    public var type: String
    public var label: String
    public var evidenceIds: [String]
    public init(id: String, type: String, label: String, evidenceIds: [String] = []) {
        self.id = id; self.type = type; self.label = label; self.evidenceIds = evidenceIds
    }
    enum CodingKeys: String, CodingKey { case id, type, label, evidenceIds = "evidence_ids" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? "screen"
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
        evidenceIds = (try? c.decodeIfPresent([String].self, forKey: .evidenceIds)) ?? []
    }

    static let networkTypes: Set<String> = ["api", "endpoint", "request", "service", "network", "api_call", "host"]
    public var isNetwork: Bool { Self.networkTypes.contains(type.lowercased()) }
}

public struct GraphEdge: Decodable, Hashable, Sendable {
    public var id: String
    public var source: String
    public var target: String
    public var label: String
    public var evidenceIds: [String]
    public init(id: String, source: String, target: String, label: String = "", evidenceIds: [String] = []) {
        self.id = id; self.source = source; self.target = target; self.label = label; self.evidenceIds = evidenceIds
    }
    enum CodingKeys: String, CodingKey { case id, source, target, label, evidenceIds = "evidence_ids" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? ""
        target = (try? c.decodeIfPresent(String.self, forKey: .target)) ?? ""
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
        evidenceIds = (try? c.decodeIfPresent([String].self, forKey: .evidenceIds)) ?? []
    }
}

public struct RemoteGraph: Decodable, Hashable, Sendable {
    public var nodes: [GraphNode]
    public var edges: [GraphEdge]
    public var rebuildProfile: RebuildProfile?
    public init(nodes: [GraphNode], edges: [GraphEdge], rebuildProfile: RebuildProfile? = nil) {
        self.nodes = nodes; self.edges = edges; self.rebuildProfile = rebuildProfile
    }
    enum CodingKeys: String, CodingKey { case nodes, edges, rebuildProfile = "rebuild_profile" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try c.decode([GraphNode].self, forKey: .nodes)
        rebuildProfile = try? c.decodeIfPresent(RebuildProfile.self, forKey: .rebuildProfile)
        edges = (try? c.decodeIfPresent([GraphEdge].self, forKey: .edges)) ?? []
    }

    /// Human corrections are separate records; apply them over agent labels.
    public func applying(_ corrections: [RemoteCorrection]) -> RemoteGraph {
        guard !corrections.isEmpty else { return self }
        let map = Dictionary(corrections.map { ($0.elementId, $0.label) }, uniquingKeysWith: { _, b in b })
        var g = self
        g.nodes = nodes.map { var n = $0; if let l = map[n.id] { n.label = l }; return n }
        g.edges = edges.map { var e = $0; if let l = map[e.id] { e.label = l }; return e }
        return g
    }
}

public struct RemoteCorrection: Decodable, Hashable, Sendable {
    public var elementId: String
    public var label: String
    public init(elementId: String, label: String) { self.elementId = elementId; self.label = label }
    enum CodingKeys: String, CodingKey { case label, elementId = "element_id" }
}

/// `GET /v1/sessions/{id}` as a device of the session's project.
public struct RemoteSessionDetail: Decodable, Hashable, Identifiable, Sendable {
    public var summary: RemoteSessionSummary
    public var frames: [RemoteFrame]
    public var interactions: [RemoteEvidenceRef]
    public var network: [RemoteNetworkEvent]
    public var job: RemoteJob?
    public var graph: RemoteGraph?
    public var corrections: [RemoteCorrection]
    public var boardUrl: String?

    public var id: String { summary.id }

    public init(summary: RemoteSessionSummary, frames: [RemoteFrame] = [], interactions: [RemoteEvidenceRef] = [],
                network: [RemoteNetworkEvent] = [], job: RemoteJob? = nil, graph: RemoteGraph? = nil,
                corrections: [RemoteCorrection] = [], boardUrl: String? = nil) {
        self.summary = summary; self.frames = frames; self.interactions = interactions; self.network = network
        self.job = job; self.graph = graph; self.corrections = corrections; self.boardUrl = boardUrl
    }

    enum CodingKeys: String, CodingKey { case frames, interactions, network, job, graph, corrections, boardUrl = "board_url" }
    public init(from decoder: Decoder) throws {
        summary = try RemoteSessionSummary(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frames = (try? c.decodeIfPresent([RemoteFrame].self, forKey: .frames)) ?? []
        interactions = (try? c.decodeIfPresent([RemoteEvidenceRef].self, forKey: .interactions)) ?? []
        network = (try? c.decodeIfPresent([RemoteNetworkEvent].self, forKey: .network)) ?? []
        job = (try? c.decodeIfPresent(RemoteJob.self, forKey: .job)) ?? nil
        graph = (try? c.decodeIfPresent(RemoteGraph.self, forKey: .graph)) ?? nil
        corrections = (try? c.decodeIfPresent([RemoteCorrection].self, forKey: .corrections)) ?? []
        let b = (try? c.decodeIfPresent(String.self, forKey: .boardUrl)) ?? nil
        boardUrl = b?.isEmpty == false ? b : nil
    }

    /// Network status from the session, else inferred from whether requests are present.
    public var networkStatus: String { summary.networkStatus ?? (network.isEmpty ? "not_captured" : "observed") }
    /// Every evidence id the graph may cite.
    public var evidenceIds: Set<String> { Set(frames.map(\.id) + interactions.map(\.id) + network.map(\.id)) }
    /// The last captured frame with a fetchable image.
    public var lastFrame: RemoteFrame? { frames.last { $0.imageUrl != nil } }
}

/// Only https figma.com links without embedded credentials (the backend enforces the same).
public func validBoardURL(_ s: String) -> URL? {
    guard let c = URLComponents(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
          c.scheme?.lowercased() == "https", c.user == nil, c.password == nil,
          let host = c.host?.lowercased(), host == "figma.com" || host.hasSuffix(".figma.com"),
          let url = c.url else { return nil }
    return url
}
