import Foundation

public enum VSCodeChatIdentity {
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

    public static func confirmsFollowUp(_ message: String, before: String, after: String) -> Bool {
        let message = Matcher.normalize(message)
        return !message.isEmpty && !Matcher.normalize(before).contains(message)
            && Matcher.normalize(after).contains(message)
    }
}
