import Foundation

/// Newest release listed in a Sparkle appcast.
public struct AppcastRelease: Equatable, Sendable {
    public let build: Int
    public let version: String

    /// Picks the item with the highest `sparkle:version` from appcast XML.
    public static func latest(inAppcast xml: String) -> AppcastRelease? {
        var best: AppcastRelease?
        for item in xml.components(separatedBy: "<item>").dropFirst() {
            guard let buildText = tag("sparkle:version", in: item), let build = Int(buildText) else { continue }
            let version = tag("sparkle:shortVersionString", in: item) ?? buildText
            if build > (best?.build ?? Int.min) { best = AppcastRelease(build: build, version: version) }
        }
        return best
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Written right before Cruise Control presses HeyClicky's "Update app" so the nudge survives the relaunch
/// (and a restart of Cruise Control itself).
public struct PendingRelaunch: Codable, Equatable, Sendable {
    public var requestedAt: Date
    public var clickyPID: Int32
    public var fromVersion: String
    /// Sidebar tasks that were in progress, e.g. ["Rippa Repair"].
    public var tasks: [String]
    public var relaunchAttempts = 0

    public init(requestedAt: Date, clickyPID: Int32, fromVersion: String, tasks: [String]) {
        self.requestedAt = requestedAt
        self.clickyPID = clickyPID
        self.fromVersion = fromVersion
        self.tasks = tasks
    }

    public static let lifetime: TimeInterval = 30 * 60

    public func isExpired(now: Date) -> Bool {
        now.timeIntervalSince(requestedAt) > Self.lifetime
    }

    /// HeyClicky is back as a new process.
    public func hasRelaunched(currentPID: Int32) -> Bool {
        currentPID != 0 && currentPID != clickyPID
    }
}

/// A sidebar row in HeyClicky's chat window, e.g. "Rippa Repair, working".
public struct TaskRow: Equatable, Sendable {
    public let name: String
    public let status: String

    public static let activeStatuses: Set<String> = ["working", "you", "needs you", "running", "thinking", "interrupted"]

    public var isActive: Bool { Self.activeStatuses.contains(Matcher.normalize(status)) }

    public static func parse(_ label: String) -> TaskRow? {
        guard !Matcher.hasTimestamp(label) else { return nil }
        let parts = label.components(separatedBy: ", ")
        guard parts.count == 2 else { return nil }
        let name = parts[0].trimmingCharacters(in: .whitespaces)
        let status = parts[1].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !status.isEmpty, status.count <= 20 else { return nil }
        return TaskRow(name: name, status: status)
    }

    /// Tasks worth resuming after a relaunch: the active ones, at most `limit`.
    public static func resumable(_ labels: [String], limit: Int = 3) -> [String] {
        var seen = Set<String>()
        return labels.compactMap(parse).filter(\.isActive).map(\.name)
            .filter { seen.insert($0).inserted }
            .prefix(limit).map { $0 }
    }
}

/// Notices when HeyClicky's conversation has gone quiet (e.g. a task card says "done" and Clicky asked a question
/// nobody answered) so Cruise Control can reply on the user's behalf.
public struct StallTracker: Sendable {
    public static let busyStatuses: Set<String> = ["working", "sent", "running", "thinking", "queued", "in progress"]
    public static let cardStatuses: Set<String> = busyStatuses.union(["done", "you", "needs you", "failed", "error", "stopped", "stopped by you", "paused", "cancelled", "canceled", "blocked", "interrupted"])

    public private(set) var fingerprint = ""
    public private(set) var changedAt = Date.distantPast
    private var answered: [String] = []

    public init() {}

    /// Feed the latest conversation lines (oldest first).
    public mutating func observe(_ lines: [String], now: Date) {
        let fp = Self.fingerprint(lines)
        guard !fp.isEmpty, fp != fingerprint else { return }
        fingerprint = fp
        changedAt = now
    }

    public static func fingerprint(_ lines: [String]) -> String {
        lines.suffix(4).map(Matcher.normalize).joined(separator: "\n")
    }

    /// "Rippa Repair, sent, 12:16 PM" → ("Rippa Repair", "sent").
    public static func headerCard(_ label: String) -> (task: String, status: String)? {
        guard Matcher.hasTimestamp(label) else { return nil }
        let parts = label.components(separatedBy: ", ")
        guard parts.count >= 3, cardStatuses.contains(Matcher.normalize(parts[1])) else { return nil }
        return (parts[0], parts[1])
    }

    /// The collapsed notch reads "HeyClicky, 1 working".
    public static func workingCount(_ label: String) -> Int? {
        let n = Matcher.normalize(label)
        guard let range = n.range(of: #"(\d+) working$"#, options: .regularExpression) else { return nil }
        return Int(n[range].split(separator: " ")[0])
    }

    public static func isBusy(_ status: String?) -> Bool {
        status.map { busyStatuses.contains(Matcher.normalize($0)) } ?? false
    }

    public func isStalled(now: Date, status: String?, quietMinutes: Double, busyQuietMinutes: Double) -> Bool {
        guard !fingerprint.isEmpty, !answered.contains(fingerprint) else { return false }
        let limit = (Self.isBusy(status) ? busyQuietMinutes : quietMinutes) * 60
        return now.timeIntervalSince(changedAt) >= limit
    }

    /// One reply per stall: the same quiet conversation is never answered twice.
    public mutating func markAnswered() {
        answered.append(fingerprint)
        if answered.count > 20 { answered.removeFirst() }
    }
}
