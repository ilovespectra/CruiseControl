import Darwin
import Foundation

/// The two task-associated path classes Cruise can inspect. This is metadata-only and never changes either path.
public enum CacheInventoryKind: String, CaseIterable, Identifiable, Codable, Sendable {
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

/// Progress for a read-only filesystem traversal.
public struct CacheInventoryScanProgress: Equatable, Sendable {
    public let rootLabel: String
    public let entriesVisited: Int
    public let report: CacheInventoryReport?

    public init(rootLabel: String, entriesVisited: Int, report: CacheInventoryReport? = nil) {
        self.rootLabel = rootLabel
        self.entriesVisited = entriesVisited
        self.report = report
    }
}

/// A configured Clicky storage root that contributes to the headline footprint.
public struct CacheInventoryRoot: Equatable, Sendable {
    public let label: String
    public let path: String

    public init(label: String, path: String) {
        self.label = label
        self.path = path
    }
}

/// One configured root's measured coverage. Non-nil sizes are known bytes; an error means a lower bound.
public struct CacheInventoryRootMeasurement: Identifiable, Equatable, Codable, Sendable {
    public var id: String { "\(label):\(path)" }
    public let label: String
    public let path: String
    public let resolvedPath: String?
    public let apparentBytes: Int64?
    public let allocatedBytes: Int64?
    public let fileCount: Int
    public let error: String?

    public init(label: String, path: String, resolvedPath: String?, apparentBytes: Int64?,
                allocatedBytes: Int64?, fileCount: Int, error: String?) {
        self.label = label
        self.path = path
        self.resolvedPath = resolvedPath
        self.apparentBytes = apparentBytes
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
        self.error = error
    }
}

/// A measured task-associated file or folder. `modifiedAt` is the newest observed modification time in a folder;
/// `bytes == nil` means the size is unknown, never zero.
public struct CacheInventoryItem: Identifiable, Equatable, Codable, Sendable {
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

/// Totals are unique file sizes within each class and across both classes; nested paths and shared files count once.
public struct CacheInventoryReport: Equatable, Codable, Sendable {
    public let items: [CacheInventoryItem]
    public let taskCount: Int
    public let expectedCachePathCount: Int
    public let expectedWorkspacePathCount: Int
    public let taskCacheBytes: Int64
    public let workspaceBytes: Int64
    public let overallUniqueBytes: Int64
    public let workspaceScopeIssue: String?
    public let storageRoots: [CacheInventoryRootMeasurement]
    public let clickyStorageApparentBytes: Int64?
    public let clickyStorageAllocatedBytes: Int64?
    public let clickyStorageFileCount: Int

    public var measuredCachePathCount: Int { items.filter { $0.kind == .cache && $0.bytes != nil }.count }
    public var measuredWorkspacePathCount: Int { items.filter { $0.kind == .workspace && $0.bytes != nil }.count }
    public var cacheIssueCount: Int { items.filter { $0.kind == .cache && $0.error != nil }.count }
    public var workspaceIssueCount: Int { items.filter { $0.kind == .workspace && $0.error != nil }.count }
    public var missingCachePathCount: Int { max(0, expectedCachePathCount - items.filter { $0.kind == .cache }.count) }
    public var isPartial: Bool {
        workspaceScopeIssue != nil || items.contains { $0.error != nil } || storageRoots.contains { $0.error != nil }
    }
    public var storageIsPartial: Bool { storageRoots.isEmpty || storageRoots.contains { $0.error != nil } }
    public var otherSupportBytes: Int64? {
        clickyStorageApparentBytes.map { max(0, $0 - overallUniqueBytes) }
    }
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

    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
        init(_ info: stat) { device = UInt64(info.st_dev); inode = UInt64(info.st_ino) }
    }

    private struct Inspection {
        let item: CacheInventoryItem
        let files: [FileIdentity: Int64]
    }

    private struct FootprintFile {
        let apparentBytes: Int64
        let allocatedBytes: Int64
        let modifiedAt: Date?

        init(_ info: stat) {
            apparentBytes = max(0, Int64(info.st_size))
            allocatedBytes = max(0, Int64(info.st_blocks)) * 512
            modifiedAt = modificationDate(info)
        }
    }

    private struct RootPlan {
        let root: CacheInventoryRoot
        let path: String
        let error: String?
    }

    private struct Tally {
        var identities = Set<FileIdentity>()
        var bytes: Int64 = 0
        var allocated: Int64 = 0
        var latest: Date?

        mutating func add(_ file: FootprintFile, identity: FileIdentity) {
            guard identities.insert(identity).inserted else { return }
            bytes += file.apparentBytes
            allocated += file.allocatedBytes
        }
    }

    public static func sources(tasks: [ClickyAgentTask], catalog: TaskCatalog,
                               cacheRoot: URL, workspaceRoot: URL?) -> [CacheInventorySource] {
        var result: [CacheInventorySource] = []
        for task in tasks {
            for path in ClickyTaskLibrary.cachePaths(threadIDs: task.threadIDs, root: cacheRoot) {
                result.append(CacheInventorySource(kind: .cache, path: path.path, taskID: task.id,
                                                   taskName: task.name))
            }
            if let folder = task.folderPath, !folder.isEmpty,
               isWithinScope(folder, root: workspaceRoot) {
                result.append(CacheInventorySource(kind: .workspace, path: folder, taskID: task.id,
                                                   taskName: task.name, includeMissing: true))
            }
        }
        let namesByID = Dictionary(tasks.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        for saved in catalog.tasks {
            guard let path = saved.project.directoryPath, isWithinScope(path, root: workspaceRoot) else { continue }
            let name = saved.sourceID.flatMap { namesByID[$0] } ?? saved.name
            result.append(CacheInventorySource(kind: .workspace, path: path, taskID: saved.sourceID,
                                               taskName: name, includeMissing: true))
        }
        return result
    }

    /// Scans only caller-supplied paths, merges duplicate task associations, skips symlinks, and keeps partial
    /// byte counts with an error marker. The overall totals deduplicate overlapping paths by filesystem identity.
    public static func scanReport(sources: [CacheInventorySource], taskCount: Int = 0,
                                  workspaceScopeIssue: String? = nil,
                                  storageRoots: [CacheInventoryRoot] = [],
                                  progress: (@Sendable (CacheInventoryScanProgress) -> Void)? = nil,
                                  fileManager: FileManager = .default) -> CacheInventoryReport {
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

        if !storageRoots.isEmpty {
            return scanRootReport(mergedSources: merged, storageRoots: storageRoots, taskCount: taskCount,
                                  workspaceScopeIssue: workspaceScopeIssue, progress: progress, fileManager: fileManager)
        }

        var items: [CacheInventoryItem] = []
        var cacheFiles: [FileIdentity: Int64] = [:]
        var workspaceFiles: [FileIdentity: Int64] = [:]
        var allFiles: [FileIdentity: Int64] = [:]
        for source in merged.values {
            guard let inspected = inspect(source, fileManager: fileManager) else { continue }
            items.append(inspected.item)
            if source.kind == .cache { mergeUnique(inspected.files, into: &cacheFiles) }
            else { mergeUnique(inspected.files, into: &workspaceFiles) }
            mergeUnique(inspected.files, into: &allFiles)
        }
        items.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return CacheInventoryReport(items: items, taskCount: taskCount,
            expectedCachePathCount: merged.values.filter { $0.kind == .cache }.count,
            expectedWorkspacePathCount: merged.values.filter { $0.kind == .workspace }.count,
            taskCacheBytes: cacheFiles.values.reduce(0, +),
            workspaceBytes: workspaceFiles.values.reduce(0, +),
            overallUniqueBytes: allFiles.values.reduce(0, +),
            workspaceScopeIssue: workspaceScopeIssue, storageRoots: [], clickyStorageApparentBytes: nil,
            clickyStorageAllocatedBytes: nil, clickyStorageFileCount: 0)
    }

    /// Measures the configured roots and associated task rows in one traversal per non-overlapping root.
    /// Root aliases are resolved first; overlapping roots and hard-linked files count once in the headline.
    private static func scanRootReport(mergedSources: [String: Accumulator], storageRoots: [CacheInventoryRoot],
                                       taskCount: Int, workspaceScopeIssue: String?,
                                       progress: (@Sendable (CacheInventoryScanProgress) -> Void)?,
                                       fileManager: FileManager) -> CacheInventoryReport {
        let plans: [RootPlan] = storageRoots.map { root in
            let resolved = resolvedPath(root.path)
            var info = stat()
            guard lstat(resolved, &info) == 0 else {
                return RootPlan(root: root, path: resolved, error: scanIssue(errno))
            }
            let type = info.st_mode & mode_t(S_IFMT)
            guard type == mode_t(S_IFDIR) || type == mode_t(S_IFREG) else {
                return RootPlan(root: root, path: resolved, error: "Not a regular file or folder")
            }
            return RootPlan(root: root, path: resolved, error: nil)
        }

        var rootIndexes: [String: [Int]] = [:]
        for index in plans.indices where plans[index].error == nil {
            rootIndexes[plans[index].path, default: []].append(index)
        }
        var sourceKeysByPath: [String: [String]] = [:]
        var sourcePathByKey: [String: String] = [:]
        for (key, source) in mergedSources {
            let path = resolvedPath(source.path)
            sourcePathByKey[key] = path
            sourceKeysByPath[path, default: []].append(key)
        }

        var rootTallies = Array(repeating: Tally(), count: plans.count)
        var rootErrors = plans.map(\.error)
        var details: [String: Tally] = [:]
        var completedRoots = Set<Int>()
        var completedSources = Set<String>()
        var seenSources = Set<String>()
        var scanFailures: [(path: String, message: String)] = []
        var unique = Tally()
        var cache = Tally()
        var workspace = Tally()
        var associated = Tally()
        var categoryOverlap: Int64 = 0

        func noteFailure(_ path: String, _ message: String) {
            scanFailures.append((path, message))
            for index in plans.indices where plans[index].error == nil
                && pathIsWithin(path, root: plans[index].path) {
                rootErrors[index] = rootErrors[index] ?? message
            }
        }

        func snapshot(scanning: Bool) -> CacheInventoryReport {
            let items = mergedSources.compactMap { key, source -> CacheInventoryItem? in
                let path = sourcePathByKey[key] ?? source.path
                let tally = details[key]
                let covered = plans.indices.contains { plans[$0].error == nil && pathIsWithin(path, root: plans[$0].path) }
                var issue = scanFailures.first {
                    pathIsWithin($0.path, root: path) || pathIsWithin(path, root: $0.path)
                }?.message
                if !covered { issue = "Outside measured Clicky storage roots" }
                if !seenSources.contains(key) {
                    var info = stat()
                    if lstat(path, &info) != 0 {
                        let missing = scanIssue(errno)
                        guard source.includeMissing || missing != "Path does not exist" else { return nil }
                        return make(source, bytes: nil, modifiedAt: nil, error: missing)
                    }
                    return make(source, bytes: nil, modifiedAt: nil,
                                error: issue ?? (scanning ? "Waiting to scan" : "Path was not traversed"))
                }
                if scanning && !completedSources.contains(key) { issue = issue ?? "Scan in progress" }
                return make(source, bytes: tally?.bytes ?? 0, modifiedAt: tally?.latest, error: issue)
            }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let roots = plans.indices.map { index in
                let plan = plans[index]
                let tally = rootTallies[index]
                return CacheInventoryRootMeasurement(label: plan.root.label, path: plan.root.path,
                    resolvedPath: plan.error == nil ? plan.path : nil,
                    apparentBytes: plan.error == nil ? tally.bytes : nil,
                    allocatedBytes: plan.error == nil ? tally.allocated : nil,
                    fileCount: tally.identities.count,
                    error: rootErrors[index] ?? (scanning && !completedRoots.contains(index) ? "Scan in progress" : nil))
            }
            let available = plans.contains { $0.error == nil }
            return CacheInventoryReport(items: items, taskCount: taskCount,
                expectedCachePathCount: mergedSources.values.filter { $0.kind == .cache }.count,
                expectedWorkspacePathCount: mergedSources.values.filter { $0.kind == .workspace }.count,
                taskCacheBytes: cache.bytes, workspaceBytes: workspace.bytes - categoryOverlap,
                overallUniqueBytes: associated.bytes, workspaceScopeIssue: workspaceScopeIssue,
                storageRoots: roots, clickyStorageApparentBytes: available ? unique.bytes : nil,
                clickyStorageAllocatedBytes: available ? unique.allocated : nil,
                clickyStorageFileCount: unique.identities.count)
        }

        var entriesVisited = 0
        var lastProgress = ProcessInfo.processInfo.systemUptime
        func publish(_ label: String, force: Bool = false) {
            guard progress != nil else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard force || now - lastProgress >= 0.5 else { return }
            lastProgress = now
            progress?(CacheInventoryScanProgress(rootLabel: label, entriesVisited: entriesVisited,
                                                 report: snapshot(scanning: true)))
        }

        func visit(_ path: String, roots inheritedRoots: [Int], sources inheritedSources: [String],
                   label: String, depth: Int, metadata: stat? = nil) {
            guard !Task.isCancelled else { noteFailure(path, "Scan cancelled"); return }
            guard depth < 256 else { noteFailure(path, "Maximum folder depth exceeded"); return }
            var info = metadata ?? stat()
            if metadata == nil && lstat(path, &info) != 0 { noteFailure(path, scanIssue(errno)); return }
            let type = info.st_mode & mode_t(S_IFMT)
            guard type == mode_t(S_IFDIR) || type == mode_t(S_IFREG) else { return }
            let ownRoots = rootIndexes[path] ?? []
            let ownSources = sourceKeysByPath[path] ?? []
            let roots = inheritedRoots + ownRoots
            let sources = inheritedSources + ownSources
            seenSources.formUnion(ownSources)
            for key in sources {
                if let date = modificationDate(info), date > (details[key]?.latest ?? .distantPast) {
                    details[key, default: Tally()].latest = date
                }
            }
            if type == mode_t(S_IFREG) {
                let identity = FileIdentity(info)
                let file = FootprintFile(info)
                unique.add(file, identity: identity)
                for index in roots { rootTallies[index].add(file, identity: identity) }
                for key in sources { details[key, default: Tally()].add(file, identity: identity) }
                let isCache = sources.contains { mergedSources[$0]?.kind == .cache }
                let isWorkspace = sources.contains { mergedSources[$0]?.kind == .workspace }
                let overlappedBefore = cache.identities.contains(identity) && workspace.identities.contains(identity)
                if isCache { cache.add(file, identity: identity) }
                if isWorkspace { workspace.add(file, identity: identity) }
                if !overlappedBefore && cache.identities.contains(identity) && workspace.identities.contains(identity) {
                    categoryOverlap += file.apparentBytes
                }
                if !sources.isEmpty { associated.add(file, identity: identity) }
            } else {
                do {
                    let bulkSupported = try bulkEntries(path) { name, metadata in
                        guard !Task.isCancelled else { return }
                        visit(path == "/" ? "/" + name : path + "/" + name,
                              roots: roots, sources: sources, label: label, depth: depth + 1, metadata: metadata)
                    }
                    if !bulkSupported {
                        guard let directory = opendir(path) else {
                            noteFailure(path, scanIssue(errno))
                            return
                        }
                        defer { closedir(directory) }
                        while !Task.isCancelled {
                            errno = 0
                            guard let entry = readdir(directory) else {
                                if errno != 0 { noteFailure(path, scanIssue(errno)) }
                                break
                            }
                            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                                    String(cString: $0)
                                }
                            }
                            if name == "." || name == ".." { continue }
                            visit(path == "/" ? "/" + name : path + "/" + name,
                                  roots: roots, sources: sources, label: label, depth: depth + 1)
                        }
                    }
                } catch {
                    noteFailure(path, error.localizedDescription)
                }
                if Task.isCancelled { noteFailure(path, "Scan cancelled") }
            }
            completedRoots.formUnion(ownRoots)
            completedSources.formUnion(ownSources)
            entriesVisited += 1
            if entriesVisited % 256 == 0 { publish(label) }
        }

        var scanned = Set<String>()
        for plan in plans where plan.error == nil {
            // Preserve caller order (support/cache first), but traverse a containing root only once.
            guard !plans.contains(where: { $0.error == nil && $0.path != plan.path && pathIsWithin(plan.path, root: $0.path) }),
                  scanned.insert(plan.path).inserted else { continue }
            publish(plan.root.label, force: true)
            visit(plan.path, roots: [], sources: [], label: plan.root.label, depth: 0)
            publish(plan.root.label, force: true)
            if Task.isCancelled { break }
        }
        for index in plans.indices where plans[index].error == nil && !completedRoots.contains(index) {
            rootErrors[index] = rootErrors[index] ?? "Scan cancelled before root completed"
        }
        return snapshot(scanning: false)
    }

    /// macOS bulk metadata avoids a separate stat syscall for every file on supported volumes.
    private static func bulkEntries(_ path: String, visit: (String, stat?) -> Void) throws -> Bool {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        var common = UInt32(ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME)
        common |= UInt32(ATTR_CMN_FILEID | ATTR_CMN_ERROR) | ATTR_CMN_RETURNED_ATTRS
        let files = UInt32(ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH)
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = common
        attributes.fileattr = files
        let capacity = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { buffer.deallocate() }
        var readAny = false
        while !Task.isCancelled {
            let count = getattrlistbulk(descriptor, &attributes, buffer, capacity, UInt64(FSOPT_PACK_INVAL_ATTRS))
            if count < 0 {
                let code = errno
                if !readAny && [ENOTSUP, EINVAL, ENOSYS].contains(code) { return false }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            if count == 0 { return true }
            readAny = true
            var offset = 0
            for _ in 0..<count {
                guard offset + 4 <= capacity else { throw CocoaError(.fileReadCorruptFile) }
                let start = buffer.advanced(by: offset)
                let length = Int(start.loadUnaligned(as: UInt32.self))
                // getattrlist records are packed on four-byte boundaries, not Swift struct alignment.
                guard length >= 68, length <= capacity - offset else { throw CocoaError(.fileReadCorruptFile) }
                let returned = start.advanced(by: 4).loadUnaligned(as: attribute_set_t.self)
                let nameReference = start.advanced(by: 28).loadUnaligned(as: attrreference_t.self)
                let nameOffset = 28 + Int(nameReference.attr_dataoffset)
                let nameLength = Int(nameReference.attr_length)
                guard returned.commonattr & UInt32(ATTR_CMN_NAME) != 0,
                      nameOffset >= 68, nameLength > 0, nameLength <= length,
                      nameOffset <= length - nameLength else { throw CocoaError(.fileReadCorruptFile) }
                let nameBytes = UnsafeRawBufferPointer(start: start.advanced(by: nameOffset), count: nameLength)
                guard nameBytes.last == 0,
                      let name = String(bytes: nameBytes.dropLast(), encoding: .utf8),
                      !name.contains("/"), name != ".", name != ".." else { throw CocoaError(.fileReadCorruptFile) }
                var metadata: stat?
                let needed = UInt32(ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_FILEID)
                let type = start.advanced(by: 40).loadUnaligned(as: fsobj_type_t.self)
                let entryError = start.advanced(by: 24).loadUnaligned(as: UInt32.self)
                if entryError == 0, returned.commonattr & needed == needed,
                   type == UInt32(VDIR.rawValue) || (type == UInt32(VREG.rawValue) && returned.fileattr & files == files) {
                    var info = stat()
                    info.st_dev = start.advanced(by: 36).loadUnaligned(as: dev_t.self)
                    info.st_ino = start.advanced(by: 60).loadUnaligned(as: ino_t.self)
                    info.st_mtimespec = start.advanced(by: 44).loadUnaligned(as: timespec.self)
                    info.st_mode = mode_t(type == UInt32(VDIR.rawValue) ? S_IFDIR : S_IFREG)
                    if type == UInt32(VREG.rawValue) {
                        guard nameOffset >= 84 else { throw CocoaError(.fileReadCorruptFile) }
                        info.st_size = start.advanced(by: 76).loadUnaligned(as: off_t.self)
                        info.st_blocks = start.advanced(by: 68).loadUnaligned(as: off_t.self) / 512
                    }
                    metadata = info
                }
                visit(name, metadata)
                offset += length
            }
        }
        return true
    }

    public static func scan(sources: [CacheInventorySource], fileManager: FileManager = .default) -> [CacheInventoryItem] {
        scanReport(sources: sources, fileManager: fileManager).items
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

    private static func resolvedPath(_ raw: String) -> String {
        URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func pathIsWithin(_ path: String, root: String) -> Bool {
        root == "/" || path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func isWithinScope(_ path: String, root: URL?) -> Bool {
        guard let root else { return true }
        let candidate = normalizedPath(path)
        let scope = normalizedPath(root.path)
        return scope == "/" || candidate == scope || candidate.hasPrefix(scope + "/")
    }

    private static func mergeUnique(_ incoming: [FileIdentity: Int64], into total: inout [FileIdentity: Int64]) {
        for (identity, bytes) in incoming where total[identity] == nil { total[identity] = bytes }
    }

    private static func inspect(_ item: Accumulator, fileManager: FileManager) -> Inspection? {
        var rootInfo = stat()
        guard lstat(item.path, &rootInfo) == 0 else {
            let issue = scanIssue(errno)
            guard item.includeMissing || issue != "Path does not exist" else { return nil }
            return Inspection(item: make(item, bytes: nil, modifiedAt: nil, error: issue), files: [:])
        }
        let rootType = rootInfo.st_mode & mode_t(S_IFMT)
        if rootType == mode_t(S_IFLNK) {
            return Inspection(item: make(item, bytes: nil, modifiedAt: nil, error: "Symbolic-link roots are not followed"), files: [:])
        }
        var latest = modificationDate(rootInfo)
        if rootType == mode_t(S_IFREG) {
            let size = max(0, Int64(rootInfo.st_size))
            return Inspection(item: make(item, bytes: size, modifiedAt: latest, error: nil),
                              files: [FileIdentity(rootInfo): size])
        }
        guard rootType == mode_t(S_IFDIR) else {
            return Inspection(item: make(item, bytes: nil, modifiedAt: latest,
                                         error: "Path is not a regular file or folder"), files: [:])
        }

        var files: [FileIdentity: Int64] = [:]
        var failure: String?
        guard let enumerator = fileManager.enumerator(at: URL(fileURLWithPath: item.path),
            includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in
                failure = error.localizedDescription
                return false
            }) else {
            return Inspection(item: make(item, bytes: nil, modifiedAt: latest,
                                         error: "Folder could not be enumerated"), files: [:])
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
            if type == mode_t(S_IFREG) { files[FileIdentity(info)] = max(0, Int64(info.st_size)) }
            let modified = modificationDate(info)
            if let modified, modified > (latest ?? .distantPast) { latest = modified }
        }
        let knownBytes = files.values.reduce(0, +)
        let rowBytes = failure == nil || !files.isEmpty ? knownBytes : nil
        return Inspection(item: make(item, bytes: rowBytes, modifiedAt: latest, error: failure), files: files)
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
