import Foundation

/// The graph's screens, actions and API calls as an editable label list (human corrections over
/// agent labels), grouped by type and in the order they happened.
public enum GraphLabels {
    public struct Item: Equatable, Identifiable, Sendable {
        public var id: String
        public var type: String
        /// What the agent named it.
        public var agentLabel: String
        /// The label shown: the correction when there is one.
        public var label: String
        public var corrected: Bool
    }

    public struct Section: Equatable, Identifiable, Sendable {
        public var type: String
        public var title: String
        public var items: [Item]
        public var id: String { type }
    }

    public static let types: [(type: String, title: String)] = [("screen", "Screens"), ("action", "Actions"), ("api_call", "API calls")]

    /// Same limit as the backend's `CorrectionPut.label`.
    public static let maxLabel = 300

    /// Sections for the detail's graph; empty types are left out.
    public static func sections(_ d: RemoteSessionDetail) -> [Section] {
        guard let graph = d.graph else { return [] }
        let corrections = Dictionary(d.corrections.map { ($0.elementId, $0.label) }, uniquingKeysWith: { _, b in b })
        let times = d.evidenceTimes
        let indexed = graph.nodes.enumerated().filter { !$0.element.id.isEmpty }
        return types.compactMap { t in
            let items = indexed.filter { $0.element.type == t.type }
                .map { (i, n) in (time: n.evidenceIds.compactMap { times[$0] }.min() ?? Int.max, index: i, node: n) }
                .sorted { ($0.time, $0.index) < ($1.time, $1.index) }
                .map { e -> Item in
                    let c = corrections[e.node.id]
                    return Item(id: e.node.id, type: t.type, agentLabel: e.node.label, label: c ?? e.node.label, corrected: c != nil)
                }
            return items.isEmpty ? nil : Section(type: t.type, title: t.title, items: items)
        }
    }

    /// The label the backend would store (printable characters, collapsed whitespace), or nil if blank or too long.
    public static func clean(_ s: String) -> String? {
        let printable = String(String.UnicodeScalarView(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        let text = printable.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty, text.count <= maxLabel else { return nil }
        return text
    }

    /// Ids the correction endpoints accept (`graph.ELEMENT_ID_RE` on the backend).
    public static func isValidElementId(_ id: String) -> Bool {
        id.range(of: #"^(screen|action|api_call|edge):[A-Za-z0-9:_>-]{1,160}$"#, options: .regularExpression) != nil
    }
}

extension RemoteSessionDetail {
    /// Earliest capture time of each evidence id.
    var evidenceTimes: [String: Int] {
        var t: [String: Int] = [:]
        for f in frames { t[f.id] = f.timestampMs }
        for i in interactions { if let ts = i.timestampMs { t[i.id] = ts } }
        for n in network { t[n.id] = n.timestampMs }
        return t
    }

    /// Sets (or with nil removes) the human label of one graph element.
    public func settingCorrection(_ elementId: String, label: String?) -> RemoteSessionDetail {
        var d = self
        d.corrections.removeAll { $0.elementId == elementId }
        if let label { d.corrections.append(RemoteCorrection(elementId: elementId, label: label)) }
        return d
    }

    /// The current correction of one element, if any.
    public func correction(_ elementId: String) -> RemoteCorrection? { corrections.last { $0.elementId == elementId } }
}
