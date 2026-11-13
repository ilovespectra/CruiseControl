import Foundation
import Testing
@testable import CruiseCore

@Suite struct TaskEngineTests {
    private func record(_ key: String, stage: TaskEngineRecord.Stage = .drafted, autoBump: Bool = true,
                        inputs: String = "a", examined: TimeInterval = 0) -> TaskEngineRecord {
        var record = TaskEngineRecord(key: key, provider: "heyclicky", title: key, stage: stage, detail: "",
                                      draft: "msg", inputsKey: inputs, autoBump: autoBump)
        record.examinedAt = Date(timeIntervalSince1970: examined)
        return record
    }

    @Test func queueHoldsEveryReadyAutoBumpDraftOldestFirst() {
        var cache = TaskEngineCache()
        cache.upsert(record("b", examined: 20))
        cache.upsert(record("a", examined: 10))
        cache.upsert(record("manual", autoBump: false))
        var held = record("held")
        held.blocker = TaskBlocker("Stopped by you.", fix: .resumeStopped)
        cache.upsert(held)
        #expect(cache.sendQueue() == ["a", "b"])
    }

    @Test func oneFailureBacksOffOnlyThatTask() {
        var cache = TaskEngineCache()
        cache.upsert(record("a", examined: 10))
        cache.upsert(record("b", examined: 20))
        let now = Date()
        cache.recordFailure("a", reason: "composer busy", now: now)
        #expect(cache.sendQueue(now: now) == ["b"])
        #expect(cache.sendQueue(now: now.addingTimeInterval(31)) == ["a", "b"])
        cache.recordFailure("a", reason: "again", now: now)
        #expect(cache.records["a"]?.nextRetryAt == now.addingTimeInterval(60))
    }

    @Test func sentDraftStaysSentUntilInputsChange() {
        var cache = TaskEngineCache()
        cache.upsert(record("a"))
        cache.recordSent("a", detail: "Sent")
        cache.upsert(record("a"))
        #expect(cache.records["a"]?.stage == .sent)
        #expect(cache.sendQueue().isEmpty)
        cache.upsert(record("a", inputs: "new report"))
        #expect(cache.records["a"]?.stage == .drafted)
        #expect(cache.sendQueue() == ["a"])
    }

    @Test func examineOrderStarvesNoTask() {
        var cache = TaskEngineCache()
        cache.upsert(record("recent", examined: 100))
        cache.upsert(record("old", examined: 1))
        #expect(cache.examineOrder(["recent", "never", "old"]) == ["never", "old", "recent"])
    }

    @Test func metadataChangesAreDescribed() {
        let old = TaskMetadata(title: "Silo", status: "done", folder: nil, done: nil, autoBump: false, plan: "p", report: "r1")
        var new = old
        new.folder = "/tmp/silo"
        new.done = "ship it"
        new.autoBump = true
        new.report = "r2"
        #expect(TaskMetadata.changes(from: old, to: new) == ["folder set to /tmp/silo", "Done defined", "auto-bump on", "new response"])
        #expect(TaskMetadata.changes(from: old, to: old).isEmpty)
        #expect(TaskMetadata.changes(from: nil, to: old) == ["tracked (done)"])
    }
}
