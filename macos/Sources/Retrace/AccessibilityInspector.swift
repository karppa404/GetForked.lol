import AppKit
import ApplicationServices
import RetraceCore

/// Read-only Accessibility queries. Only structural attributes are read: role, subrole,
/// title, description, placeholder, identifier and window title. `AXValue` (field contents,
/// including passwords) is never requested.
enum AXInspector {
    static let systemWide: AXUIElement = {
        let e = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(e, 0.25)
        return e
    }()

    static func element(at point: CGPoint) -> AXUIElement? {
        var el: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &el)
        return err == .success ? el : nil
    }

    static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    /// PID of the application that currently owns keyboard focus, per Accessibility.
    static func focusedApplicationPID() -> pid_t? {
        guard let app: AXUIElement = attribute(systemWide, kAXFocusedApplicationAttribute) else { return nil }
        return pid(of: app)
    }

    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        return attribute(app, kAXFocusedUIElementAttribute)
    }

    static func snapshot(of element: AXUIElement) -> AccessibilitySnapshot {
        let role: String? = attribute(element, kAXRoleAttribute)
        let subrole: String? = attribute(element, kAXSubroleAttribute)
        let secure = subrole == "AXSecureTextField" || role == "AXSecureTextField"
        var windowTitle: String?
        if let window: AXUIElement = attribute(element, kAXWindowAttribute) {
            windowTitle = attribute(window, kAXTitleAttribute)
        }
        if secure {
            return AccessibilitySnapshot(role: role, subrole: subrole, windowTitle: windowTitle, secure: true).sanitized()
        }
        let label: String? = attribute(element, kAXDescriptionAttribute) ?? attribute(element, kAXPlaceholderValueAttribute)
        return AccessibilitySnapshot(
            role: role, subrole: subrole,
            title: attribute(element, kAXTitleAttribute),
            label: label,
            identifier: attribute(element, kAXIdentifierAttribute),
            windowTitle: windowTitle
        ).sanitized()
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! T)
        }
        return value as? T
    }

    /// Fallback hit test via the window list (front-to-back): owner PID of the topmost
    /// normal/menu-level window containing `point` (global, top-left origin).
    static func windowOwnerPID(at point: CGPoint) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, (0..<100).contains(layer),
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict), bounds.contains(point),
                  let owner = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            return owner
        }
        return nil
    }
}
