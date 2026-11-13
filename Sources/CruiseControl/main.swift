import AppKit
import CruiseCore

if CommandLine.arguments.contains("--validate-brand-icons") {
    BrandIcons.validate()
    print("All eight brand PNGs loaded successfully.")
    exit(0)
}

if CommandLine.arguments.contains("--scan-clicky-storage") {
    do {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CruiseControl")
        let configURL = directory.appendingPathComponent("config.json")
        let config = FileManager.default.fileExists(atPath: configURL.path)
            ? try JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL)) : Config()
        let agent = try HeyClickyStorageLocation.agentRoot(bundleIDs: config.clickyBundleIDs)
        let tasks = try ClickyTaskLibrary.tasks(
            jobs: ClickyTaskLibrary.decodeJobs(ClickyTaskStore.readJobsData()), activity: [:])
        let catalogURL = directory.appendingPathComponent("task-catalog.json")
        let catalog = FileManager.default.fileExists(atPath: catalogURL.path)
            ? try JSONDecoder().decode(TaskCatalog.self, from: Data(contentsOf: catalogURL)) : TaskCatalog()
        var sources = CacheInventory.sources(tasks: tasks, catalog: catalog,
                                             cacheRoot: ClickyTaskLibrary.defaultRoot, workspaceRoot: agent)
        sources.append(.init(kind: .workspace, path: agent.path, taskName: "HeyClicky Agent workspaces", includeMissing: true))
        let projects = ClickyTaskLibrary.defaultRoot.appendingPathComponent("projects")
        if FileManager.default.fileExists(atPath: projects.path) {
            sources.append(.init(kind: .workspace, path: projects.path, taskName: "HeyClicky projects"))
        }
        let started = ProcessInfo.processInfo.systemUptime
        let report = CacheInventory.scanReport(sources: sources, taskCount: tasks.count, storageRoots: [
            .init(label: "Clicky support / cache", path: ClickyTaskLibrary.defaultRoot.path),
            .init(label: "HeyClicky Agent folder", path: agent.path),
        ], progress: { progress in
            guard let report = progress.report else { return }
            print("Progress \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - started))s: \(progress.entriesVisited) entries; \(report.clickyStorageApparentBytes ?? 0) bytes; \(report.measuredCachePathCount) cache paths; \(report.taskCacheBytes) cache bytes")
            fflush(stdout)
        })
        for root in report.storageRoots {
            print("Root \(root.path): apparent=\(root.apparentBytes.map(String.init) ?? "unknown") allocated=\(root.allocatedBytes.map(String.init) ?? "unknown") files=\(root.fileCount) error=\(root.error ?? "none")")
        }
        print("Completed in \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - started))s: cache=\(report.taskCacheBytes) workspace=\(report.workspaceBytes) other=\(report.otherSupportBytes ?? 0) total=\(report.clickyStorageApparentBytes ?? 0) partial=\(report.isPartial)")
        exit(report.isPartial ? 2 : 0)
    } catch {
        fputs("Storage scan failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--infer-task-project") {
    MainActor.assumeIsolated {
        Task { @MainActor in
            do {
                guard CommandLine.arguments.count == index + 2 else {
                    throw NSError(domain: "CruiseControl", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Specify exactly one stable HeyClicky job ID.",
                    ])
                }
                let id = CommandLine.arguments[index + 1]
                let root = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/CruiseControl")
                let configURL = root.appendingPathComponent("config.json")
                let config = FileManager.default.fileExists(atPath: configURL.path)
                    ? try JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL)) : Config()
                let tasks = try ClickyTaskLibrary.load(jobsData: ClickyTaskStore.readJobsData())
                guard let task = tasks.first(where: { $0.id == id }) else {
                    throw NSError(domain: "CruiseControl", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "No HeyClicky job has that ID.",
                    ])
                }
                let catalogURL = root.appendingPathComponent("task-catalog.json")
                let catalog = FileManager.default.fileExists(atPath: catalogURL.path)
                    ? try JSONDecoder().decode(TaskCatalog.self, from: Data(contentsOf: catalogURL)) : TaskCatalog()
                let known = catalog.groups(by: .project, sort: .name).filter { $0.id != "unassigned" }.map(\.project)
                let (project, model, answer) = try await Ollama.inferProject(task, known: known, config: config)
                print("Task: \(task.name) (\(task.id))")
                print("Exact thread joins: \(task.threadIDs.count); cache references: \(task.threadReferences.count)")
                for id in task.threadIDs {
                    let refs = task.threadReferences.filter { $0.threadID == id }
                    print("  \(id): \(refs.count) excerpts; \(Set(refs.map(\.source)).count) source locations")
                }
                task.evidenceErrors.forEach { print("Cache warning: \($0)") }
                print("Project: \(project?.title ?? "Unspecified"); model: \(model)")
                print("Model proposal: \(answer.name) | \(answer.repository); confidence: \(answer.confidence)")
                print("Supporting quote: \(answer.evidence)")
                print("Literal quote found: \(ProjectInference.evidence(for: task).contains(answer.evidence)); matching known labels: "
                    + known.filter {
                        Matcher.normalize($0.title ?? "").filter { $0.isLetter || $0.isNumber }
                            == Matcher.normalize(answer.name).filter { $0.isLetter || $0.isNumber }
                    }.map { "\($0.title ?? "") [\($0.repositoryName ?? "no repository")]" }.joined(separator: ", "))
                print("Read-only local inference; no assignments, goals or chats changed. No message sent.")
                exit(0)
            } catch {
                fputs("Project inference failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.run()
    }
}

if CommandLine.arguments.contains("--inspect-vscode") {
    VSCodeScanner(config: Config()).diagnosticTree().forEach { print($0) }
    exit(0)
}

if CommandLine.arguments.contains("--scan-vscode-sessions") {
    let config = MainActor.assumeIsolated { ConfigStore().config }
    for session in VSCodeScanner(config: config).visibleTaskSessions() {
        print("\(session.key) · \(session.title) · state: \(session.state) · workspace: \(session.workspaceTitle ?? "none") · window: \(session.windowTitle)\(session.ambiguous ? " · AMBIGUOUS" : "")")
    }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--vscode-key") {
    let title = CommandLine.arguments.dropFirst(index + 1).first ?? ""
    print(VSCodeChatIdentity.stableKey(bundleIdentifier: "com.microsoft.VSCode", taskTitle: title))
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--inspect-vscode-session") {
    let config = MainActor.assumeIsolated { ConfigStore().config }
    let key = CommandLine.arguments.dropFirst(index + 1).first ?? ""
    guard let session = VSCodeScanner(config: config).visibleTaskSessions().first(where: { $0.key == key }) else {
        print("session \(key) is not visible in any VS Code Sessions list")
        exit(1)
    }
    do {
        let chat = try VSCodeModels.inspect(config: config, session: session)
        print("read \(chat.taskTitle) · model \(chat.model) · running \(chat.running) · \(chat.transcript.count) transcript characters · composer \(chat.draft.debugDescription)")
        exit(0)
    } catch {
        print("unreadable: \(error.localizedDescription)")
        exit(1)
    }
}

if CommandLine.arguments.contains("--scan-vscode") {
    let scanner = VSCodeScanner(config: Config())
    for pending in scanner.scanAll() {
        print("Source: \(pending.sidebarThread.map { "sidebar: \($0)" } ?? "chat dialog")")
        print("Key: \(pending.key)")
        var actions: CFArray?
        AXUIElementCopyActionNames(pending.allow, &actions)
        print("Actions: \((actions as? [String] ?? []).joined(separator: ", "))")
        print("Request: \(pending.request)")
    }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--approve-vscode-sidebar") {
    let key = CommandLine.arguments.dropFirst(index + 1).joined(separator: " ")
    MainActor.assumeIsolated {
        Task { @MainActor in
            let app = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let pointer = CGEvent(source: nil)?.location
            let store = ConfigStore()
            let monitor = ClickyMonitor(store: store)
            let scanner = VSCodeScanner(config: store.config)
            guard let pending = scanner.scanAll().first(where: { $0.key == key && $0.sidebarThread != nil }) else {
                fputs("Sidebar request missing or changed; no action taken.\n", stderr)
                exit(1)
            }
            let selected = scanner.selectedThread(in: pending.window)
            let approved = await monitor.approveVSCodeSidebar(key: key)
            monitor.log.forEach { print($0.text) }
            let unchanged = selected == scanner.selectedThread(in: pending.window)
                && app == NSWorkspace.shared.frontmostApplication?.processIdentifier
                && pointer == CGEvent(source: nil)?.location
            print("Approval verified: \(approved); selected chat, foreground app and pointer unchanged: \(unchanged)")
            exit(approved && unchanged ? 0 : 1)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.run()
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--verify-clicky-delivery") {
    MainActor.assumeIsolated {
        Task { @MainActor in
            let task = CommandLine.arguments.dropFirst(index + 1).joined(separator: " ")
            guard !task.isEmpty else {
                fputs("Specify the HeyClicky task for the receipt-only test.\n", stderr)
                exit(1)
            }
            let monitor = ClickyMonitor(store: ConfigStore())
            let delivered = await monitor.verifyMessageDelivery(task: task)
            monitor.log.reversed().forEach { print($0.text) }
            exit(delivered ? 0 : 1)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.run()
    }
}

if CommandLine.arguments.contains("--inspect-main-chat") {
    // Dry run: open HeyClicky's main chat, look for a tap-out and print the reply Cruise would send. Never sends.
    MainActor.assumeIsolated {
        Task { @MainActor in
            var config = Config()
            if let data = try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/CruiseControl/config.json")),
               let saved = try? JSONDecoder().decode(Config.self, from: data) { config = saved }
            var scan = ClickyScanner(config: config).scan()
            if !scan.mainChat, let row = scan.chatButtons.first(where: {
                Matcher.normalize($0.label) == Matcher.normalize(MainChatTapOut.chatName) || Matcher.isTaskRow($0.label, title: MainChatTapOut.chatName)
            }) {
                _ = AX.press(row.element)
                for _ in 0..<10 where !scan.mainChat {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    scan = ClickyScanner(config: config).scan()
                }
            }
            print("Main chat on screen: \(scan.mainChat); composer: \(scan.composer != nil ? "found" : "missing")")
            print(scan.transcript.suffix(8).map { "  > \($0.prefix(200))" }.joined(separator: "\n"))
            guard let tapOut = MainChatTapOut.detect(scan.transcript) else {
                print("Tap-out: none (latest turn has no unfinished work with a closing question, or it was already answered)")
                exit(0)
            }
            print("Tap-out: “\(tapOut.task)” · \(tapOut.status)\nEvidence:\n" + tapOut.evidence.map { "  - \($0)" }.joined(separator: "\n"))
            let reply = await Ollama.draftTapOutReply(tapOut, config: config)
            print("Reply via \(reply.source) (not sent):\n\(reply.message)")
            exit(0)
        }
        NSApplication.shared.run()
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--inspect-clicky-task") {
    MainActor.assumeIsolated {
        Task { @MainActor in
            do {
                let task = CommandLine.arguments.dropFirst(index + 1).joined(separator: " ")
                let config = Config()
                let scan = ClickyScanner(config: config).scan()
                guard let row = scan.chatButtons.first(where: {
                    Matcher.normalize($0.label) == Matcher.normalize(task) || Matcher.isTaskRow($0.label, title: task)
                }), AX.press(row.element) else {
                    throw VSCodeModels.ModelError.action("task sidebar row is unavailable")
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let selected = ClickyScanner(config: config).scan()
                guard selected.selectedTask == task else {
                    throw VSCodeModels.ModelError.action("selected task could not be verified")
                }
                print("Verified task: \(task); status: \(selected.selectedStatus ?? "unknown")")
                print(selected.transcript.suffix(12).joined(separator: "\n"))
                let draft = try await Ollama.draftChatBump(
                    TaskAudit.context(task: task, transcript: selected.transcript.joined(separator: "\n")),
                    config: config, system: TaskAudit.system, taskName: task,
                    latestReport: TaskAudit.latestTurn(selected.transcript, report: selected.latestReport),
                    implicitYes: true)
                print("Unfinished: \(draft.unfinished); draft (not sent): \(draft.message)")
                exit(0)
            } catch {
                fputs("Task inspection failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        NSApplication.shared.run()
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--preview-task-bump") {
    MainActor.assumeIsolated {
        Task { @MainActor in
            do {
                guard CommandLine.arguments.indices.contains(index + 1) else {
                    throw Ollama.OllamaError.missingDefinition
                }
                let id = CommandLine.arguments[index + 1]
                let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: ConfigStore.directory.appendingPathComponent("config.json")))
                let source = ClickyTaskStore.shared
                let requestedAt = Date()
                async let first: Void = source.refresh(measure: false)
                async let second: Void = source.refresh(measure: false)
                _ = await (first, second)
                guard source.loadedAt.map({ $0 >= requestedAt }) == true, source.loadError == nil,
                      let task = source.task(id),
                      let definition = DefinitionOfDone.normalized(config.clickyDefinitionsOfDone[id]) else {
                    throw VSCodeModels.ModelError.action(source.loadError ?? "current task or saved Done criteria unavailable")
                }
                print("Concurrent fresh report reads completed for job \(id). No saved task state changed.")
                print("Continuation allowed: \(TaskPlanning.continuationAllowed(task, config: config, manual: false))")
                for sentence in task.lastMessage.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
                    where TaskAudit.requiresUser(sentence) {
                    print("User-blocker sentence: \(sentence.trimmingCharacters(in: .whitespaces))")
                }
                let assessment = await Ollama.assessClickyTask(task, definition: definition, config: config, localOnly: true)
                print("Review: \(assessment.state.title) · \(assessment.reason)")
                if let question = assessment.clarificationQuestion { print("Clarification: \(question)") }
                guard TaskDraftGate.evaluate(task: task, definition: definition, assessment: assessment,
                                              finished: false, ambiguous: ClickyTaskLibrary.ambiguousNames(source.tasks).contains(Matcher.normalize(task.name))) == .ready else {
                    print("No eligible draft. Nothing sent.")
                    exit(0)
                }
                let draft = try await Ollama.draftTaskBump(task: task, definition: definition, project: TaskProject(),
                                                          priority: .normal, missing: assessment.missing, config: config)
                print(draft.unfinished ? "Coverage-checked Ollama draft (NOT SENT):\n\(draft.message)"
                      : "Ollama declined; Auto-bump would send the saved-criteria follow-up (NOT SENT):\n"
                        + DefinitionOfDone.criteriaFollowUp(task: task.name, missing: assessment.missing))
                exit(0)
            } catch {
                if case Ollama.OllamaError.incompleteCriteria(_, let message) = error {
                    print("Rejected Ollama draft (NOT SENT):\n\(message)")
                }
                if case Ollama.OllamaError.invalidCoverage(let response) = error {
                    print("Rejected local coverage response:\n\(response)")
                }
                fputs("Preview failed; nothing sent: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        NSApplication.shared.run()
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--clicky-tasks") {
    // Diagnostic: print the Clicky agent task list. `--sort <newest|recentlyUpdated|oldest|longestThread|largestCache|name>`,
    // `--sizes` measures cache sizes, `--assess N` reads the first N tasks with Ollama. Never sends anything.
    MainActor.assumeIsolated {
        Task { @MainActor in
            let args = Array(CommandLine.arguments.dropFirst(index + 1))
            func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
            var config = Config()
            if let data = try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/CruiseControl/config.json")),
               let saved = try? JSONDecoder().decode(Config.self, from: data) { config = saved }
            let store = ClickyTaskStore.shared
            await store.refresh(measure: false)
            if let error = store.loadError { fputs("\(error)\n", stderr); exit(1) }
            if let error = store.persistenceError { fputs("warning: \(error)\n", stderr) }
            if args.contains("--sizes") {
                await store.refresh(measure: true, maxSizeAge: 0)
                while store.measuring { try? await Task.sleep(nanoseconds: 200_000_000) }
            }
            if let job = value("--job"), let definition = value("--definition") {
                config.clickyDefinitionsOfDone[job] = definition
            }
            let sort = value("--sort").flatMap(ClickyTaskSort.init(rawValue:)) ?? .newest
            let jobFilter = value("--job")
            let tasks = ClickyTaskLibrary.sorted(store.tasks.filter { task in
                (!task.dismissed || args.contains("--all")) && (jobFilter.map { [task.id, task.name].contains($0) } ?? true)
            }, by: sort)
            let assessCount = Int(value("--assess") ?? "") ?? 0
            let bytes = ByteCountFormatter()
            print("\(tasks.count) tasks · sorted by \(sort.title)")
            for (offset, task) in tasks.prefix(Int(value("--limit") ?? "") ?? tasks.count).enumerated() {
                let definition = config.clickyDefinitionsOfDone[task.id]
                var assessment = store.currentAssessment(for: task, definition: definition)
                if offset < assessCount { assessment = await store.assess(task, config: config) }
                print("""
                — \(task.name) [\(task.outcome)] job \(task.id)\(task.title.isEmpty ? "" : " · \(task.title)")
                  created \(task.createdAt?.formatted() ?? "?") · updated \(task.updatedAt?.formatted() ?? "?") · \(task.runCount) runs · \(task.messageCount) messages · cache \(task.cacheBytes.map(bytes.string) ?? "?") + job folder \(task.folderBytes.map(bytes.string) ?? "?")
                  last: \(task.lastMessage.replacingOccurrences(of: "\n", with: " ").prefix(220))
                """)
                if let error = store.measureErrors[task.id] { print("  size error: \(error)") }
                if let definition { print("  definition of done: \(definition)") }
                if let assessment {
                    print("  assumed: \(assessment.state.title) via \(assessment.source) — \(assessment.reason)"
                          + (assessment.meetsDefinition.map { " · meets definition: \($0)" } ?? "")
                          + (assessment.missing.isEmpty ? "" : " · missing: \(assessment.missing.joined(separator: "; "))"))
                    if DefinitionOfDone.shouldContinue(task, definition: definition, assessment: assessment,
                                                       progress: store.record(task.id).progress, maxRounds: config.maxDefinitionRounds),
                       let definition {
                        print("  would send (not sent):\n" + DefinitionOfDone.followUp(task: task, definition: definition, missing: assessment.missing,
                            round: store.rounds(for: task, definition: definition) + 1, maxRounds: config.maxDefinitionRounds)
                            .split(separator: "\n").map { "    \($0)" }.joined(separator: "\n"))
                    }
                }
            }
            exit(0)
        }
        NSApplication.shared.run()
    }
}

if CommandLine.arguments.contains("--ollama-settings") {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("CruiseControl.openOllamaSettings"), object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

if CommandLine.arguments.contains("--settings") {
    DistributedNotificationCenter.default().postNotificationName(
        SettingsController.openNotification, object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--draft-chat-bump") {
    let transcript = CommandLine.arguments.dropFirst(index + 1).joined(separator: " ")
    let done = DispatchSemaphore(value: 0)
    Task {
        do {
            let draft = try await Ollama.draftChatBump(transcript, config: Config())
            print(String(decoding: try JSONEncoder().encode(draft), as: UTF8.self))
        } catch {
            fputs("Chat follow-up review failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--assess-model") {
    let transcript = CommandLine.arguments.dropFirst(index + 1).joined(separator: " ")
    let done = DispatchSemaphore(value: 0)
    Task {
        do {
            let assessment = try await Ollama.assessModelProgress(transcript, config: Config())
            let data = try JSONEncoder().encode(assessment)
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fputs("Model review failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

if CommandLine.arguments.contains("--inspect-model-chat") || CommandLine.arguments.contains("--model-menu") || CommandLine.arguments.contains("--select-model") {
    MainActor.assumeIsolated {
        Task { @MainActor in
            do {
                let config = Config()
                let chat = try VSCodeModels.inspect(config: config)
                print("Current model: \(chat.model); running: \(chat.running)")
                if CommandLine.arguments.contains("--inspect-model-chat") {
                    print("Verified chat identity: \(chat.key); transcript characters: \(chat.transcript.count); composer empty: \(chat.draft.isEmpty); send control: \(chat.send != nil)")
                    exit(0)
                }
                if let index = CommandLine.arguments.firstIndex(of: "--select-model") {
                    let model = CommandLine.arguments.dropFirst(index + 1).joined(separator: " ")
                    guard !model.isEmpty else { throw VSCodeModels.ModelError.action("provide a model name") }
                    try await VSCodeModels.select(model, chat: chat, config: config, allowRunning: true)
                    print("Verified model: \(VSCodeModels.scan(config: config)?.model ?? "missing")")
                } else {
                    try VSCodeModels.open(chat)
                    try await Task.sleep(nanoseconds: 700_000_000)
                    for (_, label) in VSCodeModels.options(chat) { print("Option: \(label)") }
                }
                exit(0)
            } catch {
                fputs("Model selection failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        NSApplication.shared.run()
    }
}

if CommandLine.arguments.contains("--scan") {
    // Diagnostic: print what Cruise Control sees in HeyClicky right now, without acting on it.
    let result = ClickyScanner(config: Config()).scan()
    print("HeyClicky running: \(result.clickyRunning) (pid \(result.pid)), Accessibility trusted: \(AXIsProcessTrusted())")
    if let dialog = SystemDialogScanner(config: Config()).scan() {
        print("System dialog: “\(dialog.message.prefix(120))” — allow \(dialog.allow != nil ? "✓" : "✗"), deny \(dialog.deny != nil ? "✓" : "✗")")
    } else {
        print("System dialog: none")
    }
    if let c = result.consent {
        print("Drive prompt: allow=“\(c.allowLabel)” deny=“\(c.denyLabel)” frame=\(AX.frame(c.allow).map { "\($0)" } ?? "?")")
    } else {
        print("Drive prompt: none\(result.orphanConsentLabels.isEmpty ? "" : " (lone buttons: \(result.orphanConsentLabels))")")
    }
    print("Full report buttons: \(result.reports.count)")
    for r in result.reports.suffix(3) { print("  • \(r.fingerprint.prefix(140))") }
    print("Composer: \(result.composer.map { "found at \(AX.frame($0.input).map { "\($0)" } ?? "?"), text “\((AX.stringValue($0.input) ?? "").prefix(40))”" } ?? "missing"), send button: \(result.composer?.send != nil ? "found" : "missing")")
    print("Update button: \(result.update.map { "“\($0.label)”" } ?? "none (only shown while the notch is hovered)")")
    if let info = ClickyMonitor.clickyInfo(Config()) {
        print("Installed heyclicky: \(info.version) (build \(info.build)), feed \(info.feed?.absoluteString ?? "none")")
    }
    print("Open-in-a-window button: \(result.openChat != nil ? "found" : "none")")
    print("Notch says working: \(result.workingCount.map(String.init) ?? "?")")
    print("Latest task card: \(result.lastCard.map { "“\($0.task)” · \($0.status)" } ?? "none")")
    print("Conversation tail:\n" + result.conversation.suffix(4).map { "  · \($0.prefix(110))" }.joined(separator: "\n"))
    print("Needs you card: \(result.needsYou.map { "“\($0.task)” (close button found)" } ?? "none")")
    let handoff = Matcher.handoffLine(in: result.conversation + result.transcript, config: Config())
    print("Interrupt hand-back: \(handoff.map { "“\($0.prefix(80))”" } ?? "none")")
    print("Interrupted cards: \(result.interrupted.isEmpty ? "none (only shown while the notch is hovered)" : result.interrupted.map { "“\($0.task)”\($0.retry != nil ? " (retry ✓)" : "")" }.joined(separator: ", "))")
    print("VS Code confirmation: \(VSCodeScanner(config: Config()).scan().map { "“\($0.allowLabel)” for \($0.request.prefix(160))" } ?? "none")")
    print("Chat transcript lines: \(result.transcript.count)")
    if CommandLine.arguments.contains("--verbose") {
        print("Sidebar rows: " + result.chatButtons.compactMap { TaskRow.parse($0.label) }.map { "\($0.name) [\($0.status)]" }.joined(separator: " · "))
        result.transcript.suffix(60).forEach { print("  > \($0.prefix(220))") }
    }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--review") {
    // Diagnostic: run the VS Code approval review on a request string, without pressing anything.
    let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CruiseControl/config.json")
    let config = (try? Data(contentsOf: configURL)).flatMap { try? JSONDecoder().decode(Config.self, from: $0) } ?? Config()
    let request = CommandLine.arguments.dropFirst(i + 1).joined(separator: " ")
    if let reason = ApprovalReview.hardBlockReason(request) {
        print("BLOCKED (fixed list): \(reason)")
        exit(0)
    }
    let done = DispatchSemaphore(value: 0)
    Task {
        do {
            let review = try await Ollama.reviewApproval(request, config: config)
            print("[\(review.model)] \(review.verdict.safe ? "SAFE" : "FLAGGED"): \(review.verdict.reason)")
        } catch {
            print("review failed (would leave it for you): \(error.localizedDescription)")
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

if CommandLine.arguments.contains("--draft") {
    // Diagnostic: draft a needs-you nudge from the visible chat with Ollama, without sending it.
    let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CruiseControl/config.json")
    let config = (try? Data(contentsOf: configURL)).flatMap { try? JSONDecoder().decode(Config.self, from: $0) } ?? Config()
    let result = ClickyScanner(config: config).scan()
    let task = result.needsYou?.task ?? CommandLine.arguments.drop { $0 != "--draft" }.dropFirst().first { !$0.hasPrefix("--") } ?? "task"
    // --relaunch drafts the post-update nudge, --stall the reply to a quiet conversation.
    let lastLine = result.conversation.last { !$0.hasPrefix("— ") } ?? ""
    let note = CommandLine.arguments.contains("--relaunch") ? Nudge.relaunchNote(fromVersion: "1.1.2", toVersion: "1.1.3")
        : CommandLine.arguments.contains("--stall") ? Nudge.stallNote(lastLine: lastLine, minutes: 5) : ""
    if !note.isEmpty { print("Last line: \(lastLine)") }
    let transcript = Nudge.transcript(result.transcript.isEmpty ? result.conversation : result.transcript, exclude: [config.continuePrompt, config.fallbackNudge, config.relaunchNudge])
    print("Task: \(task) · transcript \(transcript.count) chars\n")
    let done = DispatchSemaphore(value: 0)
    Task {
        do {
            for _ in 0..<3 {
                let draft = try await Ollama.draftNudge(task: task, transcript: transcript, config: config, extraNote: note)
                print("[\(draft.model)] \(Nudge.isSafe(draft.text) ? "safe" : "UNSAFE"): \(draft.text)\n")
            }
        } catch {
            print("ollama failed: \(error.localizedDescription)\nfallback: \(config.fallbackNudge)")
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
