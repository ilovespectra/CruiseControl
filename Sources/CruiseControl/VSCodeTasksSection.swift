import SwiftUI
import UniformTypeIdentifiers
import CruiseCore

struct VSCodeTasksSection: View {
    let session: VSCodeVisibleSession
    @ObservedObject var store: ConfigStore
    @ObservedObject var monitor: ClickyMonitor
    @State private var chat: VSCodeModelChat?
    @State private var definition = ""
    @State private var draft: String?
    @State private var status: String?
    @State private var working = false
    @State private var selectingWorkspace = false
    @State private var diagnosticsExpanded = false
    @State private var workspaceBranches: [String] = []
    @State private var newBranchName = ""
    @State private var branchStatus: String?
    @State private var draftPolicyKey: String?
    @State private var definingDone = false
    @State private var review: Review?

    private struct Review: Equatable {
        let transcript: String
        let policyKey: String
        let unfinished: Bool
        let message: String
    }

    private var currentReview: Review? {
        guard let review, let chat, review.transcript == chat.transcript, review.policyKey == policyKey else { return nil }
        return review
    }

    private var flow: TaskFlow {
        let reviewBlocker: TaskBlocker? = if session.ambiguous {
            TaskBlocker("More than one visible VS Code session has this title, so Cruise won't act on either. Rename one in VS Code.", fix: .openVSCodeChat)
        } else if chat == nil {
            TaskBlocker("Cruise hasn't read this session yet. Open it in VS Code; Cruise reads it on the next pass.", fix: .openVSCodeChat)
        } else if chat?.running == true {
            TaskBlocker("VS Code is still answering in this chat. Cruise reviews it as soon as the turn finishes.", fix: .openVSCodeChat)
        } else if chat?.draft.isEmpty == false {
            TaskBlocker("This chat's VS Code composer has unsent text. Send or clear it so Cruise doesn't overwrite it.", fix: .openVSCodeChat)
        } else { nil }
        let sendBlocker: TaskBlocker? = store.config.mode == .rest
            ? TaskBlocker("Rest mode pauses sending. Switch to Manual or Cruise mode.", fix: .automationSettings)
            : store.config.usageCutoffReached
            ? TaskBlocker("The Copilot usage cutoff paused sending.", fix: .automationSettings) : nil
        let engineActivity = monitor.engineActivity.flatMap { $0.key == taskKey ? $0.text : nil }
        return TaskFlow(
            hasFolder: confirmedWorkspace != nil, hasDefinition: savedDefinition != nil,
            reviewBlocker: reviewBlocker, reviewed: currentReview != nil,
            draftBlocker: TaskWorkflow.messageBlocker(project: project ?? TaskProject(), plan: plan, requiresBuildLocation: false)
                .map { TaskBlocker($0, fix: .defineDone) } ?? (currentReview?.unfinished == false
                ? TaskBlocker("The latest response appears to meet Done. Inspect its evidence before relying on it.", fix: .openVSCodeChat) : nil),
            hasDraft: draft != nil, sendBlocker: sendBlocker,
            activity: working ? "Reading this chat in VS Code" : engineActivity)
    }

    private var autoBumpLockReason: String? {
        if savedDefinition == nil { return "Define what done looks like first (step 2)." }
        if session.ambiguous { return "More than one visible session matches this chat." }
        if confirmedWorkspace == nil { return "Confirm a project folder first." }
        return TaskWorkflow.autoBumpBlocker(plan: plan, requiresBuildLocation: false)
    }
    private var taskKey: String { session.key }
    private var savedDefinition: String? {
        DefinitionOfDone.normalized(store.config.vscodeDefinitionsOfDone[taskKey])
    }
    private var project: TaskProject? { store.config.vscodeTaskProjects[taskKey] }
    private var confirmedWorkspace: String? { project?.directoryPath }
    private var plan: TaskPlan { store.config.vscodeTaskPlans[taskKey] ?? TaskPlan() }
    private var policyKey: String {
        (savedDefinition ?? "") + TaskWorkflow.finishRequestKey(project: project ?? TaskProject(), plan: plan,
                                                              definition: savedDefinition)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.body.weight(.semibold)).textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text(session.state).font(.caption2).padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Brand.card, in: Capsule())
                        if let title = project?.title ?? session.workspaceTitle {
                            Label(title, systemImage: "folder").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 6)
                Menu {
                    ForEach(TaskPriority.allCases) { priority in
                        Button(priority.title) {
                            store.config.vscodeTaskPlans[taskKey, default: TaskPlan()].priority = priority
                        }
                    }
                } label: {
                    TaskMenuPill(title: (plan.priority ?? .normal).title, icon: "flag")
                }
                .help("Cruise review priority only; it does not change VS Code's queue.")
                Button(diagnosticsExpanded ? "Hide details" : "Details") { diagnosticsExpanded.toggle() }
                    .buttonStyle(TaskControlPillStyle(selected: diagnosticsExpanded))
                    .accessibilityIdentifier("vscode-task-details")
            }

            Label("Next: \(flow.nextAction)", systemImage: "arrow.turn.down.right")
                .font(.caption).foregroundStyle(.secondary)

            TaskFolderStep(confirmed: confirmedWorkspace, suggested: session.discoveredDirectory, flow: flow,
                           identifier: "vscode-choose-workspace",
                           useSuggestion: { session.discoveredDirectory.map(confirmWorkspace) },
                           choose: { selectingWorkspace = true })

            TaskDoneCriteriaControl(definition: savedDefinition, identifier: "define-done-vscode-\(taskKey)", flow: flow) {
                definition = store.config.vscodeDefinitionsOfDone[taskKey] ?? ""
                definingDone = true
            }

            if confirmedWorkspace != nil {
                workflowEditor
            }
            if let chat {
                TaskLatestResponseCard(agentName: "VS Code", text: chat.transcript)
            } else {
                Label("No task report available yet", systemImage: "doc.text.magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TaskEngineStatusCard(record: monitor.engine.records[taskKey],
                                 activity: monitor.engineActivity.flatMap { $0.key == taskKey ? $0.text : nil },
                                 goThere: goThere)
            TaskFlowRow(step: .review, flow: flow) {
                TaskFlowButton(title: working ? "Working…" : "Review latest response", systemImage: "text.magnifyingglass",
                               step: .review, flow: flow,
                               help: "Re-reads this exact session and compares its newest response with your saved Done criteria.",
                               identifier: "review-vscode-task", action: examine)
                if flow.state(.review) == .complete {
                    Label(review?.unfinished == true ? "Gaps found" : "Appears done", systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(Brand.periwinkle)
                }
            }
            HStack(spacing: 10) {
                Toggle("Auto-bump this task", isOn: autoBumpBinding)
                    .toggleStyle(.switch).controlSize(.small)
                    .disabled(autoBumpLockReason != nil && !autoBumpBinding.wrappedValue)
                Spacer(minLength: 0)
            }
            .help(autoBumpLockReason ?? "Opt this chat into automatic follow-ups when a fresh response falls short of its saved criteria.")
            Text(autoBumpLockReason.map { "Auto-bump locked: \($0)" } ?? (autoBumpBinding.wrappedValue
                 ? store.config.mode == .rest
                    ? "Auto-bump is selected, but Rest mode pauses sending."
                    : "Auto-bump is on: reviews fresh reports and sends eligible follow-ups in Manual or Cruise, without enabling drive or tool approvals."
                 : "Sending stays under your control: review, generate, then send."))
                .font(.caption2).foregroundStyle(.secondary)
            TaskFlowRow(step: .draft, flow: flow) {
                TaskFlowButton(title: "Generate response", systemImage: "doc.text", step: .draft, flow: flow,
                               help: "Drafts a follow-up for the Done gaps found in the review. Nothing is sent yet.",
                               identifier: "draft-vscode-task-bump", action: generateDraft)
            }
            if let draft {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Draft · not sent", systemImage: "doc.text").font(.caption.weight(.semibold))
                    Text(draft).font(.caption).textSelection(.enabled)
                }
                .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: 8))
            }
            TaskFlowRow(step: .send, flow: flow) {
                TaskFlowButton(title: "Send to VS Code", systemImage: "paperplane.fill", step: .send, flow: flow,
                               help: "Sends exactly the visible draft to this exact session after freshness checks.",
                               identifier: "send-vscode-task-bump", action: sendBump)
                Button(action: navigateToSession) {
                    Label("Show in VS Code", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(ClickyPillButtonStyle(primary: false))
                .disabled(working || session.ambiguous)
                .help(session.ambiguous ? "More than one visible session matches; navigation is refused." : "Opens this exact session in VS Code.")
                .accessibilityIdentifier("open-vscode-session")
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .accessibilityIdentifier("vscode-task-status")
            }

            if diagnosticsExpanded {
                Divider()
                Button(working ? "Checking…" : "Refresh session") { refresh() }
                    .buttonStyle(ClickyPillButtonStyle(primary: false))
                    .disabled(working).accessibilityIdentifier("refresh-vscode-task")
                VStack(alignment: .leading, spacing: 5) {
                    Text("Session key · \(taskKey)").textSelection(.enabled)
                    if let chat {
                        Text("Model · \(chat.model)")
                        Text("Exact session read · \(chat.taskTitle)")
                        Text("Transcript characters · \(chat.transcript.count)")
                    }
                    if let status { Text(status).textSelection(.enabled) }
                    Text("Discovery reads the VS Code Sessions sidebar; navigation, transcript reading and delivery are verified separately. Ambiguous sessions are never acted on.")
                    Text("VS Code integrations expose only visible Accessibility data. A path discovered in Explorer is a suggestion until you explicitly assign it.")
                }
                .font(.caption2).foregroundStyle(.secondary).padding(.top, 6)
            }
        }
        .padding(.vertical, 8)
        .task { refresh() }
        .environment(\.taskGoThere, goThere)
        .onReceive(NotificationCenter.default.publisher(for: ClickyMonitor.engineFixNotification)) { note in
            guard note.userInfo?["key"] as? String == taskKey,
                  let raw = note.userInfo?["fix"] as? String, let fix = TaskFix(rawValue: raw) else { return }
            goThere(fix)
        }
        .onChange(of: policyKey) { _, _ in
            draft = nil
            draftPolicyKey = nil
            review = nil
            monitor.resetVSCodeTaskProgress(for: taskKey)
        }
        .onReceive(monitor.$vscodeTaskStatuses) { statuses in
            if !working, let current = statuses[taskKey] { status = current }
        }
        .fileImporter(isPresented: $selectingWorkspace, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { confirmWorkspace(url.standardizedFileURL.path) }
            case .failure(let error): status = "Folder selection failed: \(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $definingDone) {
            TaskDoneDefinitionEditor(
                taskName: session.title, agentName: "VS Code", definition: $definition,
                plan: workflowPlanBinding, confirmedWorkspace: confirmedWorkspace != nil,
                branches: workspaceBranches, newBranchName: $newBranchName,
                branchStatus: branchStatus, onCreateBranch: createWorkspaceBranch, onSave: saveDefinition)
        }
    }

    private var workflowEditor: some View {
        DoneWorkflowPolicyEditor(
            plan: workflowPlanBinding, confirmedWorkspace: confirmedWorkspace != nil,
            branches: workspaceBranches, newBranchName: $newBranchName,
            branchStatus: branchStatus, onCreateBranch: createWorkspaceBranch, requiresBuildLocation: false)
    }

    private var autoBumpBinding: Binding<Bool> {
        Binding(
            get: { store.config.vscodeAutoBumpChatKeys.contains(taskKey) },
            set: { enabled in
                if enabled {
                    store.config.vscodeAutoBumpChatKeys.insert(taskKey)
                    monitor.resetVSCodeTaskProgress(for: taskKey)
                } else {
                    store.config.vscodeAutoBumpChatKeys.remove(taskKey)
                }
            }
        )
    }

    private var workflowPlanBinding: Binding<TaskPlan> {
        Binding(
            get: { store.config.vscodeTaskPlans[taskKey] ?? TaskPlan() },
            set: { store.config.vscodeTaskPlans[taskKey] = $0 }
        )
    }

    private func createWorkspaceBranch() {
        guard let confirmedWorkspace else { return }
        let name = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try TaskWorkspaceGit.createBranch(name, in: confirmedWorkspace)
            newBranchName = ""
            refreshBranches()
            store.config.vscodeTaskPlans[taskKey, default: TaskPlan()].workBranch = name
            branchStatus = "Created local branch “\(name)” and selected it for this session."
        } catch {
            branchStatus = error.localizedDescription
        }
    }

    private func confirmWorkspace(_ path: String) {
        var value = project ?? TaskProject()
        if value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            value.name = session.workspaceTitle ?? session.title
        }
        value.directory = path
        store.config.vscodeTaskProjects[taskKey] = value
        status = "Folder saved and confirmed for this VS Code task."
        refreshBranches()
    }

    private func refreshBranches() {
        guard let confirmedWorkspace else { workspaceBranches = []; branchStatus = "Choose a confirmed workspace first."; return }
        do {
            workspaceBranches = try TaskWorkspaceGit.branches(in: confirmedWorkspace)
            branchStatus = "Read \(workspaceBranches.count) local branch(es) from the confirmed workspace."
        } catch { branchStatus = error.localizedDescription }
    }

    private func refresh() {
        guard !working else { return }
        refreshBranches()
        working = true
        draft = nil
        let config = store.config
        let target = session
        Task {
            defer { working = false }
            let result: Result<VSCodeModelChat, Error> = await Worker.run {
                Result { try VSCodeModels.inspect(config: config, session: target) }
            }
            switch result {
            case .success(let fresh):
                guard fresh.key == target.key else { status = "Session changed; no response was generated."; return }
                chat = fresh
                status = "Read exact session · \(fresh.taskTitle) · \(fresh.transcript.count) transcript characters."
            case .failure(let error):
                chat = nil
                status = "Session unreadable · \(error.localizedDescription)"
            }
        }
    }

    private func goThere(_ fix: TaskFix) {
        switch fix {
        case .defineDone:
            definition = store.config.vscodeDefinitionsOfDone[taskKey] ?? ""
            definingDone = true
        case .chooseFolder:
            selectingWorkspace = true
        case .reviewReport:
            if flow.state(.review).isEnabled { examine() } else { monitor.requestEngineExamination(taskKey) }
        default:
            Task { if let message = await monitor.perform(fix, key: taskKey) { status = message } }
        }
    }

    private func navigateToSession() {
        guard !session.ambiguous else { status = "Session is ambiguous; navigation was refused."; return }
        working = true
        let config = store.config
        let target = session
        Task {
            defer { working = false }
            let opened = await Worker.scanVSCode { VSCodeScanner(config: config).openTaskSession(target) }
            status = opened ? "Navigated to and verified the exact VS Code session." : "Exact session could not be selected; nothing was sent."
        }
    }

    private func saveDefinition() {
        guard let normalized = DefinitionOfDone.normalized(definition) else { return }
        let changed = store.config.vscodeDefinitionsOfDone[taskKey] != normalized
        store.config.vscodeDefinitionsOfDone[taskKey] = normalized
        if changed { monitor.resetVSCodeTaskProgress(for: taskKey) }
        definition = normalized
        status = "Done definition saved for this exact VS Code session."
    }

    private func examine() {
        guard let savedDefinition, flow.state(.review).isEnabled else { return }
        let expectedPolicyKey = policyKey
        working = true
        draft = nil
        Task {
            defer { working = false }
            do {
                let inspected: Result<VSCodeModelChat, Error> = await Worker.scanVSCode {
                    Result { try VSCodeModels.inspect(config: store.config, session: session) }
                }
                let expected = try inspected.get()
                chat = expected
                monitor.engine.holdForReview(taskKey, report: expected.transcript, definition: savedDefinition)
                monitor.saveEngine()
                guard !expected.running, expected.draft.isEmpty else {
                    status = "The exact session is running, waiting for approval, or contains a draft. Nothing sent."
                    return
                }
                let workflow = confirmedWorkspace == nil
                    ? "No confirmed workspace; ask before assuming a build directory, branch, or delivery target."
                    : TaskWorkflow.instructions(project: project ?? TaskProject(), plan: plan, agentName: "VS Code") ?? ""
                let prompt = """
                Compare the saved Done definition with this freshly read VS Code session transcript. Ask for evidence only for unverified criteria; do not ask the user for work the agent can inspect.
                \(workflow)
                Done definition:
                \(savedDefinition)
                Current transcript:
                \(expected.transcript)
                """
                let result = try await Ollama.draftChatBump(
                    prompt, config: store.config,
                    system: ChatBump.doneReviewSystem,
                    taskName: expected.key)
                let refreshed: Result<VSCodeModelChat, Error> = await Worker.run {
                    Result { try VSCodeModels.inspect(config: store.config, session: session) }
                }
                guard case .success(let fresh) = refreshed,
                      fresh.key == expected.key, fresh.transcript == expected.transcript,
                      policyKey == expectedPolicyKey else {
                    status = "Session changed during review. Refresh; the draft was discarded."
                    return
                }
                review = Review(transcript: fresh.transcript, policyKey: expectedPolicyKey,
                                unfinished: result.unfinished, message: result.message)
                monitor.vscodeDrafts[taskKey] = VSCodeEngineDraft(
                    transcriptTail: String(fresh.transcript.suffix(300)), definition: savedDefinition,
                    unfinished: result.unfinished,
                    message: result.unfinished && TaskWorkflow.messageBlocker(project: project ?? TaskProject(), plan: plan, requiresBuildLocation: false) == nil ? TaskWorkflow.taskBumpMessage(
                        baseMessage: result.message, taskName: session.title, definition: savedDefinition,
                        project: project ?? TaskProject(), plan: plan, agentName: "VS Code") : nil,
                    missing: [], at: Date(), evidence: fresh.transcript)
                monitor.deriveAll(fresh: false)
                if result.unfinished {
                    status = "Review found unverified criteria. Generate a response next."
                } else {
                    status = "Current transcript appears to meet the definition; inspect its evidence before relying on it."
                }
            } catch { status = "Review failed · \(error.localizedDescription)" }
        }
    }

    private func generateDraft() {
        guard flow.state(.draft) == .current else { return }
        makeDraft()
        status = "Draft is local and unsent. Read it, then send."
    }

    private func makeDraft() {
        guard TaskWorkflow.messageBlocker(project: project ?? TaskProject(), plan: plan, requiresBuildLocation: false) == nil else {
            status = TaskWorkflow.messageBlocker(project: project ?? TaskProject(), plan: plan, requiresBuildLocation: false)
            return
        }
        guard let review = currentReview, review.unfinished, let savedDefinition else { return }
        draft = TaskWorkflow.taskBumpMessage(
            baseMessage: review.message, taskName: session.title, definition: savedDefinition,
            project: project ?? TaskProject(), plan: plan, agentName: "VS Code")
        draftPolicyKey = review.policyKey
    }

    private func sendBump() {
        guard let chat, draft != nil, !session.ambiguous, flow.state(.send) == .current else { return }
        working = true
        let expectedChat = chat
        Task {
            defer { working = false }
            await deliverDraft(expectedChat: expectedChat)
        }
    }

    private func deliverDraft(expectedChat: VSCodeModelChat) async {
        if let reason = TaskWorkflow.messageBlocker(project: project ?? TaskProject(), plan: plan, requiresBuildLocation: false) {
            status = reason
            return
        }
        guard let message = draft, let expectedPolicyKey = draftPolicyKey,
              expectedPolicyKey == policyKey, store.config.mode != .rest,
              !store.config.usageCutoffReached else {
            status = "Sending paused: policy changed, Rest mode, or usage cutoff. Review again."
            return
        }
        do {
            try await VSCodeModels.sendFollowUp(message, chat: expectedChat, config: store.config, shouldContinue: {
                policyKey == expectedPolicyKey && store.config.mode != .rest && !store.config.usageCutoffReached
            })
            draft = nil
            status = "Follow-up delivered and confirmed in this exact VS Code session."
            monitor.vscodeTaskStatuses[taskKey] = "Sent \(Date().formatted(date: .omitted, time: .shortened)) · confirmed in this exact VS Code session."
            monitor.engine.recordSent(taskKey, detail: monitor.vscodeTaskStatuses[taskKey] ?? "Sent")
            monitor.saveEngine()
        } catch { status = "Follow-up not confirmed · \(error.localizedDescription)" }
    }

}

private extension Optional where Wrapped == String {
    var flattened: String? { self }
}
