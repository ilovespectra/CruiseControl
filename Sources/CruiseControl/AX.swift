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
    static func press(_ e: AXUIElement, requiresUserPause: Bool = true) -> Bool {
        if requiresUserPause { announceControl(e) }
        return AXUIElementPerformAction(e, kAXPressAction as CFString) == .success
    }

    @discardableResult
    static func setFocused(_ e: AXUIElement) -> Bool {
        announceControl(e)
        return AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    @discardableResult
    static func setValue(_ e: AXUIElement, _ text: String) -> Bool {
        announceControl(e)
        return AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, text as CFString) == .success
    }

    private static func announceControl(_ element: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let app = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "another app"
        ScreenControlActivity.announce("Controlling \(app)")
    }

    static func stringValue(_ e: AXUIElement) -> String? {
        attr(e, kAXValueAttribute)
    }

    static func isEnabled(_ e: AXUIElement) -> Bool {
        (attr(e, kAXEnabledAttribute) as Bool?) ?? true
    }

    static func scrollArea(containing element: AXUIElement) -> AXUIElement? {
        var ancestor: AXUIElement? = attr(element, kAXParentAttribute)
        for _ in 0..<12 {
            guard let current = ancestor else { return nil }
            let role: String = attr(current, kAXRoleAttribute) ?? ""
            if role == kAXScrollAreaRole { return current }
            ancestor = attr(current, kAXParentAttribute)
        }
        return nil
    }

    enum RevealResult { case visible, scrolled, unavailable }

    static func revealInScrollArea(_ element: AXUIElement, in area: AXUIElement,
                                   shouldContinue: () -> Bool) -> RevealResult {
        guard let rect = frame(element), let viewport = frame(area),
              rect.minX >= viewport.minX, rect.maxX <= viewport.maxX else { return .unavailable }
        if viewport.contains(rect) { return .visible }
        let point = CGPoint(x: viewport.midX, y: viewport.midY)
        guard shouldContinue(), isUnderPointer(area, at: point) else { return .unavailable }
        InputSynth.move(to: point)
        usleep(40_000)
        guard shouldContinue(), isUnderPointer(area, at: point) else { return .unavailable }
        let distance = viewport.midY - rect.midY
        let pixels = Int32(max(-viewport.height * 8, min(viewport.height * 8, distance)))
        InputSynth.scroll(at: point, pixels: pixels)
        return .scrolled
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
