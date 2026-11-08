import AppKit
import ApplicationServices
import CruiseCore

struct ConsentPrompt {
    let allow: AXUIElement
    let allowLabel: String
    let deny: AXUIElement
    let denyLabel: String
}

struct ReportButton {
    let element: AXUIElement
    let fingerprint: String
    let header: String
    let windowIndex: Int
}

struct Composer {
    let input: AXUIElement
    let send: AXUIElement?
    let pid: pid_t
}

/// The "{task} Needs you" notch card. Its only control is a close (xmark) button.
struct NeedsYouCard {
    let close: AXUIElement
    let task: String
}

/// A notch card like "Rippa Repair, Interrupted · It was cut off before it finished · Retry".
struct InterruptedCard {
    let task: String
    let retry: AXUIElement?
}

/// HeyClicky's "Update app" (notch panel) or Sparkle's "Install & Relaunch" button.
struct UpdateButton {
    let element: AXUIElement
    let label: String
}

struct ScanResult {
    var clickyRunning = false
    var pid: pid_t = 0
    var consent: ConsentPrompt?
    /// Allow/deny buttons that showed up without their counterpart — logged for diagnostics only.
    var orphanConsentLabels: [String] = []
    var reports: [ReportButton] = []
    var composer: Composer?
    var needsYou: NeedsYouCard?
    /// Tasks whose card says "Interrupted" (only exposed while the notch panel is expanded).
    var interrupted: [InterruptedCard] = []
    var update: UpdateButton?
    /// "Open in a window" in the notch panel (only exposed while the panel has been expanded).
    var openChat: AXUIElement?
    /// Conversation lines from the chat window, or from the notch panel when no chat window is open.
    var conversation: [String] = []
    /// Latest task card in that conversation, e.g. ("Rippa Repair", "done").
    var lastCard: (task: String, status: String)?
    /// From the collapsed notch ("HeyClicky, 1 working").
    var workingCount: Int?
    /// Text from the chat window (the one holding the composer), oldest first.
    var transcript: [String] = []
    /// Labelled buttons in the chat window, e.g. sidebar rows like "Rippa Repair, working".
    var chatButtons: [(element: AXUIElement, label: String)] = []
    var recentTasks: [String] = []
    var selectedTask: String?
    var selectedStatus: String?
    var latestReport: String? { transcript.last(where: { $0.count > 200 }) }
}

/// Walks HeyClicky's Accessibility tree looking for the drive consent prompt, "Full report" buttons and the chat composer.
struct ClickyScanner {
    let config: Config

    private static let attrNames = [
        kAXRoleAttribute as String,
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
        kAXValueAttribute as String,
        kAXChildrenAttribute as String,
    ]

    private struct WalkContext {
        var visited = 0
        var allow: [(AXUIElement, String)] = []
        var deny: [(AXUIElement, String)] = []
        var reports: [(AXUIElement, String, String)] = []
        var input: AXUIElement?
        /// Text areas without a send button to anchor them: (element, value length, height).
        var inputs: [(AXUIElement, Int, CGFloat)] = []
        var send: AXUIElement?
        var lastHeader = ""
        var lastText = ""
        var texts: [String] = []
        var buttons: [(element: AXUIElement, label: String)] = []
        var dismiss: AXUIElement?
        var needsYouTask: String?
        var interruptedTask: String?
        var interrupted: [InterruptedCard] = []
        var update: UpdateButton?
        var openChat: AXUIElement?
        var lastCard: (task: String, status: String)?
        var workingCount: Int?
        var inRecents = false
        var recentTasks: [String] = []
        var selectedTask: String?
        var selectedStatus: String?
    }

    func scan() -> ScanResult {
        var result = ScanResult()
        let apps = config.clickyBundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .filter { !$0.isTerminated }
        guard !apps.isEmpty else { return result }
        result.clickyRunning = true

        for app in apps {
            let pid = app.processIdentifier
            result.pid = pid
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.75)
            let windows: [AXUIElement] = AX.attr(axApp, kAXWindowsAttribute) ?? []

            for (index, window) in windows.enumerated() {
                var ctx = WalkContext()
                walk(window, depth: 0, ctx: &ctx)

                if result.consent == nil, let allow = ctx.allow.first, let deny = ctx.deny.first {
                    result.consent = ConsentPrompt(allow: allow.0, allowLabel: allow.1, deny: deny.0, denyLabel: deny.1)
                } else if ctx.allow.isEmpty != ctx.deny.isEmpty {
                    result.orphanConsentLabels += (ctx.allow + ctx.deny).map(\.1)
                }

                for (element, fingerprint, header) in ctx.reports {
                    result.reports.append(ReportButton(element: element, fingerprint: fingerprint, header: header, windowIndex: index))
                }

                // HeyClicky 1.1.3 has no labelled send button: the composer is the short (empty) box, not a report.
                if ctx.send == nil, let box = ctx.inputs.min(by: { ($0.1, $0.2) < ($1.1, $1.2) }) { ctx.input = box.0 }
                if let input = ctx.input, result.composer == nil || (result.composer?.send == nil && ctx.send != nil) {
                    result.composer = Composer(input: input, send: ctx.send, pid: pid)
                    result.transcript = ctx.texts
                    result.chatButtons = ctx.buttons
                    result.conversation = ctx.texts
                    result.lastCard = ctx.lastCard
                    result.selectedTask = ctx.selectedTask
                    result.selectedStatus = ctx.selectedStatus
                    result.recentTasks = ctx.recentTasks
                }
                if let open = ctx.openChat {
                    result.openChat = open
                    if result.conversation.isEmpty {
                        result.conversation = ctx.texts
                        result.lastCard = ctx.lastCard
                    }
                }

                for card in ctx.interrupted where !result.interrupted.contains(where: { $0.task == card.task }) {
                    result.interrupted.append(card)
                }
                if let task = ctx.interruptedTask, !result.interrupted.contains(where: { $0.task == task }) {
                    result.interrupted.append(InterruptedCard(task: task, retry: nil))
                }

                if result.update == nil, let update = ctx.update { result.update = update }
                if let count = ctx.workingCount { result.workingCount = count }

                if result.conversation.isEmpty,
                   !ctx.interrupted.isEmpty || ctx.interruptedTask != nil || ctx.needsYouTask != nil || ctx.lastCard != nil {
                    result.conversation = ctx.texts
                    result.lastCard = ctx.lastCard
                }

                // The chat window has its own "Close" button, so the card must be a composer-less window.
                if result.needsYou == nil, ctx.input == nil, let task = ctx.needsYouTask, let close = ctx.dismiss {
                    result.needsYou = NeedsYouCard(close: close, task: task)
                }
            }
            if result.consent != nil { break }
        }
        return result
    }

    private func walk(_ e: AXUIElement, depth: Int, ctx: inout WalkContext) {
        guard depth < 40, ctx.visited < 8000 else { return }
        ctx.visited += 1

        let v = AX.multi(e, Self.attrNames)
        let role = v[0] as? String ?? ""
        let title = v[1] as? String ?? ""
        let desc = v[2] as? String ?? ""
        let value = v[3] as? String
        let children = v[4] as? [AXUIElement] ?? []

        if let task = Matcher.interruptedCardTask(desc, config: config) {
            if let pending = ctx.interruptedTask, pending != task { ctx.interrupted.append(InterruptedCard(task: pending, retry: nil)) }
            ctx.interruptedTask = task
        }

        switch role {
        case kAXButtonRole, "AXLink":
            var label = title.isEmpty ? desc : title
            if label.isEmpty { label = descendantText(children, depth: 3) }
            if Matcher.isRetry(label, config: config), let task = ctx.interruptedTask {
                ctx.interrupted.append(InterruptedCard(task: task, retry: e))
                ctx.interruptedTask = nil
            }
            if Matcher.isAllow(label, config: config) {
                ctx.allow.append((e, label))
            } else if Matcher.isDeny(label, config: config) {
                ctx.deny.append((e, label))
            } else if Matcher.isReport(label, config: config) {
                let fingerprint = "\(ctx.lastHeader)|\(ctx.lastText.prefix(160))|\(Matcher.normalize(label))"
                ctx.reports.append((e, fingerprint, ctx.lastHeader))
            } else if Matcher.isOpenChat(label, config: config) {
                ctx.openChat = e
            } else if Matcher.isUpdate(label, config: config) {
                if ctx.update == nil { ctx.update = UpdateButton(element: e, label: label) }
            } else if ctx.input != nil, ctx.send == nil, Matcher.isSend(label, config: config) {
                ctx.send = e
            }
            if ctx.dismiss == nil, Matcher.isDismiss(title, config: config) || Matcher.isDismiss(desc, config: config) {
                ctx.dismiss = e
            }
            if !label.isEmpty { ctx.buttons.append((e, label)) }
            if ctx.inRecents, ctx.recentTasks.count < 3,
               !label.contains(", "), !label.isEmpty {
                ctx.recentTasks.append(label)
            }
            if Matcher.hasTimestamp(label) {
                if let card = StallTracker.headerCard(label) { ctx.lastCard = card }
                ctx.lastHeader = label
                ctx.texts.append("— \(label) —")
            }
            // Button labels already summarise their content; skip the subtree.
            if !label.isEmpty { return }
        case kAXStaticTextRole:
            if let value, !value.isEmpty {
                if ctx.selectedStatus == nil, ctx.texts.count < 3, StallTracker.cardStatuses.contains(Matcher.normalize(value)) {
                    ctx.selectedStatus = value
                }
                if value == "RECENTS" { ctx.inRecents = true }
                if let task = TaskAudit.composerTask(value) {
                    ctx.selectedTask = task
                    ctx.inRecents = false
                    ctx.texts = []
                }
                if Matcher.isNeedsYou(value, config: config) {
                    ctx.needsYouTask = ctx.lastText
                }
                ctx.lastText = value
                if ctx.texts.last != value { ctx.texts.append(value) }
                if ctx.texts.count > 400 { ctx.texts.removeFirst(100) }
            }
            return
        case kAXImageRole:
            // Task cards: "Rippa Repair" followed by a status image ("done", "sent", …).
            let status = desc.isEmpty ? title : desc
            if StallTracker.cardStatuses.contains(Matcher.normalize(status)), !ctx.lastText.isEmpty {
                ctx.lastCard = (ctx.lastText, status)
                ctx.texts.append("— \(ctx.lastText) · \(status) —")
            }
            return
        case kAXTextAreaRole, kAXTextFieldRole:
            // The composer is the text area right before the send button; expanded reports are text areas too.
            if ctx.send == nil {
                ctx.input = e
                ctx.inputs.append((e, value?.count ?? 0, AX.frame(e)?.height ?? 0))
            }
            if let value, !value.isEmpty, ctx.texts.last != value { ctx.texts.append(value) }
            return
        default:
            if let count = StallTracker.workingCount(title.isEmpty ? desc : title) { ctx.workingCount = count }
        }

        for child in children {
            walk(child, depth: depth + 1, ctx: &ctx)
        }
    }

    private func descendantText(_ children: [AXUIElement], depth: Int) -> String {
        guard depth > 0 else { return "" }
        for child in children {
            let v = AX.multi(child, Self.attrNames)
            if (v[0] as? String) == kAXStaticTextRole, let s = v[3] as? String, !s.isEmpty { return s }
            let nested = descendantText(v[4] as? [AXUIElement] ?? [], depth: depth - 1)
            if !nested.isEmpty { return nested }
        }
        return ""
    }
}
