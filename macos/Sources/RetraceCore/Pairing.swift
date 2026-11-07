import Foundation

public struct ClaimRequest: Codable, Sendable { public var code: String; public var deviceName: String }
public struct ClaimResponse: Codable, Equatable, Sendable {
    public var claimId: String
    public var claimSecret: String
    public var status: String
}
struct PollRequest: Codable, Sendable { var claimSecret: String }
public struct PollResponse: Codable, Equatable, Sendable {
    public var status: String
    public var deviceToken: String?
    public var projectId: String?
}

public enum PairingPhase: Equatable, Sendable {
    case unpaired
    case claiming
    /// Code accepted; waiting for someone to approve this device name in the browser.
    case pending(claimId: String, deviceName: String)
    case paired(projectId: String)
    case failed(String)
}

public enum PairingOutcome: Equatable, Sendable {
    case approved(DeviceCredential)
    case rejected(String)
    case expired
    case failed(String)
    case cancelled
}

public struct PollPolicy: Sendable {
    public var interval: Duration
    /// Hard stop for the whole wait, independent of server-side expiry.
    public var maxWait: Duration
    /// Consecutive transient failures tolerated before giving up.
    public var maxConsecutiveErrors: Int
    public init(interval: Duration = .seconds(2), maxWait: Duration = .seconds(600), maxConsecutiveErrors: Int = 5) {
        self.interval = interval
        self.maxWait = maxWait
        self.maxConsecutiveErrors = maxConsecutiveErrors
    }
}

public struct PairingService: Sendable {
    public let client: APIClient
    public init(client: APIClient) { self.client = client }

    public static func normalize(code: String) throws -> String {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, c.count <= 64, !c.contains(where: { $0.isNewline }) else {
            throw APIError.invalidInput("Enter the pairing code shown in the browser.")
        }
        return c
    }

    public static func normalize(deviceName: String) throws -> String {
        let n = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= 64 else { throw APIError.invalidInput("Device name must be 1–64 characters.") }
        return n
    }

    /// Claims a code. Not retried automatically: the code is single use and consumed atomically.
    public func claim(code: String, deviceName: String) async throws -> ClaimResponse {
        let body = ClaimRequest(code: try Self.normalize(code: code), deviceName: try Self.normalize(deviceName: deviceName))
        let r = try client.jsonRequest("POST", "/v1/pairings/claim", body: body)
        let resp = try await client.perform(r, as: ClaimResponse.self)
        _ = try APIClient.pathComponent(resp.claimId)
        guard !resp.claimSecret.isEmpty else { throw APIError.decoding("empty claim_secret") }
        return resp
    }

    public func poll(claimId: String, claimSecret: String) async throws -> PollResponse {
        let id = try APIClient.pathComponent(claimId)
        let r = try client.jsonRequest("POST", "/v1/pairings/claims/\(id)/poll", body: PollRequest(claimSecret: claimSecret))
        return try await client.perform(r, as: PollResponse.self)
    }

    /// Polls until approved, rejected, expired, the time budget is spent, or too many
    /// consecutive transient errors occur. Bounded by `policy` in every path.
    public func waitForApproval(claim: ClaimResponse, deviceName: String, policy: PollPolicy = PollPolicy(),
                                sleep: Sleeper = realSleeper,
                                clock: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) async -> PairingOutcome {
        let deadline = clock() + policy.maxWait
        var consecutiveErrors = 0
        while true {
            if Task.isCancelled { return .cancelled }
            if clock() >= deadline { return .expired }
            do {
                let r = try await poll(claimId: claim.claimId, claimSecret: claim.claimSecret)
                if Task.isCancelled { return .cancelled }
                consecutiveErrors = 0
                switch r.status.lowercased() {
                case "pending": break
                case "approved":
                    guard let token = r.deviceToken, !token.isEmpty, let project = r.projectId, !project.isEmpty else {
                        return .failed("Server approved but returned no device token/project.")
                    }
                    return .approved(DeviceCredential(deviceToken: token, projectId: project,
                                                      apiBaseURL: client.baseURL.description, deviceName: deviceName,
                                                      pairedAt: SessionClock.iso8601(Date())))
                case "expired": return .expired
                case "rejected", "denied", "cancelled", "canceled": return .rejected("Pairing was declined in the browser.")
                default: return .failed("Unknown pairing status \"\(r.status.prefix(32))\".")
                }
            } catch let e as APIError {
                switch e {
                case .http(410, _), .http(404, _): return .expired
                case .http(401, _), .http(403, _): return .rejected("Claim secret not accepted.")
                case _ where e.isTransient:
                    consecutiveErrors += 1
                    if consecutiveErrors >= policy.maxConsecutiveErrors { return .failed("Gave up after repeated errors: \(e)") }
                default: return .failed(e.description)
                }
            } catch {
                return .failed(error.localizedDescription)
            }
            do {
                let backoff = consecutiveErrors == 0 ? policy.interval : policy.interval * (1 << min(consecutiveErrors, 4))
                try await sleep(backoff)
            } catch { return .cancelled }
        }
    }
}
