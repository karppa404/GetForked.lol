import Foundation
import Testing
@testable import RetraceCore

@Suite("API base URL")
struct BaseURLTests {
    @Test func acceptsLoopbackHTTPAndHTTPS() throws {
        #expect(try APIBaseURL("http://127.0.0.1:8000/").description == "http://127.0.0.1:8000")
        #expect(try APIBaseURL(" http://localhost:8000 ").description == "http://localhost:8000")
        #expect(try APIBaseURL("https://localhost:8000/retrace").endpoint("/v1/sessions").absoluteString == "https://localhost:8000/retrace/v1/sessions")
    }
    @Test func rejectsInsecureOrMalformed() {
        for bad in ["https://api.example.com", "http://10.0.0.5:8000", "ftp://x", "not a url", "https://user:pw@x.com", "https://x.com?token=1", ""] {
            #expect(throws: APIError.self, "\(bad)") { try APIBaseURL(bad) }
        }
    }
}

@Suite("Local connection")
struct LocalConnectionTests {
    @Test func connectSendsDeviceNameAndDecodesCredential() async throws {
        let t = MockTransport([.json(201, #"{"device_token":"rtd_tok","project_id":"proj-9","device_id":"dev-1","api_base_url":"http://evil.example","project_name":"Local workspace"}"#)])
        let cred = try await LocalConnectionService(client: try client(t)).connect(deviceName: "  Lab Mac ")
        #expect(cred.deviceToken == "rtd_tok" && cred.projectId == "proj-9" && cred.deviceName == "Lab Mac")
        #expect(cred.apiBaseURL == "http://127.0.0.1:8000", "credential stays bound to the URL we called")
        #expect(cred.projectName == "Local workspace")
        #expect(!cred.description.contains("rtd_tok"), "description must redact token")
        let req = t.requests[0]
        #expect(req.url?.absoluteString == "http://127.0.0.1:8000/v1/local/connect" && req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil && req.value(forHTTPHeaderField: "Origin") == nil)
        #expect(try jsonObject(req.httpBody!) as NSDictionary == ["device_name": "Lab Mac"])
    }

    @Test func optionalFieldsMayBeAbsent() async throws {
        let t = MockTransport([.json(201, #"{"device_token":"rtd_tok","project_id":"proj-9","device_id":"dev-1"}"#)])
        let cred = try await LocalConnectionService(client: try client(t)).connect(deviceName: "M")
        #expect(cred.projectName == nil)
    }

    @Test func rejectsBadResponsesAndIsNotRetried() async throws {
        for body in [#"{"device_token":"","project_id":"p","device_id":"d"}"#, #"{"project_id":"p"}"#, #"{"device_token":"t","project_id":"../x","device_id":"d"}"#] {
            let t = MockTransport([.json(201, body)])
            await #expect(throws: APIError.self, "\(body)") { try await LocalConnectionService(client: try client(t)).connect(deviceName: "M") }
        }
        let t = MockTransport([.json(503, "{}"), .json(201, "{}")])
        await #expect(throws: APIError.self) { try await LocalConnectionService(client: try client(t)).connect(deviceName: "M") }
        #expect(t.requestCount == 1)
        let forbidden = MockTransport([.json(403, #"{"error":"local_connect_loopback_only"}"#)])
        await #expect(throws: APIError.http(status: 403, detail: "local_connect_loopback_only")) {
            try await LocalConnectionService(client: try client(forbidden)).connect(deviceName: "M")
        }
    }

    @Test func refusesNonLoopbackServer() async throws {
        let t = MockTransport([])
        await #expect(throws: APIError.self) {
            try await LocalConnectionService(client: try client(t, base: "https://api.example.com")).connect(deviceName: "M")
        }
        #expect(t.requestCount == 0)
        await #expect(throws: APIError.self) { try await LocalConnectionService(client: try client(t)).connect(deviceName: "  ") }
    }

    @Test func legacyKeychainCredentialStillDecodes() throws {
        let json = #"{"deviceToken":"t","projectId":"p","apiBaseURL":"http://127.0.0.1:8000","deviceName":"M","pairedAt":"2026-11-07T00:00:00.000Z"}"#
        #expect(try JSONDecoder().decode(DeviceCredential.self, from: Data(json.utf8)).projectName == nil)
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
