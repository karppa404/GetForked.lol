import Combine
import Foundation
import RetraceCore

@MainActor
final class ToolReadinessModel: ObservableObject {
    @Published private(set) var codex: SetupCheck = .checking
    @Published private(set) var github: SetupCheck = .checking
    @Published private(set) var computerUse: SetupCheck = .checking
    @Published private(set) var isChecking = false

    init() { refresh() }

    func refresh() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            async let codexResult = ToolReadiness.checkCodex()
            async let githubResult = ToolReadiness.checkGitHub()
            async let computerResult = ToolReadiness.checkComputerUse()
            (codex, github, computerUse) = await (codexResult, githubResult, computerResult)
            isChecking = false
        }
    }
}
