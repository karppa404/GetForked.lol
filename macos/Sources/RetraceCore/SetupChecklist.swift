import Foundation

/// One requirement on the first-run setup checklist, in display order.
public enum SetupItem: String, CaseIterable, Sendable, Identifiable {
    case codexCLI, subscription, computerUse, browser, permissions, analysis

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .codexCLI: return "Codex CLI signed in"
        case .subscription: return "ChatGPT plan with Codex"
        case .computerUse: return "Codex computer use"
        case .browser: return "Browser approved for computer use"
        case .permissions: return "Accessibility & Screen Recording"
        case .analysis: return "Nemotron analysis"
        }
    }

    /// One line on why Retrace needs it.
    public var why: String {
        switch self {
        case .codexCLI: return "Scans run through your own Codex CLI."
        case .subscription: return "Codex scans use your ChatGPT plan's Codex usage."
        case .computerUse: return "Codex explores the app with its computer-use tool."
        case .browser: return "SaaS scans drive a browser Codex may always control."
        case .permissions: return "Retrace captures clicks, keys and app-only frames."
        case .analysis: return "The built-in engine needs a Nemotron key to analyze scans."
        }
    }
}

public enum SetupStatus: Equatable, Sendable {
    case checking, ok, missing
}

public struct SetupCheck: Equatable, Sendable {
    public var status: SetupStatus
    /// What was found, or what is wrong.
    public var detail: String?

    public init(status: SetupStatus, detail: String? = nil) {
        self.status = status
        self.detail = detail
    }

    public static let checking = SetupCheck(status: .checking)
    public static func ok(_ detail: String? = nil) -> SetupCheck { SetupCheck(status: .ok, detail: detail) }
    public static func missing(_ detail: String) -> SetupCheck { SetupCheck(status: .missing, detail: detail) }
}

/// Pure parts of the setup checklist: aggregation, when to show it, and reading Codex's answers.
public enum SetupChecklist {
    /// `UserDefaults` key recording that the user pressed Continue with every item passing.
    public static let completedKey = "setupChecklistCompleted"
    /// Development escape hatch (`RETRACE_SKIP_SETUP=1`), e.g. a debug build without a bundled engine.
    public static let skipVariable = "RETRACE_SKIP_SETUP"

    public static let installCommand = "brew install --cask codex"
    public static let loginCommand = "codex login"
    public static let mcpListCommand = "codex mcp list"
    /// Prompts for the key (it never appears in shell history), then the engine can be restarted.
    public static let addKeyCommand = "security add-generic-password -U -s dev.retrace.recorder.model-api-key -a nemotron -w"

    /// Every item is present and passing.
    public static func allPassed(_ checks: [SetupItem: SetupCheck]) -> Bool {
        SetupItem.allCases.allSatisfy { checks[$0]?.status == .ok }
    }

    /// Shown when asked for, on first run, and before a scan whenever a required item has regressed.
    /// Never shown over a running scan (its controls must stay reachable); items still checking
    /// don't count as regressions.
    public static func shouldShow(_ checks: [SetupItem: SetupCheck], completed: Bool, requested: Bool,
                                  scanning: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if scanning { return false }
        if requested { return true }
        if environment[skipVariable] == "1" { return false }
        if !completed { return true }
        return checks.values.contains { $0.status == .missing }
    }

    // MARK: Codex CLI

    public enum Login: Equatable, Sendable {
        case chatGPT, apiKey
        case signedIn(String)
        case signedOut
        case failed(String)
    }

    /// Reads `codex login status` (it prints to stderr): exit 0 "Logged in using ChatGPT" /
    /// "Logged in using an API key - …", exit 1 "Not logged in".
    public static func login(exitCode: Int32, output: String) -> Login {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("not logged in") { return .signedOut }
        guard exitCode == 0, lower.contains("logged in") else {
            let line = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            return .failed(line.isEmpty ? "codex login status exited \(exitCode)" : String(line.prefix(200)))
        }
        if lower.contains("chatgpt") { return .chatGPT }
        if lower.contains("api key") { return .apiKey }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return .signedIn(String(line.prefix(200)))
    }

    /// `login` is nil when the status command didn't answer in time.
    public static func cliCheck(executable: URL?, login: Login?) -> SetupCheck {
        guard let executable else { return .missing("Codex CLI not found. Install it, or set RETRACE_CODEX_BIN.") }
        switch login {
        case nil: return .missing("codex login status didn't answer in time.")
        case .chatGPT?: return .ok("Signed in with ChatGPT · \(executable.path)")
        case .apiKey?: return .ok("Signed in with an API key · \(executable.path)")
        case .signedIn(let how)?: return .ok("\(how) · \(executable.path)")
        case .signedOut?: return .missing("Installed at \(executable.path), but not signed in.")
        case .failed(let why)?: return .missing("Couldn't read sign-in status: \(why)")
        }
    }

    // MARK: Subscription (codex app-server, no model turns)

    /// Requests sent after `initialize`: account and usage reads only, which spend no tokens.
    public static func accountRequests() -> [(method: String, params: [String: Any])] {
        [("account/read", ["refreshToken": false]), ("account/rateLimits/read", [:])]
    }

    public static func planName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw != "unknown" else { return nil }
        let names = ["free": "Free", "go": "Go", "plus": "Plus", "pro": "Pro", "prolite": "Pro Lite", "team": "Team",
                     "business": "Business", "enterprise": "Enterprise", "edu": "Edu"]
        return names[raw.lowercased()] ?? raw.capitalized
    }

    /// `account` is the `account/read` result, `rateLimits` the `account/rateLimits/read` result
    /// (nil when that read failed; usage then isn't held against the account). `error` explains a
    /// probe that never got an account answer.
    public static func subscriptionCheck(account: [String: Any]?, rateLimits: [String: Any]?, error: String? = nil) -> SetupCheck {
        guard let account else { return .missing(error ?? "Codex didn't report an account.") }
        guard let info = account["account"] as? [String: Any] else {
            return .missing("Codex isn't signed in to an account.")
        }
        guard info["type"] as? String == "chatgpt" else {
            return .missing("Codex is using an API key. Sign in with ChatGPT so scans use your plan.")
        }
        let limits = rateLimits?["rateLimits"] as? [String: Any]
        let plan = planName(info["planType"] as? String ?? limits?["planType"] as? String)
        let label = plan.map { "ChatGPT \($0)" } ?? "ChatGPT account"
        if let limits {
            let reached = limits["rateLimitReachedType"].flatMap { $0 is NSNull ? nil : $0 } != nil
                || limits["spendControlReached"] as? Bool == true
            if rateLimits?["ordinaryUsageAllowed"] as? Bool == false || reached {
                var text = "\(label): Codex usage limit reached"
                if let resets = (limits["primary"] as? [String: Any])?["resetsAt"] as? NSNumber {
                    let date = Date(timeIntervalSince1970: resets.doubleValue)
                    text += "; resets \(date.formatted(date: .abbreviated, time: .shortened))"
                }
                return .missing(text + ".")
            }
            if let used = (limits["primary"] as? [String: Any])?["usedPercent"] as? NSNumber {
                return .ok("\(label) · \(used.intValue)% of Codex usage used")
            }
        }
        return .ok(label)
    }

    // MARK: Computer use

    /// `servers` is `codex mcp list --json`; nil when it couldn't be run.
    public static func computerUseCheck(servers: Data?) -> SetupCheck {
        guard let servers else { return .missing("Couldn't run codex mcp list.") }
        do {
            _ = try CodexScan.configuration(servers: servers)
            return .ok("Enabled: \(try CodexScan.computerServers(in: servers).joined(separator: ", "))")
        } catch {
            return .missing(error.localizedDescription)
        }
    }

    // MARK: Browser

    /// `installed` maps each installed browser's bundle id to its name; `approved` is Codex computer
    /// use's "Always allow" list (nil when unreadable).
    public static func browserCheck(installed: [String: String], approved: Set<String>?) -> SetupCheck {
        guard let approved else { return .missing("No apps are approved for Codex computer use yet.") }
        let names = installed.filter { approved.contains($0.key) }.values.sorted()
        if names.isEmpty {
            return .missing(installed.isEmpty ? "No browser is installed." : "None of your browsers are approved yet.")
        }
        return .ok("Always allowed: \(names.joined(separator: ", "))")
    }

    // MARK: Permissions and analysis

    public static func permissionsCheck(accessibility: Bool, screenRecording: Bool) -> SetupCheck {
        switch (accessibility, screenRecording) {
        case (true, true): return .ok("Both granted.")
        case (false, true): return .missing("Accessibility isn't granted.")
        case (true, false): return .missing("Screen Recording isn't granted.")
        case (false, false): return .missing("Neither is granted.")
        }
    }

    /// `failure` is the engine's failure reason; `analysisConfigured` is `/health`'s answer (nil until read).
    public static func analysisCheck(serverReady: Bool, failure: String?, analysisConfigured: Bool?) -> SetupCheck {
        if let failure { return .missing("The analysis engine stopped: \(failure)") }
        guard serverReady, let configured = analysisConfigured else { return SetupCheck(status: .checking, detail: "Starting the analysis engine…") }
        return configured ? .ok("Engine running with a model key.") : .missing("The engine has no Nemotron key.")
    }
}
