import Foundation

/// Manifest schema, version 1 (see docs/INTEGRATION.md). Encoded with snake_case keys.
///
/// Two additive fields beyond the committed contract are emitted, because the contract
/// otherwise has no way to express them honestly:
/// - `network_status`: `"not_captured"` when no network helper was running, so an empty
///   `network` array is never mistaken for "no network activity".
/// - `Interaction.delayed_frame_id`: the settled-state frame captured ~1.5 s after an action.
public struct SessionManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var projectId: String?
    public var app: AppInfo
    /// Legacy field: older local sessions stored a user-typed task. New sessions omit it;
    /// Retrace observes selected-app activity and never asks for intent.
    public var task: String?
    public var startedAt: String
    public var durationMs: Int
    public var interactions: [Interaction]
    public var frames: [Frame]
    public var network: [NetworkEvent]
    public var networkStatus: NetworkStatus
    public var redaction: Redaction

    public init(
        schemaVersion: Int = SessionManifest.currentSchemaVersion,
        id: String,
        projectId: String? = nil,
        app: AppInfo,
        task: String? = nil,
        startedAt: String,
        durationMs: Int,
        interactions: [Interaction] = [],
        frames: [Frame] = [],
        network: [NetworkEvent] = [],
        networkStatus: NetworkStatus = .notCaptured,
        redaction: Redaction = Redaction(reviewed: false)
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.projectId = projectId
        self.app = app
        self.task = task
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.interactions = interactions
        self.frames = frames
        self.network = network
        self.networkStatus = networkStatus
        self.redaction = redaction
    }
}

public struct AppInfo: Codable, Equatable, Sendable {
    public var name: String
    public var bundleId: String
    public var pid: Int32

    public init(name: String, bundleId: String, pid: Int32) {
        self.name = name
        self.bundleId = bundleId
        self.pid = pid
    }
}

public enum NetworkStatus: String, Codable, Sendable {
    case observed
    case noneObserved = "none_observed"
    case notCaptured = "not_captured"
}

public struct Redaction: Codable, Equatable, Sendable {
    /// True only after the user explicitly confirmed review in the local review window.
    public var reviewed: Bool
    public var omittedFrames: Int?
    public var omittedInteractions: Int?
    public var windowTitlesRemoved: Bool?

    public init(reviewed: Bool, omittedFrames: Int? = nil, omittedInteractions: Int? = nil, windowTitlesRemoved: Bool? = nil) {
        self.reviewed = reviewed
        self.omittedFrames = omittedFrames
        self.omittedInteractions = omittedInteractions
        self.windowTitlesRemoved = windowTitlesRemoved
    }
}

public enum InteractionKind: String, Codable, Sendable, CaseIterable {
    case click
    case doubleClick = "double_click"
    case rightClick = "right_click"
    case otherClick = "other_click"
    case scroll
    /// A safe, named key or shortcut (e.g. `return`, `cmd+s`). Never a printable character.
    case key
    /// A burst of printable typing. The characters are never recorded; `key` is `"redacted"`.
    case textInput = "text_input"
    /// Target app lost foreground; capture paused until it returns.
    case focusLost = "focus_lost"
    case focusRegained = "focus_regained"
}

public struct Interaction: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var timestampMs: Int
    public var kind: InteractionKind
    public var x: Double?
    public var y: Double?
    public var key: String?
    public var scrollDx: Double?
    public var scrollDy: Double?
    public var accessibility: AccessibilitySnapshot?
    public var beforeFrameId: String?
    public var afterFrameId: String?
    public var delayedFrameId: String?

    public init(
        id: String = UUID().uuidString.lowercased(),
        timestampMs: Int,
        kind: InteractionKind,
        x: Double? = nil,
        y: Double? = nil,
        key: String? = nil,
        scrollDx: Double? = nil,
        scrollDy: Double? = nil,
        accessibility: AccessibilitySnapshot? = nil,
        beforeFrameId: String? = nil,
        afterFrameId: String? = nil,
        delayedFrameId: String? = nil
    ) {
        self.id = id
        self.timestampMs = timestampMs
        self.kind = kind
        self.x = x
        self.y = y
        self.key = key
        self.scrollDx = scrollDx
        self.scrollDy = scrollDy
        self.accessibility = accessibility
        self.beforeFrameId = beforeFrameId
        self.afterFrameId = afterFrameId
        self.delayedFrameId = delayedFrameId
    }
}

/// Structural description of a UI element. Element *values* (field contents) are never read.
public struct AccessibilitySnapshot: Codable, Equatable, Sendable {
    public var role: String?
    public var subrole: String?
    public var title: String?
    public var label: String?
    public var identifier: String?
    public var windowTitle: String?
    /// True when the element is a secure (password) field; title/label are then dropped too.
    public var secure: Bool?

    public init(role: String? = nil, subrole: String? = nil, title: String? = nil, label: String? = nil,
                identifier: String? = nil, windowTitle: String? = nil, secure: Bool? = nil) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.label = label
        self.identifier = identifier
        self.windowTitle = windowTitle
        self.secure = secure
    }

    /// Removes anything but the role for secure fields; truncates long strings.
    public func sanitized(maxLength: Int = 200) -> AccessibilitySnapshot {
        let isSecure = secure == true || subrole == "AXSecureTextField" || role == "AXSecureTextField"
        func clip(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s.count > maxLength ? String(s.prefix(maxLength)) + "…" : s
        }
        if isSecure {
            return AccessibilitySnapshot(role: role, subrole: subrole, windowTitle: clip(windowTitle), secure: true)
        }
        return AccessibilitySnapshot(role: clip(role), subrole: clip(subrole), title: clip(title), label: clip(label),
                                     identifier: clip(identifier), windowTitle: clip(windowTitle), secure: nil)
    }
}

public struct Frame: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var timestampMs: Int
    public var filename: String
    public var width: Int
    public var height: Int
    public var sha256: String

    public init(id: String, timestampMs: Int, filename: String, width: Int, height: Int, sha256: String) {
        self.id = id
        self.timestampMs = timestampMs
        self.filename = filename
        self.width = width
        self.height = height
        self.sha256 = sha256
    }
}

public struct NetworkEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var timestampMs: Int
    public var method: String
    public var url: String
    public var status: Int?
    public var requestHeaders: [String: String]?
    public var responseHeaders: [String: String]?
    public var requestBody: String?
    public var responseBody: String?

    public init(id: String, timestampMs: Int, method: String, url: String, status: Int? = nil,
                requestHeaders: [String: String]? = nil, responseHeaders: [String: String]? = nil,
                requestBody: String? = nil, responseBody: String? = nil) {
        self.id = id
        self.timestampMs = timestampMs
        self.method = method
        self.url = url
        self.status = status
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.requestBody = requestBody
        self.responseBody = responseBody
    }
}

public enum ManifestCoding {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}
