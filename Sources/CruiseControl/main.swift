import AppKit
import CruiseCore

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

if CommandLine.arguments.contains("--model-menu") || CommandLine.arguments.contains("--select-model") {
    MainActor.assumeIsolated {
        Task { @MainActor in
            do {
                let config = Config()
                guard let chat = VSCodeModels.scan(config: config) else {
                    throw VSCodeModels.ModelError.action("no unambiguous active VS Code chat found")
                }
                print("Current model: \(chat.model); running: \(chat.running)")
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
    if CommandLine.arguments.contains("--verbose") { result.transcript.suffix(60).forEach { print("  > \($0.prefix(220))") } }
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
