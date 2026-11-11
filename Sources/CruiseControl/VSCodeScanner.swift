import AppKit
import ApplicationServices
import CruiseCore

/// A pending VS Code tool confirmation from a chat dialog or the Sessions sidebar.
struct VSCodeConfirmation {
    let allow: AXUIElement
    let allowLabel: String
    /// What the agent wants to do, e.g. "Run in terminal: Build the app: swift build".
    let request: String
    let key: String
    let window: AXUIElement
    let sidebarThread: String?
    let threadTitle: String?
    let appPID: pid_t
    let windowTitle: String
    let navigationRow: AXUIElement?
    var writeMetadataOnly = false
    var toolPermission = false
    var urlFetch: Bool { request.hasPrefix(VSCodeApprovalContext.urlFetchPrefix) }
}

struct VSCodePendingRequestNotice: Identifiable {
    let id: String
    let requestKey: String?
    let title: String
    let workspace: String
    let detail: String
    let window: AXUIElement
    let navigationRow: AXUIElement?
    let appPID: pid_t
    let automaticallyReviewable: Bool
    var interactionTargets: [AXUIElement] = []
}

struct VSCodeAttentionThread {
    let window: AXUIElement
    let row: AXUIElement
    let previousRow: AXUIElement
    let title: String
    let previousTitle: String
    let rowLabel: String
    let appPID: pid_t
    let windowTitle: String
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
            let detail = description.hasPrefix("Allow once: ") || description.hasPrefix("Chat Confirmation Dialog ")
                ? description : String(description.prefix(700))
            lines.append("\(String(repeating: " ", count: depth))\(role) | \(title.prefix(250)) | \(detail)")
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
        var dialogDescription = ""
        var dialogFiles: [String] = []
        var dialogSummaries: [String] = []
        var allow: (AXUIElement, String)?
        var inDialog = false
        var confirmations: [Dialog] = []
        var session = ""
    }

    private struct Dialog {
        let allow: AXUIElement
        let label: String
        let title: String?
        let description: String
        let files: [String]
        let summaries: [String]
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
                let windowKey = "\(app.processIdentifier)|\(CFHash(window))|\(windowTitle)"
                let rows = sidebarRows(in: window)
                for row in rows {
                    guard rows.filter({ $0.title == row.title }).count == 1,
                          row.buttons.count == 1, let button = row.buttons.first,
                          AX.isEnabled(button.0),
                          let request = VSCodeApprovalContext.sidebarRequest(button.1) else { continue }
                    confirmations.append(VSCodeConfirmation(
                        allow: button.0, allowLabel: "Allow once", request: request,
                        key: "\(windowKey)|sidebar|\(row.title)|\(request)",
                        window: window, sidebarThread: row.title, threadTitle: row.title,
                        appPID: app.processIdentifier, windowTitle: windowTitle, navigationRow: row.element))
                }
                for dialog in w.confirmations {
                    let metadata = VSCodeApprovalContext.writeMetadataRequest(
                        description: dialog.description, files: dialog.files, summaries: dialog.summaries)
                    let isWrite = VSCodeApprovalContext.isFileMutationDialog(dialog.description)
                    let isTool = VSCodeApprovalContext.isToolPermissionDialog(dialog.description)
                    let toolRequest = VSCodeApprovalContext.toolPermissionRequest(
                        description: dialog.description, allowLabel: dialog.label)
                    let fetchRequest = VSCodeApprovalContext.urlFetchDialogRequest(title: dialog.title, requests: w.requests)
                    let request = fetchRequest ?? (isTool ? toolRequest : isWrite ? metadata : dialog.title.flatMap {
                        VSCodeApprovalContext.dialogRequest(title: $0, description: dialog.description, requests: w.requests)
                    })
                    if let request = request.map(VSCodeApprovalContext.classifyFetch) {
                        let matchingRows = rows.filter { !$0.title.isEmpty && $0.title == w.session }
                        confirmations.append(VSCodeConfirmation(
                            allow: dialog.allow, allowLabel: dialog.label, request: request,
                            key: "\(windowKey)|\(w.session)|\(request)",
                            window: window, sidebarThread: nil, threadTitle: w.session.isEmpty ? nil : w.session,
                            appPID: app.processIdentifier, windowTitle: windowTitle,
                            navigationRow: matchingRows.count == 1 ? matchingRows.first?.element : nil,
                            writeMetadataOnly: !request.hasPrefix(VSCodeApprovalContext.urlFetchPrefix) && metadata != nil,
                            toolPermission: !request.hasPrefix(VSCodeApprovalContext.urlFetchPrefix) && isTool))
                    }
                }
            }
        }
        return confirmations
    }

    /// Read-only notices for recognized approval controls and explicit Sessions states that say user attention is needed.
    /// Other VS Code extensions may not expose equivalent Accessibility state; those cases are intentionally not guessed.
    func pendingRequestNotices() -> [VSCodePendingRequestNotice] {
        var byID: [String: VSCodePendingRequestNotice] = [:]
        for confirmation in scanAll() {
            let thread = confirmation.threadTitle
            let id = Self.noticeID(pid: confirmation.appPID, window: confirmation.window, thread: thread)
            let autoReviewable = config.vscodeApprovalsActive
                && (!confirmation.writeMetadataOnly || config.vscodeAllowWriteMetadata)
                && (!confirmation.toolPermission || config.vscodeAllowToolPermissions)
                && (!confirmation.urlFetch || config.vscodeURLFetchPolicy != .hold)
            let detail: String
            if confirmation.urlFetch { detail = "Web-content request needs your review" }
            else if confirmation.toolPermission { detail = "Tool permission needs your review" }
            else if confirmation.writeMetadataOnly { detail = "File-change request needs your review" }
            else { detail = "Command or tool request needs your review" }
            byID[id] = VSCodePendingRequestNotice(
                id: id, requestKey: confirmation.key,
                title: thread ?? (confirmation.windowTitle.isEmpty ? "VS Code chat" : confirmation.windowTitle),
                workspace: confirmation.windowTitle.isEmpty ? "Visual Studio Code" : confirmation.windowTitle,
                detail: detail, window: confirmation.window, navigationRow: confirmation.navigationRow,
                appPID: confirmation.appPID, automaticallyReviewable: autoReviewable,
                interactionTargets: [confirmation.allow])
        }

        for id in config.vscodeBundleIDs {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) where !app.isTerminated {
                let root = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(root, 1)
                AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                let windows: [AXUIElement] = AX.attr(root, kAXWindowsAttribute) ?? []
                for window in windows {
                    let rows = sidebarRows(in: window)
                    let windowTitle: String = AX.attr(window, kAXTitleAttribute) ?? ""
                    for row in rows {
                        let status = VSCodeApprovalContext.attentionStatus(row.label)
                        guard status != nil || !row.buttons.isEmpty else { continue }
                        let noticeID = Self.noticeID(pid: app.processIdentifier, window: window, thread: row.title)
                        guard byID[noticeID] == nil else { continue }
                        byID[noticeID] = VSCodePendingRequestNotice(
                            id: noticeID, requestKey: nil, title: row.title,
                            workspace: windowTitle.isEmpty ? "Visual Studio Code" : windowTitle,
                            detail: status.map { "Waiting for your input · \($0)" }
                                ?? "Approval request needs your review",
                            window: window, navigationRow: row.element,
                            appPID: app.processIdentifier, automaticallyReviewable: false)
                    }
                }
            }
        }
        return byID.values.sorted {
            if $0.workspace != $1.workspace { return $0.workspace < $1.workspace }
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.id < $1.id
        }
    }

    private static func noticeID(pid: pid_t, window: AXUIElement, thread: String?) -> String {
        "\(pid)|\(CFHash(window))|\(thread ?? "chat")"
    }

    /// Nil means the owning row/window disappeared, not that the approval succeeded.
    func isResolved(_ confirmation: VSCodeConfirmation) -> Bool? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(confirmation.window, &pid) == .success else { return nil }
        let windows: [AXUIElement] = AX.attr(AXUIElementCreateApplication(pid), kAXWindowsAttribute) ?? []
        guard windows.contains(where: { CFEqual($0, confirmation.window) }) else { return nil }
        guard let thread = confirmation.sidebarThread else {
            return !scanAll().contains { $0.key == confirmation.key }
        }
        let rows = sidebarRows(in: confirmation.window).filter { $0.title == thread }
        guard rows.count == 1, let row = rows.first else { return nil }
        return !row.buttons.contains {
            VSCodeApprovalContext.sidebarRequest($0.1) == confirmation.request
        }
    }

    private struct SidebarRow {
        let title: String
        let label: String
        let element: AXUIElement
        var buttons: [(AXUIElement, String)] = []
    }

    private func sidebarRows(in window: AXUIElement) -> [SidebarRow] {
        var rows: [SidebarRow] = []
        var visited = 0
        var complete = true
        func visit(_ element: AXUIElement, depth: Int, inSessions: Bool, rowIndex: Int?) {
            guard depth < 70, visited < 15000 else {
                complete = false
                return
            }
            visited += 1
            let values = AX.multi(element, Self.attrNames)
            let role = values[0] as? String ?? ""
            let title = values[1] as? String ?? ""
            let description = values[2] as? String ?? ""
            let label = title.isEmpty ? description : title
            let inside = inSessions || (role == kAXOutlineRole && label == "Sessions")
            var current = rowIndex
            if inside, role == kAXRowRole {
                current = nil
                if let title = VSCodeApprovalContext.threadTitle(label) {
                    current = rows.count
                    rows.append(SidebarRow(title: title, label: label, element: element))
                }
            }
            if inside, let current, role == kAXButtonRole,
               description.hasPrefix("Allow once: ") {
                rows[current].buttons.append((element, description))
            }
            for child in values[3] as? [AXUIElement] ?? [] {
                visit(child, depth: depth + 1, inSessions: inside, rowIndex: current)
            }
        }
        visit(window, depth: 0, inSessions: false, rowIndex: nil)
        return complete ? rows : []
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
            w.dialogDescription = desc
            w.dialogFiles = []
            w.dialogSummaries = []
            w.allow = nil
            entered = true
        }
        // The dialog's text area is labelled with just the request title; its group description can be stale.
        if w.inDialog, role == kAXTextAreaRole, w.dialogTitle == nil, !desc.isEmpty {
            w.dialogTitle = desc
        }
        if w.inDialog, role == "AXLink" {
            let label = title.isEmpty ? desc : title
            if !label.isEmpty { w.dialogFiles.append(label) }
        }
        if w.inDialog, role == kAXButtonRole {
            let label = title.isEmpty ? desc : title
            if VSCodeApprovalContext.isFileChangeSummary(label) { w.dialogSummaries.append(label) }
            if Matcher.isVSCodeAllow(label, config: config), AX.isEnabled(e) { w.allow = (e, label) }
            if VSCodeApprovalContext.isToolPermissionDialog(w.dialogDescription),
               Matcher.normalize(label) == "allow in this session", AX.isEnabled(e) { w.allow = (e, label) }
            return
        }
        for child in children { walk(child, depth: depth + 1, &w) }
        if entered {
            if let allow = w.allow {
                w.confirmations.append(Dialog(allow: allow.0, label: allow.1, title: w.dialogTitle,
                                              description: w.dialogDescription, files: w.dialogFiles,
                                              summaries: w.dialogSummaries))
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
                                                           title: title, previousTitle: session, rowLabel: row.1,
                                                           appPID: app.processIdentifier,
                                                           windowTitle: AX.attr(window, kAXTitleAttribute) ?? ""))
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
