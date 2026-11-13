import AppKit
import CruiseCore

/// The always-on task engine. Every pass it:
/// 1. reads every HeyClicky task and every VS Code chat Cruise knows about and logs metadata changes;
/// 2. derives each task's stage (needs Done, examining, draft ready, queued, held + exact fix…);
/// 3. examines one stale task with local Ollama, least recently examined first, so no task can starve the rest.
/// Drafts are deterministic from the review, so they're cached the moment a review lands. Auto-bump drafts are then
/// sent one at a time by the HeyClicky sender (`continueToDefinitionOfDone`) and the VS Code sender (`bumpChat`).
extension ClickyMonitor {
    static let engineURL = ConfigStore.directory.appendingPathComponent("task-engine.json")
    static let heldMessagesURL = ConfigStore.directory.appendingPathComponent("held-messages.json")
    static let engineExamineTimeout: TimeInterval = 150

    static func clickyKey(_ id: String) -> String { "clicky:\(id)" }

    func loadEngineIfNeeded() {
        guard !engineLoaded else { return }
        engineLoaded = true
        if let data = try? Data(contentsOf: Self.engineURL),
           let cache = try? JSONDecoder().decode(TaskEngineCache.self, from: data) {
            engine = cache
        }
        if let data = try? Data(contentsOf: Self.heldMessagesURL),
           let held = try? JSONDecoder().decode([PendingMessage].self, from: data) {
            heldMessages = held
        }
    }

    func saveEngine() {
        do {
            try JSONEncoder().encode(engine).write(to: Self.engineURL, options: .atomic)
        } catch {
            record("task engine: couldn't save drafts: \(error.localizedDescription)")
        }
    }

    // MARK: Loop

    func tickTaskEngine() {
        loadEngineIfNeeded()
        expireHeldMessages()
        archiveBlockingPendingMessage()
        let due = Date().timeIntervalSince(lastEnginePassAt) >= 8 || !enginePriorityKeys.isEmpty
        guard !engineBusy, due else { return }
        engineBusy = true
        lastEnginePassAt = Date()
        Task {
            await runEnginePass()
            engineBusy = false
        }
    }

    private func expireHeldMessages() {
            let retained = heldMessages.filter { Date().timeIntervalSince($0.createdAt) < 7 * 24 * 60 * 60 }
            guard retained.count != heldMessages.count else { return }
            do {
                try JSONEncoder().encode(retained).write(to: Self.heldMessagesURL, options: .atomic)
                heldMessages = retained
            } catch {
                record("Couldn't expire set-aside message diagnostics: \(error.localizedDescription)")
        }
    }

    private func runEnginePass() async {
        let source = ClickyTaskStore.shared
        let requested = Date()
        await source.refresh(measure: false)
        let fresh = source.loadedAt.map { $0 >= requested } == true && source.loadError == nil
        let before = engine
        deriveAll(fresh: fresh, loadError: source.loadError)
        if Date().timeIntervalSince(lastEngineIntegrityAt) >= 60 {
            lastEngineIntegrityAt = Date()
            checkIntegrity(fresh: fresh)
        }
        if fresh { await examineNext() }
        if engine != before { saveEngine() }
    }

    /// Rebuilds every task's record from current evidence. Cheap: no Ollama, no UI scripting.
    func deriveAll(fresh: Bool = true, loadError: String? = nil) {
        let source = ClickyTaskStore.shared
        let config = store.config
        var keys = Set<String>()
        let ambiguous = ClickyTaskLibrary.ambiguousNames(source.tasks)
        if fresh {
            for task in source.tasks where !task.dismissed {
                let key = Self.clickyKey(task.id)
                keys.insert(key)
                logMetadata(key: key, metadata: clickyMetadata(task, config: config))
                engine.upsert(deriveClicky(task, config: config, ambiguous: ambiguous))
            }
            // Settings saved for a task HeyClicky no longer lists are reported once, never silently dropped.
            let configured = Set(config.clickyDefinitionsOfDone.keys).union(config.taskPlans.filter { $0.value.autoBump }.keys)
            for id in configured where source.task(id) == nil || source.task(id)?.dismissed == true {
                let key = Self.clickyKey(id)
                keys.insert(key)
                let title = taskCatalog.tasks.first(where: { $0.id == id })?.name ?? engine.records[key]?.title ?? id
                let dismissed = source.task(id)?.dismissed == true
                if var old = engine.metadata[key], old.exists {
                    old.exists = false
                    engine.metadata[key] = old
                    record("task engine · “\(title)”: \(dismissed ? "dismissed in HeyClicky" : "no longer found in HeyClicky")")
                }
                engine.upsert(TaskEngineRecord(
                    key: key, provider: "heyclicky", title: title, stage: .held,
                    detail: dismissed ? "Dismissed in HeyClicky." : "Not in HeyClicky's task list.",
                    blocker: TaskBlocker(dismissed
                        ? "This task is dismissed in HeyClicky, so Cruise won't examine or bump it. Its Done and settings are kept."
                        : "HeyClicky no longer lists this task (renamed, deleted, or HeyClicky's list is unreadable). Refresh, or check HeyClicky.",
                        fix: dismissed ? .showInHeyClicky : .refreshTasks),
                    inputsKey: "missing", autoBump: config.taskPlans[id]?.autoBump == true))
            }
        } else {
            keys.formUnion(engine.records.keys.filter { $0.hasPrefix("clicky:") })
            if let loadError { engineActivity = ("HeyClicky's task list is unreadable: \(loadError)", nil, Date()) }
        }
        for key in vscodeEngineKeys(config: config) {
            keys.insert(key)
            engine.upsert(deriveVSCode(key: key, config: config))
        }
        engine.prune(keeping: keys)
        updateQueuePositions()
    }

    private func updateQueuePositions() {
        let queue = engine.sendQueue()
        for (index, key) in queue.enumerated() {
            guard var record = engine.records[key], record.stage != .sending else { continue }
            let position = "Queued \(index + 1) of \(queue.count)"
            let via = record.provider == "vscode"
                ? "Cruise sends VS Code follow-ups as soon as the chat is idle and readable."
                : "Cruise sends to HeyClicky one task at a time when its composer is free."
            record.stage = .queued
            let hold = record.provider == "heyclicky" ? autoBumpDeliveryHolds[String(key.dropFirst(7))] : nil
            record.detail = "\(position). \(hold.map { "Last attempt: \($0) " } ?? "")\(via)"
            if engine.records[key] != record { engine.records[key] = record }
        }
    }

    // MARK: HeyClicky derivation

    private func clickyMetadata(_ task: ClickyAgentTask, config: Config) -> TaskMetadata {
        let plan = config.taskPlans[task.id] ?? TaskPlan()
        let catalogTask = taskCatalog.tasks.first(where: { $0.id == task.id })
        let folder = catalogTask?.projectAssigned == true ? catalogTask?.project.directoryPath : nil
        let definition = DefinitionOfDone.normalized(config.clickyDefinitionsOfDone[task.id])
        return TaskMetadata(title: task.name, status: task.outcome.isEmpty ? "unknown" : task.outcome,
                            folder: folder, done: definition,
                            autoBump: plan.autoBump == true,
                            plan: TaskWorkflow.finishRequestKey(project: catalogTask?.project ?? TaskProject(), plan: plan,
                                                               definition: definition),
                            report: task.fingerprint)
    }

    private func logMetadata(key: String, metadata: TaskMetadata) {
        let old = engine.metadata[key]
        guard old != metadata else { return }
        let changes = TaskMetadata.changes(from: old, to: metadata)
        engine.metadata[key] = metadata
        if !changes.isEmpty { record("task engine · “\(metadata.title)”: \(changes.joined(separator: "; "))") }
    }

    /// True when the user stopped this task and hasn't explicitly resumed it in Cruise.
    func stopHeld(_ task: ClickyAgentTask) -> Bool {
        guard task.isStopped || taskRecovery.isStopped(task: task.name) else { return false }
        return engine.resumed[task.id] != task.fingerprint || taskRecovery.isStopped(task: task.name)
    }

    /// The exact message the HeyClicky sender delivers for this review; cached so the user sees it before it goes.
    func heyClickyFollowUp(_ task: ClickyAgentTask, definition: String, missing: [String], config: Config) -> String {
        let catalogTask = taskCatalog.tasks.first(where: { $0.id == task.id })
        let project = catalogTask?.projectAssigned == true ? catalogTask?.project ?? TaskProject() : TaskProject()
        let plan = config.taskPlans[task.id] ?? TaskPlan()
        let cacheLocations = task.threadIDs.flatMap { ClickyTaskLibrary.cachePaths(threadIDs: [$0]).map(\.path) }
        return TaskWorkflow.taskBumpMessage(
            baseMessage: DefinitionOfDone.criteriaFollowUp(task: task.name, missing: missing),
            taskName: task.name, definition: definition, project: project, plan: plan,
            clickyCacheLocations: Array(Set(cacheLocations)).sorted())
    }

    /// The assessment the engine acts on, with the same evidence corrections the sender applies.
    func engineAssessment(_ task: ClickyAgentTask, definition: String) -> ClickyTaskAssessment? {
        guard var assessment = ClickyTaskStore.shared.currentAssessment(for: task, definition: definition),
              assessment.source.hasPrefix("ollama") else { return nil }
        if DefinitionOfDone.needsAgentFollowUp(assessment, report: task.lastMessage) {
            assessment = DefinitionOfDone.redirectedToAgent(assessment, definition: definition)
        }
        return assessment
    }

    private func deriveClicky(_ task: ClickyAgentTask, config: Config, ambiguous: Set<String>) -> TaskEngineRecord {
        let source = ClickyTaskStore.shared
        let key = Self.clickyKey(task.id)
        let definition = DefinitionOfDone.normalized(config.clickyDefinitionsOfDone[task.id])
        let metadata = clickyMetadata(task, config: config)
        let autoBump = TaskPlanning.autoBumpOptedIn(taskID: task.id, config: config)
        let inputs = TaskEngineCache.inputsKey([task.fingerprint, definition, metadata.folder, metadata.plan,
                                                String(autoBump), String(stopHeld(task))])
        var record = TaskEngineRecord(key: key, provider: "heyclicky", title: task.name, stage: .examining,
                                      detail: "", inputsKey: inputs, autoBump: autoBump)
        guard let definition else {
            // Examined for status only: replies are drafted solely against a user-defined Done.
            record.stage = .needsDone
            let report = task.hasReport ? "latest response \(task.lastMessage.count) characters" : "no response yet"
            record.detail = "Examined · HeyClicky status “\(task.outcome)”, \(task.isWorking ? "working" : "idle"), \(report). No reply is drafted until Done is defined."
            record.blocker = TaskBlocker("Define what done looks like for this task; Cruise then reviews and drafts automatically.", fix: .defineDone)
            if engine.records[key]?.inputsKey != inputs || engine.records[key]?.examinedAt == nil { record.examinedAt = Date() }
            return record
        }
        guard task.hasReport else {
            record.stage = .waitingForReport
            record.detail = "HeyClicky hasn't posted a response yet. Cruise examines the first one as soon as it arrives."
            return record
        }
        if task.isWorking {
            record.stage = .agentWorking
            record.detail = "HeyClicky is working on this task (\(task.outcome)). Cruise examines its next response when it finishes."
            return record
        }
        guard let assessment = engineAssessment(task, definition: definition) else {
            record.stage = .examining
            if let failedAt = definitionReviewFailures[task.id], Date().timeIntervalSince(failedAt) < 60 {
                record.detail = "Local Ollama couldn't review the latest response; retrying at \(failedAt.addingTimeInterval(60).formatted(date: .omitted, time: .standard))."
                record.blocker = TaskBlocker("Local Ollama review failed for this task. Check that Ollama is running and the model is installed.", fix: .ollamaSettings)
            } else if engineActivity?.key == key {
                record.detail = engineActivity?.text ?? "Examining…"
            } else {
                let waiting = engine.examineOrder(examineCandidates()).firstIndex(of: key).map { $0 + 1 }
                record.detail = "Waiting to be examined by local Ollama\(waiting.map { " (#\($0) in line)" } ?? "")."
            }
            return record
        }
        record.examinedAt = engine.records[key]?.inputsKey == inputs ? engine.records[key]?.examinedAt ?? Date() : Date()
        record.missing = assessment.missing
        if let reason = TaskWorkflow.messageBlocker(
            project: taskCatalog.tasks.first(where: { $0.id == task.id && $0.projectAssigned })?.project ?? TaskProject(),
            plan: config.taskPlans[task.id] ?? TaskPlan()) {
            record.stage = .held
            record.detail = "Complete Done's workflow choices before drafting or sending."
            record.blocker = TaskBlocker(reason, fix: .defineDone)
            return record
        }
        if let question = assessment.clarificationQuestion {
            record.stage = .held
            record.detail = "Review needs your Done clarified."
            record.blocker = TaskBlocker("Clarify Done: \(question)", fix: .defineDone)
            return record
        }
        if TaskAudit.requiresUser(task.lastMessage) || assessment.state == .needsYou {
            record.stage = .held
            record.detail = "HeyClicky's latest response is waiting on you."
            record.blocker = TaskBlocker("HeyClicky is asking you to decide something: \(assessment.reason.isEmpty ? "open the task to answer it." : assessment.reason)", fix: .showInHeyClicky)
            return record
        }
        if assessment.meetsDefinition == true {
            engine.holdForReview(key, report: task.fingerprint, definition: definition)
            record.stage = .met
            record.detail = "The latest response appears to meet Done\(assessment.reason.isEmpty ? "." : ": \(assessment.reason)") Check the evidence, then mark it finished.\n\nResponse evidence:\n\(task.lastMessage.suffix(3000))"
            return record
        }
        guard !assessment.missing.isEmpty else {
            record.stage = .held
            record.detail = "The review found no concrete unfinished criterion to ask about."
            record.blocker = TaskBlocker("Review found no specific gap to draft against. Re-review, or make Done more specific.", fix: .reviewReport)
            return record
        }
        record.draft = heyClickyFollowUp(task, definition: definition, missing: assessment.missing, config: config)
        record.stage = .drafted
        guard autoBump else {
            record.detail = "Draft ready. Press Send, or turn on Auto-bump to send drafts like this automatically."
            return record
        }
        let progress = source.record(task.id).progress
        if progress.lastFingerprint == task.fingerprint, DefinitionOfDone.normalized(progress.definition) == definition {
            record.stage = .sent
            record.detail = progress.deliveredAt.map {
                "Follow-up delivered \($0.formatted(date: .omitted, time: .shortened)); waiting for HeyClicky's next response."
            } ?? "Follow-up sent for this response; waiting for HeyClicky's next response."
            return record
        }
        if let blocker = heyClickySendBlocker(task, definition: definition, assessment: assessment,
                                             config: config, ambiguous: ambiguous) {
            record.stage = .held
            record.detail = "Draft ready, but auto-bump can't send it yet."
            record.blocker = blocker
        }
        return record
    }

    func heyClickySendBlocker(_ task: ClickyAgentTask, definition: String, assessment: ClickyTaskAssessment,
                              config: Config, ambiguous: Set<String>) -> TaskBlocker? {
        let source = ClickyTaskStore.shared
        if engine.isReviewOnly(Self.clickyKey(task.id), report: task.fingerprint, definition: definition) {
            return TaskBlocker("Examined for your review only. Inspect the response and use Send explicitly if more work is needed.", fix: .showInHeyClicky)
        }
        if engine.alreadyDelivered(Self.clickyKey(task.id), definition: definition,
                                  message: heyClickyFollowUp(task, definition: definition, missing: assessment.missing, config: config)) {
            return TaskBlocker("This exact follow-up was already delivered. Review the latest response; Cruise will not repeat it.", fix: .showInHeyClicky)
        }
        if stopHeld(task) {
            return TaskBlocker("You stopped this task, so Cruise won't restart it on its own. Resume auto-bump to let Cruise send this draft.", fix: .resumeStopped)
        }
        if config.mode == .rest { return TaskBlocker("Rest mode pauses all sending. Switch Cruise to Manual or Cruise mode.", fix: .automationSettings) }
        if !config.continueUntilDefinedDone {
            return TaskBlocker("“Allow per-task auto-bumps” is off in Automation settings.", fix: .automationSettings)
        }
        if !config.ollamaEnabled || !TaskPlanning.usesLocalOllama(config) {
            return TaskBlocker("Auto-bump needs local Ollama enabled in Automation settings.", fix: .ollamaSettings)
        }
        if config.usageCutoffReached { return TaskBlocker("The Copilot usage cutoff paused automation. Raise or reset it in Automation settings.", fix: .automationSettings) }
        if ambiguous.contains(Matcher.normalize(task.name)) {
            return TaskBlocker("More than one HeyClicky task is named “\(task.name)”, so Cruise can't safely pick one. Rename one in HeyClicky.", fix: .showInHeyClicky)
        }
        let maxRounds = min(max(1, config.maxDefinitionRounds), DefinitionOfDone.maxRounds)
        if source.rounds(for: task, definition: definition) >= maxRounds {
            return TaskBlocker("Cruise already sent \(maxRounds) follow-ups for this Done. Reset rounds to keep going.", fix: .resetRounds)
        }
        if DefinitionOfDone.hasNoProgress(assessment, progress: source.record(task.id).progress, task: task) {
            return TaskBlocker("HeyClicky's response repeated the same gaps after the last follow-up. Check the task, then reset rounds to retry.", fix: .resetRounds)
        }
        if !TaskPlanning.continuationAllowed(task, config: config, manual: false, ignoringStop: true) {
            return TaskBlocker("The response mentions a time, credit or message limit you told Cruise to respect.", fix: .automationSettings)
        }
        if !axTrusted { return TaskBlocker("Cruise needs Accessibility permission to type into HeyClicky.", fix: .permissions) }
        if !clickyRunning { return TaskBlocker("HeyClicky isn't running. Open it so Cruise can deliver the follow-up.", fix: .showInHeyClicky) }
        return nil
    }

    // MARK: Examination

    private func examineCandidates() -> [String] {
        let config = store.config
        return ClickyTaskStore.shared.tasks.compactMap { task -> String? in
            guard !task.dismissed, task.hasReport, !task.isWorking,
                  let definition = DefinitionOfDone.normalized(config.clickyDefinitionsOfDone[task.id]),
                  engineAssessment(task, definition: definition) == nil,
                  Date().timeIntervalSince(definitionReviewFailures[task.id] ?? .distantPast) >= 60 else { return nil }
            return Self.clickyKey(task.id)
        }
    }

    /// Reviews exactly one task per pass so a slow or failing review can never hold the others.
    private func examineNext() async {
        let source = ClickyTaskStore.shared
        let config = store.config
        guard config.ollamaEnabled, TaskPlanning.usesLocalOllama(config) else { return }
        let candidates = examineCandidates()
        let priority = enginePriorityKeys.first { $0.hasPrefix("clicky:") }
        enginePriorityKeys.removeAll { $0.hasPrefix("clicky:") }
        guard let key = priority ?? engine.examineOrder(candidates).first,
              let task = source.task(String(key.dropFirst(7))), !source.assessing.contains(task.id) else { return }
        let started = Date()
        engineActivity = ("Examining “\(task.name)” against its Done with local Ollama", key, started)
        if var current = engine.records[key] {
            current.stage = .examining
            current.detail = "Examining the latest response with local Ollama…"
            engine.records[key] = current
        }
        let finished = await withTimeout(Self.engineExamineTimeout) {
            await source.assess(task, config: config, localOnly: true)
        }
        engineActivity = nil
        let seconds = Int(Date().timeIntervalSince(started))
        if let assessment = finished, assessment.source.hasPrefix("ollama") {
            definitionReviewFailures[task.id] = nil
            record("task engine · “\(task.name)”: examined in \(seconds) s — \(assessment.meetsDefinition == true ? "meets Done" : "\(assessment.missing.count) gap(s)")")
        } else {
            definitionReviewFailures[task.id] = Date()
            record("task engine · “\(task.name)”: local review \(finished == nil ? "timed out after \(seconds) s" : "unavailable: \(finished?.reason.prefix(120) ?? "")") — moving to the next task")
        }
        deriveAll()
        lastDefinitionCheckAtReset()
    }

    func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @MainActor () async -> T) async -> T? {
        await withCheckedContinuation { continuation in
            let gate = OnceGate()
            Task { @MainActor in
                let value = await work()
                if gate.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if gate.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    // MARK: Integrity

    private func checkIntegrity(fresh: Bool) {
        guard fresh else { return }
        let source = ClickyTaskStore.shared
        let names = Dictionary(grouping: source.tasks.filter { !$0.dismissed }, by: { Matcher.normalize($0.name) })
        for task in taskCatalog.tasks where task.sourceUnavailable != true {
            guard let live = source.task(task.id) else { continue }
            if Matcher.normalize(live.name) != Matcher.normalize(task.name) {
                record("task engine · integrity: Cruise lists “\(task.name)” but HeyClicky now calls it “\(live.name)”; refreshing the catalog")
                Task { await refreshTaskCatalog() }
                break
            }
        }
        for (name, tasks) in names where tasks.count > 1 {
            record("task engine · integrity: \(tasks.count) HeyClicky tasks share the name “\(name)”; name-based sends to them are held")
        }
    }

    // MARK: VS Code

    private func vscodeEngineKeys(config: Config) -> Set<String> {
        Set(config.vscodeDefinitionsOfDone.keys).union(config.vscodeAutoBumpChatKeys)
            .union(vscodeSessionsSeen.map(\.key))
    }

    private func deriveVSCode(key: String, config: Config) -> TaskEngineRecord {
        let session = vscodeSessionsSeen.first { $0.key == key }
        let title = session?.title ?? engine.records[key]?.title ?? engine.metadata[key]?.title ?? "VS Code chat"
        let definition = DefinitionOfDone.normalized(config.vscodeDefinitionsOfDone[key])
        let autoBump = config.vscodeAutoBumpChatKeys.contains(key)
        let project = config.vscodeTaskProjects[key]
        let plan = config.vscodeTaskPlans[key] ?? TaskPlan()
        let cached = vscodeDrafts[key]
        let metadata = TaskMetadata(title: title, exists: session != nil, status: session?.state ?? "not visible",
                                    folder: project?.directoryPath, done: definition, autoBump: autoBump,
                                    plan: TaskWorkflow.finishRequestKey(project: project ?? TaskProject(), plan: plan,
                                                                      definition: definition),
                                    report: cached?.transcriptTail ?? "")
        if session != nil || engine.metadata[key] != nil { logMetadata(key: key, metadata: metadata) }
        let inputs = TaskEngineCache.inputsKey([cached?.transcriptTail, definition, metadata.folder, metadata.plan, String(autoBump)])
        var record = TaskEngineRecord(key: key, provider: "vscode", title: title, stage: .examining, detail: "",
                                      inputsKey: inputs, autoBump: autoBump)
        guard let definition else {
            record.stage = .needsDone
            record.detail = session.map { "Examined · VS Code status “\($0.state)”. No reply is drafted until Done is defined." }
                ?? "Not visible in VS Code's Sessions list. No reply is drafted until Done is defined."
            if session != nil, engine.records[key]?.inputsKey != inputs || engine.records[key]?.examinedAt == nil {
                record.examinedAt = Date()
            }
            record.blocker = TaskBlocker("Define what done looks like for this chat; Cruise then reviews and drafts automatically.", fix: .defineDone)
            return record
        }
        guard let session else {
            record.stage = .held
            record.detail = "Not in VS Code's Sessions list."
            record.blocker = TaskBlocker("Cruise can't see this chat in VS Code's Sessions list (renamed, archived, closed, or scrolled away). Open it in VS Code.", fix: .openVSCodeChat)
            return record
        }
        if session.ambiguous {
            record.stage = .held
            record.detail = "Two visible sessions match this chat."
            record.blocker = TaskBlocker("More than one VS Code session has this title, so Cruise won't act on either. Rename one in VS Code.", fix: .openVSCodeChat)
            return record
        }
        if config.mode == .rest {
            record.stage = .held
            record.detail = "Rest mode pauses VS Code examination and sending."
            record.blocker = TaskBlocker("Rest mode pauses VS Code task follow-ups. Switch Cruise to Manual or Cruise mode.", fix: .automationSettings)
            return record
        }
        let status = vscodeTaskStatuses[key]
        guard let cached, DefinitionOfDone.normalized(cached.definition) == definition else {
            record.stage = .examining
            record.detail = status ?? "Waiting for the next background examination pass. Cruise reads the exact chat without activating VS Code, then restores the previous chat."
            return record
        }
        record.examinedAt = cached.at
        record.missing = cached.missing
        if let reason = TaskWorkflow.messageBlocker(project: project ?? TaskProject(), plan: plan, requiresBuildLocation: false) {
            record.stage = .held
            record.detail = "Complete Done's workflow choices before drafting or sending."
            record.blocker = TaskBlocker(reason, fix: .defineDone)
            return record
        }
        guard cached.unfinished, let message = cached.message else {
            record.stage = .met
            record.detail = "The latest response appears to cover Done. Check its evidence before relying on it."
                + (cached.evidence.map { "\n\nResponse evidence:\n\($0.suffix(3000))" } ?? "")
            return record
        }
        record.draft = message
        record.stage = .drafted
        if let evidence = cached.evidence,
           engine.isReviewOnly(key, report: evidence, definition: definition) {
            record.stage = .held
            record.detail = "Examined for your review only. Nothing sent."
            record.blocker = TaskBlocker("Inspect the response and use Send explicitly if more work is needed.", fix: .openVSCodeChat)
            return record
        }
        if let status, status.hasPrefix("Sent") {
            record.stage = .sent
            record.detail = status
            return record
        }
        if !autoBump {
            record.detail = "Draft ready. Press Send, or turn on Auto-bump to send drafts like this automatically."
            return record
        }
        if let reason = TaskWorkflow.autoBumpBlocker(plan: config.vscodeTaskPlans[key] ?? TaskPlan(), requiresBuildLocation: false) {
            record.stage = .held
            record.detail = "Auto-bump needs workflow choices."
            record.blocker = TaskBlocker(reason, fix: .defineDone)
            return record
        }
        if !config.continueUntilDefinedDone {
            record.stage = .held
            record.blocker = TaskBlocker("“Allow per-task auto-bumps” is off in Automation settings.", fix: .automationSettings)
        } else if config.usageCutoffReached {
            record.stage = .held
            record.blocker = TaskBlocker("The Copilot usage cutoff paused automation.", fix: .automationSettings)
        } else if (config.vscodeAutoBumpRounds[key] ?? 0) >= min(max(1, config.maxDefinitionRounds), DefinitionOfDone.maxRounds) {
            record.stage = .held
            record.blocker = TaskBlocker("This chat reached its auto-bump round limit. Reset rounds to keep going.", fix: .resetRounds)
        } else if let status, !status.hasPrefix("Watching") {
            record.detail = status
        }
        return record
    }

    // MARK: Held pending message

    /// A held HeyClicky delivery used to occupy the only delivery slot and stop every other task. It now moves to the
    /// held list (shown in Activity) and frees the slot; its task is re-examined and re-drafted from current evidence.
    func archiveBlockingPendingMessage() {
        guard let message = pendingMessage else { return }
        let stale = message.holdReason != nil || Date().timeIntervalSince(message.createdAt) > 10 * 60
        guard stale else { return }
        var held = message
        if held.holdReason == nil { held.hold("Not confirmed within 10 minutes; moved aside so other tasks keep moving.") }
        heldMessages.insert(held, at: 0)
        heldMessages = Array(heldMessages.prefix(30))
        try? JSONEncoder().encode(heldMessages).write(to: Self.heldMessagesURL, options: .atomic)
        guard clearPendingMessage() else { return }
        if let target = message.completionTarget, !message.submissionAttempted {
            // Never submitted, so the reserved round didn't reach HeyClicky; let the engine re-draft this report.
            let source = ClickyTaskStore.shared
            var progress = source.record(target.taskID).progress
            if progress.lastFingerprint == target.reportFingerprint, progress.deliveredAt == nil {
                progress.lastFingerprint = nil
                progress.rounds = max(0, progress.rounds - 1)
                _ = source.restoreProgress(progress, for: target.taskID)
            }
        }
        record("held message for “\(message.task)” moved to Activity → Held messages (\(held.holdReason ?? "")); other tasks continue and this task is re-drafted from its current response")
        lastDefinitionCheckAtReset()
    }

    // MARK: User actions

    func clearHeldMessages() {
        heldMessages = []
        try? FileManager.default.removeItem(at: Self.heldMessagesURL)
    }

    /// One line for the Tasks header: what the engine is doing right now, or a summary when idle.
    var engineSummary: String {
        if let activity = engineActivity {
            return "Now: \(activity.text) · \(Int(Date().timeIntervalSince(activity.since))) s"
        }
        let records = engine.records.values
        let examined = records.filter { $0.examinedAt != nil }.count
        let drafts = records.filter { $0.draft != nil && $0.stage != .sent }.count
        let queued = records.filter { $0.stage == .queued }.count
        let blocked = records.filter { $0.blocker != nil }.count
        return "Idle · \(examined) of \(records.count) tasks examined, \(drafts) drafts ready, \(queued) queued to send"
            + (blocked > 0 ? ", \(blocked) need you (see each task's Go there)" : "")
    }

    func requestEngineExamination(_ key: String) {
        if key.hasPrefix("clicky:") {
            let id = String(key.dropFirst(7))
            definitionReviewFailures[id] = nil
            if let task = ClickyTaskStore.shared.task(id),
               let definition = DefinitionOfDone.normalized(store.config.clickyDefinitionsOfDone[id]) {
                engine.holdForReview(key, report: task.fingerprint, definition: definition)
                saveEngine()
            }
            if let task = ClickyTaskStore.shared.task(id), engineAssessment(task, definition: store.config.clickyDefinitionsOfDone[id] ?? "") != nil {
                // Force a fresh review even when the cached one is current.
                ClickyTaskStore.shared.clearAssessment(for: id)
            }
        } else {
            if let cached = vscodeDrafts[key], let evidence = cached.evidence {
                engine.holdForReview(key, report: evidence, definition: cached.definition)
                saveEngine()
            }
            vscodeDrafts[key] = nil
            vscodeInspectMarks[key] = nil
            lastModelCheckAtReset()
        }
        enginePriorityKeys.removeAll { $0 == key }
        enginePriorityKeys.insert(key, at: 0)
        deriveAll()
        tickTaskEngine()
    }

    func resumeStoppedTask(_ taskID: String) {
        guard let task = ClickyTaskStore.shared.task(taskID) else { return }
        var released = taskRecovery
        released.release(task: task.name)
        do {
            try JSONEncoder().encode(released).write(to: taskRecoveryURL, options: .atomic)
            taskRecovery = released
        } catch {
            record("couldn't save the resume for “\(task.name)”: \(error.localizedDescription)")
            return
        }
        engine.resumed[taskID] = task.fingerprint
        record("task engine · “\(task.name)”: you resumed auto-bump after a stop; Cruise may send its draft now")
        deriveAll()
        saveEngine()
        lastDefinitionCheckAtReset()
    }

    func resetEngineRounds(_ key: String) {
        if key.hasPrefix("clicky:") {
            let id = String(key.dropFirst(7))
            _ = ClickyTaskStore.shared.restoreProgress(DoneProgress(), for: id)
            record("task engine · “\(engine.records[key]?.title ?? id)”: follow-up rounds reset by you")
        } else {
            resetVSCodeTaskProgress(for: key)
            record("task engine · “\(engine.records[key]?.title ?? key)”: VS Code follow-up rounds reset by you")
        }
        deriveAll()
        saveEngine()
        lastDefinitionCheckAtReset()
    }

    /// Navigates to where `fix` can be resolved. Returns a status line when the action itself reports one.
    func perform(_ fix: TaskFix, key: String) async -> String? {
        let id = key.hasPrefix("clicky:") ? String(key.dropFirst(7)) : nil
        switch fix {
        case .showInHeyClicky:
            guard let id else { return nil }
            return await showTaskInHeyClicky(id)
        case .openVSCodeChat:
            guard let session = vscodeSessionsSeen.first(where: { $0.key == key }) else {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Visual Studio Code.app"))
                return "Opened VS Code. Find the chat in the Sessions list; Cruise picks it up automatically."
            }
            let ok = await Worker.scanVSCode { VSCodeScanner(config: self.store.config).openTaskSession(session) }
            return ok ? nil : "Couldn't select “\(session.title)” in VS Code. Open it from the Sessions list."
        case .resumeStopped:
            guard let id else { return nil }
            resumeStoppedTask(id)
            return nil
        case .resetRounds:
            resetEngineRounds(key)
            return nil
        case .reviewReport:
            requestEngineExamination(key)
            return nil
        case .refreshTasks:
            await ClickyTaskStore.shared.refresh(measure: false)
            await refreshTaskCatalog()
            deriveAll()
            return nil
        case .automationSettings:
            NotificationCenter.default.post(name: SettingsController.focusSectionNotification, object: 1)
        case .ollamaSettings:
            NotificationCenter.default.post(name: SettingsController.focusOllamaSettingsNotification, object: nil)
        case .permissions:
            NotificationCenter.default.post(name: SettingsController.focusSectionNotification, object: 3)
        case .activity:
            NotificationCenter.default.post(name: SettingsController.focusSectionNotification, object: 2)
        case .defineDone, .chooseFolder:
            NotificationCenter.default.post(name: SettingsController.focusTasksNotification, object: nil)
            if let id { ClickyTaskStore.shared.requestedTaskID = id }
            NotificationCenter.default.post(name: Self.engineFixNotification, object: nil,
                                            userInfo: ["key": key, "fix": fix.rawValue])
        }
        return nil
    }

    static let engineFixNotification = Notification.Name("CruiseControl.engineFix")
}

/// Lets exactly one of two racing tasks resume a continuation.
final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// The latest examined VS Code draft for one chat; cached across passes until its inputs change.
struct VSCodeEngineDraft {
    var transcriptTail: String
    var definition: String
    var unfinished: Bool
    var message: String?
    var missing: [String]
    var at: Date
    var evidence: String? = nil
}
