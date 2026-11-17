import Foundation
import Testing
@testable import RetraceCore

@Test func scanSetupErrorsPreserveTheirExplanation() {
    let error: Error = APIError.invalidInput("Enable Codex computer use before scanning.")
    #expect(error.localizedDescription == "Enable Codex computer use before scanning.")
}

@Test func githubReadinessRequiresInstallationAndSuccessfulAuthentication() {
    let executable = URL(fileURLWithPath: "/opt/homebrew/bin/gh")
    #expect(ToolReadiness.githubCheck(executable: nil, exitCode: 0).status == .missing)
    #expect(ToolReadiness.githubCheck(executable: executable, exitCode: nil).status == .missing)
    #expect(ToolReadiness.githubCheck(executable: executable, exitCode: 1).status == .missing)
    #expect(ToolReadiness.githubCheck(executable: executable, exitCode: 0).status == .ok)
}
