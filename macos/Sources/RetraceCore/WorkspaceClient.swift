import Foundation

/// Reads and acts on this Mac's own project with its device credential. The server scopes every
/// call to the device's project (backend/README.md); anything else is 404.
public struct WorkspaceClient: Sendable {
    public let client: APIClient
    public let credential: DeviceCredential

    public init(client: APIClient, credential: DeviceCredential) throws {
        guard credential.apiBaseURL == client.baseURL.description else { throw UploadError.credentialMismatch }
        self.client = client
        self.credential = credential
    }

    private func get(_ path: String) -> URLRequest { client.request("GET", path, bearer: credential.deviceToken) }

    /// `GET /v1/devices/me/sessions`, newest first.
    public func sessions() async throws -> DeviceSessions {
        try await client.perform(get("/v1/devices/me/sessions"), as: DeviceSessions.self, decoder: RemoteCoding.decoder())
    }

    public func session(_ id: String) async throws -> RemoteSessionDetail {
        let id = try APIClient.pathComponent(id)
        return try await client.perform(get("/v1/sessions/\(id)"), as: RemoteSessionDetail.self, decoder: RemoteCoding.decoder())
    }

    /// Frame image bytes. Built from ids, never from a server-supplied URL, so the token stays on this API.
    public func frame(sessionId: String, frameId: String) async throws -> Data {
        let sid = try APIClient.pathComponent(sessionId), fid = try APIClient.pathComponent(frameId)
        var r = get("/v1/sessions/\(sid)/frames/\(fid)")
        r.setValue("image/*", forHTTPHeaderField: "Accept")
        return try await client.performData(r)
    }

    /// The graph download the FigJam plugin imports (corrections applied).
    public func graphExport(sessionId: String) async throws -> Data {
        let sid = try APIClient.pathComponent(sessionId)
        return try await client.performData(get("/v1/sessions/\(sid)/graph?download=1"))
    }

    /// Zip of the clone spec bundle (AGENTS.md, Spec Kit spec, OpenAPI/Arazzo contracts, Playwright evals)
    /// built from every analysed recording of one app in this Mac's project.
    public func specBundle(bundleId: String) async throws -> Data {
        let pid = try APIClient.pathComponent(credential.projectId), bid = try APIClient.pathComponent(bundleId)
        var r = get("/v1/projects/\(pid)/apps/\(bid)/spec-bundle")
        r.setValue("application/zip", forHTTPHeaderField: "Accept")
        return try await client.performData(r)
    }

    /// `rerun` starts a new job even when a finished one exists; in-flight jobs are always reused.
    public func analyze(sessionId: String, rerun: Bool) async throws -> AnalyzeResponse {
        let sid = try APIClient.pathComponent(sessionId)
        var r = client.request("POST", "/v1/sessions/\(sid)/analyze", bearer: credential.deviceToken)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data((rerun ? #"{"rerun":true}"# : "{}").utf8)
        return try await client.perform(r, as: AnalyzeResponse.self)
    }

    /// `DELETE /v1/sessions/{id}`: the session and everything derived from it. Already gone (404) counts
    /// as deleted; 409 `analysis_in_progress` means a job for it is still queued or running.
    public func deleteSession(_ id: String) async throws {
        let sid = try APIClient.pathComponent(id)
        do { _ = try await client.performData(client.request("DELETE", "/v1/sessions/\(sid)", bearer: credential.deviceToken)) }
        catch APIError.http(404, _) {}
    }

    /// Saves (or with nil clears) the FigJam board link on one session.
    public func setBoard(sessionId: String, url: String?) async throws -> String? {
        struct Body: Encodable {
            let boardUrl: String?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(boardUrl, forKey: .boardUrl) // explicit null clears
            }
            enum CodingKeys: String, CodingKey { case boardUrl = "board_url" }
        }
        struct Reply: Decodable { let boardUrl: String?; enum CodingKeys: String, CodingKey { case boardUrl = "board_url" } }
        if let url, validBoardURL(url) == nil { throw APIError.invalidInput("Enter an https://www.figma.com/… link to your FigJam board.") }
        let sid = try APIClient.pathComponent(sessionId)
        var r = client.request("PUT", "/v1/sessions/\(sid)/board", bearer: credential.deviceToken)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(Body(boardUrl: url))
        return try await client.perform(r, as: Reply.self, decoder: RemoteCoding.decoder()).boardUrl
    }

    /// `PUT /v1/sessions/{id}/corrections/{element_id}` with `{"label": …}`: a human label over the agent's.
    public func putCorrection(sessionId: String, elementId: String, label: String) async throws -> RemoteCorrection {
        guard let clean = GraphLabels.clean(label) else {
            throw APIError.invalidInput("Enter a label of 1–\(GraphLabels.maxLabel) characters.")
        }
        var r = try correctionRequest("PUT", sessionId: sessionId, elementId: elementId)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(["label": clean])
        return try await client.perform(r, as: RemoteCorrection.self, decoder: RemoteCoding.decoder())
    }

    /// `DELETE /v1/sessions/{id}/corrections/{element_id}`: back to the agent's label.
    public func deleteCorrection(sessionId: String, elementId: String) async throws {
        _ = try await client.performData(try correctionRequest("DELETE", sessionId: sessionId, elementId: elementId))
    }

    func correctionRequest(_ method: String, sessionId: String, elementId: String) throws -> URLRequest {
        let sid = try APIClient.pathComponent(sessionId)
        guard GraphLabels.isValidElementId(elementId) else { throw APIError.invalidInput("Unsafe graph element id from server") }
        // Ids look like `screen:frame_1` or `edge:a>b`; `>` is not allowed raw in a URL path.
        let eid = elementId.addingPercentEncoding(withAllowedCharacters: Self.elementIdAllowed)!
        return client.request(method, "/v1/sessions/\(sid)/corrections/\(eid)", bearer: credential.deviceToken)
    }

    static let elementIdAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:_-")
}
