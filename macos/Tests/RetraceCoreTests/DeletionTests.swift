import Foundation
import Testing
@testable import RetraceCore

@Suite("Deleting recordings")
struct DeletionTests {
    @Test func deleteSessionSendsDeviceScopedDelete() async throws {
        let t = MockTransport([.json(204, ""), .json(404, #"{"error":"not_found"}"#), .json(409, #"{"error":"analysis_in_progress"}"#)])
        let w = try WorkspaceClient(client: try client(t), credential: credential())
        try await w.deleteSession("s1")
        try await w.deleteSession("s2") // already gone counts as deleted
        await #expect(throws: APIError.http(status: 409, detail: "analysis_in_progress")) { try await w.deleteSession("s3") }
        await #expect(throws: APIError.self) { try await w.deleteSession("../projects") }
        #expect(t.requests.map { "\($0.httpMethod!) \($0.url!.absoluteString)" } == [
            "DELETE http://127.0.0.1:8000/v1/sessions/s1",
            "DELETE http://127.0.0.1:8000/v1/sessions/s2",
            "DELETE http://127.0.0.1:8000/v1/sessions/s3",
        ])
        #expect(t.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token-not-real" })
    }

    @Test func sessionStoreDeletesOnlyThatSessionsFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retrace-delete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)
        let gone = UUID().uuidString, kept = UUID().uuidString
        for id in [gone, kept] {
            let dir = try store.createSessionDirectory(id: id)
            try Data("x".utf8).write(to: dir.appendingPathComponent("frames/f.jpg"))
        }
        try store.delete(id: gone)
        #expect(!FileManager.default.fileExists(atPath: store.directory(for: gone).path))
        #expect(FileManager.default.fileExists(atPath: store.directory(for: kept).appendingPathComponent("frames/f.jpg").path))
        try store.delete(id: gone) // already gone is fine
        #expect(throws: SessionStoreError.self) { try store.delete(id: "..") }
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func workspaceStoreForgetsDeletedSessions() throws {
        var s = WorkspaceStore()
        let summaries = ["a", "b"].map { RemoteSessionSummary(id: $0, app: RemoteApp(name: "Ledger"), startedAt: "2026-11-07T10:00:00Z", status: "analyzed") }
        s.setSessions(summaries, project: "Local workspace", generation: s.generation)
        s.setDetail(RemoteSessionDetail(summary: summaries[0]), ticket: s.issueDetailRequest("a"))
        let inFlight = s.issueDetailRequest("a")
        #expect(s.removeSessions(["a"], generation: s.generation - 1) == .stale)
        #expect(s.removeSessions(["a"], generation: s.generation) == .changed)
        #expect(s.remote.map(\.id) == ["b"] && s.details["a"] == nil)
        #expect(s.setDetail(RemoteSessionDetail(summary: summaries[0]), ticket: inFlight) == .stale, "a response in flight must not bring it back")
        #expect(s.removeSessions(["a"], generation: s.generation) == .unchanged)
    }
}
