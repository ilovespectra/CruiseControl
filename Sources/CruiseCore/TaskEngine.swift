import Foundation

/// Where the user goes to clear a blocker. Every blocker shown in the task panels carries one.
public enum TaskFix: String, Codable, Equatable, Sendable {
    case defineDone, chooseFolder, reviewReport, showInHeyClicky, openVSCodeChat, resumeStopped,
         resetRounds, automationSettings, ollamaSettings, permissions, activity, refreshTasks

    public var title: String {
        switch self {
        case .defineDone: "Go there · Done"
        case .chooseFolder: "Go there · Folder"
        case .reviewReport: "Review now"
        case .showInHeyClicky: "Go there · HeyClicky"
        case .openVSCodeChat: "Go there · VS Code chat"
        case .resumeStopped: "Resume auto-bump"
        case .resetRounds: "Reset rounds"
        case .automationSettings: "Go there · Automation"
        case .ollamaSettings: "Go there · Ollama"
        case .permissions: "Go there · Permissions"
        case .activity: "Go there · Activity"
        case .refreshTasks: "Refresh tasks"
        }
    }
}

public struct TaskBlocker: Codable, Equatable, Sendable {
    public var reason: String
    public var fix: TaskFix?

    public init(_ reason: String, fix: TaskFix? = nil) {
        self.reason = reason
        self.fix = fix
    }
}

/// One task's place in the examine → draft → send pipeline.
public struct TaskEngineRecord: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable {
        case needsDone, waitingForReport, agentWorking, examining, drafted, met, queued, sending, sent, held, failed

        public var title: String {
            switch self {
            case .needsDone: "Needs Done"
            case .waitingForReport: "No response yet"
            case .agentWorking: "Agent working"
            case .examining: "Examining"
            case .drafted: "Draft ready"
            case .met: "Done met"
            case .queued: "Queued to send"
            case .sending: "Sending"
            case .sent: "Sent"
            case .held: "Held"
            case .failed: "Send failed"
            }
        }
    }

    public var key: String
    public var provider: String
    public var title: String
    public var stage: Stage
    public var detail: String
    public var blocker: TaskBlocker?
    public var draft: String?
    public var missing: [String]
    /// Hash of everything a draft depends on; a change means the task must be examined again.
    public var inputsKey: String
    public var autoBump: Bool
    public var updatedAt: Date
    public var examinedAt: Date?
    public var lastSentAt: Date?
    public var nextRetryAt: Date?
    public var failures: Int

    public init(key: String, provider: String, title: String, stage: Stage, detail: String,
                blocker: TaskBlocker? = nil, draft: String? = nil, missing: [String] = [],
                inputsKey: String = "", autoBump: Bool = false, updatedAt: Date = Date()) {
        self.key = key
        self.provider = provider
        self.title = title
        self.stage = stage
        self.detail = detail
        self.blocker = blocker
        self.draft = draft
        self.missing = missing
        self.inputsKey = inputsKey
        self.autoBump = autoBump
        self.updatedAt = updatedAt
        self.failures = 0
    }

    public var waitingToSend: Bool { autoBump && draft != nil && [.drafted, .queued, .failed].contains(stage) && blocker == nil }
}

/// Fields compared on every pass so metadata changes are logged once, as they happen.
public struct TaskMetadata: Codable, Equatable, Sendable {
    public var title: String
    public var exists: Bool
    public var status: String
    public var folder: String?
    public var done: String?
    public var autoBump: Bool
    public var plan: String
    public var report: String

    public init(title: String, exists: Bool = true, status: String, folder: String?, done: String?,
                autoBump: Bool, plan: String, report: String) {
        self.title = title
        self.exists = exists
        self.status = status
        self.folder = folder
        self.done = done
        self.autoBump = autoBump
        self.plan = plan
        self.report = report
    }

    public static func changes(from old: TaskMetadata?, to new: TaskMetadata) -> [String] {
        guard let old else { return ["tracked (\(new.status))"] }
        var lines: [String] = []
        if old.exists != new.exists { lines.append(new.exists ? "reappeared" : "no longer found") }
        if old.title != new.title { lines.append("renamed from “\(old.title)”") }
        if old.status != new.status { lines.append("status \(old.status) → \(new.status)") }
        if old.folder != new.folder { lines.append(new.folder.map { "folder set to \($0)" } ?? "folder cleared") }
        if old.done != new.done { lines.append(new.done == nil ? "Done cleared" : old.done == nil ? "Done defined" : "Done changed") }
        if old.autoBump != new.autoBump { lines.append("auto-bump \(new.autoBump ? "on" : "off")") }
        if old.plan != new.plan { lines.append("finish preferences changed") }
        if old.report != new.report { lines.append("new response") }
        return lines
    }
}

public struct TaskEngineCache: Codable, Equatable, Sendable {
    public var records: [String: TaskEngineRecord] = [:]
    public var metadata: [String: TaskMetadata] = [:]
    /// Stopped HeyClicky tasks the user explicitly resumed in Cruise, keyed by task ID → report fingerprint at resume.
    /// A newer stop produces a new report, so the release never outlives the stop it was granted for.
    public var resumed: [String: String] = [:]
    public var reviewOnlyInputs: [String: String] = [:]
    public var deliveredBumps: [String: Set<String>] = [:]

    public func alreadyDelivered(_ key: String, definition: String, message: String) -> Bool {
        deliveredBumps[key]?.contains(Self.inputsKey([DefinitionOfDone.normalized(definition),
                                                    message.trimmingCharacters(in: .whitespacesAndNewlines)])) == true
    }

    public mutating func recordDelivery(_ key: String, definition: String, message: String) {
        deliveredBumps[key, default: []].insert(Self.inputsKey([DefinitionOfDone.normalized(definition),
                                                              message.trimmingCharacters(in: .whitespacesAndNewlines)]))
    }

    public mutating func holdForReview(_ key: String, report: String, definition: String) {
        reviewOnlyInputs[key] = Self.inputsKey([report, DefinitionOfDone.normalized(definition)])
    }

    public func isReviewOnly(_ key: String, report: String, definition: String) -> Bool {
        reviewOnlyInputs[key] == Self.inputsKey([report, DefinitionOfDone.normalized(definition)])
    }

    public init() {}

    private enum CodingKeys: String, CodingKey { case records, metadata, resumed, reviewOnlyInputs, deliveredBumps }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        records = try container.decodeIfPresent([String: TaskEngineRecord].self, forKey: .records) ?? [:]
        metadata = try container.decodeIfPresent([String: TaskMetadata].self, forKey: .metadata) ?? [:]
        resumed = try container.decodeIfPresent([String: String].self, forKey: .resumed) ?? [:]
        reviewOnlyInputs = try container.decodeIfPresent([String: String].self, forKey: .reviewOnlyInputs) ?? [:]
        deliveredBumps = try container.decodeIfPresent([String: Set<String>].self, forKey: .deliveredBumps) ?? [:]
    }

    public static func inputsKey(_ parts: [String?]) -> String {
        ClickyTaskLibrary.hash(parts.map { $0 ?? "∅" }.joined(separator: "\u{1F}"))
    }

    /// Auto-bump drafts waiting to send, oldest draft first; tasks backing off after a failure wait their turn.
    public func sendQueue(now: Date = Date()) -> [String] {
        records.values
            .filter { $0.waitingToSend && ($0.nextRetryAt ?? .distantPast) <= now }
            .sorted { ($0.examinedAt ?? $0.updatedAt, $0.key) < ($1.examinedAt ?? $1.updatedAt, $1.key) }
            .map(\.key)
    }

    /// Tasks needing a fresh examination, least recently examined first, so no task is starved by another.
    public func examineOrder(_ keys: [String]) -> [String] {
        keys.sorted { (records[$0]?.examinedAt ?? .distantPast, $0) < (records[$1]?.examinedAt ?? .distantPast, $1) }
    }

    public static func backoff(failures: Int) -> TimeInterval {
        min(600, 30 * pow(2, Double(max(0, failures - 1))))
    }

    public mutating func recordFailure(_ key: String, reason: String, now: Date = Date()) {
        guard var record = records[key] else { return }
        record.failures += 1
        record.stage = .failed
        record.detail = reason
        record.nextRetryAt = now.addingTimeInterval(Self.backoff(failures: record.failures))
        record.updatedAt = now
        records[key] = record
    }

    public mutating func recordSent(_ key: String, detail: String, now: Date = Date()) {
        guard var record = records[key] else { return }
        record.stage = .sent
        record.detail = detail
        record.lastSentAt = now
        record.failures = 0
        record.nextRetryAt = nil
        record.blocker = nil
        record.updatedAt = now
        records[key] = record
    }

    /// Stores a freshly derived record, keeping send history and failure backoff when the inputs didn't change.
    public mutating func upsert(_ new: TaskEngineRecord) {
        var next = new
        if let old = records[new.key] {
            next.lastSentAt = old.lastSentAt
            next.examinedAt = new.examinedAt ?? old.examinedAt
            if old.inputsKey == new.inputsKey {
                next.failures = old.failures
                next.nextRetryAt = old.nextRetryAt
                if old.stage == .failed, [.drafted, .queued].contains(new.stage) {
                    next.stage = .failed
                    next.detail = old.detail
                }
                if old.stage == .sent, [.drafted, .queued].contains(new.stage) {
                    next.stage = .sent
                    next.detail = old.detail
                }
            }
            if old == next { return }
            if old.stage == next.stage, old.detail == next.detail, old.draft == next.draft,
               old.blocker == next.blocker, old.inputsKey == next.inputsKey { next.updatedAt = old.updatedAt }
        }
        records[new.key] = next
    }

    public mutating func prune(keeping keys: Set<String>) {
        records = records.filter { keys.contains($0.key) }
    }
}
