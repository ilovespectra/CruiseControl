import Foundation

public enum TaskGrouping: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, project, directory, repository
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: return "Off"
        case .project: return "Project"
        case .directory: return "Directory"
        case .repository: return "GitHub repository"
        }
    }
}

public enum TaskSort: String, Codable, CaseIterable, Identifiable, Sendable {
    case priority, sourceOrder, name, status, updated, newest, oldest, longestThread, largestCache
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .priority: return "Priority first"
        case .sourceOrder: return "Original order"
        case .name: return "Task name"
        case .status: return "Status"
        case .updated: return "Recently changed"
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .longestThread: return "Longest thread"
        case .largestCache: return "Largest local size"
        }
    }
}

public struct TaskProject: Codable, Equatable, Sendable {
    public var name = ""
    public var directory = ""
    public var repository = ""

    public init() {}

    public var priorityKey: String {
        repositoryName.map { "repo:\($0.lowercased())" }
            ?? title.map { "name:\(Matcher.normalize($0))" } ?? "unassigned"
    }

    public var repositoryName: String? {
        var value = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("git@github.com:") {
            value = String(value.dropFirst("git@github.com:".count))
        } else if value.contains("://") {
            guard let url = URL(string: value), url.host?.lowercased() == "github.com" else { return nil }
            value = url.path
        }
        let parts = value.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        let owner = String(parts[0])
        var repo = String(parts[1])
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard !owner.isEmpty, !repo.isEmpty, owner != ".", owner != "..", repo != ".", repo != "..",
              (owner + repo).unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return "\(owner)/\(repo)"
    }

    public var directoryPath: String? {
        let value = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("/") || value.hasPrefix("~/") else { return nil }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    public var title: String? {
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let repo = repositoryName { return String(repo.split(separator: "/").last ?? "") }
        return directoryPath.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    fileprivate var groupingKeys: [String] {
        var keys: [String] = []
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { keys.append("name:\(Matcher.normalize(name))") }
        if let repository = repositoryName { keys.append("repo:\(repository.lowercased())") }
        if let directory = directoryPath { keys.append("dir:\(directory)") }
        return keys
    }

    /// Only explicit repository links and paths inside a local Git checkout count as project evidence.
    public static func detect(in lines: [String]) -> TaskProject? {
        let pattern = #"(?:https?://github\.com/|git@github\.com:)([A-Za-z0-9_-]+/[A-Za-z0-9_.-]+)"#
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let text = lines.joined(separator: "\n")
        let repositories = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            var project = TaskProject()
            project.repository = String(text[range])
            return project.repositoryName?.lowercased()
        }
        let paths = try! NSRegularExpression(pattern: #"/(?:Users|home|Volumes|private|tmp|var)/[^\s"'`<>;,()]+"#)
        let directories = paths.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> String? in
            guard let range = Range(match.range, in: text) else { return nil }
            var url = URL(fileURLWithPath: String(text[range])).standardizedFileURL
            while url.path != "/" {
                if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
                url.deleteLastPathComponent()
            }
            return nil
        }
        let uniqueRepositories = Set(repositories)
        let uniqueDirectories = Set(directories)
        guard uniqueRepositories.count <= 1, uniqueDirectories.count <= 1,
              !uniqueRepositories.isEmpty || !uniqueDirectories.isEmpty else { return nil }
        if let repository = repositories.first, let directory = directories.first,
           Matcher.normalize(String(repository.split(separator: "/").last ?? ""))
            != Matcher.normalize(URL(fileURLWithPath: directory).lastPathComponent) { return nil }
        var project = TaskProject()
        project.repository = repositories.first ?? ""
        project.directory = directories.first ?? ""
        return project
    }
}

public enum SavedTaskDisposition: String, Codable, Sendable {
    case archived, finished
}

public struct CatalogTask: Codable, Equatable, Identifiable, Sendable {
    public var localDisposition: SavedTaskDisposition?
    public let id: String
    public var name: String
    public var status: String
    public var updatedAt: Date
    public var project = TaskProject()
    public var projectAssigned = false
    public var matchingThreads: Int?
    public var threadCount: Int { max(1, matchingThreads ?? 1) }
    public var sourceID: String?
    public var sourceUnavailable: Bool?
    public var createdAt: Date?
    public var runCount: Int?
    public var messageCount: Int?
    public var localBytes: Int64?
    public var inferenceFingerprint: String?
    public var inferredBy: String?
}

public struct TaskCatalog: Codable, Equatable, Sendable {
    public private(set) var tasks: [CatalogTask] = []
    public var threadCount: Int { tasks.reduce(0) { $0 + $1.threadCount } }
    public var currentTaskCount: Int { tasks.filter { $0.sourceID != nil && $0.sourceUnavailable != true }.count }
    public init() {}

    public mutating func observe(name: String, status: String?, now: Date = Date(), project: TaskProject? = nil, threadCount: Int = 1) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let id = Matcher.normalize(name)
        if let index = tasks.firstIndex(where: { $0.id == id }) {
            let previous = tasks[index]
            tasks[index].name = name
            if let status, !status.isEmpty { tasks[index].status = status }
            if threadCount > tasks[index].threadCount { tasks[index].matchingThreads = threadCount }
            if !tasks[index].projectAssigned, let project { tasks[index].project = project }
            if tasks[index] != previous { tasks[index].updatedAt = now }
        } else {
            var task = CatalogTask(id: id, name: name, status: status ?? "Unknown", updatedAt: now)
            if let project { task.project = project }
            if threadCount > 1 { task.matchingThreads = threadCount }
            tasks.append(task)
        }
    }

    public mutating func assign(_ project: TaskProject, to id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].project = project
        tasks[index].projectAssigned = true
        tasks[index].inferredBy = nil
    }

    @discardableResult
    public mutating func manageSavedRecord(_ id: String, disposition: SavedTaskDisposition?, delete: Bool = false) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              tasks[index].sourceUnavailable == true || tasks[index].sourceID == nil else { return false }
        if delete { tasks.remove(at: index) }
        else { tasks[index].localDisposition = disposition }
        return true
    }

    public mutating func infer(_ project: TaskProject?, for id: String, fingerprint: String, model: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), !tasks[index].projectAssigned else { return }
        tasks[index].project = project ?? TaskProject()
        tasks[index].inferenceFingerprint = fingerprint
        tasks[index].inferredBy = model
    }

    public mutating func resetProject(for id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].project = TaskProject()
        tasks[index].projectAssigned = false
        tasks[index].inferenceFingerprint = nil
        tasks[index].inferredBy = nil
    }

    public mutating func synchronize(_ source: [ClickyAgentTask]) throws {
        var seen: Set<String> = []
        for task in source {
            guard seen.insert(task.id).inserted else { throw CatalogError.duplicateTaskID(task.id) }
        }
        let names = Dictionary(grouping: source) { Matcher.normalize($0.name) }
        var migrated: Set<String> = []
        var imported: [CatalogTask] = []
        for task in source {
            let existing = tasks.first { $0.sourceID == task.id }
            let legacy = names[Matcher.normalize(task.name)]?.count == 1
                ? tasks.first { $0.sourceID == nil && $0.id == Matcher.normalize(task.name) } : nil
            let saved = existing?.projectAssigned == true ? existing
                : legacy?.projectAssigned == true ? legacy : existing ?? legacy
            if let legacy, saved?.sourceID == nil { migrated.insert(legacy.id) }
            var record = CatalogTask(id: task.id, name: task.name, status: task.outcome,
                                     updatedAt: task.updatedAt ?? task.createdAt ?? existing?.updatedAt ?? .distantPast)
            record.sourceID = task.id
            record.createdAt = task.createdAt
            record.runCount = task.runCount
            record.messageCount = task.messageCount
            record.localBytes = task.totalBytes
            if let saved {
                record.project = saved.project
                record.projectAssigned = saved.projectAssigned
                record.inferenceFingerprint = saved.inferenceFingerprint
                record.inferredBy = saved.inferredBy
            }
            let fingerprint = ProjectInference.fingerprint(for: task)
            if !record.projectAssigned, record.inferenceFingerprint != fingerprint {
                record.project = TaskProject.detect(in: [task.prompt, task.latestAsk, task.lastMessage]
                    + task.projectEvidence + ProjectInference.pathEvidence(for: task)) ?? TaskProject()
                record.inferenceFingerprint = fingerprint
                record.inferredBy = nil
            }
            imported.append(record)
        }
        // Never attach a name-only assignment to one arbitrary same-named job.
        for var saved in tasks where !migrated.contains(saved.id)
            && (saved.sourceID.map { !seen.contains($0) }
                ?? (saved.projectAssigned || names[Matcher.normalize(saved.name)] == nil)) {
            saved.sourceUnavailable = true
            imported.append(saved)
        }
        tasks = imported
    }

    public enum CatalogError: LocalizedError {
        case duplicateTaskID(String)
        public var errorDescription: String? {
            switch self {
            case .duplicateTaskID(let id): return "HeyClicky's task list contains duplicate job ID \(id)."
            }
        }
    }

    public struct Group: Identifiable {
        public let id: String
        public let title: String
        public let project: TaskProject
        public let tasks: [CatalogTask]
    }

    public struct NameSuggestionGroup: Identifiable, Sendable {
        public let id: String
        public let firstWord: String
        public let tasks: [CatalogTask]
    }

    /// Initial setup suggestions use the shared first word literally; the user confirms every association.
    public func nameSuggestionGroups() -> [NameSuggestionGroup] {
        let candidates = tasks.filter { $0.sourceID != nil && $0.sourceUnavailable != true && !$0.projectAssigned }
        let grouped = Dictionary(grouping: candidates) { task -> String in
            let first = task.name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            return Matcher.normalize(first)
        }
        return grouped.compactMap { key, items -> NameSuggestionGroup? in
            guard !key.isEmpty else { return nil }
            let ordered = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let firstWord = ordered.first?.name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? key
            return NameSuggestionGroup(id: key, firstWord: firstWord, tasks: ordered)
        }.sorted {
            $0.firstWord.localizedStandardCompare($1.firstWord) == .orderedAscending
        }
    }

    public func groups(by grouping: TaskGrouping, sort: TaskSort, query: String = "") -> [Group] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliases = grouping == .project ? projectAliases() : [:]
        let buckets = Dictionary(grouping: tasks) { task -> String in
            let project = task.project
            switch grouping {
            case .none: return "all"
            case .project:
                return project.groupingKeys.compactMap { aliases[$0] }.first ?? "unassigned"
            case .directory: return project.directoryPath.map { "dir:\($0)" } ?? "unassigned"
            case .repository: return project.repositoryName.map { "repo:\($0.lowercased())" } ?? "unassigned"
            }
        }
        return buckets.compactMap { key, values -> Group? in
            let ordered = sort == .sourceOrder ? values : values.sorted { left, right in
                if sort == .updated, left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
                if sort == .newest || sort == .oldest, left.createdAt != right.createdAt {
                    guard let leftDate = left.createdAt else { return false }
                    guard let rightDate = right.createdAt else { return true }
                    return sort == .newest ? leftDate > rightDate : leftDate < rightDate
                }
                if sort == .longestThread {
                    if left.runCount != right.runCount { return (left.runCount ?? -1) > (right.runCount ?? -1) }
                    if left.messageCount != right.messageCount { return (left.messageCount ?? -1) > (right.messageCount ?? -1) }
                }
                if sort == .largestCache, left.localBytes != right.localBytes { return (left.localBytes ?? -1) > (right.localBytes ?? -1) }
                if sort == .status, left.status != right.status {
                    let comparison = left.status.localizedStandardCompare(right.status)
                    if comparison != .orderedSame { return comparison == .orderedAscending }
                }
                let comparison = left.name.localizedStandardCompare(right.name)
                return comparison == .orderedSame ? left.id < right.id : comparison == .orderedAscending
            }
            let named = values.filter { !$0.project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .min { $0.project.name.localizedStandardCompare($1.project.name) == .orderedAscending }
            var project = (named ?? ordered[0]).project
            for task in ordered {
                if project.directory.isEmpty { project.directory = task.project.directory }
                if project.repository.isEmpty { project.repository = task.project.repository }
            }
            let title: String
            if grouping == .none { title = "All tasks" }
            else if key == "unassigned" { title = "Unassigned" }
            else {
                switch grouping {
                case .project: title = project.title ?? "Unassigned"
                case .directory: title = project.directoryPath ?? "Unassigned"
                case .repository: title = project.repositoryName ?? "Unassigned"
                case .none: title = "All tasks"
                }
            }
            let matchesProject = grouping != .none && [title, project.name, project.directory, project.repository]
                .contains(where: { $0.localizedCaseInsensitiveContains(query) })
            let visible = ordered.filter {
                query.isEmpty || matchesProject || [$0.name, $0.status, $0.project.name, $0.project.directory, $0.project.repository]
                    .contains(where: { $0.localizedCaseInsensitiveContains(query) })
            }
            guard !visible.isEmpty else { return nil }
            return Group(id: key, title: title, project: project, tasks: visible)
        }.sorted {
            if $0.id == "unassigned" { return false }
            if $1.id == "unassigned" { return true }
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    private func projectAliases() -> [String: String] {
        var connections: [String: Set<String>] = [:]
        var repositoriesByName: [String: Set<String>] = [:]
        for task in tasks {
            if let repository = task.project.repositoryName,
               let name = task.project.groupingKeys.first(where: { $0.hasPrefix("name:") }) {
                repositoriesByName[name, default: []].insert(repository.lowercased())
            }
        }
        let ambiguousNames = Set(repositoriesByName.filter { $0.value.count > 1 }.keys)
        for task in tasks {
            let keys = task.project.groupingKeys.filter { !ambiguousNames.contains($0) }
            for key in keys { connections[key, default: []].formUnion(keys) }
        }
        var aliases: [String: String] = [:]
        for key in connections.keys.sorted() where aliases[key] == nil {
            var pending = [key]
            var component: Set<String> = []
            while let next = pending.popLast() {
                guard component.insert(next).inserted else { continue }
                pending.append(contentsOf: connections[next] ?? [])
            }
            for alias in component { aliases[alias] = key }
        }
        return aliases
    }
}
