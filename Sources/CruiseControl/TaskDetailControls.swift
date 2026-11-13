import SwiftUI
import UniformTypeIdentifiers
import CruiseCore

struct TaskStepBadge: View {
    let number: Int
    var state: TaskFlow.State = .current

    var body: some View {
        Group {
            if state == .complete {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
            } else {
                Text("\(number)").font(BrandFont.mono(9))
            }
        }
        .foregroundStyle(state.isEnabled ? Brand.navy : Color.secondary)
        .frame(width: 20, height: 20)
        .background(background, in: Circle())
        .overlay(Circle().strokeBorder(state == .current ? Brand.royal : .clear, lineWidth: 1.5))
        .accessibilityLabel("Step \(number)\(state == .complete ? ", done" : state.isEnabled ? ", next" : ", locked")")
    }

    private var background: Color {
        switch state {
        case .complete: Brand.periwinkle.opacity(0.55)
        case .current: Brand.periwinkle
        case .locked: Color.secondary.opacity(0.18)
        }
    }
}

/// A task-flow action: highlighted when it's the next required step, greyed out with a hover reason when locked.
struct TaskFlowButton: View {
    let title: String
    var systemImage: String?
    let step: TaskFlow.Step
    let flow: TaskFlow
    let help: String
    let identifier: String
    let action: () -> Void
    @Environment(\.taskGoThere) private var goThere

    var body: some View {
        let state = flow.state(step)
        // Disabled controls don't reliably show tooltips on macOS, so a locked step states its reason inline.
        VStack(alignment: .leading, spacing: 3) {
            Button(action: action) {
                if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
            }
            .buttonStyle(ClickyPillButtonStyle(primary: state == .current))
            .disabled(!state.isEnabled)
            .accessibilityIdentifier(identifier)
            .accessibilityHint(state.reason ?? help)
            if let reason = state.reason {
                Label(reason, systemImage: "lock.fill")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(identifier)-locked-reason")
                if let fix = state.fix, let goThere {
                    TaskGoThereButton(fix: fix, identifier: "\(identifier)-go-there", action: goThere)
                }
            }
        }
        .contentShape(Rectangle())
        .help(state.reason ?? help)
    }
}

/// Navigates to where a blocker can be fixed. Panels install it with `.environment(\.taskGoThere, …)`.
private struct TaskGoThereKey: EnvironmentKey {
    static let defaultValue: ((TaskFix) -> Void)? = nil
}

extension EnvironmentValues {
    var taskGoThere: ((TaskFix) -> Void)? {
        get { self[TaskGoThereKey.self] }
        set { self[TaskGoThereKey.self] = newValue }
    }
}

struct TaskGoThereButton: View {
    let fix: TaskFix
    var identifier = "task-go-there"
    let action: (TaskFix) -> Void

    var body: some View {
        Button { action(fix) } label: {
            Label(fix.title, systemImage: "arrow.right.circle.fill")
        }
        .buttonStyle(.plain).font(.caption2.weight(.semibold)).foregroundStyle(Brand.periwinkle)
        .accessibilityIdentifier(identifier)
    }
}

/// The engine's live status for one task: stage, exact detail, the cached draft, and any blocker with its fix.
struct TaskEngineStatusCard: View {
    let record: TaskEngineRecord?
    var activity: String?
    let goThere: (TaskFix) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(activity ?? record?.stage.title ?? "Waiting for the first examination")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                if let at = record?.examinedAt {
                    Text("examined \(at.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if let detail = record?.detail, !detail.isEmpty {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let blocker = record?.blocker {
                Label(blocker.reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if let fix = blocker.fix {
                    TaskGoThereButton(fix: fix, identifier: "engine-go-there", action: goThere)
                }
            }
        }
        .padding(9).frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.card.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("task-engine-status")
    }

    private var icon: String {
        switch record?.stage {
        case .sent, .met: "checkmark.circle.fill"
        case .failed, .held: "exclamationmark.circle.fill"
        case .examining, .sending, .queued: "arrow.triangle.2.circlepath"
        default: "circle.dotted"
        }
    }
    private var tint: Color {
        switch record?.stage {
        case .failed, .held: .orange
        case .sent, .met: Brand.periwinkle
        default: .secondary
        }
    }
}

struct TaskFlowRow<Content: View>: View {
    let step: TaskFlow.Step
    let flow: TaskFlow
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            TaskStepBadge(number: step.rawValue, state: flow.state(step))
            content()
            Spacer(minLength: 0)
        }
    }
}

struct TaskLatestResponseCard: View {
    let agentName: String
    let text: String
    var updatedAt: Date?
    @State private var copied = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Latest \(agentName) response", systemImage: "text.bubble")
                    .font(.caption.weight(.semibold))
                Spacer()
                if let updatedAt {
                    Text(updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label(copied ? "Copied" : "Copy report", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(TaskControlPillStyle(selected: copied))
                .accessibilityLabel(copied ? "Report copied" : "Copy full report")
            }
            TaskReportContent(text: String(text.prefix(expanded ? 6_000 : 900)))
            if text.count > 900 {
                Button(expanded ? "Show less" : "Show full report") { expanded.toggle() }
                    .buttonStyle(.plain).font(.caption2).foregroundStyle(Brand.periwinkle)
            }
            if text.count > 6_000 {
                Text("Report shortened after 6,000 characters; open the task thread in \(agentName) for the remainder.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text("Source report · not an independent verification of the work")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.card.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
        .onChange(of: text) { _, _ in copied = false }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(1.5)) }
            catch { return }
            copied = false
        }
    }
}

struct TaskDoneCriteriaControl: View {
    let definition: String?
    let identifier: String
    let flow: TaskFlow
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            TaskStepBadge(number: TaskFlow.Step.done.rawValue, state: flow.state(.done))
            VStack(alignment: .leading, spacing: 4) {
                TaskFlowButton(title: definition == nil ? "Define what done looks like" : "Edit completion criteria",
                               step: .done, flow: flow,
                               help: "Write the short, verifiable results Cruise reviews each report against.",
                               identifier: identifier, action: edit)
                if let definition {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Done when:").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text((try? AttributedString(markdown: definition)) ?? AttributedString(definition))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } else if flow.state(.done).isEnabled {
                    Text("Choose a short, verifiable goal before reviewing the report.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Step 1: the task's confirmed workspace folder, shared by the HeyClicky and VS Code task panels.
struct TaskFolderStep: View {
    let confirmed: String?
    let suggested: String?
    let flow: TaskFlow
    let identifier: String
    let useSuggestion: () -> Void
    let choose: () -> Void

    var body: some View {
        TaskFlowRow(step: .folder, flow: flow) {
            VStack(alignment: .leading, spacing: 2) {
                if let confirmed {
                    Text("Workspace folder").font(.caption2.weight(.semibold))
                    Text(confirmed).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                } else if let suggested {
                    Text("Suggested folder · not confirmed").font(.caption2.weight(.semibold)).foregroundStyle(Brand.youBadge)
                    Text(suggested).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text("Assign the folder this task works in").font(.caption2.weight(.semibold))
                }
            }
            Spacer(minLength: 6)
            if confirmed == nil, suggested != nil {
                TaskFlowButton(title: "Use suggestion", step: .folder, flow: flow,
                               help: "Confirms and saves the suggested folder for this task.",
                               identifier: "\(identifier)-suggestion", action: useSuggestion)
            }
            Button(confirmed == nil ? "Choose folder…" : "Change folder…", action: choose)
                .buttonStyle(ClickyPillButtonStyle(primary: confirmed == nil && suggested == nil && !flow.busy))
                .disabled(flow.busy)
                .help("Choosing a folder immediately saves it as this task's confirmed workspace. Cruise will not move or edit files there.")
                .accessibilityIdentifier(identifier)
        }
    }
}

struct TaskDoneDefinitionEditor: View {
    let taskName: String
    let agentName: String
    @Binding var definition: String
    @Binding var plan: TaskPlan
    let confirmedWorkspace: Bool
    let branches: [String]
    @Binding var newBranchName: String
    let branchStatus: String?
    let onCreateBranch: () -> Void
    let onSave: () -> Void
    var workspace: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var previewing = false
    @State private var importing = false
    @State private var documentError: String?
    @FocusState private var editorFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("What does done mean for \(taskName)?").font(.headline)
                Text("Write one or more results you can verify. Cruise compares the latest \(agentName) report with this definition; it cannot prove the real work by itself.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Picker("Definition view", selection: $previewing) {
                        Text("Write").tag(false)
                        Text("Preview").tag(true)
                    }
                    .pickerStyle(.segmented).frame(width: 170)
                    Spacer()
                    Button { documentError = nil; importing = true } label: {
                        Label("Import document…", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(ClickyPillButtonStyle(primary: false))
                }
                DoneWorkflowPolicyEditor(
                    plan: $plan, confirmedWorkspace: confirmedWorkspace, branches: branches,
                    newBranchName: $newBranchName, branchStatus: branchStatus, onCreateBranch: onCreateBranch,
                    requiresBuildLocation: agentName != "VS Code", workspace: workspace)
                if previewing {
                    ScrollView {
                        Text((try? AttributedString(markdown: definition)) ?? AttributedString(definition))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                    .frame(height: 170)
                    .background(Brand.card, in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityIdentifier("done-definition-preview")
                } else {
                    TextEditor(text: $definition)
                        .font(.body).focused($editorFocused).frame(height: 170)
                        .scrollContentBackground(.hidden).padding(8)
                        .background(Brand.card, in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityIdentifier("done-definition-editor")
                        .onChange(of: definition) { _, value in
                            if value.count > DefinitionOfDone.maxDefinitionLength {
                                definition = String(value.prefix(DefinitionOfDone.maxDefinitionLength))
                            }
                        }
                }
                Text("Markdown is supported. Imported text is extracted locally and included verbatim in the next bump; Cruise does not retain the source file.")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("\(definition.count) / \(DefinitionOfDone.maxDefinitionLength) characters")
                    .font(.caption).foregroundStyle(.secondary)
                if let documentError {
                    Label(documentError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                        .buttonStyle(ClickyPillButtonStyle(primary: false))
                    Spacer()
                    Button("Save definition") { onSave(); dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(ClickyPillButtonStyle(primary: true))
                        .disabled(DefinitionOfDone.normalized(definition) == nil)
                }
            }
            .padding(24)
        }
        .frame(width: 620, height: 650)
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: ["txt", "md", "markdown", "rtf", "pdf"].compactMap { UTType(filenameExtension: $0) },
                      allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let text = try DoneDefinitionDocument.readText(from: url)
                definition = try DoneDefinitionDocument.appending(text, filename: url.lastPathComponent, to: definition)
                documentError = nil
                previewing = false
                editorFocused = true
            } catch { documentError = error.localizedDescription }
        }
        .onAppear { editorFocused = true }
        .onChange(of: previewing) { _, value in if !value { editorFocused = true } }
    }
}
