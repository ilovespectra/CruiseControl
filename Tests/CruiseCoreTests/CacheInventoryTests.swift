import Darwin
import Foundation
import Testing
@testable import CruiseCore

@Suite struct CacheInventoryTests {
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [CacheInventoryScanProgress] = []

        func append(_ value: CacheInventoryScanProgress) {
            lock.lock()
            defer { lock.unlock() }
            values.append(value)
        }

        var snapshots: [CacheInventoryScanProgress] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cruise-cache-inventory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func setModified(_ date: Date, at url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    @Test func scanMeasuresUniquePathAndMergesTaskAssociationsWithoutChangingFiles() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let nested = cache.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let first = cache.appendingPathComponent("a.log")
        let second = nested.appendingPathComponent("b.log")
        try Data("1234".utf8).write(to: first)
        try Data("123456".utf8).write(to: second)
        let earlier = Date(timeIntervalSince1970: 1_800_000_000)
        let latest = Date(timeIntervalSince1970: 1_800_000_100)
        try setModified(earlier, at: cache)
        try setModified(earlier, at: nested)
        try setModified(earlier, at: first)
        try setModified(latest, at: second)
        let originalBytes = try Data(contentsOf: first)
        let originalDate = try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date

        let rows = CacheInventory.scan(sources: [
            .init(kind: .cache, path: cache.path, taskID: "job-b", taskName: "Beta"),
            .init(kind: .cache, path: cache.path, taskID: "job-a", taskName: "Alpha"),
        ])

        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.bytes == 10)
        #expect(row.modifiedAt == latest)
        #expect(row.taskIDs == ["job-a", "job-b"])
        #expect(row.taskNames == ["Alpha", "Beta"])
        #expect(try Data(contentsOf: first) == originalBytes)
        #expect(try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date == originalDate)
    }

    @Test func scannerSkipsSymlinkChildrenAndReportsSymlinkRootsAsUnknown() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.txt")
        let visible = root.appendingPathComponent("visible.txt")
        try Data(repeating: 0x31, count: 80).write(to: outside)
        try Data("abc".utf8).write(to: visible)
        let folder = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let child = folder.appendingPathComponent("visible.txt")
        try Data("abc".utf8).write(to: child)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("linked.txt").path,
                                                   withDestinationPath: outside.path)
        let rootLink = root.appendingPathComponent("cache-link")
        try FileManager.default.createSymbolicLink(atPath: rootLink.path, withDestinationPath: folder.path)

        let rows = CacheInventory.scan(sources: [
            .init(kind: .cache, path: folder.path, taskName: "Task"),
            .init(kind: .cache, path: rootLink.path, taskName: "Task"),
        ])
        let measured = try #require(rows.first(where: { $0.path == folder.path }))
        let linked = try #require(rows.first(where: { $0.path == rootLink.path }))
        #expect(measured.bytes == 3)
        #expect(measured.error == nil)
        #expect(linked.bytes == nil)
        #expect(linked.error == "Symbolic-link roots are not followed")
    }

    @Test func missingWorkspaceIsExplicitButAbsentCacheIsNotAFalseZero() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-cache-\(UUID().uuidString)").path
        let rows = CacheInventory.scan(sources: [
            .init(kind: .workspace, path: missing, taskID: "job-1", taskName: "Workspace task", includeMissing: true),
            .init(kind: .cache, path: missing, taskID: "job-1", taskName: "Workspace task"),
        ])
        #expect(rows.count == 1)
        #expect(rows[0].kind == .workspace)
        #expect(rows[0].bytes == nil)
        #expect(rows[0].error == "Path does not exist")
    }

    @Test func reportDeduplicatesOverlappingPathsAndKeepsCategoryTotalsSeparate() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("cache", isDirectory: true)
        let nested = parent.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0x31, count: 6).write(to: parent.appendingPathComponent("cache.bin"))
        try Data(repeating: 0x32, count: 4).write(to: nested.appendingPathComponent("workspace.bin"))

        let report = CacheInventory.scanReport(sources: [
            .init(kind: .cache, path: parent.path, taskID: "job-a", taskName: "Alpha"),
            .init(kind: .workspace, path: nested.path, taskID: "job-a", taskName: "Alpha", includeMissing: true),
            .init(kind: .workspace, path: nested.path, taskID: "job-b", taskName: "Beta", includeMissing: true),
        ], taskCount: 2)

        #expect(report.items.count == 2)
        #expect(report.expectedCachePathCount == 1)
        #expect(report.expectedWorkspacePathCount == 1)
        #expect(report.measuredCachePathCount == 1)
        #expect(report.measuredWorkspacePathCount == 1)
        #expect(report.taskCacheBytes == 10)
        #expect(report.workspaceBytes == 4)
        #expect(report.overallUniqueBytes == 10)
        #expect(report.taskCount == 2)
        #expect(!report.isPartial)
        #expect(CacheInventory.scanReport(sources: [], workspaceScopeIssue: "Folder unavailable").isPartial)
    }

    @Test func fullStorageRootsCountApparentAndAllocatedBytesAndDeduplicateOverlapAndAliases() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Clicky", isDirectory: true)
        let agent = support.appendingPathComponent("Agent", isDirectory: true)
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        let taskCache = support.appendingPathComponent("task-cache.bin")
        let workspace = agent.appendingPathComponent("workspace.bin")
        try Data(repeating: 0x41, count: 6).write(to: taskCache)
        try Data(repeating: 0x42, count: 4).write(to: workspace)
        let alias = root.appendingPathComponent("Agent-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: agent)

        let report = CacheInventory.scanReport(sources: [
            .init(kind: .cache, path: taskCache.path, taskID: "job-1", taskName: "Test task"),
            .init(kind: .workspace, path: agent.path, taskID: "job-1", taskName: "Test task", includeMissing: true),
        ], taskCount: 1, storageRoots: [
            .init(label: "Clicky support", path: support.path),
            .init(label: "Agent folder", path: agent.path),
            .init(label: "Agent alias", path: alias.path),
        ])

        #expect(report.clickyStorageApparentBytes == 10)
        #expect(report.clickyStorageAllocatedBytes != nil)
        #expect(report.clickyStorageFileCount == 2)
        #expect(report.storageRoots.map(\.apparentBytes) == [10, 4, 4])
        #expect(report.storageRoots.map(\.resolvedPath) == [support.path, agent.path, agent.path])
        #expect(report.taskCacheBytes == 6)
        #expect(report.workspaceBytes == 4)
        #expect(report.overallUniqueBytes == 10)
        #expect(!report.storageIsPartial)
    }

    @Test func inaccessibleFullRootIsUnknownRatherThanZeroAndMarksCoveragePartial() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-clicky-root-\(UUID().uuidString)").path
        let report = CacheInventory.scanReport(sources: [], storageRoots: [
            .init(label: "Clicky support", path: missing),
        ])

        #expect(report.clickyStorageApparentBytes == nil)
        #expect(report.clickyStorageAllocatedBytes == nil)
        #expect(report.storageRoots.first?.error == "Path does not exist")
        #expect(report.storageIsPartial)
        #expect(report.isPartial)
    }

    @Test func fullFootprintCategoriesReconcileWithSharedCacheAndUnassociatedSupport() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let nested = workspace.appendingPathComponent("one/two/three/four/five/six", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let cache = nested.appendingPathComponent("cache")
        try Data(repeating: 0, count: 6).write(to: cache)
        try Data(repeating: 0, count: 4).write(to: nested.appendingPathComponent("source"))
        try Data(repeating: 0, count: 3).write(to: root.appendingPathComponent("support"))
        let report = CacheInventory.scanReport(sources: [
            .init(kind: .workspace, path: workspace.path, taskName: "Shared workspace"),
            .init(kind: .cache, path: cache.path, taskID: "one", taskName: "One"),
            .init(kind: .cache, path: cache.path, taskID: "two", taskName: "Two"),
        ], storageRoots: [.init(label: "Full footprint", path: root.path)])
        #expect(report.taskCacheBytes == 6)
        #expect(report.workspaceBytes == 4)
        #expect(report.otherSupportBytes == 3)
        #expect(report.clickyStorageApparentBytes == 13)
        #expect(report.taskCacheBytes + report.workspaceBytes + (report.otherSupportBytes ?? 0) == report.clickyStorageApparentBytes)
        #expect(report.items.first(where: { $0.kind == .cache })?.taskIDs == ["one", "two"])
    }

    @Test func workspaceScopeDoesNotRedirectTaskCacheRoot() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheRoot = root.appendingPathComponent("Clicky", isDirectory: true)
        let agentRoot = root.appendingPathComponent("Agent", isDirectory: true)
        let outsideRoot = root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agentRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        let task = ClickyAgentTask(id: "job-a", name: "Alpha", title: "Alpha", prompt: "", latestAsk: "",
            outcome: "unknown", summary: "", lastMessage: "", lastMessageAt: nil, createdAt: nil, updatedAt: nil,
            runCount: 1, messageCount: 0, threadIDs: ["thread-a"],
            folderPath: agentRoot.appendingPathComponent("jobs/job-a").path, dismissed: false, suggestedNext: [])
        let other = ClickyAgentTask(id: "job-b", name: "Beta", title: "Beta", prompt: "", latestAsk: "",
            outcome: "unknown", summary: "", lastMessage: "", lastMessageAt: nil, createdAt: nil, updatedAt: nil,
            runCount: 1, messageCount: 0, threadIDs: ["thread-b"],
            folderPath: outsideRoot.appendingPathComponent("job-b").path, dismissed: false, suggestedNext: [])

        let sources = CacheInventory.sources(tasks: [task, other], catalog: TaskCatalog(),
                                             cacheRoot: cacheRoot, workspaceRoot: agentRoot)

        #expect(sources.filter { $0.kind == .cache }.allSatisfy { $0.path.hasPrefix(cacheRoot.path + "/") })
        #expect(sources.filter { $0.kind == .workspace }.map(\.path) == [task.folderPath!])
    }

    @Test func progressPublishesCacheRowsBeforeAgentTraversalAndRoundTripsCompletedReport() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("deep/support")
        let agent = root.appendingPathComponent("Agent")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        let cache = support.appendingPathComponent("cache")
        try Data(repeating: 1, count: 6).write(to: cache)
        try Data(repeating: 2, count: 4).write(to: agent.appendingPathComponent("source"))
        let recorder = ProgressRecorder()
        let report = CacheInventory.scanReport(sources: [
            .init(kind: .cache, path: cache.path, taskID: "one", taskName: "One"),
            .init(kind: .workspace, path: agent.path, taskName: "Agent", includeMissing: true),
        ], storageRoots: [
            .init(label: "Support", path: support.path),
            .init(label: "Agent", path: agent.path),
        ], progress: { recorder.append($0) })
        let beforeAgent = try #require(recorder.snapshots.first { $0.rootLabel == "Agent" }?.report)
        #expect(beforeAgent.taskCacheBytes == 6)
        #expect(beforeAgent.measuredCachePathCount == 1)
        #expect(beforeAgent.items.first { $0.kind == .cache }?.error == nil)
        #expect(beforeAgent.storageIsPartial)
        #expect(beforeAgent.clickyStorageApparentBytes == 6)
        let last = try #require(recorder.snapshots.last?.report)
        #expect(last.clickyStorageApparentBytes == report.clickyStorageApparentBytes)
        #expect(last.items == report.items)
        #expect(!report.isPartial)
        #expect(try JSONDecoder().decode(CacheInventoryReport.self, from: JSONEncoder().encode(report)) == report)
    }

    @Test func fullScanDeduplicatesHardLinksAcrossRootsAndCategoriesAndSkipsInteriorSymlinks() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support")
        let agent = root.appendingPathComponent("agent")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        let cache = support.appendingPathComponent("cache")
        try Data(repeating: 1, count: 7).write(to: cache)
        try FileManager.default.linkItem(at: cache, to: agent.appendingPathComponent("hardlink"))
        try FileManager.default.createSymbolicLink(at: agent.appendingPathComponent("symlink"), withDestinationURL: support)
        let report = CacheInventory.scanReport(sources: [
            .init(kind: .cache, path: cache.path, taskName: "Cache"),
            .init(kind: .workspace, path: agent.path, taskName: "Workspace"),
        ], storageRoots: [.init(label: "Agent", path: agent.path), .init(label: "Support", path: support.path)])
        #expect(report.clickyStorageApparentBytes == 7)
        #expect(report.clickyStorageFileCount == 1)
        #expect(report.taskCacheBytes == 7)
        #expect(report.workspaceBytes == 0)
        #expect(report.otherSupportBytes == 0)
        #expect(report.storageRoots.map(\.apparentBytes) == [7, 7])
        #expect(!report.isPartial)
    }

    @Test func bulkTraversalSpansMultipleBatchesAndMatchesStatForSparseFiles() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<1800 {
            try Data(repeating: 1, count: 3).write(to: root.appendingPathComponent("file-\(index)"))
        }
        let sparse = root.appendingPathComponent("sparse")
        #expect(FileManager.default.createFile(atPath: sparse.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 128 * 1024 * 1024)
        try handle.close()
        var sparseInfo = stat()
        #expect(lstat(sparse.path, &sparseInfo) == 0)
        var regularInfo = stat()
        #expect(lstat(root.appendingPathComponent("file-0").path, &regularInfo) == 0)
        let report = CacheInventory.scanReport(sources: [],
                                               storageRoots: [.init(label: "Files", path: root.path)])
        #expect(!report.isPartial)
        #expect(report.clickyStorageFileCount == 1801)
        #expect(report.clickyStorageApparentBytes == 1800 * 3 + Int64(sparseInfo.st_size))
        #expect(report.clickyStorageAllocatedBytes == Int64(regularInfo.st_blocks) * 512 * 1800
                + Int64(sparseInfo.st_blocks) * 512)
    }

    @Test func cancelledScanDoesNotReportAnUntouchedRootAsComplete() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return CacheInventory.scanReport(sources: [], storageRoots: [.init(label: "Root", path: root.path)])
        }
        let report = await work.value
        #expect(report.storageIsPartial)
        #expect(report.storageRoots.first?.error != nil)
    }

    @Test func filtersAndSortsOperateIndependently() {
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let items = [
            CacheInventoryItem(kind: .cache, path: "/tmp/small", taskIDs: ["job-a"], taskNames: ["Alpha"],
                               bytes: 10, modifiedAt: now, error: nil),
            CacheInventoryItem(kind: .cache, path: "/tmp/large", taskIDs: ["job-b"], taskNames: ["Beta"],
                               bytes: 100, modifiedAt: now.addingTimeInterval(-100), error: nil),
            CacheInventoryItem(kind: .cache, path: "/tmp/unknown", taskIDs: ["job-c"], taskNames: ["Gamma"],
                               bytes: nil, modifiedAt: nil, error: "Permission denied"),
            CacheInventoryItem(kind: .workspace, path: "/tmp/workspace", taskIDs: ["job-a"], taskNames: ["Alpha"],
                               bytes: 200, modifiedAt: now, error: nil),
        ]

        #expect(CacheInventory.filteredAndSorted(items, kind: .cache).map(\.path) == ["/tmp/large", "/tmp/small", "/tmp/unknown"])
        #expect(CacheInventory.filteredAndSorted(items, kind: .cache, query: "Beta").map(\.path) == ["/tmp/large"])
        #expect(CacheInventory.filteredAndSorted(items, query: "workspace").map(\.kind) == [.workspace])
        #expect(CacheInventory.filteredAndSorted(items, kind: .cache, sort: .oldest).map(\.path) == ["/tmp/large", "/tmp/small", "/tmp/unknown"])
        #expect(CacheInventory.filteredAndSorted(items, sort: .name).map(\.path) == ["/tmp/large", "/tmp/small", "/tmp/unknown", "/tmp/workspace"])
    }
}
