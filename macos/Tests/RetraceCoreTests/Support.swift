import Foundation
@testable import RetraceCore

/// Scripted HTTP transport; records requests. No real network is used in tests.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    enum Reply { case json(Int, String); case failure(Error) }
    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    var requestCount: Int { lock.withLock { requests.count } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply = lock.withLock {
            requests.append(request)
            return replies.isEmpty ? .json(500, "{\"detail\":\"script exhausted\"}") : replies.removeFirst()
        }
        switch reply {
        case .failure(let e): throw e
        case .json(let status, let body):
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            return (Data(body.utf8), resp)
        }
    }
}

let noSleep: Sleeper = { _ in }

func fixtureDirectory() -> URL {
    Bundle.module.resourceURL!.appendingPathComponent("Fixtures/synthetic-session", isDirectory: true)
}

func loadFixture() throws -> LocalSession { try SessionStore.load(directory: fixtureDirectory()) }

func jsonObject(_ data: Data) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: data) as! [String: Any]
}

func client(_ t: MockTransport, base: String = "http://127.0.0.1:8000") throws -> APIClient {
    APIClient(baseURL: try APIBaseURL(base), transport: t)
}

func credential(base: String = "http://127.0.0.1:8000") -> DeviceCredential {
    DeviceCredential(deviceToken: "test-token-not-real", projectId: "proj-1", apiBaseURL: base, deviceName: "Test Mac", pairedAt: "2026-11-07T00:00:00.000Z")
}
