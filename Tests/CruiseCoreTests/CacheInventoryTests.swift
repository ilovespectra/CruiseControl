import Foundation
import Testing
@testable import CruiseCore

@Suite struct CacheInventoryTests {
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

    @Test func totalsFiltersAndSortsReconcileWithScannedRows() {
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

        #expect(CacheInventory.totalCacheBytes(in: items) == 110)
        #expect(CacheInventory.unknownCacheCount(in: items) == 1)
        #expect(CacheInventory.filteredAndSorted(items, kind: .cache).map(\.path) == ["/tmp/large", "/tmp/small", "/tmp/unknown"])
        #expect(CacheInventory.filteredAndSorted(items, kind: .cache, query: "Beta").map(\.path) == ["/tmp/large"])
        #expect(CacheInventory.filteredAndSorted(items, query: "workspace").map(\.kind) == [.workspace])
        #expect(CacheInventory.filteredAndSorted(items, kind: .cache, sort: .oldest).map(\.path) == ["/tmp/large", "/tmp/small", "/tmp/unknown"])
        #expect(CacheInventory.filteredAndSorted(items, sort: .name).map(\.path) == ["/tmp/large", "/tmp/small", "/tmp/unknown", "/tmp/workspace"])
    }
}
