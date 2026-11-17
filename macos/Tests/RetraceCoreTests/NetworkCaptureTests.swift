import Foundation
import Testing
@testable import RetraceCore

@Suite("Network capture: runtime detection")
struct RuntimeDetectionTests {
    @Test func detectsElectronChromiumAndOther() {
        // Discord.app/Contents/Frameworks as shipped.
        #expect(AppRuntimeDetector.detect(frameworkNames: ["Discord Helper (GPU).app", "Discord Helper.app", "Electron Framework.framework",
                                                           "Mantle.framework", "Squirrel.framework"]) == .electron)
        #expect(AppRuntimeDetector.detect(frameworkNames: ["Chromium Embedded Framework.framework"]) == .chromium)
        #expect(AppRuntimeDetector.detect(frameworkNames: ["Google Chrome Framework.framework"]) == .chromium)
        #expect(AppRuntimeDetector.detect(frameworkNames: ["Sparkle.framework", "ElectronLike.framework"]) == .other)
        #expect(AppRuntimeDetector.detect(frameworkNames: []) == .other)
        #expect(!AppRuntime.other.supportsProxyFlags && AppRuntime.electron.supportsProxyFlags)
    }

    @Test func detectsFromBundleOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let electron = root.appendingPathComponent("E.app")
        try FileManager.default.createDirectory(at: electron.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"),
                                                withIntermediateDirectories: true)
        let native = root.appendingPathComponent("N.app")
        try FileManager.default.createDirectory(at: native.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        #expect(AppRuntimeDetector.detect(bundleURL: electron) == .electron)
        #expect(AppRuntimeDetector.detect(bundleURL: native) == .other)
    }
}

@Suite("Network capture: proxy arguments")
struct ProxyArgumentTests {
    @Test func buildsLoopbackProxyAndSPKIPinOnly() throws {
        let hash = "edrh7twlrOuB4p7N1Ri2as8Rvl42f6rt0AuD/MzAaDY="
        let args = try ProxyLaunch.arguments(port: 62840, spkiHash: hash)
        #expect(args == ["--proxy-server=127.0.0.1:62840", "--ignore-certificate-errors-spki-list=\(hash)"])
        #expect(!args.contains("--ignore-certificate-errors"), "never accept arbitrary certificates")
        #expect(ProxyLaunch.hasProxyFlags(["/Applications/Discord.app/Contents/MacOS/Discord"] + args))
        #expect(!ProxyLaunch.hasProxyFlags(["/Applications/Discord.app/Contents/MacOS/Discord"]))
    }

    @Test func rejectsBadPortOrHash() {
        #expect(throws: NetworkCaptureError.invalidPort(80)) { try ProxyLaunch.arguments(port: 80, spkiHash: "edrh7twlrOuB4p7N1Ri2as8Rvl42f6rt0AuD/MzAaDY=") }
        for bad in ["", "abc", "edrh7twlrOuB4p7N1Ri2as8Rvl42f6rt0AuD/MzAaDY", "edrh7twlrOuB4p7N1Ri2as8Rvl42f6rt0AuD/MzAa,Y=", "x --no-sandbox"] {
            #expect(throws: NetworkCaptureError.invalidSPKIHash, "\(bad)") { try ProxyLaunch.arguments(port: 9000, spkiHash: bad) }
        }
    }

    @Test func spkiHashMatchesOpenSSL() throws {
        // Expected values: openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64
        #expect(try SPKI.sha256Base64(certificatePEM: Self.rsaPEM) == "2kG2tzCZgyT19/UQhtUClsOpApjDVs7M/5wJ81MqLkk=")
        #expect(try SPKI.sha256Base64(certificatePEM: Self.ecPEM) == "v+DNLVHv8KElXoboSp2QrWgwhw2wu6BqIAWoAM3+qmo=")
        #expect(throws: NetworkCaptureError.self) { try SPKI.sha256Base64(certificatePEM: "not a cert") }
        #expect(throws: NetworkCaptureError.self) {
            try SPKI.sha256Base64(certificatePEM: "-----BEGIN CERTIFICATE-----\nMAMCAQA=\n-----END CERTIFICATE-----")
        }
    }

    @Test func mitmdumpArgumentsAreLoopbackAndAllowlisted() {
        let args = MitmproxyLocator.mitmdumpArguments(port: 9001, confDir: "/c", addon: "/a.py", output: "/o.jsonl",
                                                      hosts: NetworkCaptureHosts.allowlist(bundleId: "com.hnc.Discord"))
        #expect(Array(args.prefix(4)) == ["--listen-host", "127.0.0.1", "-p", "9001"])
        #expect(args.contains("confdir=/c") && args.contains("retrace_out=/o.jsonl") && args.contains("retrace_skip_static=true"))
        #expect(args.contains("retrace_hosts=discord.com,discordapp.com,discord.gg,discord.media,discordapp.net"))
        #expect(args.contains("--allow-hosts"))
        let open = MitmproxyLocator.mitmdumpArguments(port: 9001, confDir: "/c", addon: "/a.py", output: "/o", hosts: [])
        #expect(!open.contains("--allow-hosts") && !open.contains { $0.hasPrefix("retrace_hosts=") })
    }

    @Test func locatorSearchesPathThenUserToolDirs() {
        let c = MitmproxyLocator.candidates(path: "/usr/bin:/opt/homebrew/bin/", home: "/Users/u")
        #expect(c.first == "/usr/bin/mitmdump")
        #expect(c.contains("/Users/u/.local/bin/mitmdump") && c.contains("/Users/u/.local/pipx/venvs/mitmproxy/bin/mitmdump"))
        #expect(c.filter { $0 == "/opt/homebrew/bin/mitmdump" }.count == 1)
        #expect(MitmproxyLocator.find(path: "", home: "/Users/u", isExecutable: { $0 == "/Users/u/.local/bin/mitmdump" }) == "/Users/u/.local/bin/mitmdump")
        #expect(MitmproxyLocator.find(path: nil, home: "/Users/u", isExecutable: { _ in false }) == nil)
    }

    static let rsaPEM = """
    -----BEGIN CERTIFICATE-----
    MIIC9DCCAdygAwIBAgIUXixkkzaOpD3vd4meqj1IWu8zRCowDQYJKoZIhvcNAQEL
    BQAwGjEYMBYGA1UEAwwPUmV0cmFjZSBUZXN0IENBMB4XDTI2MTEwODAyNDU0MloX
    DTM2MTEwNTAyNDU0MlowGjEYMBYGA1UEAwwPUmV0cmFjZSBUZXN0IENBMIIBIjAN
    BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAo+Ndlkw10GiXROZQLj5z8ldIL5Kd
    76XfNgtsidulDzFxFSlkQSQ09CDY+JrcqZx8C72l0CVctFJkDPamaAkF6T5GfMy8
    78D0Zw3VguUAi60+SV0w2/Pq33Pp4b18Xb39XxND+HnBgRFpjHFb86iNa6FjxdU7
    mQsMTBkbA6HVLjGfNIIei51QpENEIWm60v6q48sac4JjfV3WAFHvgji5GJKCz5Oy
    sti1D+yTg/jCE5a5m4wH4El7qeUnkJtghOdDfSawiZJMWMMoORMH2V0yyCGGDrQX
    lREh6VcIZdzSU5ausRtabz0CYMAv8xPv7OvrD1ezsbqZnoFR3U+WXyYfFwIDAQAB
    ozIwMDAdBgNVHQ4EFgQUWmppaGRp9KhcSKIQO1Np8ArOfwwwDwYDVR0TAQH/BAUw
    AwEB/zANBgkqhkiG9w0BAQsFAAOCAQEAIQEzApmSBXzTyTo+BvAkIa/KWDxeSK+P
    UMDK24/Cj6N37E4husRcEtmr4SdUBOWV4o4Zy5Yk9LO2m4aNt/jXECfkZcwA077t
    Ssq5uyd9udPRN31CUcfkTX25uhCTHggKhguPXzl8n5PMpXXsM5ZXIX2eV+lJ+NRJ
    l13cL1Ma9Uot103s7idfWUsdQgrN60fg0rWQ6EgJvbPE8K0jquvXf15QQgA9H7FF
    rYqfgMggLQsVcGUlGwFpzDd38Fl4sIJ4X6SjYGHbCxDCT8u+KFJydL4pI9mmH/uD
    mAuUOxQLUU//8h9mA+L78PEzqJZMRY0YNZ3Onk7ZRl4xJ/LXke02iQ==
    -----END CERTIFICATE-----
    """

    static let ecPEM = """
    -----BEGIN CERTIFICATE-----
    MIIBXjCCAQSgAwIBAgIUHdiPUBA2GcePnGJCTh2B266YqkIwCgYIKoZIzj0EAwIw
    FTETMBEGA1UEAwwKUmV0cmFjZSBFQzAeFw0yNjExMDgwMjQ1NDJaFw0zNjExMDUw
    MjQ1NDJaMBUxEzARBgNVBAMMClJldHJhY2UgRUMwWTATBgcqhkjOPQIBBggqhkjO
    PQMBBwNCAASamFg5TC31RW99GiPONsNi4KCqJK47Qr7bk0SjUi7MNTGCCtP/CYEk
    qQYHCnYy+L2SmwfhaglDlMhq+KKlqVuxozIwMDAdBgNVHQ4EFgQUx0jM7BLhja87
    +MZchuYS/qydzj0wDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEA
    qmtVhSypwq8UIV0IVM7hlsBElZZ959lUpS+re1MJrl0CIBXC3lefABqIenOyLr3N
    MCDGBxhlnj5wTuiByTMzjrC5
    -----END CERTIFICATE-----
    """
}

@Suite("Network capture: host allowlist")
struct AllowlistTests {
    @Test func discordProfileAndUnknownApps() {
        let d = NetworkCaptureHosts.allowlist(bundleId: "com.hnc.Discord")
        for host in ["discord.com", "status.discord.com", "cdn.discordapp.com", "gateway.discord.gg", "latency.discord.media", "media.discordapp.net"] {
            #expect(NetworkCaptureHosts.isAllowed(host: host, allowlist: d), "\(host)")
        }
        for host in ["o64374.ingest.sentry.io", "evildiscord.com", "discord.com.evil.net", "hcaptcha.com"] {
            #expect(!NetworkCaptureHosts.isAllowed(host: host, allowlist: d), "\(host)")
        }
        #expect(NetworkCaptureHosts.allowlist(bundleId: "com.tinyspeck.slackmacgap").isEmpty)
        #expect(NetworkCaptureHosts.isAllowed(host: "anything.example", allowlist: []))
    }

    @Test func normalizesHosts() {
        #expect(NetworkCaptureHosts.normalize([" https://Discord.com/api ", "*.discord.com", ".discord.gg", "cdn.discordapp.com:443", "discord.com",
                                               "localhost", "bad host.com", "a..b.com", "x.com."])
                == ["discord.com", "discord.gg", "cdn.discordapp.com"])
    }

    @Test func allowHostsPatternMatchesLikeMitmproxy() throws {
        let pattern = try #require(NetworkCaptureHosts.allowHostsPattern(["discord.com", "discord.gg"]))
        let re = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        func matches(_ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        #expect(matches("discord.com:443") && matches("gateway.discord.gg:443") && matches("Status.Discord.com:443"))
        #expect(!matches("evildiscord.com:443") && !matches("discord.com.evil.net:443") && !matches("sentry.io:443"))
        #expect(NetworkCaptureHosts.allowHostsPattern([]) == nil)
    }
}

@Suite("Network capture: export into manifest")
struct NetworkExportTests {
    let start = "2026-11-07T15:00:00.000Z"
    let base: Int64 = 1_794_063_600_000  // 2026-11-07T15:00:00Z in ms

    func line(_ o: [String: Any]) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self) }

    var capture: Data {
        let a = "0b7c1f8e-3a52-4d2e-9a43-2c1f6f7b9a01", b = "1c8d2f9e-4b63-4e3f-8b54-3d2f7f8c0b12"
        let lines = [
            line(["id": b, "captured_at_ms": base + 2500, "method": "GET", "url": "https://discord.com/api/v9/users/%40me/badges", "status": 200,
                  "request_headers": ["authorization": "[REDACTED]"], "response_headers": [:] as [String: String], "request_body": NSNull(), "response_body": NSNull()]),
            line(["id": a, "captured_at_ms": base + 100, "method": "get", "url": "wss://gateway.discord.gg/?encoding=etf&v=9", "status": 101]),
            line(["id": UUID().uuidString, "captured_at_ms": base - 5, "method": "GET", "url": "https://discord.com/early"]),
            line(["id": UUID().uuidString, "captured_at_ms": base + 99_000, "method": "GET", "url": "https://discord.com/late"]),
            line(["id": UUID().uuidString, "captured_at_ms": base + 10, "method": "GE T", "url": "https://discord.com/bad-method"]),
            line(["id": UUID().uuidString, "captured_at_ms": base + 10, "method": "GET", "url": "file:///etc/passwd"]),
            line(["id": "not-a-uuid", "captured_at_ms": base + 10, "method": "GET", "url": "https://discord.com/x"]),
            line(["id": a, "captured_at_ms": base + 200, "method": "GET", "url": "https://discord.com/dup"]),
            "{not json",
            "",
        ]
        return Data(lines.joined(separator: "\n").utf8)
    }

    @Test func convertsLikeExportEvidence() {
        let events = NetworkEvidenceExport.events(fromJSONL: capture, startedAt: start, durationMs: 10_000)
        #expect(events.map(\.timestampMs) == [100, 2500])
        #expect(events[0].method == "GET" && events[0].url.hasPrefix("wss://") && events[0].status == 101)
        #expect(events[1].requestHeaders == ["authorization": "[REDACTED]"] && events[1].responseHeaders == nil && events[1].requestBody == nil)
    }

    @Test func mergeProducesValidObservedManifest() throws {
        let raw = SessionManifest(id: UUID().uuidString.lowercased(), app: AppInfo(name: "Discord", bundleId: "com.hnc.Discord", pid: 42),
                                  startedAt: start, durationMs: 10_000)
        #expect(raw.networkStatus == .notCaptured)
        let events = NetworkEvidenceExport.events(fromJSONL: capture, startedAt: start, durationMs: raw.durationMs)
        let m = NetworkEvidenceExport.merge(events, into: raw)
        #expect(m.networkStatus == .observed && m.network.count == 2)
        #expect(ManifestValidator.validate(m, purpose: .local).isEmpty)
        let json = String(decoding: try ManifestCoding.encoder().encode(m), as: UTF8.self)
        #expect(json.contains("\"network_status\":\"observed\"") && json.contains("\"timestamp_ms\":2500"))
        #expect(!json.contains("captured_at_ms"))
    }

    @Test func emptyCaptureIsNoneObservedNotNotCaptured() {
        let raw = SessionManifest(id: UUID().uuidString.lowercased(), app: AppInfo(name: "D", bundleId: "d", pid: 1), startedAt: start, durationMs: 5)
        let m = NetworkEvidenceExport.merge(NetworkEvidenceExport.events(fromJSONL: Data(), startedAt: start, durationMs: 5), into: raw)
        #expect(m.networkStatus == .noneObserved && m.network.isEmpty)
        #expect(ManifestValidator.validate(m, purpose: .local).isEmpty)
    }

    @Test func mergeDropsIdCollisionsWithOtherEvidence() {
        let id = "0b7c1f8e-3a52-4d2e-9a43-2c1f6f7b9a01"
        var raw = SessionManifest(id: UUID().uuidString.lowercased(), app: AppInfo(name: "D", bundleId: "d", pid: 1), startedAt: start, durationMs: 100)
        raw.interactions = [Interaction(id: id, timestampMs: 1, kind: .click)]
        let m = NetworkEvidenceExport.merge([NetworkEvent(id: id, timestampMs: 2, method: "GET", url: "https://h/x")], into: raw)
        #expect(m.network.isEmpty && m.networkStatus == .noneObserved)
    }
}

@Suite("Network capture: process arguments")
struct ProcArgsTests {
    @Test func parsesProcargs2Layout() {
        var d = Data()
        var argc = Int32(3).littleEndian
        d.append(Data(bytes: &argc, count: 4))
        d.append(Data("/Applications/Discord.app/Contents/MacOS/Discord".utf8)); d.append(contentsOf: [0, 0, 0, 0])
        for a in ["/Applications/Discord.app/Contents/MacOS/Discord", "--proxy-server=127.0.0.1:9000",
                  "--ignore-certificate-errors-spki-list=edrh7twlrOuB4p7N1Ri2as8Rvl42f6rt0AuD/MzAaDY="] {
            d.append(Data(a.utf8)); d.append(0)
        }
        d.append(Data("PATH=/usr/bin".utf8)); d.append(0)  // environment follows argv
        let args = ProcArgs.parse(d)
        #expect(args?.count == 3 && args?[1] == "--proxy-server=127.0.0.1:9000")
        #expect(ProxyLaunch.hasProxyFlags(args ?? []))
        #expect(ProcArgs.parse(Data([1, 0])) == nil)
        #expect(ProcArgs.parse(Data([5, 0, 0, 0]) + Data("/x".utf8) + Data([0])) == nil)
    }
}

@Suite("Network capture: SaaS web scans in browsers")
struct WebScanCaptureTests {
    @Test func detectsRebrandedChromiumBrowsersByResourcePack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // Helium.app ships "Helium Framework.framework", which no vendor-name list knew.
        let helium = root.appendingPathComponent("Helium.app")
        let res = helium.appendingPathComponent("Contents/Frameworks/Helium Framework.framework/Resources")
        try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: res.appendingPathComponent("chrome_100_percent.pak").path, contents: Data())
        let other = root.appendingPathComponent("Other.app")
        try FileManager.default.createDirectory(at: other.appendingPathComponent("Contents/Frameworks/Helium Framework.framework/Resources"),
                                                withIntermediateDirectories: true)
        #expect(AppRuntimeDetector.detect(bundleURL: helium) == .chromium)
        #expect(AppRuntimeDetector.detect(bundleURL: other) == .other)
    }

    @Test func scopesToTheTargetSite() {
        #expect(NetworkCaptureHosts.siteAllowlist(forHost: "scrabblebot.spacetimedb.com") == ["spacetimedb.com"])
        #expect(NetworkCaptureHosts.siteAllowlist(forHost: "app.example.co.uk") == ["example.co.uk"])
        #expect(NetworkCaptureHosts.siteAllowlist(forHost: "my-app.vercel.app") == ["my-app.vercel.app"])
        #expect(NetworkCaptureHosts.siteAllowlist(forHost: "x.y.up.railway.app") == ["y.up.railway.app"])
        #expect(NetworkCaptureHosts.siteAllowlist(forHost: "Linear.app") == ["linear.app"])
        #expect(NetworkCaptureHosts.siteAllowlist(forHost: "10.0.0.5") == ["10.0.0.5"])
        #expect(NetworkCaptureHosts.siteAllowlist(forHost: "intranet").isEmpty)
        let site = NetworkCaptureHosts.siteAllowlist(forHost: "scrabblebot.spacetimedb.com")
        for host in ["scrabblebot.spacetimedb.com", "maincloud.spacetimedb.com", "spacetimedb.com"] {
            #expect(NetworkCaptureHosts.isAllowed(host: host, allowlist: site), "\(host)")
        }
        for host in ["accounts.google.com", "evilspacetimedb.com", "spacetimedb.com.evil.net", "www.google-analytics.com"] {
            #expect(!NetworkCaptureHosts.isAllowed(host: host, allowlist: site), "\(host)")
        }
        let args = MitmproxyLocator.mitmdumpArguments(port: 9001, confDir: "/c", addon: "/a.py", output: "/o.jsonl", hosts: site)
        #expect(args.contains("retrace_hosts=spacetimedb.com") && args.contains("--allow-hosts"))
    }

    @Test func planCapturesChromiumBrowsersAndExplainsTheRest() {
        let url = URL(string: "https://scrabblebot.spacetimedb.com/")!
        #expect(NetworkCapturePlan.make(runtime: .chromium, appName: "Helium", bundleId: "net.imput.helium", targetURL: url)
                == .capture(hosts: ["spacetimedb.com"]))
        // A web scan never falls back to "record every host", even for an app with a profile.
        #expect(NetworkCapturePlan.make(runtime: .electron, appName: "Discord", bundleId: "com.hnc.Discord", targetURL: url)
                == .capture(hosts: ["spacetimedb.com"]))
        guard case .unavailable(let safari) = NetworkCapturePlan.make(runtime: .other, appName: "Safari", bundleId: "com.apple.Safari", targetURL: url),
              case .unavailable(let loopback) = NetworkCapturePlan.make(runtime: .chromium, appName: "Chrome", bundleId: "com.google.Chrome",
                                                                         targetURL: URL(string: "http://localhost:3000/")!),
              case .unavailable(let native) = NetworkCapturePlan.make(runtime: .other, appName: "Notes", bundleId: "com.apple.Notes", targetURL: nil)
        else { Issue.record("expected unavailable plans"); return }
        #expect(safari.contains("Safari") && safari.contains("Chromium"))
        #expect(loopback.contains("loopback"))
        #expect(native.contains("Notes"))
        #expect(NetworkCapturePlan.make(runtime: .electron, appName: "Discord", bundleId: "com.hnc.Discord", targetURL: nil)
                == .capture(hosts: NetworkCaptureHosts.allowlist(bundleId: "com.hnc.Discord")))
    }

    @Test func browserRelaunchKeepsProfileAndTabs() {
        #expect(ProxyLaunch.browserRelaunchArguments(currentArguments: ["/Applications/Helium.app/Contents/MacOS/Helium"]) == ["--restore-last-session"])
        #expect(ProxyLaunch.browserRelaunchArguments(currentArguments: ["/x/Chrome", "--user-data-dir=/tmp/p", "--profile-directory=Profile 1", "--proxy-server=evil"])
                == ["--user-data-dir=/tmp/p", "--profile-directory=Profile 1", "--restore-last-session"])
    }

    @Test func manifestCarriesWhyNetworkWasNotCaptured() throws {
        var m = SessionManifest(id: UUID().uuidString.lowercased(), app: AppInfo(name: "Safari", bundleId: "web.example.com", pid: 1),
                                startedAt: "2026-11-08T10:00:00Z", durationMs: 1000)
        m.networkNote = "Safari is not a Chromium-based browser."
        let object = try #require(JSONSerialization.jsonObject(with: ManifestCoding.encoder().encode(m)) as? [String: Any])
        #expect(object["network_note"] as? String == m.networkNote)
        #expect(try ManifestCoding.decoder().decode(SessionManifest.self, from: ManifestCoding.encoder().encode(m)).networkNote == m.networkNote)
        #expect(ManifestValidator.validate(m, purpose: .local).isEmpty)
        m.networkNote = String(repeating: "x", count: SessionManifest.maxNetworkNote + 1)
        #expect(!ManifestValidator.validate(m, purpose: .local).isEmpty)
    }
}
