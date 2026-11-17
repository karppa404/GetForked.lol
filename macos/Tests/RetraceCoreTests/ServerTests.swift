import Foundation
import Testing
@testable import RetraceCore

@Suite("Engine ready line")
struct ReadyLineTests {
    @Test func parsesReadyLine() throws {
        let r = try #require(ServerReady(line: #"RETRACE_READY {"port":53121,"version":"0.4.0"}"#))
        #expect(r.port == 53121 && r.version == "0.4.0")
        #expect(r.baseURL.description == "http://127.0.0.1:53121")
        #expect(ServerReady(line: "  RETRACE_READY {\"port\": 8000}\n")?.version == nil)
    }

    @Test func rejectsOtherLines() {
        for bad in ["", "INFO started", "RETRACE_READY", "RETRACE_READY {}", #"RETRACE_READY {"port":0}"#,
                    #"RETRACE_READY {"port":70000}"#, #"RETRACE_READY {"port":"80"}"#, #"retrace_ready {"port":80}"#,
                    #"xRETRACE_READY {"port":80}"#, "RETRACE_READY not json"] {
            #expect(ServerReady(line: bad) == nil, "\(bad)")
        }
    }
}

@Suite("Supervisor policy and diagnostics")
struct PolicyTests {
    @Test func backoffDoublesThenGivesUp() {
        let p = SupervisorPolicy(maxQuickRetries: 3, baseDelay: .milliseconds(500), maxDelay: .seconds(4))
        #expect(p.retryDelay(afterFailures: 1) == .milliseconds(500))
        #expect(p.retryDelay(afterFailures: 2) == .seconds(1))
        #expect(p.retryDelay(afterFailures: 3) == .seconds(2))
        #expect(p.retryDelay(afterFailures: 4) == nil)
        #expect(p.retryDelay(afterFailures: 0) == nil)
        let capped = SupervisorPolicy(maxQuickRetries: 10, baseDelay: .seconds(1), maxDelay: .seconds(3))
        #expect(capped.retryDelay(afterFailures: 5) == .seconds(3))
    }

    @Test func splitsLinesAcrossChunks() {
        let l = LineSplitter()
        #expect(l.feed(Data("RETRACE_RE".utf8)).isEmpty)
        #expect(l.feed(Data("ADY {\"port\":1}\r\nlog one\nlog".utf8)) == [#"RETRACE_READY {"port":1}"#, "log one"])
        #expect(l.finish() == "log")
        #expect(l.finish() == nil)
    }

    @Test func redactsSecrets() {
        let r = DiagnosticRedactor.self
        #expect(!r.redact("using key my-secret-value now", secrets: ["my-secret-value"]).contains("my-secret-value"))
        #expect(r.redact("Bearer abc.def-123") == "Bearer ‹redacted›")
        #expect(!r.redact("Authorization: Bearer abc.def-123").contains("abc.def"))
        #expect(!r.redact(#"{"api_key": "hunter22"}"#).contains("hunter22"))
        #expect(!r.redact("RETRACE_LLM_API_KEY=xyz123").contains("xyz123"))
        #expect(!r.redact("got nvapi-AbCdEf123456 from env").contains("AbCdEf123456"))
        #expect(!r.redact("device rtd_0123456789abcdef").contains("0123456789abcdef"))
        #expect(r.redact("INFO Uvicorn running on 127.0.0.1") == "INFO Uvicorn running on 127.0.0.1")
        #expect(r.redact(String(repeating: "a", count: 2000)).count == 500)
    }
}

@Suite("Engine launch configuration")
struct LaunchConfigTests {
    let dataDir = URL(fileURLWithPath: "/tmp/retrace-test-data")
    let inherited = ["HOME": "/Users/me", "PATH": "/opt/homebrew/bin:/usr/bin", "LANG": "en_US.UTF-8", "LC_ALL": "C",
                     "RETRACE_LLM_API_KEY": "leaked", "OPENAI_API_KEY": "leaked", "NVIDIA_API_KEY": "leaked",
                     "RETRACE_SERVER_URL": "http://127.0.0.1:8000", "RETRACE_STATE_BACKEND": "spacetimedb"]

    @Test func environmentCarriesKeyFilePathNeverTheKey() {
        let keyFile = dataDir.appendingPathComponent("llm.key")
        let env = ServerEnvironment.make(inherited: inherited, dataDir: dataDir, settings: ModelSettings(), apiKeyFile: keyFile)
        #expect(env["RETRACE_EMBEDDED"] == "1" && env["RETRACE_PORT"] == "0")
        #expect(env["RETRACE_DATA_DIR"] == dataDir.path)
        #expect(env["RETRACE_LLM_PROVIDER"] == "openai_compatible")
        #expect(env["RETRACE_LLM_BASE_URL"] == ModelSettings.defaultEndpoint)
        #expect(env["RETRACE_LLM_MODEL"] == "nvidia/NVIDIA-Nemotron-Nano-9B-v2")
        #expect(env["RETRACE_LLM_VISION"] == "0")
        #expect(env["RETRACE_LLM_API_KEY_FILE"] == keyFile.path)
        #expect(env["RETRACE_LLM_API_KEY"] == nil && env["OPENAI_API_KEY"] == nil && env["NVIDIA_API_KEY"] == nil)
        #expect(!env.values.contains("leaked"))
        #expect(env["RETRACE_SERVER_URL"] == nil && env["RETRACE_STATE_BACKEND"] == nil, "stray RETRACE_* overrides are dropped")
        #expect(env["HOME"] == "/Users/me" && env["LANG"] == "en_US.UTF-8" && env["LC_ALL"] == "C")
        #expect(env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func noKeyMeansNoKeyFileVariable() {
        let env = ServerEnvironment.make(inherited: [:], dataDir: dataDir, settings: ModelSettings(vision: true), apiKeyFile: nil)
        #expect(env["RETRACE_LLM_API_KEY_FILE"] == nil)
        #expect(env["RETRACE_LLM_VISION"] == "1")
    }

    @Test func offlineDemoSelectsHeuristicProvider() {
        let env = ServerEnvironment.make(inherited: [:], dataDir: dataDir, settings: ModelSettings(offlineDemo: true),
                                         apiKeyFile: dataDir.appendingPathComponent("llm.key"))
        #expect(env["RETRACE_LLM_PROVIDER"] == "offline_heuristic")
        #expect(env["RETRACE_LLM_BASE_URL"] == nil && env["RETRACE_LLM_API_KEY_FILE"] == nil)
    }

    @Test func emptyEndpointAndModelAreOmitted() {
        let env = ServerEnvironment.make(inherited: [:], dataDir: dataDir, settings: ModelSettings(endpoint: " ", model: ""), apiKeyFile: nil)
        #expect(env["RETRACE_LLM_BASE_URL"] == nil && env["RETRACE_LLM_MODEL"] == nil)
    }

    @Test func secretFileIsOwnerOnly() throws {
        let dir = try tempDir()
        let f = dir.appendingPathComponent("llm.key")
        try "old".write(to: f, atomically: true, encoding: .utf8)
        try ServerEnvironment.writeSecretFile("nvapi-test", to: f)
        #expect(try String(contentsOf: f, encoding: .utf8) == "nvapi-test")
        let perms = try FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600)
    }

    @Test func locationPrecedence() throws {
        let res = URL(fileURLWithPath: "/App/Contents/Resources")
        let bundled = res.appendingPathComponent("retrace-server/retrace-server")
        let yes: (URL) -> Bool = { _ in true }, no: (URL) -> Bool = { _ in false }
        #expect(ServerLocation.resolve(environment: [:], resources: res, isExecutable: yes) == .binary(bundled))
        #expect(ServerLocation.resolve(environment: ["RETRACE_SERVER_URL": "http://127.0.0.1:8000"], resources: res, isExecutable: yes)
                == .external(try APIBaseURL("http://127.0.0.1:8000")))
        #expect(ServerLocation.resolve(environment: ["RETRACE_SERVER_URL": "http://127.0.0.1:8000", "RETRACE_SERVER_BIN": "/opt/x"], resources: res, isExecutable: yes)
                == .external(try APIBaseURL("http://127.0.0.1:8000")))
        #expect(ServerLocation.resolve(environment: ["RETRACE_SERVER_BIN": "/opt/x"], resources: res, isExecutable: yes)
                == .binary(URL(fileURLWithPath: "/opt/x")))
        if case .missing = ServerLocation.resolve(environment: [:], resources: res, isExecutable: no) {} else { Issue.record("expected missing") }
        if case .missing = ServerLocation.resolve(environment: ["RETRACE_SERVER_URL": "https://example.com"], resources: res, isExecutable: yes) {} else {
            Issue.record("non-loopback override must be refused")
        }
    }

    @Test func healthDecoding() throws {
        let body = #"{"status":"ok","version":"0.4.0","embedded":true,"analysis":{"provider":null,"configured":false,"vision_enabled":false}}"#
        let h = try ManifestCoding.decoder().decode(ServerHealth.self, from: Data(body.utf8))
        #expect(!h.analysisConfigured && h.embedded == true && h.analysis?.visionEnabled == false)
        let offline = try ManifestCoding.decoder().decode(ServerHealth.self, from: Data(#"{"analysis":{"provider":"offline_heuristic","configured":true}}"#.utf8))
        #expect(offline.analysisConfigured && offline.isOfflineDemo)
        let old = try ManifestCoding.decoder().decode(ServerHealth.self, from: Data(#"{"status":"ok"}"#.utf8))
        #expect(old.analysisConfigured)
    }

    @Test func embeddedCredentialIsKeyedByIdentityNotPort() throws {
        let store = InMemoryCredentialStore()
        let issued = credential(base: "http://127.0.0.1:53121")
        try store.save(issued.bound(to: DeviceCredential.embeddedServerKey))
        let next = try #require(try store.load(apiBaseURL: DeviceCredential.embeddedServerKey)).bound(to: "http://127.0.0.1:61000")
        #expect(next.deviceToken == issued.deviceToken && next.apiBaseURL == "http://127.0.0.1:61000")
        #expect(try store.load(apiBaseURL: "http://127.0.0.1:53121") == nil)
        _ = try WorkspaceClient(client: APIClient(baseURL: try APIBaseURL("http://127.0.0.1:61000")), credential: next)
    }
}

// MARK: - Supervisor with fake engines (tiny shell scripts)

func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("retrace-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

func script(_ body: String, in dir: URL, name: String = "engine.sh") throws -> URL {
    let f = dir.appendingPathComponent(name)
    try ("#!/bin/sh\n" + body + "\n").write(to: f, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
    return f
}

@MainActor
func eventually(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}

func processAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

let fastPolicy = SupervisorPolicy(readyTimeout: .seconds(5), maxQuickRetries: 3, baseDelay: .milliseconds(10),
                                  maxDelay: .milliseconds(40), stableAfter: .seconds(30), terminateGrace: .milliseconds(400))

@Suite("Server supervisor", .serialized)
@MainActor
struct SupervisorTests {
    @Test func becomesReadyPassesEnvironmentAndStopsOnStdinEOF() async throws {
        let dir = try tempDir()
        let envOut = dir.appendingPathComponent("env.txt")
        let keyFile = dir.appendingPathComponent("llm.key")
        try "nvapi-secret".write(to: keyFile, atomically: true, encoding: .utf8)
        // Like the real engine: one ready line, logs on stderr, exit on stdin EOF.
        let bin = try script("""
        env > "\(envOut.path)"
        echo "starting with nvapi-secret" >&2
        echo 'RETRACE_READY {"port":45678,"version":"t1"}'
        cat > /dev/null
        echo "stdin closed" >&2
        """, in: dir)
        var states: [ServerState] = []
        let sup = ServerSupervisor(policy: fastPolicy) {
            ServerLaunchSpec(executable: bin, environment: ["RETRACE_EMBEDDED": "1", "RETRACE_LLM_API_KEY_FILE": keyFile.path],
                             transientFiles: [keyFile], secrets: ["nvapi-secret"])
        }
        sup.onStateChange = { states.append($0) }
        sup.start()
        #expect(await eventually { sup.state.baseURL != nil })
        #expect(sup.state.baseURL?.description == "http://127.0.0.1:45678")
        if case .ready(let r) = sup.state { #expect(r.version == "t1") }
        #expect(states.first == .starting)
        let env = try String(contentsOf: envOut, encoding: .utf8)
        #expect(env.contains("RETRACE_LLM_API_KEY_FILE=\(keyFile.path)") && !env.contains("RETRACE_LLM_API_KEY="))
        #expect(!FileManager.default.fileExists(atPath: keyFile.path), "key file is removed once the engine is ready")
        #expect(await eventually { !sup.diagnostics.isEmpty })
        #expect(sup.diagnostics.allSatisfy { !$0.contains("nvapi-secret") })
        let pid = try #require(sup.pid)
        await sup.stop()
        #expect(sup.state == .stopped && !sup.isRunning)
        #expect(await eventually { !processAlive(pid) })
        #expect(sup.launchCount == 1, "a requested stop is not restarted")
    }

    @Test func crashLoopRetriesWithBackoffThenFails() async throws {
        let dir = try tempDir()
        let bin = try script("echo 'configuration error: RETRACE_LLM_BASE_URL must use https' >&2\nexit 2", in: dir)
        let sup = ServerSupervisor(policy: fastPolicy) { ServerLaunchSpec(executable: bin, environment: [:]) }
        sup.start()
        #expect(await eventually { if case .failed = sup.state { return true } else { return false } })
        #expect(sup.launchCount == 1 + fastPolicy.maxQuickRetries)
        guard case .failed(let reason) = sup.state else { return }
        #expect(reason.contains("exit code 2") && reason.contains("must use https"))
        // Retry starts over with a fresh retry budget.
        sup.start()
        #expect(await eventually { sup.launchCount == 2 * (1 + fastPolicy.maxQuickRetries) })
        #expect(await eventually { if case .failed = sup.state { return true } else { return false } })
    }

    @Test func unexpectedExitAfterReadyRestarts() async throws {
        let dir = try tempDir()
        let counter = dir.appendingPathComponent("runs")
        // First run: ready, then crashes. Later runs: ready on a new port and stay up.
        let bin = try script("""
        n=$(cat "\(counter.path)" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "\(counter.path)"
        echo "RETRACE_READY {\\"port\\":$((40000+n))}"
        if [ "$n" = 1 ]; then sleep 0.2; exit 1; fi
        cat > /dev/null
        """, in: dir)
        var states: [ServerState] = []
        let sup = ServerSupervisor(policy: fastPolicy) { ServerLaunchSpec(executable: bin, environment: [:]) }
        sup.onStateChange = { states.append($0) }
        sup.start()
        #expect(await eventually { sup.state.baseURL?.description == "http://127.0.0.1:40002" })
        #expect(sup.launchCount == 2)
        #expect(states.compactMap(\.baseURL).map(\.description) == ["http://127.0.0.1:40001", "http://127.0.0.1:40002"])
        #expect(states.contains(.starting))
        sup.terminateNow()
        #expect(sup.state == .stopped)
    }

    @Test func readyTimeoutKillsAndFails() async throws {
        let dir = try tempDir()
        let bin = try script("trap '' TERM\nwhile true; do sleep 0.05; done", in: dir)
        var policy = fastPolicy
        policy.readyTimeout = .milliseconds(300)
        policy.maxQuickRetries = 0
        let sup = ServerSupervisor(policy: policy) { ServerLaunchSpec(executable: bin, environment: [:]) }
        sup.start()
        let pid = try #require(sup.pid)
        #expect(await eventually { if case .failed = sup.state { return true } else { return false } })
        if case .failed(let reason) = sup.state { #expect(reason.contains("didn't start")) }
        #expect(!processAlive(pid), "a process ignoring SIGTERM is killed after the grace period")
    }

    @Test func stopEscalatesToSIGKILL() async throws {
        let dir = try tempDir()
        let bin = try script("trap '' TERM\necho 'RETRACE_READY {\"port\":45001}'\nwhile true; do sleep 0.05; done", in: dir)
        let sup = ServerSupervisor(policy: fastPolicy) { ServerLaunchSpec(executable: bin, environment: [:]) }
        sup.start()
        #expect(await eventually { sup.state.baseURL != nil })
        let pid = try #require(sup.pid)
        let started = ContinuousClock.now
        await sup.stop()
        #expect(!processAlive(pid))
        #expect(ContinuousClock.now - started >= .milliseconds(350))
        #expect(sup.state == .stopped)
    }

    @Test func terminateNowIsSynchronous() async throws {
        let dir = try tempDir()
        let bin = try script("echo 'RETRACE_READY {\"port\":45002}'\nwhile true; do sleep 0.05; done", in: dir)
        let sup = ServerSupervisor(policy: fastPolicy) { ServerLaunchSpec(executable: bin, environment: [:]) }
        sup.start()
        #expect(await eventually { sup.state.baseURL != nil })
        let pid = try #require(sup.pid)
        sup.terminateNow()
        #expect(!processAlive(pid) && sup.state == .stopped)
    }

    @Test func restartLaunchesFreshProcess() async throws {
        let dir = try tempDir()
        let counter = dir.appendingPathComponent("runs")
        let bin = try script("""
        n=$(cat "\(counter.path)" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "\(counter.path)"
        echo "RETRACE_READY {\\"port\\":$((41000+n))}"
        cat > /dev/null
        """, in: dir)
        let sup = ServerSupervisor(policy: fastPolicy) { ServerLaunchSpec(executable: bin, environment: [:]) }
        sup.start()
        #expect(await eventually { sup.state.baseURL?.description == "http://127.0.0.1:41001" })
        let first = try #require(sup.pid)
        sup.restart()
        #expect(await eventually { sup.state.baseURL?.description == "http://127.0.0.1:41002" })
        #expect(!processAlive(first) && sup.launchCount == 2)
        await sup.stop()
    }

    @Test func missingBinaryFailsAfterRetries() async throws {
        let sup = ServerSupervisor(policy: fastPolicy) {
            ServerLaunchSpec(executable: URL(fileURLWithPath: "/nonexistent/retrace-server"), environment: [:])
        }
        sup.start()
        #expect(await eventually { if case .failed = sup.state { return true } else { return false } })
        if case .failed(let reason) = sup.state { #expect(reason.contains("Could not start")) }
    }
}
