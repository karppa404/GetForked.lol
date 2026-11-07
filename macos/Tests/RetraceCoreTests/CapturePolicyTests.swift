import Foundation
import Testing
@testable import RetraceCore

@Suite("Capture policy")
struct CapturePolicyTests {
    let target: Int32 = 500

    @Test func asynchronousFrameCompletionCannotCrossSessionBoundary() {
        #expect(CapturePolicy.canRetainFrame(sessionId: "A", activeSessionId: "A", sessionIsActive: true, cancelled: false))
        #expect(!CapturePolicy.canRetainFrame(sessionId: "A", activeSessionId: "B", sessionIsActive: true, cancelled: false))
        #expect(!CapturePolicy.canRetainFrame(sessionId: "A", activeSessionId: "A", sessionIsActive: false, cancelled: false))
        #expect(!CapturePolicy.canRetainFrame(sessionId: "A", activeSessionId: "A", sessionIsActive: true, cancelled: true))
    }

    @Test func ambientOutputEvidenceIsBounded() {
        #expect(CapturePolicy.shouldRetainAmbientFrame(lastUptime: nil, currentUptime: 100))
        #expect(!CapturePolicy.shouldRetainAmbientFrame(lastUptime: 100, currentUptime: 114.99))
        #expect(CapturePolicy.shouldRetainAmbientFrame(lastUptime: 100, currentUptime: 115))
        #expect(!CapturePolicy.shouldRetainAmbientFrame(lastUptime: 100, currentUptime: 99))
    }

    @Test func acceptsOnlyTargetWhileFrontmostAndRecording() {
        #expect(CapturePolicy.evaluate(recording: true, targetPID: target, frontmostPID: target, ownerPID: target, kind: .pointer) == .accept)
        #expect(CapturePolicy.evaluate(recording: true, targetPID: target, frontmostPID: target, ownerPID: target, kind: .key) == .accept)
    }

    @Test func dropsWhenPausedOrNotFrontmost() {
        #expect(CapturePolicy.evaluate(recording: false, targetPID: target, frontmostPID: target, ownerPID: target, kind: .pointer) == .dropPaused)
        #expect(CapturePolicy.evaluate(recording: true, targetPID: target, frontmostPID: 77, ownerPID: target, kind: .pointer) == .dropNotFrontmost)
        #expect(CapturePolicy.evaluate(recording: true, targetPID: target, frontmostPID: nil, ownerPID: target, kind: .key) == .dropNotFrontmost)
    }

    @Test func dropsOtherOwnersAndUnverifiable() {
        // e.g. click on a floating window of another app, a notification banner, or Retrace's own menu.
        #expect(CapturePolicy.evaluate(recording: true, targetPID: target, frontmostPID: target, ownerPID: 1, kind: .pointer) == .dropOutsideTarget)
        #expect(CapturePolicy.evaluate(recording: true, targetPID: target, frontmostPID: target, ownerPID: nil, kind: .pointer) == .dropUnverified)
        #expect(CapturePolicy.evaluate(recording: true, targetPID: target, frontmostPID: target, ownerPID: 9, kind: .key) == .dropOutsideTarget)
    }

    @Test func beforeFrameAgeAndOrdering() {
        #expect(CapturePolicy.isUsableBeforeFrame(frameUptime: 10, eventUptime: 10.5))
        #expect(CapturePolicy.isUsableBeforeFrame(frameUptime: 10, eventUptime: 10))
        #expect(!CapturePolicy.isUsableBeforeFrame(frameUptime: 10.6, eventUptime: 10.5), "frame after event is not 'before'")
        #expect(!CapturePolicy.isUsableBeforeFrame(frameUptime: 5, eventUptime: 10), "stale frame")
    }

    @Test func coalescingKeepsAfterFramesAfterEvents() {
        // Two events 100 ms apart share an after-capture bucket; the shared capture time is still
        // later than both events, so after-frame ordering holds.
        let e1 = 100.00, e2 = 100.10
        let t1 = e1 + CapturePolicy.afterDelay, t2 = e2 + CapturePolicy.afterDelay
        #expect(CapturePolicy.coalescingBucket(forUptime: t1) == CapturePolicy.coalescingBucket(forUptime: t2))
        #expect(min(t1, t2) > max(e1, e2))
        #expect(CapturePolicy.settledDelay > CapturePolicy.afterDelay)
    }
}
