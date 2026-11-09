import AppKit
import ApplicationServices

enum AX {
    static func attr<T>(_ e: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    /// Fetches several attributes in one IPC round-trip; missing ones come back as nil.
    static func multi(_ e: AXUIElement, _ names: [String]) -> [Any?] {
        var v: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(e, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &v)
        guard err == .success, let arr = v as? [AnyObject], arr.count == names.count else {
            return Array(repeating: nil, count: names.count)
        }
        return arr.map { item -> Any? in
            if CFGetTypeID(item) == AXValueGetTypeID(), AXValueGetType(item as! AXValue) == .axError { return nil }
            return item
        }
    }

    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let posValue: AXValue = attr(e, kAXPositionAttribute),
              let sizeValue: AXValue = attr(e, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        guard AXValueGetValue(posValue, .cgPoint, &p), AXValueGetValue(sizeValue, .cgSize, &s) else { return nil }
        let r = CGRect(origin: p, size: s)
        return r.width > 0 && r.height > 0 ? r : nil
    }

    @discardableResult
    static func press(_ e: AXUIElement) -> Bool {
        AXUIElementPerformAction(e, kAXPressAction as CFString) == .success
    }

    @discardableResult
    static func setFocused(_ e: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    @discardableResult
    static func setValue(_ e: AXUIElement, _ text: String) -> Bool {
        AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, text as CFString) == .success
    }

    static func stringValue(_ e: AXUIElement) -> String? {
        attr(e, kAXValueAttribute)
    }

    static func isEnabled(_ e: AXUIElement) -> Bool {
        (attr(e, kAXEnabledAttribute) as Bool?) ?? true
    }

    static func isUnderPointer(_ target: AXUIElement, at point: CGPoint) -> Bool {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success
        else { return false }
        for _ in 0..<8 {
            guard let element = hit else { return false }
            if CFEqual(element, target) { return true }
            hit = attr(element, kAXParentAttribute)
        }
        return false
    }
}
