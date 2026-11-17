import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RetraceCore

private func summary(_ id: String, _ app: String, _ bundle: String?, _ at: String, status: String = "analyzed", network: String? = nil) -> RemoteSessionSummary {
    RemoteSessionSummary(id: id, app: RemoteApp(name: app, bundleId: bundle), startedAt: at, status: status, networkStatus: network)
}

@Suite("App grouping")
struct AppGroupingTests {
    @Test func groupsByBundleIdNewestFirst() {
        let recs = AppGrouping.recordings(remote: [
            summary("a1", "Ledger", "com.example.ledger", "2026-11-07T10:00:00Z"),
            summary("b1", "Notes", "com.apple.Notes", "2026-11-07T12:00:00.000Z", status: "queued"),
            summary("a2", "Ledger Beta", "com.example.ledger", "2026-11-07T13:00:00Z", network: "observed"),
            summary("c1", "Tool", nil, "2026-11-06T09:00:00Z"),
            summary("c2", " tool ", "", "2026-11-06T08:00:00Z"),
        ], local: [], apiBaseURL: nil)
        let groups = AppGrouping.group(recs)
        #expect(groups.map(\.key) == ["com.example.ledger", "com.apple.Notes", "tool"])
        #expect(groups[0].name == "Ledger Beta", "name comes from the newest recording")
        #expect(groups[0].recordings.map(\.remoteId) == ["a2", "a1"])
        #expect(groups[0].hasNetwork && !groups[1].hasNetwork)
        #expect(groups[1].isAnalyzing && !groups[0].isAnalyzing)
        #expect(groups[2].recordings.count == 2 && groups[2].bundleId == nil)
    }

    @Test func mergesLocalSessionsWithTheirUploads() throws {
        var uploaded = try loadFixture()
        uploaded.upload = UploadRecord(remoteSessionId: "r1", uploadedAt: nil, apiBaseURL: "http://127.0.0.1:8000")
        var elsewhere = try loadFixture()
        elsewhere.manifest.id = "22222222-2222-4222-8222-222222222222"
        elsewhere.upload = UploadRecord(remoteSessionId: "r9", uploadedAt: nil, apiBaseURL: "http://localhost:9999")
        let local = try loadFixture()
        let remote = [summary("r1", local.manifest.app.name, local.manifest.app.bundleId, local.manifest.startedAt)]

        let recs = AppGrouping.recordings(remote: remote, local: [uploaded, elsewhere], apiBaseURL: "http://127.0.0.1:8000")
        #expect(recs.count == 2)
        #expect(recs[0].remoteId == "r1" && recs[0].localId == uploaded.id, "local copy attached to its upload")
        #expect(recs[1].isLocalOnly && recs[1].localId == elsewhere.id && recs[1].status == "local")
        let groups = AppGrouping.group(recs)
        #expect(groups.count == 1 && groups[0].remoteIds == ["r1"])
    }

    @Test func separatesWebsiteScansFromDesktopApps() {
        let groups = AppGrouping.group(AppGrouping.recordings(remote: [
            summary("w1", "scrabblebot.spacetimedb.com", AppGrouping.webBundleId(host: "scrabblebot.spacetimedb.com"), "2026-11-07T10:00:00Z"),
            summary("d1", "Clock", "com.apple.clock", "2026-11-07T11:00:00Z"),
            summary("d2", "Tool", nil, "2026-11-07T09:00:00Z"),
        ], local: [], apiBaseURL: nil))
        #expect(groups.filter(\.isWeb).map(\.key) == ["web.scrabblebot.spacetimedb.com"])
        #expect(groups.filter { !$0.isWeb }.map(\.key) == ["com.apple.clock", "tool"])
        #expect(AppGrouping.isWebScan(bundleId: " Web.Example.com "))
        for desktop in [nil, "", "web.", "com.web.app", "website.app", "unknown"] { #expect(!AppGrouping.isWebScan(bundleId: desktop)) }
    }
}

@Suite("API docs")
struct APIDocsTests {
    @Test func normalizesIdSegments() {
        #expect(APIDocs.normalizePath("/api/v2/invoices/8812/send/") == "/api/v2/invoices/{id}/send")
        #expect(APIDocs.normalizePath("/u/3f2b1c4d-1111-4222-8333-123456789abc") == "/u/{id}")
        #expect(APIDocs.normalizePath("/c/cus_123/x/abcdef12") == "/c/{id}/x/{id}")
        #expect(APIDocs.normalizePath("/settings/profile") == "/settings/profile")
        #expect(APIDocs.normalizePath("") == "/")
        #expect(!APIDocs.isIdSegment("v1") && !APIDocs.isIdSegment("deadbeef") && APIDocs.isIdSegment("tok3nAbcdefghijklmn"))
    }

    @Test func redactsSecretsAndStripsCredentials() {
        let p = APIDocs.parseRequestURL("https://user:pw@API.example.com:443/v1/orders?api_key=abc&page=2&q=a%20b#frag")
        #expect(p.host == "api.example.com" && p.path == "/v1/orders")
        #expect(p.query == [APIQueryParam(name: "api_key", value: "[redacted]"), APIQueryParam(name: "page", value: "2"), APIQueryParam(name: "q", value: "a b")])
        #expect(p.url == "https://api.example.com/v1/orders?api_key=[redacted]&page=2&q=a%20b")
        let rel = APIDocs.parseRequestURL("/graphql?session=x")
        #expect(rel.host == APIDocs.unknownHost && rel.url == "/graphql?session=[redacted]")
        #expect(APIDocs.parseRequestURL("http://localhost:8080/x").host == "localhost:8080")
    }

    @Test func aggregatesEndpointsWithTriggers() {
        let graph = RemoteGraph(nodes: [
            GraphNode(id: "a1", type: "action", label: "Click Save"),
            GraphNode(id: "n1", type: "api_call", label: "POST /orders", evidenceIds: ["e1", "e2"]),
        ], edges: [GraphEdge(id: "x1", source: "a1", target: "n1", evidenceIds: ["e1"])])
        let s1 = APIDocsInput(id: "s1", startedAt: "2026-11-07T20:00:00Z", network: [
            RemoteNetworkEvent(id: "e1", timestampMs: 900, method: "post", url: "https://api.example.com/v1/orders/12?page=1", status: 201),
            RemoteNetworkEvent(id: "e2", timestampMs: 100, method: "POST", url: "https://api.example.com/v1/orders/13", status: 500),
            RemoteNetworkEvent(id: "e3", timestampMs: 50, url: "https://cdn.example.com/a.js"),
        ], graph: graph, corrections: [RemoteCorrection(elementId: "a1", label: "Save order")])
        let s2 = APIDocsInput(id: "s2", startedAt: "2026-11-08T20:00:00Z", network: [
            RemoteNetworkEvent(id: "f1", timestampMs: 0, method: "GET", url: "https://api.example.com/v1/orders/14", status: 200),
            RemoteNetworkEvent(id: "f2", timestampMs: 0, method: "POST", url: "https://api.example.com/v1/orders/15", status: 201),
        ])
        let docs = APIDocs.build([s1, s2])
        #expect(docs.requestCount == 5 && docs.endpointCount == 3 && docs.sessionCount == 2)
        #expect(docs.hosts.map(\.host) == ["api.example.com", "cdn.example.com"])
        let api = docs.hosts[0]
        #expect(api.calls == 4 && api.endpoints.map(\.method) == ["GET", "POST"], "same path sorts by method order")
        let post = api.endpoints[1]
        #expect(post.path == "/v1/orders/{id}" && post.calls == 3 && post.statuses == [201, 500] && post.sessions == 2)
        #expect(post.queryParams == ["page"] && post.examples.count == 3)
        #expect(post.triggeredBy == ["Save order"], "corrections apply to trigger labels")
        #expect(post.firstSeen.timestampMs == 100 && post.firstSeen.sessionId == "s1" && post.lastSeen.sessionId == "s2")

        #expect(docs.filtered("post 500").map(\.host) == ["api.example.com"])
        #expect(docs.filtered("save").first?.endpoints.count == 1)
        #expect(docs.filtered("nothing-matches").isEmpty)
        #expect(docs.filtered("  ") == docs.hosts)
    }
}

@Suite("Export UI flow")
struct FlowExportTests {
    static let graphJSON = #"""
    {"schema_version":1,"graph_version":2,"network_status":"not_captured","ambiguities":[],"corrections":[],
     "nodes":[{"id":"s1","type":"screen","label":"Start","evidence_ids":["f1","i1"]},
              {"id":"a1","type":"action","label":"Click","evidence_ids":["i1"]},
              {"id":"s2","type":"screen","label":"Next","evidence_ids":["i1","f2"]},
              {"id":"s3","type":"screen","label":"No image","evidence_ids":["f3"]}],
     "edges":[{"id":"e1","source":"s1","target":"a1","label":"","evidence_ids":["i1"],"association":"observed"},
              {"id":"e2","source":"a1","target":"s2","label":"","evidence_ids":["i1"],"association":"observed"}]}
    """#
    let frames = [RemoteFrame(id: "f1", imageUrl: "/v1/sessions/s/frames/f1"), RemoteFrame(id: "f2", imageUrl: "/v1/sessions/s/frames/f2"), RemoteFrame(id: "f3")]
    let evidence: Set<String> = ["f1", "f2", "f3", "i1"]

    @Test func validatesGraph() throws {
        let g = try FlowExport.parseGraph(Data(Self.graphJSON.utf8))
        #expect(FlowExport.validate(g, evidenceIds: evidence).ok)

        var bad = g
        var nodes = g["nodes"] as! [[String: Any]]
        nodes.append(["id": "n1", "type": "api_call", "label": "GET /x", "evidence_ids": ["nope"]])
        nodes.append(["id": "s1", "type": "screen", "label": " ", "evidence_ids": []])
        bad["nodes"] = nodes
        var edges = g["edges"] as! [[String: Any]]
        edges.append(["id": "e3", "source": "s1", "target": "ghost", "evidence_ids": [], "association": "maybe"])
        bad["edges"] = edges
        let v = FlowExport.validate(bad, evidenceIds: evidence)
        #expect(v.errors == [
            "Node n1: unknown evidence reference nope.",
            "Node n1: network node present but network_status is not_captured.",
            "Duplicate element id s1.",
            "Node s1: label is empty.",
            "Edge e3: target ghost is not a node.",
            "Edge e3: association must be observed or candidate.",
            "Edge e3 cites no supporting evidence.",
        ])
        #expect(v.message == "The graph didn’t pass validation: Node n1: unknown evidence reference nope. (+6 more)")
        #expect(FlowExport.validate(["schema_version": 2, "nodes": [], "edges": [], "network_status": "observed"], evidenceIds: nil).errors
                == ["Unsupported schema_version 2 (expected 1)."])
        #expect(throws: FlowExportError.notAGraph) { try FlowExport.parseGraph(Data("[1]".utf8)) }
    }

    @Test func picksOneFramePerScreen() throws {
        let g = try FlowExport.parseGraph(Data(Self.graphJSON.utf8))
        let picked = FlowExport.screenFrames(g, frames: frames)
        #expect(picked.map(\.nodeId) == ["s1", "s2"] && picked.map(\.frame.id) == ["f1", "f2"], "frames without an image are skipped")
    }

    @Test func documentKeepsGraphAndAddsScreenshots() throws {
        let g = try FlowExport.parseGraph(Data(Self.graphJSON.utf8))
        let shot = ExportScreenshot(frameId: "f1", data: "data:image/jpeg;base64,AAAA", width: 1200, height: 750)
        let doc = try jsonObject(FlowExport.document(graph: g, screenshots: ["s1": shot]))
        #expect(Set(doc.keys) == Set(g.keys).union(["screenshots"]))
        #expect(doc["graph_version"] as? Int == 2 && (doc["nodes"] as? [Any])?.count == 4)
        let shots = doc["screenshots"] as! [String: [String: Any]]
        #expect(shots.keys.sorted() == ["s1"])
        #expect(shots["s1"]! as NSDictionary == ["frame_id": "f1", "data": "data:image/jpeg;base64,AAAA", "width": 1200, "height": 750])
        let plain = try jsonObject(FlowExport.document(graph: g, screenshots: [:]))
        #expect(plain["screenshots"] == nil, "no key when nothing was embedded")
    }

    @Test func encodesDownscaledJPEG() throws {
        let ctx = CGContext(data: nil, width: 2400, height: 1500, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0.4, blue: 0.3, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 2400, height: 1500))
        let png = NSMutableData()
        let dest = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))

        let shot = try #require(FlowExport.encodeScreenshot(png as Data, frameId: "f1"))
        #expect(shot.frameId == "f1" && shot.width == 1200 && shot.height == 750)
        #expect(shot.data.hasPrefix("data:image/jpeg;base64,"))
        let jpeg = try #require(Data(base64Encoded: String(shot.data.dropFirst("data:image/jpeg;base64,".count))))
        #expect(jpeg.starts(with: [0xFF, 0xD8]))
        #expect(FlowExport.encodeScreenshot(Data("not an image".utf8), frameId: "x") == nil)
    }

    @Test func filenameMatchesWebExport() {
        #expect(FlowExport.filename(appName: "Microsoft Excel (Beta)!", sessionId: "3f2b1c4d-1111") == "retrace-microsoft-excel-beta-3f2b1c4d.graph.json")
        #expect(FlowExport.filename(appName: "日本", sessionId: "abcdefghij") == "retrace-session-abcdefgh.graph.json")
    }

    @Test func boardURLRules() {
        #expect(validBoardURL("https://www.figma.com/board/abc/Retrace") != nil)
        #expect(validBoardURL("https://figma.com/board/abc") != nil)
        for bad in ["http://www.figma.com/board/x", "https://evil.example/figma.com", "https://notfigma.com/x", "https://u:p@www.figma.com/x", "javascript:alert(1)"] {
            #expect(validBoardURL(bad) == nil, "\(bad)")
        }
    }
}

@Suite("Session detail and agent trace")
struct AgentTraceDecodingTests {
    static let detailJSON = #"""
    {"id":"s1","project_id":"p1","status":"analyzing","app":{"name":"Ledger","bundle_id":"com.example.ledger"},
     "started_at":"2026-11-07T20:00:00Z","duration_ms":3000,"network_status":"observed","task":"",
     "counts":{"frames":2,"interactions":1,"network":1},
     "job":{"id":"j1","status":"running","stage":"agent","error":null,"mode":"staged_fallback",
            "usage":{"calls":3,"prompt_tokens":12345,"completion_tokens":678,"estimated":false},
            "stages":[{"name":"agent","label":"Nemotron agent","status":"failed","detail":"fell back to staged pipeline: timeout","updated_at":null}],
            "agent_trace":[
              {"step":2,"tool":"validate_graph","reason":"Check","args":{"draft_id":"d1","nodes":[1,2]},"result_summary":"invalid: 2 problems","ok":true},
              {"step":0,"tool":"list_evidence","reason":"Look first","plan":["List evidence","Draft graph","  "],"args":"{\n  \"kind\": \"frame\" }","result_summary":"12 items"},
              {"step":1,"tool":"","reason":"dropped"},
              {"step":3,"tool":"inspect_frame","args":{},"result_summary":"","ok":false},
              {"step":4,"tool":"validate_graph","args":"x","result_summary":"valid","ok":true,"plan":["Re-plan"]}]},
     "frames":[{"id":"f1","timestamp_ms":0,"filename":"a.jpg","width":1280,"height":800,"image_url":"/v1/sessions/s1/frames/f1"},
               {"id":"f2","timestamp_ms":900,"filename":"b.jpg","width":1280,"height":800}],
     "interactions":[{"id":"i1","timestamp_ms":500,"kind":"click"}],
     "network":[{"id":"n1","timestamp_ms":700,"method":"POST","url":"https://api.example.com/x","status":201}],
     "graph":{"schema_version":1,"nodes":[{"id":"s","type":"screen","label":"Start","evidence_ids":["f1"]}],"edges":[]},
     "corrections":[{"element_id":"s","label":"Home","updated_at":"t","author":"u"}],
     "board_url":"https://www.figma.com/board/abc"}
    """#

    @Test func decodesDetailAndTrace() throws {
        let d = try RemoteCoding.decoder().decode(RemoteSessionDetail.self, from: Data(Self.detailJSON.utf8))
        #expect(d.id == "s1" && d.summary.app.bundleId == "com.example.ledger" && d.summary.isAnalyzing)
        #expect(d.frames.count == 2 && d.lastFrame?.id == "f1" && d.evidenceIds == ["f1", "f2", "i1", "n1"])
        #expect(d.networkStatus == "observed" && d.network[0].status == 201)
        #expect(d.graph?.nodes.first?.evidenceIds == ["f1"] && d.corrections == [RemoteCorrection(elementId: "s", label: "Home")])
        #expect(d.boardUrl == "https://www.figma.com/board/abc")

        let job = try #require(d.job)
        #expect(job.isActive && job.isFallback && job.hasAgentTrace)
        #expect(job.usage?.promptTokens == 12345 && job.usage?.completionTokens == 678)
        #expect(job.agentStage?.detail == "fell back to staged pipeline: timeout")
        #expect(job.agentTrace.map(\.step) == [0, 2, 3, 4], "sorted by step; entries without a tool dropped")
        #expect(job.agentTrace[0].plan == ["List evidence", "Draft graph"] && job.agentTrace[0].ok, "missing ok means success")
        #expect(job.agentTrace[0].args == #"{ "kind": "frame" }"#, "whitespace collapsed")
        #expect(job.agentTrace[1].args == #"{"draft_id":"d1","nodes":[1,2]}"#, "object args keep snake_case keys")
        #expect(job.agentTrace[1].isValidationFailure && !job.agentTrace[3].isValidationFailure)
        #expect(job.agentTrace[2].args == nil && job.agentTrace[2].resultSummary == nil && !job.agentTrace[2].ok)
        #expect(job.plan == ["Re-plan"], "latest plan wins")
        #expect(job.validationFixes == 1)
    }

    @Test func toleratesMinimalPayloads() throws {
        let d = try RemoteCoding.decoder().decode(RemoteSessionDetail.self, from: Data(#"{"id":"s2","job":{"id":"j","status":"succeeded"},"graph":{"nodes":"x"}}"#.utf8))
        #expect(d.summary.app.name == "Unknown app" && d.summary.status == "uploaded" && d.frames.isEmpty)
        #expect(d.job?.agentTrace == [] && d.job?.hasAgentTrace == false && d.graph == nil && d.networkStatus == "not_captured")
        let long = String(repeating: "a", count: 400)
        let step = AgentStep(json: .object(["tool": .string("t"), "args": .string(long)]), index: 7)
        #expect(step?.step == 7 && step?.args?.count == AgentStep.argsMax && step?.args?.hasSuffix("…") == true)
    }

    @Test func decodesDeviceSessionList() throws {
        let json = #"{"project":{"id":"p1","name":"Local workspace","created_at":"t"},"sessions":[{"id":"s1","project_id":"p1","status":"analyzed","app":{"name":"Ledger","bundle_id":null},"started_at":"2026-11-07T20:00:00Z","duration_ms":10}]}"#
        let list = try RemoteCoding.decoder().decode(DeviceSessions.self, from: Data(json.utf8))
        #expect(list.project?.name == "Local workspace" && list.sessions.map(\.id) == ["s1"] && list.sessions[0].app.bundleId == nil)
    }
}

@Suite("Workspace client")
struct WorkspaceClientTests {
    @Test func sendsDeviceTokenToScopedEndpoints() async throws {
        let t = MockTransport([
            .json(200, #"{"sessions":[]}"#),
            .json(200, #"{"job_id":"j2","status":"queued"}"#),
            .json(200, #"{"session_id":"s1","board_url":null}"#),
            .json(200, #"{"schema_version":1}"#),
            .json(200, "PK"),
        ])
        let w = try WorkspaceClient(client: try client(t), credential: credential())
        #expect(try await w.sessions().sessions.isEmpty)
        #expect(try await w.analyze(sessionId: "s1", rerun: true).jobId == "j2")
        #expect(try await w.setBoard(sessionId: "s1", url: nil) == nil)
        _ = try await w.graphExport(sessionId: "s1")
        _ = try await w.specBundle(bundleId: "com.apple.clock")
        #expect(t.requests.map { "\($0.httpMethod!) \($0.url!.absoluteString)" } == [
            "GET http://127.0.0.1:8000/v1/devices/me/sessions",
            "POST http://127.0.0.1:8000/v1/sessions/s1/analyze",
            "PUT http://127.0.0.1:8000/v1/sessions/s1/board",
            "GET http://127.0.0.1:8000/v1/sessions/s1/graph?download=1",
            "GET http://127.0.0.1:8000/v1/projects/proj-1/apps/com.apple.clock/spec-bundle",
        ])
        #expect(t.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token-not-real" })
        #expect(try jsonObject(t.requests[1].httpBody!) as NSDictionary == ["rerun": true])
        #expect(String(decoding: t.requests[2].httpBody!, as: UTF8.self) == #"{"board_url":null}"#)
    }

    @Test func rejectsUnsafeInput() async throws {
        let t = MockTransport([])
        await #expect(throws: UploadError.self) { try WorkspaceClient(client: try client(t), credential: credential(base: "http://localhost:8000")) }
        let w = try WorkspaceClient(client: try client(t), credential: credential())
        await #expect(throws: APIError.self) { try await w.session("../projects") }
        await #expect(throws: APIError.self) { try await w.setBoard(sessionId: "s1", url: "https://evil.example/x") }
        #expect(t.requestCount == 0)
    }
}

@Suite("Screenshot compression")
struct ScreenshotCompressionTests {
    @Test func preservesCaptureCoordinatesAndProducesSmallJPEG() throws {
        let ctx = try #require(CGContext(data: nil, width: 2000, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 2000, height: 1200))
        let image = try #require(ctx.makeImage())
        let data = try #require(ScreenshotCompression.jpeg(image))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 2000 && decoded.height == 1200)
        #expect(data.count < ScreenshotCompression.targetBytes)
    }
}
