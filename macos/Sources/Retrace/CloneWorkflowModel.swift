import Combine
import Foundation
import RetraceCore

/// The new four-stage workflow uses local scan evidence and the signed-in Codex CLI directly.
@MainActor
final class CloneWorkflowModel: ObservableObject {
    @Published var stage: CloneStage = .select
    @Published private(set) var session: LocalSession?
    @Published private(set) var plan: ClonePlan?
    @Published private(set) var isWorking = false
    @Published private(set) var status = "Choose an application to begin."
    @Published var error: String?
    @Published private(set) var repositoryURL: URL?
    @Published var repositoryName = "app-clone"
    @Published var requirementsApproved = false
    private var work: Task<Void, Never>?

    func acceptScan(_ session: LocalSession) {
        guard !isWorking else { return }
        self.session = session
        plan = nil
        repositoryURL = nil
        requirementsApproved = false
        repositoryName = ClonePlan.repositoryName(session.manifest.app.name)
        stage = .requirements
        error = nil
        status = "Evidence saved. Review it before generating requirements."
    }

    func generateRequirements() {
        guard !isWorking, let session else { return }
        isWorking = true
        error = nil
        requirementsApproved = false
        status = "Codex is turning captured evidence into user stories, requirements and build tasks…"
        work = Task {
            defer { isWorking = false; work = nil }
            do {
                let result = try await CloneWorkflowEngine.generate(session: session)
                try Task.checkCancellation()
                let data = try JSONEncoder().encode(result)
                let path = session.directory.appendingPathComponent("clone-plan.json")
                try data.write(to: path, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                plan = result
                repositoryURL = nil
                stage = .requirements
                status = "Review \(result.stories.count) user stories and \(result.tasks.count) build tasks."
            } catch is CancellationError {
                status = "Generation cancelled. Your scan evidence is still saved."
            } catch {
                self.error = error.localizedDescription
                status = "Requirements could not be generated."
            }
        }
    }

    func createRepository(at parent: URL) {
        guard !isWorking, requirementsApproved, let plan, let session else { return }
        isWorking = true
        error = nil
        stage = .build
        status = "Creating a local Git repository with the approved requirements and task prompts…"
        let name = repositoryName
        work = Task {
            defer { isWorking = false; work = nil }
            do {
                let url = try await CloneWorkflowEngine.createRepository(plan: plan, sessionID: session.id, name: name, parent: parent)
                repositoryURL = url
                status = "Repository ready. Send the prompts in tasks/ to your coding agents."
            } catch is CancellationError {
                status = "Repository creation cancelled."
            } catch {
                self.error = error.localizedDescription
                status = "The repository could not be created."
            }
        }
    }

    func cancel() {
        guard isWorking else { return }
        status = "Stopping…"
        work?.cancel()
    }

    func reset() {
        guard !isWorking else { return }
        stage = .select
        session = nil
        plan = nil
        repositoryURL = nil
        requirementsApproved = false
        repositoryName = "app-clone"
        error = nil
        status = "Choose an application to begin."
    }
}
