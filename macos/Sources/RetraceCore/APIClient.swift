import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    public init(timeout: TimeInterval = 30) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = max(timeout, 300)
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config)
    }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.transport("Non-HTTP response") }
        return (data, http)
    }
}

public enum APIError: Error, Equatable, CustomStringConvertible {
    case invalidBaseURL(String)
    case invalidInput(String)
    case transport(String)
    case http(status: Int, detail: String?)
    case decoding(String)

    public var description: String {
        switch self {
        case .invalidBaseURL(let m): return "Invalid API base URL: \(m)"
        case .invalidInput(let m): return m
        case .transport(let m): return "Network error: \(m)"
        case .http(let status, let detail):
            let hint: String
            switch status {
            case 401, 403: hint = "Not authorized. Connect this Mac again."
            case 404: hint = "Not found."
            case 409: hint = "Conflict (already used or already exists)."
            case 410: hint = "Expired."
            case 413: hint = "Upload too large."
            case 422, 400: hint = "Request rejected by server validation."
            case 429: hint = "Rate limited."
            default: hint = status >= 500 ? "Server error." : "Request failed."
            }
            return "HTTP \(status): \(hint)" + (detail.map { " \($0)" } ?? "")
        case .decoding(let m): return "Unexpected server response: \(m)"
        }
    }

    /// Worth retrying: no response, rate limiting, or gateway/server unavailability.
    public var isTransient: Bool {
        switch self {
        case .transport: return true
        case .http(let status, _): return status == 429 || status == 502 || status == 503 || status == 504 || status == 500
        default: return false
        }
    }
}

/// Validated, normalized API base URL. Plain HTTP is only allowed for loopback hosts so a
/// device token is never sent unencrypted across a network.
public struct APIBaseURL: Equatable, Sendable, CustomStringConvertible {
    public static let development = "http://127.0.0.1:8000"
    public let url: URL

    public init(_ string: String) throws {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let comps = URLComponents(string: s), let scheme = comps.scheme?.lowercased(),
              let host = comps.host?.lowercased(), !host.isEmpty else {
            throw APIError.invalidBaseURL("expected http(s)://host[:port][/path]")
        }
        guard comps.query == nil, comps.fragment == nil, comps.user == nil, comps.password == nil else {
            throw APIError.invalidBaseURL("must not contain credentials, query or fragment")
        }
        let loopback = Self.loopbackHosts.contains(host)
        switch scheme {
        case "https": break
        case "http": guard loopback else { throw APIError.invalidBaseURL("plain http is only allowed for localhost; use https") }
        default: throw APIError.invalidBaseURL("scheme must be http or https")
        }
        guard let url = URL(string: s) else { throw APIError.invalidBaseURL("unparseable") }
        self.url = url
    }

    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]
    public var isLoopback: Bool { Self.loopbackHosts.contains(url.host?.lowercased() ?? "") }

    public var description: String { url.absoluteString }

    public func endpoint(_ path: String) -> URL {
        URL(string: url.absoluteString + path)!
    }
}

public struct APIClient: Sendable {
    public let baseURL: APIBaseURL
    public let transport: HTTPTransport

    public init(baseURL: APIBaseURL, transport: HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public static func pathComponent(_ s: String) throws -> String {
        guard ManifestValidator.isSafeFilename(s) else { throw APIError.invalidInput("Unsafe identifier from server") }
        return s
    }

    func request(_ method: String, _ path: String, bearer: String? = nil) -> URLRequest {
        var r = URLRequest(url: baseURL.endpoint(path))
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("Retrace-macOS/1", forHTTPHeaderField: "User-Agent")
        if let bearer { r.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        return r
    }

    func jsonRequest<Body: Encodable>(_ method: String, _ path: String, body: Body, bearer: String? = nil) throws -> URLRequest {
        var r = request(method, path, bearer: bearer)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try ManifestCoding.encoder().encode(body)
        return r
    }

    /// Sends a request and decodes a 2xx JSON body. Non-2xx becomes `APIError.http` with a
    /// short, sanitized `detail` (never echoed request contents).
    public func perform<T: Decodable>(_ request: URLRequest, as: T.Type) async throws -> T {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.http(status: response.statusCode, detail: Self.errorDetail(data))
        }
        do {
            return try ManifestCoding.decoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: T.self))
        }
    }

    static func errorDetail(_ data: Data) -> String? {
        struct Detail: Decodable { let detail: String?; let error: String?; let message: String? }
        guard let d = try? JSONDecoder().decode(Detail.self, from: data) else { return nil }
        guard let s = d.detail ?? d.error ?? d.message else { return nil }
        return String(s.prefix(200))
    }
}

public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: Duration
    public var maxDelay: Duration
    public init(maxAttempts: Int = 3, baseDelay: Duration = .seconds(1), maxDelay: Duration = .seconds(8)) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }
    public func delay(afterAttempt attempt: Int) -> Duration {
        let factor = 1 << min(max(attempt - 1, 0), 10)
        return min(baseDelay * factor, maxDelay)
    }
}

public typealias Sleeper = @Sendable (Duration) async throws -> Void
public let realSleeper: Sleeper = { try await Task.sleep(for: $0) }

/// Runs `operation` with bounded retries for transient errors only.
public func withBoundedRetry<T: Sendable>(_ policy: RetryPolicy, sleep: Sleeper = realSleeper,
                                         _ operation: @Sendable () async throws -> T) async throws -> T {
    var attempt = 0
    while true {
        attempt += 1
        do {
            return try await operation()
        } catch let e as APIError where e.isTransient && attempt < policy.maxAttempts {
            try await sleep(policy.delay(afterAttempt: attempt))
        }
    }
}
