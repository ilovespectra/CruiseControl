import Combine
import CruiseCore
import Foundation

/// Backs Settings → Tasks and the definition-of-done follow-ups.
@MainActor
final class ClickyTaskStore: ObservableObject {
    static let shared = ClickyTaskStore()

    struct Record: Codable, Equatable {
        var assessment: ClickyTaskAssessment?
        var progress = DoneProgress()
        var backgroundReply: BackgroundReply?
        var completionNotice: TaskCompletionNotice?
    }

    func recordDefinitionDelivery(_ message: PendingMessage) -> Bool {
        guard let target = message.completionTarget else { return true }
        let previous = records[target.taskID]
        var record = record(target.taskID)
        guard record.progress.lastFingerprint == target.reportFingerprint,
              DefinitionOfDone.normalized(record.progress.definition) == DefinitionOfDone.normalized(target.definition) else {
            loadError = "The delivery receipt no longer matches this task's saved follow-up."
            return false
        }
        record.progress.deliveredAt = Date()
        records[target.taskID] = record
        guard save() else {
            records[target.taskID] = previous
            return false
        }
        return true
    }

    struct BackgroundReply: Codable, Equatable {
        var fingerprint: String
        var definition: String
        var text: String
        var createdAt: Date
        var deliveredAt: Date?
    }

    struct SizeRecord: Codable, Equatable {
        var cacheBytes: Int64
        var folderBytes: Int64?
        var measuredAt: Date
    }

    private struct Saved: Codable {
        var records: [String: Record] = [:]
        var sizes: [String: SizeRecord] = [:]
    }

    @Published private(set) var tasks: [ClickyAgentTask] = []
    @Published private(set) var records: [String: Record] = [:]
    @Published private(set) var loading = false
    @Published private(set) var measuring = false
    @Published private(set) var assessing: Set<String> = []
    @Published private(set) var loadedAt: Date?
    @Published private(set) var loadError: String?
    /// Set when the saved assessments/rounds file exists but can't be read. Nothing is written over it, and
    /// definition-of-done follow-ups stay off, until the user moves or repairs that file.
    @Published private(set) var persistenceError: String?
    /// Why a task's size couldn't be measured (unreadable cache, job folder missing or drive not mounted).
    @Published private(set) var measureErrors: [String: String] = [:]
    @Published var requestedTaskID: String?

    private var sizes: [String: SizeRecord] = [:]
    private var assessQueueRunning = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private let root: URL
    private let fileURL: URL

    init(root: URL = ClickyTaskLibrary.defaultRoot,
         fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CruiseControl/clicky-tasks.json")) {
        self.root = root
        self.fileURL = fileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let saved = try JSONDecoder.iso.decode(Saved.self, from: Data(contentsOf: fileURL))
            records = saved.records
            sizes = saved.sizes
        } catch {
            persistenceError = "Saved task assessments at \(fileURL.path) are unreadable (\(error.localizedDescription)). "
                + "Cruise won't overwrite them or send define-done follow-ups until that file is moved or repaired."
        }
    }

    var canPersist: Bool { persistenceError == nil }

    func task(_ id: String) -> ClickyAgentTask? { tasks.first { $0.id == id } }

    func record(_ id: String) -> Record { records[id] ?? Record() }

    @discardableResult
    func recordCompletion(_ notice: TaskCompletionNotice) -> Bool {
        let previous = records[notice.taskID]
        var record = record(notice.taskID)
        if notice.isSameReport(as: record.completionNotice) { return true }
        // The first review after install/definition change is a silent baseline, not a state change.
        var notice = notice
        if record.completionNotice?.definition != notice.definition { notice.acknowledgedAt = Date() }
        record.completionNotice = notice
        records[notice.taskID] = record
        guard save() else {
            records[notice.taskID] = previous
            return false
        }
        return true
    }

    func acknowledgeCompletion(_ notice: TaskCompletionNotice) -> Bool {
        let previous = records[notice.taskID]
        var record = record(notice.taskID)
        guard record.completionNotice == notice else { return false }
        record.completionNotice?.acknowledgedAt = Date()
        records[notice.taskID] = record
        guard save() else {
            records[notice.taskID] = previous
            return false
        }
        return true
    }

    @discardableResult
    func saveBackgroundReply(_ text: String, for task: ClickyAgentTask, definition: String) -> Bool {
        let previous = records[task.id]
        var record = record(task.id)
        record.backgroundReply = BackgroundReply(fingerprint: task.fingerprint, definition: definition,
                                                 text: text, createdAt: Date())
        records[task.id] = record
        guard save() else {
            records[task.id] = previous
            return false
        }
        return true
    }

    func recordBackgroundDelivery(_ message: PendingMessage) -> Bool {
        guard let target = message.completionTarget else { return false }
        let previous = records[target.taskID]
        var record = record(target.taskID)
        if record.backgroundReply?.text == message.text,
           record.backgroundReply?.definition == target.definition {
            record.backgroundReply?.deliveredAt = Date()
            records[target.taskID] = record
            guard save() else {
                records[target.taskID] = previous
                return false
            }
        }
        return true
    }

    private var userAttentionCache: [String: (report: String, requiresUser: Bool)] = [:]

    func reportRequiresUser(_ task: ClickyAgentTask) -> Bool {
        if let cached = userAttentionCache[task.id], cached.report == task.lastMessage {
            return cached.requiresUser
        }
        let requiresUser = TaskAudit.requiresUser(task.lastMessage)
        userAttentionCache[task.id] = (task.lastMessage, requiresUser)
        return requiresUser
    }

    /// The assessment for the task's latest report and current definition, if Ollama (or the rules) read it.
    func currentAssessment(for task: ClickyAgentTask, definition: String?) -> ClickyTaskAssessment? {
        records[task.id]?.assessment.flatMap {
            guard $0.isCurrent(for: task, definition: definition) else { return nil }
            if definition != nil, $0.source.hasPrefix("ollama"),
               !$0.evaluatesUserCriteria(definition) { return nil }
            // Ollama's guess that a criterion "needs the user" doesn't hold unless HeyClicky's report actually asks.
            if let definition = DefinitionOfDone.normalized(definition), $0.source.hasPrefix("ollama"),
               DefinitionOfDone.needsAgentFollowUp($0, report: task.lastMessage) {
                return DefinitionOfDone.redirectedToAgent($0, definition: definition)
            }
            return $0
        }
    }

    /// Reloads the task list. `measure` also re-measures cache sizes older than `maxSizeAge` in the background.
    func refresh(measure: Bool = false, maxSizeAge: TimeInterval = 30 * 60) async {
        let requestedAt = Date()
        while loading {
            await withCheckedContinuation { refreshWaiters.append($0) }
            if loadedAt.map({ $0 >= requestedAt }) == true, loadError == nil {
                if measure { measureSizes(maxAge: maxSizeAge) }
                return
            }
        }
        let readStarted = Date()
        loading = true
        defer {
            loading = false
            let waiters = refreshWaiters
            refreshWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        let root = root
        let result: Result<[ClickyAgentTask], Error> = await Task.detached(priority: .utility) {
            do {
                return .success(try ClickyTaskLibrary.load(jobsData: Self.readJobsData(), root: root))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let loaded):
            let liveIDs = Set(loaded.map(\.id))
            userAttentionCache = userAttentionCache.filter { liveIDs.contains($0.key) }
            tasks = loaded.map(applySizes)
            loadedAt = readStarted
            loadError = nil
        case .failure(let error):
            loadError = "Couldn't read HeyClicky tasks: \(error.localizedDescription)"
        }
        if measure { measureSizes(maxAge: maxSizeAge) }
    }

    private func applySizes(_ task: ClickyAgentTask) -> ClickyAgentTask {
        var task = task
        if let size = sizes[task.id] {
            task.cacheBytes = size.cacheBytes
            task.folderBytes = size.folderBytes
        }
        return task
    }

    private func measureSizes(maxAge: TimeInterval) {
        guard !measuring else { return }
        let now = Date()
        let due = ClickyTaskLibrary.sorted(tasks, by: .newest)
            .filter { now.timeIntervalSince(sizes[$0.id]?.measuredAt ?? .distantPast) >= maxAge }
            .map { (id: $0.id, threads: $0.threadIDs, folder: $0.folderPath) }
        guard !due.isEmpty else { return }
        measuring = true
        let root = root
        Task {
            for item in due {
                let measured = await Task.detached(priority: .utility) { () -> Result<SizeRecord, Error> in
                    do {
                        var cache: Int64 = 0
                        for path in ClickyTaskLibrary.cachePaths(threadIDs: item.threads, root: root) {
                            cache += try ClickyTaskLibrary.measuredSize(of: path) ?? 0
                        }
                        var folder: Int64?
                        if let path = item.folder, !path.isEmpty {
                            guard let bytes = try ClickyTaskLibrary.measuredSize(of: URL(fileURLWithPath: path)) else {
                                throw MeasureError.folderMissing(path)
                            }
                            folder = bytes
                        }
                        return .success(SizeRecord(cacheBytes: cache, folderBytes: folder, measuredAt: Date()))
                    } catch {
                        return .failure(error)
                    }
                }.value
                switch measured {
                case .success(let size):
                    sizes[item.id] = size
                    measureErrors[item.id] = nil
                    if let index = tasks.firstIndex(where: { $0.id == item.id }) {
                        tasks[index].cacheBytes = size.cacheBytes
                        tasks[index].folderBytes = size.folderBytes
                    }
                case .failure(let error):
                    // Keep any earlier measurement rather than reporting a misleading 0 bytes.
                    measureErrors[item.id] = error.localizedDescription
                }
            }
            measuring = false
            save()
        }
    }

    @discardableResult
    func assess(_ task: ClickyAgentTask, config: Config, localOnly: Bool = false) async -> ClickyTaskAssessment {
        let definition = config.clickyDefinitionsOfDone[task.id]
        assessing.insert(task.id)
        defer { assessing.remove(task.id) }
        let assessment = await Ollama.assessClickyTask(task, definition: definition, config: config, localOnly: localOnly)
        var record = record(task.id)
        record.assessment = assessment
        records[task.id] = record
        save()
        return assessment
    }

    /// Reads every visible task whose latest report or definition changed since it was last assessed, newest first.
    func assessStale(config: @escaping () -> Config, includeDismissed: Bool = false) {
        guard !assessQueueRunning else { return }
        assessQueueRunning = true
        Task {
            defer { assessQueueRunning = false }
            for task in ClickyTaskLibrary.sorted(tasks, by: .newest) where includeDismissed || !task.dismissed {
                let config = config()
                guard let current = self.task(task.id),
                      currentAssessment(for: current, definition: config.clickyDefinitionsOfDone[current.id]) == nil else { continue }
                await assess(current, config: config)
            }
        }
    }

    /// Reserves a follow-up round on disk. Returns false (and changes nothing) unless the reservation is durable.
    @discardableResult
    func recordFollowUp(_ task: ClickyAgentTask, definition: String, missing: [String]? = nil) -> Bool {
        guard canPersist else { return false }
        let previous = records[task.id]
        var record = record(task.id)
        if DefinitionOfDone.normalized(record.progress.definition) != DefinitionOfDone.normalized(definition) {
            record.progress = DoneProgress()
            record.progress.definition = definition
        }
        record.progress.rounds += 1
        record.progress.lastFingerprint = task.fingerprint
        record.progress.lastSentAt = Date()
        record.progress.lastReport = task.lastMessage
        record.progress.deliveredAt = nil
        record.progress.lastMissing = missing
            ?? record.assessment.flatMap { $0.isCurrent(for: task, definition: definition) ? $0.missing : nil }
        records[task.id] = record
        guard save() else {
            records[task.id] = previous
            return false
        }
        return true
    }

    /// Undoes a round reserved by `recordFollowUp` when the message was definitely not sent (nor saved for retry).
    @discardableResult
    func restoreProgress(_ progress: DoneProgress, for id: String) -> Bool {
        let previous = records[id]
        var record = record(id)
        record.progress = progress
        records[id] = record
        guard save() else {
            records[id] = previous
            return false
        }
        return true
    }

    /// Rounds count against one definition; editing it starts over.
    func rounds(for task: ClickyAgentTask, definition: String?) -> Int {
        guard let progress = records[task.id]?.progress,
              DefinitionOfDone.normalized(progress.definition) == DefinitionOfDone.normalized(definition) else { return 0 }
        return progress.rounds
    }

    @discardableResult
    private func save() -> Bool {
        if let persistenceError {
            loadError = persistenceError
            return false
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.iso.encode(Saved(records: records, sizes: sizes)).write(to: fileURL, options: .atomic)
            return true
        } catch {
            loadError = "Couldn't save task assessments: \(error.localizedDescription)"
            return false
        }
    }

    enum LoadError: LocalizedError {
        case noJobList
        case unreadablePreferences(String)
        var errorDescription: String? {
            switch self {
            case .noJobList: "HeyClicky's job list (\(ClickyTaskLibrary.jobsKey)) wasn't found in its preferences."
            case .unreadablePreferences(let reason): "HeyClicky's preferences couldn't be read: \(reason)"
            }
        }
    }

    enum MeasureError: LocalizedError {
        case folderMissing(String)
        var errorDescription: String? {
            switch self {
            case .folderMissing(let path): "Job folder not found (drive not mounted?): \(path)"
            }
        }
    }

    /// HeyClicky keeps its job list as JSON data in its preferences.
    nonisolated static func readJobsData() throws -> Data {
        let domain = ClickyTaskLibrary.preferencesDomain as CFString
        CFPreferencesAppSynchronize(domain)
        if let data = CFPreferencesCopyAppValue(ClickyTaskLibrary.jobsKey as CFString, domain) as? Data { return data }
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(ClickyTaskLibrary.preferencesDomain).plist")
        guard FileManager.default.fileExists(atPath: plist.path) else { throw LoadError.noJobList }
        let dict: [String: Any]?
        do {
            dict = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
        } catch {
            throw LoadError.unreadablePreferences(error.localizedDescription)
        }
        guard let data = dict?[ClickyTaskLibrary.jobsKey] as? Data else { throw LoadError.noJobList }
        return data
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
