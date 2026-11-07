import AppKit
import ApplicationServices
import CruiseCore

struct VSCodeModelChat {
    let window: AXUIElement
    let picker: AXUIElement
    let key: String
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
        guard let app = NSWorkspace.shared.frontmostApplication,
              let id = app.bundleIdentifier, config.vscodeBundleIDs.contains(id) else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.75)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window: AXUIElement = AX.attr(root, kAXFocusedWindowAttribute) else { return nil }
        var nodes: [(AXUIElement, String, String, String)] = []
        var visited = 0
        collect(window, depth: 0, visited: &visited, into: &nodes)
        let pickers = nodes.filter { $0.1 == kAXPopUpButtonRole && $0.2.hasPrefix("Models, ") }
        // Split editors can contain multiple chats: never choose an arbitrary one.
        guard pickers.count == 1, let picker = pickers.first,
              let chat = nodes.first(where: { $0.1 == kAXListRole && $0.2 == "Chat" }),
              let input = nodes.first(where: { $0.2.hasPrefix("Chat Input (") }) else { return nil }
        let children: [AXUIElement] = AX.attr(chat.0, kAXChildrenAttribute) ?? []
        let rows = children.compactMap { (AX.attr($0, kAXDescriptionAttribute) as String?) }
        let title: String = AX.attr(window, kAXTitleAttribute) ?? ""
        // The task title beside "Pick Agent Session" distinguishes chats in the same window.
        let sessionIndex = nodes.firstIndex { $0.2 == "Pick Agent Session" }
        let task = sessionIndex.flatMap { index in
            nodes.dropFirst(index + 1).prefix(5).first { $0.1 == kAXStaticTextRole && !$0.3.isEmpty && $0.3 != "Copilot" }?.3
        }
        guard let task else { return nil }
        return VSCodeModelChat(
            window: window, picker: picker.0,
            key: "\(id)|\(title)|\(task)",
            model: String(picker.2.dropFirst("Models, ".count)),
            transcript: String(rows.joined(separator: "\n").suffix(12000)),
            running: !nodes.contains { $0.1 == kAXButtonRole && $0.2.hasPrefix("Send") }
                || nodes.contains { $0.1 == kAXButtonRole && ($0.2.hasPrefix("Cancel (") || $0.2.hasPrefix("Stop (")) }
                || rows.contains { $0.lowercased().hasPrefix("chat confirmation required:") },
            draft: input.3,
            input: input.0,
            send: nodes.first { $0.1 == kAXButtonRole && $0.2.hasPrefix("Send") }?.0
        )
    }

    static func sendFollowUp(_ message: String, chat: VSCodeModelChat, config: Config) async throws {
        guard let fresh = scan(config: config), fresh.key == chat.key,
              fresh.transcript == chat.transcript, !fresh.running, fresh.draft.isEmpty,
              fresh.send != nil, AX.setValue(fresh.input, message) else {
            throw ModelError.action("chat changed, draft exists, or composer is unavailable; follow-up not sent")
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        guard let ready = scan(config: config), ready.key == chat.key,
              ready.transcript == chat.transcript, ready.draft == message, !ready.running,
              let button = ready.send, AX.isEnabled(button) else {
            throw ModelError.action("composer changed while preparing the follow-up; leaving the draft for you")
        }
        guard AX.press(button) else { throw ModelError.action("couldn't send follow-up; leaving the draft for you") }
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 200_000_000)
            if let verified = scan(config: config), verified.key == chat.key,
               verified.draft.isEmpty, verified.running || verified.transcript != chat.transcript { return }
        }
        throw ModelError.action("follow-up submission could not be verified; not resending")
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

    static func select(_ model: String, chat: VSCodeModelChat, config: Config, allowRunning: Bool = false) async throws {
        guard let fresh = scan(config: config), fresh.key == chat.key, fresh.model == chat.model,
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
                guard let focused = scan(config: config), focused.key == chat.key,
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
        var errorDescription: String? {
            switch self { case .action(let message): return message }
        }
    }
}
