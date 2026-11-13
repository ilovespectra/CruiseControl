import Foundation

public enum VSCodeChatIdentity {
    /// Identity is the app plus the chat title. VS Code's workspace group headers and window titles change with
    /// scrolling and open files, so they are not part of the key; same-titled visible chats are treated as ambiguous.
    public static func stableKey(bundleIdentifier: String, taskTitle: String) -> String {
        let values = [bundleIdentifier, Matcher.normalize(taskTitle)]
        return "vscode:" + ClickyTaskLibrary.hash(values.joined(separator: "\u{1F}"))
    }

    /// The earlier workspace/window-scoped key, kept only so saved settings can be moved to `stableKey`.
    public static func legacyKey(bundleIdentifier: String, workspace: String?, windowTitle: String, taskTitle: String) -> String {
        let candidate = workspace?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let scope = candidate.isEmpty ? windowTitle : candidate
        let values = [bundleIdentifier, Matcher.normalize(scope), Matcher.normalize(taskTitle)]
        return "vscode:" + ClickyTaskLibrary.hash(values.joined(separator: "\u{1F}"))
    }

    public static func taskName(sessionLabels: [String], legacyTask: String?) -> String? {
        let names = Set(sessionLabels.filter { $0.hasPrefix("Session: ") }
            .map { String($0.dropFirst("Session: ".count)).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        guard names.count <= 1 else { return nil }
        if let name = names.first {
            guard legacyTask == nil || legacyTask == name else { return nil }
            return name
        }
        return legacyTask.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// VS Code renders sent messages as Markdown, so compare a distinctive plain-text opening rather than the full text.
    public static func confirmsFollowUp(_ message: String, before: String, after: String) -> Bool {
        let opening = String(plain(message).prefix(160))
        return opening.count >= 20 && !plain(before).contains(opening) && plain(after).contains(opening)
    }

    /// The chat list is virtualized: rows scroll out of the top as the composer grows, so "unchanged" means
    /// the newest part of the conversation (its tail) is identical, not the whole rendered transcript.
    public static func sameLatestTurn(_ before: String, _ after: String) -> Bool {
        let a = plain(before), b = plain(after)
        let tail = min(300, a.count, b.count)
        guard tail >= 40 else { return a == b }
        return a.suffix(tail) == b.suffix(tail)
    }

    private static func plain(_ text: String) -> String {
        let stripped = String(text.unicodeScalars.filter { !"*_`#>-".unicodeScalars.contains($0) })
        return Matcher.normalize(stripped)
    }
}
