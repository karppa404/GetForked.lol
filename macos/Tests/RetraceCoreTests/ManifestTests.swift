import Foundation
import Testing
@testable import RetraceCore

@Suite("Manifest")
struct ManifestTests {
    @Test func fixtureIsValidLocally() throws {
        let s = try loadFixture()
        #expect(ManifestValidator.validate(s.manifest, purpose: .local).isEmpty)
        #expect(try SessionStore.frameFiles(for: s.manifest, in: s.directory).count == 3)
    }

    @Test func fixtureIsNotUploadableUntilReviewedAndBound() throws {
        let issues = ManifestValidator.validate(try loadFixture().manifest, purpose: .upload)
        #expect(issues.contains { $0.path == "redaction.reviewed" })
        #expect(issues.contains { $0.path == "project_id" })
    }

    @Test func encodesContractKeysInSnakeCase() throws {
        var m = try loadFixture().manifest
        m.projectId = "proj-1"
        let obj = try jsonObject(try ManifestCoding.encoder().encode(m))
        for key in ["schema_version", "id", "project_id", "app", "started_at", "duration_ms", "interactions", "frames", "network", "redaction", "network_status"] {
            #expect(obj[key] != nil, "missing \(key)")
        }
        #expect(obj["task"] == nil, "no task/reason is recorded")
        #expect(obj["network_status"] as? String == "not_captured")
        #expect((obj["app"] as? [String: Any])?["bundle_id"] as? String == "com.example.synthetic-notes")
        let first = (obj["interactions"] as! [[String: Any]])[0]
        #expect(first["timestamp_ms"] as? Int == 1200)
        #expect(first["before_frame_id"] != nil && first["after_frame_id"] != nil)
        #expect(first["key"] == nil, "nil optionals must be omitted")
        let frame = (obj["frames"] as! [[String: Any]])[0]
        #expect(Set(frame.keys) == ["id", "timestamp_ms", "filename", "width", "height", "sha256"])
    }

    @Test func decodesLegacyManifestWithTask() throws {
        var obj = try jsonObject(try ManifestCoding.encoder().encode(try loadFixture().manifest))
        obj["task"] = "Old typed task"
        let m = try ManifestCoding.decoder().decode(SessionManifest.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(m.task == "Old typed task")
    }

    @Test func roundTrips() throws {
        let m = try loadFixture().manifest
        let back = try ManifestCoding.decoder().decode(SessionManifest.self, from: ManifestCoding.encoder().encode(m))
        #expect(back == m)
    }

    @Test func rejectsTraversalAndUnsafeFilenames() {
        for bad in ["../x.jpg", "a/b.jpg", ".hidden", "..", "a..b", "x\\y", "", "spaced name.jpg"] {
            #expect(!ManifestValidator.isSafeFilename(bad), "\(bad)")
        }
        #expect(ManifestValidator.isSafeFilename("3f1c9a52-6a0e-4c5b-9b8e-1d2f3a4b5c61.jpg"))
    }

    @Test func detectsBrokenReferencesTimestampsAndKeys() throws {
        var m = try loadFixture().manifest
        m.interactions[0].afterFrameId = UUID().uuidString
        m.interactions[1].timestampMs = 99_999
        m.interactions[4].key = "p"           // a printable character must never appear
        m.frames[1].filename = "../escape.png"
        m.frames[2].id = m.frames[0].id
        m.network = [NetworkEvent(id: UUID().uuidString, timestampMs: 1, method: "GET", url: "https://x")]
        let paths = Set(ManifestValidator.validate(m, purpose: .local).map(\.path))
        #expect(paths.contains("interactions[0].after_frame_id"))
        #expect(paths.contains("interactions[1].timestamp_ms"))
        #expect(paths.contains("interactions[4].key"))
        #expect(paths.contains("frames[1].filename"))
        #expect(paths.contains("frames[2].id"))
        #expect(paths.contains("network"), "not_captured must not carry events")
    }

    @Test func beforeFrameMustPrecedeInteraction() throws {
        var m = try loadFixture().manifest
        m.interactions[0].beforeFrameId = m.frames[2].id // 7600 > 1200
        #expect(ManifestValidator.validate(m, purpose: .local).contains { $0.path == "interactions[0].before_frame_id" })
    }

    @Test func secureFieldsDropTitleAndLabel() {
        let s = AccessibilitySnapshot(role: "AXTextField", subrole: "AXSecureTextField", title: "Password", label: "hunter2?", windowTitle: "Login").sanitized()
        #expect(s.secure == true && s.title == nil && s.label == nil)
        #expect(s.windowTitle == "Login")
    }
}

@Suite("Timestamps")
struct ClockTests {
    @Test func millisecondsAreRelativeAndClamped() {
        let c = SessionClock(startUptime: 100, startDate: Date(timeIntervalSince1970: 0))
        #expect(c.milliseconds(atUptime: 100) == 0)
        #expect(c.milliseconds(atUptime: 101.2346) == 1235)
        #expect(c.milliseconds(atUptime: 99) == 0, "events before start clamp to 0")
        #expect(c.startedAtISO8601 == "1970-01-01T00:00:00.000Z")
    }

    @Test func isoParses() {
        #expect(SessionClock.parseISO8601("2026-11-07T15:00:00.000Z") != nil)
        #expect(SessionClock.parseISO8601("2026-11-07T15:00:00Z") != nil)
        #expect(SessionClock.parseISO8601("yesterday") == nil)
    }

    @Test func validatorRejectsNonUTCStart() throws {
        var m = try loadFixture().manifest
        m.startedAt = "2026-11-07T10:00:00-05:00"
        #expect(ManifestValidator.validate(m, purpose: .local).contains { $0.path == "started_at" })
    }
}

@Suite("Key naming")
struct KeyNamingTests {
    typealias M = KeyNaming.Modifiers
    @Test func namedKeysAndShortcuts() {
        #expect(KeyNaming.classify(keyCode: 36, modifiers: []) == .named("return"))
        #expect(KeyNaming.classify(keyCode: 48, modifiers: [.shift]) == .named("shift+tab"))
        #expect(KeyNaming.classify(keyCode: 1, modifiers: [.command]) == .named("cmd+s"))
        #expect(KeyNaming.classify(keyCode: 1, modifiers: [.command, .shift]) == .named("shift+cmd+s"))
        #expect(KeyNaming.classify(keyCode: 8, modifiers: [.control]) == .named("ctrl+c"))
    }

    @Test func printableInputIsText() {
        #expect(KeyNaming.classify(keyCode: 0, modifiers: []) == .text)          // a
        #expect(KeyNaming.classify(keyCode: 0, modifiers: [.shift]) == .text)    // A
        #expect(KeyNaming.classify(keyCode: 0, modifiers: [.option]) == .text)   // å
        #expect(KeyNaming.classify(keyCode: 49, modifiers: []) == .text)         // space
        #expect(KeyNaming.classify(keyCode: 200, modifiers: [.command]) == .text) // unknown
    }

    @Test func safeValueAllowList() {
        for ok in ["return", "cmd+s", "shift+cmd+z", "ctrl+opt+delete", "redacted", "f5"] { #expect(KeyNaming.isSafeKeyValue(ok), "\(ok)") }
        for bad in ["a", "shift+a", "opt+e", "hello", "cmd+cmd+s", "super+s", "", "+"] { #expect(!KeyNaming.isSafeKeyValue(bad), "\(bad)") }
    }
}
