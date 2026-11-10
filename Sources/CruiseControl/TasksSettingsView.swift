import SwiftUI
import UniformTypeIdentifiers
import CruiseCore

private enum TaskListFilter: String, CaseIterable, Identifiable {
    case all, needsDefinition, attention, working, reportedDone, unassigned, reviewEnabled

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All tasks"
        case .needsDefinition: "Needs a definition"
        case .attention: "Needs attention"
        case .working: "Working"
        case .reportedDone: "Reported done"
        case .unassigned: "Unassigned project"
        case .reviewEnabled: "In Cruise review"
        }
    }
}

struct TasksSettingsView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var monitor: ClickyMonitor
    @ObservedObject private var tasks = ClickyTaskStore.shared
    @State private var search = ""
    @State private var filter: TaskListFilter = .all
    @State private var projectFilter = "all"
    @State private var collapsedGroups: Set<String> = []
    @State private var initializedGroupState = false
    @State private var refreshing = false

    private let visibleSorts: [TaskSort] = [.priority, .updated, .newest, .name]

    private var groupedByProject: Bool { store.config.taskGrouping == .project || store.config.taskGrouping == .repository }
    private var groupedByWorkspace: Bool { store.config.taskGrouping == .directory }

    private var selectedSort: TaskSort {
        visibleSorts.contains(store.config.taskSort) ? store.config.taskSort : .priority
    }

    private var projectGroups: [TaskCatalog.Group] {
        monitor.taskCatalog.groups(by: .project, sort: .name).filter { $0.id != "unassigned" }
    }

    private var visibleGroups: [TaskCatalog.Group] {
        let grouping: TaskGrouping = groupedByWorkspace ? .directory : groupedByProject ? .project : .none
        let catalogSort: TaskSort = selectedSort == .priority ? .name : selectedSort
        let candidates = monitor.taskCatalog.groups(by: grouping, sort: catalogSort, query: search)
        let included = candidates.filter { group in
            (projectFilter == "all" || !groupedByProject || group.id == projectFilter)
                && !visibleTasks(in: group).isEmpty
        }
        guard selectedSort == .priority else { return included }
        return included.sorted { left, right in
            if left.id == "unassigned" { return false }
            if right.id == "unassigned" { return true }
            let leftPriority = projectPriority(for: left).rank
            let rightPriority = projectPriority(for: right).rank
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            let leftUpdate = latestUpdate(in: left)
            let rightUpdate = latestUpdate(in: right)
            if leftUpdate != rightUpdate { return leftUpdate > rightUpdate }
            return left.title.localizedStandardCompare(right.title) == .orderedAscending
        }
    }

    private var visibleTaskCount: Int {
        visibleGroups.reduce(0) { $0 + visibleTasks(in: $1).count }
    }

    private func visibleTasks(in group: TaskCatalog.Group) -> [CatalogTask] {
        let matches = group.tasks.filter(matchesFilter)
        guard selectedSort == .priority else { return matches }
        return matches.sorted { left, right in
            let leftPriority = priority(for: left).rank
            let rightPriority = priority(for: right).rank
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            let leftUpdate = lastUpdate(for: left)
            let rightUpdate = lastUpdate(for: right)
            if leftUpdate != rightUpdate { return leftUpdate > rightUpdate }
            let comparison = left.name.localizedStandardCompare(right.name)
            return comparison == .orderedSame ? left.id < right.id : comparison == .orderedAscending
        }
    }

    private func matchesFilter(_ item: CatalogTask) -> Bool {
        let definition = store.config.clickyDefinitionsOfDone[item.id]
        let current = tasks.task(item.id)
        let assessment = current.flatMap { tasks.currentAssessment(for: $0, definition: definition) }
        let status = item.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch filter {
        case .all:
            return true
        case .needsDefinition:
            return current != nil && DefinitionOfDone.normalized(definition) == nil
        case .attention:
            if let current, current.isWorking { return false }
            if let assessment,
               assessment.state == .needsYou || assessment.state == .unfinished || assessment.state == .failed {
                return true
            }
            return status == "failed" || current.map { TaskAudit.requiresUser($0.lastMessage) } == true
        case .working:
            return current?.isWorking == true || ["working", "running", "in progress"].contains(status)
        case .reportedDone:
            return assessment?.state == .done || ["done", "complete", "completed", "success", "succeeded"].contains(status)
        case .unassigned:
            return item.project.title == nil
        case .reviewEnabled:
            return store.config.taskPlans[item.id]?.enabled == true
        }
    }

    private func priority(for item: CatalogTask) -> TaskPriority {
        store.config.taskPlans[item.id]?.priority
            ?? store.config.projectPriorities[item.project.priorityKey]
            ?? .normal
    }

    private func projectPriority(for group: TaskCatalog.Group) -> TaskPriority {
        visibleTasks(in: group).map { priority(for: $0) }.min { $0.rank < $1.rank } ?? .normal
    }

    private func lastUpdate(for item: CatalogTask) -> Date {
        tasks.task(item.id)?.updatedAt ?? item.updatedAt
    }

    private func latestUpdate(in group: TaskCatalog.Group) -> Date {
        visibleTasks(in: group).map(lastUpdate(for:)).max() ?? .distantPast
    }

    private var projectFilterTitle: String {
        projectGroups.first(where: { $0.id == projectFilter })?.title ?? "All projects"
    }

    var body: some View {
        let groups = visibleGroups
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("HeyClicky tasks").font(.headline)
                    Text("A project-first workspace for priorities, completion goals, and the latest task report.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(refreshing ? "Refreshing…" : "Refresh") {
                    Task {
                        refreshing = true
                        await monitor.refreshTaskCatalog()
                        refreshing = false
                    }
                }
                .disabled(refreshing || tasks.loading)
                .accessibilityIdentifier("refresh-agent-tasks")
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checklist")
                    .font(.title3).foregroundStyle(Brand.youBadge)
                VStack(alignment: .leading, spacing: 3) {
                    Text("A clear path to done").font(.subheadline.weight(.semibold))
                    Text("Group jobs by project → set priority → define done → compare the latest HeyClicky report. Reports are evidence, not proof of the underlying work.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Cruise reads HeyClicky's local task records; no private HeyClicky API is assumed. Task organization stays local and never changes HeyClicky's own queue.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 8) {
                TextField("Search task, project, or repository", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("agent-task-search")
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
                Picker("Filter", selection: $filter) {
                    ForEach(TaskListFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("agent-task-filter")
                if groupedByProject {
                    Picker("Project", selection: $projectFilter) {
                        Text("All projects").tag("all")
                        ForEach(projectGroups) { group in
                            Text(group.title).tag(group.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("agent-project-filter")
                }
            }

            HStack(spacing: 10) {
                Picker("Group by", selection: Binding(
                    get: { groupedByWorkspace ? TaskGrouping.directory : groupedByProject ? TaskGrouping.project : TaskGrouping.none },
                    set: { store.config.taskGrouping = $0 }
                )) {
                    Text("Project").tag(TaskGrouping.project)
                    Text("Workspace").tag(TaskGrouping.directory)
                    Text("All tasks").tag(TaskGrouping.none)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                .accessibilityIdentifier("agent-task-layout")

                Picker("Sort", selection: Binding(
                    get: { selectedSort },
                    set: { store.config.taskSort = $0 }
                )) {
                    ForEach(visibleSorts) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("agent-task-sort")

                Spacer()
                Text("\(visibleTaskCount) shown · \(monitor.taskCatalog.currentTaskCount) current")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Image(systemName: "arrow.down.doc")
                Text(tasks.loading ? "Reading HeyClicky's local task list…"
                     : "Read-only local HeyClicky task list · \(tasks.tasks.count) tasks")
                if let loadedAt = tasks.loadedAt {
                    Text("· updated \(loadedAt.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            .font(.caption2).foregroundStyle(.secondary)

            if monitor.taskCatalog.tasks.count > monitor.taskCatalog.currentTaskCount {
                Text("\(monitor.taskCatalog.tasks.count - monitor.taskCatalog.currentTaskCount) saved records are unmatched to a current HeyClicky job. They’re retained for review, not resumed automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            DisclosureGroup("Review & completion settings") {
                VStack(alignment: .leading, spacing: 9) {
                    Toggle("Infer projects locally with Ollama", isOn: $store.config.inferTaskProjects)
                        .onChange(of: store.config.inferTaskProjects) { _, enabled in
                            if enabled { Task { await monitor.inferTaskProjects() } }
                        }
                    Text(monitor.projectInferenceStatus)
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Review opted-in tasks in the background", isOn: $store.config.backgroundTaskReview)
                    Picker("Reply delivery", selection: $store.config.backgroundTaskDelivery) {
                        ForEach(TaskDeliveryMode.allCases) { Text($0.title).tag($0) }
                    }
                    Text(store.config.backgroundTaskDelivery == .chatOnly
                         ? "Chat-only uses HeyClicky's visible chat while you’re idle. It sends text only; it never approves drive, tool, or permission requests."
                         : "No supported HeyClicky message API is configured. Cruise keeps generated follow-ups local instead of sending them.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("A saved definition and an explicit per-task review toggle are required. Assessments read the latest report; they don’t prove the underlying work.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Allow per-task auto-bumps in Cruise mode", isOn: $store.config.continueUntilDefinedDone)
                    Text("Tasks also need an explicit Auto-bump opt-in. Local Ollama compares each fresh report with its saved definition and writes a grounded follow-up; Cruise sends it only to that unique HeyClicky task while idle. It never grants permissions or confirms user-only requests.")
                        .font(.caption).foregroundStyle(.secondary)
                    Stepper("Maximum follow-up rounds: \(store.config.maxDefinitionRounds)",
                            value: $store.config.maxDefinitionRounds, in: 1...30)
                    Text("Working, stopped, dismissed, user-blocked, or ambiguous tasks are not resumed automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(tasks.measuring ? "Measuring local sizes…" : "Measure local sizes") {
                        Task { await tasks.refresh(measure: true) }
                    }
                    .disabled(tasks.measuring || tasks.loading)
                    Text("Size measurement is optional; shared caches are counted for each task and are not additional disk usage.")
                        .font(.caption).foregroundStyle(.secondary)
                    if store.config.backgroundTaskReview {
                        Text(monitor.backgroundTaskStatus)
                            .font(.caption).foregroundStyle(Brand.youBadge).textSelection(.enabled)
                    }
                }
                .padding(.top, 8)
            }

            if let error = monitor.taskCatalogError {
                Text(error).font(.caption).foregroundStyle(Brand.youBadge).textSelection(.enabled)
            }
            if let error = tasks.loadError, error != monitor.taskCatalogError {
                Text(error).font(.caption).foregroundStyle(Brand.youBadge).textSelection(.enabled)
            }
            if let error = tasks.persistenceError, error != tasks.loadError {
                Text(error).font(.caption).foregroundStyle(Brand.youBadge).textSelection(.enabled)
            }

            if groups.isEmpty {
                Text(tasks.loading ? "Reading the local job list…"
                     : search.isEmpty ? "No tasks match these filters." : "No tasks match this search and filter.")
                    .foregroundStyle(.secondary)
            }

            ForEach(groups) { group in
                let items = visibleTasks(in: group)
                DisclosureGroup(isExpanded: Binding(
                    get: { !collapsedGroups.contains(group.id) },
                    set: { if $0 { collapsedGroups.remove(group.id) } else { collapsedGroups.insert(group.id) } }
                )) {
                    VStack(alignment: .leading, spacing: 8) {
                        if groupedByProject, group.id != "unassigned" {
                            Menu {
                                ForEach(TaskPriority.allCases) { priority in
                                    Button(priority.title) {
                                        store.config.projectPriorities[group.project.priorityKey] = priority
                                    }
                                }
                            } label: {
                                Label("Project default: \(store.config.projectPriorities[group.project.priorityKey]?.title ?? "Normal")",
                                      systemImage: "flag")
                            }
                        }
                        ForEach(items) { item in
                            TaskProjectRow(task: item, projects: projectGroups.map(\.project), store: store, tasks: tasks, monitor: monitor,
                                            assign: { monitor.assignProject($0, to: item.id) },
                                            reset: { monitor.resetProject(for: item.id) })
                            if item.id != items.last?.id { Divider() }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    HStack {
                        Text(group.id == "unassigned" ? "Unassigned" : group.title).font(.headline)
                        Text("\(items.count)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if groupedByProject, group.id != "unassigned" {
                            Text(store.config.projectPriorities[group.project.priorityKey]?.title ?? "Normal")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .padding(12)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task { await monitor.refreshTaskCatalog() }
        .onReceive(tasks.$tasks) { loaded in
            if tasks.loadedAt != nil { monitor.updateTaskCatalog(loaded) }
        }
        .onReceive(tasks.$loadedAt) { loadedAt in
            guard loadedAt != nil else { return }
            monitor.updateTaskCatalog(tasks.tasks)
            if !initializedGroupState && groupedByProject {
                collapsedGroups.formUnion(monitor.taskCatalog.groups(by: .project, sort: .name).map(\.id))
                initializedGroupState = true
            }
            if projectFilter != "all" && !projectGroups.contains(where: { $0.id == projectFilter }) {
                projectFilter = "all"
            }
        }
    }
}

private struct TaskProjectRow: View {
    let task: CatalogTask
    let projects: [TaskProject]
    @ObservedObject var store: ConfigStore
    @ObservedObject var tasks: ClickyTaskStore
    @ObservedObject var monitor: ClickyMonitor
    let assign: (TaskProject) -> Void
    let reset: () -> Void
    @State private var editingProject = false
    @State private var projectDraft = TaskProject()
    @State private var selectingWorkspace = false
    @State private var definingDone = false
    @State private var definitionDraft = ""
    @State private var showingDetails = false

    private var details: ClickyAgentTask? { tasks.task(task.id) }
    private var stateLabel: String {
        let state = Matcher.normalize(task.status)
        return ["done", "complete", "completed", "reported done"].contains(state) ? "Reported done" : task.status.replacingOccurrences(of: "_", with: " ").capitalized
    }
    private var definition: String? { DefinitionOfDone.normalized(store.config.clickyDefinitionsOfDone[task.id]) }
    private var assessment: ClickyTaskAssessment? {
        guard let details else { return nil }
        return tasks.currentAssessment(for: details, definition: definition)
    }
    private var projectDefault: TaskPriority {
        store.config.projectPriorities[task.project.priorityKey] ?? .normal
    }
    private var priority: TaskPriority {
        store.config.taskPlans[task.id]?.priority ?? projectDefault
    }
    private var autoBumpEnabled: Bool {
        store.config.taskPlans[task.id]?.autoBump == true
    }
    private var canBumpNow: Bool {
        guard let details else { return false }
        return TaskPlanning.manualBumpAvailable(details, allTasks: tasks.tasks, config: store.config)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.name).font(.body.weight(.semibold)).textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text(stateLabel)
                            .font(.caption2).padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Brand.card, in: Capsule())
                        if store.config.taskGrouping == .none, let project = task.project.title {
                            Label(project, systemImage: "folder").font(.caption2).foregroundStyle(.secondary)
                        }
                        if task.sourceUnavailable == true {
                            Text("Saved · not matched").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 6)
                Menu {
                    Button("Use project default (\(projectDefault.title))") { setPriority(nil) }
                    Divider()
                    ForEach(TaskPriority.allCases) { option in
                        Button(option.title) { setPriority(option) }
                    }
                } label: {
                    Label("\(priority.title)", systemImage: "flag")
                }
                .help("Cruise review priority only; it does not change HeyClicky's queue.")
                .disabled(details == nil)

                Button(definition == nil ? "Define done" : "Edit done") {
                    definitionDraft = store.config.clickyDefinitionsOfDone[task.id] ?? ""
                    definingDone = true
                }
                .disabled(details == nil)
                .accessibilityIdentifier("define-done-\(task.id)")

                Button(showingDetails ? "Hide details" : "Details") { showingDetails.toggle() }
                    .accessibilityIdentifier("task-details-\(task.id)")
            }

            if let definition {
                Text("Done when: \(definition)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else if details != nil {
                Text("Add a short, verifiable completion goal to enable review.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("This saved record is not matched to a current HeyClicky job.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let details {
                latestResponseCard(details)
                criteriaSummary(details)
                HStack(spacing: 10) {
                    Toggle("Auto-bump this task", isOn: Binding(
                        get: { autoBumpEnabled },
                        set: { store.config.taskPlans[task.id, default: TaskPlan()].autoBump = $0 }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(definition == nil)
                    .help("Explicitly opt this task into automatic follow-ups when its latest report falls short of its saved definition.")
                    Button(monitor.bumpingTaskIDs.contains(task.id) ? "Queued…" : "Bump now") {
                        monitor.bumpTaskNow(task.id)
                    }
                    .disabled(!canBumpNow || monitor.bumpingTaskIDs.contains(task.id))
                    .help("Compare the newest report with this task's saved goal. A single grounded follow-up is sent only for a clear, safe gap.")
                    .accessibilityIdentifier("bump-task-\(task.id)")
                    Spacer()
                }
                if definition != nil {
                    Text("Auto-bump is off until you turn it on for this task. It waits for a fresh report, stops on repeated gaps or user decisions, and never approves or publishes.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            if showingDetails {
                Divider()
                detailsPanel(details)
            }
        }
        .padding(.vertical, 8)
        .accessibilityIdentifier("task-row-\(task.id)")
        .sheet(isPresented: $editingProject) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Project & workspace for \(task.name)").font(.headline)
                TextField("Project name", text: $projectDraft.name)
                    .accessibilityIdentifier("project-name-\(task.id)")
                Text("Workspace folder for this task (optional)")
                    .font(.caption.weight(.medium))
                HStack {
                    TextField("/Users/you/GitHub/Project", text: $projectDraft.directory)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("workspace-path-\(task.id)")
                    Button("Choose…") { selectingWorkspace = true }
                }
                Text("A workspace is a local folder, not a project/repository guess. It only helps organize tasks; Cruise will not move or edit files here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fileImporter(isPresented: $selectingWorkspace, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                        if case .success(let urls) = result, let url = urls.first {
                            projectDraft.directory = url.standardizedFileURL.path
                        }
                    }
                HStack {
                    Button("Cancel") { editingProject = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save project") {
                        editingProject = false
                        if projectDraft.name != task.project.name {
                            projectDraft.repository = ""
                        }
                        assign(projectDraft)
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("save-project-\(task.id)")
                    .disabled(projectDraft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 460)
            .textFieldStyle(.roundedBorder)
        }
        .sheet(isPresented: $definingDone) {
            VStack(alignment: .leading, spacing: 14) {
                Text("What does done mean for \(task.name)?").font(.headline)
                Text("Write one or more results you can verify. Cruise compares the latest HeyClicky report with this definition; it cannot prove the real work by itself.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $definitionDraft).frame(height: 150)
                Text("\(definitionDraft.count) / \(DefinitionOfDone.maxDefinitionLength) characters")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { definingDone = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save definition") {
                        store.config.clickyDefinitionsOfDone[task.id] = DefinitionOfDone.normalized(definitionDraft)
                        definingDone = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(definitionDraft.count > DefinitionOfDone.maxDefinitionLength)
                }
            }
            .padding(24)
            .frame(width: 480)
        }
    }

    @ViewBuilder
    private func latestResponseCard(_ details: ClickyAgentTask) -> some View {
        if !details.lastMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Latest HeyClicky response").font(.caption.weight(.semibold))
                    Spacer()
                    if let updated = details.lastMessageAt ?? details.updatedAt {
                        Text(updated.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Text(String(details.lastMessage.prefix(520)) + (details.lastMessage.count > 520 ? "…" : ""))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(4)
                Text("Source report · not an independent verification of the work")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.card.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
        } else {
            Label("No task report available yet", systemImage: "doc.text.magnifyingglass")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func criteriaSummary(_ details: ClickyAgentTask) -> some View {
        if let assessment {
            let meets = assessment.meetsDefinition
            VStack(alignment: .leading, spacing: 4) {
                Label(meets == true ? "Criteria appear met in report" : meets == false ? "Criteria gap found" : "Criteria not yet verified",
                      systemImage: meets == true ? "checkmark.seal" : meets == false ? "exclamationmark.circle" : "questionmark.circle")
                    .font(.caption.weight(.semibold))
                Text(assessment.reason).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                ForEach(Array(assessment.missing.prefix(3)), id: \.self) { gap in
                    Label(gap, systemImage: "arrow.turn.down.right")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Text("Compared with the saved definition using the latest report; not a test of the underlying project.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.leading, 2)
        } else if definition != nil {
            Label("Criteria not assessed for this report", systemImage: "questionmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Label("Add a definition to compare this report with completion criteria", systemImage: "checklist")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func setPriority(_ value: TaskPriority?) {
        var plan = store.config.taskPlans[task.id] ?? TaskPlan()
        plan.priority = value
        store.config.taskPlans[task.id] = plan
    }

    @ViewBuilder
    private func detailsPanel(_ details: ClickyAgentTask?) -> some View {
        if let details {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(details.runCount) runs · \(details.messageCount) messages")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(tasks.assessing.contains(task.id) ? "Reviewing…" : "Review latest report") {
                        Task { await tasks.assess(details, config: store.config) }
                    }
                    .disabled(tasks.assessing.contains(task.id))
                }
                Text("Job ID: \(task.sourceID ?? "legacy saved record")")
                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                Text(task.updatedAt == .distantPast ? "Last update unavailable" : "Updated \(task.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)

                Menu {
                    ForEach(Array(projects.enumerated()), id: \.offset) { _, project in
                        Button(project.repositoryName.map { "\(project.title ?? $0) (\($0))" }
                               ?? project.title ?? "Unnamed project") { assign(project) }
                    }
                    if !projects.isEmpty { Divider() }
                    Button("Create or rename project…") {
                        projectDraft = task.project
                        editingProject = true
                    }
                    Button("Leave unassigned") { assign(TaskProject()) }
                    Button("Infer again") { reset() }
                } label: {
                    Label("Project: \(task.project.title ?? "Unassigned")", systemImage: "folder")
                }

                if definition == nil {
                    Text("Save a definition above before enabling this task's Auto-bump option.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let error = tasks.measureErrors[task.id] {
                    Text("Size measurement: \(error)").font(.caption).foregroundStyle(Brand.youBadge).textSelection(.enabled)
                }
                if let bytes = details.totalBytes {
                    Text("Local size: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !details.threadReferences.isEmpty || !details.evidenceErrors.isEmpty {
                    DisclosureGroup("Thread evidence · \(details.threadReferences.count) excerpts") {
                        ForEach(details.threadIDs, id: \.self) { id in
                            Text("Thread: \(id)").font(.caption).textSelection(.enabled)
                            ForEach(Array(Set(details.threadReferences.filter { $0.threadID == id }.map(\.source))).sorted(), id: \.self) { source in
                                Text(source).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        ForEach(details.evidenceErrors, id: \.self) { error in
                            Text(error).font(.caption).foregroundStyle(Brand.youBadge).textSelection(.enabled)
                        }
                    }
                }
                if let assessment {
                    Text("Assessment: \(assessment.state.title) · \(assessment.source)").font(.caption)
                    Text(assessment.reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if !assessment.missing.isEmpty {
                        Text("Missing: \(assessment.missing.joined(separator: "; "))")
                            .font(.caption).textSelection(.enabled)
                    }
                }
                if let reply = tasks.record(task.id).backgroundReply {
                    DisclosureGroup(reply.deliveredAt == nil ? "Saved follow-up · delivery unconfirmed" : "Follow-up · delivery confirmed") {
                        if reply.fingerprint != details.fingerprint || definition != reply.definition {
                            Text("Outdated: the report or definition changed.").font(.caption).foregroundStyle(Brand.youBadge)
                        }
                        Text(reply.text).font(.caption).textSelection(.enabled)
                        Text(reply.deliveredAt == nil ? TaskPlanning.deliveryHold : "Confirmed: \(reply.deliveredAt!.formatted())")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !details.lastMessage.isEmpty {
                    DisclosureGroup("Latest report") {
                        Text(String(details.lastMessage.prefix(6000))).font(.caption).textSelection(.enabled)
                        if details.lastMessage.count > 6000 {
                            Text("Report shortened here; open the thread in HeyClicky for the full text.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("No report available.").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Text("Saved metadata is not matched to a current HeyClicky job. It is kept for reference, not resumed automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
