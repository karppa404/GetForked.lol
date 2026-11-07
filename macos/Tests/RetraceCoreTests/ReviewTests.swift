import Foundation
import Testing
@testable import RetraceCore

@Suite("Review and redaction")
struct ReviewTests {
    @Test func unconfirmedReviewCannotProduceUpload() throws {
        let m = try loadFixture().manifest
        #expect(throws: ReviewError.notConfirmed) { try ReviewApplier.apply(ReviewState(), to: m, projectId: "p") }
        let confirmed = ReviewState(confirmedAt: "2026-11-07T15:10:00.000Z")
        #expect(throws: ReviewError.missingProject) { try ReviewApplier.apply(confirmed, to: m, projectId: nil) }
    }

    @Test func omittingFramesClearsReferences() throws {
        let m = try loadFixture().manifest
        let omittedFrame = m.frames[1].id
        let review = ReviewState(omittedFrameIds: [omittedFrame], omittedInteractionIds: [m.interactions[1].id],
                                 removeWindowTitles: true, confirmedAt: "2026-11-07T15:10:00.000Z")
        let out = try ReviewApplier.apply(review, to: m, projectId: "proj-1")
        #expect(out.frames.count == 2)
        #expect(!out.frames.contains { $0.id == omittedFrame })
        #expect(out.interactions.count == 4)
        #expect(out.interactions.allSatisfy { $0.beforeFrameId != omittedFrame && $0.afterFrameId != omittedFrame })
        #expect(out.interactions.allSatisfy { $0.accessibility?.windowTitle == nil })
        #expect(out.redaction == Redaction(reviewed: true, omittedFrames: 1, omittedInteractions: 1, windowTitlesRemoved: true))
        #expect(out.projectId == "proj-1")
        #expect(ManifestValidator.validate(out, purpose: .upload).isEmpty)
        // The original local recording is untouched.
        #expect(m.redaction.reviewed == false && m.frames.count == 3)
    }

    @Test func storeWritesPrivateFilesAndHashes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retrace-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)
        let id = UUID().uuidString.lowercased()
        let dir = try store.createSessionDirectory(id: id)
        let data = Data("synthetic".utf8)
        let frame = try store.writeFrame(sessionId: id, frameId: UUID().uuidString.lowercased(), timestampMs: 5, data: data, width: 1, height: 1)
        #expect(frame.sha256 == SessionStore.sha256Hex(data))
        let manifest = SessionManifest(id: id, app: AppInfo(name: "X", bundleId: "x", pid: 1),
                                       startedAt: "2026-11-07T15:00:00.000Z", durationMs: 10, frames: [frame])
        try store.save(manifest: manifest)
        let perms = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(perms == 0o700)
        #expect(store.list().map(\.id) == [id])
        #expect(try SessionStore.frameFiles(for: manifest, in: dir).first?.data == data)
        try Data("tampered".utf8).write(to: dir.appendingPathComponent("frames").appendingPathComponent(frame.filename))
        #expect(throws: SessionStoreError.self) { try SessionStore.frameFiles(for: manifest, in: dir) }
        #expect(throws: SessionStoreError.self) { try store.createSessionDirectory(id: "../evil") }
    }
}
