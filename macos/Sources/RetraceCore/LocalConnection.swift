import Foundation

struct LocalConnectRequest: Codable, Sendable { var deviceName: String }

/// `POST /v1/local/connect` response. Snake-case keys are converted by `ManifestCoding`.
public struct LocalConnectResponse: Codable, Equatable, Sendable {
    public var deviceToken: String
    public var projectId: String
    public var deviceId: String
    public var apiBaseUrl: String?
    public var projectName: String?
}

/// One-click connection to the Retrace API running on this Mac. The server only answers
/// loopback requests in local development, so no code or browser approval is needed.
public struct LocalConnectionService: Sendable {
    public let client: APIClient
    public init(client: APIClient) { self.client = client }

    public static func normalize(deviceName: String) throws -> String {
        let n = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= 64 else { throw APIError.invalidInput("Device name must be 1–64 characters.") }
        return n
    }

    /// Not retried: every successful call issues a new device token.
    public func connect(deviceName: String) async throws -> DeviceCredential {
        guard client.baseURL.isLoopback else {
            throw APIError.invalidInput("Local connection only works with a Retrace server on this Mac (localhost).")
        }
        let name = try Self.normalize(deviceName: deviceName)
        let r = try client.jsonRequest("POST", "/v1/local/connect", body: LocalConnectRequest(deviceName: name))
        let resp = try await client.perform(r, as: LocalConnectResponse.self)
        guard !resp.deviceToken.isEmpty else { throw APIError.decoding("empty device_token") }
        _ = try APIClient.pathComponent(resp.projectId)
        // Bound to the URL we called, never a server-supplied one, so the token cannot be redirected.
        return DeviceCredential(deviceToken: resp.deviceToken, projectId: resp.projectId,
                                apiBaseURL: client.baseURL.description, deviceName: name,
                                pairedAt: SessionClock.iso8601(Date()), projectName: resp.projectName)
    }
}
