import Darwin
import Foundation

/// The two task-associated path classes Cruise can inspect. This is metadata-only and never changes either path.
public enum CacheInventoryKind: String, CaseIterable, Identifiable, Sendable {
    case cache = "Task cache"
    case workspace = "Workspace"
    public var id: String { rawValue }
}

/// One known path and its task association. `includeMissing` is useful for configured workspaces; absent cache
/// paths are normal and are omitted from the visible inventory.
public struct CacheInventorySource: Equatable, Sendable {
    public let kind: CacheInventoryKind
    public let path: String
    public let taskID: String?
    public let taskName: String
    public let includeMissing: Bool

    public init(kind: CacheInventoryKind, path: String, taskID: String? = nil,
                taskName: String, includeMissing: Bool = false) {
        self.kind = kind
        self.path = path
        self.taskID = taskID
        self.taskName = taskName
        self.includeMissing = includeMissing
    }
}

/// A measured task-associated file or folder. `modifiedAt` is the newest observed modification time in a folder;
/// `bytes == nil` means the size is unknown, never zero.
public struct CacheInventoryItem: Identifiable, Equatable, Sendable {
    public var id: String { "\(kind.rawValue):\(path)" }
    public let kind: CacheInventoryKind
    public let path: String
    public let taskIDs: [String]
    public let taskNames: [String]
    public let bytes: Int64?
    public let modifiedAt: Date?
    public let error: String?

    public init(kind: CacheInventoryKind, path: String, taskIDs: [String], taskNames: [String],
                bytes: Int64?, modifiedAt: Date?, error: String?) {
        self.kind = kind
        self.path = path
        self.taskIDs = taskIDs
        self.taskNames = taskNames
        self.bytes = bytes
        self.modifiedAt = modifiedAt
        self.error = error
    }
}

public enum CacheInventorySort: String, CaseIterable, Identifiable, Sendable {
    case largest = "Largest first"
    case oldest = "Oldest first"
    case name = "Name"
    public var id: String { rawValue }
}

/// Read-only inventory of paths already referenced by current HeyClicky jobs or saved Cruise workspaces.
public enum CacheInventory {
    private struct Accumulator {
        var kind: CacheInventoryKind
        var path: String
        var taskIDs = Set<String>()
        var taskNames = Set<String>()
        var includeMissing = false
    }

    public static func sources(tasks: [ClickyAgentTask], catalog: TaskCatalog, root: URL) -> [CacheInventorySource] {
        var result: [CacheInventorySource] = []
        for task in tasks {
            for path in ClickyTaskLibrary.cachePaths(threadIDs: task.threadIDs, root: root) {
                result.append(CacheInventorySource(kind: .cache, path: path.path, taskID: task.id,
                                                   taskName: task.name))
            }
            if let folder = task.folderPath, !folder.isEmpty {
                result.append(CacheInventorySource(kind: .workspace, path: folder, taskID: task.id,
                                                   taskName: task.name, includeMissing: true))
            }
        }
        let namesByID = Dictionary(tasks.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        for saved in catalog.tasks {
            guard let path = saved.project.directoryPath else { continue }
            let name = saved.sourceID.flatMap { namesByID[$0] } ?? saved.name
            result.append(CacheInventorySource(kind: .workspace, path: path, taskID: saved.sourceID,
                                               taskName: name, includeMissing: true))
        }
        return result
    }

    /// Scans only caller-supplied paths, deduplicates same-kind paths, skips symlinks, and returns an explicit
    /// unknown/error row when a requested workspace cannot be measured. No file is written, moved or deleted.
    public static func scan(sources: [CacheInventorySource], fileManager: FileManager = .default) -> [CacheInventoryItem] {
        var merged: [String: Accumulator] = [:]
        for source in sources {
            let path = normalizedPath(source.path)
            let key = "\(source.kind.rawValue)\u{1F}\(path)"
            var value = merged[key] ?? Accumulator(kind: source.kind, path: path)
            if let id = source.taskID, !id.isEmpty { value.taskIDs.insert(id) }
            if !source.taskName.isEmpty { value.taskNames.insert(source.taskName) }
            value.includeMissing = value.includeMissing || source.includeMissing
            merged[key] = value
        }
        return merged.values.compactMap { inspect($0, fileManager: fileManager) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    public static func totalCacheBytes(in items: [CacheInventoryItem]) -> Int64 {
        items.lazy.filter { $0.kind == .cache }.compactMap(\.bytes).reduce(0, +)
    }

    public static func unknownCacheCount(in items: [CacheInventoryItem]) -> Int {
        items.filter { $0.kind == .cache && $0.bytes == nil }.count
    }

    public static func filteredAndSorted(_ items: [CacheInventoryItem], kind: CacheInventoryKind? = nil,
                                         query: String = "", sort: CacheInventorySort = .largest) -> [CacheInventoryItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = items.filter { item in
            guard kind == nil || item.kind == kind else { return false }
            guard !needle.isEmpty else { return true }
            return item.path.localizedStandardContains(needle)
                || item.kind.rawValue.localizedStandardContains(needle)
                || item.taskNames.contains(where: { $0.localizedStandardContains(needle) })
                || item.taskIDs.contains(where: { $0.localizedStandardContains(needle) })
        }
        result.sort { lhs, rhs in
            let decided: Bool?
            switch sort {
            case .largest:
                if lhs.bytes != rhs.bytes { decided = (lhs.bytes ?? -1) > (rhs.bytes ?? -1) }
                else { decided = nil }
            case .oldest:
                if lhs.modifiedAt != rhs.modifiedAt {
                    decided = (lhs.modifiedAt ?? .distantFuture) < (rhs.modifiedAt ?? .distantFuture)
                } else { decided = nil }
            case .name:
                let order = lhs.path.localizedStandardCompare(rhs.path)
                decided = order == .orderedSame ? nil : order == .orderedAscending
            }
            return decided ?? (lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending)
        }
        return result
    }

    private static func normalizedPath(_ raw: String) -> String {
        URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    private static func inspect(_ item: Accumulator, fileManager: FileManager) -> CacheInventoryItem? {
        var rootInfo = stat()
        guard lstat(item.path, &rootInfo) == 0 else {
            let issue = scanIssue(errno)
            guard item.includeMissing || issue != "Path does not exist" else { return nil }
            return make(item, bytes: nil, modifiedAt: nil, error: issue)
        }
        let rootType = rootInfo.st_mode & mode_t(S_IFMT)
        if rootType == mode_t(S_IFLNK) {
            return make(item, bytes: nil, modifiedAt: nil, error: "Symbolic-link roots are not followed")
        }
        var latest = modificationDate(rootInfo)
        if rootType == mode_t(S_IFREG) {
            return make(item, bytes: max(0, Int64(rootInfo.st_size)), modifiedAt: latest, error: nil)
        }
        guard rootType == mode_t(S_IFDIR) else {
            return make(item, bytes: nil, modifiedAt: latest, error: "Path is not a regular file or folder")
        }

        var total: Int64 = 0
        var failure: String?
        guard let enumerator = fileManager.enumerator(at: URL(fileURLWithPath: item.path),
            includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in
                failure = error.localizedDescription
                return false
            }) else {
            return make(item, bytes: nil, modifiedAt: latest, error: "Folder could not be enumerated")
        }
        for case let file as URL in enumerator {
            var info = stat()
            guard lstat(file.path, &info) == 0 else {
                failure = scanIssue(errno)
                break
            }
            let type = info.st_mode & mode_t(S_IFMT)
            if type == mode_t(S_IFLNK) {
                enumerator.skipDescendants()
                continue
            }
            if type == mode_t(S_IFREG) { total += max(0, Int64(info.st_size)) }
            let modified = modificationDate(info)
            if let modified, modified > (latest ?? .distantPast) { latest = modified }
        }
        if let failure { return make(item, bytes: nil, modifiedAt: nil, error: failure) }
        return make(item, bytes: total, modifiedAt: latest, error: nil)
    }

    private static func make(_ item: Accumulator, bytes: Int64?, modifiedAt: Date?, error: String?) -> CacheInventoryItem {
        CacheInventoryItem(kind: item.kind, path: item.path, taskIDs: item.taskIDs.sorted(),
                           taskNames: item.taskNames.sorted(), bytes: bytes, modifiedAt: modifiedAt, error: error)
    }

    private static func modificationDate(_ info: stat) -> Date? {
        Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    private static func scanIssue(_ code: Int32) -> String {
        if code == ENOENT || code == ENOTDIR { return "Path does not exist" }
        if code == EACCES || code == EPERM { return "Permission denied" }
        return String(cString: strerror(code))
    }
}
