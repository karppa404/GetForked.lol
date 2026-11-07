import CryptoKit
import Foundation

/// Upload bookkeeping for a local session (never contains credentials).
public struct UploadRecord: Codable, Equatable, Sendable {
    public var remoteSessionId: String?
    public var uploadedAt: String?
    public var jobId: String?
    public var jobStatus: String?
    public var apiBaseURL: String?
    public init(remoteSessionId: String? = nil, uploadedAt: String? = nil, jobId: String? = nil, jobStatus: String? = nil, apiBaseURL: String? = nil) {
        self.remoteSessionId = remoteSessionId
        self.uploadedAt = uploadedAt
        self.jobId = jobId
        self.jobStatus = jobStatus
        self.apiBaseURL = apiBaseURL
    }
}

public struct LocalSession: Sendable, Identifiable, Equatable {
    public var id: String { manifest.id }
    public var directory: URL
    public var manifest: SessionManifest
    public var review: ReviewState
    public var upload: UploadRecord

    public var framesDirectory: URL { directory.appendingPathComponent("frames", isDirectory: true) }
    public func url(for frame: Frame) -> URL { framesDirectory.appendingPathComponent(frame.filename, isDirectory: false) }
}

public enum SessionStoreError: Error, CustomStringConvertible {
    case unsafeFilename(String)
    case missingFile(String)
    case hashMismatch(String)
    case notASession(URL)

    public var description: String {
        switch self {
        case .unsafeFilename(let f): return "Unsafe frame filename: \(f)"
        case .missingFile(let f): return "Frame file missing: \(f)"
        case .hashMismatch(let f): return "Frame file changed since capture: \(f)"
        case .notASession(let u): return "Not a Retrace session: \(u.path)"
        }
    }
}

/// Local-only storage. Default root: ~/Library/Application Support/Retrace/Sessions.
/// Directories are created 0700 and excluded from backups. Nothing here touches the network.
public struct SessionStore: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Retrace", isDirectory: true).appendingPathComponent("Sessions", isDirectory: true)
    }

    public func directory(for sessionId: String) -> URL { root.appendingPathComponent(sessionId, isDirectory: true) }

    @discardableResult
    public func createSessionDirectory(id: String) throws -> URL {
        guard ManifestValidator.isUUID(id) else { throw SessionStoreError.unsafeFilename(id) }
        let dir = directory(for: id)
        try Self.makePrivateDirectory(root)
        try Self.makePrivateDirectory(dir)
        try Self.makePrivateDirectory(dir.appendingPathComponent("frames", isDirectory: true))
        return dir
    }

    static func makePrivateDirectory(_ url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }

    /// Writes encoded frame bytes and returns the manifest frame record (with SHA-256).
    public func writeFrame(sessionId: String, frameId: String, timestampMs: Int, data: Data, width: Int, height: Int, ext: String = "jpg") throws -> Frame {
        let filename = "\(frameId.lowercased()).\(ext)"
        guard ManifestValidator.isSafeFilename(filename) else { throw SessionStoreError.unsafeFilename(filename) }
        let url = directory(for: sessionId).appendingPathComponent("frames", isDirectory: true).appendingPathComponent(filename)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return Frame(id: frameId, timestampMs: timestampMs, filename: filename, width: width, height: height, sha256: Self.sha256Hex(data))
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func save(manifest: SessionManifest) throws {
        try write(manifest, to: directory(for: manifest.id).appendingPathComponent("manifest.json"))
    }

    public func save(review: ReviewState, sessionId: String) throws {
        try write(review, to: directory(for: sessionId).appendingPathComponent("review.json"))
    }

    public func save(upload: UploadRecord, sessionId: String) throws {
        try write(upload, to: directory(for: sessionId).appendingPathComponent("upload.json"))
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try ManifestCoding.encoder(pretty: true).encode(value)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func load(directory dir: URL) throws -> LocalSession {
        let dec = ManifestCoding.decoder()
        let mURL = dir.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: mURL.path) else { throw SessionStoreError.notASession(dir) }
        let manifest = try dec.decode(SessionManifest.self, from: Data(contentsOf: mURL))
        let review = (try? dec.decode(ReviewState.self, from: Data(contentsOf: dir.appendingPathComponent("review.json")))) ?? ReviewState()
        let upload = (try? dec.decode(UploadRecord.self, from: Data(contentsOf: dir.appendingPathComponent("upload.json")))) ?? UploadRecord()
        return LocalSession(directory: dir, manifest: manifest, review: review, upload: upload)
    }

    public func load(id: String) throws -> LocalSession { try Self.load(directory: directory(for: id)) }

    /// All readable sessions, newest first. Unreadable directories are skipped.
    public func list() -> [LocalSession] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { try? Self.load(directory: $0) }
            .sorted { $0.manifest.startedAt > $1.manifest.startedAt }
    }

    public func delete(id: String) throws {
        guard ManifestValidator.isUUID(id) else { throw SessionStoreError.unsafeFilename(id) }
        try FileManager.default.removeItem(at: directory(for: id))
    }

    /// Loads exactly the frame files referenced by `manifest`, verifying names and hashes.
    public static func frameFiles(for manifest: SessionManifest, in dir: URL) throws -> [(filename: String, data: Data)] {
        try manifest.frames.map { f in
            guard ManifestValidator.isSafeFilename(f.filename) else { throw SessionStoreError.unsafeFilename(f.filename) }
            let url = dir.appendingPathComponent("frames", isDirectory: true).appendingPathComponent(f.filename)
            guard let data = try? Data(contentsOf: url) else { throw SessionStoreError.missingFile(f.filename) }
            guard sha256Hex(data) == f.sha256 else { throw SessionStoreError.hashMismatch(f.filename) }
            return (f.filename, data)
        }
    }
}
