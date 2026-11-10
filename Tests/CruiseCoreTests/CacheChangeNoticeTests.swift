import Foundation
import Testing
@testable import CruiseCore

@Suite struct CacheChangeNoticeTests {
    private func change(eventID: String = "op-123", taskID: String = "job-7",
                        result: VerifiedCacheChange.Result = .completed,
                        items: [VerifiedCacheChange.Item]? = nil) -> VerifiedCacheChange {
        VerifiedCacheChange(
            eventID: eventID, taskID: taskID, taskName: "Cruise Docs Scribe",
            operation: .relocate, result: result,
            items: items ?? [.init(result: .applied, oldPath: "/Volumes/Old/agent/cache",
                                   newPath: "/Users/tanny/Library/Caches/agent/cache", bytesBefore: 2_048, bytesAfter: 2_048)],
            verification: .verified, verificationNote: "new path exists; old path absent",
            preservedContext: ["Task job-7 metadata and project assignment were retained"],
            recoverySteps: ["If needed, point the task workspace back to /Volumes/Old/agent/cache"],
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func queueIsTaskIdBoundAndDeduplicatesSameOperation() throws {
        var outbox = CacheChangeNoticeOutbox()
        let record = change()
        #expect(try outbox.queue(record, currentTaskIDs: ["job-7", "job-8"]) == .queued)
        #expect(try outbox.queue(record, currentTaskIDs: ["job-7", "job-8"]) == .duplicate)
        #expect(outbox.entries.count == 1)
        #expect(outbox.entries["op-123"]?.state == .pending)
        #expect(outbox.entries["op-123"]?.change.taskID == "job-7")
    }

    @Test func missingOrAmbiguousTaskAssociationDoesNotCreateNotice() {
        var outbox = CacheChangeNoticeOutbox()
        #expect(throws: VerifiedCacheChange.ValidationError.self) {
            try outbox.queue(change(), currentTaskIDs: ["job-8"])
        }
        #expect(throws: VerifiedCacheChange.ValidationError.self) {
            try outbox.queue(change(), currentTaskIDs: ["job-7", "job-7"])
        }
        #expect(outbox.entries.isEmpty)
    }

    @Test func unchangedAndFailedWithoutAppliedItemsDoNotNotify() throws {
        var outbox = CacheChangeNoticeOutbox()
        let unchanged = change(items: [.init(result: .unchanged, oldPath: "/tmp/cache", newPath: "/tmp/cache")])
        #expect(try outbox.queue(unchanged, currentTaskIDs: ["job-7"]) == .noChange)
        #expect(outbox.entries.isEmpty)
        let failed = change(eventID: "op-fail", result: .failed,
                            items: [.init(result: .failed, oldPath: "/tmp/cache", newPath: "/tmp/new")])
        #expect(try outbox.queue(failed, currentTaskIDs: ["job-7"]) == .noChange)
        #expect(outbox.entries.isEmpty)
    }

    @Test func partialChangeCarriesFailureVerificationAndRecoveryFacts() throws {
        var outbox = CacheChangeNoticeOutbox()
        let record = VerifiedCacheChange(
            eventID: "op-partial", taskID: "job-7", taskName: "Task",
            operation: .relocate, result: .partial,
            items: [.init(result: .applied, oldPath: "/old/one", newPath: "/new/one"),
                    .init(result: .failed, oldPath: "/old/two", newPath: "/new/two")],
            verification: .partial, verificationNote: "one item remains at its old path",
            preservedContext: ["No task record was changed"], recoverySteps: ["Restore the first item from /new/one"])
        #expect(try outbox.queue(record, currentTaskIDs: ["job-7"]) == .queued)
        let notice = try #require(outbox.entries["op-partial"]?.change.factualMessage)
        #expect(notice.contains("recorded result: partial"))
        #expect(notice.contains("Verification: partial"))
        #expect(notice.contains("/old/one → /new/one"))
        #expect(notice.contains("/old/two → /new/two"))
        #expect(notice.contains("Restore the first item from /new/one"))
        #expect(notice.contains("not file contents"))
    }

    @Test func noticeNeedsValidLocalAnalysisAndExplicitReceiptForSentState() throws {
        #expect(CacheChangeAnalysis.parse(#"{"summary":"Relocation completed; the task should use the new path."}"#)
                == "Relocation completed; the task should use the new path.")
        #expect(CacheChangeAnalysis.parse("not-json") == nil)
        #expect(CacheChangeAnalysis.parse(#"{"summary":""}"#) == nil)
        #expect(CacheChangeAnalysis.parse(#"{"summary":"two\nlines"}"#) == nil)

        var outbox = CacheChangeNoticeOutbox()
        try #expect(outbox.queue(change(), currentTaskIDs: ["job-7"]) == .queued)
        #expect(throws: CacheChangeNoticeOutbox.StateError.self) {
            try outbox.markSent("op-123")
        }
        try outbox.storeDraft("The task should retain its updated cache location.", for: "op-123")
        #expect(outbox.entries["op-123"]?.state == .ready)
        #expect(outbox.entries["op-123"]?.message?.contains("/Volumes/Old/agent/cache → /Users/tanny/Library/Caches/agent/cache") == true)
        #expect(outbox.entries["op-123"]?.message?.contains("Ollama context analysis") == true)
        try outbox.markFailed("op-123", reason: "HeyClicky UI could not be verified")
        #expect(outbox.entries["op-123"]?.state == .failed)
        #expect(outbox.entries["op-123"]?.lastError == "HeyClicky UI could not be verified")
        try outbox.retry("op-123")
        #expect(outbox.entries["op-123"]?.state == .ready)
        try outbox.markSent("op-123")
        #expect(outbox.entries["op-123"]?.state == .sent)
        #expect(outbox.entries["op-123"]?.attempts == 2)
        #expect(throws: CacheChangeNoticeOutbox.StateError.self) {
            try outbox.markFailed("op-123", reason: "duplicate")
        }
    }

    @Test func roundTripPersistsPendingAndSentOutboxStates() throws {
        var outbox = CacheChangeNoticeOutbox()
        try #expect(outbox.queue(change(), currentTaskIDs: ["job-7"]) == .queued)
        try outbox.storeDraft("Cache is now at the new task path.", for: "op-123")
        let pending = try JSONDecoder().decode(CacheChangeNoticeOutbox.self, from: JSONEncoder().encode(outbox))
        #expect(pending == outbox)
        try outbox.markSent("op-123")
        let sent = try JSONDecoder().decode(CacheChangeNoticeOutbox.self, from: JSONEncoder().encode(outbox))
        #expect(sent.entries["op-123"]?.state == .sent)
    }
}
