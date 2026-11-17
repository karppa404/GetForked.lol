import Foundation
import Testing
@testable import RetraceCore

private func all(_ check: SetupCheck) -> [SetupItem: SetupCheck] {
    Dictionary(uniqueKeysWithValues: SetupItem.allCases.map { ($0, check) })
}

@Test func setupAllPassedNeedsEveryItemOK() {
    #expect(SetupChecklist.allPassed(all(.ok())))
    var checks = all(.ok())
    checks[.browser] = .checking
    #expect(!SetupChecklist.allPassed(checks))
    checks[.browser] = .missing("no")
    #expect(!SetupChecklist.allPassed(checks))
    checks.removeValue(forKey: .browser)
    #expect(!SetupChecklist.allPassed(checks))
    #expect(!SetupChecklist.allPassed([:]))
}

@Test func setupGateShowsOnFirstRunRegressionAndRequest() {
    let env: [String: String] = [:]
    // First run: shown even while everything still passes or checks.
    #expect(SetupChecklist.shouldShow(all(.ok()), completed: false, requested: false, scanning: false, environment: env))
    #expect(SetupChecklist.shouldShow(all(.checking), completed: false, requested: false, scanning: false, environment: env))
    // Completed: hidden unless something regressed; "checking" is not a regression.
    #expect(!SetupChecklist.shouldShow(all(.ok()), completed: true, requested: false, scanning: false, environment: env))
    #expect(!SetupChecklist.shouldShow(all(.checking), completed: true, requested: false, scanning: false, environment: env))
    var regressed = all(.ok())
    regressed[.permissions] = .missing("Screen Recording isn't granted.")
    #expect(SetupChecklist.shouldShow(regressed, completed: true, requested: false, scanning: false, environment: env))
    // Reopened from the header.
    #expect(SetupChecklist.shouldShow(all(.ok()), completed: true, requested: true, scanning: false, environment: env))
    // Never over a running scan, and skippable for development builds.
    #expect(!SetupChecklist.shouldShow(regressed, completed: false, requested: true, scanning: true, environment: env))
    #expect(!SetupChecklist.shouldShow(regressed, completed: false, requested: false, scanning: false,
                                       environment: [SetupChecklist.skipVariable: "1"]))
}

@Test func setupParsesCodexLoginStatus() {
    // Output of codex-cli 0.166 `codex login status` (printed on stderr).
    #expect(SetupChecklist.login(exitCode: 0, output: "Logged in using ChatGPT\n") == .chatGPT)
    #expect(SetupChecklist.login(exitCode: 0, output: "Logged in using an API key - sk-proj-***ABCD\n") == .apiKey)
    #expect(SetupChecklist.login(exitCode: 1, output: "Not logged in\n") == .signedOut)
    #expect(SetupChecklist.login(exitCode: 0, output: "Logged in using an access token") == .signedIn("Logged in using an access token"))
    #expect(SetupChecklist.login(exitCode: 1, output: "WARNING: x\nError loading configuration: bad toml\n")
            == .failed("Error loading configuration: bad toml"))
    #expect(SetupChecklist.login(exitCode: 2, output: "") == .failed("codex login status exited 2"))

    let bin = URL(fileURLWithPath: "/opt/homebrew/bin/codex")
    #expect(SetupChecklist.cliCheck(executable: nil, login: nil).status == .missing)
    #expect(SetupChecklist.cliCheck(executable: bin, login: nil).status == .missing)
    #expect(SetupChecklist.cliCheck(executable: bin, login: .signedOut).status == .missing)
    #expect(SetupChecklist.cliCheck(executable: bin, login: .failed("x")).status == .missing)
    #expect(SetupChecklist.cliCheck(executable: bin, login: .chatGPT) == .ok("Signed in with ChatGPT · /opt/homebrew/bin/codex"))
    #expect(SetupChecklist.cliCheck(executable: bin, login: .apiKey).status == .ok)
}

@Test func setupReadsSubscriptionFromAppServer() throws {
    func json(_ s: String) throws -> [String: Any] { try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) }
    // Shapes from codex-cli 0.166 app-server `account/read` and `account/rateLimits/read`.
    let chatgpt = try json(#"{"account":{"type":"chatgpt","email":"a@b.c","planType":"prolite"},"requiresOpenaiAuth":true}"#)
    let usage = try json(#"{"ordinaryUsageAllowed":true,"rateLimits":{"primary":{"usedPercent":8,"resetsAt":1794686839},"planType":"prolite","rateLimitReachedType":null,"spendControlReached":false}}"#)
    #expect(SetupChecklist.subscriptionCheck(account: chatgpt, rateLimits: usage) == .ok("ChatGPT Pro Lite · 8% of Codex usage used"))
    #expect(SetupChecklist.subscriptionCheck(account: chatgpt, rateLimits: nil) == .ok("ChatGPT Pro Lite"))

    let limited = try json(#"{"ordinaryUsageAllowed":false,"rateLimits":{"primary":{"usedPercent":100,"resetsAt":1794686839},"rateLimitReachedType":"primary"}}"#)
    let blocked = SetupChecklist.subscriptionCheck(account: chatgpt, rateLimits: limited)
    #expect(blocked.status == .missing)
    #expect(blocked.detail?.contains("usage limit reached; resets") == true)

    let apiKey = try json(#"{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}"#)
    #expect(SetupChecklist.subscriptionCheck(account: apiKey, rateLimits: nil).status == .missing)
    let signedOut = try json(#"{"account":null,"requiresOpenaiAuth":true}"#)
    #expect(SetupChecklist.subscriptionCheck(account: signedOut, rateLimits: nil).status == .missing)
    #expect(SetupChecklist.subscriptionCheck(account: nil, rateLimits: nil, error: "timed out") == .missing("timed out"))

    #expect(SetupChecklist.planName("plus") == "Plus")
    #expect(SetupChecklist.planName("unknown") == nil)
    #expect(SetupChecklist.planName("newtier") == "Newtier")
    #expect(SetupChecklist.accountRequests().map(\.method) == ["account/read", "account/rateLimits/read"])
}

@Test func setupChecksComputerUseBrowserPermissionsAndAnalysis() {
    let enabled = Data(#"[{"name":"cua_repl","enabled":true,"transport":{"type":"stdio","command":"/bin/tool"}},{"name":"computer-use","enabled":false}]"#.utf8)
    #expect(SetupChecklist.computerUseCheck(servers: enabled) == .ok("Enabled: cua_repl"))
    #expect(SetupChecklist.computerUseCheck(servers: Data(#"[{"name":"computer-use","enabled":false}]"#.utf8)).status == .missing)
    #expect(SetupChecklist.computerUseCheck(servers: nil).status == .missing)

    let browsers = ["com.apple.Safari": "Safari", "net.imput.helium": "Helium", "com.google.Chrome": "Google Chrome"]
    #expect(SetupChecklist.browserCheck(installed: browsers, approved: ["net.imput.helium", "com.apple.finder"])
            == .ok("Always allowed: Helium"))
    #expect(SetupChecklist.browserCheck(installed: browsers, approved: ["com.apple.finder"]).status == .missing)
    #expect(SetupChecklist.browserCheck(installed: browsers, approved: nil).status == .missing)
    #expect(SetupChecklist.browserCheck(installed: [:], approved: ["net.imput.helium"]).status == .missing)

    #expect(SetupChecklist.permissionsCheck(accessibility: true, screenRecording: true).status == .ok)
    #expect(SetupChecklist.permissionsCheck(accessibility: true, screenRecording: false).status == .missing)
    #expect(SetupChecklist.permissionsCheck(accessibility: false, screenRecording: true).status == .missing)

    #expect(SetupChecklist.analysisCheck(serverReady: false, failure: nil, analysisConfigured: nil).status == .checking)
    #expect(SetupChecklist.analysisCheck(serverReady: true, failure: nil, analysisConfigured: nil).status == .checking)
    #expect(SetupChecklist.analysisCheck(serverReady: true, failure: nil, analysisConfigured: true).status == .ok)
    #expect(SetupChecklist.analysisCheck(serverReady: true, failure: nil, analysisConfigured: false).status == .missing)
    #expect(SetupChecklist.analysisCheck(serverReady: false, failure: "Engine not bundled", analysisConfigured: nil).status == .missing)
}
