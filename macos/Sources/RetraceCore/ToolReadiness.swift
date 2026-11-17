import Foundation

/// Checks installed command-line tools without reading or displaying their credentials.
public enum ToolReadiness {
    public static func githubExecutable(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let paths = [environment["RETRACE_GH_BIN"], "/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
            .compactMap { $0 } + (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/gh" }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public static func githubCheck(executable: URL?, exitCode: Int32?) -> SetupCheck {
        guard let executable else { return .missing("GitHub CLI is not installed. Run brew install gh in Terminal.") }
        guard let exitCode else { return .missing("GitHub sign-in check did not finish. Check your connection and try again.") }
        guard exitCode == 0 else { return .missing("GitHub CLI is installed, but github.com sign-in could not be verified. Run gh auth login.") }
        return .ok("Signed in to github.com · \(executable.path)")
    }

    public static func checkGitHub() async -> SetupCheck {
        let executable = githubExecutable()
        guard let executable else { return githubCheck(executable: nil, exitCode: nil) }
        let result = try? await CloneCommand().run(executable: executable,
            arguments: ["auth", "status", "--active", "--hostname", "github.com"],
            directory: FileManager.default.temporaryDirectory, timeout: 15)
        return githubCheck(executable: executable, exitCode: result?.status)
    }

    public static func checkCodex() async -> SetupCheck {
        let executable = CodexScan.executable()
        guard let executable else { return SetupChecklist.cliCheck(executable: nil, login: nil) }
        let result = try? await CloneCommand().run(executable: executable, arguments: ["login", "status"],
            directory: FileManager.default.temporaryDirectory, timeout: 15)
        let login = result.map { SetupChecklist.login(exitCode: $0.status, output: $0.text) }
        return SetupChecklist.cliCheck(executable: executable, login: login)
    }

    public static func checkComputerUse() async -> SetupCheck {
        guard let executable = CodexScan.executable() else { return .missing("Install Codex first, then enable its computer-use MCP.") }
        let result = try? await CloneCommand().run(executable: executable, arguments: ["mcp", "list", "--json"],
            directory: FileManager.default.temporaryDirectory, timeout: 20)
        return SetupChecklist.computerUseCheck(servers: result.flatMap { $0.status == 0 ? Data($0.text.utf8) : nil })
    }
}
