import Foundation

/// Label matching shared by the Accessibility scanner and the OCR fallback.
public enum Matcher {
    public static func normalize(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
        let collapsed = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ".!?:…").union(.whitespaces))
    }

    /// Pulls the quoted targets out of a system alert like
    /// "“HeyClicky” wants access to control “Reason”." → "HeyClicky → Reason".
    public static func quotedSubjects(_ message: String) -> String {
        let parts = message.components(separatedBy: CharacterSet(charactersIn: "\u{201C}\u{201D}\""))
        let quoted = stride(from: 1, to: parts.count, by: 2).map { parts[$0] }.filter { !$0.isEmpty }
        var seen = Set<String>()
        return quoted.filter { seen.insert($0).inserted }.joined(separator: " \u{2192} ")
    }

    /// Exact match, or a label followed by an accessibility suffix (e.g. "Full report, button").
    public static func matches(_ label: String, any labels: [String]) -> Bool {
        let n = normalize(label)
        guard !n.isEmpty else { return false }
        return labels.contains { raw in
            let l = normalize(raw)
            return !l.isEmpty && (n == l || n.hasPrefix(l + ","))
        }
    }

    private static let allowPattern = try! NSRegularExpression(pattern: "^let \\S+ drive$")

    public static func isAllow(_ label: String, config: Config) -> Bool {
        if matches(label, any: config.allowLabels) { return true }
        let n = normalize(label)
        return allowPattern.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) != nil
    }

    public static func isDeny(_ label: String, config: Config) -> Bool {
        matches(label, any: config.denyLabels)
    }

    public static func isReport(_ label: String, config: Config) -> Bool {
        matches(label, any: config.reportLabels)
    }

    public static func isNeedsYou(_ text: String, config: Config) -> Bool {
        let n = normalize(text)
        return config.needsYouLabels.contains { normalize($0) == n }
    }

    public static func isDismiss(_ label: String, config: Config) -> Bool {
        let n = normalize(label)
        return config.dismissLabels.contains { normalize($0) == n }
    }

    public static func isTaskDismissButton(_ label: String) -> Bool {
        ["close", "dismiss", "x", "xmark", "x mark", "close task", "dismiss task"].contains(normalize(label))
    }

    /// Sidebar row for a task, e.g. "Rippa Repair, working" (not a timestamped message header).
    public static func isTaskRow(_ label: String, title: String) -> Bool {
        let n = normalize(label), t = normalize(title)
        return !t.isEmpty && (n == t || n.hasPrefix(t + ",")) && !hasTimestamp(label)
    }

    public static func isUpdate(_ label: String, config: Config) -> Bool {
        let n = normalize(label)
        return config.updateLabels.contains { normalize($0) == n }
    }

    public static func isOpenChat(_ label: String, config: Config) -> Bool {
        let n = normalize(label)
        return config.openChatLabels.contains { normalize($0) == n }
    }

    /// A line where HeyClicky hands control back after the user took over, e.g. "Ok, it's all yours".
    /// Returns the matched line (last one in `lines`) or nil. Matching is a normalized substring test so the
    /// surrounding sentence ("Ok, it's all yours — ping me when you want me back") still triggers.
    public static func handoffLine(in lines: [String], config: Config) -> String? {
        let needles = config.interruptLabels.map { normalize($0) }.filter { !$0.isEmpty }
        guard !needles.isEmpty else { return nil }
        for line in lines.reversed() {
            let n = normalize(line)
            guard !n.isEmpty else { continue }
            if needles.contains(where: { n.contains($0) }) { return line }
        }
        return nil
    }

    /// Notch card header like "Rippa Repair, Interrupted" → "Rippa Repair".
    public static func interruptedCardTask(_ label: String, config: Config) -> String? {
        guard !hasTimestamp(label), let comma = label.range(of: ", ", options: .backwards) else { return nil }
        let task = label[..<comma.lowerBound].trimmingCharacters(in: .whitespaces)
        let status = normalize(String(label[comma.upperBound...]))
        guard !task.isEmpty, !TaskRecovery.isStopped(status),
              config.interruptedStatuses.contains(where: { normalize($0) == status }) else { return nil }
        return task
    }

    public static func isRetry(_ label: String, config: Config) -> Bool {
        matches(label, any: config.retryLabels)
    }

    /// Timeout/error cards name the task in the toast; the inline card belongs to the verified chat.
    public static func failedTask(_ label: String, selectedTask: String?) -> String? {
        let prefix = "Didn't finish "
        if label.hasPrefix(prefix),
           let end = label.range(of: ". ", range: label.index(label.startIndex, offsetBy: prefix.count)..<label.endIndex) {
            let task = String(label[label.index(label.startIndex, offsetBy: prefix.count)..<end.lowerBound])
            return task.isEmpty ? nil : task
        }
        if label.hasPrefix("Didn't finish. ") { return selectedTask }
        return nil
    }

    public static func isVSCodeAllow(_ label: String, config: Config) -> Bool {
        let n = normalize(label)
        return config.vscodeAllowLabels.contains { normalize($0) == n }
    }

    public static func isSend(_ label: String, config: Config) -> Bool {
        let n = normalize(label)
        return config.sendLabels.contains { normalize($0) == n }
    }

    // MARK: OCR helpers (search inside a longer recognized line)

    private static let ocrAllowPattern = try! NSRegularExpression(pattern: "let\\s+\\S+\\s+drive", options: [.caseInsensitive])

    public static func allowRange(in text: String, config: Config) -> Range<String.Index>? {
        for label in config.allowLabels.sorted(by: { $0.count > $1.count }) {
            if let r = text.range(of: label, options: [.caseInsensitive, .diacriticInsensitive]) { return r }
        }
        if let m = ocrAllowPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            return Range(m.range, in: text)
        }
        return nil
    }

    public static func denyRange(in text: String, config: Config) -> Range<String.Index>? {
        for label in config.denyLabels.sorted(by: { $0.count > $1.count }) {
            if let r = text.range(of: label, options: [.caseInsensitive, .diacriticInsensitive]) { return r }
        }
        return nil
    }

    // MARK: Timestamps in chat headers ("Rippa Repair, done, 7:38 AM")

    private static let timePattern = try! NSRegularExpression(
        pattern: "(\\d{1,2}):(\\d{2})\\s*([ap]\\.?m\\.?)?",
        options: [.caseInsensitive]
    )

    public static func hasTimestamp(_ label: String) -> Bool {
        timePattern.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil
    }

    public static func timestamp(in label: String, now: Date, calendar: Calendar = .current) -> Date? {
        let ns = label as NSString
        guard let m = timePattern.firstMatch(in: label, range: NSRange(location: 0, length: ns.length)),
              var hour = Int(ns.substring(with: m.range(at: 1))),
              let minute = Int(ns.substring(with: m.range(at: 2))),
              hour < 24, minute < 60 else { return nil }
        if m.range(at: 3).location != NSNotFound {
            let ampm = ns.substring(with: m.range(at: 3)).lowercased()
            hour = hour % 12 + (ampm.hasPrefix("p") ? 12 : 0)
        }
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        guard var date = calendar.date(from: comps) else { return nil }
        if label.lowercased().contains("yesterday") || date.timeIntervalSince(now) > 120 {
            date = calendar.date(byAdding: .day, value: -1, to: date) ?? date
        }
        return date
    }

    /// Headers without a recognizable time are treated as fresh.
    public static func isFresh(header: String, now: Date, maxAge: TimeInterval, calendar: Calendar = .current) -> Bool {
        guard let t = timestamp(in: header, now: now, calendar: calendar) else { return true }
        return now.timeIntervalSince(t) <= maxAge
    }
}
