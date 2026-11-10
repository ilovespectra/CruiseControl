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
    @State private var priorityFilter: TaskPriorityFilter = .all
    @State private var projectFilter = "all"
    @State private var collapsedGroups: Set<String> = []
    @State private var initializedGroupState = false
    @State private var refreshing = false
    @State private var selectedTaskID: String?

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
        let matches = group.tasks.filter { matchesFilter($0) && priorityFilter.includes(priority(for: $0)) }
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

    private var listedTaskIDs: [String] { visibleGroups.flatMap { visibleTasks(in: $0) }.map(\.id) }
    private var selectedTask: CatalogTask? {
        let listed = visibleGroups.flatMap { visibleTasks(in: $0) }
        return listed.first(where: { $0.id == selectedTaskID }) ?? listed.first
    }

    private var redesignedBody: some View {
        VStack(spacing: 0) {
            taskHeader.padding(.bottom, 12)
            taskOverview.padding(.bottom, 12)
            taskControls.padding(.bottom, 8)
            taskFilters.padding(.bottom, 10)
            taskContentColumns
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.07)))
            taskFooter.padding(.top, 8)
        }
        .padding(12)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
        .task { await monitor.refreshTaskCatalog() }
        .onReceive(tasks.$tasks) { loaded in
            if tasks.loadedAt != nil { monitor.updateTaskCatalog(loaded) }
        }
        .onReceive(tasks.$loadedAt) { loadedAt in
            guard loadedAt != nil else { return }
            monitor.updateTaskCatalog(tasks.tasks)
            if selectedTaskID == nil { selectedTaskID = listedTaskIDs.first }
            if projectFilter != "all" && !visibleGroups.contains(where: { $0.id == projectFilter }) { projectFilter = "all" }
        }
        .onChange(of: listedTaskIDs) { _, ids in
            if !ids.contains(selectedTaskID ?? "") { selectedTaskID = ids.first }
        }
    }

    private var taskHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 12).fill(Brand.primaryFill)
                .overlay(Image(systemName: "checklist").foregroundStyle(Brand.navy).font(.title3))
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text("HeyClicky Tasks").font(BrandFont.inter(20, .semibold))
                Text("One place for project context, priorities, completion goals, and the latest report.")
                    .font(BrandFont.inter(11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { refreshing = true; await monitor.refreshTaskCatalog(); await tasks.refresh(); refreshing = false }
            } label: {
                Label(refreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(refreshing || tasks.loading)
            .accessibilityIdentifier("refresh-agent-tasks")
        }
    }

    private var taskOverview: some View {
        HStack(spacing: 8) {
            overviewMetric("CURRENT TASKS", "\(monitor.taskCatalog.currentTaskCount)", "checklist", Brand.periwinkle)
            overviewMetric("NEED ATTENTION", "\(tasks.tasks.filter { TaskAudit.requiresUser($0.lastMessage) || $0.isStopped }.count)", "exclamationmark.circle", Brand.youBadge)
            overviewMetric("PROJECTS", "\(projectGroups.count)", "folder", Brand.accent(for: .cruise))
        }
    }

    private var taskControls: some View {
        HStack(spacing: 10) {
            TextField("Search tasks, projects, workspaces…", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("agent-task-search")
            Picker("Group by", selection: Binding(
                get: { groupedByWorkspace ? TaskGrouping.directory : groupedByProject ? TaskGrouping.project : TaskGrouping.none },
                set: { store.config.taskGrouping = $0; projectFilter = "all" }
            )) {
                Text("Projects").tag(TaskGrouping.project)
                Text("Workspaces").tag(TaskGrouping.directory)
                Text("All tasks").tag(TaskGrouping.none)
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
            .accessibilityIdentifier("agent-task-layout")
            Picker("Priority", selection: $priorityFilter) {
                ForEach(TaskPriorityFilter.allCases) { option in Text(option.title).tag(option) }
            }
            .pickerStyle(.menu)
            .frame(width: 130)
            .accessibilityIdentifier("agent-task-priority-filter")
            Picker("Sort", selection: Binding(get: { selectedSort }, set: { store.config.taskSort = $0 })) {
                ForEach(visibleSorts) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(width: 150)
            .accessibilityIdentifier("agent-task-sort")
        }
    }

    private var taskFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(TaskListFilter.allCases) { option in
                    Button { filter = option } label: {
                        Text(option.title).font(BrandFont.inter(10, .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(filter == option ? Brand.navy : Brand.card, in: Capsule())
                            .overlay(Capsule().strokeBorder(filter == option ? Brand.periwinkle.opacity(0.7) : Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("task-filter-\(option.id)")
                }
                if projectFilter != "all" {
                    Button("Clear project filter") { projectFilter = "all" }
                        .font(BrandFont.inter(10, .semibold)).foregroundStyle(Brand.periwinkle)
                }
            }
        }
    }

    private var taskContentColumns: some View {
        HStack(spacing: 0) {
            taskListColumn.frame(width: 310)
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
            taskDetailColumn.frame(maxWidth: .infinity)
        }
    }

    private var taskListColumn: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(groupedByWorkspace ? "WORKSPACES" : groupedByProject ? "PROJECTS" : "TASKS")
                        .font(BrandFont.inter(9, .bold)).tracking(0.8).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(visibleTaskCount)").font(BrandFont.mono(9)).foregroundStyle(.tertiary)
                }
                ForEach(visibleGroups) { group in taskGroupRow(group) }
                if visibleGroups.isEmpty {
                    Text(tasks.loading ? "Reading local HeyClicky tasks…" : "Nothing matches these filters.")
                        .font(BrandFont.inter(11)).foregroundStyle(.secondary).padding(12)
                }
            }
            .padding(10)
        }
    }

    private func taskGroupRow(_ group: TaskCatalog.Group) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if groupedByProject { projectFilter = projectFilter == group.id ? "all" : group.id }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: groupedByWorkspace ? "externaldrive" : "folder.fill")
                        .foregroundStyle(Brand.periwinkle)
                    Text(group.title).font(BrandFont.inter(10, .semibold)).lineLimit(1)
                    Text("\(visibleTasks(in: group).count)").font(BrandFont.mono(8)).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(Brand.card.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            ForEach(visibleTasks(in: group)) { item in taskListButton(item) }
        }
    }

    private var taskDetailColumn: some View {
        ScrollView { taskDetailContent }
    }

    @ViewBuilder
    private var taskDetailContent: some View {
        if let current = selectedTask {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "text.alignleft").foregroundStyle(Brand.periwinkle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current.name).font(BrandFont.inter(16, .semibold)).textSelection(.enabled)
                        Text("\(current.project.title ?? "Unassigned project") · \(current.status.replacingOccurrences(of: "_", with: " ").capitalized)")
                            .font(BrandFont.inter(10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: 12))
                TaskProjectRow(task: current, projects: projectGroups.map(\.project), store: store,
                               tasks: tasks, monitor: monitor,
                               assign: { monitor.assignProject($0, to: current.id) },
                               reset: { monitor.resetProject(for: current.id) }, initiallyExpanded: true)
                    .padding(12)
                    .background(Brand.card, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(12)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "text.magnifyingglass").font(.largeTitle).foregroundStyle(Brand.periwinkle)
                Text("Choose a task").font(BrandFont.inter(16, .semibold))
                Text("Select a project task to review its latest response, saved goal, evidence, and next step.")
                    .font(BrandFont.inter(11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(32)
        }
    }

    private var taskFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield")
            Text("Local task data · read-only source reports · no private HeyClicky API assumed")
            Spacer()
            Text("Reports are evidence, not independent verification.")
        }
        .font(BrandFont.inter(9.5)).foregroundStyle(.tertiary)
    }

    private func overviewMetric(_ title: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).font(.callout)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(BrandFont.inter(8, .bold)).tracking(0.5).foregroundStyle(.secondary)
                Text(value).font(BrandFont.inter(15, .semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 10))
    }

    private func taskListButton(_ item: CatalogTask) -> some View {
        let selected = selectedTaskID == item.id
        return Button { selectedTaskID = item.id } label: {
            HStack(alignment: .top, spacing: 7) {
                Circle().fill(taskAccent(item.status)).frame(width: 6, height: 6).padding(.top, 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(BrandFont.inter(10.5, .medium)).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        Text(item.status.replacingOccurrences(of: "_", with: " ").capitalized)
                        Text("·")
                        Text(priority(for: item).title)
                    }
                    .font(BrandFont.inter(8.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Brand.navy.opacity(0.75) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Brand.periwinkle.opacity(0.5) : Color.clear))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("task-row-\(item.id)")
    }

    private func taskAccent(_ raw: String) -> Color {
        let value = raw.lowercased()
        if value.contains("fail") || value.contains("need") || value.contains("error") { return Brand.youBadge }
        if value.contains("work") || value.contains("run") { return Brand.accent(for: .cruise) }
        if value.contains("done") || value.contains("complete") { return Brand.periwinkle }
        return Color.white.opacity(0.3)
    }

    var body: some View { redesignedBody }

    private var legacyBody: some View {
        let groups = visibleGroups
        return VStack(alignment: .leading, spacing: 12) {
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
    var initiallyExpanded: Bool = false
    @State private var editingProject = false
    @State private var projectDraft = TaskProject()
    @State private var selectingWorkspace = false
    @State private var definingDone = false
    @State private var definitionDraft = ""
    @State private var showingDetails = false
    @State private var draftingBump = false
    @State private var bumpDraftMessage: String?
    @State private var bumpDraftError: String?

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
    private var canDraftBump: Bool {
        guard let details, definition != nil else { return false }
        return details.hasReport && !details.isWorking && !details.isStopped && !details.dismissed
            && !TaskAudit.requiresUser(details.lastMessage)
            && !ClickyTaskLibrary.ambiguousNames(tasks.tasks).contains(Matcher.normalize(details.name))
    }

    private func createBumpDraft() async {
        guard let details, let definition else { return }
        draftingBump = true
        bumpDraftMessage = nil
        bumpDraftError = nil
        defer { draftingBump = false }

        let current: ClickyTaskAssessment
        if let assessment {
            current = assessment
        } else {
            current = await Ollama.assessClickyTask(details, definition: definition, config: store.config, localOnly: true)
        }
        guard current.meetsDefinition == false, !current.missing.isEmpty else {
            bumpDraftError = current.meetsDefinition == true
                ? "The latest report appears to meet the saved goal; no follow-up draft is needed."
                : "No concrete gap is available yet; review the latest report before drafting."
            return
        }

        do {
            let draft = try await Ollama.draftTaskBump(task: details, definition: definition, project: task.project,
                                                      priority: priority, missing: current.missing, config: store.config)
            guard draft.unfinished else {
                bumpDraftError = "The latest report has no actionable gap; no follow-up draft is needed."
                return
            }
            bumpDraftMessage = draft.message
        } catch {
            bumpDraftError = error.localizedDescription
        }
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
                    Button(draftingBump ? "Drafting…" : "Draft follow-up") {
                        Task { await createBumpDraft() }
                    }
                    .disabled(!canDraftBump || draftingBump)
                    .help("Drafts locally from the latest report and saved goal. Nothing is queued, typed, or sent.")
                    .accessibilityIdentifier("bump-task-\(task.id)")
                    Spacer()
                }
                if let bumpDraftMessage {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Draft only · not sent", systemImage: "doc.text")
                            .font(.caption.weight(.semibold)).foregroundStyle(Brand.periwinkle)
                        Text(bumpDraftMessage).font(.caption).textSelection(.enabled)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.card.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                }
                if let bumpDraftError {
                    Text("Draft unavailable: \(bumpDraftError)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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
        .onAppear { showingDetails = initiallyExpanded }
        .onChange(of: task.id) { _, _ in showingDetails = initiallyExpanded }
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
                Text(String(details.lastMessage.prefix(6_000)))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if details.lastMessage.count > 6_000 {
                    Text("Report shortened after 6,000 characters; open the task thread in HeyClicky for the remainder.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
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
                VStack(alignment: .leading, spacing: 5) {
                    Label("Evidence · \(details.threadReferences.count) excerpts", systemImage: "doc.text.magnifyingglass")
                        .font(.caption.weight(.semibold))
                    if details.threadReferences.isEmpty && details.evidenceErrors.isEmpty {
                        Text("No linked thread excerpts or evidence errors were recorded.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(details.threadIDs.prefix(4), id: \.self) { id in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Thread: \(id)").font(.caption2).textSelection(.enabled)
                            ForEach(Array(Set(details.threadReferences.filter { $0.threadID == id }.map(\.source))).sorted(), id: \.self) { source in
                                Text(source).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    if details.threadIDs.count > 4 {
                        Text("And \(details.threadIDs.count - 4) more linked threads.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(Array(details.evidenceErrors.prefix(3)), id: \.self) { error in
                        Text(error).font(.caption2).foregroundStyle(Brand.youBadge).textSelection(.enabled)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.card.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
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
