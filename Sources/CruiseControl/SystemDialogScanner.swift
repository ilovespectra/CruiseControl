import AppKit
import ApplicationServices
import CruiseCore

/// A macOS automation / permission alert triggered by HeyClicky, e.g.
/// "HeyClicky" wants access to control "Reason".
struct SystemDialog {
    let allow: AXUIElement?
    let deny: AXUIElement?
    let message: String
    let ownerPID: pid_t
}

/// These alerts are owned by a system agent (UserNotificationCenter / coreservicesd), not by HeyClicky, so they
/// don't show up in `ClickyScanner`. We only ever touch an alert whose text names HeyClicky.
struct SystemDialogScanner {
    let config: Config

    private static let attrNames = [
        kAXRoleAttribute as String,
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
        kAXValueAttribute as String,
        kAXChildrenAttribute as String,
    ]

    func scan() -> SystemDialog? {
        let names = config.clickyAppNames.map { $0.lowercased() }
        for id in config.systemDialogBundleIDs {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) where !app.isTerminated {
                let axApp = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(axApp, 0.5)
                let windows: [AXUIElement] = AX.attr(axApp, kAXWindowsAttribute) ?? []
                for window in windows {
                    var ctx = Context()
                    walk(window, depth: 0, ctx: &ctx)
                    // Only HeyClicky's own prompts, and only when the user can actually allow.
                    let text = ctx.message.lowercased()
                    guard ctx.allow != nil || ctx.deny != nil,
                          names.contains(where: { text.contains($0) }) else { continue }
                    return SystemDialog(allow: ctx.allow, deny: ctx.deny, message: ctx.message, ownerPID: app.processIdentifier)
                }
            }
        }
        return nil
    }

    private struct Context {
        var message = ""
        var allow: AXUIElement?
        var deny: AXUIElement?
    }

    private func walk(_ e: AXUIElement, depth: Int, ctx: inout Context) {
        guard depth < 20 else { return }
        let v = AX.multi(e, Self.attrNames)
        let role = v[0] as? String ?? ""
        let title = v[1] as? String ?? ""
        let desc = v[2] as? String ?? ""
        let value = v[3] as? String ?? ""
        let children = v[4] as? [AXUIElement] ?? []

        switch role {
        case kAXButtonRole:
            let label = title.isEmpty ? (desc.isEmpty ? value : desc) : title
            if ctx.allow == nil, Matcher.matches(label, any: config.systemAllowLabels) {
                ctx.allow = e
            } else if ctx.deny == nil, Matcher.matches(label, any: config.systemDenyLabels) {
                ctx.deny = e
            }
        case kAXStaticTextRole:
            if !value.isEmpty { ctx.message += (ctx.message.isEmpty ? "" : " ") + value }
        default:
            break
        }
        for child in children { walk(child, depth: depth + 1, ctx: &ctx) }
    }
}
