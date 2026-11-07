import Foundation

/// Converts a key press into either a safe, named key/shortcut or "text" (which must be
/// redacted). Works only from the hardware virtual key code and modifier flags; the typed
/// character is never consulted, so no text content can leak through this path.
public enum KeyNaming {
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
        public static let function = Modifiers(rawValue: 1 << 4)
    }

    public enum Classification: Equatable, Sendable {
        /// Safe to record verbatim.
        case named(String)
        /// Printable input: record only that typing happened (`"redacted"`).
        case text
    }

    public static let redacted = "redacted"

    /// Non-printing keys that are safe to name (Carbon kVK_* codes, ANSI layout positions).
    static let namedKeys: [UInt16: String] = [
        36: "return", 76: "enter", 48: "tab", 51: "delete", 117: "forward_delete", 53: "escape",
        123: "left", 124: "right", 125: "down", 126: "up",
        115: "home", 119: "end", 116: "page_up", 121: "page_down", 114: "help",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8",
        101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

    /// Positions used only to name command/control shortcuts like `cmd+s`.
    static let shortcutKeys: [UInt16: String] = [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h", 34: "i", 38: "j",
        40: "k", 37: "l", 46: "m", 45: "n", 31: "o", 35: "p", 12: "q", 15: "r", 1: "s",
        17: "t", 32: "u", 9: "v", 13: "w", 7: "x", 16: "y", 6: "z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        27: "minus", 24: "equal", 33: "left_bracket", 30: "right_bracket", 41: "semicolon",
        39: "quote", 43: "comma", 47: "period", 44: "slash", 42: "backslash", 50: "grave", 49: "space",
    ]

    public static func classify(keyCode: UInt16, modifiers: Modifiers) -> Classification {
        if let name = namedKeys[keyCode] {
            return .named(prefix(modifiers, includeShift: true) + name)
        }
        // A shortcut needs command or control. Option/shift alone produce characters.
        if modifiers.contains(.command) || modifiers.contains(.control), let name = shortcutKeys[keyCode] {
            return .named(prefix(modifiers, includeShift: true) + name)
        }
        return .text
    }

    static func prefix(_ m: Modifiers, includeShift: Bool) -> String {
        var parts: [String] = []
        if m.contains(.control) { parts.append("ctrl") }
        if m.contains(.option) { parts.append("opt") }
        if includeShift, m.contains(.shift) { parts.append("shift") }
        if m.contains(.command) { parts.append("cmd") }
        return parts.isEmpty ? "" : parts.joined(separator: "+") + "+"
    }

    /// Every key value allowed in a manifest. Used by the validator as a last line of defence.
    public static func isSafeKeyValue(_ value: String) -> Bool {
        if value == redacted { return true }
        let parts = value.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let base = parts.last, !base.isEmpty else { return false }
        let mods = parts.dropLast()
        let allowedMods: Set<String> = ["ctrl", "opt", "shift", "cmd"]
        guard mods.allSatisfy({ allowedMods.contains($0) }), Set(mods).count == mods.count else { return false }
        if Set(namedKeys.values).contains(base) { return true }
        if Set(shortcutKeys.values).contains(base) { return mods.contains("cmd") || mods.contains("ctrl") }
        return false
    }
}
