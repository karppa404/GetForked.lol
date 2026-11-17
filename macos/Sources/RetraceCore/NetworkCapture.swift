import CryptoKit
import Foundation

// Pure logic for per-app network capture. The app side (NetworkCaptureController) runs
// mitmdump with network-helper/retrace_capture.py on a loopback port and relaunches the
// target app with Chromium proxy flags. Nothing here changes system proxy settings or
// certificate trust: the app trusts the mitmproxy CA only through
// --ignore-certificate-errors-spki-list, for that one process, and mitmproxy still
// verifies upstream TLS.

/// What a target app is built on. Only Electron and Chromium-based apps honor the
/// `--proxy-server` and `--ignore-certificate-errors-spki-list` command-line switches.
public enum AppRuntime: String, Sendable, Equatable {
    case electron
    case chromium
    case other

    public var supportsProxyFlags: Bool { self != .other }
}

public enum AppRuntimeDetector {
    /// Classifies by the framework bundles an app ships (names without `.framework`).
    public static func detect(frameworkNames: [String]) -> AppRuntime {
        let names = frameworkNames.map { $0.hasSuffix(".framework") ? String($0.dropLast(10)) : $0 }
        if names.contains("Electron Framework") { return .electron }
        let chromium = ["Chromium Embedded Framework", "Chromium Framework", "Google Chrome Framework",
                        "Microsoft Edge Framework", "Brave Browser Framework", "Vivaldi Framework",
                        "Opera Framework", "Arc Framework"]
        if names.contains(where: { chromium.contains($0) }) { return .chromium }
        return .other
    }

    /// Name-based first; otherwise any framework that ships Chromium's UI resource pack
    /// (`chrome_100_percent.pak`) is Chromium. That covers rebranded browsers such as
    /// Helium ("Helium Framework") without a fixed list of vendor names.
    public static func detect(bundleURL: URL, fileManager: FileManager = .default) -> AppRuntime {
        let dir = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let names = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
        let byName = detect(frameworkNames: names)
        guard byName == .other else { return byName }
        let chromium = names.filter { $0.hasSuffix(".framework") }.contains { name in
            fileManager.fileExists(atPath: dir.appendingPathComponent(name).appendingPathComponent("Resources/chrome_100_percent.pak").path)
        }
        return chromium ? .chromium : .other
    }
}

/// Whether and how a recording's network is captured. Pure, so the decision (and the reason
/// recorded in the session when capture can't run) is unit-tested.
public enum NetworkCapturePlan: Equatable, Sendable {
    /// Proxy the app; record only these hosts and their subdomains (empty: all of the app's traffic).
    case capture(hosts: [String])
    /// Capture can't run; the reason is shown and stored as the manifest's `network_note`.
    case unavailable(String)

    public static func make(runtime: AppRuntime, appName: String, bundleId: String, targetURL: URL?) -> NetworkCapturePlan {
        guard let targetURL else {
            guard runtime.supportsProxyFlags else {
                return .unavailable("\(appName) is not an Electron or Chromium app, so its requests can't be routed through Retrace's per-app capture proxy.")
            }
            return .capture(hosts: NetworkCaptureHosts.allowlist(bundleId: bundleId))
        }
        guard runtime.supportsProxyFlags else {
            return .unavailable("\(appName) is not a Chromium-based browser. Retrace captures web API calls only by relaunching a Chromium browser (Chrome, Edge, Brave, Arc, Vivaldi, Helium…) with a per-app proxy; \(appName) would need system-wide proxy or certificate changes, which Retrace never makes. Scan in a Chromium browser to record endpoints.")
        }
        let host = (targetURL.host ?? "").lowercased()
        if NetworkCaptureHosts.isLoopback(host) {
            return .unavailable("\(host) is a loopback address, which Chromium browsers contact directly instead of through a proxy, so its requests can't be captured.")
        }
        let hosts = NetworkCaptureHosts.siteAllowlist(forHost: host)
        guard !hosts.isEmpty else {
            return .unavailable("Retrace could not scope capture to \(host.isEmpty ? "the scan target" : host), so network capture was skipped rather than recording all browsing.")
        }
        return .capture(hosts: hosts)
    }
}

public enum NetworkCaptureHosts {
    /// Hosts recorded for apps we know. For other apps the list is empty, which records every
    /// host: the proxy is set on that one process only, so everything through it is that
    /// app's own traffic (redaction still applies).
    public static func allowlist(bundleId: String) -> [String] {
        switch bundleId.lowercased() {
        case "com.hnc.discord", "com.hnc.discordptb", "com.hnc.discordcanary":
            // API (discord.com/api), gateway (gateway.discord.gg), CDN (cdn.discordapp.com),
            // media/voice signalling (*.discord.media) and attachments (*.discordapp.net).
            return ["discord.com", "discordapp.com", "discord.gg", "discord.media", "discordapp.net"]
        default:
            return []
        }
    }

    /// Hosts recorded for a web scan: the target's site (registrable domain), so the page
    /// host and same-site API hosts (`api.`, `maincloud.`, …) are recorded and everything
    /// else the browser does is tunneled undecrypted. Empty when no site can be derived.
    public static func siteAllowlist(forHost host: String) -> [String] {
        normalize([site(ofHost: host)].compactMap { $0 })
    }

    /// Multi-label public suffixes where the registrable domain has three labels.
    static let multiLabelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "com.au", "net.au", "org.au", "edu.au", "gov.au",
        "co.nz", "org.nz", "co.jp", "ne.jp", "or.jp", "co.kr", "or.kr", "com.br", "net.br", "org.br", "com.cn", "net.cn",
        "org.cn", "com.hk", "com.sg", "com.tw", "com.mx", "com.ar", "com.tr", "co.in", "net.in", "org.in", "co.za", "co.il",
        "com.my", "com.ph", "com.vn", "com.pl", "co.id", "com.ua", "com.co", "com.pe", "com.sa", "com.eg", "com.ng",
    ]
    /// Shared hosting suffixes where every subdomain is a different customer's site, so the
    /// scan's own subdomain is the site (capturing `*.vercel.app` would record other sites).
    static let privateSuffixes: Set<String> = [
        "vercel.app", "netlify.app", "github.io", "gitlab.io", "herokuapp.com", "pages.dev", "workers.dev", "web.app",
        "firebaseapp.com", "appspot.com", "run.app", "azurewebsites.net", "azurestaticapps.net", "cloudfront.net",
        "amazonaws.com", "amplifyapp.com", "onrender.com", "fly.dev", "railway.app", "up.railway.app", "deno.dev",
        "glitch.me", "replit.app", "repl.co", "ngrok.io", "ngrok-free.app", "ngrok.app", "trycloudflare.com", "surge.sh",
        "blogspot.com", "myshopify.com", "wixsite.com", "webflow.io", "framer.app", "streamlit.app", "lovable.app",
        "supabase.co", "bubbleapps.io", "carrd.co", "notion.site",
    ]

    /// Registrable domain of a host (approximate public-suffix rules), or the host itself
    /// for IP literals. Nil for single-label names.
    public static func site(ofHost raw: String) -> String? {
        guard let host = normalize([raw]).first else { return nil }
        if host.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) { return host }  // IPv4
        let labels = host.split(separator: ".").map(String.init)
        for n in stride(from: min(labels.count - 1, 3), through: 2, by: -1) {
            let suffix = labels.suffix(n).joined(separator: ".")
            if privateSuffixes.contains(suffix) || multiLabelSuffixes.contains(suffix) {
                return labels.suffix(n + 1).joined(separator: ".")
            }
        }
        return labels.suffix(2).joined(separator: ".")
    }

    /// `localhost`, `*.localhost`, 127.0.0.0/8 and ::1, which Chromium never sends through a proxy.
    public static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return h == "localhost" || h.hasSuffix(".localhost") || h.hasPrefix("127.") || h == "::1" || h == "0.0.0.0"
    }

    /// Lowercased bare hostnames: strips schemes, ports, paths and leading `*.`/`.`; drops
    /// anything that is not a plausible DNS name. Order is preserved, duplicates removed.
    public static func normalize(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        for raw in hosts {
            var h = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
            if let i = h.firstIndex(where: { $0 == "/" || $0 == ":" }) { h = String(h[..<i]) }
            while h.hasPrefix("*.") { h.removeFirst(2) }
            while h.hasPrefix(".") { h.removeFirst() }
            guard !h.isEmpty, h.count <= 253, h.contains("."), !h.hasSuffix("."), !h.contains(".."),
                  h.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { continue }
            if seen.insert(h).inserted { out.append(h) }
        }
        return out
    }

    /// Same rule as retrace_capture.host_allowed: exact host or any subdomain.
    public static func isAllowed(host: String, allowlist: [String]) -> Bool {
        guard !allowlist.isEmpty else { return true }
        let h = host.lowercased()
        return allowlist.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// mitmproxy `--allow-hosts` regex (matched against `host:port`). Hosts outside it are
    /// tunneled without TLS interception, so they are never decrypted. Nil means intercept all.
    public static func allowHostsPattern(_ hosts: [String]) -> String? {
        let hs = normalize(hosts)
        guard !hs.isEmpty else { return nil }
        let alternatives = hs.map { $0.replacingOccurrences(of: ".", with: "\\.") }.joined(separator: "|")
        return "^(?:[a-z0-9-]+\\.)*(?:\(alternatives)):\\d+$"
    }
}

public enum NetworkCaptureError: Error, Equatable, CustomStringConvertible {
    case invalidPort(Int)
    case invalidSPKIHash
    case invalidCertificate(String)

    public var description: String {
        switch self {
        case .invalidPort(let p): return "Invalid proxy port \(p)"
        case .invalidSPKIHash: return "Invalid certificate SPKI hash"
        case .invalidCertificate(let why): return "Could not read the capture certificate: \(why)"
        }
    }
}

public enum ProxyLaunch {
    public static let proxyFlag = "--proxy-server="
    public static let spkiFlag = "--ignore-certificate-errors-spki-list="

    /// Command-line switches that route one Electron/Chromium process through the local
    /// capture proxy and make it accept certificates signed with the capture CA's key only.
    /// `--ignore-certificate-errors` (accept any certificate) is deliberately never used.
    public static func arguments(port: Int, spkiHash: String) throws -> [String] {
        guard (1024...65535).contains(port) else { throw NetworkCaptureError.invalidPort(port) }
        guard isValidSPKIHash(spkiHash) else { throw NetworkCaptureError.invalidSPKIHash }
        return ["\(proxyFlag)127.0.0.1:\(port)", "\(spkiFlag)\(spkiHash)"]
    }

    /// A base64 SHA-256 digest: 44 characters ending in `=`.
    public static func isValidSPKIHash(_ s: String) -> Bool {
        guard s.count == 44, s.hasSuffix("="), let d = Data(base64Encoded: s) else { return false }
        return d.count == 32
    }

    /// Switches kept when a browser is relaunched (for capture and again afterwards): the
    /// profile it was running with, if it was started with an explicit one, plus restoring
    /// its last session so the user's tabs come back. Chromium keeps cookies and sign-ins in
    /// that same profile, so the user stays signed in.
    public static func browserRelaunchArguments(currentArguments argv: [String]) -> [String] {
        let keep = argv.dropFirst().filter { $0.hasPrefix("--user-data-dir=") || $0.hasPrefix("--profile-directory=") }
        return Array(keep) + ["--restore-last-session"]
    }

    /// True when a process's argv carries the proxy switch (used to verify a relaunch took).
    public static func hasProxyFlags(_ argv: [String]) -> Bool {
        argv.contains { $0.hasPrefix(proxyFlag) } && argv.contains { $0.hasPrefix(spkiFlag) }
    }
}

/// SPKI pin of a certificate, in the format Chromium's
/// `--ignore-certificate-errors-spki-list` expects: base64(SHA-256(SubjectPublicKeyInfo DER)).
public enum SPKI {
    public static func sha256Base64(certificatePEM pem: String) throws -> String {
        let der = try derFromPEM(pem)
        let spki = try subjectPublicKeyInfo(certificateDER: der)
        return Data(SHA256.hash(data: spki)).base64EncodedString()
    }

    static func derFromPEM(_ pem: String) throws -> Data {
        let begin = "-----BEGIN CERTIFICATE-----", end = "-----END CERTIFICATE-----"
        guard let b = pem.range(of: begin), let e = pem.range(of: end, range: b.upperBound..<pem.endIndex) else {
            throw NetworkCaptureError.invalidCertificate("no PEM certificate block")
        }
        let body = pem[b.upperBound..<e.lowerBound].filter { !$0.isWhitespace }
        guard let der = Data(base64Encoded: String(body)) else { throw NetworkCaptureError.invalidCertificate("bad base64") }
        return der
    }

    /// Walks Certificate → tbsCertificate → [version] serial sigAlg issuer validity subject
    /// and returns the full subjectPublicKeyInfo TLV.
    public static func subjectPublicKeyInfo(certificateDER der: Data) throws -> Data {
        let bytes = [UInt8](der)
        let cert = try tlv(bytes, at: 0)
        guard cert.tag == 0x30 else { throw NetworkCaptureError.invalidCertificate("not a SEQUENCE") }
        let tbs = try tlv(bytes, at: cert.contentStart)
        guard tbs.tag == 0x30 else { throw NetworkCaptureError.invalidCertificate("no tbsCertificate") }
        var cursor = tbs.contentStart
        var first = try tlv(bytes, at: cursor)
        if first.tag == 0xA0 { cursor = first.end; first = try tlv(bytes, at: cursor) }  // explicit version
        for _ in 0..<5 { cursor = try tlv(bytes, at: cursor).end }  // serial, sigAlg, issuer, validity, subject
        let spki = try tlv(bytes, at: cursor)
        guard spki.tag == 0x30, spki.end <= tbs.end else { throw NetworkCaptureError.invalidCertificate("no subjectPublicKeyInfo") }
        return Data(bytes[cursor..<spki.end])
    }

    private struct TLV { let tag: UInt8; let contentStart: Int; let end: Int }

    private static func tlv(_ b: [UInt8], at i: Int) throws -> TLV {
        guard i + 1 < b.count else { throw NetworkCaptureError.invalidCertificate("truncated") }
        let tag = b[i]
        var len = Int(b[i + 1])
        var start = i + 2
        if len & 0x80 != 0 {
            let n = len & 0x7f
            guard n >= 1, n <= 4, start + n <= b.count else { throw NetworkCaptureError.invalidCertificate("bad length") }
            len = b[start..<(start + n)].reduce(0) { ($0 << 8) | Int($1) }
            start += n
        }
        guard start + len <= b.count else { throw NetworkCaptureError.invalidCertificate("truncated") }
        return TLV(tag: tag, contentStart: start, end: start + len)
    }
}

/// Swift equivalent of network-helper/export_evidence.py `convert`, applied when a
/// recording stops: timestamps become relative to the session start, entries outside the
/// session window are dropped, and anything the manifest schema would reject is dropped or
/// clipped. Entries were already redacted by the capture addon; the API re-redacts on ingest.
public enum NetworkEvidenceExport {
    public static let maxEntries = 2000

    public static func events(fromJSONL data: Data, startedAt: String, durationMs: Int) -> [NetworkEvent] {
        guard let start = SessionClock.parseISO8601(startedAt) else { return [] }
        let startMs = start.timeIntervalSince1970 * 1000
        var out: [NetworkEvent] = []
        var ids = Set<String>()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let event = event(from: obj, startMs: startMs, durationMs: durationMs),
                  ids.insert(event.id).inserted else { continue }
            out.append(event)
        }
        out.sort { ($0.timestampMs, $0.id) < ($1.timestampMs, $1.id) }
        return Array(out.prefix(maxEntries))
    }

    static func event(from o: [String: Any], startMs: Double, durationMs: Int) -> NetworkEvent? {
        guard let rawId = o["id"] as? String, let uuid = UUID(uuidString: rawId),
              let captured = (o["captured_at_ms"] as? NSNumber)?.doubleValue,
              let method = (o["method"] as? String)?.uppercased(), (1...16).contains(method.count),
              method.unicodeScalars.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) && $0.isASCII }),
              let url = o["url"] as? String, (1...4096).contains(url.count), hasAllowedScheme(url) else { return nil }
        let ts = Int((captured - startMs).rounded(.down))
        guard ts >= 0, ts <= durationMs else { return nil }
        var status = (o["status"] as? NSNumber)?.intValue
        if let s = status, !(0...999).contains(s) { status = nil }
        return NetworkEvent(id: uuid.uuidString.lowercased(), timestampMs: ts, method: method, url: url, status: status,
                            requestHeaders: headers(o["request_headers"]), responseHeaders: headers(o["response_headers"]),
                            requestBody: body(o["request_body"]), responseBody: body(o["response_body"]))
    }

    static func hasAllowedScheme(_ url: String) -> Bool {
        let lower = url.lowercased()
        return ["http://", "https://", "ws://", "wss://"].contains { lower.hasPrefix($0) }
    }

    private static func headers(_ v: Any?) -> [String: String]? {
        guard let d = v as? [String: Any], !d.isEmpty, d.count <= 100 else { return nil }
        var out: [String: String] = [:]
        for (k, value) in d { out[k] = (value as? String) ?? "\(value)" }
        return out
    }

    private static func body(_ v: Any?) -> String? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        return s.count > 4096 ? String(s.prefix(4096)) : s
    }

    /// Puts captured evidence into a manifest. Called only when a capture actually ran, so
    /// an empty capture is `none_observed`, never `not_captured`.
    public static func merge(_ events: [NetworkEvent], into manifest: SessionManifest) -> SessionManifest {
        var m = manifest
        let taken = Set(m.frames.map(\.id) + m.interactions.map(\.id))
        m.network = events.filter { !taken.contains($0.id) && $0.timestampMs <= m.durationMs }
        m.networkStatus = m.network.isEmpty ? .noneObserved : .observed
        return m
    }
}

public enum MitmproxyLocator {
    public static let installHint = "uv tool install mitmproxy"

    /// Where `mitmdump` is looked for, in order: $PATH, then uv tool / pipx / Homebrew /
    /// python.org user installs (a menu bar app does not inherit the shell's PATH).
    public static func candidates(path: String?, home: String) -> [String] {
        var dirs = (path ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        dirs += ["\(home)/.local/bin", "\(home)/.local/share/uv/tools/mitmproxy/bin",
                 "\(home)/.local/pipx/venvs/mitmproxy/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        var seen = Set<String>()
        return dirs.map { ($0.hasSuffix("/") ? String($0.dropLast()) : $0) + "/mitmdump" }.filter { seen.insert($0).inserted }
    }

    public static func find(path: String? = ProcessInfo.processInfo.environment["PATH"],
                            home: String = NSHomeDirectory(),
                            isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        candidates(path: path, home: home).first(where: isExecutable)
    }

    /// mitmdump arguments: loopback only, private config dir (its CA never touches the
    /// system keychain), the Retrace addon, and an allowlist when the app has one.
    public static func mitmdumpArguments(port: Int, confDir: String, addon: String, output: String, hosts: [String]) -> [String] {
        var args = ["--listen-host", "127.0.0.1", "-p", String(port), "--set", "confdir=\(confDir)", "-q",
                    "-s", addon, "--set", "retrace_out=\(output)", "--set", "retrace_skip_static=true"]
        let hs = NetworkCaptureHosts.normalize(hosts)
        if !hs.isEmpty {
            args += ["--set", "retrace_hosts=\(hs.joined(separator: ","))"]
            if let pattern = NetworkCaptureHosts.allowHostsPattern(hs) { args += ["--allow-hosts", pattern] }
        }
        return args
    }
}

/// Parses a `sysctl(KERN_PROCARGS2)` buffer: int32 argc, exec path, NUL padding, then argv.
/// Used to confirm a relaunched app really received the proxy switches (a launch that races
/// the previous instance's shutdown can be handed to it and lose its arguments).
public enum ProcArgs {
    public static func parse(_ data: Data) -> [String]? {
        let b = [UInt8](data)
        guard b.count >= 4 else { return nil }
        let argc = Int(Int32(littleEndian: b.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))
        guard argc > 0, argc < 4096 else { return nil }
        var i = 4
        while i < b.count, b[i] != 0 { i += 1 }  // exec path
        while i < b.count, b[i] == 0 { i += 1 }  // padding
        var args: [String] = []
        while args.count < argc, i < b.count {
            var j = i
            while j < b.count, b[j] != 0 { j += 1 }
            args.append(String(decoding: b[i..<j], as: UTF8.self))
            i = j + 1
        }
        return args.count == argc ? args : nil
    }
}
