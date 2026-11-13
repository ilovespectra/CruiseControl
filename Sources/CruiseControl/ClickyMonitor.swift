import AppKit
import ApplicationServices
import Combine
import CruiseCore

@MainActor
final class ClickyMonitor: ObservableObject {
    struct LogLine: Identifiable {
        let id = UUID()
        let date: Date
        let text: String
    }

    @Published private(set) var clickyRunning = false
    @Published private(set) var axTrusted = AXIsProcessTrusted()
    @Published private(set) var screenTrusted = CGPreflightScreenCaptureAccess()
    @Published private(set) var stats = ActivityStats() {
        didSet { if stats != oldValue { saveStats() } }
    }
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var lastActionAt: Date?
    @Published private(set) var vscodeStatus = "Waiting for a VS Code request."
    @Published private(set) var vscodeFollowUpStatus = "Not yet checked."
    @Published var vscodeTaskStatuses: [String: String] = [:]
    @Published private(set) var vscodeModelStatus = "Not yet checked."
    @Published private(set) var pendingVSCodeAlerts: [VSCodePendingRequestNotice] = []
    @Published private(set) var drivingTaskName: String? {
        didSet { vscodeApprovalPermission.set(store.config.vscodeApprovalsActive && drivingTaskName == nil) }
    }
    @Published private(set) var preparingFinish = false
    @Published private(set) var taskCatalog = TaskCatalog()
    @Published private(set) var taskCatalogError: String?
    @Published private(set) var projectInferenceStatus = "Projects are inferred locally from conversation evidence."
    @Published private(set) var backgroundTaskStatus = TaskPlanning.deliveryHold
    @Published private(set) var bumpingTaskIDs: Set<String> = []
    @Published private(set) var autoBumpDeliveryHolds: [String: String] = [:]
    /// Per-task examine → draft → send state for every HeyClicky and VS Code task (see TaskEngineMonitor.swift).
    @Published var engine = TaskEngineCache()
    /// Exactly what the engine is doing right now and since when; nil when idle.
    @Published var engineActivity: (text: String, key: String?, since: Date)?
    @Published var heldMessages: [PendingMessage] = []
    var vscodeModelUsed = false
    var engineBusy = false
    var engineSendBusy = false
    var lastEnginePassAt = Date.distantPast
    var lastEngineIntegrityAt = Date.distantPast
    var enginePriorityKeys: [String] = []
    var engineLoaded = false
    private var queuedManualBumpIDs: Set<String> = []
    private var inferringProjects = false
    private var backgroundReviewBusy = false
    private var lastBackgroundReviewAt = Date.distantPast
    private let taskCatalogURL = ConfigStore.directory.appendingPathComponent("task-catalog.json")
    private var taskCatalogReadable = true
    private var taskCatalogRefreshing = false
    private var lastTaskCatalogRefreshAt = Date.distantPast

    /// Hides Cruise Control's own notch panel while synthetic mouse clicks happen.
    var setOverlayHidden: ((Bool) -> Void)?

    let store: ConfigStore
    private var timer: Timer?
    private var busy = false
    private let vscodeApprovalPermission = InputSynth.ActionPermission()
    private var cancellables: Set<AnyCancellable> = []

    private var consentAttempts = 0
    private var consentCounted = false
    private var lastConsentActionAt = Date.distantPast
    private var lastSystemDialogAt = Date.distantPast
    private var lastOCRAt = Date.distantPast
    private var lastOrphanLogAt = Date.distantPast

    private var gate: ReportGate
    private var nudgeLimiter: NudgeLimiter
    private var lastNeedsYouSkipLog: [String: Date] = [:]
    private var lastTaskNoticeDismissAt = Date.distantPast
    private let seenURL = ConfigStore.directory.appendingPathComponent("seen-reports.json")
    /// Rate-limit history survives restarts (launchd relaunches the app whenever it exits).
    private let budgetURL = ConfigStore.directory.appendingPathComponent("nudge-budget.json")
    private let statsURL = ConfigStore.directory.appendingPathComponent("activity-stats.json")
    private var loadingStats = false

    // HeyClicky self-update
    private let pendingURL = ConfigStore.directory.appendingPathComponent("pending-relaunch.json")
    private var pending: PendingRelaunch?
    private var latestRelease: AppcastRelease?
    private var lastAppcastCheck = Date.distantPast
    private var lastUpdatePressAt = Date.distantPast
    private var lastHoverProbeAt = Date.distantPast
    private var clickyQuitAt: Date?
    private var lastRelaunchAttemptAt = Date.distantPast
    private var lastTaskLabels: [String] = []
    private var updateHintAt = Date.distantPast
    private var autoContinueReportsEnabled = true

    // Quiet-conversation replies
    private var stall = StallTracker()
    private var lastStallProbeAt = Date.distantPast
    private var lastStallSkipLogAt = Date.distantPast

    // Accidental-interrupt recovery
    private var lastInterruptFingerprint = ""
    private var lastInterruptAt = Date.distantPast
    // "Interrupted" task cards (e.g. after the Mac restarted). distantPast = check on the first idle cycle after launch.
    private var lastInterruptedProbeAt = Date.distantPast
    private var lastNotchInspectionAt = Date.distantPast
    private var lastInterruptedBump: [String: Date] = [:]

    // VS Code tool confirmations and read-only pending-request notices
    private var vscodeBusy = false
    private var lastVSCodeCheckAt = Date.distantPast
    private var pendingVSCodeAlertScanBusy = false
    private var lastPendingVSCodeAlertScanAt = Date.distantPast
    private var pendingVSCodeAlertFirstSeen: [String: Date] = [:]
    private var pendingVSCodeAlertLastSeen: [String: Date] = [:]
    @Published private(set) var safetyHeldRequests: [SafetyHeldRequest] = []
    var safetyReviewInProgress = false

    func resolveSafetyHeldRequest(_ key: String) {
        safetyHeldRequests.removeAll { $0.id == key }
        safetyReviewInProgress = !safetyHeldRequests.isEmpty
    }

    private func holdForSafetyReview(_ pending: VSCodeConfirmation, reason: String) {
        guard !safetyHeldRequests.contains(where: { $0.id == pending.key }) else { return }
        safetyHeldRequests.append(SafetyHeldRequest(confirmation: pending, reason: reason))
    }

    private struct Review { let verdict: ApprovalReview.Verdict?; let at: Date }
    private var reviews: [String: Review] = [:]
    private var modelBusy = false
    private var lastModelCheckAt = Date.distantPast
    func lastModelCheckAtReset() { lastModelCheckAt = .distantPast }
    func lastDefinitionCheckAtReset() { lastDefinitionCheckAt = .distantPast }
    /// Last Sessions-row state seen when each opted-in chat was inspected; unchanged rows aren't re-read every tick.
    var vscodeInspectMarks: [String: (mark: String, at: Date)] = [:]
    /// Last Sessions-list read, so the engine tracks VS Code chats between scans.
    var vscodeSessionsSeen: [VSCodeVisibleSession] = []
    var vscodeDrafts: [String: VSCodeEngineDraft] = [:]
    /// Attention threads already opened without anything to approve; re-opened only when their row changes or after 5 minutes.
    private var attentionThreadMarks: [String: Date] = [:]
    private var fingerprintMemo: [String: (task: ClickyAgentTask, fingerprint: String)] = [:]
    private var modelStates: [String: ModelRouting.State] = [:]
    private let modelStateURL = ConfigStore.directory.appendingPathComponent("model-routing.json")
    var bumpStates: [String: ChatBump.State] = [:]
    private let bumpStateURL = ConfigStore.directory.appendingPathComponent("chat-bumps.json")
    private var approvalAttempts: [String: Date] = [:]
    private var writePolicyHolds: [String: Date] = [:]
    private var toolPolicyHolds: [String: Date] = [:]
    private var lastMainChatCheckAt = Date.distantPast
    private var tapOutAttempts: [String: Date] = [:]
    private var urlPolicyHolds: [String: Date] = [:]
    private var lastVSCodeThreadProbeAt = Date.distantPast
    private var usageScanBusy = false
    private var lastUsageScanAt = Date.distantPast
    private var lastTaskAuditAt = Date.distantPast
    private var lastDefinitionCheckAt = Date.distantPast
    private var definitionReviewBusy = false
    private var lastDefinitionReviewAt = Date.distantPast
    var definitionReviewFailures: [String: Date] = [:]
    private var taskAuditStates: [String: ChatBump.State] = [:]
    private let taskAuditURL = ConfigStore.directory.appendingPathComponent("clicky-task-audits.json")
    var taskRecovery = TaskRecovery()
    private var recoveryHistoryReadable = true
    let taskRecoveryURL = ConfigStore.directory.appendingPathComponent("stopped-tasks.json")
    private let pendingMessageURL = ConfigStore.directory.appendingPathComponent("pending-message.json")
    @Published private(set) var pendingMessage: PendingMessage?
    private var messageHistoryReadable = true
    private var lastMessageRetryAt = Date.distantPast
    private var pendingHeldLogged = false

    private struct Budget: Codable {
        var continueTimes: [Date]
        var perTask: NudgeLimiter
    }
    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CruiseControl.log")

    init(store: ConfigStore) {
        self.store = store
        self.autoContinueReportsEnabled = store.config.autoContinueReports
        let seen = (try? Data(contentsOf: seenURL)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let budget = (try? Data(contentsOf: budgetURL)).flatMap { try? JSONDecoder().decode(Budget.self, from: $0) }
        gate = ReportGate(known: Set(seen), continueTimes: budget?.continueTimes ?? [])
        nudgeLimiter = budget?.perTask ?? NudgeLimiter()
        pending = (try? Data(contentsOf: pendingURL)).flatMap { try? JSONDecoder().decode(PendingRelaunch.self, from: $0) }
        if FileManager.default.fileExists(atPath: statsURL.path) {
            loadingStats = true
            do {
                stats = try JSONDecoder().decode(ActivityStats.self, from: Data(contentsOf: statsURL))
            } catch {
                record("couldn't load activity statistics: \(error.localizedDescription)")
            }
            loadingStats = false
        }
        saveStats()
        if FileManager.default.fileExists(atPath: taskCatalogURL.path) {
            do {
                taskCatalog = try JSONDecoder().decode(TaskCatalog.self, from: Data(contentsOf: taskCatalogURL))
            } catch {
                taskCatalogReadable = false
                let message = "Couldn't load the saved task catalog: \(error.localizedDescription). The file will not be overwritten."
                taskCatalogError = message
                record(message)
            }
        }
        if FileManager.default.fileExists(atPath: pendingMessageURL.path) {
            do {
                pendingMessage = try JSONDecoder().decode(PendingMessage.self, from: Data(contentsOf: pendingMessageURL))
            } catch {
                messageHistoryReadable = false
                record("couldn't load pending HeyClicky message: \(error.localizedDescription) — automatic messages disabled")
            }
        }
        if FileManager.default.fileExists(atPath: taskRecoveryURL.path) {
            do {
                taskRecovery = try JSONDecoder().decode(TaskRecovery.self, from: Data(contentsOf: taskRecoveryURL))
            } catch {
                recoveryHistoryReadable = false
                record("couldn't load stopped-task history: \(error.localizedDescription) — automatic HeyClicky recovery disabled")
            }
        }
        if FileManager.default.fileExists(atPath: taskAuditURL.path) {
            do {
                taskAuditStates = try JSONDecoder().decode([String: ChatBump.State].self, from: Data(contentsOf: taskAuditURL))
            } catch {
                record("couldn't load HeyClicky task-audit history: \(error.localizedDescription)")
            }
        }
        if FileManager.default.fileExists(atPath: modelStateURL.path) {
            do {
                modelStates = try JSONDecoder().decode([String: ModelRouting.State].self, from: Data(contentsOf: modelStateURL))
            } catch {
                record("couldn't load model-routing history: \(error.localizedDescription)")
            }
            if FileManager.default.fileExists(atPath: bumpStateURL.path) {
                do {
                    bumpStates = try JSONDecoder().decode([String: ChatBump.State].self, from: Data(contentsOf: bumpStateURL))
                } catch {
                    record("couldn't load chat follow-up history: \(error.localizedDescription)")
                }
            }
        }

        store.$config
            .sink { [weak self] config in
                guard let self else { return }
                self.vscodeApprovalPermission.set(config.vscodeApprovalsActive && self.drivingTaskName == nil)
            }
            .store(in: &cancellables)

        store.$config
            .map(\.pollInterval)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.restartTimer() } }
            .store(in: &cancellables)

        store.$config
            .map(\.mode)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] mode in Task { @MainActor in self?.record("mode → \(mode.title)") } }
            .store(in: &cancellables)

        store.$config
            .map { config in
                "\(config.vscodeDefinitionsOfDone)|\(config.vscodeAutoBumpChatKeys)|\(config.vscodeTaskPlans)|\(config.vscodeTaskProjects)|\(config.continueUntilDefinedDone)|\(config.mode)|\(config.ollamaEnabled)"
            }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.lastModelCheckAt = .distantPast
                    self.tickModelRouting()
                }
            }
            .store(in: &cancellables)

            store.$config
                .map { "\($0.clickyDefinitionsOfDone)|\($0.continueUntilDefinedDone)" }
                .removeDuplicates()
                .dropFirst()
                .sink { [weak self] _ in
                    Task { @MainActor in self?.lastDefinitionCheckAt = .distantPast }
                }
                .store(in: &cancellables)
    }

    var logFileURL: URL { logURL }

    func refreshTaskCatalog() async {
        guard !taskCatalogRefreshing else { return }
        taskCatalogRefreshing = true
        lastTaskCatalogRefreshAt = Date()
        defer { taskCatalogRefreshing = false }
        let source = ClickyTaskStore.shared
        let previousTasks = Dictionary(source.tasks.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        await source.refresh(measure: false)
        if let error = source.loadError {
            taskCatalogError = error
            return
        }
        guard source.loadedAt != nil else { return }
        updateTaskCatalog(source.tasks)
        if !previousTasks.isEmpty {
            let changedTasks = source.tasks.filter { task in
                !task.dismissed && task.hasReport && previousTasks[task.id]?.fingerprint != task.fingerprint
            }
            for task in changedTasks {
                guard store.config.ollamaEnabled, Ollama.isLocalServer(store.config),
                      let latest = source.task(task.id), latest.fingerprint == task.fingerprint,
                      source.currentAssessment(for: latest, definition: store.config.clickyDefinitionsOfDone[task.id]) == nil,
                      !source.assessing.contains(task.id) else { continue }
                let reviewConfig = store.config
                let assessment = await source.assess(latest, config: reviewConfig, localOnly: true)
                guard source.task(task.id)?.fingerprint == task.fingerprint else {
                    record("task state changed again while reviewing “\(task.name)” — the next refresh will review the newer report")
                    continue
                }
                record("task state changed for “\(task.name)” — Ollama reviewed the latest HeyClicky report (\(assessment.state.title.lowercased()))")
            }
        }
        if !inferringProjects {
            Task { await inferTaskProjects() }
        }
    }

    func inferTaskProjects() async {
        guard !inferringProjects, store.config.inferTaskProjects, store.config.ollamaEnabled, taskCatalogReadable else { return }
        inferringProjects = true
        defer { inferringProjects = false }
        let source = ClickyTaskStore.shared
        let saved = Dictionary(taskCatalog.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = source.tasks.filter { task in
            guard let saved = saved[task.id] else { return false }
            return !saved.projectAssigned
                && (saved.inferredBy == nil || saved.inferenceFingerprint != cachedFingerprint(for: task))
        }
        for (index, task) in candidates.enumerated() {
            guard store.config.inferTaskProjects, store.config.ollamaEnabled else { break }
            projectInferenceStatus = "Reviewing task projects locally: \(index + 1) / \(candidates.count)…"
            let known = taskCatalog.groups(by: .project, sort: .name).filter { $0.id != "unassigned" }.map(\.project)
            do {
                let (project, model, _) = try await Ollama.inferProject(task, known: known, config: store.config)
                guard store.config.inferTaskProjects, store.config.ollamaEnabled,
                      let latest = source.task(task.id),
                      ProjectInference.fingerprint(for: latest) == ProjectInference.fingerprint(for: task) else { continue }
                var catalog = taskCatalog
                catalog.infer(project, for: task.id, fingerprint: ProjectInference.fingerprint(for: task), model: model)
                saveTaskCatalog(catalog)
                if taskCatalogError != nil { return }
            } catch {
                projectInferenceStatus = "Project review paused: \(error.localizedDescription). Existing assignments are unchanged; uncertain tasks remain unspecified."
                record(projectInferenceStatus)
                return
            }
        }
        projectInferenceStatus = "Project review complete. Only high-confidence, evidence-backed matches are grouped; other tasks remain unspecified."
    }

    /// Fingerprinting hashes tens of KB of evidence; only recompute when the task actually changed.
    private func cachedFingerprint(for task: ClickyAgentTask) -> String {
        if let hit = fingerprintMemo[task.id], hit.task == task { return hit.fingerprint }
        let fingerprint = ProjectInference.fingerprint(for: task)
        fingerprintMemo[task.id] = (task, fingerprint)
        return fingerprint
    }

    func resetProject(for task: String) {
        var catalog = taskCatalog
        catalog.resetProject(for: task)
        saveTaskCatalog(catalog)
        Task { await inferTaskProjects() }
    }

    private func reviewBackgroundTasks() async {
        guard !backgroundReviewBusy, store.config.backgroundTaskReview else { return }
        backgroundReviewBusy = true
        lastBackgroundReviewAt = Date()
        defer { backgroundReviewBusy = false }
        let source = ClickyTaskStore.shared
        guard source.canPersist else {
            backgroundTaskStatus = source.persistenceError ?? "Background review paused: saved task state is unreadable."
            return
        }
        let requested = Date()
        await source.refresh()
        guard source.loadError == nil, let loaded = source.loadedAt, loaded >= requested else {
            backgroundTaskStatus = source.loadError ?? "Background review is waiting for a fresh local task read."
            return
        }
        guard store.config.ollamaEnabled, Ollama.isLocalServer(store.config) else {
            backgroundTaskStatus = "Background review paused: enable a local Ollama server."
            return
        }
        // Review only saves drafts. Chat-only delivery is separately opted in and serialized by cycle().
        let candidates = TaskPlanning.ranked(source.tasks, catalog: taskCatalog, config: store.config).filter { task in
            if let assessment = source.currentAssessment(for: task, definition: store.config.clickyDefinitionsOfDone[task.id]),
               assessment.source.hasPrefix("ollama"),
               assessment.meetsDefinition != false || assessment.state == .unknown { return false }
            let reply = source.record(task.id).backgroundReply
            return reply?.fingerprint != task.fingerprint
                || reply?.definition != DefinitionOfDone.normalized(store.config.clickyDefinitionsOfDone[task.id])
        }
        for task in candidates.prefix(3) {
            let config = store.config
            guard let definition = DefinitionOfDone.normalized(config.clickyDefinitionsOfDone[task.id]) else { continue }
            if let reply = source.record(task.id).backgroundReply,
               reply.fingerprint == task.fingerprint, reply.definition == definition { continue }
            backgroundTaskStatus = "Reviewing “\(task.name)” with local Ollama…"
            let assessment = await source.assess(task, config: config, localOnly: true)
            guard assessment.source.hasPrefix("ollama") else {
                backgroundTaskStatus = "Background review paused for “\(task.name)”: \(assessment.reason)"
                record(backgroundTaskStatus)
                return
            }
            let recheck = Date()
            await source.refresh()
            guard source.loadError == nil, let read = source.loadedAt, read >= recheck,
                  let latest = source.task(task.id), latest.fingerprint == task.fingerprint,
                  TaskPlanning.eligible(latest, config: store.config),
                  DefinitionOfDone.normalized(store.config.clickyDefinitionsOfDone[task.id]) == definition else { continue }
            guard assessment.state != .unknown,
                  DefinitionOfDone.shouldContinue(task, definition: definition, assessment: assessment,
                                                  progress: source.record(task.id).progress,
                                                  maxRounds: config.maxDefinitionRounds),
                  !TaskAudit.requiresUser(definition + "\n" + assessment.missing.joined(separator: "\n")) else { continue }
            guard TaskWorkflow.messageBlocker(
                project: taskCatalog.tasks.first(where: { $0.id == task.id && $0.projectAssigned })?.project ?? TaskProject(),
                plan: store.config.taskPlans[task.id] ?? TaskPlan()) == nil else { continue }
            let text = DefinitionOfDone.followUp(task: task, definition: definition, missing: assessment.missing,
                                                 round: source.rounds(for: task, definition: definition) + 1,
                                                 maxRounds: config.maxDefinitionRounds)
                + "\nWork only without screen control. Do not approve permissions, tool grants or drive requests. If blocked by one, stop and report the blocker."
            guard source.saveBackgroundReply(text, for: task, definition: definition) else {
                backgroundTaskStatus = source.loadError ?? "Couldn't save the background reply; nothing sent."
                return
            }
        }
        backgroundTaskStatus = store.config.backgroundTaskDelivery == .chatOnly ? TaskPlanning.chatOnlyStatus : TaskPlanning.deliveryHold
    }

    private func deliverBackgroundReply(config: Config) async -> Bool {
        guard config.backgroundTaskReview, config.backgroundTaskDelivery == .chatOnly,
              !backgroundReviewBusy, pendingMessage == nil, messageHistoryReadable,
              Self.idleSeconds() >= config.awayIdleSeconds else { return false }
        let source = ClickyTaskStore.shared
        let requested = Date()
        await source.refresh()
        guard source.canPersist, source.loadError == nil, let read = source.loadedAt, read >= requested else { return false }
        let ambiguous = ClickyTaskLibrary.ambiguousNames(source.tasks)
        let candidate = TaskPlanning.ranked(source.tasks, catalog: taskCatalog, config: store.config).first { task in
            guard !ambiguous.contains(Matcher.normalize(task.name)),
                  !taskRecovery.isStopped(task: task.name),
                  let reply = source.record(task.id).backgroundReply else { return false }
            let progress = source.record(task.id).progress
            return reply.deliveredAt == nil && reply.fingerprint == task.fingerprint
                && reply.definition == DefinitionOfDone.normalized(store.config.clickyDefinitionsOfDone[task.id])
                && source.rounds(for: task, definition: reply.definition) < config.maxDefinitionRounds
                && !(progress.lastFingerprint == task.fingerprint
                     && DefinitionOfDone.normalized(progress.definition) == reply.definition)
        }
        guard let task = candidate, let reply = source.record(task.id).backgroundReply else { return false }
        guard store.config.backgroundTaskDelivery == .chatOnly,
              TaskPlanning.eligible(task, config: store.config),
              Self.idleSeconds() >= store.config.awayIdleSeconds else { return false }
        let interaction = InputSynth.UserInteractionWatch()
        defer { interaction.stop() }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let original = await Worker.run { ClickyScanner(config: config).scan() }
        if let composer = original.composer {
            guard await Worker.run({ AX.stringValue(composer.input) == "" }) else {
                backgroundTaskStatus = "Chat-only delivery is waiting: HeyClicky already contains a draft."
                return false
            }
        }
        guard let chat = await revealChat(config: config), !interaction.interrupted,
              let selected = await selectTask(task.name, from: chat, config: config, unique: true),
              let composer = selected.composer else { return true }
        let recheck = Date()
        await source.refresh()
        guard !interaction.interrupted, source.loadError == nil,
              let refreshed = source.loadedAt, refreshed >= recheck,
              let latest = source.task(task.id), latest.fingerprint == reply.fingerprint,
              TaskPlanning.eligible(latest, config: store.config),
              store.config.backgroundTaskDelivery == .chatOnly,
              !ClickyTaskLibrary.ambiguousNames(source.tasks).contains(Matcher.normalize(task.name)),
              DefinitionOfDone.normalized(store.config.clickyDefinitionsOfDone[task.id]) == reply.definition else {
            record("chat-only delivery paused: task, goal, opt-in or input changed while opening the chat")
            return true
        }
        let previousProgress = source.record(task.id).progress
        guard source.recordFollowUp(latest, definition: reply.definition) else {
            backgroundTaskStatus = source.loadError ?? "Couldn't reserve a durable chat-only follow-up round."
            return true
        }
        let project = taskCatalog.tasks.first { $0.id == task.id && $0.projectAssigned }?.project ?? TaskProject()
        let plan = store.config.taskPlans[task.id] ?? TaskPlan()
        let message = TaskWorkflow.taskBumpMessage(
            baseMessage: reply.text, taskName: task.name, definition: reply.definition, project: project, plan: plan,
            clickyCacheLocations: task.threadIDs.flatMap { ClickyTaskLibrary.cachePaths(threadIDs: [$0]).map(\.path) })
        let target = PendingMessage.CompletionTarget(taskID: task.id, definition: reply.definition, reportFingerprint: reply.fingerprint,
                                                     workflowKey: currentWorkflowKey(task.id), workspace: confirmedTaskWorkspace(task.id))
        let delivered = await send(message, via: composer, task: task.name, completionTarget: target, chatOnly: true)
        if delivered {
            stats.continued += 1
            backgroundTaskStatus = "Chat-only reply confirmed in “\(task.name)”."
            record(backgroundTaskStatus)
        } else if pendingMessage == nil {
            if !source.restoreProgress(previousProgress, for: task.id) {
                record("chat-only round rollback failed: \(source.loadError ?? "saved state is unreadable")")
            }
            backgroundTaskStatus = "Chat-only reply was not sent; draft remains saved."
        } else {
            backgroundTaskStatus = "Chat-only reply saved for delivery verification or retry."
        }
        if pendingMessage == nil, !interaction.interrupted {
            previousApp?.activate()
        }
        return true
    }

    private func waitForCurrentTaskAction(_ interaction: InputSynth.UserInteractionWatch, action: String) async -> String? {
        let deadline = Date().addingTimeInterval(20)
        while busy, Date() < deadline, !interaction.interrupted, !Task.isCancelled, store.config.mode != .rest {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if interaction.interrupted || Task.isCancelled {
            return "\(action) cancelled by user input or cancellation. No new task action was started."
        }
        if store.config.mode == .rest { return "\(action) paused: Cruise entered Rest mode. No new task action was started." }
        if busy { return "\(action) paused: the previous Cruise action is still running. Retry when it finishes." }
        return nil
    }

    /// Sends the exact visible, user-approved draft to its unique task after refreshing and rechecking evidence.
    /// Returns nil only after HeyClicky's transcript confirms delivery; otherwise returns a truthful blocked/pending status.
    func sendReviewedTaskDraft(taskID: String, text: String, definition: String,
                               reportFingerprint: String, missing: [String]) async -> String? {
        let source = ClickyTaskStore.shared
        guard drivingTaskName == nil else { return "Send paused: another explicit task action is already running." }
        let interaction = InputSynth.UserInteractionWatch()
        drivingTaskName = "Waiting to send to \(source.task(taskID)?.name ?? "selected task")"
        defer {
            drivingTaskName = nil
            interaction.stop()
        }
        if let problem = await waitForCurrentTaskAction(interaction, action: "Send") { return problem }
        let config = store.config
        busy = true
        defer { busy = false }
        drivingTaskName = "Sending to \(source.task(taskID)?.name ?? "selected task")"
        if let reason = TaskWorkflow.messageBlocker(
            project: taskCatalog.tasks.first(where: { $0.id == taskID && $0.projectAssigned })?.project ?? TaskProject(),
            plan: config.taskPlans[taskID] ?? TaskPlan()) {
            return "Send blocked: \(reason)"
        }
        guard TaskPlanning.definitionDeliveryAllowed(config: config, oneShot: true) else {
            return "Send blocked: leave Rest mode and enable local Ollama; check the usage cutoff."
        }
        guard messageHistoryReadable, pendingMessage == nil, source.canPersist else {
            return "Send blocked: a saved delivery is pending or task history cannot be safely updated."
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 8_000 else {
            return "Send blocked: the draft is empty or exceeds the safe message length."
        }
        let requestedAt = Date()
        await source.refresh(measure: false)
        guard let loadedAt = source.loadedAt, loadedAt >= requestedAt, source.loadError == nil,
              let task = source.task(taskID), task.fingerprint == reportFingerprint,
              DefinitionOfDone.normalized(store.config.clickyDefinitionsOfDone[taskID]) == DefinitionOfDone.normalized(definition),
              !task.isWorking, !stopHeld(task), !task.dismissed, task.hasReport,
              !TaskAudit.requiresUser(task.lastMessage),
              !ClickyTaskLibrary.ambiguousNames(source.tasks).contains(Matcher.normalize(task.name)),
              !taskRecovery.isStopped(task: task.name),
              let assessment = engineAssessment(task, definition: definition),
              assessment.meetsDefinition == false, !assessment.missing.isEmpty,
              assessment.missing == missing, [.unfinished, .failed].contains(assessment.state) else {
            return "Send blocked: the task, report, criteria, review, or user-decision status changed. Review again."
        }
        let maxRounds = min(max(1, config.maxDefinitionRounds), DefinitionOfDone.maxRounds)
        let previousProgress = source.record(taskID).progress
        let rounds = source.rounds(for: task, definition: definition)
        guard rounds < maxRounds, !DefinitionOfDone.hasNoProgress(assessment, progress: previousProgress),
              previousProgress.lastFingerprint != task.fingerprint else {
            return "Send blocked: this report was already followed up, its gaps repeated, or the round limit was reached."
        }
        guard source.recordFollowUp(task, definition: definition, missing: missing) else {
            return "Send blocked: Cruise couldn't safely save the follow-up receipt before delivery."
        }
        let target = PendingMessage.CompletionTarget(taskID: taskID, definition: definition,
                                                     reportFingerprint: reportFingerprint, oneShot: true,
                                                     workflowKey: currentWorkflowKey(taskID), workspace: confirmedTaskWorkspace(taskID))
        guard let chat = await revealChat(config: config),
              let selected = await selectTask(task.name, from: chat, config: config, unique: true),
              let composer = selected.composer, recoveryAllowed(selected),
              ![selected.selectedStatus, selected.latestTurnStatus].compactMap({ $0 }).contains(where: StallTracker.isBusy) else {
            _ = source.restoreProgress(previousProgress, for: taskID)
            return "Send blocked: HeyClicky couldn't verify the exact task and an idle composer. Nothing was sent."
        }
        let finalRead = Date()
        await source.refresh(measure: false)
        guard let finalLoadedAt = source.loadedAt, finalLoadedAt >= finalRead, source.loadError == nil,
              let latest = source.task(taskID), latest.fingerprint == reportFingerprint,
              DefinitionOfDone.normalized(store.config.clickyDefinitionsOfDone[taskID]) == DefinitionOfDone.normalized(definition),
              !latest.isWorking, !stopHeld(latest), !latest.dismissed,
              !TaskAudit.requiresUser(latest.lastMessage),
              !ClickyTaskLibrary.ambiguousNames(source.tasks).contains(Matcher.normalize(latest.name)),
              completionTargetMatches(target),
              source.currentAssessment(for: latest, definition: definition) == assessment else {
            _ = source.restoreProgress(previousProgress, for: taskID)
            return "Send blocked: the task changed while HeyClicky was being opened. Nothing was sent."
        }
        guard await Worker.run({ AX.stringValue(composer.input) == "" }) else {
            _ = source.restoreProgress(previousProgress, for: taskID)
            return "Send blocked: the HeyClicky composer already contains a draft; it was left untouched."
        }
        let confirmed = await send(text, via: composer, task: task.name, completionTarget: target)
        if confirmed {
            stats.continued += 1
            record("user-approved reviewed follow-up confirmed in ‘\(task.name)’")
            return nil
        }
        if let pendingMessage, pendingMessage.completionTarget?.taskID == taskID, pendingMessage.text == text {
            return pendingMessage.holdReason ?? "Saved for a bounded retry; delivery is not yet confirmed."
        }
        _ = source.restoreProgress(previousProgress, for: taskID)
        return "Send not confirmed. The draft was not reported as sent; review the HeyClicky task before retrying."
    }

    func closeHeyClickyTask(taskID: String) async -> String? {
        let started = ProcessInfo.processInfo.systemUptime
        record("Finish requested for HeyClicky job [\(taskID)]")
        let result = await performCloseHeyClickyTask(taskID: taskID)
        let seconds = String(format: "%.2f", ProcessInfo.processInfo.systemUptime - started)
        record(result.map { "Finish [\(taskID)] after \(seconds)s: \($0)" }
               ?? "Finish [\(taskID)] completed in \(seconds)s; history and files preserved")
        return result
    }

    private func performCloseHeyClickyTask(taskID: String) async -> String? {
        let config = store.config
        let source = ClickyTaskStore.shared
        guard axTrusted else { return "Finish blocked: grant Cruise Control Accessibility access before retrying." }
        guard config.mode != .rest else { return "Finish paused: leave Rest mode before retrying." }
        guard drivingTaskName == nil else { return "Finish paused: another task's finish action is already running." }
        preparingFinish = true
        let interaction = InputSynth.UserInteractionWatch()
        var returnInteraction: InputSynth.UserInteractionWatch?
        let previousApp = NSWorkspace.shared.frontmostApplication
        drivingTaskName = "Waiting to finish \(source.task(taskID)?.name ?? "selected task")"
        defer {
            drivingTaskName = nil
            preparingFinish = false
            interaction.stop()
            returnInteraction?.stop()
        }
        let waitStarted = ProcessInfo.processInfo.systemUptime
        if let problem = await waitForCurrentTaskAction(interaction, action: "Finish") { return problem }
        record("Finish [\(taskID)] action slot ready after \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - waitStarted))s")
        guard pendingMessage?.completionTarget?.taskID != taskID else {
            return "Close blocked: resolve this task's saved delivery before dismissing it."
        }
        busy = true
        defer { busy = false }
        let currentTasks: [ClickyAgentTask]
        do {
            currentTasks = try await Task.detached(priority: .userInitiated) {
                try ClickyTaskLibrary.tasks(
                    jobs: ClickyTaskLibrary.decodeJobs(ClickyTaskStore.readJobsData()), activity: [:])
            }.value
        } catch {
            return "Close blocked: couldn't read the current HeyClicky jobs: \(error.localizedDescription). Nothing was clicked."
        }
        if let blocker = TaskPlanning.finishBlocker(taskID: taskID, tasks: currentTasks) { return blocker }
        guard let task = currentTasks.first(where: { $0.id == taskID }) else {
            return "Close blocked: this HeyClicky job is unavailable."
        }
        guard !interaction.interrupted, !Task.isCancelled, store.config.mode != .rest else {
            return "Finish cancelled during task verification. Nothing was clicked."
        }
        var stopped = taskRecovery
        stopped.stopByUser(task: task.name)
        do {
            try JSONEncoder().encode(stopped).write(to: taskRecoveryURL, options: .atomic)
        } catch {
            record("Finish paused: couldn't save the user's stop for ‘\(task.name)’: \(error.localizedDescription)")
            return "Finish paused: couldn't persist the stop before closing. Nothing was clicked."
        }
        taskRecovery = stopped
        queuedManualBumpIDs.remove(taskID)
        bumpingTaskIDs.remove(taskID)
        store.config.taskPlans[taskID, default: TaskPlan()].autoBump = false
        drivingTaskName = task.name
        var dismissalVerified = task.dismissed
        defer {
            if dismissalVerified {
                let active = NSWorkspace.shared.frontmostApplication
                let stillInWorkflow = active?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                    || active?.bundleIdentifier.map(config.clickyBundleIDs.contains) == true
                if !(returnInteraction ?? interaction).interrupted, stillInWorkflow {
                    record("Finish [\(taskID)] returning to the existing Cruise Tasks view")
                    NotificationCenter.default.post(name: SettingsController.openTasksNotification, object: nil)
                } else {
                    record("Finish [\(taskID)] return to Cruise skipped: user input or another app took over")
                }
            } else if !interaction.interrupted {
                previousApp?.activate()
            }
        }
        if task.dismissed {
            let scan = await Worker.run { ClickyScanner(config: config).scan() }
            guard await dismissTaskNotices(task.name, from: scan, config: config, interaction: interaction) else {
                return "Task already dismissed; its notification could not be safely closed. Nothing was retried."
            }
            return nil
        }
        drivingTaskName = "Opening HeyClicky to finish \(task.name)"
        preparingFinish = false
        record("Finish [\(taskID)] preflight passed; opening HeyClicky chat")
        guard let runningApp = config.clickyBundleIDs.lazy.compactMap({
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first { !$0.isTerminated }
        }).first, runningApp.activate() else {
            return "Finish paused: HeyClicky is not running or could not be activated. Open HeyClicky and retry."
        }
        guard var chat = await revealChat(config: config, requireSidebar: true), !interaction.interrupted,
              let app = NSRunningApplication(processIdentifier: chat.pid), app.activate() else {
            return "Finish paused: HeyClicky's expanded chat could not be opened, or input interrupted the drive."
        }
        if let window = chat.chatWindow {
            let minimized: Bool = await Worker.run { AX.attr(window, kAXMinimizedAttribute) ?? false }
            if minimized {
                let restored = await Worker.run {
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
                }
                guard restored else { return "Finish paused: HeyClicky's chat window could not be restored." }
            }
            _ = await Worker.run { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
        }
        if let sidebar = chat.showSidebar {
            guard await Worker.run({ AX.press(sidebar) }) else { return "Finish paused: HeyClicky's task sidebar could not be expanded." }
        }
        if chat.showSidebar != nil {
            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !interaction.interrupted, !Task.isCancelled else {
                    return "Finish cancelled while expanding the sidebar. No X was clicked."
                }
                chat = await Worker.run { ClickyScanner(config: config).scan() }
                if chat.showSidebar == nil { break }
            }
            guard chat.showSidebar == nil else {
                return "Finish paused: HeyClicky's sidebar did not expand. No scrolling or X click was attempted."
            }
        }
        guard await dismissTaskNotices(task.name, from: chat, config: config, interaction: interaction) else {
            return "Finish paused: the task's notification could not be safely closed. Nothing was retried."
        }
        if !chat.taskNotices.isEmpty {
            chat = await Worker.run { ClickyScanner(config: config).scan() }
        }
        guard let exact = await selectTask(task.name, from: chat, config: config, unique: true),
              exact.selectedTask == task.name, !interaction.interrupted else {
            return "Finish paused: the exact task could not be opened and verified. No task was closed."
        }
        chat = exact
        let initialRows = chat.chatButtons.filter { Matcher.isTaskRow($0.label, title: task.name) }
        guard initialRows.count == 1, let initialRow = initialRows.first,
              let sidebar = await Worker.run({ AX.scrollArea(containing: initialRow.element) }),
              !interaction.interrupted else {
            return "Close blocked: Cruise couldn't verify the exact HeyClicky sidebar task or user input interrupted it."
        }
        drivingTaskName = "Revealing \(task.name) in the sidebar"
        var visible = await Worker.run { ClickyScanner(config: config).scanSidebar(sidebar) }
        guard visible.isTaskSidebar else {
            return "Finish blocked: the row's scroll area is not a composer-free task sidebar. No scrolling or X click was attempted."
        }
        var revealed = false
        for _ in 0..<30 {
            guard !interaction.interrupted, !Task.isCancelled, store.config.mode != .rest else {
                return "Finish cancelled while revealing the sidebar task. No X was clicked."
            }
            let candidates = visible.chatButtons.filter { Matcher.isTaskRow($0.label, title: task.name) }
            guard candidates.count == 1, let candidate = candidates.first else { break }
            let result = await Worker.run {
                AX.revealInScrollArea(candidate.element, in: sidebar, shouldContinue: { !interaction.interrupted })
            }
            if result == .visible {
                revealed = true
                break
            }
            if result == .unavailable { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
            visible = await Worker.run { ClickyScanner(config: config).scanSidebar(sidebar) }
            guard visible.isTaskSidebar else { break }
        }
        guard revealed else { return "Finish paused: the exact sidebar task could not be scrolled into view. No X was clicked." }
        record("Finish [\(taskID)] sidebar target visible")
        drivingTaskName = task.name
        let rows = visible.chatButtons.filter {
            Matcher.normalize($0.label) == Matcher.normalize(task.name) || Matcher.isTaskRow($0.label, title: task.name)
        }
        guard rows.count == 1, let row = rows.first,
              let frame = await Worker.run({ AX.frame(row.element) }), frame.width > 0, frame.height > 0 else {
            return "Close blocked: the exact sidebar card is not uniquely visible. Bring it into view and retry."
        }
        var pressed = false
        await withOverlayHidden {
            pressed = await Worker.run {
                let original = CGEvent(source: nil)?.location
                defer { if let original, !interaction.interrupted { InputSynth.move(to: original) } }
                let hoverPoint = CGPoint(x: frame.midX, y: frame.midY)
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == chat.pid,
                      AX.isUnderPointer(row.element, at: hoverPoint), !interaction.interrupted else { return false }
                InputSynth.move(to: hoverPoint)
                usleep(400_000)
                guard let cursor = CGEvent(source: nil)?.location,
                      abs(cursor.x - hoverPoint.x) < 2, abs(cursor.y - hoverPoint.y) < 2 else { return false }
                let fresh = ClickyScanner(config: config).scanSidebar(sidebar)
                guard fresh.isTaskSidebar else { return false }
                let freshRows = fresh.chatButtons.filter { Matcher.isTaskRow($0.label, title: task.name) }
                guard freshRows.count == 1, let freshRow = freshRows.first,
                      AX.frame(freshRow.element) == frame else { return false }
                let controls = fresh.dismissButtons.compactMap { element -> (AXUIElement, CGRect)? in
                    guard AX.isEnabled(element), let rect = AX.frame(element), frame.contains(rect),
                          rect.width < frame.width / 2 else { return nil }
                    return (element, rect)
                }
                guard controls.count == 1, let control = controls.first, !interaction.interrupted else { return false }
                let point = CGPoint(x: control.1.midX, y: control.1.midY)
                guard AX.isUnderPointer(control.0, at: point), !interaction.interrupted else { return false }
                return InputSynth.click(at: point, restoreCursor: false, shouldContinue: {
                    !interaction.interrupted && AX.isUnderPointer(control.0, at: point)
                })
            }
        }
        guard pressed else { return "Close blocked: HeyClicky did not expose this task's own X. No notice was sent and no local-only state was changed." }
        returnInteraction = InputSynth.UserInteractionWatch(includeMouseMovement: false)
        record("Finish [\(taskID)] exact sidebar X clicked; verifying dismissal")
        queuedManualBumpIDs.remove(taskID)
        bumpingTaskIDs.remove(taskID)
        store.config.taskPlans[taskID, default: TaskPlan()].autoBump = false
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            let readAt = Date()
            await source.refresh()
            let scan = await Worker.run { ClickyScanner(config: config).scan() }
            if source.loadedAt.map({ $0 >= readAt }) == true, source.loadError == nil,
               source.task(taskID)?.dismissed == true,
               !scan.chatButtons.contains(where: { Matcher.normalize($0.label) == Matcher.normalize(task.name) || Matcher.isTaskRow($0.label, title: task.name) }) {
                dismissalVerified = true
                guard await dismissTaskNotices(task.name, from: scan, config: config, interaction: interaction) else {
                    return "Task dismissed and Auto-bump stopped, but its notification could not be closed. Nothing was retried."
                }
                record("user-confirmed X dismissal verified for ‘\(task.name)’ [\(taskID)]; history and all storage preserved")
                return nil
            }
        }
        return "X was activated, but dismissal is not confirmed. Auto-bump is off; inspect HeyClicky before retrying."
    }

    private func dismissTaskNotices(_ task: String, from scan: ScanResult, config: Config,
                                    interaction: InputSynth.UserInteractionWatch) async -> Bool {
        let matches = scan.taskNotices.filter { Matcher.normalize($0.task) == Matcher.normalize(task) }
        guard matches.count == scan.taskNoticeNames.filter({ Matcher.normalize($0) == Matcher.normalize(task) }).count else {
            return false
        }
        if matches.isEmpty { return true }
        for notice in matches {
            guard !interaction.interrupted, !Task.isCancelled,
                  await Worker.run({ AX.press(notice.close) }) else { return false }
        }
        guard !interaction.interrupted, !Task.isCancelled else { return false }
        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !interaction.interrupted, !Task.isCancelled else { return false }
            let fresh = await Worker.run { ClickyScanner(config: config).scan() }
            if !fresh.taskNoticeNames.contains(where: { Matcher.normalize($0) == Matcher.normalize(task) }) { return true }
        }
        return false
    }

    /// Shows the exact HeyClicky task thread to the user without waiting on a separate review pass.
    func showTaskInHeyClicky(_ taskID: String) async -> String? {
        let source = ClickyTaskStore.shared
        guard let task = source.task(taskID) else {
            return "This task is no longer present in the current HeyClicky list. Refresh and try again."
        }
        guard !ClickyTaskLibrary.ambiguousNames(source.tasks).contains(Matcher.normalize(task.name)) else {
            return "This HeyClicky task has a duplicate name; resolve the ambiguity before opening the thread."
        }
        guard drivingTaskName == nil else {
            return "Cruise is already focused on another HeyClicky task. Try again when that action finishes."
        }
        let interaction = InputSynth.UserInteractionWatch()
        defer {
            interaction.stop()
            drivingTaskName = nil
        }
        drivingTaskName = "Opening \(task.name) in HeyClicky"
        guard var chat = await revealChat(config: store.config, requireSidebar: true),
              chat.chatWindow != nil, !interaction.interrupted else {
            return "HeyClicky’s expanded chat window did not open; no other chat was selected."
        }
        if let sidebar = chat.showSidebar {
            guard await Worker.run({ AX.press(sidebar) }) else {
                return "HeyClicky’s expanded chat opened, but its task sidebar could not be expanded."
            }
            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !interaction.interrupted else { return "Opening the task was interrupted; no fallback chat was selected." }
                chat = await Worker.run { ClickyScanner(config: self.store.config).scan() }
                if chat.chatWindow != nil && chat.showSidebar == nil { break }
            }
            guard chat.chatWindow != nil, chat.showSidebar == nil else {
                return "HeyClicky’s task sidebar did not expand; no task was closed."
            }
        }
        guard let selected = await selectTask(task.name, from: chat, config: store.config, unique: true),
              selected.chatWindow != nil, selected.composer != nil,
              Self.chatName(selected).map({ Matcher.normalize($0) == Matcher.normalize(task.name) }) == true else {
            return "HeyClicky could not verify the exact expanded task thread. No other chat was selected."
        }
        record("opened “\(task.name)” in HeyClicky from the task manager")
        return nil
    }

    /// Queues a one-shot report check. Auto-bump should fire immediately against the current report when the task is still eligible.
    func bumpTaskNow(_ taskID: String) {
        let config = store.config
        guard !queuedManualBumpIDs.contains(taskID), !bumpingTaskIDs.contains(taskID) else { return }
        let source = ClickyTaskStore.shared
        guard let task = source.task(taskID),
              TaskPlanning.manualBumpAvailable(task, allTasks: source.tasks, config: config) else {
            record("bump not queued: add a current report and saved definition, use Cruise mode with local Ollama, and resolve any user decision or duplicate task name")
            return
        }
        queuedManualBumpIDs.insert(taskID)
        bumpingTaskIDs.insert(taskID)
        lastDefinitionCheckAt = .distantPast
        backgroundTaskStatus = "One-time bump queued for “\(task.name)”; Cruise will send the current eligible follow-up immediately when the task remains valid."
        record("one-time bump queued for “\(task.name)” — no extra wait added before delivery")
    }

    func assignProject(_ project: TaskProject, to task: String) {
        var catalog = taskCatalog
        catalog.assign(project, to: task)
        saveTaskCatalog(catalog)
    }

    func manageSavedTask(_ id: String, disposition: SavedTaskDisposition?, delete: Bool = false) {
        guard taskCatalogReadable else {
            record("Saved task changes blocked: the task catalog could not be read.")
            return
        }
        var catalog = taskCatalog
        guard catalog.manageSavedRecord(id, disposition: disposition, delete: delete) else {
            record("Saved task changes blocked: this record now matches a current HeyClicky job. Refresh tasks.")
            return
        }
        saveTaskCatalog(catalog)
        if let error = taskCatalogError { record(error) }
    }

    func updateTaskCatalog(_ tasks: [ClickyAgentTask]) {
        guard taskCatalogReadable else { return }
        var catalog = taskCatalog
        do {
            try catalog.synchronize(tasks)
        } catch {
            let message = "Couldn't update task projects: \(error.localizedDescription)"
            if taskCatalogError != message { record(message) }
            taskCatalogError = message
            return
        }
        if catalog != taskCatalog { saveTaskCatalog(catalog) }
        else { taskCatalogError = nil }
    }

    private func saveTaskCatalog(_ catalog: TaskCatalog) {
        guard taskCatalogReadable else { return }
        do {
            try JSONEncoder().encode(catalog).write(to: taskCatalogURL, options: .atomic)
            taskCatalog = catalog
            taskCatalogError = nil
        } catch {
            let message = "Couldn't save the task catalog: \(error.localizedDescription)"
            if taskCatalogError != message { record(message) }
            taskCatalogError = message
        }
    }

    func start() {
        record("cruise control started in \(store.config.mode.title) mode")
        refreshClickyRunning()
        observeClickyLifecycle()
        requestPermissionsIfNeeded()
        restartTimer()
    }

    func requestPermissionsIfNeeded() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        if store.config.ocrFallback && !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
    }

    func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: store.config.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 0.1
    }

    private func tick() {
        let accessibility = AXIsProcessTrusted()
        let recording = CGPreflightScreenCaptureAccess()
        if axTrusted != accessibility { axTrusted = accessibility }
        if screenTrusted != recording { screenTrusted = recording }
        tickTaskEngine()
        guard drivingTaskName == nil else { return }
        refreshClickyRunning()
        tickPendingVSCodeAlerts()
        let taskRefreshInterval = min(15, max(10, store.config.pollInterval))
        if !taskCatalogRefreshing, Date().timeIntervalSince(lastTaskCatalogRefreshAt) >= taskRefreshInterval {
            Task { await refreshTaskCatalog() }
        }
        if axTrusted, !usageScanBusy, Date().timeIntervalSince(lastUsageScanAt) >= 30 {
            lastUsageScanAt = Date()
            usageScanBusy = true
            Task {
                await refreshUsageGuard()
                usageScanBusy = false
            }
        }
        guard !enforceUsageGuard() else { return }
        if !definitionReviewBusy, Date().timeIntervalSince(lastDefinitionReviewAt) >= 10,
           store.config.taskPlans.values.contains(where: \.autoBump) {
            definitionReviewBusy = true
            lastDefinitionReviewAt = Date()
            Task {
                await reviewAutoBumpDefinitions()
                definitionReviewBusy = false
            }
        }
        if store.config.backgroundTaskReview, !backgroundReviewBusy,
           Date().timeIntervalSince(lastBackgroundReviewAt) >= 60 {
            Task { await reviewBackgroundTasks() }
        }
        checkAppcastIfDue()
        relaunchClickyIfStuck()
        tickVSCode()
        tickModelRouting()
        guard !busy, !modelBusy, axTrusted, clickyRunning else {
            if !clickyRunning {
                gate.coolDown()
                consentAttempts = 0
            }
            return
        }
        busy = true
        Task {
            await cycle()
            busy = false
        }
    }

    private func refreshUsageGuard() async {
        let config = store.config
        if let percentage = await Worker.scanVSCode({ VSCodeScanner(config: config).usageNotificationPercentage() }) {
            // Keep the highest warning until the user resets it after credits renew.
            store.config.vscodeObservedUsage = max(store.config.vscodeObservedUsage ?? 0, percentage)
        }
        _ = enforceUsageGuard()
    }

    @discardableResult
    private func enforceUsageGuard() -> Bool {
        guard store.config.usageCutoffReached else { return false }
        if store.config.stopAtUsageCutoff() {
            record("Copilot usage cutoff reached (\(store.config.vscodeObservedUsage ?? 0)% / \(store.config.vscodeUsageCutoff ?? 100)%): Cruise Control stopped; VS Code approvals, follow-ups, model routing and HeyClicky updates disabled. Running agents are not cancelled.")
        }
        return true
    }

    private func refreshClickyRunning() {
        let running = store.config.clickyBundleIDs.contains { id in
            NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { !$0.isTerminated }
        }
        if running != clickyRunning { clickyRunning = running }
    }

    private func observeClickyLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.publisher(for: name)
                .compactMap { ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier }
                .sink { [weak self] id in
                    Task { @MainActor in
                        guard let self, self.store.config.clickyBundleIDs.contains(id) else { return }
                        // Terminated apps can linger briefly in runningApplications.
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        self.refreshClickyRunning()
                        self.clickyQuitAt = self.clickyRunning ? nil : Date()
                        if self.clickyRunning {
                            self.lastInterruptedProbeAt = .distantPast
                            self.lastNotchInspectionAt = .distantPast
                        }
                        self.record(self.clickyRunning ? "heyclicky launched" : "heyclicky quit")
                    }
                }
                .store(in: &cancellables)
        }
    }

    private func cycle() async {
        guard drivingTaskName == nil, !safetyReviewInProgress else { return }
        let config = store.config
        if pendingMessage?.chatOnly == true {
            await retryPendingMessage(config: config)
            return
        }
        if await deliverBackgroundReply(config: config) { return }
        guard drivingTaskName == nil else { return }
        if config.autoContinueReports && !autoContinueReportsEnabled {
            lastInterruptedProbeAt = .distantPast
            lastNotchInspectionAt = .distantPast
            lastStallProbeAt = .distantPast
            gate.coolDown()
            record("keep unfinished tasks going was re-enabled — checking heyclicky immediately")
        }
        autoContinueReportsEnabled = config.autoContinueReports
        if await handleSystemDialog(config: config) { return }
        var result = await Worker.run { ClickyScanner(config: config).scan() }
        guard drivingTaskName == nil else { return }
        guard result.clickyRunning else {
            gate.coolDown()
            consentAttempts = 0
            return
        }
        guard messageHistoryReadable else { return }
        if let message = pendingMessage, message.isExpired(), message.holdReason == nil {
            holdPendingMessage("Undelivered for 30 minutes. Review the saved message and the task in HeyClicky before discarding it.")
        }
        let now = Date()
        if config.taskPlans.values.contains(where: \.autoBump),
           NotchInspection.shouldInspect(workingCount: result.workingCount, mode: config.mode,
                                         idleSeconds: Self.idleSeconds(), lastProbe: lastNotchInspectionAt,
                                         now: now, config: config) {
            lastNotchInspectionAt = now
            lastInterruptedProbeAt = now
            lastStallProbeAt = now
            record("no Working status visible — inspecting heyclicky's notch")
            if let expanded = await hoverNotch(config: config, until: {
                $0.needsYou != nil || !$0.interrupted.isEmpty || !$0.reports.isEmpty
                    || $0.consent != nil || $0.lastCard != nil || $0.openChat != nil
                    || ($0.workingCount ?? 0) > 0
            }) {
                result = expanded
            } else {
                record("notch inspection found no readable task cards — will check again")
            }
        }
        guard drivingTaskName == nil else { return }
        let rows = result.chatButtons.map(\.label).filter { TaskRow.parse($0) != nil }
        if !rows.isEmpty { lastTaskLabels = rows }
        _ = recoveryAllowed(result)
        if result.conversation.suffix(6).contains(where: { $0.contains("Please update HeyClicky") || $0.contains("agent_turn_lease_required") }) {
            updateHintAt = Date()
        }

        if await handleConsent(result, config: config) { return }
        guard drivingTaskName == nil else { return }
        if await clearTaskNotice(result, config: config) { return }
        if pendingMessage != nil {
            await retryPendingMessage(config: config)
            return
        }
        if await handleUpdate(result, config: config) { return }
        guard drivingTaskName == nil else { return }
        if await continueToDefinitionOfDone(config: config) { return }
        guard drivingTaskName == nil, pendingMessage == nil else { return }
    }

    // MARK: macOS automation / permission dialogs ("HeyClicky wants access to control …")

    /// Approves (cruise) or dismisses (rest) a system permission alert that HeyClicky triggered. Returns true when
    /// one was on screen, so the rest of the cycle waits for it to clear.
    private func handleSystemDialog(config: Config) async -> Bool {
        guard config.heyClickyDriveEnabled, config.autoAnswerSystemDialogs, config.mode != .manual else { return false }
        guard let dialog = await Worker.run({ SystemDialogScanner(config: config).scan() }) else { return false }
        let allow = config.mode == .cruise
        guard let target = allow ? dialog.allow : dialog.deny else {
            // e.g. rest mode on an OK-only alert: nothing safe to press.
            return dialog.allow != nil || dialog.deny != nil
        }
        guard store.config.mode == config.mode, store.config.heyClickyDriveEnabled else { return true }
        guard Date().timeIntervalSince(lastSystemDialogAt) > 2 else { return true }
        lastSystemDialogAt = Date()

        let subject = Matcher.quotedSubjects(dialog.message)
        var pressed = await Worker.run { AX.press(target) }
        if !pressed { pressed = await mouseClick(on: target) }
        guard pressed else {
            record("couldn't press the HeyClicky system permission button")
            return true
        }
        if allow { stats.approved += 1 } else { stats.declined += 1 }
        lastActionAt = Date()
        record("\(allow ? "allowed" : "dismissed") system request\(subject.isEmpty ? "" : " (\(subject))")")
        return true
    }

    // MARK: Drive consent ("Go ahead" / "Let Clicky Drive" vs "Not now")

    /// Returns true when a consent prompt is on screen (so report handling waits).
    private func handleConsent(_ result: ScanResult, config: Config) async -> Bool {
        if let consent = result.consent {
            guard config.heyClickyDriveEnabled, store.config.heyClickyDriveEnabled,
                  config.mode != .manual, store.config.mode == config.mode else { return true }
            let allow = config.mode == .cruise
            let target = allow ? consent.allow : consent.deny
            let label = allow ? consent.allowLabel : consent.denyLabel

            guard Date().timeIntervalSince(lastConsentActionAt) > 1.2 else { return true }
            lastConsentActionAt = Date()
            consentAttempts += 1

            switch consentAttempts {
            case 1, 2:
                let pressed = await Worker.run { AX.press(target, requiresUserPause: false) }
                if pressed && !consentCounted {
                    consentCounted = true
                    if allow { stats.approved += 1 } else { stats.declined += 1 }
                    record("\(allow ? "approved" : "declined") drive request → “\(label)”")
                } else if !pressed {
                    record("couldn't press “\(label)” via Accessibility — retrying")
                }
            case 3...5:
                guard store.config.taskPlans.values.contains(where: \.autoBump) else {
                    record("drive request remains visible; background approval failed and mouse takeover is disabled without Auto-bump")
                    return true
                }
                let clicked = await mouseClick(on: target)
                if clicked && !consentCounted {
                    consentCounted = true
                    if allow { stats.approved += 1 } else { stats.declined += 1 }
                }
                record("prompt still showing — \(clicked ? "clicked" : "couldn't locate") “\(label)” with the mouse")
            case 6:
                record("gave up on this drive prompt after 5 attempts")
            default:
                break
            }
            lastActionAt = Date()
            return true
        }

        consentAttempts = 0
        consentCounted = false
        if !result.orphanConsentLabels.isEmpty, Date().timeIntervalSince(lastOrphanLogAt) > 300 {
            lastOrphanLogAt = Date()
            record("saw “\(result.orphanConsentLabels.joined(separator: "”, “"))” without its partner button — ignoring")
        }

        guard config.heyClickyDriveEnabled, config.mode != .manual, config.ocrFallback, screenTrusted,
              Date().timeIntervalSince(lastOCRAt) > config.ocrInterval else { return false }
        lastOCRAt = Date()
        guard let hit = await ScreenOCR.findConsent(config: config) else { return false }
        guard store.config.heyClickyDriveEnabled, store.config.mode == config.mode else { return true }

        let allow = config.mode == .cruise
        guard Date().timeIntervalSince(lastConsentActionAt) > 2 else { return true }
        lastConsentActionAt = Date()
        await withOverlayHidden {
            await Worker.run { InputSynth.click(at: allow ? hit.allow : hit.deny) }
        }
        if allow { stats.approved += 1 } else { stats.declined += 1 }
        lastActionAt = Date()
        record("\(allow ? "approved" : "declined") drive request via screen OCR")
        return true
    }

    // MARK: "Full report" → continue the task

    private func handleReports(_ result: ScanResult, config: Config) async {
        if result.selectedTask != nil, !recoveryAllowed(result) { return }
        let before = gate.known.count
        let decision = gate.evaluate(
            fingerprints: result.reports.map(\.fingerprint),
            headers: result.reports.map(\.header),
            enabled: config.mode != .manual && config.autoContinueReports,
            now: Date(),
            limits: ReportGate.Limits(config: config)
        )
        if gate.known.count != before { saveSeen() }

        switch decision {
        case .trigger(let index):
            await continueTask(result.reports[index], config: config)
        case .stale:
            record("new “Full report” is older than \(Int(config.reportFreshnessMinutes)) min — skipped")
        case .rateLimited:
            record("new “Full report” skipped — continue limit reached (\(config.maxContinuesPerHour)/hour, ≥\(Int(config.minSecondsBetweenContinues))s apart)")
        case .none, .seeded, .disabled:
            break
        }
    }

    private func continueTask(_ report: ReportButton, config: Config) async {
        guard !ClickyTaskStore.shared.tasks.contains(where: {
            hasSavedDefinition(task: $0.name) && Matcher.isTaskRow(report.header, title: $0.name)
        }) else { return }
        gate.recordContinue(at: Date())
        saveBudget()
        lastActionAt = Date()
        let label = report.header.isEmpty ? "task" : "“\(report.header)”"
        record("unfinished \(label) — opening Full report")

        let previousApp = NSWorkspace.shared.frontmostApplication
        let element = report.element
        if !(await Worker.run { AX.press(element) }) {
            _ = await mouseClick(on: element)
        }
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        let rescan = await Worker.run { ClickyScanner(config: config).scan() }
        guard recoveryAllowed(rescan) else { return }
        guard !report.header.isEmpty,
              let task = rescan.selectedTask,
              Matcher.isTaskRow(report.header, title: task) || report.header.hasPrefix(task + ", ") else {
            record("report task could not be verified — not sending a continuation into an unrelated chat")
            return
        }
        guard let composer = rescan.composer else {
            record("couldn't find HeyClicky's chat box — is the chat window closed?")
            return
        }

        guard let latestReport = rescan.latestReport else {
            record("report has no readable task-specific context — not sending a generic continuation")
            return
        }
        do {
            let draft = try await Ollama.draftChatBump(
                TaskAudit.context(task: task, transcript: rescan.transcript.joined(separator: "\n")),
                config: config, system: TaskAudit.system, taskName: task,
                latestReport: TaskAudit.latestTurn(rescan.transcript, report: latestReport), implicitYes: config.mode == .cruise)
            guard draft.unfinished else {
                record("report for “\(task)” has no actionable unfinished work")
                return
            }
            let fresh = await Worker.run { ClickyScanner(config: config).scan() }
            let input = composer.input
            guard fresh.selectedTask == task, fresh.transcript == rescan.transcript,
                  store.config.mode != .manual, store.config.autoContinueReports,
                  await Worker.run({ (AX.stringValue(input) ?? "").isEmpty }) else {
                record("report context changed — continuation not sent")
                return
            }
            if await send(draft.message, via: composer, task: task) {
                stats.continued += 1
                record("sent task-specific report continuation to “\(task)”")
            } else {
                record("failed to send task-specific report continuation")
            }
        } catch {
            record("couldn't assess task report: \(error.localizedDescription) — no generic fallback sent")
        }

        if pendingMessage == nil, let previousApp, previousApp.bundleIdentifier.map({ !config.clickyBundleIDs.contains($0) }) ?? true {
            previousApp.activate()
        }
    }

    /// Clears only a scoped notification X, never the task's sidebar X or its pending request.
    private func clearTaskNotice(_ result: ScanResult, config: Config) async -> Bool {
        guard config.mode == .cruise, store.config.mode == .cruise,
              drivingTaskName == nil, !safetyReviewInProgress,
              Date().timeIntervalSince(lastTaskNoticeDismissAt) >= 3,
              let notice = result.taskNotices.first else { return false }
        lastTaskNoticeDismissAt = Date()
        let close = notice.close
        guard !Task.isCancelled,
              await Worker.run({ AX.press(close, requiresUserPause: false) }) else {
            record("Could not close HeyClicky's notification for “\(notice.task)” via Accessibility; no mouse takeover or task action attempted")
            return true
        }
        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return true }
            let fresh = await Worker.run { ClickyScanner(config: config).scan() }
            if !fresh.taskNotices.contains(where: { CFEqual($0.close, close) }) {
                record("Closed HeyClicky's notification for “\(notice.task)” to allow the next request; task state and Auto-bump unchanged")
                return true
            }
        }
        record("HeyClicky's notification for “\(notice.task)” is still visible after closing; will retry one card at a time")
        return true
    }

    // MARK: Legacy needs-you continuation (not called by the monitoring loop)

    /// Returns true when it acted (so the rest of this cycle is skipped).
    private func handleNeedsYou(_ result: ScanResult, config: Config) async -> Bool {
        guard let card = result.needsYou else { return false }
        let task = card.task.isEmpty ? "task" : card.task
        guard config.mode != .manual, config.autoContinueReports,
              !taskRecovery.isStopped(task: task), !hasSavedDefinition(task: task) else { return false }

        let now = Date()
        let limits = ReportGate.Limits(config: config)
        guard nudgeLimiter.allow(task: task, now: now, maxPerHour: config.maxNudgesPerTaskPerHour),
              gate.canContinue(now: now, limits: limits) else {
            if now.timeIntervalSince(lastNeedsYouSkipLog[task] ?? .distantPast) > 600 {
                lastNeedsYouSkipLog[task] = now
                record("“\(task)” needs you — leaving it for you (nudge limit reached)")
            }
            return false
        }
        nudgeLimiter.record(task: task, at: now)
        gate.recordContinue(at: now)
        saveBudget()
        lastActionAt = now
        record("“\(task)” needs you — closing the card")

        let previousApp = NSWorkspace.shared.frontmostApplication
        let close = card.close
        if !(await Worker.run { AX.press(close) }) {
            _ = await mouseClick(on: close)
        }
        try? await Task.sleep(nanoseconds: 700_000_000)

        guard var chat = await revealChat(config: config) else {
            record("couldn't open heyclicky's chat window — nudge not sent")
            return true
        }

        guard let selected = await selectTask(task, from: chat, config: config) else { return true }
        chat = selected
        guard recoveryAllowed(chat) else { return true }
        guard let composer = chat.composer else {
            record("couldn't find heyclicky's chat box — nudge not sent")
            return true
        }

        let message = await draftNudge(task: task, transcript: chat.transcript, config: config)
        if await send(message, via: composer, task: task) {
            stats.continued += 1
            record("nudged “\(task)”: \(message.prefix(90))\(message.count > 90 ? "…" : "")")
        } else {
            record("failed to send nudge to “\(task)”")
        }

        if pendingMessage == nil, let previousApp, previousApp.bundleIdentifier.map({ !config.clickyBundleIDs.contains($0) }) ?? true {
            previousApp.activate()
        }
        return true
    }

    /// Makes sure HeyClicky's chat window (with its composer) is on screen and returns a fresh scan.
    private func revealChat(config: Config, requireSidebar: Bool = false) async -> ScanResult? {
        let hasExpandedTaskWindow: (ScanResult) -> Bool = { scan in
            scan.chatWindow != nil && scan.composer != nil
                && (scan.showSidebar != nil || scan.chatButtons.contains(where: { TaskRow.parse($0.label) != nil }))
        }
        let scan = await Worker.run { ClickyScanner(config: config).scan() }
        if requireSidebar ? hasExpandedTaskWindow(scan) : scan.composer != nil { return scan }

        // HeyClicky 1.1.3+: the notch panel's "Open in a window" button opens the full chat.
        if let open = scan.openChat, await Worker.run({ AX.press(open) }) {
            if let ready = await waitForComposer(config: config, requireSidebar: requireSidebar) { return ready }
        } else {
            var pressed = false
            _ = await hoverNotch(config: config, until: { $0.openChat != nil }) { found in
                if let open = found.openChat { pressed = AX.press(open) }
            }
            if pressed, let ready = await waitForComposer(config: config, requireSidebar: requireSidebar) { return ready }
        }

        if let app = config.clickyBundleIDs.lazy.compactMap({ NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }).first,
           let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        return await waitForComposer(config: config, requireSidebar: requireSidebar)
    }

    private func selectTask(_ task: String, from chat: ScanResult, config: Config, unique: Bool = false) async -> ScanResult? {
        if Self.chatName(chat).map({ Matcher.normalize($0) == Matcher.normalize(task) }) == true { return chat }
        let matches = chat.chatButtons.filter {
                Matcher.normalize($0.label) == Matcher.normalize(task) || Matcher.isTaskRow($0.label, title: task)
        }
        guard let row = matches.first, !unique || matches.count == 1 else {
            record("couldn't find HeyClicky task “\(task)” — leaving other chats alone")
            return nil
        }
        let element = row.element
        var pressed = await Worker.run({ AX.press(element) })
        if !pressed {
            // Sidebar rows can be mid-animation; retry once against a fresh scan before giving up.
            try? await Task.sleep(nanoseconds: 600_000_000)
            let retry = await Worker.run { ClickyScanner(config: config).scan() }
            if let again = retry.chatButtons.first(where: {
                Matcher.normalize($0.label) == Matcher.normalize(task) || Matcher.isTaskRow($0.label, title: task)
            }) {
                let el = again.element
                pressed = await Worker.run({ AX.press(el) })
            }
        }
        guard pressed else {
            record("couldn't select HeyClicky task “\(task)”")
            return nil
        }
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            let scan = await Worker.run { ClickyScanner(config: config).scan() }
            if Self.chatName(scan).map({ Matcher.normalize($0) == Matcher.normalize(task) }) == true { return scan }
        }
        record("HeyClicky didn't confirm task “\(task)” — no message sent")
        return nil
    }

    /// Clicky taps out in its main chat ("…shall I retry in smaller checkpoints?") while work is unfinished. In Cruise
    /// mode that is answered yes, asking for smaller tasks that can each be verified.
    private func handleMainChatTapOut(_ result: ScanResult, config: Config) async -> Bool {
        let now = Date()
        guard config.mode == .cruise, config.autoContinueReports, config.replyToTapOuts,
              Self.idleSeconds() >= config.awayIdleSeconds else { return false }
        var chat = result
        var navigatedFrom: String?
        var previousApp: NSRunningApplication?
        if !result.mainChat || result.composer == nil {
            guard now.timeIntervalSince(lastMainChatCheckAt) >= config.clickyTaskAuditMinutes * 60 else { return false }
            lastMainChatCheckAt = now
            previousApp = NSWorkspace.shared.frontmostApplication
            guard let revealed = await revealChat(config: config) else { return false }
            navigatedFrom = revealed.selectedTask
            guard let main = await selectTask(MainChatTapOut.chatName, from: revealed, config: config) else { return false }
            chat = main
        }
        let handled = await answerMainChatTapOut(chat, config: config, now: now)
        if !handled, let task = navigatedFrom {
            let scan = await Worker.run { ClickyScanner(config: config).scan() }
            _ = await selectTask(task, from: scan, config: config)
        }
        if pendingMessage == nil, let previousApp,
           previousApp.bundleIdentifier.map({ !config.clickyBundleIDs.contains($0) }) ?? true {
            previousApp.activate()
        }
        return handled
    }

    private func answerMainChatTapOut(_ chat: ScanResult, config: Config, now: Date) async -> Bool {
        guard chat.mainChat, let composer = chat.composer,
              let tapOut = MainChatTapOut.detect(chat.transcript),
              now.timeIntervalSince(tapOutAttempts[tapOut.fingerprint] ?? .distantPast) >= config.clickyTaskAuditMinutes * 60
        else { return false }
        if taskRecovery.isStopped(task: tapOut.task) { return false }
        if let row = chat.chatButtons.compactMap({ TaskRow.parse($0.label) })
            .first(where: { [tapOut.task, MainChatTapOut.chatName].map(Matcher.normalize).contains(Matcher.normalize($0.name)) && StallTracker.isBusy($0.status) }) {
            record("“\(row.name)” is \(row.status) — tap-out reply waits")
            return false
        }
        let limits = ReportGate.Limits(config: config)
        guard gate.canContinue(now: now, limits: limits),
              nudgeLimiter.allow(task: tapOut.task, now: now, maxPerHour: config.maxNudgesPerTaskPerHour) else { return false }
        let input = composer.input
        guard await Worker.run({ (AX.stringValue(input) ?? "").isEmpty }) else {
            record("main chat has a draft — not answering “\(tapOut.task)” tap-out")
            return false
        }
        if tapOutAttempts.count > 100 { tapOutAttempts.removeAll() }
        tapOutAttempts[tapOut.fingerprint] = now
        record("clicky tapped out on “\(tapOut.task)” in the main chat — drafting a smaller-checkpoints reply")
        let reply = await Ollama.draftTapOutReply(tapOut, config: config)
        let fresh = await Worker.run { ClickyScanner(config: config).scan() }
        guard fresh.mainChat, MainChatTapOut.detect(fresh.transcript) == tapOut, let freshComposer = fresh.composer,
              store.config.mode == .cruise, store.config.replyToTapOuts,
              Self.idleSeconds() >= config.awayIdleSeconds else {
            record("main chat changed while drafting — tap-out reply for “\(tapOut.task)” not sent")
            return false
        }
        nudgeLimiter.record(task: tapOut.task, at: Date())
        gate.recordContinue(at: Date())
        saveBudget()
        let sent = await send(reply.message, via: freshComposer, task: MainChatTapOut.chatName)
        if sent {
            stats.continued += 1
            record("answered “\(tapOut.task)” tap-out in the main chat via \(reply.source): \(reply.message.prefix(160))")
        } else if pendingMessage == nil {
            record("couldn't send the main-chat reply for “\(tapOut.task)”")
        }
        return sent || pendingMessage != nil
    }

    private func auditOtherClickyTasks(config: Config) async -> Bool {
        let now = Date()
        guard config.auditClickyTasks, config.mode == .cruise, config.autoContinueReports,
            Self.idleSeconds() >= config.awayIdleSeconds,
            now.timeIntervalSince(lastTaskAuditAt) >= config.clickyTaskAuditMinutes * 60
        else { return false }
        lastTaskAuditAt = now
        let previousApp = NSWorkspace.shared.frontmostApplication
        guard let original = await revealChat(config: config) else {
            record("task audit couldn't open HeyClicky — will retry later")
            return false
        }
        let tasks = TaskAudit.candidates(tracked: config.trackedClickyTasks, recent: original.recentTasks)
        var sent = false
        for task in tasks {
            guard store.config.auditClickyTasks, store.config.mode == .cruise,
                Self.idleSeconds() >= config.awayIdleSeconds
            else { break }
            let limits = ReportGate.Limits(config: config)
            guard gate.canContinue(now: Date(), limits: limits),
                nudgeLimiter.allow(task: task, now: Date(), maxPerHour: config.maxNudgesPerTaskPerHour)
            else { continue }
            let scan = await Worker.run { ClickyScanner(config: config).scan() }
            guard let chat = await selectTask(task, from: scan, config: config),
                let composer = chat.composer
            else { continue }
            guard recoveryAllowed(chat) else { continue }
            guard let status = chat.selectedStatus, !StallTracker.isBusy(status),
                let latestReport = chat.latestReport
            else { continue }
            let input = composer.input
            guard await Worker.run({ (AX.stringValue(input) ?? "").isEmpty }) else {
                record("task “\(task)” has a draft — audit will not overwrite it")
                continue
            }
            var state = taskAuditStates[task] ?? ChatBump.State()
            let transcript = chat.transcript.joined(separator: "\n")
            state.observe(transcript, now: Date())
            guard transcript != state.answeredTranscript,
                Date().timeIntervalSince(state.lastAttempt) >= config.clickyTaskAuditMinutes * 60,
                !transcript.isEmpty
            else { continue }
            state.lastAttempt = Date()
            taskAuditStates[task] = state
            saveTaskAudits()
            do {
                let draft = try await Ollama.draftChatBump(
                    TaskAudit.context(task: task, transcript: transcript), config: config, system: TaskAudit.system, taskName: task,
                    latestReport: TaskAudit.latestTurn(chat.transcript, report: latestReport), implicitYes: config.mode == .cruise)
                guard draft.unfinished else {
                    state.answeredTranscript = transcript
                    taskAuditStates[task] = state
                    guard saveTaskAudits() else { break }
                    record("task audit: “\(task)” has no actionable unfinished work")
                    continue
                }
                let fresh = await Worker.run { ClickyScanner(config: config).scan() }
                guard fresh.selectedTask == chat.selectedTask, fresh.transcript == chat.transcript,
                    let freshComposer = fresh.composer,
                    store.config.mode == .cruise, store.config.auditClickyTasks,
                    Self.idleSeconds() >= config.awayIdleSeconds
                else {
                    record("task changed during audit of “\(task)” — no message sent")
                    continue
                }
                let freshInput = freshComposer.input
                guard await Worker.run({ (AX.stringValue(freshInput) ?? "").isEmpty }) else { continue }
                nudgeLimiter.record(task: task, at: Date())
                gate.recordContinue(at: Date())
                saveBudget()
                if await send(draft.message, via: freshComposer, task: task) {
                    stats.continued += 1
                    sent = true
                    state.answeredTranscript = transcript
                    taskAuditStates[task] = state
                    guard saveTaskAudits() else { return sent }
                    record("task audit resumed “\(task)”: \(draft.message.prefix(160))")
                } else {
                    record("task audit couldn't send to “\(task)” — not redirecting to another task")
                    if pendingMessage != nil { return sent }
                }
            } catch {
                record("task audit failed for “\(task)”: \(error.localizedDescription)")
            }
        }
        if let task = original.selectedTask {
            let scan = await Worker.run { ClickyScanner(config: config).scan() }
            _ = await selectTask(task, from: scan, config: config)
        }
        if pendingMessage == nil, let previousApp, previousApp.bundleIdentifier.map({ !config.clickyBundleIDs.contains($0) }) ?? true {
            previousApp.activate()
        }
        return sent
    }

    private func reviewAutoBumpDefinitions() async {
        let source = ClickyTaskStore.shared
        let config = store.config
        guard TaskPlanning.definitionDeliveryAllowed(config: config, oneShot: false), source.canPersist else { return }
        let requestedAt = Date()
        await source.refresh(measure: false)
        guard source.loadedAt.map({ $0 >= requestedAt }) == true, source.loadError == nil else {
            record("Auto-bump review paused: \(source.loadError ?? "waiting for a fresh HeyClicky report")")
            return
        }
        for task in TaskPlanning.prioritized(source.tasks, catalog: taskCatalog, config: store.config) {
            guard drivingTaskName == nil,
                  TaskPlanning.definitionDeliveryAllowed(config: store.config, oneShot: false) else { return }
            guard !task.dismissed, task.hasReport, !task.isWorking,
                  let definition = DefinitionOfDone.normalized(store.config.clickyDefinitionsOfDone[task.id]) else { continue }
            // The task engine examines every task one at a time; this only turns finished reviews into notices.
            guard let assessment = source.currentAssessment(for: task, definition: definition),
                  assessment.source.hasPrefix("ollama"),
                  let candidate = TaskCompletionNotice(task: task, definition: definition, assessment: assessment),
                  !candidate.isSameReport(as: source.record(task.id).completionNotice) else { continue }
            let checkedAt = Date()
            await source.refresh(measure: false)
            guard source.loadedAt.map({ $0 >= checkedAt }) == true, source.loadError == nil,
                  let latest = source.task(task.id), latest.fingerprint == task.fingerprint,
                  DefinitionOfDone.normalized(store.config.clickyDefinitionsOfDone[task.id]) == definition,
                  TaskPlanning.definitionDeliveryAllowed(config: store.config, oneShot: false),
                  !taskRecovery.isStopped(task: latest.name),
                  var notice = TaskCompletionNotice(task: latest, definition: definition, assessment: assessment) else { continue }
            notice.autoBump = TaskPlanning.autoBumpEnabled(latest, config: store.config, workspace: confirmedTaskWorkspace(latest.id))
            if notice.meetsDefinition != true, notice.autoBump == true { lastDefinitionCheckAt = .distantPast }
            if source.recordCompletion(notice) {
                record("“\(task.name)” changed state; Cruise reviewed it (\(notice.meetsDefinition == true ? "appears to meet" : "short of") your Done definition) and queued a review notice")
            } else {
                record("Couldn't save review notification for “\(task.name)”: \(source.loadError ?? "task-state persistence failed")")
            }
        }
    }

    /// Each changed report is compared with the current saved criteria before any follow-up is sent.
    private func continueToDefinitionOfDone(config: Config) async -> Bool {
        let now = Date()
        guard !config.clickyDefinitionsOfDone.isEmpty,
              TaskPlanning.definitionDeliveryAllowed(config: config, oneShot: !queuedManualBumpIDs.isEmpty),
              now.timeIntervalSince(lastDefinitionCheckAt) >= 10
        else { return false }
        lastDefinitionCheckAt = now
        let tasks = ClickyTaskStore.shared
        guard tasks.canPersist else {
            record("define done paused: \(tasks.persistenceError ?? "saved task state is unreadable")")
            return false
        }
        let requestedAt = Date()
        await tasks.refresh(measure: false)
        guard let loadedAt = tasks.loadedAt, loadedAt >= requestedAt, tasks.loadError == nil else {
            record("define done: \(tasks.loadError ?? "waiting for a fresh task-list read")")
            return false
        }
        let maxRounds = config.maxDefinitionRounds
        let manualRequests = queuedManualBumpIDs
        var due: [(task: ClickyAgentTask, definition: String, assessment: ClickyTaskAssessment)] = []
        let ambiguous = ClickyTaskLibrary.ambiguousNames(tasks.tasks)
        for task in TaskPlanning.prioritized(tasks.tasks, catalog: taskCatalog, config: store.config) {
            let optedIn = TaskPlanning.autoBumpEnabled(task, config: store.config, workspace: confirmedTaskWorkspace(task.id)) || manualRequests.contains(task.id)
            if optedIn, DefinitionOfDone.normalized(config.clickyDefinitionsOfDone[task.id]) != nil,
               !task.dismissed, !task.isStopped, taskRecovery.isStopped(task: task.name),
               engine.resumed[task.id] == task.fingerprint {
                // An explicit Auto-bump/Generate request after an old stop, with a current non-stopped status, supersedes it.
                var released = taskRecovery
                released.release(task: task.name)
                do {
                    try JSONEncoder().encode(released).write(to: taskRecoveryURL, options: .atomic)
                    taskRecovery = released
                    record("define done: “\(task.name)” released an old remembered stop because Auto-bump is on and its status is no longer stopped")
                } catch {
                    record("define done: “\(task.name)” is held by a remembered stop that couldn't be released: \(error.localizedDescription)")
                }
            }
            guard optedIn,
                  let definition = DefinitionOfDone.normalized(config.clickyDefinitionsOfDone[task.id]),
                  !engine.isReviewOnly(Self.clickyKey(task.id), report: task.fingerprint, definition: definition),
                  task.hasReport, !task.dismissed, !task.isWorking, !stopHeld(task),
                  tasks.rounds(for: task, definition: definition) < maxRounds else { continue }
            guard TaskPlanning.continuationAllowed(task, config: store.config, manual: manualRequests.contains(task.id),
                                                   ignoringStop: true) else {
                record("define done: “\(task.name)” is held by its saved stop-reason settings or a user blocker")
                continue
            }
            let progress = tasks.record(task.id).progress
            if let retry = engine.records[Self.clickyKey(task.id)]?.nextRetryAt, retry > Date() { continue }
            autoBumpDeliveryHolds[task.id] = nil
            // Already followed up on this exact report; wait for Clicky's next one.
            if progress.lastFingerprint == task.fingerprint,
               DefinitionOfDone.normalized(progress.definition) == definition { continue }
            if let reply = tasks.record(task.id).backgroundReply,
               reply.fingerprint == task.fingerprint, reply.definition == definition { continue }
            // The task engine examines each report; the sender only delivers what it has reviewed.
            guard var assessment = tasks.currentAssessment(for: task, definition: definition),
                  assessment.source.hasPrefix("ollama") else { continue }
            if DefinitionOfDone.needsAgentFollowUp(assessment, report: task.lastMessage) {
                assessment = DefinitionOfDone.redirectedToAgent(assessment, definition: definition)
                record("define done: “\(task.name)” review asked something HeyClicky can answer — treating it as a gap")
            }
            guard assessment.source.hasPrefix("ollama") else {
                record("define done: no automatic bump for “\(task.name)” because local Ollama review was unavailable")
                continue
            }
            if DefinitionOfDone.hasNoProgress(assessment, progress: progress, task: task) {
                record("define done: “\(task.name)” repeated the same completion gaps — automatic bump stopped for review")
                continue
            }
            if DefinitionOfDone.shouldContinue(task, definition: definition, assessment: assessment,
                                               progress: progress, maxRounds: maxRounds) {
                if ambiguous.contains(Matcher.normalize(task.name)) {
                    record("define done: more than one HeyClicky task is named “\(task.name)” — rename one; no follow-up sent")
                    continue
                }
                due.append((task, definition, assessment))
            }
        }
        let waitingForReport = Set(tasks.tasks.filter {
            manualRequests.contains($0.id) && ($0.isWorking || !$0.hasReport)
        }.map(\.id))
        let consumedRequests = manualRequests.subtracting(waitingForReport)
        queuedManualBumpIDs.subtract(consumedRequests)
        bumpingTaskIDs.subtract(consumedRequests)
        guard !due.isEmpty, drivingTaskName == nil,
              TaskPlanning.definitionDeliveryAllowed(config: store.config, oneShot: !manualRequests.isEmpty) else {
            if !consumedRequests.isEmpty {
                backgroundTaskStatus = "No safe completion gap was found, or a decision/error stopped the one-time bump. Nothing was sent."
            }
            return false
        }
        let recheckAt = Date()
        await tasks.refresh(measure: false)
        guard let reloadedAt = tasks.loadedAt, reloadedAt >= recheckAt, tasks.loadError == nil else {
            record("define done: task-list recheck did not complete — no follow-up sent")
            return false
        }

        let previousApp = NSWorkspace.shared.frontmostApplication
        guard let original = await revealChat(config: config) else {
            record("define done couldn't open HeyClicky — will retry later")
            return false
        }
        var sent = false
        for item in due {
            let task = item.task
            guard TaskPlanning.autoBumpEnabled(task, config: store.config, workspace: confirmedTaskWorkspace(task.id)) || manualRequests.contains(task.id),
                  DefinitionOfDone.normalized(store.config.clickyDefinitionsOfDone[task.id]) == item.definition,
                  let latest = tasks.task(task.id), latest.fingerprint == task.fingerprint,
                  !latest.isWorking, !stopHeld(latest), !latest.dismissed,
                  !ClickyTaskLibrary.ambiguousNames(tasks.tasks).contains(Matcher.normalize(task.name)) else {
                record("define done: “\(task.name)” or its definition changed during review — no follow-up sent")
                continue
            }
            guard drivingTaskName == nil,
                  TaskPlanning.definitionDeliveryAllowed(config: store.config, oneShot: manualRequests.contains(task.id)) else { break }
            let scan = await Worker.run { ClickyScanner(config: config).scan() }
            if let row = scan.chatButtons.compactMap({ TaskRow.parse($0.label) })
                .first(where: { Matcher.normalize($0.name) == Matcher.normalize(task.name) }), StallTracker.isBusy(row.status) {
                record("define done: “\(task.name)” is \(row.status) — follow-up waits")
                continue
            }
            let chatTarget = task.name
            guard TaskWorkflow.messageBlocker(
                project: taskCatalog.tasks.first(where: { $0.id == task.id && $0.projectAssigned })?.project ?? TaskProject(),
                plan: store.config.taskPlans[task.id] ?? TaskPlan()) == nil else { continue }
            let selected = await selectTask(task.name, from: scan, config: config, unique: true)
            guard let chat = selected, let composer = chat.composer,
                  recoveryAllowed(chat) else {
                autoBumpDeliveryHolds[task.id] = "Could not verify this exact task's HeyClicky chat. Nothing was sent to the main chat or another task."
                continue
            }
            if let status = chat.selectedStatus, StallTracker.isBusy(status) { continue }
            let input = composer.input
            guard await Worker.run({ AX.stringValue(input) == "" }) else {
                autoBumpDeliveryHolds[task.id] = "HeyClicky's composer has an existing or unreadable draft; it will not be overwritten."
                record("“\(task.name)” has a draft — define-done follow-up will not overwrite it")
                continue
            }
            guard DefinitionOfDone.normalized(store.config.clickyDefinitionsOfDone[task.id]) == item.definition else {
                record("define done: the target changed while opening “\(task.name)” — no follow-up sent")
                continue
            }
            // Exactly the draft the task panel shows for this review.
            let draft = ChatBump.Draft(unfinished: true,
                message: heyClickyFollowUp(task, definition: item.definition, missing: item.assessment.missing, config: store.config))
            guard draft.unfinished, TaskAudit.definitionFollowUpIsActionable(draft.message) else {
                autoBumpDeliveryHolds[task.id] = "Local Ollama did not produce an actionable follow-up; review the saved criteria and report."
                record("define done: Ollama found no explicit actionable gap for “\(task.name)” — nothing sent")
                continue
            }
            let afterDraft = Date()
            await tasks.refresh(measure: false)
            guard let refreshedAt = tasks.loadedAt, refreshedAt >= afterDraft, tasks.loadError == nil,
                  let refreshedTask = tasks.task(task.id), refreshedTask.fingerprint == task.fingerprint,
                  DefinitionOfDone.normalized(store.config.clickyDefinitionsOfDone[task.id]) == item.definition,
                  (TaskPlanning.autoBumpEnabled(refreshedTask, config: store.config, workspace: confirmedTaskWorkspace(task.id)) || manualRequests.contains(task.id)),
                  TaskPlanning.continuationAllowed(refreshedTask, config: store.config, manual: manualRequests.contains(task.id),
                                                   ignoringStop: true),
                  !ClickyTaskLibrary.ambiguousNames(tasks.tasks).contains(Matcher.normalize(refreshedTask.name)),
                  engineAssessment(refreshedTask, definition: item.definition)?.missing == item.assessment.missing,
                  !refreshedTask.isWorking, !stopHeld(refreshedTask), !refreshedTask.dismissed,
                  !TaskAudit.requiresUser(refreshedTask.lastMessage) else {
                record("define done: task, report, or opt-in changed during Ollama drafting — no bump sent")
                continue
            }
            let round = tasks.rounds(for: task, definition: item.definition) + 1
            let message = draft.message
            if engine.alreadyDelivered(Self.clickyKey(task.id), definition: item.definition, message: message) {
                autoBumpDeliveryHolds[task.id] = "This exact follow-up was already delivered. Review the latest response; nothing repeated."
                continue
            }
            // Reserve the round on disk before typing, so a saved-for-retry message still counts after a restart.
            let previous = tasks.record(task.id).progress
            guard tasks.recordFollowUp(task, definition: item.definition, missing: item.assessment.missing) else {
                record("define done: couldn't save the round for “\(task.name)” — no follow-up sent. "
                    + (tasks.persistenceError ?? tasks.loadError ?? ""))
                break
            }
            let oneShot = manualRequests.contains(task.id) && !TaskPlanning.autoBumpEnabled(task, config: store.config, workspace: confirmedTaskWorkspace(task.id))
            let target = PendingMessage.CompletionTarget(taskID: task.id, definition: item.definition,
                                                         reportFingerprint: task.fingerprint, oneShot: oneShot,
                                                         workflowKey: currentWorkflowKey(task.id), workspace: confirmedTaskWorkspace(task.id))
            let engineKey = Self.clickyKey(task.id)
            engine.records[engineKey]?.stage = .sending
            engine.records[engineKey]?.detail = "Typing the follow-up into HeyClicky's “\(task.name)” chat…"
            engineActivity = ("Sending the auto-bump to HeyClicky “\(task.name)”", engineKey, Date())
            let delivered = await send(message, via: composer, task: chatTarget, completionTarget: target)
            engineActivity = nil
            if delivered {
                engine.recordSent(engineKey, detail: "Sent \(Date().formatted(date: .omitted, time: .shortened)) · round \(round) of \(maxRounds); waiting for HeyClicky's next response.")
                saveEngine()
                stats.continued += 1
                sent = true
                record("define done: “\(task.name)” falls short (round \(round) of \(maxRounds)) — asked for: "
                    + item.assessment.missing.joined(separator: "; ").prefix(160))
            } else {
                if pendingMessage != nil {
                    engine.records[engineKey]?.stage = .sending
                    engine.records[engineKey]?.detail = "Typed into HeyClicky; confirming delivery (retries for up to 10 minutes)."
                    record("define done follow-up to “\(task.name)” saved for retry — round \(round) counted")
                    return true
                }
                if !tasks.restoreProgress(previous, for: task.id) {
                    record("define done: couldn't release the unused round for “\(task.name)” — it stays counted")
                }
                engine.recordFailure(engineKey, reason: "HeyClicky didn't confirm the message; retrying this task after a short backoff while other tasks continue.")
                saveEngine()
                record("define done couldn't send to “\(task.name)” — backing off this task and continuing with the next")
                continue
            }
        }
        if let task = original.selectedTask {
            let scan = await Worker.run { ClickyScanner(config: config).scan() }
            _ = await selectTask(task, from: scan, config: config)
        }
        if pendingMessage == nil, let previousApp, previousApp.bundleIdentifier.map({ !config.clickyBundleIDs.contains($0) }) ?? true {
            previousApp.activate()
        }
        return sent
    }

    @discardableResult
    private func saveTaskAudits() -> Bool {
        do {
            try JSONEncoder().encode(taskAuditStates).write(to: taskAuditURL, options: .atomic)
            return true
        } catch {
            record("couldn't persist HeyClicky task-audit history: \(error.localizedDescription)")
            return false
        }
    }
    private func waitForComposer(config: Config, requireSidebar: Bool = false) async -> ScanResult? {
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let scan = await Worker.run { ClickyScanner(config: config).scan() }
            let expandedTaskWindow = scan.chatWindow != nil && scan.composer != nil
                && (scan.showSidebar != nil || scan.chatButtons.contains(where: { TaskRow.parse($0.label) != nil }))
            if requireSidebar ? expandedTaskWindow : scan.composer != nil { return scan }
        }
        return nil
    }

    /// Moves the cursor to the notch so HeyClicky expands its panel, waits until `until` matches, runs `act` while the
    /// panel is still open, then puts the cursor back. Returns the matching scan.
    private func hoverNotch(config: Config, until: @escaping (ScanResult) -> Bool,
                            act: @escaping (ScanResult) -> Void = { _ in }) async -> ScanResult? {
        var match: ScanResult?
        await withOverlayHidden {
            match = await Worker.run {
                let original = CGEvent(source: nil)?.location
                InputSynth.move(to: Self.notchPoint())
                var found: ScanResult?
                for _ in 0..<6 where found == nil {
                    usleep(400_000)
                    let scan = ClickyScanner(config: config).scan()
                    if until(scan) { found = scan }
                }
                if let found { act(found) }
                usleep(150_000)
                if let original { InputSynth.move(to: original) }
                return found
            }
        }
        return match
    }

    // MARK: Accidental interrupt → apologise and ask HeyClicky to continue

    /// If you take over mid-drive by mistake, HeyClicky hands control back ("Ok, it's all yours"). In cruise mode,
    /// Cruise Control notices that line and sends a short apology so the task resumes. Only fires while you're idle,
    /// so it never fights you when you're actually at the desk working.
    private func handleInterrupt(_ result: ScanResult, config: Config) async -> Bool {
        guard config.resumeAfterInterrupt, config.mode == .cruise else { return false }
        guard Self.idleSeconds() >= config.awayIdleSeconds else { return false }

        var conversation = result.conversation
        if conversation.isEmpty {
            // No chat window open: peek at the notch panel (we're already idle) to read the latest lines.
            guard Date().timeIntervalSince(lastStallProbeAt) > config.stallCheckMinutes * 60 else { return false }
            lastStallProbeAt = Date()
            guard let peek = await hoverNotch(config: config, until: { !$0.conversation.isEmpty }) else { return false }
            conversation = peek.conversation
        }
        guard let handoff = Matcher.handoffLine(in: Array(conversation.suffix(6)), config: config) else { return false }

        let now = Date()
        let fingerprint = Matcher.normalize(handoff)
        // One apology per hand-back: don't re-send while the same line is still the latest.
        guard fingerprint != lastInterruptFingerprint || now.timeIntervalSince(lastInterruptAt) > 1800 else { return true }

        let task = result.lastCard?.task
            ?? result.chatButtons.compactMap({ TaskRow.parse($0.label)?.name }).first
            ?? "the current task"
        let limits = ReportGate.Limits(config: config)
        guard nudgeLimiter.allow(task: task, now: now, maxPerHour: config.maxNudgesPerTaskPerHour),
              gate.canContinue(now: now, limits: limits) else { return false }

        lastInterruptFingerprint = fingerprint
        lastInterruptAt = now
        nudgeLimiter.record(task: task, at: now)
        gate.recordContinue(at: now)
        saveBudget()
        lastActionAt = now
        record("looks like you interrupted “\(task)” by mistake — apologising and asking it to continue")

        let previousApp = NSWorkspace.shared.frontmostApplication
        guard var chat = await revealChat(config: config) else {
            record("couldn't open heyclicky's chat window — apology not sent")
            return true
        }
        guard let selected = await selectTask(task, from: chat, config: config) else { return true }
        chat = selected
        guard recoveryAllowed(chat) else { return true }
        guard let composer = chat.composer else {
            record("couldn't find heyclicky's chat box — apology not sent")
            return true
        }
        if await send(config.interruptedNudge, via: composer, task: task) {
            stats.continued += 1
            record("told “\(task)” to keep going after the accidental interrupt")
        } else {
            record("failed to send the apology on “\(task)”")
        }
        if pendingMessage == nil, let previousApp, previousApp.bundleIdentifier.map({ !config.clickyBundleIDs.contains($0) }) ?? true {
            previousApp.activate()
        }
        return true
    }

    // MARK: "Interrupted · It was cut off before it finished" → polite bump

    /// Prefer the task's own Retry control over sending a new message. Failed attempts never consume nudge budget.
    private func handleInterruptedCards(_ result: ScanResult, config: Config) async -> Bool {
        guard config.resumeAfterInterrupt, config.autoContinueReports, config.mode == .cruise else { return false }
        let now = Date()
        var cards = result.interrupted
        if cards.isEmpty {
            guard Self.idleSeconds() >= config.awayIdleSeconds,
                  now.timeIntervalSince(lastInterruptedProbeAt) > config.stallCheckMinutes * 60 else { return false }
            lastInterruptedProbeAt = now
            cards = await hoverNotch(config: config, until: { !$0.interrupted.isEmpty })?.interrupted ?? []
        }
        guard let card = cards.first(where: {
            !taskRecovery.isStopped(task: $0.task)
                && !hasSavedDefinition(task: $0.task)
                && now.timeIntervalSince(lastInterruptedBump[$0.task] ?? .distantPast) >= 5
        }) else {
            return false
        }
        let task = card.task
        let source = ClickyTaskStore.shared
        await source.refresh(measure: false)
        let liveTasks = source.tasks.filter { Matcher.normalize($0.name) == Matcher.normalize(task) }
        guard source.loadError == nil, liveTasks.count == 1, liveTasks.first?.dismissed == false,
              !taskRecovery.isStopped(task: task) else { return false }
        let limits = ReportGate.Limits(config: config)
        guard nudgeLimiter.allow(task: task, now: now, maxPerHour: config.maxNudgesPerTaskPerHour),
              gate.canContinue(now: now, limits: limits) else { return false }

        lastInterruptedBump[task] = now
        let previousApp = NSWorkspace.shared.frontmostApplication
        defer {
            if pendingMessage == nil, let previousApp, previousApp.bundleIdentifier.map({ !config.clickyBundleIDs.contains($0) }) ?? true {
                previousApp.activate()
            }
        }
        var chat = await Worker.run { ClickyScanner(config: config).scan() }
        if chat.selectedTask.map({ Matcher.normalize($0) == Matcher.normalize(task) }) != true {
            guard Self.idleSeconds() >= config.awayIdleSeconds else { return false }
            guard let opened = await revealChat(config: config),
                  let selected = await selectTask(task, from: opened, config: config) else { return false }
            chat = selected
        }
        guard recoveryAllowed(chat), store.config.mode == .cruise,
              store.config.resumeAfterInterrupt, store.config.autoContinueReports else { return false }

        var retried = false
        if let retry = chat.interrupted.first(where: { $0.task == task && $0.retry != nil })?.retry {
            retried = await Worker.run { AX.press(retry) }
        } else if card.retry == nil, Self.idleSeconds() >= config.awayIdleSeconds {
            _ = await hoverNotch(config: config, until: { $0.interrupted.contains { $0.task == task && $0.retry != nil } }) { scan in
                guard scan.selectedTask.map({ Matcher.normalize($0) == Matcher.normalize(task) }) == true,
                      !TaskRecovery.isStopped(scan.selectedStatus),
                      !TaskRecovery.isStopped(scan.latestTurnStatus) else { return }
                if let retry = scan.interrupted.first(where: { $0.task == task })?.retry { retried = AX.press(retry) }
            }
        }
        var recovered = false
        if retried {
            try? await Task.sleep(nanoseconds: 700_000_000)
            let after = await Worker.run { ClickyScanner(config: config).scan() }
            recovered = after.selectedTask == chat.selectedTask
                && !after.interrupted.contains(where: { $0.task == task && $0.retry != nil })
            record(recovered ? "pressed Retry on “\(task)” — prompt cleared" : "Retry on “\(task)” is still pending — will retry")
        } else if card.retry != nil {
            record("couldn't press Retry on “\(task)” — will retry without consuming continuation budget")
        } else if Self.idleSeconds() >= config.awayIdleSeconds, let composer = chat.composer {
            recovered = await send(config.interruptedCardNudge, via: composer, task: task)
            record(recovered ? "asked “\(task)” to pick up where it left off" : "couldn't send recovery to “\(task)” — will retry")
        }
        if recovered {
            nudgeLimiter.record(task: task, at: Date())
            gate.recordContinue(at: Date())
            saveBudget()
            lastActionAt = Date()
            stats.continued += 1
        }
        return recovered || retried
    }

    // MARK: VS Code pending-request alerts

    private func tickPendingVSCodeAlerts() {
        guard drivingTaskName == nil else { return }
        let config = store.config
        guard config.vscodeRequestAlertsEnabled else {
            pendingVSCodeAlerts = []
            pendingVSCodeAlertFirstSeen.removeAll()
            pendingVSCodeAlertLastSeen.removeAll()
            return
        }
        guard axTrusted else {
            pendingVSCodeAlerts = []
            pendingVSCodeAlertFirstSeen.removeAll()
            pendingVSCodeAlertLastSeen.removeAll()
            return
        }
        guard !pendingVSCodeAlertScanBusy,
              Date().timeIntervalSince(lastPendingVSCodeAlertScanAt) >= max(10, config.vscodeCheckSeconds) else { return }
        lastPendingVSCodeAlertScanAt = Date()
        pendingVSCodeAlertScanBusy = true
        Task {
            let found = await Worker.scanVSCode { VSCodeScanner(config: config).pendingRequestNotices() }
            let now = Date()
            guard store.config.vscodeRequestAlertsEnabled, axTrusted else {
                pendingVSCodeAlerts = []
                pendingVSCodeAlertFirstSeen.removeAll()
                pendingVSCodeAlertLastSeen.removeAll()
                pendingVSCodeAlertScanBusy = false
                return
            }
            let foundByID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
            for notice in found {
                if pendingVSCodeAlertFirstSeen[notice.id] == nil { pendingVSCodeAlertFirstSeen[notice.id] = now }
                pendingVSCodeAlertLastSeen[notice.id] = now
            }
            // Give AX a brief recovery window if VS Code rebuilds its accessibility tree during a chat update.
            var retained = foundByID
            for old in pendingVSCodeAlerts where retained[old.id] == nil {
                if now.timeIntervalSince(pendingVSCodeAlertLastSeen[old.id] ?? .distantPast) < 4 {
                    retained[old.id] = old
                }
            }
            let liveIDs = Set(retained.keys)
            pendingVSCodeAlertFirstSeen = pendingVSCodeAlertFirstSeen.filter { liveIDs.contains($0.key) }
            pendingVSCodeAlertLastSeen = pendingVSCodeAlertLastSeen.filter { liveIDs.contains($0.key) }
            pendingVSCodeAlerts = retained.values.filter { notice in
                guard notice.automaticallyReviewable, let key = notice.requestKey else { return true }
                let firstSeen = pendingVSCodeAlertFirstSeen[notice.id] ?? now
                if let review = reviews[key] {
                    if review.verdict?.safe == false { return true }
                    let delay = review.verdict?.safe == true ? 8.0 : 5.0
                    return now.timeIntervalSince(review.at) >= delay
                }
                // Eligible requests get time for the existing auto-review path to decide. Failed or stalled reviews
                // become visible after the grace period; alerts never press an approval control.
                return !vscodeBusy && now.timeIntervalSince(firstSeen) >= 6
            }.sorted { $0.workspace == $1.workspace ? $0.title < $1.title : $0.workspace < $1.workspace }
            pendingVSCodeAlertScanBusy = false
        }
    }

    // MARK: VS Code chat tool confirmations → Ollama safety check → Allow Once

    private func tickVSCode() {
        let config = store.config
        guard config.vscodeApprovalsActive, axTrusted, !vscodeBusy, !modelBusy,
              Date().timeIntervalSince(lastVSCodeCheckAt) >= max(3, config.vscodeCheckSeconds) else { return }
        lastVSCodeCheckAt = Date()
        vscodeBusy = true
        Task {
            _ = await handleVSCode(config: config)
            vscodeBusy = false
        }
    }

    func approveVSCodeSidebar(key: String) async -> Bool {
        guard store.config.vscodeApprovalsActive, axTrusted else {
            record("vscode: sidebar check requires Cruise mode, explicit VS Code opt-in and Accessibility permission")
            return false
        }
        let count = stats.vscodeApproved
        _ = await handleVSCode(config: store.config, onlyKey: key)
        return stats.vscodeApproved > count
    }

    private func handleVSCode(config: Config, onlyKey: String? = nil, permitAction: () -> Bool = { true }) async -> Bool {
        guard store.config.vscodeApprovalsActive, drivingTaskName == nil else { return false }
        let now = Date()
        let pendingRequests = await Worker.scanVSCode { VSCodeScanner(config: config).scanAll() }
            .sorted { (approvalAttempts[$0.key] ?? .distantPast) < (approvalAttempts[$1.key] ?? .distantPast) }
        for pending in pendingRequests where pending.writeMetadataOnly && !config.vscodeAllowWriteMetadata {
            if now.timeIntervalSince(writePolicyHolds[pending.key] ?? .distantPast) >= 60 {
                if writePolicyHolds.count > 300 { writePolicyHolds.removeAll() }
                writePolicyHolds[pending.key] = now
                record("vscode: file edit/create approval held — full diff unavailable. Enable “allow file edits without a readable diff” in Settings → Automation to review file/action metadata instead.")
            }
        }
        for pending in pendingRequests where pending.toolPermission && !config.vscodeAllowToolPermissions {
            if now.timeIntervalSince(toolPolicyHolds[pending.key] ?? .distantPast) >= 60 {
                if toolPolicyHolds.count > 300 { toolPolicyHolds.removeAll() }
                toolPolicyHolds[pending.key] = now
                record("vscode: tool permission held — enable “allow tool permissions (including session grants)” in Settings → Automation to review tool/provider identity and grant scope.")
            }
        }
        for pending in pendingRequests where pending.urlFetch && config.vscodeURLFetchPolicy == .hold {
            if now.timeIntervalSince(urlPolicyHolds[pending.key] ?? .distantPast) >= 60 {
                if urlPolicyHolds.count > 300 { urlPolicyHolds.removeAll() }
                urlPolicyHolds[pending.key] = now
                record("vscode: URL fetch held — Settings → Automation → URL fetches is set to leave them for you.")
            }
        }
        guard let pending = pendingRequests.first(where: { pending in
            if pending.urlFetch && config.vscodeURLFetchPolicy == .hold { return false }
            if pending.writeMetadataOnly && !config.vscodeAllowWriteMetadata { return false }
            if pending.toolPermission && !config.vscodeAllowToolPermissions { return false }
            if let onlyKey, pending.key != onlyKey || pending.sidebarThread == nil { return false }
            guard now.timeIntervalSince(approvalAttempts[pending.key] ?? .distantPast) >= 5 else { return false }
            if let cached = reviews[pending.key] {
                return cached.verdict?.safe != false && (cached.verdict != nil || now.timeIntervalSince(cached.at) >= 60)
            }
            return true
        }) else { return false }
        let key = pending.key
        approvalAttempts[key] = now
        let short = pending.request.replacingOccurrences(of: "\n", with: " ").prefix(110)
        let verdict: ApprovalReview.Verdict
        if let cached = reviews[key]?.verdict {
            verdict = cached
        } else if pending.urlFetch && config.vscodeURLFetchPolicy == .allowAll {
            verdict = ApprovalReview.Verdict(safe: true, reason: "URL fetches allowed by your setting")
            remember(key, verdict)
        } else if let reason = ApprovalReview.hardBlockReason(pending.request) {
            verdict = ApprovalReview.Verdict(safe: false, reason: reason)
            remember(key, verdict)
            stats.vscodeHeldForReview += 1
            record("vscode: left for you — \(reason): \(short)")
            holdForSafetyReview(pending, reason: reason)
            return true
        } else {
            record("vscode: reviewing with ollama → \(short)")
            do {
                let review = try await Ollama.reviewApproval(pending.request, config: config)
                verdict = review.verdict
                remember(key, verdict)
                if !verdict.safe {
                    stats.vscodeHeldForReview += 1
                    record("vscode: left for you — ollama (\(review.model)) flagged it: \(verdict.reason)")
                    holdForSafetyReview(pending, reason: verdict.reason)
                    return true
                }
            } catch {
                remember(key, nil)
                record("vscode: couldn't review (\(error.localizedDescription)) — leaving it for you")
                return true
            }
        }

        // Only press if the very same request is still waiting (the review can take a few seconds).
        await refreshUsageGuard()
        guard drivingTaskName == nil,
              let still = await Worker.scanVSCode({ VSCodeScanner(config: config).scanAll().first { $0.key == key } }),
              still.request == pending.request, store.config.vscodeApprovalsActive,
              !still.writeMetadataOnly || store.config.vscodeAllowWriteMetadata,
              !still.toolPermission || store.config.vscodeAllowToolPermissions,
              !still.urlFetch || store.config.vscodeURLFetchPolicy != .hold,
              !still.urlFetch || config.vscodeURLFetchPolicy != .allowAll || store.config.vscodeURLFetchPolicy == .allowAll,
              drivingTaskName == nil, permitAction() else { return true }
        approvalAttempts[key] = Date()
        let pressed = await pressVSCodeConfirmation(still, config: config, permitAction: permitAction)
        if pressed {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let resolved = await Worker.run { VSCodeScanner(config: config).isResolved(still) }
            if resolved == nil {
                record("vscode: owning sidebar row unavailable after pressing — success not verified: \(short)")
            } else if resolved == false {
                record("vscode: approval still pending after pressing — will retry: \(short)")
                return false
            } else {
                stats.vscodeApproved += 1
                lastActionAt = Date()
                record("vscode: \(still.allowLabel.lowercased()) → \(short) (\(verdict.reason))")
            }
        } else {
            record("vscode: couldn't press “\(still.allowLabel)” — will retry other pending requests first")
            return false
        }
        return true
    }

    private func pressVSCodeConfirmation(_ pending: VSCodeConfirmation, config: Config,
                                        permitAction: () -> Bool) async -> Bool {
        guard drivingTaskName == nil, store.config.vscodeApprovalsActive, permitAction() else { return false }
        let permission = vscodeApprovalPermission
        if await Worker.run({ permission.allowed && AX.press(pending.allow, requiresUserPause: false) }) { return true }
        // Inline sidebar approvals stay background-only. A dialog fallback must not fight active input.
        guard store.config.vscodeAutoBumpChatKeys.contains(where: {
                  TaskPlanning.vscodeAutoBumpEnabled(chatKey: $0, config: store.config)
              }),
              !safetyReviewInProgress, permission.allowed, pending.sidebarThread == nil, !busy,
              Self.idleSeconds() >= config.awayIdleSeconds else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(pending.window, &pid) == .success else { return false }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let interaction = InputSynth.UserInteractionWatch()
        defer {
            interaction.stop()
            if !interaction.interrupted { previousApp?.activate() }
        }
        ScreenControlActivity.announce("Opening a VS Code approval")
        NSRunningApplication(processIdentifier: pid)?.activate()
        guard AXUIElementPerformAction(pending.window, kAXRaiseAction as CFString) == .success else { return false }
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !interaction.interrupted, permitAction(), store.config.vscodeApprovalsActive,
              !store.config.usageCutoffReached,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        var clicked = false
        await withOverlayHidden {
            guard !interaction.interrupted, permitAction(), store.config.vscodeApprovalsActive,
                  !pending.writeMetadataOnly || store.config.vscodeAllowWriteMetadata,
                  !pending.toolPermission || store.config.vscodeAllowToolPermissions else { return }
            clicked = await Worker.run {
                guard permission.allowed,
                      let fresh = VSCodeScanner(config: config).scanAll().first(where: { $0.key == pending.key }),
                      fresh.request == pending.request, AX.isEnabled(fresh.allow),
                      let frame = AX.frame(fresh.allow), let bounds = AX.frame(fresh.window),
                      bounds.contains(frame) else { return false }
                let point = CGPoint(x: frame.midX, y: frame.midY)
                guard permission.allowed, !interaction.interrupted,
                      Self.idleSeconds() >= config.awayIdleSeconds,
                      AX.isUnderPointer(fresh.allow, at: point) else { return false }
                return InputSynth.click(at: point, restoreCursor: true, shouldContinue: {
                    permission.allowed && !interaction.interrupted
                })
            }
        }
        return clicked
    }

    private func inspectVSCodeThreads(config: Config) async {
        guard config.mode == .cruise, store.config.vscodeAutoApprove,
              Self.idleSeconds() >= config.awayIdleSeconds,
              Date().timeIntervalSince(lastVSCodeThreadProbeAt) >= 15 else { return }
        lastVSCodeThreadProbeAt = Date()
        let threads = await Worker.scanVSCode { VSCodeScanner(config: config).attentionThreads() }
        let now = Date()
        attentionThreadMarks = attentionThreadMarks.filter { now.timeIntervalSince($0.value) < 300 }
        for thread in threads.prefix(3) {
            guard store.config.mode == .cruise, store.config.vscodeAutoApprove else { return }
            let mark = "\(thread.title)|\(thread.rowLabel)"
            guard attentionThreadMarks[mark] == nil else { continue }
            attentionThreadMarks[mark] = now
            let previousApp = NSWorkspace.shared.frontmostApplication
            let interaction = InputSynth.UserInteractionWatch()
            defer { interaction.stop() }
            guard await openVSCodeRow(thread.row, window: thread.window) else {
                record("vscode: couldn't open attention thread “\(thread.title)”")
                continue
            }
            do {
                try await Task.sleep(nanoseconds: 700_000_000)
                let selected = await Worker.run { VSCodeScanner(config: config).selectedThread(in: thread.window) }
                guard selected == thread.title, !interaction.interrupted else {
                    record("vscode: selected thread could not be verified — no request approved")
                    if !interaction.interrupted { _ = await openVSCodeRow(thread.previousRow, window: thread.window) }
                    continue
                }
                record("vscode: inspecting attention thread “\(thread.title)”")
                _ = await handleVSCode(config: config, permitAction: {
                    !interaction.interrupted && self.store.config.mode == .cruise
                })
            } catch {
                record("vscode: thread inspection interrupted: \(error.localizedDescription)")
            }
            // Do not change the user's newly selected thread after they return to the keyboard or mouse.
            if !interaction.interrupted,
               await Worker.run({ VSCodeScanner(config: config).selectedThread(in: thread.window) }) == thread.title {
                if await openVSCodeRow(thread.previousRow, window: thread.window) == false {
                    record("vscode: couldn't restore “\(thread.previousTitle)”")
                }
                previousApp?.activate()
            }
        }
    }

    private func openVSCodeRow(_ row: AXUIElement, window: AXUIElement) async -> Bool {
        ScreenControlActivity.announce("Opening a VS Code thread")
        if AX.press(row) { return true }
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return false }
        NSRunningApplication(processIdentifier: pid)?.activate()
        guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else { return false }
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let frame = AX.frame(row), let bounds = AX.frame(window),
              bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return false }
        return await mouseClick(on: row)
    }

    private func remember(_ key: String, _ verdict: ApprovalReview.Verdict?) {
        if reviews.count > 300 { reviews.removeAll() }
        reviews[key] = Review(verdict: verdict, at: Date())
    }

    private func tickModelRouting() {
        guard !safetyReviewInProgress else { return }
        if !store.config.vscodeTaskBumps && store.config.vscodeAutoBumpChatKeys.isEmpty {
            vscodeFollowUpStatus = "Off · no follow-ups will be sent."
        }
        if !store.config.autoSelectVSCodeModel { vscodeModelStatus = "Off · no model changes will be made." }
        let config = store.config
        let hasVSCodeTaskWork = config.vscodeAutoBumpChatKeys.contains {
            TaskPlanning.vscodeAutoBumpEnabled(chatKey: $0, config: config)
        }
        let taskAutomationAllowed = config.mode == .cruise || (config.mode == .manual && hasVSCodeTaskWork)
        guard taskAutomationAllowed, !config.usageCutoffReached else {
            vscodeFollowUpStatus = "Paused · requires Cruise mode and available usage."
            vscodeModelStatus = "Paused · requires Cruise mode and available usage."
            return
        }
        guard hasVSCodeTaskWork,
              axTrusted, !modelBusy, !busy,
              Date().timeIntervalSince(lastModelCheckAt) >= 300 else { return }
        lastModelCheckAt = Date()
        modelBusy = true
        Task {
            defer { modelBusy = false }
            let config = store.config
            if config.autoSelectVSCodeModel && config.mode == .cruise { await routeModel(config: config) }
            await bumpChat(config: config)
        }
    }

    func resetVSCodeTaskProgress(for chatKey: String) {
        vscodeInspectMarks[chatKey] = nil
        var state = bumpStates[chatKey] ?? ChatBump.State()
        state.answeredTranscript = ""
        state.lastAttempt = .distantPast
        bumpStates[chatKey] = state
        store.config.vscodeAutoBumpRounds[chatKey] = 0
        if !saveBumpStates() {
            vscodeFollowUpStatus = "Paused · couldn't reset saved progress for the changed Done definition."
        }
    }

    /// Carries Done, folder and Auto-bump settings saved under a chat's old workspace/window-scoped key to its current key.
    func adoptLegacyVSCodeKeys(_ sessions: [VSCodeVisibleSession]) {
        var config = store.config
        var adopted: [String] = []
        for session in sessions where !session.ambiguous {
            let renamed = vscodeSessionsSeen.filter { old in
                old.appPID == session.appPID && CFEqual(old.window, session.window)
                    && CFEqual(old.row, session.row) && old.key != session.key
                    && !sessions.contains(where: { current in current.key == old.key })
            }
            if renamed.count == 1, let old = renamed.first,
               config.adoptVSCodeSettings(from: old.key, to: session.key) {
                adopted.append(session.title)
                record("vscode: verified same session row renamed “\(old.title)” → “\(session.title)”; carrying its settings forward")
            }
            if let legacy = session.legacyKey, config.adoptVSCodeSettings(from: legacy, to: session.key) {
                adopted.append(session.title)
            }
        }
        guard !adopted.isEmpty else { return }
        store.config = config
        record("vscode: moved saved task settings to stable session keys for \(adopted.map { "“\($0)”" }.joined(separator: ", "))")
    }

    private func bumpChat(config: Config) async {
        guard config.mode != .rest else {
            vscodeFollowUpStatus = "Paused · Rest mode suspends VS Code task follow-ups."
            return
        }
        var config = config
        if !config.vscodeAutoBumpChatKeys.isEmpty || !config.vscodeDefinitionsOfDone.isEmpty {
            let sessions = await Worker.scanVSCode { VSCodeScanner(config: config).visibleTaskSessions() }
            guard !sessions.isEmpty else {
                vscodeFollowUpStatus = "Unavailable · no readable VS Code Sessions rows were discovered."
                return
            }
            adoptLegacyVSCodeKeys(sessions)
            vscodeSessionsSeen = sessions
            config = store.config
            var inspected = false
            let work = sessions.filter {
                TaskPlanning.vscodeAutoBumpEnabled(chatKey: $0.key, config: config)
            }
            for session in work {
                guard !safetyReviewInProgress else { return }
                guard TaskPlanning.vscodeAutoBumpEnabled(chatKey: session.key, config: store.config) else { continue }
                guard !session.ambiguous else {
                    record("vscode auto-bump held: ambiguous session \(session.title) in \(session.workspaceTitle ?? "unknown workspace")")
                    continue
                }
                let mark = "\(session.state)|\(session.updated ?? "")"
                if let last = vscodeInspectMarks[session.key], last.mark == mark,
                   Date().timeIntervalSince(last.at) < 300 {
                    inspected = true
                    continue
                }
                vscodeInspectMarks[session.key] = (mark, Date())
                let previousThread = await Worker.scanVSCode { VSCodeScanner(config: config).selectedThread(in: session.window) }
                let switching = previousThread != session.title
                let interaction = InputSynth.UserInteractionWatch()
                if switching {
                    ScreenControlActivity.announce("Preparing to examine VS Code: \(session.title). Pause typing briefly; input cancels this switch.")
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if interaction.interrupted || Task.isCancelled {
                        interaction.stop()
                        vscodeInspectMarks[session.key] = nil
                        vscodeTaskStatuses[session.key] = "Examination deferred because you are using the computer. Your place was preserved."
                        break
                    }
                }
                guard !safetyReviewInProgress,
                      TaskPlanning.vscodeAutoBumpEnabled(chatKey: session.key, config: store.config) else {
                    interaction.stop()
                    vscodeInspectMarks[session.key] = nil
                    continue
                }
                // Exact-session AX selection does not activate or raise VS Code.
                let result: Result<VSCodeModelChat, Error> = await Worker.scanVSCode {
                    Result { try VSCodeModels.inspect(config: config, session: session) }
                }
                if switching, let previousThread {
                    let restored = await Worker.scanVSCode {
                        let scanner = VSCodeScanner(config: config)
                        guard scanner.selectedThread(in: session.window) == session.title else { return true }
                        return scanner.restoreThread(titled: previousThread, in: session.window)
                    }
                    if !restored { record("vscode examination: couldn't restore “\(previousThread)”") }
                }
                interaction.stop()
                if case .success(let chat) = result, chat.key == session.key {
                    inspected = true
                    let usedModel = await bumpChat(chat: chat, config: config)
                    if usedModel, !TaskPlanning.vscodeAutoBumpEnabled(chatKey: session.key, config: config) {
                        break
                    }
                } else {
                    let reason: String
                    if case .failure(let error) = result { reason = error.localizedDescription } else { reason = "the read chat had a different key" }
                    vscodeTaskStatuses[session.key] = "Session unreadable · \(reason)"
                    record("vscode auto-bump held: exact session could not be read · \(session.title) · \(reason)")
                }
            }
            if !inspected {
                let visible = Set(sessions.map(\.key))
                let missing = config.vscodeAutoBumpChatKeys.filter { !visible.contains($0) }
                for key in missing {
                    vscodeTaskStatuses[key] = "Not visible · open this chat in VS Code's Sessions list so Cruise can find it."
                }
                vscodeFollowUpStatus = missing.count == config.vscodeAutoBumpChatKeys.count
                    ? "Paused · opted-in chats aren't in VS Code's visible Sessions list (renamed, archived, or scrolled away)."
                    : "Paused · opted-in sessions are not uniquely readable; no other chat was selected."
            }
            return
        }
        guard let chat = await Worker.run({ VSCodeModels.scan(config: config) }) else {
            vscodeFollowUpStatus = "Unavailable · no unique readable foreground VS Code chat; no session was selected."
            return
        }
        await bumpChat(chat: chat, config: config)
    }

    /// Returns true when local Ollama was asked to review this chat.
    @discardableResult
    private func bumpChat(chat: VSCodeModelChat, config: Config) async -> Bool {
        vscodeModelUsed = false
        await reviewAndBumpChat(chat: chat, config: config)
        return vscodeModelUsed
    }

    private func reviewAndBumpChat(chat: VSCodeModelChat, config: Config) async {
        let taskAutoBump = TaskPlanning.vscodeAutoBumpEnabled(chatKey: chat.key, config: config)
        let previousStatus = vscodeTaskStatuses[chat.key]
        defer {
            vscodeTaskStatuses[chat.key] = vscodeFollowUpStatus
            if taskAutoBump, previousStatus != vscodeFollowUpStatus {
                record("vscode auto-bump · \(chat.taskTitle): \(vscodeFollowUpStatus)")
            }
        }
        let expectedPlan = config.vscodeTaskPlans[chat.key] ?? TaskPlan()
        let expectedProject = config.vscodeTaskProjects[chat.key] ?? TaskProject()
        let savedDone = DefinitionOfDone.normalized(config.vscodeDefinitionsOfDone[chat.key])
        guard savedDone != nil else {
            vscodeFollowUpStatus = "No Done definition. No draft or message is permitted for this task."
            return
        }
        // Chats with Done but without Auto-bump are still examined so their draft is ready; nothing is typed.
        let draftOnly = !taskAutoBump
        guard !draftOnly || (savedDone != nil && config.mode != .rest) else { return }
        if draftOnly, let cached = vscodeDrafts[chat.key], cached.definition == savedDone,
           cached.transcriptTail == String(chat.transcript.suffix(300)) {
            vscodeFollowUpStatus = previousStatus ?? "Draft ready · press Send, or turn on Auto-bump."
            return
        }
        let doneDefinition = DefinitionOfDone.normalized(config.vscodeDefinitionsOfDone[chat.key])
        guard !taskAutoBump || doneDefinition != nil else {
            vscodeFollowUpStatus = "Paused · save a Done definition for this VS Code chat before enabling Auto-bump."
            return
        }
        let autoRounds = config.vscodeAutoBumpRounds[chat.key] ?? 0
        let maxAutoRounds = min(max(1, config.maxDefinitionRounds), DefinitionOfDone.maxRounds)
        guard !taskAutoBump || autoRounds < maxAutoRounds else {
            vscodeFollowUpStatus = "Paused · this chat reached its Auto-bump round limit. Review it before continuing."
            return
        }
        let now = Date()
        var state = bumpStates[chat.key] ?? ChatBump.State()
        let changed = state.transcript != chat.transcript
        state.observe(chat.transcript, now: now)
        bumpStates[chat.key] = state
        if changed, !saveBumpStates() { return }
        // Auto-bump owns the composer: a leftover draft is replaced by the fresh review's follow-up.
        vscodeFollowUpStatus = chat.running ? "Waiting · the detected chat is running or needs approval."
            : !chat.draft.isEmpty && !taskAutoBump ? "Waiting · your composer draft is preserved."
            : "Watching a verified chat · waiting for quiet time, idle input and cooldown."
        if draftOnly {
            guard !chat.running else { return }
        } else {
            guard !chat.running, chat.draft.isEmpty || taskAutoBump,
                  state.answeredTranscript.isEmpty || !VSCodeChatIdentity.sameLatestTurn(state.answeredTranscript, chat.transcript),
                  (taskAutoBump || Self.idleSeconds() >= config.awayIdleSeconds),
                  state.eligible(now: now,
                                 quietMinutes: taskAutoBump ? 0 : config.vscodeBumpQuietMinutes,
                                 cooldownMinutes: taskAutoBump ? 0 : config.vscodeBumpCooldownMinutes) else { return }
            state.lastAttempt = now
            bumpStates[chat.key] = state
            guard saveBumpStates() else {
                vscodeFollowUpStatus = "Paused · follow-up history could not be saved."
                return
            }
        }
        let engineKey = chat.key
        engineActivity = ("Examining VS Code “\(chat.taskTitle)” with local Ollama", engineKey, Date())
        defer { if engineActivity?.key == engineKey { engineActivity = nil } }
        do {
            vscodeFollowUpStatus = "Reviewing fresh session evidence and drafting with local Ollama…"
            vscodeTaskStatuses[chat.key] = vscodeFollowUpStatus
            var transcript = doneDefinition.map {
                """
                Saved Done definition for this VS Code task:
                \($0)

                Current chat transcript:
                \(chat.transcript)
                """
            } ?? chat.transcript
            if let project = config.vscodeTaskProjects[chat.key], project.directoryPath != nil {
                let plan = config.vscodeTaskPlans[chat.key] ?? TaskPlan()
                transcript += "\n\nConfirmed repository and delivery policy:\n\(TaskWorkflow.instructions(project: project, plan: plan, agentName: "VS Code") ?? "")"
            } else if taskAutoBump {
                transcript += "\n\nWorkspace is not confirmed. Do not invent a directory or branch; ask before any repository-specific step."
            }
            let system = doneDefinition == nil ? ChatBump.system : ChatBump.doneReviewSystem
            vscodeModelUsed = true
            let draft = try await Ollama.draftChatBump(transcript, config: config, system: system,
                                                      taskName: chat.key, latestReport: chat.transcript)
            let tail = String(chat.transcript.suffix(300))
            if let reason = TaskWorkflow.messageBlocker(project: expectedProject, plan: expectedPlan, requiresBuildLocation: false) {
                vscodeDrafts[chat.key] = nil
                vscodeFollowUpStatus = reason
                deriveAll(fresh: false)
                return
            }
            let cachedMessage: String? = draft.unfinished ? doneDefinition.map {
                TaskWorkflow.taskBumpMessage(
                    baseMessage: draft.message, taskName: chat.taskTitle, definition: $0,
                    project: config.vscodeTaskProjects[chat.key].flatMap { $0.directoryPath == nil ? nil : $0 } ?? TaskProject(),
                    plan: config.vscodeTaskPlans[chat.key] ?? TaskPlan(), agentName: "VS Code")
            } ?? draft.message : nil
            if let doneDefinition {
                vscodeDrafts[chat.key] = VSCodeEngineDraft(transcriptTail: tail, definition: doneDefinition,
                                                           unfinished: draft.unfinished, message: cachedMessage,
                                                           missing: [], at: Date(), evidence: chat.transcript)
            }
            if draftOnly {
                vscodeFollowUpStatus = draft.unfinished
                    ? "Draft ready \(Date().formatted(date: .omitted, time: .shortened)) · press Send, or turn on Auto-bump to send automatically."
                    : "Reviewed \(Date().formatted(date: .omitted, time: .shortened)) · the latest response appears to cover Done."
                record("vscode task engine · \(chat.taskTitle): \(draft.unfinished ? "draft ready (not auto-bump, not sent)" : "appears done")")
                deriveAll(fresh: false)
                return
            }
            guard draft.unfinished else {
                if let doneDefinition {
                    engine.holdForReview(chat.key, report: chat.transcript, definition: doneDefinition)
                    saveEngine()
                }
                if taskAutoBump { store.config.vscodeAutoBumpRounds[chat.key] = 0 }
                state.answeredTranscript = chat.transcript
                bumpStates[chat.key] = state
                guard saveBumpStates() else { return }
                vscodeFollowUpStatus = "Reviewed · no unfinished work found; nothing sent."
                record("vscode follow-up: no unfinished task identified — leaving the chat alone")
                return
            }
            if let doneDefinition,
               engine.isReviewOnly(chat.key, report: chat.transcript, definition: doneDefinition) {
                vscodeFollowUpStatus = "Examined for your review only. Nothing sent."
                return
            }
            guard (store.config.vscodeTaskBumps || TaskPlanning.vscodeAutoBumpEnabled(chatKey: chat.key, config: store.config)),
                  store.config.mode != .rest,
                  (store.config.mode == .cruise || TaskPlanning.vscodeAutoBumpEnabled(chatKey: chat.key, config: store.config)), !store.config.usageCutoffReached,
                  DefinitionOfDone.normalized(store.config.vscodeDefinitionsOfDone[chat.key]) == doneDefinition,
                  (store.config.vscodeTaskPlans[chat.key] ?? TaskPlan()) == expectedPlan,
                  (store.config.vscodeTaskProjects[chat.key] ?? TaskProject()) == expectedProject,
                  taskAutoBump || Self.idleSeconds() >= config.awayIdleSeconds else { return }
            let outgoingMessage: String
            if let doneDefinition {
                let confirmedProject = config.vscodeTaskProjects[chat.key].flatMap { $0.directoryPath == nil ? nil : $0 } ?? TaskProject()
                let plan = config.vscodeTaskPlans[chat.key] ?? TaskPlan()
                outgoingMessage = TaskWorkflow.taskBumpMessage(
                    baseMessage: draft.message, taskName: chat.taskTitle, definition: doneDefinition,
                    project: confirmedProject, plan: plan, agentName: "VS Code")
            } else {
                outgoingMessage = draft.message
            }
            let interaction = InputSynth.UserInteractionWatch()
            defer { interaction.stop() }
            if let doneDefinition,
               engine.alreadyDelivered(chat.key, definition: doneDefinition, message: outgoingMessage) {
                vscodeFollowUpStatus = "Held · this exact follow-up was already delivered. Review the latest response."
                vscodeTaskStatuses[chat.key] = vscodeFollowUpStatus
                return
            }
            // Persist before touching the composer: uncertain submissions must not be sent twice after a restart.
            if taskAutoBump { store.config.vscodeAutoBumpRounds[chat.key] = autoRounds + 1 }
            state.answeredTranscript = chat.transcript
            bumpStates[chat.key] = state
            guard saveBumpStates() else {
                vscodeFollowUpStatus = "Paused · delivery reservation could not be saved."
                return
            }
            vscodeFollowUpStatus = "Draft ready · sending to the verified exact session…"
            vscodeTaskStatuses[chat.key] = vscodeFollowUpStatus
            engineActivity = ("Sending the auto-bump to VS Code “\(chat.taskTitle)”", engineKey, Date())
            try await VSCodeModels.sendFollowUp(outgoingMessage, chat: chat, config: config, replaceDraft: taskAutoBump, shouldContinue: {
                (self.store.config.vscodeTaskBumps || TaskPlanning.vscodeAutoBumpEnabled(chatKey: chat.key, config: self.store.config))
                    && self.store.config.mode != .rest
                    && (self.store.config.mode == .cruise || TaskPlanning.vscodeAutoBumpEnabled(chatKey: chat.key, config: self.store.config))
                    && DefinitionOfDone.normalized(self.store.config.vscodeDefinitionsOfDone[chat.key]) == doneDefinition
                    && !(doneDefinition.map { self.engine.isReviewOnly(chat.key, report: chat.transcript, definition: $0) } ?? false)
                    && (self.store.config.vscodeTaskPlans[chat.key] ?? TaskPlan()) == expectedPlan
                    && (self.store.config.vscodeTaskProjects[chat.key] ?? TaskProject()) == expectedProject
                    && !self.store.config.usageCutoffReached && self.drivingTaskName == nil && !interaction.interrupted
            })
            stats.vscodeContinued += 1
            if let doneDefinition {
                engine.recordDelivery(chat.key, definition: doneDefinition, message: outgoingMessage)
            }
            vscodeFollowUpStatus = "Sent \(Date().formatted(date: .omitted, time: .shortened)) · exact follow-up confirmed in the same chat."
            engine.recordSent(engineKey, detail: vscodeFollowUpStatus)
            saveEngine()
            record("vscode follow-up sent: \(outgoingMessage.prefix(120))")
        } catch VSCodeModels.ModelError.notSent(let reason) {
            // Nothing reached the agent: release the delivery reservation so the next pass retries.
            if taskAutoBump { store.config.vscodeAutoBumpRounds[chat.key] = autoRounds }
            state.answeredTranscript = ""
            bumpStates[chat.key] = state
            saveBumpStates()
            vscodeFollowUpStatus = "Retrying · \(reason)"
            record("vscode follow-up not sent (will retry): \(reason)")
        } catch {
            vscodeFollowUpStatus = "Not confirmed · \(error.localizedDescription)"
            record("vscode follow-up unavailable: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func saveBumpStates() -> Bool {
        do {
            try JSONEncoder().encode(bumpStates).write(to: bumpStateURL, options: .atomic)
            return true
        } catch {
            record("couldn't persist chat follow-up history: \(error.localizedDescription)")
            return false
        }
    }

    private func routeModel(config: Config) async {
        guard let chat = await Worker.run({ VSCodeModels.scan(config: config) }) else {
            vscodeModelStatus = "Unavailable · bring one readable VS Code chat forward; split or unsupported chats are not driven."
            return
        }
        guard TaskPlanning.vscodeAutoBumpEnabled(chatKey: chat.key, config: store.config) else {
            vscodeModelStatus = "Paused · this task has not enabled Auto-bump."
            return
        }
        vscodeModelStatus = chat.running ? "Waiting · \(chat.model) is running or needs approval."
            : !chat.draft.isEmpty ? "Waiting · your composer draft is preserved."
            : "Watching \(chat.model) · idle-only switching; escalation requires confirmation."
        let now = Date()
        var state = modelStates[chat.key] ?? ModelRouting.State()
        let cheap = ModelRouting.normalize(chat.model) == ModelRouting.normalize(config.economyModel)
        if cheap && state.cheapSince == nil {
            state.cheapSince = now
            state.observedTranscript = chat.transcript
        } else if cheap {
            state.observe(chat.transcript)
        } else if state.cheapSince != nil {
            // A manually chosen model is an override, not an excuse to switch the user back.
            state.escalated = true
        }
        let changed = modelStates[chat.key] != state
        modelStates[chat.key] = state
        if changed { saveModelStates() }
        guard !chat.running, chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.idleSeconds() >= config.awayIdleSeconds else { return }

        var assessment: ModelRouting.Assessment?
        if cheap && !state.escalated && !state.progress.isEmpty,
           state.lastReview.map({ now.timeIntervalSince($0) >= config.modelReviewMinutes * 60 }) ?? true {
            state.lastReview = now
            do {
                assessment = try await Ollama.assessModelProgress(state.progress, config: config)
                if let assessment {
                    record("model review: \(assessment.failures) unresolved failures, regression \(assessment.regression), stalled \(assessment.stalled)")
                }
            } catch {
                record("model review unavailable — keeping \(chat.model): \(error.localizedDescription)")
            }
        }
        modelStates[chat.key] = state
        saveModelStates()
        guard store.config.autoSelectVSCodeModel,
              let target = ModelRouting.target(current: chat.model, state: state, assessment: assessment, now: now, config: config)
        else { return }
        if ModelRouting.normalize(target) != ModelRouting.normalize(config.economyModel) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Switch this task to \(target)?"
            alert.informativeText = """
            Cruise Control observed difficulty on \(chat.model).

            \(assessment?.evidence ?? "No supporting evidence")

            This may increase Copilot usage costs. Your conversation will be preserved. \
            Keeping the current model will postpone another suggestion for \(Int(config.modelSwitchCooldownMinutes)) minutes.
            """
            alert.addButton(withTitle: "Keep \(chat.model)")
            alert.addButton(withTitle: "Switch to \(target)")
            alert.buttons.first?.keyEquivalent = "\r"
            alert.buttons.last?.keyEquivalent = ""
            guard alert.runModal() == .alertSecondButtonReturn else {
                state.lastSwitch = Date()
                modelStates[chat.key] = state
                saveModelStates()
                record("model escalation not approved — keeping \(chat.model)")
                return
            }
            guard store.config.autoSelectVSCodeModel, store.config.mode == .cruise,
                  !store.config.usageCutoffReached else { return }
        }
        do {
            let interaction = InputSynth.UserInteractionWatch()
            defer { interaction.stop() }
            try await VSCodeModels.select(target, chat: chat, config: config, shouldContinue: {
                self.store.config.autoSelectVSCodeModel && self.store.config.mode == .cruise
                    && !self.store.config.usageCutoffReached && self.drivingTaskName == nil && !interaction.interrupted
            })
            stats.vscodeModelSwitches += 1
            vscodeModelStatus = "Verified · \(chat.model) → \(target) in the same chat."
            state.lastSwitch = Date()
            if ModelRouting.normalize(target) == ModelRouting.normalize(config.economyModel) {
                state.cheapSince = Date()
                state.observedTranscript = chat.transcript
                state.progress = ""
            } else {
                state.escalated = true
            }
            modelStates[chat.key] = state
            saveModelStates()
            record("model: \(chat.model) → \(target); same conversation preserved, next turn uses the selected model")
        } catch {
            vscodeModelStatus = "Not confirmed · \(error.localizedDescription)"
            record("model handoff failed — leaving the chat intact: \(error.localizedDescription)")
            // Avoid reopening an unavailable picker every polling cycle.
            state.lastSwitch = Date()
            modelStates[chat.key] = state
            saveModelStates()
        }
    }

    private func saveModelStates() {
        do {
            try JSONEncoder().encode(modelStates).write(to: modelStateURL, options: .atomic)
        } catch {
            record("couldn't persist model-routing history: \(error.localizedDescription)")
        }
    }

    // MARK: Quiet conversation → reply with Ollama

    /// HeyClicky finished a turn (often with a question, or a "done" card that isn't really done) and nothing has
    /// happened since. Reply once per stall so the work keeps going.
    private func handleStall(_ result: ScanResult, config: Config) async -> Bool {
        guard config.replyToStalls, config.autoContinueReports, config.mode != .manual else { return false }
        let now = Date()
        var conversation = result.conversation
        var card = result.lastCard
        if conversation.isEmpty {
            // Nothing readable: peek at the notch panel now and then, only while the user is away.
            guard now.timeIntervalSince(lastStallProbeAt) > config.stallCheckMinutes * 60,
                  Self.idleSeconds() >= config.awayIdleSeconds else { return false }
            lastStallProbeAt = now
            guard let peek = await hoverNotch(config: config, until: { !$0.conversation.isEmpty }) else { return false }
            conversation = peek.conversation
            card = peek.lastCard
        }
        stall.observe(conversation, now: now)
        // Anything still marked working (notch summary or sidebar) gets the longer, busy timeout.
        let working = (result.workingCount ?? 0) > 0
            || result.chatButtons.contains { TaskRow.parse($0.label).map { StallTracker.isBusy($0.status) } ?? false }
        let status = working ? "working" : card?.status
        // Once you've clearly been away for a while, drop the quiet thresholds so a stop gets nudged fast.
        let away = Self.idleSeconds() >= config.awayAfterMinutes * 60
        let quietMins = away ? config.awayStallMinutes : config.stallMinutes
        let busyQuietMins = away ? config.awayBusyStallMinutes : config.busyStallMinutes
        guard stall.isStalled(now: now, status: status, quietMinutes: quietMins,
                              busyQuietMinutes: busyQuietMins),
              Self.idleSeconds() >= config.awayIdleSeconds else { return false }

        let task = card?.task ?? "the current task"
        let limits = ReportGate.Limits(config: config)
        guard nudgeLimiter.allow(task: task, now: now, maxPerHour: config.maxNudgesPerTaskPerHour),
              gate.canContinue(now: now, limits: limits) else {
            if now.timeIntervalSince(lastStallSkipLogAt) > 600 {
                lastStallSkipLogAt = now
                record("heyclicky went quiet on “\(task)” — leaving it for you (nudge limit reached)")
            }
            return false
        }
        let quietMinutes = max(1, Int(now.timeIntervalSince(stall.changedAt) / 60))
        let lastLine = conversation.last { !$0.hasPrefix("— ") } ?? ""
        stall.markAnswered()
        nudgeLimiter.record(task: task, at: now)
        gate.recordContinue(at: now)
        saveBudget()
        lastActionAt = now
        record("heyclicky has been quiet for \(quietMinutes) min on “\(task)” — replying")

        let previousApp = NSWorkspace.shared.frontmostApplication
        guard var chat = await revealChat(config: config) else {
            record("couldn't open heyclicky's chat window — reply not sent")
            return true
        }
        guard let selected = await selectTask(task, from: chat, config: config) else { return true }
        chat = selected
        guard recoveryAllowed(chat) else { return true }
        guard let composer = chat.composer else {
            record("couldn't find heyclicky's chat box — reply not sent")
            return true
        }
        let context = chat.transcript.isEmpty ? conversation : chat.transcript
        let message = await draftNudge(task: task, transcript: context, config: config,
                                       note: Nudge.stallNote(lastLine: lastLine, minutes: quietMinutes))
        if await send(message, via: composer, task: task) {
            stats.continued += 1
            record("replied on “\(task)”: \(message.prefix(90))\(message.count > 90 ? "…" : "")")
        } else {
            record("failed to send the reply on “\(task)”")
        }
        if pendingMessage == nil, let previousApp, previousApp.bundleIdentifier.map({ !config.clickyBundleIDs.contains($0) }) ?? true {
            previousApp.activate()
        }
        return true
    }

    private func draftNudge(task: String, transcript lines: [String], config: Config, note: String = "", fallback: String? = nil) async -> String {
        let fallbackNudge = fallback ?? config.fallbackNudge
        guard config.ollamaEnabled else { return fallbackNudge }
        let transcript = Nudge.transcript(lines, exclude: [config.continuePrompt, config.fallbackNudge, config.relaunchNudge])
        record("drafting a nudge with ollama…")
        do {
            var draft = try await Ollama.draftNudge(task: task, transcript: transcript, config: config, extraNote: note)
            if !Nudge.isSafe(draft.text) {
                record("ollama's draft spoke for you on a permission/credential — redrafting (rejected: \(draft.text.prefix(140)))")
                draft = try await Ollama.draftNudge(task: task, transcript: transcript, config: config, extraNote: note + Nudge.saferRetryNote)
            }
            guard Nudge.isSafe(draft.text) else {
                record("ollama's redraft still wasn't safe — using fallback nudge")
                return fallbackNudge
            }
            record("ollama (\(draft.model)) drafted the nudge")
            return draft.text
        } catch {
            record("ollama unavailable (\(error.localizedDescription)) — using fallback nudge")
            return fallbackNudge
        }
    }

    /// The thread on screen: a task, the drafted task header, or HeyClicky's main chat.
    static func chatName(_ scan: ScanResult, draft: Bool = true) -> String? {
        scan.selectedTask ?? (draft ? scan.draftTask : nil) ?? (scan.mainChat ? MainChatTapOut.chatName : nil)
    }

    /// Shared by every HeyClicky continuation path, including delayed Ollama drafts.
    private func recoveryAllowed(_ scan: ScanResult, draft: Bool = false) -> Bool {
        let selected = Self.chatName(scan, draft: draft)
        let previous = taskRecovery
        if let selected,
           let row = scan.chatButtons.compactMap({ TaskRow.parse($0.label) })
               .first(where: { Matcher.normalize($0.name) == Matcher.normalize(selected) }),
           TaskRecovery.isStopped(row.status) {
            taskRecovery.observe(task: row.name, status: row.status, latestTurnStatus: scan.latestTurnStatus)
        }
        if let task = selected, !scan.mainChat {
            taskRecovery.observe(task: task, status: scan.selectedStatus, latestTurnStatus: scan.latestTurnStatus)
        }
        if taskRecovery != previous {
            do {
                try JSONEncoder().encode(taskRecovery).write(to: taskRecoveryURL, options: .atomic)
            } catch {
                recoveryHistoryReadable = false
                record("couldn't persist stopped-task history: \(error.localizedDescription) — automatic HeyClicky recovery disabled")
            }
        }
        guard recoveryHistoryReadable else { return false }
        guard let task = selected else { return false }
        if taskRecovery.isStopped(task: task) {
            if !previous.isStopped(task: task) {
                record("“\(task)” was stopped by you — leaving it stopped until you resume it")
            }
            return false
        }
        return true
    }

    func verifyMessageDelivery(task: String) async -> Bool {
        let config = store.config
        guard messageHistoryReadable, pendingMessage == nil,
              config.mode == .cruise, config.autoContinueReports else {
            record("delivery check blocked: enable Cruise and resolve any saved message first")
            return false
        }
        let idle = Self.idleSeconds()
        guard idle >= config.awayIdleSeconds else {
            record("delivery check blocked: input idle for \(Int(idle))s; requires \(Int(config.awayIdleSeconds))s — not interrupting active input")
            return false
        }
        guard
              let chat = await revealChat(config: config),
              let selected = await selectTask(task, from: chat, config: config),
              let composer = selected.composer else {
            record("delivery check blocked: task or composer could not be verified")
            return false
        }
        if [selected.selectedStatus, selected.latestTurnStatus].compactMap({ $0 }).contains(where: StallTracker.isBusy) {
            record("delivery check blocked: “\(task)” is working — not interrupting its current task")
            return false
        }
        let text = "Cruise Control delivery check \(UUID().uuidString). Please reply 'received' only. Do not start or change any other work or perform any release actions."
        let delivered = await send(text, via: composer, task: task)
        record(delivered ? "delivery check confirmed in “\(task)” transcript" : "delivery check not confirmed — inspect the saved message in Settings → Activity")
        return delivered
    }

    private func confirmedTaskWorkspace(_ taskID: String) -> String? {
        taskCatalog.tasks.first { $0.id == taskID && $0.projectAssigned }?.project.directoryPath
    }

    func currentWorkflowKey(_ taskID: String) -> String {
        let project = taskCatalog.tasks.first { $0.id == taskID && $0.projectAssigned }?.project ?? TaskProject()
        let definition = store.config.clickyDefinitionsOfDone[taskID]
        return TaskWorkflow.finishRequestKey(project: project, plan: store.config.taskPlans[taskID] ?? TaskPlan(),
                                            definition: definition)
    }

    private func completionTargetMatches(_ target: PendingMessage.CompletionTarget?, chatOnly: Bool = false) -> Bool {
        guard let target else { return true }
        if target.oneShot != true, let report = target.reportFingerprint,
           engine.isReviewOnly(Self.clickyKey(target.taskID), report: report, definition: target.definition) { return false }
        guard target.workflowKey == currentWorkflowKey(target.taskID) else { return false }
        let plan = store.config.taskPlans[target.taskID]
        if TaskWorkflow.messageBlocker(
            project: taskCatalog.tasks.first(where: { $0.id == target.taskID && $0.projectAssigned })?.project ?? TaskProject(),
            plan: plan ?? TaskPlan()) != nil { return false }
        guard target.matches(definition: store.config.clickyDefinitionsOfDone[target.taskID],
                             enabled: chatOnly ? store.config.backgroundTaskReview : target.oneShot == true || store.config.continueUntilDefinedDone),
              (chatOnly ? plan?.enabled == true : (target.oneShot == true || plan?.autoBump == true)),
              ClickyTaskStore.shared.canPersist else { return false }
        let source = ClickyTaskStore.shared
        guard let task = source.task(target.taskID), task.fingerprint == target.reportFingerprint,
              !task.isWorking, !stopHeld(task), !task.dismissed, !TaskAudit.requiresUser(task.lastMessage),
              !ClickyTaskLibrary.ambiguousNames(source.tasks).contains(Matcher.normalize(task.name)) else { return false }
        if chatOnly {
            guard store.config.backgroundTaskDelivery == .chatOnly,
                  TaskPlanning.eligible(task, config: store.config) else { return false }
        } else {
            guard TaskDraftGate.evaluate(task: task, definition: target.definition,
                                         assessment: source.currentAssessment(for: task, definition: target.definition),
                                         finished: false, ambiguous: false) == .ready else { return false }
            guard TaskPlanning.definitionDeliveryAllowed(config: store.config, oneShot: target.oneShot == true),
                  TaskPlanning.continuationAllowed(task, config: store.config, manual: target.oneShot == true) else { return false }
        }
        let progress = ClickyTaskStore.shared.record(target.taskID).progress
        return DefinitionOfDone.normalized(progress.definition) == DefinitionOfDone.normalized(target.definition)
            && progress.rounds > 0 && progress.rounds <= store.config.maxDefinitionRounds
            && (!chatOnly || progress.lastFingerprint == target.reportFingerprint)
    }

    private func hasSavedDefinition(task: String) -> Bool {
        ClickyTaskStore.shared.tasks.contains(where: {
            Matcher.normalize($0.name) == Matcher.normalize(task)
                && DefinitionOfDone.normalized(store.config.clickyDefinitionsOfDone[$0.id]) != nil
        })
    }

    private func send(_ text: String, via composer: Composer, task: String,
                      completionTarget: PendingMessage.CompletionTarget? = nil, chatOnly: Bool = false,
                      userApprovedOneShot: Bool = false) async -> Bool {
        let config = store.config
        if let completionTarget,
           let reason = TaskWorkflow.messageBlocker(
            project: taskCatalog.tasks.first(where: { $0.id == completionTarget.taskID && $0.projectAssigned })?.project ?? TaskProject(),
            plan: config.taskPlans[completionTarget.taskID] ?? TaskPlan()) {
            record("message blocked for “\(task)”: \(reason)")
            return false
        }
        if let completionTarget,
           engine.alreadyDelivered(Self.clickyKey(completionTarget.taskID),
                                   definition: completionTarget.definition, message: text) {
            record("duplicate follow-up blocked for “\(task)”: this exact message was already delivered")
            return false
        }
        if completionTarget == nil {
            record("unbound follow-up blocked for “\(task)”: messages require a reviewed task draft, Done, folder and explicit Auto-bump/manual Send")
            return false
        }
        let policy = PendingMessage(task: task, text: text, transcript: [], completionTarget: completionTarget,
                                    chatOnly: chatOnly, userApprovedOneShot: userApprovedOneShot ? true : nil)
        guard messageHistoryReadable, pendingMessage == nil,
              policy.automationAllowed(config: config), !chatOnly || Self.idleSeconds() >= config.awayIdleSeconds else {
            record("message not sent — automation disabled or another delivery is pending")
            return false
        }
        let fresh = await Worker.run { ClickyScanner(config: config).scan() }
        guard recoveryAllowed(fresh),
              Self.chatName(fresh, draft: false).map({ Matcher.normalize($0) == Matcher.normalize(task) }) == true,
              let current = fresh.composer, current.pid == composer.pid,
              CFEqual(current.input, composer.input) else {
            record("recovery for “\(task)” blocked: task stopped or chat could not be verified")
            return false
        }
        guard await Worker.run({ AX.stringValue(current.input) == "" }) else {
            record("“\(task)” has an unreadable or existing draft — not overwriting it")
            return false
        }
        guard completionTargetMatches(completionTarget, chatOnly: chatOnly) else {
            record("message not sent — its definition of done changed or was disabled")
            return false
        }
        let message = PendingMessage(task: task, text: text, transcript: fresh.transcript, completionTarget: completionTarget,
                                     chatOnly: chatOnly, userApprovedOneShot: userApprovedOneShot ? true : nil)
        do {
            try JSONEncoder().encode(message).write(to: pendingMessageURL, options: .atomic)
        } catch {
            record("couldn't persist HeyClicky message: \(error.localizedDescription) — not sent")
            return false
        }
        pendingMessage = message
        pendingHeldLogged = false
        return await deliverPendingMessage(config: config)
    }

    private func retryPendingMessage(config: Config) async {
        guard let message = pendingMessage, message.automationAllowed(config: store.config) else { return }
        let completionDelivery = message.chatOnly != true && message.completionTarget != nil
        guard completionDelivery || Date().timeIntervalSince(lastMessageRetryAt) >= 15 else { return }
        lastMessageRetryAt = Date()
        if completionDelivery {
            let source = ClickyTaskStore.shared
            let requested = Date()
            await source.refresh(measure: false)
            guard let loadedAt = source.loadedAt, loadedAt >= requested, source.loadError == nil,
                  completionTargetMatches(message.completionTarget) else {
                holdPendingMessage("Task report or completion settings changed. Review the saved message; Cruise will not send it against stale task evidence.")
                return
            }
        }
        if message.holdReason != nil {
            _ = await deliverPendingMessage(config: config)
            return
        }
        guard completionDelivery || Self.idleSeconds() >= config.awayIdleSeconds else { return }
        let interaction = InputSynth.UserInteractionWatch()
        defer { interaction.stop() }
        if message.chatOnly == true {
            if message.isExpired() {
                holdPendingMessage("Undelivered for 30 minutes. Review the saved chat-only message before discarding it.")
                return
            }
            let source = ClickyTaskStore.shared
            let requested = Date()
            await source.refresh()
            guard let read = source.loadedAt, read >= requested, source.loadError == nil,
                  let target = message.completionTarget, let task = source.task(target.taskID),
                  !ClickyTaskLibrary.ambiguousNames(source.tasks).contains(Matcher.normalize(task.name)) else { return }
            let current = await Worker.run { ClickyScanner(config: config).scan() }
            if let composer = current.composer,
               let input = await Worker.run({ AX.stringValue(composer.input) }),
               !input.isEmpty,
               !(Self.chatName(current) == message.task && input == message.text) {
                record("chat-only retry is waiting: another HeyClicky draft is present")
                return
            }
        }
        guard message.automationAllowed(config: store.config),
              completionDelivery || !interaction.interrupted else { return }
        guard let chat = await revealChat(config: config),
              completionDelivery || !interaction.interrupted,
              await selectTask(message.task, from: chat, config: config, unique: message.chatOnly == true || message.completionTarget != nil) != nil,
              completionDelivery || !interaction.interrupted else { return }
        if await deliverPendingMessage(config: config) {
            stats.continued += 1
            record("delivered pending message to “\(message.task)”")
        }
    }

    private func deliverPendingMessage(config: Config) async -> Bool {
        for attempt in 0...3 {
            guard let message = pendingMessage else { return false }
            let scan = await Worker.run { ClickyScanner(config: config).scan() }
            let allowed = recoveryAllowed(scan, draft: true)
            if Self.chatName(scan).map({ Matcher.normalize($0) == Matcher.normalize(message.task) }) == true,
               taskRecovery.isStopped(task: message.task) {
                holdPendingMessage("Task was stopped. The saved message will not be submitted automatically.")
                return false
            }
            guard message.automationAllowed(config: store.config),
                  allowed, let composer = scan.composer else { return false }
            let input = await Worker.run { AX.stringValue(composer.input) }
            if message.holdReason == PendingMessage.conversationChangedHoldReason {
                guard completionTargetMatches(message.completionTarget, chatOnly: message.chatOnly == true),
                      rebaseUnsubmittedDelivery(message, transcript: scan.transcript, input: input) else { return false }
                continue
            }
            switch message.delivery(selectedTask: Self.chatName(scan), input: input, transcript: scan.transcript) {
            case .delivered:
                if message.chatOnly == true, !ClickyTaskStore.shared.recordBackgroundDelivery(message) {
                    record("couldn't persist chat-only receipt: \(ClickyTaskStore.shared.loadError ?? "unreadable saved task state")")
                    return false
                }
                if message.chatOnly != true, !ClickyTaskStore.shared.recordDefinitionDelivery(message) {
                    record("couldn't persist task delivery receipt: \(ClickyTaskStore.shared.loadError ?? "unreadable saved task state")")
                    return false
                }
                record("delivery confirmed in ‘\(message.task)’ [\(message.completionTarget?.taskID ?? "legacy")]")
                if let target = message.completionTarget {
                    engine.recordDelivery(Self.clickyKey(target.taskID), definition: target.definition, message: message.text)
                    saveEngine()
                }
                return clearPendingMessage()
            case .superseded:
                guard completionTargetMatches(message.completionTarget, chatOnly: message.chatOnly == true) else {
                    holdPendingMessage("Task report or completion settings changed. Review the saved message; Cruise will not send it against stale task evidence.")
                    return false
                }
                guard rebaseUnsubmittedDelivery(message, transcript: scan.transcript, input: input) else {
                    holdPendingMessage(PendingMessage.conversationChangedHoldReason)
                    return false
                }
                continue
            case .held:
                guard !pendingHeldLogged else { return false }
                pendingHeldLogged = true
                record("pending message for “\(message.task)” held: \(message.holdReason ?? "chat, draft or submission cannot be verified") — saved in Settings → Activity; not overwriting or resending")
                return false
            case .ready:
                break
            }
            guard completionTargetMatches(message.completionTarget, chatOnly: message.chatOnly == true) else {
                holdPendingMessage("The definition of done, round limit or saved completion state changed. Review this saved message; its automatic follow-up is held.")
                return false
            }
            if attempt == 3 { break }
            if message.chatOnly == true, Self.idleSeconds() < config.awayIdleSeconds { return false }
            if attempt == 0 {
                let ready = await Worker.run {
                    if input != message.text {
                        guard AX.setValue(composer.input, message.text) else { return false }
                        usleep(300_000)
                    }
                    return AX.stringValue(composer.input) == message.text
                }
                if ready {
                    let fresh = await Worker.run { ClickyScanner(config: config).scan() }
                    let value = await Worker.run { fresh.composer.flatMap { AX.stringValue($0.input) } }
                    if message.automationAllowed(config: store.config),
                       completionTargetMatches(message.completionTarget, chatOnly: message.chatOnly == true),
                       message.chatOnly != true || Self.idleSeconds() >= config.awayIdleSeconds,
                       recoveryAllowed(fresh, draft: true), let current = fresh.composer,
                       CFEqual(current.input, composer.input),
                       message.delivery(selectedTask: Self.chatName(fresh), input: value, transcript: fresh.transcript) == .ready,
                       let send = current.send, AX.isEnabled(send), markMessageSubmission() {
                        _ = await Worker.run { AX.press(send) }
                    }
                }
            } else if message.chatOnly == true {
                await submitPendingViaKeyboard(composer, message: message, config: config)
            }
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
        record("HeyClicky message is still pending — saved for retry before navigating away")
        return false
    }

    private func rebaseUnsubmittedDelivery(_ message: PendingMessage, transcript: [String], input: String?) -> Bool {
        guard message.canRetryAfterConversationChange(input: input) else { return false }
        var rebased = message
        rebased.rebaseAfterConversationChange(transcript: transcript)
        do {
            try JSONEncoder().encode(rebased).write(to: pendingMessageURL, options: .atomic)
            pendingMessage = rebased
            pendingHeldLogged = false
            record("“\(message.task)” conversation changed before submission; refreshed the saved delivery context and retried automatically")
            return true
        } catch {
            record("couldn't refresh pending HeyClicky delivery context: \(error.localizedDescription)")
            return false
        }
    }

    func clearPendingMessage() -> Bool {
        do {
            try FileManager.default.removeItem(at: pendingMessageURL)
            pendingMessage = nil
            pendingHeldLogged = false
            return true
        } catch {
            record("couldn't clear pending HeyClicky message: \(error.localizedDescription)")
            return false
        }
    }

    private func holdPendingMessage(_ reason: String) {
        guard var message = pendingMessage, message.holdReason != reason else { return }
        message.hold(reason)
        do {
            try JSONEncoder().encode(message).write(to: pendingMessageURL, options: .atomic)
            pendingMessage = message
            record("pending message for “\(message.task)” saved for review: \(reason)")
        } catch {
            messageHistoryReadable = false
            record("couldn't persist held message: \(error.localizedDescription) — automatic HeyClicky delivery disabled")
        }
    }

    func discardPendingMessage() {
        guard let message = pendingMessage else { return }
        let alert = NSAlert()
        alert.messageText = "Discard the saved message to \(message.task)?"
        alert.informativeText = "This removes Cruise Control's delivery record, not any draft already in HeyClicky. Review that chat before allowing another follow-up."
        alert.addButton(withTitle: "Keep saved")
        alert.addButton(withTitle: "Discard saved message")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        if clearPendingMessage() { record("user discarded saved message for “\(message.task)”") }
    }

    private func markMessageSubmission() -> Bool {
        guard var message = pendingMessage else { return false }
        message.submissionAttempted = true
        do {
            try JSONEncoder().encode(message).write(to: pendingMessageURL, options: .atomic)
            pendingMessage = message
            return true
        } catch {
            record("couldn't persist HeyClicky submission attempt: \(error.localizedDescription) — not submitted")
            return false
        }
    }

    private func submitPendingViaKeyboard(_ composer: Composer, message: PendingMessage, config: Config) async {
        guard Self.idleSeconds() >= config.awayIdleSeconds else {
            record("waiting for idle input before submitting pending message")
            return
        }
        let interaction = InputSynth.UserInteractionWatch()
        defer { interaction.stop() }
        ScreenControlActivity.announce("Sending to HeyClicky")
        NSRunningApplication(processIdentifier: composer.pid)?.activate()
        try? await Task.sleep(nanoseconds: 400_000_000)
        let fresh = await Worker.run { ClickyScanner(config: config).scan() }
        guard message.automationAllowed(config: store.config),
              completionTargetMatches(message.completionTarget, chatOnly: message.chatOnly == true),
              recoveryAllowed(fresh, draft: true), let current = fresh.composer, current.pid == composer.pid,
              CFEqual(current.input, composer.input),
              !interaction.interrupted,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == composer.pid else {
            record("task or focus changed before submission — message remains pending")
            return
        }
        let value = await Worker.run { AX.stringValue(current.input) }
        guard message.delivery(selectedTask: Self.chatName(fresh), input: value, transcript: fresh.transcript) == .ready else {
            record("chat changed before submission — message remains pending")
            return
        }
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(message.text, forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        let input = current.input
        await withOverlayHidden {
            await Worker.run {
                guard AX.setFocused(input), AX.stringValue(input) == value,
                      let focused: AXUIElement = AX.attr(AXUIElementCreateApplication(composer.pid), kAXFocusedUIElementAttribute),
                      CFEqual(focused, input) else { return }
                // Re-pasting also updates composers whose model ignores AX value changes.
                InputSynth.key(InputSynth.keyA, flags: .maskCommand)
                InputSynth.key(InputSynth.keyV, flags: .maskCommand)
                usleep(250_000)
            }
            let verified = await Worker.run { ClickyScanner(config: config).scan() }
            let value = await Worker.run { verified.composer.flatMap { AX.stringValue($0.input) } }
            guard !interaction.interrupted, message.automationAllowed(config: self.store.config),
                  self.completionTargetMatches(message.completionTarget, chatOnly: message.chatOnly == true),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == composer.pid,
                  self.recoveryAllowed(verified, draft: true),
                  let latest = verified.composer, CFEqual(latest.input, input),
                  value == message.text,
                  message.delivery(selectedTask: Self.chatName(verified), input: value, transcript: verified.transcript) == .ready,
                  self.markMessageSubmission() else {
                self.record("pending message could not be verified before Return — not submitted")
                return
            }
            await Worker.run {
                guard let focused: AXUIElement = AX.attr(AXUIElementCreateApplication(composer.pid), kAXFocusedUIElementAttribute),
                      CFEqual(focused, input), AX.stringValue(input) == message.text else { return }
                InputSynth.key(InputSynth.keyReturn)
            }
        }
    }

    // MARK: HeyClicky updates ("Update app" → relaunch → nudge)

    private func handleUpdate(_ result: ScanResult, config: Config) async -> Bool {
        guard config.autoUpdateClicky else { return false }
        let now = Date()

        if let button = result.update {
            guard now.timeIntervalSince(lastUpdatePressAt) > 20 else { return false }
            await pressUpdate(button, pid: result.pid)
            return true
        }

        // "Update app" only exists while the notch panel is expanded, so hover it once the machine is idle.
        let installed = Self.clickyInfo(config)
        let newer = latestRelease.flatMap { latest in installed.map { latest.build > $0.build ? latest : nil } } ?? nil
        let hinted = now.timeIntervalSince(updateHintAt) < 600
        guard newer != nil || hinted, now.timeIntervalSince(lastHoverProbeAt) > 300,
              Self.idleSeconds() >= config.awayIdleSeconds else { return false }
        lastHoverProbeAt = now
        record(newer.map { "heyclicky \($0.version) is available (installed \(installed?.version ?? "?")) — checking the notch" }
               ?? "heyclicky says it needs an update — checking the notch")

        var found: UpdateButton?
        _ = await hoverNotch(config: config, until: { $0.update != nil }) { scan in
            guard let update = scan.update else { return }
            found = update
            if !AX.press(update.element), let frame = AX.frame(update.element) {
                InputSynth.click(at: CGPoint(x: frame.midX, y: frame.midY), restoreCursor: false)
            }
        }
        if let found {
            beginPending(pid: result.pid, config: config)
            lastUpdatePressAt = Date()
            record("pressed heyclicky's “\(found.label)”\(newer.map { " → updating to \($0.version)" } ?? "")")
        } else {
            record("no “update app” button in the notch yet — will look again in 5 min")
        }
        return true
    }

    private func pressUpdate(_ button: UpdateButton, pid: pid_t) async {
        beginPending(pid: pid, config: store.config)
        lastUpdatePressAt = Date()
        lastActionAt = lastUpdatePressAt
        record("pressing heyclicky's “\(button.label)”")
        let element = button.element
        if !(await Worker.run { AX.press(element) }) {
            _ = await mouseClick(on: element)
        }
    }

    private func beginPending(pid: pid_t, config: Config) {
        guard pending == nil else { return }
        let tasks = TaskRow.resumable(lastTaskLabels)
        pending = PendingRelaunch(requestedAt: Date(), clickyPID: pid,
                                  fromVersion: Self.clickyInfo(config)?.version ?? "", tasks: tasks)
        savePending()
        record(tasks.isEmpty ? "will nudge heyclicky after it relaunches"
                             : "will nudge \(tasks.map { "“\($0)”" }.joined(separator: ", ")) after heyclicky relaunches")
    }

    /// Sparkle normally relaunches HeyClicky itself; if it hasn't come back, open it.
    private func relaunchClickyIfStuck() {
        guard var p = pending, !clickyRunning else { return }
        let now = Date()
        if p.isExpired(now: now) { clearPending("heyclicky update didn't finish — giving up on the relaunch nudge"); return }
        guard let quitAt = clickyQuitAt, now.timeIntervalSince(quitAt) > 45,
              now.timeIntervalSince(lastRelaunchAttemptAt) > 60, p.relaunchAttempts < 3,
              let url = store.config.clickyBundleIDs.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first
        else { return }
        lastRelaunchAttemptAt = now
        p.relaunchAttempts += 1
        pending = p
        savePending()
        record("heyclicky hasn't come back after updating — relaunching it")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                Task { @MainActor in self.record("couldn't relaunch heyclicky: \(error.localizedDescription)") }
            }
        }
    }

    private func resumeAfterRelaunch(_ result: ScanResult, config: Config) async -> Bool {
        guard let p = pending else { return false }
        if p.isExpired(now: Date()) { clearPending("heyclicky never relaunched — dropping the update nudge"); return false }
        guard p.hasRelaunched(currentPID: result.pid) else { return false }
        // Give the fresh process a moment to restore its windows and tasks.
        if let launched = NSRunningApplication(processIdentifier: result.pid)?.launchDate,
           Date().timeIntervalSince(launched) < 10 { return false }

        let now = Self.clickyInfo(config)?.version ?? ""
        clearPending("heyclicky relaunched\(now.isEmpty ? "" : " on \(now)")")
        guard config.mode != .manual, config.autoContinueReports else {
            record("manual mode — not nudging after the update")
            return false
        }

        let previousApp = NSWorkspace.shared.frontmostApplication
        guard var chat = await revealChat(config: config) else {
            record("couldn't open heyclicky's chat window after the update — nudge not sent")
            return true
        }
        let note = Nudge.relaunchNote(fromVersion: p.fromVersion, toVersion: now)
        let tasks = p.tasks.isEmpty ? chat.selectedTask.map { [$0] } ?? [] : p.tasks
        for task in tasks {
            guard let selected = await selectTask(task, from: chat, config: config) else { continue }
            chat = selected
            guard recoveryAllowed(chat) else { continue }
            guard let composer = chat.composer else {
                record("couldn't find heyclicky's chat box after the update")
                break
            }
            let name = task.isEmpty ? "the task you were working on" : task
            let message = await draftNudge(task: name, transcript: chat.transcript, config: config,
                                           note: note, fallback: config.relaunchNudge)
            let sentAt = Date()
            nudgeLimiter.record(task: name, at: sentAt)
            gate.recordContinue(at: sentAt)
            saveBudget()
            if await send(message, via: composer, task: task) {
                stats.continued += 1
                lastActionAt = sentAt
                record("nudged “\(name)” after the update: \(message.prefix(90))\(message.count > 90 ? "…" : "")")
            } else {
                record("failed to send the post-update nudge to “\(name)”")
                if pendingMessage != nil { return true }
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        if pendingMessage == nil, let previousApp, previousApp.bundleIdentifier.map({ !config.clickyBundleIDs.contains($0) }) ?? true {
            previousApp.activate()
        }
        return true
    }

    private func checkAppcastIfDue() {
        let config = store.config
        guard config.autoUpdateClicky,
              Date().timeIntervalSince(lastAppcastCheck) > config.updateCheckMinutes * 60,
              let feed = Self.clickyInfo(config)?.feed else { return }
        lastAppcastCheck = Date()
        Task {
            var request = URLRequest(url: feed)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let release = AppcastRelease.latest(inAppcast: String(decoding: data, as: UTF8.self)) else { return }
            if release != latestRelease, let installed = Self.clickyInfo(config), release.build > installed.build {
                record("heyclicky \(release.version) is out (installed \(installed.version))")
            }
            latestRelease = release
        }
    }

    /// Installed HeyClicky build, read straight from Info.plist (Bundle caches stale values across updates).
    nonisolated static func clickyInfo(_ config: Config) -> (build: Int, version: String, feed: URL?)? {
        for id in config.clickyBundleIDs {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
                  let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) else { continue }
            let build = Int(info["CFBundleVersion"] as? String ?? "") ?? 0
            let version = info["CFBundleShortVersionString"] as? String ?? "\(build)"
            let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:))
            return (build, version, feed)
        }
        return nil
    }

    nonisolated static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Centre of the notch (top-centre of the built-in display), in global top-left coordinates.
    nonisolated private static func notchPoint() -> CGPoint {
        let screens = NSScreen.screens
        let screen = screens.first { $0.safeAreaInsets.top > 0 } ?? screens.first
        guard let screen, let primary = screens.first else { return CGPoint(x: 864, y: 8) }
        return CGPoint(x: screen.frame.midX, y: primary.frame.maxY - screen.frame.maxY + 8)
    }

    private func savePending() {
        if let pending, let data = try? JSONEncoder().encode(pending) {
            try? data.write(to: pendingURL, options: .atomic)
        }
    }

    private func clearPending(_ message: String) {
        pending = nil
        try? FileManager.default.removeItem(at: pendingURL)
        record(message)
    }

    // MARK: Helpers

    private func mouseClick(on element: AXUIElement) async -> Bool {
        guard let frame = await Worker.run({ AX.frame(element) }) else { return false }
        await withOverlayHidden {
            await Worker.run { InputSynth.click(at: CGPoint(x: frame.midX, y: frame.midY)) }
        }
        return true
    }

    private func withOverlayHidden(_ body: () async -> Void) async {
        setOverlayHidden?(true)
        await body()
        setOverlayHidden?(false)
    }

    private func saveStats() {
        guard !loadingStats else { return }
        do {
            try JSONEncoder().encode(stats).write(to: statsURL, options: .atomic)
        } catch {
            record("couldn't persist activity statistics: \(error.localizedDescription)")
        }
    }

    private func saveBudget() {
        let budget = Budget(continueTimes: gate.continueTimes.filter { Date().timeIntervalSince($0) < 3600 }, perTask: nudgeLimiter)
        if let data = try? JSONEncoder().encode(budget) {
            try? data.write(to: budgetURL, options: .atomic)
        }
    }

    private func saveSeen() {
        if let data = try? JSONEncoder().encode(Array(gate.known)) {
            try? data.write(to: seenURL, options: .atomic)
        }
    }

    func record(_ text: String) {
        if text.hasPrefix("vscode: ") { vscodeStatus = String(text.dropFirst("vscode: ".count)) }
        let line = LogLine(date: Date(), text: text)
        log.append(line)
        if log.count > 60 { log.removeFirst(log.count - 60) }

        let stamp = ISO8601DateFormatter().string(from: line.date)
        let data = Data("\(stamp)  \(text)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}
