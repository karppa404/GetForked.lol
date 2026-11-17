import Foundation
import Testing
@testable import RetraceCore

private func detail(_ id: String, status: String = "analyzed", jobStatus: String? = nil, graph: RemoteGraph? = nil,
                    corrections: [RemoteCorrection] = [], frames: [RemoteFrame] = [], interactions: [RemoteEvidenceRef] = [],
                    network: [RemoteNetworkEvent] = []) throws -> RemoteSessionDetail {
    var d = RemoteSessionDetail(summary: RemoteSessionSummary(id: id, app: RemoteApp(name: "Ledger"), startedAt: "2026-11-07T10:00:00Z", status: status),
                                frames: frames, interactions: interactions, network: network, graph: graph, corrections: corrections)
    if let jobStatus {
        d.job = try JSONDecoder().decode(RemoteJob.self, from: Data(#"{"id":"j1","status":"\#(jobStatus)"}"#.utf8))
    }
    return d
}

private func summary(_ id: String, status: String) -> RemoteSessionSummary {
    RemoteSessionSummary(id: id, app: RemoteApp(name: "Ledger"), startedAt: "2026-11-07T10:00:00Z", status: status)
}

@Suite("Workspace store generations")
struct WorkspaceStoreTests {
    @Test func dropsResultsStartedBeforeACredentialChange() throws {
        var s = WorkspaceStore()
        let gen = s.generation
        let ticket = s.issueDetailRequest("s1")
        s.reset() // disconnect or switch servers mid-request
        #expect(s.setSessions([summary("s1", status: "analyzing")], project: "Old", generation: gen) == .stale)
        #expect(s.setDetail(try detail("s1", jobStatus: "running"), ticket: ticket) == .stale)
        #expect(s.setDetailError("boom", ticket: ticket) == .stale)
        #expect(s.remote.isEmpty && s.details.isEmpty && s.detailErrors.isEmpty && s.projectName == nil)
        #expect(!s.needsPolling, "an old active job never keeps polling alive after reconnect")

        let fresh = s.issueDetailRequest("s1")
        #expect(s.setDetail(try detail("s1"), ticket: fresh) == .changed)
        #expect(s.setSessions([summary("s1", status: "analyzed")], project: "New", generation: s.generation) == .changed)
        #expect(s.projectName == "New" && !s.needsPolling)
    }

    @Test func needsPollingFollowsCurrentData() throws {
        var s = WorkspaceStore()
        s.setSessions([summary("a", status: "queued"), summary("b", status: "analyzed")], project: nil, generation: s.generation)
        #expect(s.needsPolling && s.runningIds == ["a"])
        s.setDetail(try detail("b", jobStatus: "running"), ticket: s.issueDetailRequest("b"))
        #expect(s.runningIds == ["a", "b"])
        s.reset()
        #expect(!s.needsPolling && s.runningIds.isEmpty)
    }

    @Test func olderResponsesNeverOverwriteNewerOnes() throws {
        var s = WorkspaceStore()
        let first = s.issueDetailRequest("s1"), second = s.issueDetailRequest("s1")
        #expect(s.setDetail(try detail("s1", status: "analyzed"), ticket: second) == .changed)
        #expect(s.setDetail(try detail("s1", status: "analyzing"), ticket: first) == .stale)
        #expect(s.details["s1"]?.summary.status == "analyzed")
        #expect(s.setDetail(try detail("s1"), ticket: s.issueDetailRequest("s1")) == .unchanged)
        #expect(s.setDetail(try detail("s2"), ticket: s.issueDetailRequest("s1")) == .stale, "ticket must match the session")
    }

    @Test func errorsOnlyForSessionsThatNeverLoaded() throws {
        var s = WorkspaceStore()
        #expect(s.setDetailError("Not found", ticket: s.issueDetailRequest("x")) == .changed)
        #expect(s.detailErrors["x"] == "Not found")
        s.setDetail(try detail("y"), ticket: s.issueDetailRequest("y"))
        #expect(s.setDetailError("offline", ticket: s.issueDetailRequest("y")) == .unchanged)
        #expect(s.detailErrors["y"] == nil && s.details["y"] != nil)
        #expect(s.setDetail(try detail("x"), ticket: s.issueDetailRequest("x")) == .changed)
        #expect(s.detailErrors["x"] == nil)
    }

    @Test func localEditsDropInFlightResponses() throws {
        var s = WorkspaceStore()
        s.setDetail(try detail("s1"), ticket: s.issueDetailRequest("s1"))
        let inFlight = s.issueDetailRequest("s1") // e.g. a poll started before the edit
        #expect(s.updateDetail("s1", generation: s.generation) { $0 = $0.settingCorrection("screen:f1", label: "Inbox") } == .changed)
        #expect(s.setDetail(try detail("s1"), ticket: inFlight) == .stale, "pre-edit data must not undo the optimistic label")
        #expect(s.details["s1"]?.correction("screen:f1")?.label == "Inbox")
        let gen = s.generation
        s.reset()
        #expect(s.updateDetail("s1", generation: gen) { _ in } == .stale)
    }
}

@Suite("Graph label corrections")
struct GraphLabelTests {
    let graph = RemoteGraph(nodes: [
        GraphNode(id: "screen:f2", type: "screen", label: "Settings", evidenceIds: ["f2"]),
        GraphNode(id: "api_call:n1", type: "api_call", label: "GET /invoices", evidenceIds: ["n1"]),
        GraphNode(id: "screen:f1", type: "screen", label: "Inbox", evidenceIds: ["f1"]),
        GraphNode(id: "action:i1", type: "action", label: "Click gear", evidenceIds: ["i1", "f2"]),
        GraphNode(id: "screen:fx", type: "screen", label: "Unknown time", evidenceIds: ["missing"]),
    ], edges: [GraphEdge(id: "edge:abc", source: "screen:f1", target: "screen:f2")])

    func sample(_ corrections: [RemoteCorrection] = []) throws -> RemoteSessionDetail {
        try detail("s1", graph: graph, corrections: corrections,
                   frames: [RemoteFrame(id: "f1", timestampMs: 100), RemoteFrame(id: "f2", timestampMs: 900)],
                   interactions: [RemoteEvidenceRef(id: "i1", timestampMs: 500)],
                   network: [RemoteNetworkEvent(id: "n1", timestampMs: 950, url: "https://x/invoices")])
    }

    @Test func groupsByTypeInStepOrder() throws {
        let sections = GraphLabels.sections(try sample())
        #expect(sections.map(\.type) == ["screen", "action", "api_call"])
        #expect(sections[0].items.map(\.id) == ["screen:f1", "screen:f2", "screen:fx"], "by earliest evidence; unknown times last")
        #expect(sections[1].items.map(\.label) == ["Click gear"])
        #expect(sections.flatMap(\.items).allSatisfy { !$0.corrected })
        #expect(GraphLabels.sections(try detail("none")).isEmpty)
    }

    @Test func appliesCorrectionsToTheDisplayedList() throws {
        var d = try sample([RemoteCorrection(elementId: "screen:f1", label: "Mail inbox")])
        var inbox = GraphLabels.sections(d)[0].items[0]
        #expect(inbox.label == "Mail inbox" && inbox.agentLabel == "Inbox" && inbox.corrected)

        d = d.settingCorrection("action:i1", label: "Open settings").settingCorrection("screen:f1", label: "Inbox (all)")
        let sections = GraphLabels.sections(d)
        inbox = sections[0].items[0]
        #expect(inbox.label == "Inbox (all)" && d.corrections.filter { $0.elementId == "screen:f1" }.count == 1)
        #expect(sections[1].items[0].label == "Open settings" && sections[1].items[0].corrected)

        d = d.settingCorrection("screen:f1", label: nil)
        inbox = GraphLabels.sections(d)[0].items[0]
        #expect(inbox.label == "Inbox" && !inbox.corrected, "revert shows the agent label again")
        #expect(d.graph!.applying(d.corrections).nodes.first { $0.id == "action:i1" }?.label == "Open settings")
    }

    @Test func cleansLabelsLikeTheBackend() {
        #expect(GraphLabels.clean("  Sign \n in\t page ") == "Sign in page")
        #expect(GraphLabels.clean("a\u{0007}b") == "ab")
        #expect(GraphLabels.clean("   ") == nil)
        #expect(GraphLabels.clean(String(repeating: "x", count: 301)) == nil)
        #expect(GraphLabels.clean(String(repeating: "x", count: 300)) != nil)
    }

    @Test func decodesInteractionTimestamps() throws {
        let d = try JSONDecoder().decode(RemoteSessionDetail.self, from: Data(#"{"id":"s","interactions":[{"id":"i1","timestamp_ms":42},{"id":"i2"}]}"#.utf8))
        #expect(d.interactions == [RemoteEvidenceRef(id: "i1", timestampMs: 42), RemoteEvidenceRef(id: "i2")])
    }
}

@Suite("Correction requests")
struct CorrectionRequestTests {
    @Test func putSendsTheCleanedLabelWithTheDeviceToken() async throws {
        let t = MockTransport([.json(200, #"{"element_id":"screen:frame_1","label":"Mail inbox","updated_at":"2026-11-07T00:00:00Z","author":null}"#)])
        let w = try WorkspaceClient(client: try client(t), credential: credential())
        let saved = try await w.putCorrection(sessionId: "s-1", elementId: "screen:frame_1", label: "  Mail\n inbox ")
        #expect(saved == RemoteCorrection(elementId: "screen:frame_1", label: "Mail inbox"))
        let r = t.requests[0]
        #expect(r.httpMethod == "PUT")
        #expect(r.url?.absoluteString == "http://127.0.0.1:8000/v1/sessions/s-1/corrections/screen:frame_1")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer test-token-not-real")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try jsonObject(r.httpBody!) as NSDictionary == ["label": "Mail inbox"])
    }

    @Test func deleteRevertsAndEncodesEdgeIds() async throws {
        let t = MockTransport([.json(204, "")])
        let w = try WorkspaceClient(client: try client(t), credential: credential())
        try await w.deleteCorrection(sessionId: "s-1", elementId: "edge:a>b")
        #expect(t.requests[0].httpMethod == "DELETE")
        #expect(t.requests[0].url?.absoluteString == "http://127.0.0.1:8000/v1/sessions/s-1/corrections/edge:a%3Eb")
        #expect(t.requests[0].httpBody == nil)
    }

    @Test func rejectsBadInputBeforeSending() async throws {
        let t = MockTransport([])
        let w = try WorkspaceClient(client: try client(t), credential: credential())
        await #expect(throws: APIError.self) { try await w.putCorrection(sessionId: "s-1", elementId: "screen:f1", label: " \n ") }
        await #expect(throws: APIError.self) { try await w.putCorrection(sessionId: "s-1", elementId: "../graph", label: "x") }
        await #expect(throws: APIError.self) { try await w.deleteCorrection(sessionId: "s/1", elementId: "screen:f1") }
        #expect(t.requestCount == 0)
    }

    @Test func surfacesServerRefusals() async throws {
        let t = MockTransport([.json(404, #"{"detail":"unknown_element"}"#)])
        let w = try WorkspaceClient(client: try client(t), credential: credential())
        await #expect(throws: APIError.http(status: 404, detail: "unknown_element")) {
            try await w.putCorrection(sessionId: "s-1", elementId: "screen:f9", label: "x")
        }
    }
}
