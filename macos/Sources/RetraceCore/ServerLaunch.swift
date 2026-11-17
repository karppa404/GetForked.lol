import Foundation

/// How the app reaches its analysis engine (the Python backend).
public enum ServerLocation: Equatable, Sendable {
    /// A server someone else runs (development: `RETRACE_SERVER_URL`).
    case external(APIBaseURL)
    /// A binary the app launches and supervises (the bundled engine or `RETRACE_SERVER_BIN`).
    case binary(URL)
    /// Nothing to launch; the reason is shown in the panel.
    case missing(String)

    public static let serverURLVariable = "RETRACE_SERVER_URL"
    public static let serverBinVariable = "RETRACE_SERVER_BIN"
    /// `Contents/Resources/retrace-server/retrace-server` (PyInstaller onedir folder).
    public static let bundledRelativePath = "retrace-server/retrace-server"

    /// Precedence: `RETRACE_SERVER_URL`, `RETRACE_SERVER_BIN`, the bundled engine.
    public static func resolve(environment: [String: String], resources: URL?,
                               isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }) -> ServerLocation {
        if let raw = nonEmpty(environment[serverURLVariable]) {
            guard let url = try? APIBaseURL(raw) else { return .missing("\(serverURLVariable) must be a localhost URL such as \(APIBaseURL.development).") }
            return .external(url)
        }
        if let raw = nonEmpty(environment[serverBinVariable]) {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            guard isExecutable(url) else { return .missing("\(serverBinVariable) does not point to an executable file.") }
            return .binary(url)
        }
        if let resources {
            let bin = resources.appendingPathComponent(bundledRelativePath)
            if isExecutable(bin) { return .binary(bin) }
        }
        return .missing("This build doesn't include the analysis engine. For development, run the backend and set \(serverURLVariable).")
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

/// Model settings for the bundled engine: code defaults, or a value older versions saved in
/// UserDefaults. The API key is not part of this value: it lives in the Keychain and reaches the
/// engine only through a 0600 key file.
public struct ModelSettings: Codable, Equatable, Sendable {
    public static let defaultEndpoint = "https://integrate.api.nvidia.com/v1"
    public static let defaultModel = "nvidia/NVIDIA-Nemotron-Nano-9B-v2"

    public var endpoint: String
    public var model: String
    /// Screenshot vision; Nemotron Nano 9B v2 is text-only, so off by default.
    public var vision: Bool
    /// Deterministic local analysis with no model calls (`offline_heuristic`).
    public var offlineDemo: Bool

    public init(endpoint: String = defaultEndpoint, model: String = defaultModel, vision: Bool = false, offlineDemo: Bool = false) {
        self.endpoint = endpoint
        self.model = model
        self.vision = vision
        self.offlineDemo = offlineDemo
    }
}

/// What the supervisor launches. `transientFiles` (the key file) are deleted once the process is
/// ready or has exited; the engine reads them at startup only.
public struct ServerLaunchSpec: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectory: URL?
    public var transientFiles: [URL]
    /// Values scrubbed from captured diagnostics (for example the API key).
    public var secrets: [String]

    public init(executable: URL, arguments: [String] = [], environment: [String: String], currentDirectory: URL? = nil,
                transientFiles: [URL] = [], secrets: [String] = []) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.transientFiles = transientFiles
        self.secrets = secrets
    }
}

public enum ServerEnvironment {
    /// `~/Library/Application Support/Retrace/server`.
    public static func defaultDataDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Retrace/server", isDirectory: true)
    }

    public static func keyFile(in dataDir: URL) -> URL { dataDir.appendingPathComponent("llm.key") }

    /// Only these inherited variables reach the engine. Everything else (notably any `*_API_KEY`
    /// a model SDK would pick up, and stray `RETRACE_*` overrides) is dropped.
    static let inheritedAllowlist: Set<String> = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "TZ", "__CF_USER_TEXT_ENCODING"]

    /// The engine's environment. The API key itself is never placed in it, only `apiKeyFile`'s path.
    public static func make(inherited: [String: String], dataDir: URL, settings: ModelSettings, apiKeyFile: URL?) -> [String: String] {
        var env = inherited.filter { inheritedAllowlist.contains($0.key) || $0.key.hasPrefix("LC_") }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["RETRACE_EMBEDDED"] = "1"
        env["RETRACE_PORT"] = "0"
        env["RETRACE_DATA_DIR"] = dataDir.path
        if settings.offlineDemo {
            env["RETRACE_LLM_PROVIDER"] = "offline_heuristic"
            return env
        }
        env["RETRACE_LLM_PROVIDER"] = "openai_compatible"
        if let e = ServerLocation.nonEmpty(settings.endpoint) { env["RETRACE_LLM_BASE_URL"] = e }
        if let m = ServerLocation.nonEmpty(settings.model) { env["RETRACE_LLM_MODEL"] = m }
        env["RETRACE_LLM_VISION"] = settings.vision ? "1" : "0"
        if let apiKeyFile { env["RETRACE_LLM_API_KEY_FILE"] = apiKeyFile.path }
        return env
    }

    /// Creates `dataDir` (0700) if needed.
    public static func prepareDataDirectory(_ dataDir: URL) throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Writes `secret` to `url` with mode 0600, never following a symlink at that path.
    public static func writeSecretFile(_ secret: String, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let bytes = Array(secret.utf8)
        var written = 0
        while written < bytes.count {
            let n = bytes[written...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            written += n
        }
    }
}

/// `GET /health`, only the fields the app uses.
public struct ServerHealth: Decodable, Equatable, Sendable {
    public struct Analysis: Decodable, Equatable, Sendable {
        public var provider: String?
        public var configured: Bool
        public var visionEnabled: Bool?
    }
    public var status: String?
    public var version: String?
    public var embedded: Bool?
    public var analysis: Analysis?

    /// Missing `analysis` (an older server) is treated as configured so Analyze stays available.
    public var analysisConfigured: Bool { analysis?.configured ?? true }
    public var isOfflineDemo: Bool { analysis?.provider == "offline_heuristic" }
}

extension APIClient {
    public func health() async throws -> ServerHealth {
        try await perform(request("GET", "/health"), as: ServerHealth.self)
    }
}
