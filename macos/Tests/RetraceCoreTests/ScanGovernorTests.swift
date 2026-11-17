import Foundation
import Testing
@testable import RetraceCore

private func call(_ title: String?, code: String = "await app.screenshot()", failed: Bool = false, result: String = "") -> ScanToolCall {
    var item: [String: Any] = ["type": "mcpToolCall", "tool": "js", "status": failed ? "failed" : "completed",
                               "arguments": ["title": title as Any, "code": code].compactMapValues { $0 is NSNull ? nil : $0 }]
    if !result.isEmpty { item["result"] = ["content": [["type": "text", "text": result]]] }
    return ScanToolCall(item: item)
}

@Test func toolCallSignatureIgnoresTitleAndWhitespace() {
    let a = call("Click Play", code: "await app.click({ id: 42 })")
    let b = call("Retry clicking Play", code: "await  app.click({ id: 42 })")
    #expect(a.signature == b.signature)
    #expect(a.signature != call("Click Play", code: "await app.click({ id: 43 })").signature)
    #expect(call("x", failed: true).failed)
    let withResult = call("Open", result: "Address bar: https://example.com/board")
    #expect(withResult.text.contains("example.com/board"))
}

@Test func coverageFindsPageURLsOnTheScanHostOnly() {
    let text = "now at scrabblebot.spacetimedb.com/leaderboard?x=1 and https://SCRABBLEBOT.spacetimedb.com/rules/ via https://cdn.other.com/a.js"
    #expect(ScanCoverage.pageURLs(in: text, host: "scrabblebot.spacetimedb.com")
        == ["scrabblebot.spacetimedb.com/leaderboard", "scrabblebot.spacetimedb.com/rules"])
    #expect(ScanCoverage.pageURLs(in: "evil-scrabblebot.spacetimedb.com/x", host: "scrabblebot.spacetimedb.com").isEmpty)
    #expect(ScanCoverage.pageURLs(in: "see https://a.com/x#/settings.", host: nil) == ["a.com/x#/settings"])
    #expect(ScanCoverage.featureWords("Clicking the Leaderboard tab again") == ["leaderboard"])
    #expect(ScanCoverage.featureWords("Opened Settings; checking Settings") == ["sett"])
    #expect(ScanCoverage.featureWords("Navigating back and taking a screenshot").isEmpty)
}

@Test func coverageSaturatesAfterStallButNotWhileDiscovering() {
    var coverage = ScanCoverage(host: "example.com")
    let features = ["Board", "Leaderboard", "Rules", "Settings", "Profile", "History", "Lobby", "Chat", "Tiles", "Dictionary", "Scores", "Help"]
    for (i, feature) in features.enumerated() {
        do { let r = coverage.observe(call("Open \(feature)", code: "nav(\(i))")); #expect(r) }
    }
    #expect(coverage.saturation == nil)
    // Re-checking covered pages with varied wording and actions finds nothing new.
    for i in 0..<7 {
        do { let r = coverage.observe(call("Check the \(features[i]) page again", code: "look(\(i))")); #expect(!r) }
        #expect(coverage.saturation == nil)
    }
    coverage.observe(call("Verify Rules", code: "look(99)"))
    #expect(coverage.saturation == .noNewCoverage(steps: 8))
    // A new route resets the stall.
    coverage.observe(call(nil, code: "nav()", result: "https://example.com/admin"))
    #expect(coverage.saturation == nil)
    #expect(coverage.callsSinceNovelty == 0)
}

@Test func coverageStallWaitsForMinimumCallsAndCommentaryURLsCount() {
    var coverage = ScanCoverage(host: "example.com")
    for i in 0..<10 { coverage.observe(call(nil, code: "wait(\(i))")) }
    #expect(coverage.callsSinceNovelty == 10)
    #expect(coverage.saturation == nil) // fewer than 12 calls
    coverage.observe(commentary: "Reached example.com/billing; pending: Team, Export")
    #expect(coverage.callsSinceNovelty == 0)
    coverage.observe(commentary: "Back on example.com/billing")
    for i in 0..<8 { coverage.observe(call(nil, code: "wait(\(i + 20))")) }
    #expect(coverage.saturation == .noNewCoverage(steps: 8))
}

@Test func coverageDetectsRetriedActionsAndFailureStreaks() {
    var coverage = ScanCoverage()
    coverage.observe(call("Open Play dialog", code: "click(42)"))
    // The same failing element retried: failures are never novel.
    for _ in 0..<2 { coverage.observe(call("Click Play", code: "click(42)", failed: true)) }
    #expect(coverage.saturation == nil)
    coverage.observe(call("Click Play once more", code: "click(42)", failed: true))
    #expect(coverage.saturation == .repeatedAction(times: 3))

    var failing = ScanCoverage()
    for i in 0..<4 { failing.observe(call("Step \(i)", code: "do(\(i))", failed: true)) }
    #expect(failing.saturation == nil)
    failing.observe(call("Step 5", code: "do(5)", failed: true))
    #expect(failing.saturation == .repeatedFailures(count: 5))
    failing.observe(call("Board", code: "do(6)"))
    #expect(failing.saturation == nil)

    // Repeating a harmless action between discoveries is not a loop.
    var alternating = ScanCoverage()
    for feature in ["Alpha", "Bravo", "Charlie", "Delta"] {
        alternating.observe(call("Open \(feature)", code: "nav('\(feature)')"))
        alternating.observe(call(nil))
    }
    #expect(alternating.saturation == nil)
}

@Test func budgetSteersAtEightyPercentThenStops() {
    let budget = ScanBudget()
    #expect(budget.softSteps == 64)
    #expect(budget.softSeconds == 480)
    let t0 = Date(timeIntervalSince1970: 0)
    var governor = ScanGovernor(started: t0)
    for i in 0..<63 {
        do { let r = governor.observe(call("Feature\(i)", code: "f(\(i))", result: "https://x.dev/p\(i)"), now: t0 + 1); #expect(r == .none) }
    }
    guard case .steer(let text) = governor.observe(call("Feature63", code: "f(63)"), now: t0 + 2) else {
        Issue.record("expected a wrap-up steer at 64 steps"); return
    }
    #expect(text.contains("Retrace scan control"))
    #expect(text.contains("64 of 80 steps"))
    #expect(governor.isWrappingUp)
    do { let r = governor.requestWrapUp(now: t0 + 3); #expect(r == .none) } // already wrapping up
    for i in 0..<5 { #expect(governor.observe(call("Last\(i)", code: "g(\(i))"), now: t0 + 4) == .none) }
    do { let r = governor.observe(call("Last5", code: "g(5)"), now: t0 + 5); #expect(r == .interrupt) } // grace of 6 steps used
    do { let r = governor.tick(now: t0 + 10); #expect(r == .none) }
    do { let r = governor.tick(now: t0 + 15); #expect(r == .terminate) } // interrupt never landed
    #expect(governor.endReason(cancelled: false, failure: nil) == .budget("the step budget is nearly spent (64 of 80 steps)"))
}

@Test func timeBudgetAndInterruptGetAReportOnlyTurn() {
    let t0 = Date(timeIntervalSince1970: 0)
    var governor = ScanGovernor(started: t0)
    do { let r = governor.tick(now: t0 + 479); #expect(r == .none) }
    guard case .steer(let text) = governor.tick(now: t0 + 480) else { Issue.record("expected a time steer"); return }
    #expect(text.contains("8 of 10 minutes"))
    do { let r = governor.tick(now: t0 + 569); #expect(r == .none) }
    do { let r = governor.tick(now: t0 + 570); #expect(r == .interrupt) } // 90 s grace
    guard case .startReportTurn(let report) = governor.turnCompleted(status: "interrupted", hasReport: false, now: t0 + 572) else {
        Issue.record("expected a report-only turn"); return
    }
    #expect(report.contains("Do not call any tools"))
    do { let r = governor.toolStarted(); #expect(r == .terminate) } // acting during the report turn stops the scan
    #expect(governor.phase == .finished)

    var reported = ScanGovernor(started: t0)
    _ = reported.tick(now: t0 + 480)
    _ = reported.tick(now: t0 + 570)
    do { let r = reported.turnCompleted(status: "interrupted", hasReport: true, now: t0 + 571); #expect(r == .terminate) }

    var timedOut = ScanGovernor(started: t0)
    _ = timedOut.tick(now: t0 + 480); _ = timedOut.tick(now: t0 + 570)
    _ = timedOut.turnCompleted(status: "interrupted", hasReport: false, now: t0 + 571)
    do { let r = timedOut.tick(now: t0 + 660); #expect(r == .none) }
    do { let r = timedOut.tick(now: t0 + 661); #expect(r == .terminate) } // report turn limited to 90 s
}

@Test func saturationAndUserWrapUpSteerAndRecordWhyTheScanEnded() {
    let t0 = Date(timeIntervalSince1970: 0)
    var governor = ScanGovernor(coverage: ScanCoverage(host: "example.com"), started: t0)
    let features = ["Board", "Leaderboard", "Rules", "Settings", "Profile", "History", "Lobby", "Chat", "Tiles", "Dictionary", "Scores", "Help"]
    for (i, feature) in features.enumerated() {
        do { let r = governor.observe(call(feature, code: "f(\(i))"), now: t0 + 10); #expect(r == .none) }
    }
    var action = ScanGovernor.Action.none
    for i in 0..<8 {
        #expect(action == .none)
        action = governor.observe(call("Recheck \(features[i])", code: "r(\(i))"), now: t0 + 20)
    }
    guard case .steer(let text) = action else { Issue.record("expected a saturation steer"); return }
    #expect(text.contains("coverage saturated"))
    do { let r = governor.turnCompleted(status: "completed", hasReport: true, now: t0 + 30); #expect(r == .terminate) }
    guard case .saturated = governor.endReason(cancelled: false, failure: nil) else { Issue.record("expected saturated"); return }
    #expect(governor.endReason(cancelled: true, failure: nil) == .userStopped)
    #expect(governor.endReason(cancelled: false, failure: "boom") == .error("boom"))

    var user = ScanGovernor(started: t0)
    guard case .steer(let userText) = user.requestWrapUp(now: t0 + 5) else { Issue.record("expected a user steer"); return }
    #expect(userText.contains("user asked to wrap up"))
    do { let r = user.steerFailed(now: t0 + 6); #expect(r == .interrupt) }
    #expect(user.endReason(cancelled: false, failure: nil) == .userWrapUp)
    #expect(user.endReason(cancelled: false, failure: nil).label == "user wrap-up")

    var natural = ScanGovernor(started: t0)
    _ = natural.observe(call("Board"), now: t0 + 1)
    do { let r = natural.turnCompleted(status: "completed", hasReport: true, now: t0 + 2); #expect(r == .terminate) }
    #expect(natural.endReason(cancelled: false, failure: nil) == .agentFinished)
}

@Test func steerAndInterruptMatchAppServerSchema() {
    // Shapes from `codex app-server generate-json-schema` (TurnSteerParams, TurnInterruptParams).
    let steer = CodexScan.steerParams(threadId: "t", turnId: "u", text: "wrap up")
    #expect(Set(steer.keys) == ["threadId", "expectedTurnId", "input"])
    #expect(steer["expectedTurnId"] as? String == "u")
    #expect((steer["input"] as? [[String: String]]) == [["type": "text", "text": "wrap up"]])
    #expect(CodexScan.interruptParams(threadId: "t", turnId: "u") as? [String: String] == ["threadId": "t", "turnId": "u"])
    let started = CodexScan.event(method: "turn/started", params: ["turn": ["id": "turn-1"]])
    #expect(started?.turnID == "turn-1")
    #expect(CodexScan.event(method: "item/started", params: ["item": ["type": "mcpToolCall"]])?.toolStarted == true)
    #expect(CodexScan.event(method: "item/started", params: ["item": ["type": "agentMessage"]]) == nil)
    let commentary = CodexScan.event(method: "item/completed", params: ["item": ["type": "agentMessage", "phase": "commentary", "text": "at example.com/x"]])
    #expect(commentary?.commentary == "at example.com/x")
    let tool = CodexScan.event(method: "item/completed", params: ["item": ["type": "mcpToolCall", "status": "completed", "tool": "js", "arguments": ["title": "Open"]]])
    #expect(tool?.tool?.title == "Open")
    let prompt = CodexScan.prompt(name: "App", bundleID: "dev.test", pid: 1)
    #expect(prompt.contains("pending-branches list is empty"))
    #expect(prompt.contains("80 actions or\n10 minutes") || prompt.contains("80 actions or"))
    #expect(prompt.contains("Retrace scan control"))
}
