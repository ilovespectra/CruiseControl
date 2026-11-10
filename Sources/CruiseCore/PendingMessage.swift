import Foundation

/// A HeyClicky follow-up saved before it is typed, so a lost draft is retried rather than silently dropped.
public struct PendingMessage: Codable, Equatable {
    public let task: String
    public let text: String
    public let transcript: [String]
    public var createdAt = Date()
    public var submissionAttempted = false
    public private(set) var holdReason: String?

    /// Old messages require review; they remain on disk until delivered or explicitly discarded.
    public static let maxAge: TimeInterval = 30 * 60
    private static let contextLength = 24

    public init(task: String, text: String, transcript: [String], createdAt: Date = Date()) {
        self.task = task
        self.text = text
        self.transcript = transcript
        self.createdAt = createdAt
    }

    public enum Delivery {
        case delivered, ready, held, superseded
    }

    public func isExpired(now: Date = Date()) -> Bool {
        now.timeIntervalSince(createdAt) > Self.maxAge
    }

    public mutating func hold(_ reason: String) {
        holdReason = reason
    }

    public func delivery(selectedTask: String?, input: String?, transcript current: [String]) -> Delivery {
        guard let selectedTask, Matcher.normalize(selectedTask) == Matcher.normalize(task),
              let input else { return .held }
        let body = Self.trim(text)
        let previousCount = transcript.filter { Self.trim($0) == body }.count
        if input.isEmpty, current.filter({ Self.trim($0) == body }).count > previousCount {
            return .delivered
        }
        guard holdReason == nil else { return .held }
        guard input.isEmpty || Self.trim(input) == body else { return .held }
        // The "Message <task>…" placeholder is only listed while the composer is empty.
        var context = current.filter { TaskAudit.composerTask($0) == nil }
        let snapshot = transcript.filter { TaskAudit.composerTask($0) == nil }
        // The scanner lists the composer's draft first, before the conversation.
        if !input.isEmpty, let index = context.firstIndex(where: { Self.trim($0) == body }) {
            context.remove(at: index)
        }
        // Compare the recent conversation only: long transcripts are trimmed from the front.
        let length = min(Self.contextLength, snapshot.count)
        guard context.count >= length, Array(context.suffix(length)) == Array(snapshot.suffix(length)) else {
            return .superseded
        }
        // An empty composer after submission is ambiguous, not permission to resend.
        if input.isEmpty, submissionAttempted { return .held }
        return .ready
    }

    private static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
