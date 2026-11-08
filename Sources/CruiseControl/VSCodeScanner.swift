import AppKit
import ApplicationServices
import CruiseCore

/// A pending VS Code chat tool confirmation ("Run in terminal: … [Allow Once] [Skip]").
struct VSCodeConfirmation {
    let allow: AXUIElement
    let allowLabel: String
    /// What the agent wants to do, e.g. "Run in terminal: Build the app: swift build".
    let request: String
    let key: String
}

struct VSCodeAttentionThread {
    let window: AXUIElement
    let row: AXUIElement
    let previousRow: AXUIElement
    let title: String
    let previousTitle: String
}

/// Finds VS Code's chat tool confirmation through Accessibility. Electron only builds its web-content tree after an
/// assistive app sets AXManualAccessibility, so the first scan after VS Code launches may come back empty.
struct VSCodeScanner {
    let config: Config

    /// Only notification containers are read; conversation text must not trigger the spending guard.
    func usageNotificationPercentage() -> Double? {
        var highest: Double?
        for id in config.vscodeBundleIDs {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) where !app.isTerminated {
                let root = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(root, 1)
                AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                let windows: [AXUIElement] = AX.attr(root, kAXWindowsAttribute) ?? []
                for window in windows {
                    var visited = 0
                    func visit(_ element: AXUIElement, depth: Int, inNotification: Bool) {
                        guard depth < 70, visited < 15000 else { return }
                        visited += 1
                        let values = AX.multi(element, Self.attrNames)
                        let role = values[0] as? String ?? ""
                        let title = values[1] as? String ?? ""
                        let description = values[2] as? String ?? ""
                        let label = title.isEmpty ? description : title
                        let normalized = label.lowercased()
                        let inside = inNotification || role == "AXAlert"
                            || ((role == kAXGroupRole || role == kAXListRole)
                                && (normalized == "notifications" || normalized.hasPrefix("notification:") || normalized == "notification"))
                        if inside {
                            let value = AX.stringValue(element) ?? ""
                            if let percentage = CopilotUsage.percentage(in: "\(title)\n\(description)\n\(value)") {
                                highest = max(highest ?? 0, percentage)
                            }
                        }
                        for child in values[3] as? [AXUIElement] ?? [] {
                            visit(child, depth: depth + 1, inNotification: inside)
                        }
                    }
                    visit(window, depth: 0, inNotification: false)
                }
            }
        }
        return highest
    }

    func diagnosticTree() -> [String] {
        var lines: [String] = []
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 60, lines.count < 12000 else { return }
            let values = AX.multi(element, Self.attrNames)
            let role = values[0] as? String ?? ""
            let title = values[1] as? String ?? ""
            let description = values[2] as? String ?? ""
            lines.append("\(String(repeating: " ", count: depth))\(role) | \(title.prefix(250)) | \(description.prefix(700))")
            for child in values[3] as? [AXUIElement] ?? [] { visit(child, depth: depth + 1) }
        }
        for id in config.vscodeBundleIDs {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
                let root = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                let windows: [AXUIElement] = AX.attr(root, kAXWindowsAttribute) ?? []
                for window in windows { visit(window, depth: 0) }
            }
        }
        return lines
    }

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
        var confirmations: [(AXUIElement, String, String)] = []
        var session = ""
    }

    func scan() -> VSCodeConfirmation? {
        scanAll().first
    }

    func scanAll() -> [VSCodeConfirmation] {
        var confirmations: [VSCodeConfirmation] = []
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
                let windowTitle: String = AX.attr(window, kAXTitleAttribute) ?? ""
                for (allow, label, title) in w.confirmations {
                    if let request = Self.request(matching: title, in: w.requests) {
                        confirmations.append(VSCodeConfirmation(
                            allow: allow, allowLabel: label, request: request,
                            key: "\(app.processIdentifier)|\(windowTitle)|\(w.session)|\(Matcher.normalize(request))"))
                    }
                }
            }
        }
        return confirmations
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
        VSCodeApprovalContext.request(matching: title, in: requests)
    }

    private func walk(_ e: AXUIElement, depth: Int, _ w: inout Walk) {
        guard depth < 70, w.visited < 15000 else { return }
        w.visited += 1
        let v = AX.multi(e, Self.attrNames)
        let role = v[0] as? String ?? ""
        let title = v[1] as? String ?? ""
        let desc = v[2] as? String ?? ""
        let children = v[3] as? [AXUIElement] ?? []

        let lower = desc.lowercased()
        if lower.hasPrefix("session: ") { w.session = String(desc.dropFirst("Session: ".count)) }
        if lower.hasPrefix(Self.requiredPrefix) {
            w.requests.append(Self.trimRequired(String(desc.dropFirst(Self.requiredPrefix.count))))
        }
        var entered = false
        if lower.hasPrefix(Self.dialogPrefix), !w.inDialog {
            w.inDialog = true
            w.dialogTitle = nil
            w.allow = nil
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
        if entered {
            if let allow = w.allow, let title = w.dialogTitle {
                w.confirmations.append((allow.0, allow.1, title))
            }
            w.inDialog = false
        }
    }

    func attentionThreads() -> [VSCodeAttentionThread] {
        var threads: [VSCodeAttentionThread] = []
        for id in config.vscodeBundleIDs {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) where !app.isTerminated {
                let root = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(root, 1)
                AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                let windows: [AXUIElement] = AX.attr(root, kAXWindowsAttribute) ?? []
                for window in windows {
                    var rows: [(AXUIElement, String)] = []
                    var inlineApprovalRows = Set<Int>()
                    var session: String?
                    var visited = 0
                    func visit(_ element: AXUIElement, depth: Int, inSessions: Bool, rowIndex: Int?) {
                        guard depth < 70, visited < 15000 else { return }
                        visited += 1
                        let values = AX.multi(element, Self.attrNames)
                        let role = values[0] as? String ?? ""
                        let label = (values[1] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (values[2] as? String ?? "")
                        let inside = inSessions || (role == kAXOutlineRole && label == "Sessions")
                        var currentRow = rowIndex
                        if role == kAXGroupRole, label.hasPrefix("Session: ") {
                            session = String(label.dropFirst("Session: ".count))
                        }
                        if inside, role == kAXRowRole, VSCodeApprovalContext.threadTitle(label) != nil {
                            currentRow = rows.count
                            rows.append((element, label))
                        }
                        if inside, let currentRow, role == kAXButtonRole,
                           Matcher.isVSCodeAllow(label, config: config), AX.isEnabled(element) {
                            inlineApprovalRows.insert(currentRow)
                        }
                        for child in values[3] as? [AXUIElement] ?? [] {
                            visit(child, depth: depth + 1, inSessions: inside, rowIndex: currentRow)
                        }
                    }
                    visit(window, depth: 0, inSessions: false, rowIndex: nil)
                    guard let session else { continue }
                    let previous = rows.filter { VSCodeApprovalContext.threadTitle($0.1) == session }
                    guard previous.count == 1, let original = previous.first else { continue }
                    for (index, row) in rows.enumerated() where VSCodeApprovalContext.needsInspection(row.1, hasInlineApproval: inlineApprovalRows.contains(index)) {
                        guard let title = VSCodeApprovalContext.threadTitle(row.1), title != session,
                              rows.filter({ VSCodeApprovalContext.threadTitle($0.1) == title }).count == 1 else { continue }
                        threads.append(VSCodeAttentionThread(window: window, row: row.0, previousRow: original.0,
                                                           title: title, previousTitle: session))
                    }
                }
            }
        }
        return threads
    }

    func selectedThread(in window: AXUIElement) -> String? {
        var names = Set<String>()
        var visited = 0
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 70, visited < 15000 else { return }
            visited += 1
            let values = AX.multi(element, Self.attrNames)
            let label = values[2] as? String ?? ""
            if label.hasPrefix("Session: ") { names.insert(String(label.dropFirst("Session: ".count))) }
            for child in values[3] as? [AXUIElement] ?? [] { visit(child, depth: depth + 1) }
        }
        visit(window, depth: 0)
        return names.count == 1 ? names.first : nil
    }
}
