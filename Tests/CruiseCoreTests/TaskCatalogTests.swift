import Foundation
import Testing
@testable import CruiseCore

struct TaskCatalogTests {
    @Test func groupsMoreThanADozenTasksWithoutCappingOrDroppingUnassignedTasks() {
        var catalog = TaskCatalog()
        var project = TaskProject()
        project.name = "Cruise Control"
        for number in 1...14 {
            let name = "Task \(number)"
            catalog.observe(name: name, status: "done")
            catalog.assign(project, to: Matcher.normalize(name))
        }
        catalog.observe(name: "Unknown project", status: nil)
        let groups = catalog.groups(by: .project, sort: .name)
        #expect(groups.map(\.title) == ["Cruise Control", "Unassigned"])
        #expect(groups.map { $0.tasks.count } == [14, 1])
        #expect(groups[0].tasks.map(\.name).prefix(3) == ["Task 1", "Task 2", "Task 3"])
        #expect(catalog.groups(by: .none, sort: .name).first?.tasks.count == 15)
    }

    @Test func canonicalRepositoriesMergeHTTPSAndSSHLinksButNotDifferentOwners() {
        var catalog = TaskCatalog()
        for (name, repository) in [("A", "https://github.com/Owner/Repo.git"), ("B", "git@github.com:owner/repo"),
                                   ("C", "other/repo")] {
            catalog.observe(name: name, status: "done")
            var project = TaskProject()
            project.repository = repository
            catalog.assign(project, to: Matcher.normalize(name))
        }
        let groups = catalog.groups(by: .repository, sort: .name)
        #expect(groups.count == 2)
        #expect(groups.first { $0.id == "repo:owner/repo" }?.tasks.map(\.name) == ["A", "B"])
    }

    @Test func directoryGroupingStandardizesPathsAndKeepsDifferentRootsSeparate() {
        var catalog = TaskCatalog()
        for (name, directory) in [("A", "/projects/Repo/."), ("B", "/projects/Repo/"),
                                 ("C", "/other/Repo")] {
            catalog.observe(name: name, status: nil)
            var project = TaskProject()
            project.directory = directory
            catalog.assign(project, to: Matcher.normalize(name))
        }

        let groups = catalog.groups(by: .directory, sort: .name)
        #expect(groups.count == 2)
        #expect(groups.first { $0.id == "dir:/projects/Repo" }?.tasks.count == 2)
    }

    @Test func sharedNameDirectoryAndRepositoryConnectTheSameProject() {
        var catalog = TaskCatalog()
        var first = TaskProject()
        first.name = "Cruise Control"
        first.repository = "owner/CruiseControl"
        var second = TaskProject()
        second.repository = "https://github.com/owner/CruiseControl"
        second.directory = "/projects/CruiseControl"
        var third = TaskProject()
        third.directory = "/projects/CruiseControl"
        for (name, project) in [("A", first), ("B", second), ("C", third)] {
            catalog.observe(name: name, status: nil)
            catalog.assign(project, to: Matcher.normalize(name))
        }
        let groups = catalog.groups(by: .project, sort: .name)
        #expect(groups.count == 1)
        #expect(groups[0].title == "Cruise Control")
        #expect(groups[0].tasks.count == 3)
        #expect(groups[0].project.directory == "/projects/CruiseControl")
        #expect(groups[0].project.repositoryName == "owner/CruiseControl")
        #expect(catalog.groups(by: .project, sort: .status, query: "Cruise Control")[0].tasks.count == 3)
        #expect(catalog.groups(by: .project, sort: .name, query: "/projects/CruiseControl")[0].tasks.count == 3)
    }

    @Test func refreshRetainsMetadataAndHiddenTasksWithoutAdvancingUnchangedTimestamps() throws {
        var catalog = TaskCatalog()
        let first = Date(timeIntervalSince1970: 100)
        catalog.observe(name: "Task A", status: "working", now: first)
        catalog.observe(name: "Task B", status: "done", now: first)
        var project = TaskProject()
        project.name = "Explicit project"
        catalog.assign(project, to: "task a")
        var detected = TaskProject()
        detected.repository = "other/repo"
        catalog.observe(name: "Task A", status: "working", now: first.addingTimeInterval(60), project: detected)
        let restored = try JSONDecoder().decode(TaskCatalog.self, from: JSONEncoder().encode(catalog))
        #expect(restored == catalog)
        #expect(restored.tasks.count == 2)
        #expect(restored.tasks.first?.project.name == "Explicit project")
        #expect(restored.tasks.first?.updatedAt == first)
        catalog.observe(name: "Task A", status: "done", now: first.addingTimeInterval(120))
        #expect(catalog.tasks.first?.updatedAt == first.addingTimeInterval(120))
    }

    @Test func sortingAndSearchIncludeProjectMetadata() {
        var catalog = TaskCatalog()
        catalog.observe(name: "Zebra", status: "working", now: Date(timeIntervalSince1970: 1))
        catalog.observe(name: "Apple", status: "done", now: Date(timeIntervalSince1970: 2))
        #expect(catalog.groups(by: .none, sort: .name)[0].tasks.map(\.name) == ["Apple", "Zebra"])
        #expect(catalog.groups(by: .none, sort: .updated)[0].tasks.map(\.name) == ["Apple", "Zebra"])
        #expect(catalog.groups(by: .none, sort: .status)[0].tasks.map(\.status) == ["done", "working"])
        var project = TaskProject()
        project.repository = "owner/Needle"
        catalog.assign(project, to: "zebra")
        #expect(catalog.groups(by: .project, sort: .name, query: "NEEDLE")[0].tasks.map(\.name) == ["Zebra"])
        #expect(catalog.groups(by: .project, sort: .name, query: "missing").isEmpty)
    }

    @Test func onlyUnambiguousExplicitGitHubReferencesAreDetected() {
        let detected = TaskProject.detect(in: ["Work in https://github.com/Owner/Repo/tree/main",
                                               "Source git@github.com:owner/repo.git"])
        #expect(detected?.repositoryName == "owner/repo")
        #expect(TaskProject.detect(in: ["Cruise Control task, no repository"]) == nil)
        #expect(TaskProject.detect(in: ["https://github.com/a/one https://github.com/a/two"]) == nil)
        #expect(TaskProject.detect(in: ["https://example.com/a/one"]) == nil)
    }

    @Test func sameNamedThreadCountsSurviveRestartAndPartialVisibility() throws {
        var catalog = TaskCatalog()
        catalog.observe(name: "Saturday Tube", status: "new / oops", threadCount: 8)
        #expect(catalog.threadCount == 8)
        let restored = try JSONDecoder().decode(TaskCatalog.self, from: JSONEncoder().encode(catalog))
        #expect(restored.threadCount == 8)
        catalog.observe(name: "Saturday Tube", status: nil)
        #expect(catalog.threadCount == 8)
        #expect(catalog.tasks.count == 1)
    }

    @Test func localCheckoutPathsIdentifyOneProjectButNeverMergeMultipleProjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cruise-catalog-\(UUID().uuidString)")
        let first = root.appendingPathComponent("First")
        let second = root.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: first.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let detected = TaskProject.detect(in: ["Update \(first.path)/Sources/file.swift"])
        #expect(detected?.directory == first.path)
        #expect(detected?.title == "First")
        #expect(TaskProject.detect(in: ["Update \(first.path) and \(second.path)"]) == nil)
        #expect(TaskProject.detect(in: ["Update \(first.path) https://github.com/owner/Second"]) == nil)
    }

    @Test func groupingOptionsSurviveConfigRestartAndOldConfigsUseDefaults() throws {
        var config = Config()
        config.taskGrouping = .directory
        config.taskSort = .updated
        let restored = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(restored.taskGrouping == .directory)
        #expect(restored.taskSort == .updated)
        let old = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        #expect(old.taskGrouping == .project)
        #expect(old.taskSort == .priority)
    }

    @Test func stableJobIDsKeepSameNamedTasksSeparateAcrossReorderingAndRestart() throws {
        let jobs = try ClickyTaskLibrary.decodeJobs(Data(#"""
        [{"id":"first","nickname":"Saturday Tube","outcome":"new"},
         {"id":"second","nickname":"Saturday Tube","outcome":"oops"}]
        """#.utf8))
        let source = ClickyTaskLibrary.tasks(jobs: jobs, activity: [:])
        var catalog = TaskCatalog()
        try catalog.synchronize(source)
        var project = TaskProject()
        project.name = "First project"
        catalog.assign(project, to: "first")
        catalog = try JSONDecoder().decode(TaskCatalog.self, from: JSONEncoder().encode(catalog))
        try catalog.synchronize(Array(source.reversed()))
        #expect(catalog.tasks.count == 2)
        #expect(catalog.tasks.first { $0.id == "first" }?.project.name == "First project")
        #expect(catalog.tasks.first { $0.id == "second" }?.project.name == "")
    }

    @Test func legacyAssignmentsMigrateOnlyForUniqueNamesAndAmbiguousAssignmentsAreRetained() throws {
        let jobs = try ClickyTaskLibrary.decodeJobs(Data(#"""
        [{"id":"first","nickname":"Duplicate","outcome":"new"},
         {"id":"second","nickname":"Duplicate","outcome":"oops"},
         {"id":"unique","nickname":"Unique","outcome":"done"}]
        """#.utf8))
        var catalog = TaskCatalog()
        var project = TaskProject()
        project.name = "Saved project"
        for name in ["Duplicate", "Unique"] {
            catalog.observe(name: name, status: nil)
            catalog.assign(project, to: Matcher.normalize(name))
        }
        catalog.observe(name: "Observed without a job record", status: nil)
        try catalog.synchronize(ClickyTaskLibrary.tasks(jobs: jobs, activity: [:]))
        #expect(catalog.tasks.first { $0.id == "unique" }?.sourceID == "unique")
        #expect(catalog.tasks.first { $0.id == "unique" }?.project.name == "Saved project")
        #expect(catalog.tasks.first { $0.id == "first" }?.projectAssigned == false)
        #expect(catalog.tasks.first { $0.id == "second" }?.projectAssigned == false)
        #expect(catalog.tasks.first { $0.id == "duplicate" }?.sourceUnavailable == true)
        #expect(catalog.tasks.first { $0.id == "duplicate" }?.project.name == "Saved project")
        #expect(catalog.tasks.first { $0.id == "observed without a job record" }?.sourceUnavailable == true)
    }

    @Test func duplicateSourceIDsFailWithoutReplacingSavedCatalog() throws {
        let jobs = try ClickyTaskLibrary.decodeJobs(Data(#"""
        [{"id":"same","nickname":"A"},{"id":"same","nickname":"B"}]
        """#.utf8))
        var catalog = TaskCatalog()
        catalog.observe(name: "Saved", status: nil)
        let before = catalog
        #expect(throws: TaskCatalog.CatalogError.self) {
            try catalog.synchronize(ClickyTaskLibrary.tasks(jobs: jobs, activity: [:]))
        }
        #expect(catalog == before)
    }

    @Test func fullTaskMetricsSortByCreationThreadLengthAndMeasuredSize() throws {
        let jobs = try ClickyTaskLibrary.decodeJobs(Data(#"""
        [{"id":"older","nickname":"Older","createdAt":"2026-01-01T00:00:00Z"},
         {"id":"newer","nickname":"Newer","createdAt":"2026-02-01T00:00:00Z"},
         {"id":"unknown","nickname":"Unknown"}]
        """#.utf8))
        var source = ClickyTaskLibrary.tasks(jobs: jobs, activity: [:])
        source[0].runCount = 3
        source[0].messageCount = 20
        source[0].cacheBytes = 100
        source[1].runCount = 2
        source[1].messageCount = 30
        source[1].cacheBytes = 200
        var catalog = TaskCatalog()
        try catalog.synchronize(source)
        #expect(catalog.groups(by: .none, sort: .newest)[0].tasks.map(\.id) == ["newer", "older", "unknown"])
        #expect(catalog.groups(by: .none, sort: .oldest)[0].tasks.map(\.id) == ["older", "newer", "unknown"])
        #expect(catalog.groups(by: .none, sort: .longestThread)[0].tasks.map(\.id) == ["older", "newer", "unknown"])
        #expect(catalog.groups(by: .none, sort: .largestCache)[0].tasks.map(\.id) == ["newer", "older", "unknown"])
        try catalog.synchronize([])
        #expect(catalog.tasks.count == 3)
        #expect(catalog.currentTaskCount == 0)
        #expect(catalog.tasks.allSatisfy { $0.sourceUnavailable == true })
        try catalog.synchronize(source)
        #expect(catalog.currentTaskCount == 3)
    }
}
