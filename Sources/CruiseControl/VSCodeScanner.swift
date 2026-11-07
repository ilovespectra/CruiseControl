import AppKit
import ApplicationServices
import CruiseCore

/// A pending VS Code chat tool confirmation ("Run in terminal: … [Allow Once] [Skip]").
struct VSCodeConfirmation {
    let allow: AXUIElement
    let allowLabel: String
    /// What the agent wants to do, e.g. "Run in terminal: Build the app: swift build".
    let request: String
}

/// Finds VS Code's chat tool confirmation through Accessibility. Electron only builds its web-content tree after an
/// assistive app sets AXManualAccessibility, so the first scan after VS Code launches may come back empty.
struct VSCodeScanner {
    let config: Config

    private static let attrNames = [
        kAXRoleAttribute as String,
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
        kAXChildrenAttribute as String,
    ]
    private static let dialogPrefix = "chat confirmation dialog"
    private static let requiredPrefix = "chat confirmation required:"

    private struct Walk {
        var visited = 0
        /// "Run in terminal: <title>: <command>" for every pending confirmation in the chat list.
        var requests: [String] = []
        /// The dialog's own title, "Run in terminal: <title>" — identifies which request the Allow button belongs to.
        var dialogTitle: String?
        var allow: (AXUIElement, String)?
        var inDialog = false
    }

    func scan() -> VSCodeConfirmation? {
        let apps = config.vscodeBundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .filter { !$0.isTerminated }
        for app in apps {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 1.0)
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            let windows: [AXUIElement] = AX.attr(axApp, kAXWindowsAttribute) ?? []
            for window in windows {
                var w = Walk()
                walk(window, depth: 0, &w)
                if let allow = w.allow, let title = w.dialogTitle,
                   let request = Self.request(matching: title, in: w.requests) {
                    return VSCodeConfirmation(allow: allow.0, allowLabel: allow.1, request: request)
                }
            }
        }
        return nil
    }

    /// VS Code appends the keyboard hint and then the rest of the chat transcript to the accessible description.
    static func trimRequired(_ text: String) -> String {
        var t = text
        if let r = t.range(of: ". Press Command+Enter", options: .caseInsensitive) ?? t.range(of: "Press Command+Enter", options: .caseInsensitive) {
            t = String(t[..<r.lowerBound])
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The pending request whose title matches the dialog. Nil if none or ambiguous — never guess which one Allow approves.
    static func request(matching title: String, in requests: [String]) -> String? {
        let t = Matcher.normalize(title)
        guard !t.isEmpty else { return nil }
        let matches = requests.filter { Matcher.normalize($0).hasPrefix(t) && $0.count > title.count }
        return Set(matches).count == 1 ? matches.first : nil
    }

    private func walk(_ e: AXUIElement, depth: Int, _ w: inout Walk) {
        guard depth < 70, w.visited < 15000, w.allow == nil else { return }
        w.visited += 1
        let v = AX.multi(e, Self.attrNames)
        let role = v[0] as? String ?? ""
        let title = v[1] as? String ?? ""
        let desc = v[2] as? String ?? ""
        let children = v[3] as? [AXUIElement] ?? []

        let lower = desc.lowercased()
        if lower.hasPrefix(Self.requiredPrefix) {
            w.requests.append(Self.trimRequired(String(desc.dropFirst(Self.requiredPrefix.count))))
        }
        var entered = false
        if lower.hasPrefix(Self.dialogPrefix), !w.inDialog {
            w.inDialog = true
            entered = true
        }
        // The dialog's text area is labelled with just the request title; its group description can be stale.
        if w.inDialog, role == kAXTextAreaRole, w.dialogTitle == nil, !desc.isEmpty {
            w.dialogTitle = desc
        }
        if w.inDialog, role == kAXButtonRole {
            let label = title.isEmpty ? desc : title
            if Matcher.isVSCodeAllow(label, config: config), AX.isEnabled(e) { w.allow = (e, label) }
            return
        }
        for child in children { walk(child, depth: depth + 1, &w) }
        if entered { w.inDialog = false }
    }
}
