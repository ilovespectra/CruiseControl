import Foundation

public enum VSCodeApprovalContext {
    public static func request(matching title: String, in requests: [String]) -> String? {
        let normalized = Matcher.normalize(title)
        guard !normalized.isEmpty else { return nil }
        let candidates = requests.flatMap { request in
            request.components(separatedBy: ", Run in terminal: ").enumerated().map { index, text in
                index == 0 ? text : "Run in terminal: \(text)"
            }
        }.filter { Matcher.normalize($0).hasPrefix(normalized + ":") }
        let matches = Set(candidates)
        return matches.count == 1 ? matches.first : nil
    }

    public static func threadTitle(_ label: String) -> String? {
        guard let state = label.range(of: ", State: ", options: .backwards) else { return nil }
        var title = String(label[..<state.lowerBound])
        if let updated = title.range(of: ", updated ", options: .backwards) {
            title = String(title[..<updated.lowerBound])
        }
        return title.isEmpty ? nil : title
    }

    public static func needsAttention(_ label: String) -> Bool {
        guard let state = label.range(of: ", State: ", options: .backwards) else { return false }
        let status = Matcher.normalize(String(label[state.upperBound...]))
        return ["attention needed", "needs input", "input needed", "needs attention"].contains(status)
    }
}
