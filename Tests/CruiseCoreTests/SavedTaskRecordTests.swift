import Foundation
import Testing
@testable import CruiseCore

struct SavedTaskRecordTests {
    @Test func currentJobsCannotBeLocallyClosedOrDeleted() throws {
        let jobs = try ClickyTaskLibrary.decodeJobs(Data(#"[{"id":"live","nickname":"Current","outcome":"done"}]"#.utf8))
        let source = ClickyTaskLibrary.tasks(jobs: jobs, activity: [:])
        var catalog = TaskCatalog()
        try catalog.synchronize(source)
        let archived = catalog.manageSavedRecord("live", disposition: .archived)
        let deleted = catalog.manageSavedRecord("live", disposition: nil, delete: true)
        #expect(!archived)
        #expect(!deleted)
        try catalog.synchronize([])
        let finished = catalog.manageSavedRecord("live", disposition: .finished)
        #expect(finished)
        try catalog.synchronize(source)
        #expect(catalog.tasks.first?.localDisposition == nil)
        #expect(catalog.currentTaskCount == 1)
    }

    @Test func unmatchedHistoryCanBeArchivedFinishedRestoredAndDeleted() throws {
        var catalog = TaskCatalog()
        catalog.observe(name: "Saved task", status: "Done")
        let id = try #require(catalog.tasks.first?.id)
        let archived = catalog.manageSavedRecord(id, disposition: .archived)
        #expect(archived)
        var restored = try JSONDecoder().decode(TaskCatalog.self, from: JSONEncoder().encode(catalog))
        #expect(restored.tasks.first?.localDisposition == .archived)
        try restored.synchronize([])
        #expect(restored.tasks.first?.localDisposition == .archived)
        let finished = restored.manageSavedRecord(id, disposition: .finished)
        #expect(finished)
        #expect(restored.tasks.first?.localDisposition == .finished)
        let reopened = restored.manageSavedRecord(id, disposition: nil)
        #expect(reopened)
        #expect(restored.tasks.first?.localDisposition == nil)
        let deleted = restored.manageSavedRecord(id, disposition: nil, delete: true)
        #expect(deleted)
        #expect(restored.tasks.isEmpty)
    }

    @Test func unknownIDCannotBeManaged() {
        var catalog = TaskCatalog()
        let archived = catalog.manageSavedRecord("missing", disposition: .archived)
        let deleted = catalog.manageSavedRecord("missing", disposition: nil, delete: true)
        #expect(!archived)
        #expect(!deleted)
    }
}
