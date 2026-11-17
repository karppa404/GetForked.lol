import Foundation
import Security

/// Device credential issued by the local connection (or legacy pairing). Bound to the API base URL it came from,
/// so changing the base URL never sends this token to a different server.
public struct DeviceCredential: Codable, Equatable, Sendable, CustomStringConvertible {
    public var deviceToken: String
    public var projectId: String
    public var apiBaseURL: String
    public var deviceName: String
    /// When the credential was issued (name kept for Keychain compatibility).
    public var pairedAt: String
    public var projectName: String?

    public init(deviceToken: String, projectId: String, apiBaseURL: String, deviceName: String, pairedAt: String,
                projectName: String? = nil) {
        self.deviceToken = deviceToken
        self.projectId = projectId
        self.apiBaseURL = apiBaseURL
        self.deviceName = deviceName
        self.pairedAt = pairedAt
        self.projectName = projectName
    }

    public var description: String { "DeviceCredential(project: \(projectId), server: \(apiBaseURL), token: <redacted>)" }

    /// Keychain key for the engine bundled in Retrace.app. Its port changes on every launch, so its
    /// credential is stored under this stable identity instead of a URL and rebound at runtime.
    public static let embeddedServerKey = "embedded-local-server"

    /// The same credential addressed to `server` (a URL or `embeddedServerKey`).
    public func bound(to server: String) -> DeviceCredential {
        var c = self
        c.apiBaseURL = server
        return c
    }
}

public protocol CredentialStore: Sendable {
    func load(apiBaseURL: String) throws -> DeviceCredential?
    func save(_ credential: DeviceCredential) throws
    func delete(apiBaseURL: String) throws
}

public enum CredentialStoreError: Error, CustomStringConvertible {
    case keychain(OSStatus)
    public var description: String {
        switch self {
        case .keychain(let s):
            let msg = SecCopyErrorMessageString(s, nil) as String? ?? "unknown"
            return "Keychain error \(s): \(msg)"
        }
    }
}

/// Generic-password Keychain item per API base URL. The token is only ever in the Keychain
/// and in memory; it is never written to disk, logs, manifests or UserDefaults.
public struct KeychainCredentialStore: CredentialStore {
    public let service: String
    public init(service: String = "dev.retrace.recorder.device-credential") { self.service = service }

    func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load(apiBaseURL: String) throws -> DeviceCredential? {
        var q = baseQuery(apiBaseURL)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw CredentialStoreError.keychain(status) }
        return try JSONDecoder().decode(DeviceCredential.self, from: data)
    }

    public func save(_ credential: DeviceCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let q = baseQuery(credential.apiBaseURL)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            add[kSecAttrLabel as String] = "Retrace device credential"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
    }

    public func delete(apiBaseURL: String) throws {
        let status = SecItemDelete(baseQuery(apiBaseURL) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.keychain(status) }
    }
}

/// For tests and previews only.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: DeviceCredential] = [:]
    public init() {}
    public func load(apiBaseURL: String) throws -> DeviceCredential? { lock.withLock { items[apiBaseURL] } }
    public func save(_ c: DeviceCredential) throws { lock.withLock { items[c.apiBaseURL] = c } }
    public func delete(apiBaseURL: String) throws { lock.withLock { _ = items.removeValue(forKey: apiBaseURL) } }
}

/// One secret string (the model API key) per account, read from the Keychain. Retrace no longer
/// writes it; a key saved by an older version, or added with `security`, is still used.
public protocol SecretStore: Sendable {
    func load(_ account: String) throws -> String?
}

public struct KeychainSecretStore: SecretStore {
    public let service: String
    public init(service: String = "dev.retrace.recorder.model-api-key") { self.service = service }

    func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load(_ account: String) throws -> String? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw CredentialStoreError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }
}
