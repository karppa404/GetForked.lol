import Foundation

public struct UploadResponse: Codable, Equatable, Sendable { public var id: String; public var status: String }
public struct AnalyzeResponse: Codable, Equatable, Sendable { public var jobId: String; public var status: String }

public struct MultipartBody: Sendable {
    public let boundary: String
    public private(set) var data = Data()

    public init(boundary: String = "RetraceBoundary-\(UUID().uuidString)") { self.boundary = boundary }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func addField(name: String, value: String) {
        data.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        data.append(value)
        data.append("\r\n")
    }

    public mutating func addFile(name: String, filename: String, contentType: String, content: Data) {
        data.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n")
        data.append(content)
        data.append("\r\n")
    }

    public func finalized() -> Data {
        var d = data
        d.append("--\(boundary)--\r\n")
        return d
    }
}

private extension Data {
    mutating func append(_ s: String) { append(Data(s.utf8)) }
}

public enum UploadError: Error, CustomStringConvertible {
    case credentialMismatch
    case projectMismatch
    public var description: String {
        switch self {
        case .credentialMismatch: return "This Mac's credential was issued by a different server. Connect again for this API URL."
        case .projectMismatch: return "This recording belongs to a different project than this Mac's device credential."
        }
    }
}

/// Uploads a reviewed, redacted manifest and its frame files. Call only from an explicit
/// user action; this type never schedules uploads on its own.
public struct SessionUploader: Sendable {
    public let client: APIClient
    public let retry: RetryPolicy
    public let sleep: Sleeper

    public init(client: APIClient, retry: RetryPolicy = RetryPolicy(), sleep: @escaping Sleeper = realSleeper) {
        self.client = client
        self.retry = retry
        self.sleep = sleep
    }

    public static func mimeType(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        default: return "application/octet-stream"
        }
    }

    public func makeUploadRequest(manifest: SessionManifest, files: [(filename: String, data: Data)], credential: DeviceCredential) throws -> URLRequest {
        guard credential.apiBaseURL == client.baseURL.description else { throw UploadError.credentialMismatch }
        guard manifest.projectId == credential.projectId else { throw UploadError.projectMismatch }
        let issues = ManifestValidator.validate(manifest, purpose: .upload)
        guard issues.isEmpty else { throw ReviewError.invalid(issues) }
        let referenced = Set(manifest.frames.map(\.filename))
        guard Set(files.map(\.filename)) == referenced, files.count == referenced.count else {
            throw APIError.invalidInput("Attached files do not match manifest frames.")
        }
        var body = MultipartBody()
        let json = try ManifestCoding.encoder().encode(manifest)
        body.addField(name: "manifest", value: String(decoding: json, as: UTF8.self))
        for f in files {
            body.addFile(name: "files", filename: f.filename, contentType: Self.mimeType(for: f.filename), content: f.data)
        }
        var r = client.request("POST", "/v1/sessions", bearer: credential.deviceToken)
        r.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        r.httpBody = body.finalized()
        r.timeoutInterval = 300
        return r
    }

    public func upload(manifest: SessionManifest, files: [(filename: String, data: Data)], credential: DeviceCredential) async throws -> UploadResponse {
        let request = try makeUploadRequest(manifest: manifest, files: files, credential: credential)
        let client = self.client
        let resp = try await withBoundedRetry(retry, sleep: sleep) {
            try await client.perform(request, as: UploadResponse.self)
        }
        _ = try APIClient.pathComponent(resp.id)
        return resp
    }

    public func analyze(sessionId: String, credential: DeviceCredential) async throws -> AnalyzeResponse {
        guard credential.apiBaseURL == client.baseURL.description else { throw UploadError.credentialMismatch }
        let id = try APIClient.pathComponent(sessionId)
        var r = client.request("POST", "/v1/sessions/\(id)/analyze", bearer: credential.deviceToken)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data("{}".utf8)
        let client = self.client
        let request = r
        return try await withBoundedRetry(retry, sleep: sleep) {
            try await client.perform(request, as: AnalyzeResponse.self)
        }
    }
}
