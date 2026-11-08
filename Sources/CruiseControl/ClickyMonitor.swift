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
    private var lastTaskAuditAt = Date.distantPast
    private var taskAuditStates: [String: ChatBump.State] = [:]
    private let taskAuditURL = ConfigStore.directory.appendingPathComponent("clicky-task-audits.json")

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
        if result.conversation.suffix(6).contains(where: { $0.contains("Please update HeyClicky") || $0.contains("agent_turn_lease_required") }) {
            updateHintAt = Date()
        }

        if await handleConsent(result, config: config) { return }
        if await resumeAfterRelaunch(result, config: config) { return }
        if await handleUpdate(result, config: config) { return }
        if await auditOtherClickyTasks(config: config) { return }
        if await handleNeedsYou(result, config: config) { return }
        if await handleInterruptedCards(result, config: config) { return }
        await handleReports(result, config: config)
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
                config: config, system: TaskAudit.system, taskName: task, latestReport: latestReport)
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
            if await send(draft.message, via: composer) {
                stats.continued += 1
                record("sent task-specific report continuation to “\(task)”")
            } else {
                record("failed to send task-specific report continuation")
            }
        } catch {
            record("couldn't assess task report: \(error.localizedDescription) — no generic fallback sent")
        }

        if let previousApp, previousApp.bundleIdentifier.map({ !config.clickyBundleIDs.contains($0) }) ?? true {
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
        guard let composer = chat.composer else {
            record("couldn't find heyclicky's chat box — nudge not sent")
            return true
        }

        let message = await draftNudge(task: task, transcript: chat.transcript, config: config)
        if await send(message, via: composer) {
            stats.continued += 1
            record("nudged “\(task)”: \(message.prefix(90))\(message.count > 90 ? "…" : "")")
        } else {
            record("failed to send nudge to “\(task)”")
        }

        if let previousApp, previousApp.bundleIdentifier.map({ !config.clickyBundleIDs.contains($0) }) ?? true {
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

    private func selectTask(_ task: String, from chat: ScanResult, config: Config) async -> ScanResult? {
        if chat.selectedTask.map({ Matcher.normalize($0) == Matcher.normalize(task) }) == true { return chat }
        guard
            let row = chat.chatButtons.first(where: {
                Matcher.normalize($0.label) == Matcher.normalize(task) || Matcher.isTaskRow($0.label, title: task)
            })
        else {
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
            if scan.selectedTask.map({ Matcher.normalize($0) == Matcher.normalize(task) }) == true { return scan }
        }
        record("HeyClicky didn't confirm task “\(task)” — no message sent")
        return nil
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
                    latestReport: latestReport)
                state.answeredTranscript = transcript
                taskAuditStates[task] = state
                guard saveTaskAudits() else { break }
                guard draft.unfinished else {
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
                if await send(draft.message, via: freshComposer) {
                    stats.continued += 1
                    sent = true
                    record("task audit resumed “\(task)”: \(draft.message.prefix(160))")
                } else {
                    record("task audit couldn't send to “\(task)” — not redirecting to another task")
                }
            } catch {
                record("task audit failed for “\(task)”: \(error.localizedDescription)")
            }
        }
        if let task = original.selectedTask {
            let scan = await Worker.run { ClickyScanner(config: config).scan() }
            _ = await selectTask(task, from: scan, config: config)
        }
        if let previousApp, previousApp.bundleIdentifier.map({ !config.clickyBundleIDs.contains($0) }) ?? true {
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
        guard let composer = chat.composer else {
            record("couldn't find heyclicky's chat box — apology not sent")
            return true
        }
        if await send(config.interruptedNudge, via: composer) {
            stats.continued += 1
            record("told “\(task)” to keep going after the accidental interrupt")
        } else {
            record("failed to send the apology on “\(task)”")
        }
        if let previousApp, previousApp.bundleIdentifier.map({ !config.clickyBundleIDs.contains($0) }) ?? true {
            previousApp.activate()
        }
        return true
    }

    // MARK: "Interrupted · It was cut off before it finished" → polite bump

    /// A restart (or crash) leaves HeyClicky's task cards saying "Interrupted" with a Retry button, and HeyClicky just
    /// sits idle. While you're away, open that task's chat and politely ask it to carry on; if the chat can't be
    /// opened, press the card's Retry instead. Checks right after launch, then every `stallCheckMinutes`.
    private func handleInterruptedCards(_ result: ScanResult, config: Config) async -> Bool {
        guard config.resumeAfterInterrupt, config.autoContinueReports, config.mode != .manual,
              Self.idleSeconds() >= config.awayIdleSeconds else { return false }
        let now = Date()
        var cards = result.interrupted
        if cards.isEmpty {
            guard now.timeIntervalSince(lastInterruptedProbeAt) > config.stallCheckMinutes * 60 else { return false }
            lastInterruptedProbeAt = now
            cards = await hoverNotch(config: config, until: { !$0.interrupted.isEmpty })?.interrupted ?? []
        }
        guard let card = cards.first(where: { now.timeIntervalSince(lastInterruptedBump[$0.task] ?? .distantPast) > 1800 }) else {
            return false
        }
        let task = card.task
        let limits = ReportGate.Limits(config: config)
        guard nudgeLimiter.allow(task: task, now: now, maxPerHour: config.maxNudgesPerTaskPerHour),
              gate.canContinue(now: now, limits: limits) else { return false }

        lastInterruptedBump[task] = now
        nudgeLimiter.record(task: task, at: now)
        gate.recordContinue(at: now)
        saveBudget()
        lastActionAt = now
        record("“\(task)” was interrupted and heyclicky is idle — giving it a polite bump")

        let previousApp = NSWorkspace.shared.frontmostApplication
        defer {
            if let previousApp, previousApp.bundleIdentifier.map({ !config.clickyBundleIDs.contains($0) }) ?? true {
                previousApp.activate()
            }
        }
        if var chat = await revealChat(config: config) {
            guard let selected = await selectTask(task, from: chat, config: config) else { return true }
            chat = selected
            if let composer = chat.composer {
                if await send(config.interruptedCardNudge, via: composer) {
                    stats.continued += 1
                    record("asked “\(task)” to pick up where it left off")
                    return true
                }
                record("couldn't type into heyclicky's chat — trying Retry on the card")
            } else {
                record("heyclicky's chat box isn't reachable — trying Retry on the card")
            }
        } else {
            record("heyclicky's chat window didn't open — trying Retry on the card")
        }
        // No chat box: the card's own Retry button re-runs the turn.
        var retried = false
        _ = await hoverNotch(config: config, until: { $0.interrupted.contains { $0.task == task && $0.retry != nil } }) { scan in
            if let retry = scan.interrupted.first(where: { $0.task == task })?.retry { retried = AX.press(retry) }
        }
        if retried {
            stats.continued += 1
            record("pressed Retry on “\(task)”")
        } else {
            record("couldn't bump “\(task)” — chat box and Retry both unavailable")
        }
        return true
    }

    // MARK: VS Code chat tool confirmations → Ollama safety check → Allow Once

    private func tickVSCode() {
        let config = store.config
        guard config.vscodeAutoApprove, axTrusted, !vscodeBusy, !modelBusy,
              Date().timeIntervalSince(lastVSCodeCheckAt) >= config.vscodeCheckSeconds else { return }
        lastVSCodeCheckAt = Date()
        vscodeBusy = true
        Task {
            await handleVSCode(config: config)
            vscodeBusy = false
        }
    }

    private func handleVSCode(config: Config) async {
        guard let pending = await Worker.run({ VSCodeScanner(config: config).scan() }) else { return }
        let key = Matcher.normalize(pending.request)
        let short = pending.request.replacingOccurrences(of: "\n", with: " ").prefix(110)
        let now = Date()

        guard now.timeIntervalSince(approvalAttempts[key] ?? .distantPast) >= 5 else { return }
        if let cached = reviews[key] {
            // Unsafe verdicts stick; a failed review is retried after a minute.
            if cached.verdict?.safe == false || (cached.verdict == nil && now.timeIntervalSince(cached.at) < 60) { return }
        }
        let verdict: ApprovalReview.Verdict
        if let cached = reviews[key]?.verdict {
            verdict = cached
        } else if let reason = ApprovalReview.hardBlockReason(pending.request) {
            verdict = ApprovalReview.Verdict(safe: false, reason: reason)
            remember(key, verdict)
            stats.vscodeHeldForReview += 1
            record("vscode: left for you — \(reason): \(short)")
            return
        } else {
            record("vscode: reviewing with ollama → \(short)")
            do {
                let review = try await Ollama.reviewApproval(pending.request, config: config)
                verdict = review.verdict
                remember(key, verdict)
                if !verdict.safe {
                    stats.vscodeHeldForReview += 1
                    record("vscode: left for you — ollama (\(review.model)) flagged it: \(verdict.reason)")
                    return
                }
            } catch {
                remember(key, nil)
                record("vscode: couldn't review (\(error.localizedDescription)) — leaving it for you")
                return
            }
        }

        // Only press if the very same request is still waiting (the review can take a few seconds).
        guard let still = await Worker.run({ VSCodeScanner(config: config).scan() }),
              Matcher.normalize(still.request) == key, store.config.vscodeAutoApprove else { return }
        approvalAttempts[key] = Date()
        let allow = still.allow
        var pressed = await Worker.run { AX.press(allow) }
        if !pressed { pressed = await mouseClick(on: allow) }
        if pressed {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let remaining = await Worker.run { VSCodeScanner(config: config).scan() }
            if remaining.map({ Matcher.normalize($0.request) == key }) == true {
                record("vscode: approval still pending after pressing — will retry: \(short)")
            } else {
                stats.vscodeApproved += 1
                lastActionAt = Date()
                record("vscode: \(still.allowLabel.lowercased()) → \(short) (\(verdict.reason))")
            }
        } else {
            record("vscode: couldn't press “\(still.allowLabel)”")
        }
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
        guard let composer = chat.composer else {
            record("couldn't find heyclicky's chat box — reply not sent")
            return true
        }
        let context = chat.transcript.isEmpty ? conversation : chat.transcript
        let message = await draftNudge(task: task, transcript: context, config: config,
                                       note: Nudge.stallNote(lastLine: lastLine, minutes: quietMinutes))
        if await send(message, via: composer) {
            stats.continued += 1
            record("replied on “\(task)”: \(message.prefix(90))\(message.count > 90 ? "…" : "")")
        } else {
            record("failed to send the reply on “\(task)”")
        }
        if let previousApp, previousApp.bundleIdentifier.map({ !config.clickyBundleIDs.contains($0) }) ?? true {
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

    private func send(_ text: String, via composer: Composer) async -> Bool {
        if await Worker.run({ Self.sendViaAccessibility(composer, text: text) }) { return true }
        return await sendViaPaste(composer, text: text)
    }

    nonisolated private static func sendViaAccessibility(_ composer: Composer, text: String) -> Bool {
        AX.setFocused(composer.input)
        guard AX.setValue(composer.input, text) else { return false }
        usleep(300_000)
        guard AX.stringValue(composer.input)?.contains(text.prefix(24)) == true else { return false }

        if let send = composer.send, AX.isEnabled(send) {
            AX.press(send)
        } else {
            return false
        }
        usleep(800_000)
        let remaining = AX.stringValue(composer.input) ?? ""
        return !remaining.contains(text.prefix(24))
    }

    private func sendViaPaste(_ composer: Composer, text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        NSRunningApplication(processIdentifier: composer.pid)?.activate()
        try? await Task.sleep(nanoseconds: 400_000_000)

        let input = composer.input
        await withOverlayHidden {
            await Worker.run {
                AX.setFocused(input)
                if let frame = AX.frame(input) {
                    InputSynth.click(at: CGPoint(x: frame.midX, y: frame.midY))
                }
                InputSynth.key(InputSynth.keyA, flags: .maskCommand)
                InputSynth.key(InputSynth.keyV, flags: .maskCommand)
                usleep(250_000)
                InputSynth.key(InputSynth.keyReturn)
            }
        }
        try? await Task.sleep(nanoseconds: 900_000_000)

        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }

        let remaining = await Worker.run { AX.stringValue(input) ?? "" }
        return !remaining.contains(text.prefix(24))
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
            if await send(message, via: composer) {
                stats.continued += 1
                lastActionAt = sentAt
                record("nudged “\(name)” after the update: \(message.prefix(90))\(message.count > 90 ? "…" : "")")
            } else {
                record("failed to send the post-update nudge to “\(name)”")
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        if let previousApp, previousApp.bundleIdentifier.map({ !config.clickyBundleIDs.contains($0) }) ?? true {
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
