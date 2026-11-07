import Foundation
import RetraceCore

// Headless helper. Never requests permissions, never records, never uploads.
//   retrace-cli validate <session-dir> [--upload]   validate manifest + frame hashes
//   retrace-cli list                                 list local sessions

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: retrace-cli validate <session-dir> [--upload] | list\n".utf8))
    exit(64)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

switch command {
case "validate":
    guard args.count >= 2 else { usage() }
    let dir = URL(fileURLWithPath: args[1], isDirectory: true)
    do {
        let session = try SessionStore.load(directory: dir)
        let purpose: ManifestValidator.Purpose = args.contains("--upload") ? .upload : .local
        var issues = ManifestValidator.validate(session.manifest, purpose: purpose)
        do { _ = try SessionStore.frameFiles(for: session.manifest, in: dir) }
        catch { issues.append(ValidationIssue("files", String(describing: error))) }
        let m = session.manifest
        print("session \(m.id) app=\(m.app.bundleId) interactions=\(m.interactions.count) frames=\(m.frames.count) duration_ms=\(m.durationMs) network_status=\(m.networkStatus.rawValue)")
        if issues.isEmpty { print("OK"); exit(0) }
        issues.forEach { print("INVALID \($0)") }
        exit(1)
    } catch {
        print("ERROR \(error)")
        exit(2)
    }
case "list":
    for s in SessionStore(root: SessionStore.defaultRoot()).list() {
        print("\(s.manifest.startedAt)  \(s.id)  \(s.manifest.app.name)  frames=\(s.manifest.frames.count) reviewed=\(s.review.isConfirmed) uploaded=\(s.upload.remoteSessionId != nil)")
    }
default:
    usage()
}
