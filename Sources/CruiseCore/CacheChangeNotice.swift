import Foundation

/// Facts recorded by the cache operation layer only after it has attempted and verified a user-approved change.
/// This model intentionally has no field for file contents.
public struct VerifiedCacheChange: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable { case delete, relocate, modify }
    public enum Result: String, Codable, Sendable { case completed, partial, failed }
    public enum ItemResult: String, Codable, Sendable { case applied, unchanged, failed }
    public enum Verification: String, Codable, Sendable { case verified, partial, failed, notRun }

    public struct Item: Codable, Equatable, Sendable {
        public let result: ItemResult
        public let oldPath: String?
        public let newPath: String?
        public let bytesBefore: Int64?
        public let bytesAfter: Int64?

        public init(result: ItemResult, oldPath: String?, newPath: String?, bytesBefore: Int64? = nil,
                    bytesAfter: Int64? = nil) {
            self.result = result
            self.oldPath = oldPath
            self.newPath = newPath
            self.bytesBefore = bytesBefore
            self.bytesAfter = bytesAfter
        }
    }

    /// Unique, durable operation ID supplied by the cache-operation transaction and reused on retries.
    public let eventID: String
    /// Stable HeyClicky `clicky.jobs.v1` job ID. Never infer this from the task's display name.
    public let taskID: String
    public let taskName: String
    public let operation: Operation
    public let result: Result
    public let items: [Item]
    public let verification: Verification
    public let verificationNote: String
    public let preservedContext: [String]
    public let recoverySteps: [String]
    public let occurredAt: Date

    public init(eventID: String, taskID: String, taskName: String, operation: Operation, result: Result,
                items: [Item], verification: Verification, verificationNote: String = "",
                preservedContext: [String] = [], recoverySteps: [String] = [], occurredAt: Date = Date()) {
        self.eventID = eventID
        self.taskID = taskID
        self.taskName = taskName
        self.operation = operation
        self.result = result
        self.items = items
        self.verification = verification
        self.verificationNote = verificationNote
        self.preservedContext = preservedContext
        self.recoverySteps = recoverySteps
        self.occurredAt = occurredAt
    }

    /// A notice is warranted only when the operation record says an item actually changed.
    public var containsActualChange: Bool { items.contains { $0.result == .applied } }

    public func validationError(currentTaskIDs: [String]) -> ValidationError? {
        guard !eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, eventID.count <= 160,
              !taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, taskID.count <= 300,
              !taskName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .missingIdentity }
        guard currentTaskIDs.filter({ $0 == taskID }).count == 1 else { return .taskAssociationUnavailable(taskID) }
        guard !items.isEmpty, items.count <= 500,
              items.allSatisfy({ Self.validPath($0.oldPath) && Self.validPath($0.newPath) }) else { return .invalidPathFacts }
        guard verificationNote.count <= 1_000, preservedContext.count <= 30, recoverySteps.count <= 30,
              (preservedContext + recoverySteps).allSatisfy({ $0.count <= 500 && !$0.contains("\0") }) else {
            return .invalidEvidence
        }
        return nil
    }

    private static func validPath(_ path: String?) -> Bool {
        guard let path else { return true }
        return !path.isEmpty && path.count <= 4_096 && !path.contains("\0") && !path.contains("\n")
    }

    public enum ValidationError: Error, Equatable, LocalizedError {
        case missingIdentity
        case taskAssociationUnavailable(String)
        case invalidPathFacts
        case invalidEvidence

        public var errorDescription: String? {
            switch self {
            case .missingIdentity: "The cache-change record is missing its stable event or task identity."
            case .taskAssociationUnavailable(let id): "Task \(id) is missing or not unique in the current HeyClicky task list; select the associated task before notifying it."
            case .invalidPathFacts: "The cache-change record contains invalid path facts."
            case .invalidEvidence: "The verification or recovery evidence is outside the supported size limits."
            }
        }
    }

    /// Deterministic filesystem facts; the Ollama summary is kept separate and cannot replace these fields.
    public var factualMessage: String {
        let itemLines = items.enumerated().map { index, item in
            let paths: String
            switch (item.oldPath, item.newPath) {
            case let (old?, new?): paths = "\(old) → \(new)"
            case let (old?, nil): paths = "\(old) → removed"
            case let (nil, new?): paths = "created at \(new)"
            case (nil, nil): paths = "path not recorded"
            }
            let sizes = [item.bytesBefore.map { "\($0) bytes before" }, item.bytesAfter.map { "\($0) bytes after" }]
                .compactMap { $0 }.joined(separator: ", ")
            return "- [\(item.result.rawValue)] \(paths)\(sizes.isEmpty ? "" : " (\(sizes))")"
        }.joined(separator: "\n")
        let context = preservedContext.isEmpty ? "- None recorded" : preservedContext.map { "- \($0)" }.joined(separator: "\n")
        let recovery = recoverySteps.isEmpty ? "- None recorded" : recoverySteps.map { "- \($0)" }.joined(separator: "\n")
        return """
        Cache context update for HeyClicky task \(taskName) (stable task ID: \(taskID))
        Event: \(eventID)
        Operation: \(operation.rawValue) · recorded result: \(result.rawValue)
        Changed paths (filesystem operation record):
        \(itemLines)
        Verification: \(verification.rawValue)\(verificationNote.isEmpty ? "" : " — \(verificationNote)")
        Preserved context:
        \(context)
        Recovery / rebuild steps:
        \(recovery)
        This message contains operation metadata only, not file contents. The recorded result is not upgraded by this summary.
        """
    }
}

/// Minimal, bounded Ollama output. It is explicitly interpretive; deterministic operation facts remain separate.
public enum CacheChangeAnalysis {
    public static func parse(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let summary = value.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, summary.count <= 600,
              !summary.contains("\n"), !summary.contains("\r"), !summary.contains("\0") else { return nil }
        return summary
    }

    private struct Response: Decodable { let summary: String }
}

/// A durable, deduplicating outbox. State advances only when a caller reports the corresponding result.
public struct CacheChangeNoticeOutbox: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case pending, ready, sent, failed }
    public struct Entry: Codable, Equatable, Sendable {
        public let change: VerifiedCacheChange
        public var state: State
        public var analysis: String?
        public var message: String?
        public var attempts: Int
        public var lastError: String?
        public var updatedAt: Date

        fileprivate init(change: VerifiedCacheChange, now: Date) {
            self.change = change
            state = .pending
            attempts = 0
            updatedAt = now
        }
    }

    public private(set) var entries: [String: Entry] = [:]
    public init() {}

    public enum QueueResult: Equatable { case queued, duplicate, noChange }

    public mutating func queue(_ change: VerifiedCacheChange, currentTaskIDs: [String], now: Date = Date()) throws -> QueueResult {
        if let error = change.validationError(currentTaskIDs: currentTaskIDs) { throw error }
        guard change.containsActualChange else { return .noChange }
        guard entries[change.eventID] == nil else { return .duplicate }
        entries[change.eventID] = Entry(change: change, now: now)
        return .queued
    }

    public mutating func storeDraft(_ analysis: String, for eventID: String, now: Date = Date()) throws {
        guard var entry = entries[eventID], entry.state == .pending || entry.state == .failed else {
            throw StateError.invalidTransition(eventID)
        }
        let summary = analysis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, summary.count <= 600, !summary.contains("\0") else { throw StateError.invalidAnalysis }
        entry.analysis = summary
        entry.message = entry.change.factualMessage + "\n\nOllama context analysis (interpretive; the record above is authoritative):\n" + summary
        entry.state = .ready
        entry.lastError = nil
        entry.updatedAt = now
        entries[eventID] = entry
    }

    public mutating func markSent(_ eventID: String, now: Date = Date()) throws {
        guard var entry = entries[eventID], entry.state == .ready, entry.message != nil else {
            throw StateError.invalidTransition(eventID)
        }
        entry.state = .sent
        entry.attempts += 1
        entry.lastError = nil
        entry.updatedAt = now
        entries[eventID] = entry
    }

    public mutating func markFailed(_ eventID: String, reason: String, now: Date = Date()) throws {
        guard var entry = entries[eventID], entry.state != .sent else { throw StateError.invalidTransition(eventID) }
        entry.state = .failed
        entry.attempts += 1
        entry.lastError = String(reason.prefix(800))
        entry.updatedAt = now
        entries[eventID] = entry
    }

    /// An explicit retry reuses the same event ID; it never creates a second notification.
    public mutating func retry(_ eventID: String, now: Date = Date()) throws {
        guard var entry = entries[eventID], entry.state == .failed else { throw StateError.invalidTransition(eventID) }
        entry.state = entry.analysis == nil ? .pending : .ready
        entry.lastError = nil
        entry.updatedAt = now
        entries[eventID] = entry
    }

    public enum StateError: Error, Equatable, LocalizedError {
        case invalidTransition(String)
        case invalidAnalysis
        public var errorDescription: String? {
            switch self {
            case .invalidTransition(let id): "Invalid cache-notice state transition for event \(id)."
            case .invalidAnalysis: "Ollama returned an empty or oversized cache-change analysis."
            }
        }
    }
}
