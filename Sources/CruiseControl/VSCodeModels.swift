import AppKit
import ApplicationServices
import CruiseCore

struct VSCodeModelChat {
    let window: AXUIElement
    let picker: AXUIElement
    let key: String
    let bundleIdentifier: String
    let appPID: pid_t
    let windowTitle: String
    let taskTitle: String
    let workspaceDirectory: String?
    let model: String
    let transcript: String
    let running: Bool
    let draft: String
    let input: AXUIElement
    let send: AXUIElement?
}

enum VSCodeModels {
    private static let attributes = [
        kAXRoleAttribute as String, kAXTitleAttribute as String,
        kAXDescriptionAttribute as String, kAXValueAttribute as String,
        kAXChildrenAttribute as String,
    ]

    static func scan(config: Config) -> VSCodeModelChat? {
        try? inspect(config: config)
    }

    static func inspect(config: Config) throws -> VSCodeModelChat {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let id = app.bundleIdentifier, config.vscodeBundleIDs.contains(id) else {
            throw ModelError.action("VS Code is not the foreground app; no background chat was chosen")
        }
        return try inspect(config: config, targetWindow: nil, bundleIdentifier: id,
                           processID: app.processIdentifier, expectedKey: nil)
    }

    static func inspect(config: Config, session: VSCodeVisibleSession) throws -> VSCodeModelChat {
        func selectExactSession() throws {
            guard !session.ambiguous,
                  let app = NSRunningApplication(processIdentifier: session.appPID), !app.isTerminated,
                  app.bundleIdentifier == session.bundleIdentifier,
                  VSCodeScanner(config: config).openTaskSession(session),
                  VSCodeScanner(config: config).selectedThread(in: session.window) == session.title else {
                throw ModelError.action("the exact VS Code session could not be selected or was ambiguous; nothing was sent")
            }
        }
        try selectExactSession()
        var attempt = 0
        while true {
            do {
                return try inspect(config: config, targetWindow: session.window,
                                   bundleIdentifier: session.bundleIdentifier, processID: session.appPID,
                                   expectedKey: session.key)
            } catch let error as ModelError {
                // VS Code renders a newly selected session asynchronously, and a closed Chat panel hides it entirely.
                let composerVisible: Bool
                switch error {
                case .chatHidden(let visible): composerVisible = visible
                case .staleView: composerVisible = true
                default: throw error
                }
                attempt += 1
                guard attempt <= 4 else {
                    throw ModelError.action("the selected VS Code session never showed a chat view in “\(session.windowTitle)”; nothing was sent")
                }
                if !composerVisible, attempt == 2 { _ = revealChat(in: session.window, processID: session.appPID) }
                Thread.sleep(forTimeInterval: 1)
                try selectExactSession()
            }
        }
    }

    /// Presses the window's own "Toggle Chat" control; only called when no chat view is visible, so it never hides one.
    private static func revealChat(in window: AXUIElement, processID: pid_t) -> Bool {
        let root = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(root, 0.75)
        var nodes: [(AXUIElement, String, String, String)] = []
        var visited = 0
        collect(window, depth: 0, visited: &visited, into: &nodes)
        guard let toggle = nodes.first(where: { $0.1 == kAXButtonRole && $0.2 == "Toggle Chat" }) else { return false }
        return AX.press(toggle.0)
    }

    private static func inspect(config: Config, targetWindow: AXUIElement?, bundleIdentifier: String,
                                processID: pid_t, expectedKey: String?) throws -> VSCodeModelChat {
        let id = bundleIdentifier
        let root = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(root, 0.75)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let window: AXUIElement
        if let targetWindow {
            let windows: [AXUIElement] = AX.attr(root, kAXWindowsAttribute) ?? []
            guard windows.contains(where: { CFEqual($0, targetWindow) }) else {
                throw ModelError.action("the discovered VS Code window closed before its session could be read")
            }
            window = targetWindow
        } else if let focused: AXUIElement = AX.attr(root, kAXFocusedWindowAttribute) {
            window = focused
        } else {
            throw ModelError.action("VS Code has no accessible focused window")
        }
        var nodes: [(AXUIElement, String, String, String)] = []
        var visited = 0
        collect(window, depth: 0, visited: &visited, into: &nodes)
        let pickers = nodes.filter { $0.1 == kAXPopUpButtonRole && $0.2.hasPrefix("Models, ") }
        // Split editors can contain multiple chats: never choose an arbitrary one.
        if pickers.isEmpty { throw ModelError.chatHidden(composerVisible: nodes.contains { $0.2.hasPrefix("Chat Input (") }) }
        guard pickers.count == 1, let picker = pickers.first,
              let chat = nodes.first(where: { $0.1 == kAXListRole && $0.2 == "Chat" }),
              let input = nodes.first(where: { $0.2.hasPrefix("Chat Input (") }) else {
            throw ModelError.action("expected exactly one model picker plus a readable Chat list and composer; found \(pickers.count) model pickers")
        }
        let children: [AXUIElement] = AX.attr(chat.0, kAXChildrenAttribute) ?? []
        let rows = children.flatMap { child -> [String] in
            let label: String = AX.attr(child, kAXDescriptionAttribute) ?? ""
            if !label.isEmpty { return [label] }
            var descendants: [(AXUIElement, String, String, String)] = []
            var count = 0
            collect(child, depth: 0, visited: &count, into: &descendants)
            return descendants.filter { $0.1 == kAXGroupRole && !$0.2.isEmpty }.map(\.2)
        }
        let title: String = AX.attr(window, kAXTitleAttribute) ?? ""
        // The task title beside "Pick Agent Session" distinguishes chats in the same window.
        let sessionIndex = nodes.firstIndex { $0.2 == "Pick Agent Session" }
        let legacyTask = sessionIndex.flatMap { index in
            nodes.dropFirst(index + 1).prefix(5).first { $0.1 == kAXStaticTextRole && !$0.3.isEmpty && $0.3 != "Copilot" }?.3
        }
        let task = VSCodeChatIdentity.taskName(sessionLabels: nodes.filter { $0.1 == kAXGroupRole }.map(\.2),
                                               legacyTask: legacyTask)
        guard let task else { throw ModelError.action("chat session identity is missing or ambiguous") }
        guard !rows.isEmpty, !rows.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelError.action("chat report is unreadable")
        }
        guard let inputValue = AX.stringValue(input.0) else {
            throw ModelError.action("composer value is unreadable; an empty draft cannot be proven")
        }
        let scanner = VSCodeScanner(config: config)
        if targetWindow != nil, scanner.selectedThread(in: window) != task {
            throw expectedKey == nil ? ModelError.action("selected VS Code sidebar session does not match the readable chat; no action was taken")
                : ModelError.staleView
        }
        guard let key = scanner.sessionKey(title: task, in: window, bundleIdentifier: id, windowTitle: title),
              expectedKey == nil || expectedKey == key else {
            throw ModelError.action("the session title is missing, duplicated, or scoped to another workspace")
        }
        let matches = scanner.visibleTaskSessions().filter { $0.key == key }
        guard matches.count == 1, !matches[0].ambiguous else {
            throw ModelError.action("the session is duplicated or ambiguous; no follow-up will be sent")
        }
        return VSCodeModelChat(
            window: window, picker: picker.0, key: key, bundleIdentifier: id, appPID: processID,
            windowTitle: title, taskTitle: task, workspaceDirectory: matches[0].discoveredDirectory,
            model: String(picker.2.dropFirst("Models, ".count)),
            transcript: String(rows.joined(separator: "\n").suffix(12000)),
            running: !nodes.contains { $0.1 == kAXButtonRole && $0.2.hasPrefix("Send") }
                || nodes.contains { $0.1 == kAXButtonRole && ($0.2.hasPrefix("Cancel (") || $0.2.hasPrefix("Stop (")) }
                || rows.contains { $0.lowercased().hasPrefix("chat confirmation required:") },
            // An empty Monaco composer reads back as "\n"; whitespace alone is not a user draft.
            draft: inputValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : inputValue,
            input: input.0,
            send: nodes.first { $0.1 == kAXButtonRole && $0.2.hasPrefix("Send") }?.0
        )
    }

    /// Re-reads only the same PID, window and selected session as the reviewed chat. It never falls back to the frontmost chat.
    private static func scan(config: Config, matching chat: VSCodeModelChat) -> VSCodeModelChat? {
        guard let app = NSRunningApplication(processIdentifier: chat.appPID), !app.isTerminated,
              app.bundleIdentifier == chat.bundleIdentifier else { return nil }
        let root = AXUIElementCreateApplication(chat.appPID)
        let windows: [AXUIElement] = AX.attr(root, kAXWindowsAttribute) ?? []
        guard windows.contains(where: { CFEqual($0, chat.window) }),
              VSCodeScanner(config: config).selectedThread(in: chat.window) == chat.taskTitle else { return nil }
        return try? inspect(config: config, targetWindow: chat.window,
                            bundleIdentifier: chat.bundleIdentifier, processID: chat.appPID,
                            expectedKey: chat.key)
    }

    /// `replaceDraft` lets an opted-in Auto-bump overwrite stale composer text instead of waiting on it.
    @MainActor
    static func sendFollowUp(_ message: String, chat: VSCodeModelChat, config: Config, replaceDraft: Bool = false,
                             shouldContinue: () -> Bool) async throws {
        let scanner = VSCodeScanner(config: config)
        let previousThread = scanner.selectedThread(in: chat.window)
        let switching = previousThread != chat.taskTitle
        if switching {
            ScreenControlActivity.announce("Preparing to send to VS Code: \(chat.taskTitle). Pause typing briefly.")
            let interaction = InputSynth.UserInteractionWatch()
            defer { interaction.stop() }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            guard !interaction.interrupted, shouldContinue(),
                  let session = scanner.visibleTaskSessions().first(where: {
                      $0.key == chat.key && CFEqual($0.window, chat.window) && !$0.ambiguous
                  }), scanner.openTaskSession(session) else {
                throw ModelError.notSent("input interrupted the announced switch, or the exact chat was unavailable")
            }
        }
        defer {
            if switching, let previousThread, scanner.selectedThread(in: chat.window) == chat.taskTitle,
               !scanner.restoreThread(titled: previousThread, in: chat.window) {
                ScreenControlActivity.announce("Could not restore VS Code: \(previousThread). Please select it in Sessions.")
                NSLog("Cruise Control: could not restore VS Code thread %@", previousThread)
            }
        }
        guard shouldContinue(), let fresh = scan(config: config, matching: chat), fresh.key == chat.key,
              VSCodeChatIdentity.sameLatestTurn(chat.transcript, fresh.transcript), !fresh.running, replaceDraft || fresh.draft.isEmpty,
              fresh.send != nil, replaceComposer(fresh.input, with: message, processID: fresh.appPID) else {
            throw ModelError.notSent("exact chat changed, draft exists, or composer is unavailable; follow-up not sent")
        }
        // Verify the exact composer synchronously before clicking; no quiet-time or post-draft delay is inserted.
        guard shouldContinue(), let ready = scan(config: config, matching: chat), ready.key == chat.key,
              VSCodeChatIdentity.sameLatestTurn(chat.transcript, ready.transcript), composer(ready.draft, matches: message), !ready.running,
              let button = ready.send, AX.isEnabled(button) else {
            throw ModelError.notSent("composer changed while preparing the follow-up; draft left unsent")
        }
        guard AX.press(button) else { throw ModelError.notSent("couldn't press Send; the follow-up was not submitted") }
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 200_000_000)
            if let verified = scan(config: config, matching: chat), verified.key == chat.key,
               verified.draft.isEmpty,
               VSCodeChatIdentity.confirmsFollowUp(message, before: chat.transcript, after: verified.transcript) { return }
        }
        throw ModelError.action("follow-up submission could not be verified; not resending")
    }

    private static func composer(_ value: String, matches message: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines) == message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// VS Code's Monaco composer accepts AXValue writes without applying them, so fall back to
    /// select-all + paste delivered to VS Code's process; the user's clipboard is restored afterwards.
    private static func replaceComposer(_ input: AXUIElement, with message: String, processID: pid_t) -> Bool {
        if AX.setValue(input, message), let value = AX.stringValue(input), composer(value, matches: message) { return true }
        guard AX.setFocused(input) else { return false }
        usleep(150_000)
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        pasteboard.clearContents()
        pasteboard.setString(message, forType: .string)
        defer {
            pasteboard.clearContents()
            let items = saved.map { entries -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
        for key: CGKeyCode in [0, 9] { // ⌘A, ⌘V
            ScreenControlActivity.announce("Writing to a VS Code task")
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return false }
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.postToPid(processID)
            up.postToPid(processID)
            usleep(150_000)
        }
        for _ in 0..<10 {
            if let value = AX.stringValue(input), composer(value, matches: message) { return true }
            usleep(100_000)
        }
        return false
    }

    static func open(_ chat: VSCodeModelChat) throws {
        if options(chat).contains(where: { ModelRouting.normalize($0.1) == ModelRouting.normalize(chat.model) }) { return }
        guard let frame = AX.frame(chat.picker) else { throw ModelError.action("model picker has no visible frame") }
        InputSynth.click(at: CGPoint(x: frame.midX, y: frame.midY))
    }

    static func options(_ chat: VSCodeModelChat) -> [(AXUIElement, String)] {
        var nodes: [(AXUIElement, String, String, String)] = []
        var visited = 0
        collect(chat.window, depth: 0, visited: &visited, into: &nodes)
        return nodes.filter { $0.1 == kAXMenuItemRole }
            .map { ($0.0, ($0.2.isEmpty ? $0.3 : $0.2).components(separatedBy: ", ").first ?? "") }
    }

    static func select(_ model: String, chat: VSCodeModelChat, config: Config, allowRunning: Bool = false,
                       shouldContinue: () -> Bool = { true }) async throws {
        guard shouldContinue(), let fresh = scan(config: config), fresh.key == chat.key, fresh.model == chat.model,
              allowRunning || (!fresh.running && fresh.draft.isEmpty && fresh.transcript == chat.transcript) else {
            throw ModelError.action("the active chat changed; model selection cancelled")
        }
        try open(fresh)
        var selected = false
        defer {
            if !selected, let focused = scan(config: config), focused.key == chat.key, !options(fresh).isEmpty {
                InputSynth.key(53)
            }
        }
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 200_000_000)
            let candidates = options(fresh).filter { ModelRouting.normalize($0.1) == ModelRouting.normalize(model) }
            if candidates.count == 1, let option = candidates.first {
                guard shouldContinue(), let focused = scan(config: config), focused.key == chat.key,
                      allowRunning || (!focused.running && focused.draft.isEmpty),
                      let frame = AX.frame(option.0) else {
                    throw ModelError.action("chat changed or model option is not visible")
                }
                InputSynth.click(at: CGPoint(x: frame.midX, y: frame.midY))
                selected = true
                for _ in 0..<10 {
                    try await Task.sleep(nanoseconds: 200_000_000)
                    guard let verified = scan(config: config), verified.key == chat.key else {
                        throw ModelError.action("active chat changed before selection could be verified")
                    }
                    if ModelRouting.normalize(verified.model) == ModelRouting.normalize(model) { return }
                }
                throw ModelError.action("model picker did not confirm \(model)")
            }
        }
        throw ModelError.action("\(model) is unavailable or its picker label is ambiguous")
    }

    private static func collect(_ element: AXUIElement, depth: Int, visited: inout Int,
                                into nodes: inout [(AXUIElement, String, String, String)]) {
        guard depth < 70, visited < 15000 else { return }
        visited += 1
        let values = AX.multi(element, attributes)
        let role = values[0] as? String ?? ""
        let title = values[1] as? String ?? ""
        let description = values[2] as? String ?? ""
        let value = values[3] as? String ?? ""
        nodes.append((element, role, title.isEmpty ? description : title, value))
        for child in values[4] as? [AXUIElement] ?? [] {
            collect(child, depth: depth + 1, visited: &visited, into: &nodes)
        }
    }

    enum ModelError: LocalizedError {
        case action(String)
        case chatHidden(composerVisible: Bool)
        /// The sidebar already shows the target session but the chat view still renders the previous one.
        case staleView
        /// Failed before Send was pressed, so retrying cannot duplicate a message.
        case notSent(String)
        var errorDescription: String? {
            switch self {
            case .action(let message), .notSent(let message): return message
            case .staleView: return "the chat view did not switch to the selected session; no action was taken"
            case .chatHidden: return "the VS Code Chat panel is closed, so the selected session is not readable; nothing was sent"
            }
        }
    }
}
