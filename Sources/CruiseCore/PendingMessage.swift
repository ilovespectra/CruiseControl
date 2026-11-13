import Foundation

/// A HeyClicky follow-up saved before it is typed, so a lost draft is retried rather than silently dropped.
public struct PendingMessage: Codable, Equatable {
    public let task: String
    public let text: String
    public var transcript: [String]
    public var createdAt = Date()
    public var submissionAttempted = false
    public private(set) var holdReason: String?
    public var completionTarget: CompletionTarget?
    public var chatOnly: Bool?
    /// Direct one-shot message the user explicitly requested (for example, pre-finish commit review).
    public var userApprovedOneShot: Bool?

    public struct CompletionTarget: Codable, Equatable, Sendable {
        public let taskID: String
        public let definition: String
        public let reportFingerprint: String?
        /// Explicit user-requested one-shot bump; absent/false requires the task's persistent Auto-bump opt-in.
        public let oneShot: Bool?
        public let workflowKey: String?
        public let workspace: String?

        public init(taskID: String, definition: String, reportFingerprint: String? = nil, oneShot: Bool = false,
                    workflowKey: String? = nil, workspace: String? = nil) {
            self.taskID = taskID
            self.definition = definition
            self.reportFingerprint = reportFingerprint
            self.oneShot = oneShot
            self.workflowKey = workflowKey
            self.workspace = workspace
        }

        public func matches(definition current: String?, enabled: Bool) -> Bool {
            enabled && DefinitionOfDone.normalized(definition) != nil
                && DefinitionOfDone.normalized(definition) == DefinitionOfDone.normalized(current)
        }
    }

    /// Old messages require review; they remain on disk until delivered or explicitly discarded.
    public static let maxAge: TimeInterval = 30 * 60
    public static let conversationChangedHoldReason =
        "Conversation has moved on. Review the saved message; it will not be sent into a changed conversation."
    private static let contextLength = 24

    public init(task: String, text: String, transcript: [String], createdAt: Date = Date(), completionTarget: CompletionTarget? = nil,
                chatOnly: Bool? = nil, userApprovedOneShot: Bool? = nil) {
        self.task = task
        self.text = text
        self.transcript = transcript
        self.createdAt = createdAt
        self.completionTarget = completionTarget
        self.chatOnly = chatOnly
        self.userApprovedOneShot = userApprovedOneShot
    }

    public func automationAllowed(config: Config) -> Bool {
        guard !config.usageCutoffReached else { return false }
        guard let target = completionTarget,
              target.reportFingerprint != nil,
              TaskWorkflow.autoBumpBlocker(plan: config.taskPlans[target.taskID] ?? TaskPlan(), workspace: target.workspace) == nil else { return false }
        if chatOnly != true {
            let oneShot = target.oneShot == true
            guard TaskPlanning.definitionDeliveryAllowed(config: config, oneShot: oneShot) else { return false }
            return target.matches(definition: config.clickyDefinitionsOfDone[target.taskID],
                                  enabled: oneShot || config.continueUntilDefinedDone)
                && (oneShot || (config.taskPlans[target.taskID]?.autoBump == true
                    && TaskWorkflow.autoBumpBlocker(plan: config.taskPlans[target.taskID] ?? TaskPlan(), workspace: target.workspace) == nil))
        }
        guard let target = completionTarget, target.reportFingerprint != nil else { return false }
        return config.backgroundTaskReview && config.backgroundTaskDelivery == .chatOnly && config.ollamaEnabled
            && config.taskPlans[target.taskID]?.enabled == true
            && config.taskPlans[target.taskID]?.autoBump == true
            && target.matches(definition: config.clickyDefinitionsOfDone[target.taskID], enabled: true)
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

    public func canRetryAfterConversationChange(input: String?) -> Bool {
        completionTarget != nil && chatOnly != true && !submissionAttempted && input == ""
    }

    public mutating func rebaseAfterConversationChange(transcript: [String]) {
        self.transcript = transcript
        holdReason = nil
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
