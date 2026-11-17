import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// "Export UI flow": the validated graph JSON (`GET /v1/sessions/{id}/graph?download=1`, corrections
// applied) plus one embedded screenshot per screen node under `screenshots`, which the FigJam plugin
// (figjam-plugin/README.md) draws above each screen. Same format the web dashboard downloaded.

/// One screenshot per screen node: `{frame_id, data: "data:image/jpeg;base64,…", width, height}`.
public struct ExportScreenshot: Equatable, Sendable {
    public var frameId: String
    public var data: String
    public var width: Int
    public var height: Int

    var json: [String: Any] { ["frame_id": frameId, "data": data, "width": width, "height": height] }
}

public struct GraphValidation: Equatable, Sendable {
    public var errors: [String]
    public var ok: Bool { errors.isEmpty }
    /// "The graph didn't pass validation: <first> (+N more)"
    public var message: String? {
        guard let first = errors.first else { return nil }
        let more = errors.count > 1 ? " (+\(errors.count - 1) more)" : ""
        return "The graph didn’t pass validation: \(first)\(more)"
    }
}

public enum FlowExportError: Error, CustomStringConvertible, Equatable {
    case notAGraph
    case invalid(GraphValidation)
    public var description: String {
        switch self {
        case .notAGraph: return "The server's graph export was not a JSON object."
        case .invalid(let v): return v.message ?? "The graph didn’t pass validation."
        }
    }
}

public enum FlowExport {
    public static let maxScreenshotWidth = 1200
    public static let jpegQuality = 0.82
    static let networkStatuses: Set<String> = ["observed", "none_observed", "not_captured"]

    /// Parses the raw graph download. Kept as untyped JSON so every field the backend sends survives.
    public static func parseGraph(_ data: Data) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data), let dict = obj as? [String: Any] else { throw FlowExportError.notAGraph }
        return dict
    }

    /// Structural validation before export: unique ids, edges reference nodes, evidence resolves,
    /// network elements only when network activity was observed, every edge cites evidence.
    public static func validate(_ g: [String: Any], evidenceIds: Set<String>?) -> GraphValidation {
        var errors: [String] = []
        let version = g["schema_version"] as? NSNumber
        if version == nil || isBool(version!) || version!.intValue != 1 || version!.doubleValue != 1 {
            errors.append("Unsupported schema_version \(describe(g["schema_version"])) (expected 1).")
        }
        let nodes = g["nodes"] as? [Any]
        let edges = g["edges"] as? [Any]
        if nodes == nil { errors.append("nodes must be an array.") }
        if edges == nil { errors.append("edges must be an array.") }
        let status = g["network_status"] as? String
        if status.map({ !networkStatuses.contains($0) }) ?? true {
            errors.append("network_status must be one of observed, none_observed, not_captured.")
        }
        if let a = g["ambiguities"], !(a is [Any]) { errors.append("ambiguities must be an array.") }
        guard errors.isEmpty, let nodes, let edges else { return GraphValidation(errors: errors) }

        var ids = Set<String>(), nodeIds = Set<String>()
        func checkEvidence(_ owner: String, _ list: Any?) {
            guard let list = list as? [Any] else { errors.append("\(owner): evidence_ids must be an array."); return }
            guard let evidenceIds else { return }
            for id in list where !((id as? String).map(evidenceIds.contains) ?? false) {
                errors.append("\(owner): unknown evidence reference \(describe(id, quoted: false)).")
            }
        }
        for case let n as [String: Any] in nodes {
            guard let id = n["id"] as? String, !id.isEmpty else { errors.append("A node is missing an id."); continue }
            if ids.contains(id) { errors.append("Duplicate element id \(id).") }
            ids.insert(id); nodeIds.insert(id)
            if (n["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true { errors.append("Node \(id): label is empty.") }
            let type = n["type"] as? String
            if type == nil { errors.append("Node \(id): type is missing.") }
            checkEvidence("Node \(id)", n["evidence_ids"])
            if let type, GraphNode.networkTypes.contains(type.lowercased()), status != "observed" {
                errors.append("Node \(id): network node present but network_status is \(status ?? "undefined").")
            }
        }
        if nodes.contains(where: { !($0 is [String: Any]) }) { errors.append("A node is missing an id.") }
        for e in edges {
            guard let e = e as? [String: Any], let id = e["id"] as? String, !id.isEmpty else { errors.append("An edge is missing an id."); continue }
            if ids.contains(id) { errors.append("Duplicate element id \(id).") }
            ids.insert(id)
            if !((e["source"] as? String).map(nodeIds.contains) ?? false) { errors.append("Edge \(id): source \(describe(e["source"], quoted: false)) is not a node.") }
            if !((e["target"] as? String).map(nodeIds.contains) ?? false) { errors.append("Edge \(id): target \(describe(e["target"], quoted: false)) is not a node.") }
            let assoc = e["association"] as? String
            if assoc != "observed" && assoc != "candidate" { errors.append("Edge \(id): association must be observed or candidate.") }
            checkEvidence("Edge \(id)", e["evidence_ids"])
            if let list = e["evidence_ids"] as? [Any], list.isEmpty { errors.append("Edge \(id) cites no supporting evidence.") }
        }
        return GraphValidation(errors: errors)
    }

    /// For each screen node (graph order), the first of its evidence ids that is a frame with a fetchable image.
    public static func screenFrames(_ g: [String: Any], frames: [RemoteFrame]) -> [(nodeId: String, frame: RemoteFrame)] {
        var byId: [String: RemoteFrame] = [:]
        for f in frames where f.imageUrl != nil { byId[f.id] = f }
        var out: [(String, RemoteFrame)] = []
        var seen = Set<String>()
        for case let n as [String: Any] in (g["nodes"] as? [Any]) ?? [] {
            guard n["type"] as? String == "screen", let id = n["id"] as? String, let ev = n["evidence_ids"] as? [Any] else { continue }
            if let frame = ev.lazy.compactMap({ byId[String(describing: $0)] }).first, seen.insert(id).inserted { out.append((id, frame)) }
        }
        return out
    }

    /// Downscales to `maxWidth` and re-encodes as JPEG so a whole export stays a few MB.
    public static func encodeScreenshot(_ image: Data, frameId: String, maxWidth: Int = maxScreenshotWidth) -> ExportScreenshot? {
        guard maxWidth > 0, let src = CGImageSourceCreateWithData(image as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              sourceWidth > 0, sourceHeight > 0 else { return nil }
        // Decode a thumbnail directly, avoiding a full Retina bitmap before downscaling.
        let longestSide = max(maxWidth, Int((Double(maxWidth) * Double(sourceHeight) / Double(sourceWidth)).rounded()))
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: longestSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary) else { return nil }
        let scale = min(1, Double(maxWidth) / Double(cg.width))
        let w = max(1, Int((Double(cg.width) * scale).rounded())), h = max(1, Int((Double(cg.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        guard let out = ScreenshotCompression.jpeg(scaled, quality: jpegQuality) else { return nil }
        return ExportScreenshot(frameId: frameId, data: "data:image/jpeg;base64," + out.base64EncodedString(), width: w, height: h)
    }

    /// The file the FigJam plugin imports: the graph as downloaded, plus `screenshots` when any were embedded.
    public static func document(graph: [String: Any], screenshots: [String: ExportScreenshot]) throws -> Data {
        var doc = graph
        if !screenshots.isEmpty { doc["screenshots"] = screenshots.mapValues(\.json) }
        return try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// `retrace-<app-slug>-<first 8 of session id>.graph.json`
    public static func filename(appName: String, sessionId: String) -> String {
        var slug = ""
        var dash = false
        for ch in appName.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { slug.append(ch); dash = false }
            else if !dash { slug.append("-"); dash = true }
        }
        slug = String(slug.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(48))
        return "retrace-\(slug.isEmpty ? "session" : slug)-\(sessionId.prefix(8)).graph.json"
    }

    static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

    static func describe(_ v: Any?, quoted: Bool = true) -> String {
        switch v {
        case nil, is NSNull: return quoted ? "undefined" : "undefined"
        case let s as String: return quoted ? "\"\(s)\"" : s
        case let n as NSNumber: return isBool(n) ? (n.boolValue ? "true" : "false") : n.stringValue
        default: return String(describing: v!)
        }
    }
}
