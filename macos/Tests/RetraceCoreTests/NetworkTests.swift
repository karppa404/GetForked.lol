import Foundation
import Testing
@testable import RetraceCore

@Suite("API base URL")
struct BaseURLTests {
    @Test func acceptsLoopbackHTTPAndHTTPS() throws {
        #expect(try APIBaseURL("http://127.0.0.1:8000/").description == "http://127.0.0.1:8000")
        #expect(try APIBaseURL(" http://localhost:8000 ").description == "http://localhost:8000")
        #expect(try APIBaseURL("https://api.example.com/retrace").endpoint("/v1/sessions").absoluteString == "https://api.example.com/retrace/v1/sessions")
    }
    @Test func rejectsInsecureOrMalformed() {
        for bad in ["http://10.0.0.5:8000", "ftp://x", "not a url", "https://user:pw@x.com", "https://x.com?token=1", ""] {
            #expect(throws: APIError.self, "\(bad)") { try APIBaseURL(bad) }
        }
    }
}

@Suite("Pairing")
struct PairingTests {
    @Test func cancellationDuringPollDoesNotAcceptDeviceCredential() async throws {
        struct CancellingTransport: HTTPTransport {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                withUnsafeCurrentTask { $0?.cancel() }
                let body = Data(#"{"status":"approved","device_token":"never-store-this","project_id":"proj-1"}"#.utf8)
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let service = PairingService(client: APIClient(baseURL: try APIBaseURL(APIBaseURL.development), transport: CancellingTransport()))
        let task = Task {
            await service.waitForApproval(claim: ClaimResponse(claimId: "c-1", claimSecret: "s", status: "pending"), deviceName: "Mac", sleep: noSleep)
        }
        #expect(await task.value == .cancelled)
    }

    @Test func claimSendsCodeAndDeviceNameOnly() async throws {
        let t = MockTransport([.json(200, #"{"claim_id":"c-1","claim_secret":"s3cret","status":"pending"}"#)])
        let resp = try await PairingService(client: try client(t)).claim(code: "  ABCD-1234 ", deviceName: "Lab Mac")
        #expect(resp == ClaimResponse(claimId: "c-1", claimSecret: "s3cret", status: "pending"))
        let req = t.requests[0]
        #expect(req.url?.path == "/v1/pairings/claim" && req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try jsonObject(req.httpBody!)
        #expect(body as NSDictionary == ["code": "ABCD-1234", "device_name": "Lab Mac"])
    }

    @Test func claimIsNotRetried() async throws {
        let t = MockTransport([.json(503, "{}"), .json(200, "{}")])
        await #expect(throws: APIError.self) { try await PairingService(client: try client(t)).claim(code: "X", deviceName: "M") }
        #expect(t.requestCount == 1, "single-use code must not be resent automatically")
    }

    @Test func pollsPendingThenApproved() async throws {
        let t = MockTransport([
            .json(200, #"{"status":"pending"}"#),
            .json(503, "{}"),
            .json(200, #"{"status":"pending"}"#),
            .json(200, #"{"status":"approved","device_token":"tok-XYZ","project_id":"proj-9"}"#),
        ])
        let svc = PairingService(client: try client(t))
        let claim = ClaimResponse(claimId: "c-1", claimSecret: "s3cret", status: "pending")
        let outcome = await svc.waitForApproval(claim: claim, deviceName: "Lab Mac", sleep: noSleep)
        guard case .approved(let cred) = outcome else { Issue.record("expected approval, got \(outcome)"); return }
        #expect(cred.deviceToken == "tok-XYZ" && cred.projectId == "proj-9" && cred.apiBaseURL == "http://127.0.0.1:8000")
        #expect(!cred.description.contains("tok-XYZ"), "description must redact token")
        #expect(t.requestCount == 4)
        #expect(t.requests[0].url?.path == "/v1/pairings/claims/c-1/poll")
        #expect(try jsonObject(t.requests[0].httpBody!) as NSDictionary == ["claim_secret": "s3cret"])
    }

    @Test func expiryAndRejectionAreTerminal() async throws {
        let claim = ClaimResponse(claimId: "c-1", claimSecret: "s", status: "pending")
        let gone = MockTransport([.json(410, #"{"detail":"expired"}"#)])
        #expect(await PairingService(client: try client(gone)).waitForApproval(claim: claim, deviceName: "M", sleep: noSleep) == .expired)
        let denied = MockTransport([.json(403, "{}")])
        if case .rejected = await PairingService(client: try client(denied)).waitForApproval(claim: claim, deviceName: "M", sleep: noSleep) {} else { Issue.record("expected rejection") }
        let bad = MockTransport([.json(200, #"{"status":"approved"}"#)])
        if case .failed = await PairingService(client: try client(bad)).waitForApproval(claim: claim, deviceName: "M", sleep: noSleep) {} else { Issue.record("approval without token must fail") }
    }

    @Test func transientErrorsAreBounded() async throws {
        let t = MockTransport(Array(repeating: .failure(URLError(.notConnectedToInternet)), count: 50))
        let policy = PollPolicy(interval: .milliseconds(1), maxWait: .seconds(600), maxConsecutiveErrors: 3)
        let outcome = await PairingService(client: try client(t)).waitForApproval(
            claim: ClaimResponse(claimId: "c", claimSecret: "s", status: "pending"), deviceName: "M", policy: policy, sleep: noSleep)
        if case .failed = outcome {} else { Issue.record("expected failure, got \(outcome)") }
        #expect(t.requestCount == 3)
    }

    @Test func waitHonoursDeadline() async throws {
        let t = MockTransport(Array(repeating: .json(200, #"{"status":"pending"}"#), count: 100))
        let start = ContinuousClock.now
        final class Ticker: @unchecked Sendable { var n = 0 }
        let ticker = Ticker()
        let fakeClock: @Sendable () -> ContinuousClock.Instant = { ticker.n += 1; return start + .seconds(ticker.n) }
        let outcome = await PairingService(client: try client(t)).waitForApproval(
            claim: ClaimResponse(claimId: "c", claimSecret: "s", status: "pending"), deviceName: "M",
            policy: PollPolicy(interval: .seconds(1), maxWait: .seconds(5)), sleep: noSleep, clock: fakeClock)
        #expect(outcome == .expired)
        #expect(t.requestCount < 10)
    }

    @Test func credentialStoreIsKeyedByServer() throws {
        let store = InMemoryCredentialStore()
        try store.save(credential())
        #expect(try store.load(apiBaseURL: "http://127.0.0.1:8000") != nil)
        #expect(try store.load(apiBaseURL: "https://other.example.com") == nil)
        try store.delete(apiBaseURL: "http://127.0.0.1:8000")
        #expect(try store.load(apiBaseURL: "http://127.0.0.1:8000") == nil)
    }
}

@Suite("Upload")
struct UploadTests {
    func reviewedFixture() throws -> (SessionManifest, [(filename: String, data: Data)]) {
        let s = try loadFixture()
        let m = try ReviewApplier.apply(ReviewState(omittedFrameIds: [s.manifest.frames[2].id], confirmedAt: "2026-11-07T15:10:00.000Z"), to: s.manifest, projectId: "proj-1")
        return (m, try SessionStore.frameFiles(for: m, in: s.directory))
    }

    @Test func multipartContainsManifestAndOnlyKeptFiles() async throws {
        let (m, files) = try reviewedFixture()
        let t = MockTransport([.json(201, #"{"id":"\#(m.id)","status":"uploaded"}"#)])
        let resp = try await SessionUploader(client: try client(t), sleep: noSleep).upload(manifest: m, files: files, credential: credential())
        #expect(resp.status == "uploaded")
        let req = t.requests[0]
        #expect(req.url?.path == "/v1/sessions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer test-token-not-real")
        let ct = try #require(req.value(forHTTPHeaderField: "Content-Type"))
        #expect(ct.hasPrefix("multipart/form-data; boundary="))
        let body = String(decoding: req.httpBody!, as: UTF8.self)
        #expect(body.contains(#"name="manifest""#))
        #expect(body.components(separatedBy: #"name="files"; filename="#).count - 1 == 2)
        #expect(!body.contains("c4e5f6a7-1b2c-4d3e-9f0a-3c4d5e6f7a83.png"), "omitted frame must not be uploaded")
        #expect(!body.contains("test-token-not-real"), "token must never be in the body")
        #expect(body.contains(#""reviewed":true"#))
    }

    @Test func refusesUnreviewedOrMismatchedCredential() throws {
        let s = try loadFixture()
        let up = SessionUploader(client: try client(MockTransport([])), sleep: noSleep)
        var unreviewed = s.manifest
        unreviewed.projectId = "proj-1"
        #expect(throws: ReviewError.self) { try up.makeUploadRequest(manifest: unreviewed, files: [], credential: credential()) }
        let (m, files) = try reviewedFixture()
        #expect(throws: UploadError.self) { try up.makeUploadRequest(manifest: m, files: files, credential: credential(base: "https://evil.example.com")) }
        var wrongProject = m
        wrongProject.projectId = "other-project"
        #expect(throws: UploadError.self) { try up.makeUploadRequest(manifest: wrongProject, files: files, credential: credential()) }
        #expect(throws: APIError.self) { try up.makeUploadRequest(manifest: m, files: Array(files.prefix(1)), credential: credential()) }
    }

    @Test func retriesTransientThenStops() async throws {
        let (m, files) = try reviewedFixture()
        let t = MockTransport([.json(503, "{}"), .json(503, "{}"), .json(503, "{}"), .json(201, "{}")])
        await #expect(throws: APIError.http(status: 503, detail: nil)) {
            try await SessionUploader(client: try client(t), retry: RetryPolicy(maxAttempts: 3), sleep: noSleep).upload(manifest: m, files: files, credential: credential())
        }
        #expect(t.requestCount == 3)
        let auth = MockTransport([.json(401, #"{"detail":"bad token"}"#)])
        await #expect(throws: APIError.http(status: 401, detail: "bad token")) {
            try await SessionUploader(client: try client(auth), sleep: noSleep).upload(manifest: m, files: files, credential: credential())
        }
        #expect(auth.requestCount == 1, "4xx is never retried")
    }

    @Test func analyzeIsSeparateCall() async throws {
        let t = MockTransport([.json(202, #"{"job_id":"job-1","status":"queued"}"#)])
        let r = try await SessionUploader(client: try client(t), sleep: noSleep).analyze(sessionId: "0b6f3c1e-8d2a-4f5b-9c7d-1e2f3a4b5c6d", credential: credential())
        #expect(r == AnalyzeResponse(jobId: "job-1", status: "queued"))
        #expect(t.requests[0].url?.path == "/v1/sessions/0b6f3c1e-8d2a-4f5b-9c7d-1e2f3a4b5c6d/analyze")
        await #expect(throws: APIError.self) {
            try await SessionUploader(client: try client(MockTransport([])), sleep: noSleep).analyze(sessionId: "../admin", credential: credential())
        }
    }
}
