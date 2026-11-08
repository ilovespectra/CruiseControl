import Foundation

public enum CopilotUsage {
    public static let cutoffs = [25, 50, 75, 90, 95, 100]

    public static func percentage(in notification: String) -> Double? {
        let pattern = #"\byou(?:'|’| ha)ve\s+used\s+(\d{1,3}(?:\.\d+)?)\s*%\s+of\s+your\s+(?:(?:monthly|included|Copilot|premium|AI)\s+)*(?:credits|premium requests)\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(notification.startIndex..., in: notification)
        let percentages = expression.matches(in: notification, range: range).compactMap { match -> Double? in
            guard let numberRange = Range(match.range(at: 1), in: notification),
                  let value = Double(notification[numberRange]), (0...100).contains(value) else { return nil }
            return value
        }
        return percentages.max()
    }
}
