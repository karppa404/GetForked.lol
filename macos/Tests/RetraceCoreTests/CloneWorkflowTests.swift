import Foundation
import Testing
@testable import RetraceCore

private func clonePlan() -> ClonePlan {
    ClonePlan(title: "Notes", summary: "An observed notes app", stories: [
        CloneStory(id: "S1", title: "As a user, view notes", acceptanceCriteria: ["A list displays saved notes"], evidence: ["frame-1"])
    ], stack: ["SwiftUI for native macOS UI"], tasks: [
        CloneTask(id: "T1", title: "Scaffold", instructions: "Create a Swift package", acceptanceCriteria: ["swift build passes"], dependencies: []),
        CloneTask(id: "T2", title: "Note list", instructions: "Implement S1", acceptanceCriteria: ["List test passes"], dependencies: ["T1"])
    ], unknowns: ["Sync behavior was not observed"])
}

@Test func clonePlanRejectsInventedEvidenceAndBadTasks() throws {
    try clonePlan().validate(evidenceIDs: ["frame-1"])
    #expect(throws: (any Error).self) { try clonePlan().validate(evidenceIDs: ["other-frame"]) }
    var plan = clonePlan()
    plan.tasks[1].dependencies = ["missing"]
    #expect(throws: (any Error).self) { try plan.validate() }
    plan = clonePlan()
    plan.tasks[0].dependencies = ["T2"]
    #expect(throws: (any Error).self) { try plan.validate() }
    plan = clonePlan()
    plan.tasks[1].id = "../../escape"
    #expect(throws: (any Error).self) { try plan.validate() }
    plan = clonePlan()
    plan.stories[0].acceptanceCriteria = ["  "]
    #expect(throws: (any Error).self) { try plan.validate() }
    plan = clonePlan()
    plan.tasks[1].id = "T1"
    #expect(throws: (any Error).self) { try plan.validate() }
}

@Test func cloneRepositoryNameCannotEscapeParent() throws {
    for name in ["../escape", "/tmp/escape", "", ".git", "-option", "name space", String(repeating: "a", count: 65)] {
        #expect(throws: (any Error).self) { try ClonePlan.validateRepositoryName(name) }
    }
    try ClonePlan.validateRepositoryName("notes-clone_2")
    #expect(ClonePlan.repositoryName("My / Notes") == "my-notes-clone")
    try ClonePlan.validateRepositoryName(ClonePlan.repositoryName(String(repeating: "x", count: 100)))
}

@Test func clonePlanExportsDelegatableTasksWithoutRawEvidence() throws {
    let files = try clonePlan().files(sessionID: "session-1")
    #expect(files["tasks/T1.md"] != nil)
    #expect(files["tasks/T2.md"] != nil)
    #expect(files["AGENTS.md"] != nil)
    #expect(files["manifest.json"] == nil)
    #expect(String(decoding: files["tasks/T2.md"]!, as: UTF8.self).contains("Dependencies: T1"))
    #expect(try JSONDecoder().decode(ClonePlan.self, from: files["PLAN.json"]!) == clonePlan())
}

@Test func clonePromptExcludesHTTPSecretsAndStatesCoverage() throws {
    let manifest = SessionManifest(id: "session", app: AppInfo(name: "Notes", bundleId: "dev.notes", pid: 1), startedAt: "now", durationMs: 10,
        network: [NetworkEvent(id: "request-1", timestampMs: 3, method: "GET", url: "https://user:password@example.com/notes?token=secret#fragment", status: 200,
                               requestHeaders: ["Authorization": "header-secret"], requestBody: "body-secret")], networkStatus: .observed)
    let prompt = try CloneWorkflowEngine.prompt(manifest: manifest)
    #expect(prompt.contains("request-1 @ 3ms: GET https://example.com/notes status 200"))
    #expect(!prompt.contains("password"))
    #expect(!prompt.contains("header-secret"))
    #expect(!prompt.contains("body-secret"))
    #expect(!prompt.contains("token=secret"))
    #expect(!prompt.contains("#fragment"))
    #expect(prompt.contains("partial observational evidence"))
}

@Test func cloneRepositoryCreatesCommitAndRefusesExistingFolder() async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("retrace-clone-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: parent) }
    let repository = try await CloneWorkflowEngine.createRepository(plan: clonePlan(), sessionID: "session-1", name: "notes", parent: parent)
    #expect(FileManager.default.fileExists(atPath: repository.appendingPathComponent(".git/HEAD").path))
    let result = try await CloneCommand().run(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: ["log", "-1", "--format=%s"], directory: repository)
    #expect(result.status == 0)
    #expect(result.text.contains("Initialize reviewed clone requirements"))
    do {
        _ = try await CloneWorkflowEngine.createRepository(plan: clonePlan(), sessionID: "session-1", name: "notes", parent: parent)
        Issue.record("Existing repository was overwritten")
    } catch {}
    #expect(FileManager.default.fileExists(atPath: repository.appendingPathComponent("PLAN.json").path))
}

@Test func cloneCommandTimesOutAndSupportsCancellation() async throws {
    let directory = FileManager.default.temporaryDirectory
    do {
        _ = try await CloneCommand().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], directory: directory, timeout: 0.05)
        Issue.record("Timeout returned success")
    } catch { #expect(error.localizedDescription.contains("timed out")) }
    let running = Task {
        try await CloneCommand().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], directory: directory)
    }
    try await Task.sleep(for: .milliseconds(50))
    running.cancel()
    do {
        _ = try await running.value
        Issue.record("Running command did not cancel")
    } catch { #expect(error is CancellationError) }
    let command = CloneCommand()
    command.cancel()
    do {
        _ = try await command.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], directory: directory)
        Issue.record("Cancelled command started")
    } catch { #expect(error is CancellationError) }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["RETRACE_TEST_LIVE_CODEX"] == "1"))
func cloneLiveCodexStructuredPlan() async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("retrace-live-clone-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: parent) }
    let store = SessionStore(root: parent)
    let id = UUID().uuidString.lowercased()
    try store.createSessionDirectory(id: id)
    let fixture = try loadFixture()
    let sourceFrame = try #require(fixture.manifest.frames.first)
    let frame = try store.writeFrame(sessionId: id, frameId: UUID().uuidString.lowercased(), timestampMs: 0,
                                    data: Data(contentsOf: fixture.url(for: sourceFrame)), width: sourceFrame.width, height: sourceFrame.height, ext: "png")
    try store.save(manifest: SessionManifest(id: id, app: AppInfo(name: "Synthetic notes app", bundleId: "dev.test.notes", pid: 1),
        scanReport: "Observed a native macOS notes application. Its left list displays note titles. Clicking a title displays a read-only note detail on the right. No editing, sync, settings or account flows were tested. Only implement this observed list and detail behavior.",
        startedAt: "2026-11-16T00:00:00Z", durationMs: 1000, frames: [frame], networkStatus: .notCaptured))
    let plan = try await CloneWorkflowEngine.generate(session: store.load(id: id))
    try plan.validate(evidenceIDs: ["scan-report", frame.id])
    #expect(!plan.stories.isEmpty)
    #expect(!plan.tasks.isEmpty)
    print("Live Codex returned \(plan.stories.count) evidence-grounded stories and \(plan.tasks.count) dependency-validated tasks.")
}
