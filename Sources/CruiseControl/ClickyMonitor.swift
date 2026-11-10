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
    @Published private(set) var taskCatalog = TaskCatalog()
    @Published private(set) var taskCatalogError: String?
    @Published private(set) var projectInferenceStatus = "Projects are inferred locally from conversation evidence."
    @Published private(set) var backgroundTaskStatus = TaskPlanning.deliveryHold
    @Published private(set) var bumpingTaskIDs: Set<String> = []
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

    private let store: ConfigStore
    private var timer: Timer?
    private var busy = false
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

    // VS Code tool confirmations
    private var vscodeBusy = false
    private var lastVSCodeCheckAt = Date.distantPast
    private struct Review { let verdict: ApprovalReview.Verdict?; let at: Date }
    private var reviews: [String: Review] = [:]
    private var modelBusy = false
    private var lastModelCheckAt = Date.distantPast
    private var modelStates: [String: ModelRouting.State] = [:]
    private let modelStateURL = ConfigStore.directory.appendingPathComponent("model-routing.json")
    private var bumpStates: [String: ChatBump.State] = [:]
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
    private var taskAuditStates: [String: ChatBump.State] = [:]
    private let taskAuditURL = ConfigStore.directory.appendingPathComponent("clicky-task-audits.json")
    private var taskRecovery = TaskRecovery()
    private var recoveryHistoryReadable = true
    private let taskRecoveryURL = ConfigStore.directory.appendingPathComponent("stopped-tasks.json")
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
    }

    var logFileURL: URL { logURL }

    func refreshTaskCatalog() async {
        guard !taskCatalogRefreshing else { return }
        taskCatalogRefreshing = true
        lastTaskCatalogRefreshAt = Date()
        defer { taskCatalogRefreshing = false }
        let source = ClickyTaskStore.shared
        await source.refresh(measure: false)
        if let error = source.loadError {
            taskCatalogError = error
            return
        }
        guard source.loadedAt != nil else { return }
        updateTaskCatalog(source.tasks)
        if !inferringProjects {
            Task { await inferTaskProjects() }
        }
    }

    func inferTaskProjects() async {
        guard !inferringProjects, store.config.inferTaskProjects, store.config.ollamaEnabled, taskCatalogReadable else { return }
        inferringProjects = true
        defer { inferringProjects = false }
        let source = ClickyTaskStore.shared
        let candidates = source.tasks.filter { task in
            guard let saved = taskCatalog.tasks.first(where: { $0.id == task.id }) else { return false }
            return !saved.projectAssigned
                && (saved.inferredBy == nil || saved.inferenceFingerprint != ProjectInference.fingerprint(for: task))
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
        let limits = ReportGate.Limits(config: config)
        guard gate.canContinue(now: Date(), limits: limits),
              nudgeLimiter.allow(task: task.name, now: Date(), maxPerHour: config.maxNudgesPerTaskPerHour) else { return false }
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
        let previousGate = gate
        let previousLimiter = nudgeLimiter
        gate.recordContinue(at: Date())
        nudgeLimiter.record(task: task.name, at: Date())
        saveBudget()
        let target = PendingMessage.CompletionTarget(taskID: task.id, definition: reply.definition, reportFingerprint: reply.fingerprint)
        let delivered = await send(reply.text, via: composer, task: task.name, completionTarget: target, chatOnly: true)
        if delivered {
            stats.continued += 1
            backgroundTaskStatus = "Chat-only reply confirmed in “\(task.name)”."
            record(backgroundTaskStatus)
        } else if pendingMessage == nil {
            gate = previousGate
            nudgeLimiter = previousLimiter
            saveBudget()
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

    /// Queues a one-shot report check. Sending waits for Cruise's normal quiet-time and task-safety gates.
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
        backgroundTaskStatus = "One-time bump queued for “\(task.name)”; it waits for quiet input and a current safe report."
        record("one-time bump queued for “\(task.name)” — no message sent yet")
    }

    func assignProject(_ project: TaskProject, to task: String) {
        var catalog = taskCatalog
        catalog.assign(project, to: task)
        saveTaskCatalog(catalog)
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
        axTrusted = AXIsProcessTrusted()
        screenTrusted = CGPreflightScreenCaptureAccess()
        refreshClickyRunning()
        if !taskCatalogRefreshing, Date().timeIntervalSince(lastTaskCatalogRefreshAt) >= 60 {
            Task { await refreshTaskCatalog() }
        }
        if axTrusted, !usageScanBusy, Date().timeIntervalSince(lastUsageScanAt) >= 5 {
            lastUsageScanAt = Date()
            usageScanBusy = true
            Task {
                await refreshUsageGuard()
                usageScanBusy = false
            }
        }
        guard !enforceUsageGuard() else { return }
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
        if let percentage = await Worker.run({ VSCodeScanner(config: config).usageNotificationPercentage() }) {
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
        let config = store.config
        if pendingMessage?.chatOnly == true {
            await retryPendingMessage(config: config)
            return
        }
        if await deliverBackgroundReply(config: config) { return }
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
        if NotchInspection.shouldInspect(workingCount: result.workingCount, mode: config.mode,
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
        let rows = result.chatButtons.map(\.label).filter { TaskRow.parse($0) != nil }
        if !rows.isEmpty { lastTaskLabels = rows }
        _ = recoveryAllowed(result)
        if result.conversation.suffix(6).contains(where: { $0.contains("Please update HeyClicky") || $0.contains("agent_turn_lease_required") }) {
            updateHintAt = Date()
        }

        if await handleConsent(result, config: config) { return }
        if pendingMessage != nil {
            await retryPendingMessage(config: config)
            return
        }
        if await resumeAfterRelaunch(result, config: config) { return }
        if await handleUpdate(result, config: config) { return }
        if await handleInterruptedCards(result, config: config) { return }
        guard pendingMessage == nil else { return }
        if await handleNeedsYou(result, config: config) { return }
        if await handleMainChatTapOut(result, config: config) { return }
        guard pendingMessage == nil else { return }
        if await auditOtherClickyTasks(config: config) { return }
        guard pendingMessage == nil else { return }
        if await continueToDefinitionOfDone(config: config) { return }
        guard pendingMessage == nil else { return }
        await handleReports(result, config: config)
        guard pendingMessage == nil else { return }
        if await handleInterrupt(result, config: config) { return }
        _ = await handleStall(result, config: config)
    }

    // MARK: macOS automation / permission dialogs ("HeyClicky wants access to control …")

    /// Approves (cruise) or dismisses (rest) a system permission alert that HeyClicky triggered. Returns true when
    /// one was on screen, so the rest of the cycle waits for it to clear.
    private func handleSystemDialog(config: Config) async -> Bool {
        guard config.autoAnswerSystemDialogs, config.mode != .manual else { return false }
        guard let dialog = await Worker.run({ SystemDialogScanner(config: config).scan() }) else { return false }
        let allow = config.mode == .cruise
        guard let target = allow ? dialog.allow : dialog.deny else {
            // e.g. rest mode on an OK-only alert: nothing safe to press.
            return dialog.allow != nil || dialog.deny != nil
        }
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
            guard config.mode != .manual else { return true }
            let allow = config.mode == .cruise
            let target = allow ? consent.allow : consent.deny
            let label = allow ? consent.allowLabel : consent.denyLabel

            guard Date().timeIntervalSince(lastConsentActionAt) > 1.2 else { return true }
            lastConsentActionAt = Date()
            consentAttempts += 1

            switch consentAttempts {
            case 1, 2:
                let pressed = await Worker.run { AX.press(target) }
                if pressed && !consentCounted {
                    consentCounted = true
                    if allow { stats.approved += 1 } else { stats.declined += 1 }
                    record("\(allow ? "approved" : "declined") drive request → “\(label)”")
                } else if !pressed {
                    record("couldn't press “\(label)” via Accessibility — retrying")
                }
            case 3...5:
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

        guard config.mode != .manual, config.ocrFallback, screenTrusted,
              Date().timeIntervalSince(lastOCRAt) > config.ocrInterval else { return false }
        lastOCRAt = Date()
        guard let hit = await ScreenOCR.findConsent(config: config) else { return false }

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

    // MARK: "{task} Needs you" → close the card, draft a nudge with Ollama, send it

    /// Returns true when it acted (so the rest of this cycle is skipped).
    private func handleNeedsYou(_ result: ScanResult, config: Config) async -> Bool {
        guard let card = result.needsYou else { return false }
        let task = card.task.isEmpty ? "task" : card.task
        guard config.mode != .manual, config.autoContinueReports else { return false }

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
    private func revealChat(config: Config) async -> ScanResult? {
        var scan = await Worker.run { ClickyScanner(config: config).scan() }
        if scan.composer != nil { return scan }

        // HeyClicky 1.1.3+: the notch panel's "Open in a window" button opens the full chat.
        if let open = scan.openChat, await Worker.run({ AX.press(open) }) {
            if let ready = await waitForComposer(config: config) { return ready }
        } else {
            var pressed = false
            _ = await hoverNotch(config: config, until: { $0.openChat != nil }) { found in
                if let open = found.openChat { pressed = AX.press(open) }
            }
            if pressed, let ready = await waitForComposer(config: config) { return ready }
        }

        if let app = config.clickyBundleIDs.lazy.compactMap({ NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }).first,
           let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        return await waitForComposer(config: config)
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
        guard await Worker.run({ AX.press(element) }) else {
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

    /// Tasks with a user-written definition of done keep going until HeyClicky's latest report meets it. Each report is
    /// read once (Ollama, or rules as a fallback) and earns at most one follow-up, up to `maxDefinitionRounds`.
    private func continueToDefinitionOfDone(config: Config) async -> Bool {
        let now = Date()
        guard config.continueUntilDefinedDone, !config.clickyDefinitionsOfDone.isEmpty,
              config.mode == .cruise, config.autoContinueReports, config.ollamaEnabled,
              Ollama.isLocalServer(config), !config.usageCutoffReached,
              Self.idleSeconds() >= config.awayIdleSeconds,
              now.timeIntervalSince(lastDefinitionCheckAt) >= config.clickyTaskAuditMinutes * 60
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
        for task in ClickyTaskLibrary.sorted(tasks.tasks, by: .recentlyUpdated) {
            guard TaskPlanning.autoBumpEnabled(task, config: store.config) || manualRequests.contains(task.id),
                  let definition = DefinitionOfDone.normalized(config.clickyDefinitionsOfDone[task.id]),
                  task.hasReport, !task.dismissed, !task.isWorking, !task.isStopped,
                  !taskRecovery.isStopped(task: task.name),
                  tasks.rounds(for: task, definition: definition) < maxRounds else { continue }
            let progress = tasks.record(task.id).progress
            // Already followed up on this exact report; wait for Clicky's next one.
            if progress.lastFingerprint == task.fingerprint,
               DefinitionOfDone.normalized(progress.definition) == definition { continue }
            if let reply = tasks.record(task.id).backgroundReply,
               reply.fingerprint == task.fingerprint, reply.definition == definition { continue }
            let assessment: ClickyTaskAssessment
            if let current = tasks.currentAssessment(for: task, definition: definition), current.source.hasPrefix("ollama") {
                assessment = current
            } else {
                assessment = await tasks.assess(task, config: config, localOnly: true)
                record("define done: “\(task.name)” reads as \(assessment.state.title.lowercased())"
                    + (assessment.meetsDefinition == true ? " — meets your definition" : ""))
            }
            guard assessment.source.hasPrefix("ollama") else {
                record("define done: no automatic bump for “\(task.name)” because local Ollama review was unavailable")
                continue
            }
            if DefinitionOfDone.hasNoProgress(assessment, progress: progress) {
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
        guard !due.isEmpty, store.config.mode == .cruise, store.config.continueUntilDefinedDone,
              Self.idleSeconds() >= config.awayIdleSeconds else {
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
            guard TaskPlanning.autoBumpEnabled(task, config: store.config) || manualRequests.contains(task.id),
                  DefinitionOfDone.normalized(store.config.clickyDefinitionsOfDone[task.id]) == item.definition,
                  let latest = tasks.task(task.id), latest.fingerprint == task.fingerprint,
                  !latest.isWorking, !latest.isStopped, !latest.dismissed,
                  !ClickyTaskLibrary.ambiguousNames(tasks.tasks).contains(Matcher.normalize(task.name)) else {
                record("define done: “\(task.name)” or its definition changed during review — no follow-up sent")
                continue
            }
            let limits = ReportGate.Limits(config: config)
            guard store.config.mode == .cruise, store.config.continueUntilDefinedDone,
                  Self.idleSeconds() >= config.awayIdleSeconds,
                  gate.canContinue(now: Date(), limits: limits) else { break }
            guard nudgeLimiter.allow(task: task.name, now: Date(), maxPerHour: config.maxNudgesPerTaskPerHour) else { continue }
            let scan = await Worker.run { ClickyScanner(config: config).scan() }
            if let row = scan.chatButtons.compactMap({ TaskRow.parse($0.label) })
                .first(where: { Matcher.normalize($0.name) == Matcher.normalize(task.name) }), StallTracker.isBusy(row.status) {
                record("define done: “\(task.name)” is \(row.status) — follow-up waits")
                continue
            }
            guard let chat = await selectTask(task.name, from: scan, config: config), let composer = chat.composer,
                  recoveryAllowed(chat) else { continue }
            if let status = chat.selectedStatus, StallTracker.isBusy(status) { continue }
            let input = composer.input
            guard await Worker.run({ (AX.stringValue(input) ?? "").isEmpty }) else {
                record("“\(task.name)” has a draft — define-done follow-up will not overwrite it")
                continue
            }
            guard DefinitionOfDone.normalized(store.config.clickyDefinitionsOfDone[task.id]) == item.definition else {
                record("define done: the target changed while opening “\(task.name)” — no follow-up sent")
                continue
            }
            let project = taskCatalog.tasks.first(where: { $0.id == task.id })?.project ?? TaskProject()
            let priority = store.config.taskPlans[task.id]?.priority
                ?? store.config.projectPriorities[project.priorityKey] ?? .normal
            let draft: ChatBump.Draft
            do {
                draft = try await Ollama.draftTaskBump(task: task, definition: item.definition, project: project,
                                                      priority: priority, missing: item.assessment.missing, config: config)
            } catch {
                record("define done: Ollama couldn't draft a safe bump for “\(task.name)”: \(error.localizedDescription)")
                continue
            }
            guard draft.unfinished else {
                record("define done: Ollama found no explicit actionable gap for “\(task.name)” — nothing sent")
                continue
            }
            let afterDraft = Date()
            await tasks.refresh(measure: false)
            guard let refreshedAt = tasks.loadedAt, refreshedAt >= afterDraft, tasks.loadError == nil,
                  let refreshedTask = tasks.task(task.id), refreshedTask.fingerprint == task.fingerprint,
                  TaskPlanning.autoBumpEnabled(refreshedTask, config: store.config),
                  DefinitionOfDone.normalized(store.config.clickyDefinitionsOfDone[task.id]) == item.definition,
                  (TaskPlanning.autoBumpEnabled(refreshedTask, config: store.config) || manualRequests.contains(task.id)),
                  !refreshedTask.isWorking, !refreshedTask.isStopped, !refreshedTask.dismissed,
                  !TaskAudit.requiresUser(refreshedTask.lastMessage) else {
                record("define done: task, report, or opt-in changed during Ollama drafting — no bump sent")
                continue
            }
            let round = tasks.rounds(for: task, definition: item.definition) + 1
            let message = draft.message
            // Reserve the round on disk before typing, so a saved-for-retry message still counts after a restart.
            let previous = tasks.record(task.id).progress
            guard tasks.recordFollowUp(task, definition: item.definition, missing: item.assessment.missing) else {
                record("define done: couldn't save the round for “\(task.name)” — no follow-up sent. "
                    + (tasks.persistenceError ?? tasks.loadError ?? ""))
                break
            }
            let previousGate = gate
            let previousLimiter = nudgeLimiter
            nudgeLimiter.record(task: task.name, at: Date())
            gate.recordContinue(at: Date())
            saveBudget()
            let oneShot = manualRequests.contains(task.id) && !TaskPlanning.autoBumpEnabled(task, config: store.config)
            let target = PendingMessage.CompletionTarget(taskID: task.id, definition: item.definition,
                                                         reportFingerprint: task.fingerprint, oneShot: oneShot)
            if await send(message, via: composer, task: task.name, completionTarget: target) {
                stats.continued += 1
                sent = true
                record("define done: “\(task.name)” falls short (round \(round) of \(maxRounds)) — asked for: "
                    + item.assessment.missing.joined(separator: "; ").prefix(160))
            } else {
                if pendingMessage != nil {
                    record("define done follow-up to “\(task.name)” saved for retry — round \(round) counted")
                    return true
                }
                gate = previousGate
                nudgeLimiter = previousLimiter
                saveBudget()
                if !tasks.restoreProgress(previous, for: task.id) {
                    record("define done: couldn't release the unused round for “\(task.name)” — it stays counted")
                }
                record("define done couldn't send to “\(task.name)” — not redirecting to another task")
                break
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
    private func waitForComposer(config: Config) async -> ScanResult? {
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let scan = await Worker.run { ClickyScanner(config: config).scan() }
            if scan.composer != nil { return scan }
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
                && now.timeIntervalSince(lastInterruptedBump[$0.task] ?? .distantPast) >= 5
        }) else {
            return false
        }
        let task = card.task
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

    // MARK: VS Code chat tool confirmations → Ollama safety check → Allow Once

    private func tickVSCode() {
        let config = store.config
        guard config.vscodeAutoApprove, axTrusted, !vscodeBusy, !modelBusy,
              Date().timeIntervalSince(lastVSCodeCheckAt) >= config.vscodeCheckSeconds else { return }
        lastVSCodeCheckAt = Date()
        vscodeBusy = true
        Task {
            if await handleVSCode(config: config) == false {
                await inspectVSCodeThreads(config: config)
            }
            vscodeBusy = false
        }
    }

    func approveVSCodeSidebar(key: String) async -> Bool {
        guard store.config.vscodeAutoApprove, axTrusted else {
            record("vscode: sidebar check requires enabled automation and Accessibility permission")
            return false
        }
        let count = stats.vscodeApproved
        _ = await handleVSCode(config: store.config, onlyKey: key)
        return stats.vscodeApproved > count
    }

    private func handleVSCode(config: Config, onlyKey: String? = nil, permitAction: () -> Bool = { true }) async -> Bool {
        let now = Date()
        let pendingRequests = await Worker.run { VSCodeScanner(config: config).scanAll() }
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
        guard let still = await Worker.run({ VSCodeScanner(config: config).scanAll().first { $0.key == key } }),
              still.request == pending.request, store.config.vscodeAutoApprove,
              !still.writeMetadataOnly || store.config.vscodeAllowWriteMetadata,
              !still.toolPermission || store.config.vscodeAllowToolPermissions,
              !still.urlFetch || store.config.vscodeURLFetchPolicy != .hold,
              !still.urlFetch || config.vscodeURLFetchPolicy != .allowAll || store.config.vscodeURLFetchPolicy == .allowAll,
              permitAction() else { return true }
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
        if await Worker.run({ AX.press(pending.allow) }) { return true }
        // Inline sidebar approvals stay background-only. A dialog fallback must not fight active input.
        guard pending.sidebarThread == nil, !busy,
              Self.idleSeconds() >= config.awayIdleSeconds else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(pending.window, &pid) == .success else { return false }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let interaction = InputSynth.UserInteractionWatch()
        defer {
            interaction.stop()
            if !interaction.interrupted { previousApp?.activate() }
        }
        NSRunningApplication(processIdentifier: pid)?.activate()
        guard AXUIElementPerformAction(pending.window, kAXRaiseAction as CFString) == .success else { return false }
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !interaction.interrupted, permitAction(), store.config.vscodeAutoApprove,
              !store.config.usageCutoffReached,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        var clicked = false
        await withOverlayHidden {
            guard !interaction.interrupted, permitAction(), store.config.vscodeAutoApprove,
                  !pending.writeMetadataOnly || store.config.vscodeAllowWriteMetadata,
                  !pending.toolPermission || store.config.vscodeAllowToolPermissions else { return }
            clicked = await Worker.run {
                guard let fresh = VSCodeScanner(config: config).scanAll().first(where: { $0.key == pending.key }),
                      fresh.request == pending.request, AX.isEnabled(fresh.allow),
                      let frame = AX.frame(fresh.allow), let bounds = AX.frame(fresh.window),
                      bounds.contains(frame) else { return false }
                let point = CGPoint(x: frame.midX, y: frame.midY)
                guard Self.idleSeconds() >= config.awayIdleSeconds,
                      AX.isUnderPointer(fresh.allow, at: point) else { return false }
                InputSynth.click(at: point)
                return true
            }
        }
        return clicked
    }

    private func inspectVSCodeThreads(config: Config) async {
        guard config.mode == .cruise, store.config.vscodeAutoApprove,
              Date().timeIntervalSince(lastVSCodeThreadProbeAt) >= 5 else { return }
        lastVSCodeThreadProbeAt = Date()
        let threads = await Worker.run { VSCodeScanner(config: config).attentionThreads() }
        for thread in threads.prefix(3) {
            guard store.config.mode == .cruise, store.config.vscodeAutoApprove else { return }
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
        guard store.config.autoSelectVSCodeModel || store.config.vscodeTaskBumps,
              axTrusted, !modelBusy, !vscodeBusy, !busy,
              Date().timeIntervalSince(lastModelCheckAt) >= 15 else { return }
        lastModelCheckAt = Date()
        modelBusy = true
        Task {
            defer { modelBusy = false }
            let config = store.config
            if config.autoSelectVSCodeModel { await routeModel(config: config) }
            if config.vscodeTaskBumps { await bumpChat(config: config) }
        }
    }

    private func bumpChat(config: Config) async {
        guard config.mode == .cruise,
              let chat = await Worker.run({ VSCodeModels.scan(config: config) }) else { return }
        let now = Date()
        var state = bumpStates[chat.key] ?? ChatBump.State()
        let changed = state.transcript != chat.transcript
        state.observe(chat.transcript, now: now)
        bumpStates[chat.key] = state
        if changed { saveBumpStates() }
        guard !chat.running, chat.draft.isEmpty, Self.idleSeconds() >= config.awayIdleSeconds,
              state.eligible(now: now, quietMinutes: config.vscodeBumpQuietMinutes,
                             cooldownMinutes: config.vscodeBumpCooldownMinutes) else { return }
        state.lastAttempt = now
        bumpStates[chat.key] = state
        saveBumpStates()
        do {
            let draft = try await Ollama.draftChatBump(chat.transcript, config: config)
            guard draft.unfinished else {
                state.answeredTranscript = chat.transcript
                bumpStates[chat.key] = state
                guard saveBumpStates() else { return }
                record("vscode follow-up: no unfinished task identified — leaving the chat alone")
                return
            }
            guard store.config.vscodeTaskBumps, store.config.mode == .cruise,
                  Self.idleSeconds() >= config.awayIdleSeconds else { return }
            // Persist before touching the composer: uncertain submissions must not be sent twice after a restart.
            state.answeredTranscript = chat.transcript
            bumpStates[chat.key] = state
            saveBumpStates()
            try await VSCodeModels.sendFollowUp(draft.message, chat: chat, config: config)
            stats.vscodeContinued += 1
            record("vscode follow-up sent: \(draft.message.prefix(120))")
        } catch {
            record("vscode follow-up unavailable: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func saveBumpStates() -> Bool {
        do {
            try JSONEncoder().encode(bumpStates).write(to: bumpStateURL, options: .atomic)
            return true
        } catch {
            record("couldn't persist chat follow-up history: \(error.localizedDescription)")
            return false
        }
    }

    private func routeModel(config: Config) async {
        guard let chat = await Worker.run({ VSCodeModels.scan(config: config) }) else { return }
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
        guard !chat.running, chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

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
            guard store.config.autoSelectVSCodeModel else { return }
        }
        do {
            try await VSCodeModels.select(target, chat: chat, config: config)
            stats.vscodeModelSwitches += 1
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
        for row in scan.chatButtons.compactMap({ TaskRow.parse($0.label) }) where TaskRecovery.isStopped(row.status) {
            taskRecovery.observe(task: row.name, status: row.status, latestTurnStatus: nil)
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

    private func completionTargetMatches(_ target: PendingMessage.CompletionTarget?, chatOnly: Bool = false) -> Bool {
        guard let target else { return true }
        let plan = store.config.taskPlans[target.taskID]
        guard target.matches(definition: store.config.clickyDefinitionsOfDone[target.taskID],
                             enabled: chatOnly ? store.config.backgroundTaskReview : store.config.continueUntilDefinedDone),
              (chatOnly ? plan?.enabled == true : (target.oneShot == true || plan?.autoBump == true)),
              ClickyTaskStore.shared.canPersist else { return false }
        let source = ClickyTaskStore.shared
        guard let task = source.task(target.taskID), task.fingerprint == target.reportFingerprint,
              !task.isWorking, !task.isStopped, !task.dismissed, !TaskAudit.requiresUser(task.lastMessage),
              !ClickyTaskLibrary.ambiguousNames(source.tasks).contains(Matcher.normalize(task.name)) else { return false }
        if chatOnly {
            guard store.config.backgroundTaskDelivery == .chatOnly,
                  TaskPlanning.eligible(task, config: store.config) else { return false }
        } else {
            guard store.config.mode == .cruise, store.config.autoContinueReports,
                  store.config.ollamaEnabled, Ollama.isLocalServer(store.config) else { return false }
        }
        let progress = ClickyTaskStore.shared.record(target.taskID).progress
        return DefinitionOfDone.normalized(progress.definition) == DefinitionOfDone.normalized(target.definition)
            && progress.rounds > 0 && progress.rounds <= store.config.maxDefinitionRounds
            && (!chatOnly || progress.lastFingerprint == target.reportFingerprint)
    }

    private func send(_ text: String, via composer: Composer, task: String,
                      completionTarget: PendingMessage.CompletionTarget? = nil, chatOnly: Bool = false) async -> Bool {
        let config = store.config
        let policy = PendingMessage(task: task, text: text, transcript: [], completionTarget: completionTarget, chatOnly: chatOnly)
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
        let message = PendingMessage(task: task, text: text, transcript: fresh.transcript, completionTarget: completionTarget, chatOnly: chatOnly)
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
        guard Date().timeIntervalSince(lastMessageRetryAt) >= 15,
              let message = pendingMessage, message.automationAllowed(config: store.config) else { return }
        lastMessageRetryAt = Date()
        if message.holdReason != nil {
            _ = await deliverPendingMessage(config: config)
            return
        }
        guard Self.idleSeconds() >= config.awayIdleSeconds else { return }
        if message.chatOnly != true, message.completionTarget != nil {
            let source = ClickyTaskStore.shared
            let requested = Date()
            await source.refresh(measure: false)
            guard let loadedAt = source.loadedAt, loadedAt >= requested, source.loadError == nil,
                  completionTargetMatches(message.completionTarget) else {
                holdPendingMessage("Task report or completion settings changed. Review the saved message; Cruise will not send it against stale task evidence.")
                return
            }
        }
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
        guard message.automationAllowed(config: store.config), !interaction.interrupted else { return }
        guard let chat = await revealChat(config: config),
              !interaction.interrupted,
              await selectTask(message.task, from: chat, config: config, unique: message.chatOnly == true) != nil,
              !interaction.interrupted else { return }
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
            switch message.delivery(selectedTask: Self.chatName(scan), input: input, transcript: scan.transcript) {
            case .delivered:
                if message.chatOnly == true, !ClickyTaskStore.shared.recordBackgroundDelivery(message) {
                    record("couldn't persist chat-only receipt: \(ClickyTaskStore.shared.loadError ?? "unreadable saved task state")")
                    return false
                }
                return clearPendingMessage()
            case .superseded:
                holdPendingMessage("Conversation has moved on. Review the saved message; it will not be sent into a changed conversation.")
                return false
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
            } else {
                await submitPendingViaKeyboard(composer, message: message, config: config)
            }
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
        record("HeyClicky message is still pending — saved for retry before navigating away")
        return false
    }

    private func clearPendingMessage() -> Bool {
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

    nonisolated private static func idleSeconds() -> Double {
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
