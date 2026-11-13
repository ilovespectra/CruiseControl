import SwiftUI
import UniformTypeIdentifiers
import AppKit
import CruiseCore

private enum TaskReportBlock: Identifiable {
    case markdown(Int, String)
    case code(Int, String, String)

    var id: Int {
        switch self {
        case .markdown(let id, _), .code(let id, _, _): id
        }
    }
}

private enum TaskReportParser {
    static func blocks(_ source: String) -> [TaskReportBlock] {
        var result: [TaskReportBlock] = []
        var prose: [String] = []
        var code: [String] = []
        var language = ""
        var insideCode = false
        var nextID = 0

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { prose.removeAll(); return }
            result.append(.markdown(nextID, text))
            nextID += 1
            prose.removeAll()
        }

        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if insideCode {
                    result.append(.code(nextID, language, code.joined(separator: "\n")))
                    nextID += 1
                    code.removeAll()
                    language = ""
                    insideCode = false
                } else {
                    flushProse()
                    language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    insideCode = true
                }
            } else if insideCode {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if insideCode {
            result.append(.code(nextID, language, code.joined(separator: "\n")))
            nextID += 1
        } else {
            flushProse()
        }
        return result
    }
}

private struct TaskCodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "curlybraces").foregroundStyle(Brand.periwinkle)
                Text(language.isEmpty ? "Code" : language)
                    .font(BrandFont.inter(9, .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(TaskControlPillStyle(selected: copied))
                .accessibilityLabel(copied ? "Code copied" : "Copy code block")
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            ScrollView([.horizontal, .vertical]) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.86))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(9)
            }
            .frame(maxWidth: .infinity, maxHeight: 210, alignment: .topLeading)
            .background(Color.black.opacity(0.48))
        }
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct TaskReportContent: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(TaskReportParser.blocks(text)) { block in
                switch block {
                case .markdown(_, let markdown):
                    if let attributed = try? AttributedString(markdown: markdown) {
                        Text(attributed).font(BrandFont.inter(11)).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(markdown).font(BrandFont.inter(11)).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                case .code(_, let language, let code):
                    TaskCodeBlockView(language: language, code: code)
                }
            }
        }
    }
}

private enum TaskProviderFilter: String, CaseIterable, Identifiable {
    case all, heyClicky, vsCode
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .heyClicky: "HeyClicky"
        case .vsCode: "VS Code"
        }
    }
}

private enum AgentTaskEntry: Identifiable {
    case clicky(CatalogTask)
    case vscode(VSCodeVisibleSession)

    var id: String {
        switch self {
        case .clicky(let task): "clicky:\(task.id)"
        case .vscode(let session): "vscode:\(session.key)"
        }
    }

    var title: String {
        switch self {
        case .clicky(let task): task.name
        case .vscode(let session): session.title
        }
    }
}

private struct AgentTaskGroup: Identifiable {
    let id: String
    let title: String
    var entries: [AgentTaskEntry]
}

private enum TaskListFilter: String, CaseIterable, Identifiable {
    case all, needsDefinition, defined, attention, working, reportedDone, unassigned, reviewEnabled, autoBumpEnabled, closed

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "Open tasks"
        case .needsDefinition: "Needs a definition"
        case .defined: "Defined"
        case .attention: "Needs attention"
        case .working: "Working"
        case .reportedDone: "Ready for your review"
        case .unassigned: "Unassigned project"
        case .reviewEnabled: "In Cruise review"
        case .autoBumpEnabled: "Auto-bump enabled"
        case .closed: "Closed / archived"
        }
    }
}

struct TasksSettingsView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var monitor: ClickyMonitor
    @ObservedObject private var tasks = ClickyTaskStore.shared
    @State private var search = ""
    @State private var filter: TaskListFilter = .all
    @State private var providerFilter: TaskProviderFilter = .all
    @State private var priorityFilter: TaskPriorityFilter = .all
    @State private var projectFilter = "all"
    @State private var vscodeSessions: [VSCodeVisibleSession] = []
    @State private var selectedVSCodeSessionKey: String?
    @State private var collapsedGroups: Set<String> = []
    @State private var initializedGroupState = false
    @State private var refreshing = false
    @State private var selectedTaskID: String?
    @State private var showingProjectWizard = false
    @State private var workspaceWizardAutoPresented = false

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
        groups(matching: filter)
    }

    private func groups(matching listFilter: TaskListFilter) -> [TaskCatalog.Group] {
        let grouping: TaskGrouping = groupedByWorkspace ? .directory : groupedByProject ? .project : .none
        let catalogSort: TaskSort = selectedSort == .priority ? .name : selectedSort
        let candidates = monitor.taskCatalog.groups(by: grouping, sort: catalogSort, query: search)
        guard providerFilter != .vsCode else { return [] }
        guard selectedSort == .priority else {
            return candidates.filter { group in group.tasks.contains { isVisible($0, matching: listFilter) } }
        }
        // Compute each group's sort key once; sort comparators must not re-filter tasks.
        let keyed = candidates.compactMap { group -> (TaskCatalog.Group, rank: Int, updated: Date)? in
            let matches = group.tasks.filter { isVisible($0, matching: listFilter) }
            guard !matches.isEmpty else { return nil }
            return (group, matches.map { priority(for: $0).rank }.min() ?? TaskPriority.normal.rank,
                    matches.map(lastUpdate(for:)).max() ?? .distantPast)
        }
        return keyed.sorted { left, right in
            if left.0.id == "unassigned" { return false }
            if right.0.id == "unassigned" { return true }
            if left.rank != right.rank { return left.rank < right.rank }
            if left.updated != right.updated { return left.updated > right.updated }
            return left.0.title.localizedStandardCompare(right.0.title) == .orderedAscending
        }.map(\.0)
    }

    private var visibleTaskCount: Int {
        visibleGroups.reduce(0) { $0 + visibleTasks(in: $1).count } + visibleVSCodeSessions.count
    }

    private var visibleVSCodeSessions: [VSCodeVisibleSession] {
        guard providerFilter != .heyClicky, filter != .closed else { return [] }
        let query = Matcher.normalize(search)
        return vscodeSessions.filter { session in
            let workspace = session.workspaceTitle ?? session.discoveredDirectory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unassigned workspace"
            guard query.isEmpty || Matcher.normalize("\(session.title) \(workspace) \(session.discoveredDirectory ?? "")").contains(query) else { return false }
            if projectFilter != "all", projectKey(vscodeProject(session)) != projectFilter { return false }
            let definition = DefinitionOfDone.normalized(store.config.vscodeDefinitionsOfDone[session.key])
            let optedIn = store.config.vscodeAutoBumpChatKeys.contains(session.key)
            let state = Matcher.normalize(session.state)
            switch filter {
            case .all: break
            case .needsDefinition: guard definition == nil else { return false }
            case .defined: guard definition != nil else { return false }
            case .attention: guard state.contains("wait") || state.contains("need") || state.contains("fail") || state.contains("error") else { return false }
            case .working: guard state.contains("work") || state.contains("run") else { return false }
            case .reportedDone: guard state.contains("done") || state.contains("complete") else { return false }
            case .unassigned: guard store.config.vscodeTaskProjects[session.key]?.directoryPath == nil else { return false }
            case .reviewEnabled: guard store.config.vscodeTaskPlans[session.key]?.enabled == true else { return false }
            case .autoBumpEnabled: guard optedIn else { return false }
            case .closed: return false
            }
            let priority = store.config.vscodeTaskPlans[session.key]?.priority ?? .normal
            return priorityFilter.includes(priority)
        }
    }

    private var selectedVSCodeSession: VSCodeVisibleSession? {
        guard let selectedVSCodeSessionKey else { return nil }
        return visibleVSCodeSessions.first { $0.key == selectedVSCodeSessionKey }
    }

    private var attentionTaskCount: Int {
        groups(matching: .attention).reduce(0) { $0 + visibleTasks(in: $1, matching: .attention).count }
    }

    private func visibleTasks(in group: TaskCatalog.Group, matching listFilter: TaskListFilter? = nil) -> [CatalogTask] {
        let matches = group.tasks.filter { isVisible($0, matching: listFilter ?? filter) }
        guard selectedSort == .priority else { return matches }
        return matches.map { ($0, rank: priority(for: $0).rank, updated: lastUpdate(for: $0)) }
            .sorted { left, right in
                if left.rank != right.rank { return left.rank < right.rank }
                if left.updated != right.updated { return left.updated > right.updated }
                let comparison = left.0.name.localizedStandardCompare(right.0.name)
                return comparison == .orderedSame ? left.0.id < right.0.id : comparison == .orderedAscending
            }
            .map(\.0)
    }

    private func isVisible(_ item: CatalogTask, matching listFilter: TaskListFilter) -> Bool {
        (projectFilter == "all" || projectKey(item.project) == projectFilter)
            && priorityFilter.includes(priority(for: item))
            && matchesFilter(item, matching: listFilter)
    }

    private func matchesFilter(_ item: CatalogTask, matching listFilter: TaskListFilter) -> Bool {
        let definition = store.config.clickyDefinitionsOfDone[item.id]
        let current = tasks.task(item.id)
        if current == nil, item.localDisposition != nil { return listFilter == .closed }
        if current?.dismissed == true { return listFilter == .closed }
        let assessment = current.flatMap { tasks.currentAssessment(for: $0, definition: definition) }
        let status = item.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch listFilter {
        case .all:
            return current?.dismissed != true
        case .needsDefinition:
            return current != nil && DefinitionOfDone.normalized(definition) == nil
        case .defined:
            return current != nil && DefinitionOfDone.normalized(definition) != nil
        case .attention:
            if let current, current.isWorking { return false }
            if let assessment,
               assessment.state == .needsYou || assessment.state == .unfinished || assessment.state == .failed {
                return true
            }
            return status == "failed" || current.map { tasks.reportRequiresUser($0) } == true
        case .working:
            return current?.isWorking == true || ["working", "running", "in progress"].contains(status)
        case .reportedDone:
            return assessment?.state == .done || ["done", "complete", "completed", "success", "succeeded"].contains(status)
        case .unassigned:
            return item.project.title == nil
        case .reviewEnabled:
            return store.config.taskPlans[item.id]?.enabled == true
        case .autoBumpEnabled:
            return TaskPlanning.autoBumpOptedIn(taskID: item.id, config: store.config)
        case .closed:
            return current?.dismissed == true
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
        tasks.updatedAt(item.id) ?? item.updatedAt
    }

    private func latestUpdate(in group: TaskCatalog.Group) -> Date {
        visibleTasks(in: group).map(lastUpdate(for:)).max() ?? .distantPast
    }

    private var projectFilterTitle: String {
        if projectFilter == "all" { return "All projects & workspaces" }
        return projectChoices.first { $0.id == projectFilter }?.title ?? "All projects & workspaces"
    }

    private func projectKey(_ project: TaskProject) -> String {
        project.directoryPath.map { "dir:\($0)" } ?? project.priorityKey
    }

    private func vscodeProject(_ session: VSCodeVisibleSession) -> TaskProject {
        if let confirmed = store.config.vscodeTaskProjects[session.key] { return confirmed }
        var suggestion = TaskProject()
        suggestion.name = session.workspaceTitle ?? ""
        suggestion.directory = session.discoveredDirectory ?? ""
        return suggestion
    }

    private var projectChoices: [AgentTaskGroup] {
        let projects = monitor.taskCatalog.tasks.map(\.project) + vscodeSessions.map(vscodeProject)
        var names: [String: String] = [:]
        for project in projects { names[projectKey(project)] = project.title ?? "Unassigned" }
        return names.map { AgentTaskGroup(id: $0.key, title: $0.value, entries: []) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var vscodeWorkspaceNames: [String] {
        Array(Set(vscodeSessions.map { session in
            session.workspaceTitle ?? session.discoveredDirectory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unassigned workspace"
        })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var listedTaskIDs: [String] { visibleGroups.flatMap { visibleTasks(in: $0) }.map(\.id) }
    private var selectedTask: CatalogTask? {
        guard selectedVSCodeSessionKey == nil, providerFilter != .vsCode else { return nil }
        let listed = visibleGroups.flatMap { visibleTasks(in: $0) }
        return listed.first(where: { $0.id == selectedTaskID })
    }

    private var unifiedEntries: [AgentTaskEntry] {
        let entries = visibleGroups.flatMap { visibleTasks(in: $0) }.map(AgentTaskEntry.clicky)
            + visibleVSCodeSessions.map(AgentTaskEntry.vscode)
        func priorityRank(_ entry: AgentTaskEntry) -> Int {
            switch entry {
            case .clicky(let item): priority(for: item).rank
            case .vscode(let session): (store.config.vscodeTaskPlans[session.key]?.priority ?? .normal).rank
            }
        }
        func date(_ entry: AgentTaskEntry) -> Date {
            switch entry {
            case .clicky(let task): selectedSort == .newest ? task.createdAt ?? .distantPast : lastUpdate(for: task)
            case .vscode: .distantPast
            }
        }
        return entries.sorted { left, right in
            if selectedSort == .priority, priorityRank(left) != priorityRank(right) {
                return priorityRank(left) < priorityRank(right)
            }
            if [.updated, .newest].contains(selectedSort), date(left) != date(right) {
                return date(left) > date(right)
            }
            let comparison = left.title.localizedStandardCompare(right.title)
            return comparison == .orderedSame ? left.id < right.id : comparison == .orderedAscending
        }
    }

    private var unifiedGroups: [AgentTaskGroup] {
        guard groupedByProject || groupedByWorkspace else {
            return [.init(id: "all", title: "", entries: unifiedEntries)]
        }
        var groups: [AgentTaskGroup] = []
        for entry in unifiedEntries {
            let project: TaskProject
            switch entry {
            case .clicky(let task): project = task.project
            case .vscode(let session): project = vscodeProject(session)
            }
            let key = projectKey(project)
            if let index = groups.firstIndex(where: { $0.id == key }) {
                groups[index].entries.append(entry)
            } else {
                groups.append(.init(id: key, title: groupedByWorkspace ? project.directoryPath ?? "Unassigned workspace" : project.title ?? "Unassigned", entries: [entry]))
            }
        }
        return groups
    }

    private var selectedEntryID: String? {
        if let selectedVSCodeSessionKey { return "vscode:\(selectedVSCodeSessionKey)" }
        return selectedTaskID.map { "clicky:\($0)" }
    }

    private func selectEntry(_ entry: AgentTaskEntry?) {
        selectedTaskID = nil
        selectedVSCodeSessionKey = nil
        switch entry {
        case .clicky(let task): selectedTaskID = task.id
        case .vscode(let session): selectedVSCodeSessionKey = session.key
        case nil: break
        }
    }

    private func refreshVSCodeSessions() async {
        let config = store.config
        let discovered = await Worker.scanVSCode { VSCodeScanner(config: config).visibleTaskSessions() }
        monitor.adoptLegacyVSCodeKeys(discovered)
        vscodeSessions = discovered
        if let selectedVSCodeSessionKey, !discovered.contains(where: { $0.key == selectedVSCodeSessionKey }) {
            self.selectedVSCodeSessionKey = nil
        }
    }

    private var redesignedBody: some View {
        VStack(spacing: 0) {
            taskHeader.padding(.bottom, 8)
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                Label(monitor.engineSummary, systemImage: monitor.engineActivity == nil ? "checklist" : "gearshape.2")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("task-engine-summary")
            }
            .padding(.bottom, 6)
            taskControls.padding(.bottom, 6)
            taskFilters.padding(.bottom, 7)
            DisclosureGroup("Automation & safety") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mode: \(store.config.mode.rawValue.capitalized). Task Auto-bump runs in Manual or Cruise independently of drive approvals; Rest pauses it.")
                    Toggle("Allow per-task auto-bumps", isOn: $store.config.continueUntilDefinedDone)
                    Toggle("Keep unfinished tasks going", isOn: $store.config.autoContinueReports)
                    Toggle("Review opted-in tasks in the background", isOn: $store.config.backgroundTaskReview)
                    Text("Background review is separate from Auto-bump and selected-task previews. Global switches never change a task's saved opt-in.")
                    if let message = monitor.pendingMessage {
                        Text("Confirming delivery of a message to \(message.task). If HeyClicky doesn't confirm it within 10 minutes it's set aside in Activity and other tasks keep going.")
                            .foregroundStyle(Brand.youBadge)
                    }
                }
                .font(.caption)
            }
            .padding(.bottom, 8)
            taskContentColumns
                .frame(maxHeight: .infinity)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.07)))
            taskFooter.padding(.top, 8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
        .task {
            await refreshVSCodeSessions()
            await monitor.refreshTaskCatalog()
        }
        .task {
            // VS Code chats appear, finish and get renamed while this pane is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await refreshVSCodeSessions()
            }
        }
        .onReceive(tasks.$tasks) { loaded in
            if tasks.loadedAt != nil { monitor.updateTaskCatalog(loaded) }
        }
        .onReceive(tasks.$loadedAt) { loadedAt in
            guard loadedAt != nil else { return }
            monitor.updateTaskCatalog(tasks.tasks)
            if selectedEntryID == nil { selectEntry(unifiedEntries.first) }
        }
        .onChange(of: unifiedEntries.map(\.id)) { previousIDs, ids in
            if !ids.contains(selectedEntryID ?? "") {
                let previousIndex = previousIDs.firstIndex(of: selectedEntryID ?? "") ?? 0
                selectEntry(unifiedEntries.isEmpty ? nil : unifiedEntries[min(previousIndex, ids.count - 1)])
            }
        }
        .onReceive(tasks.$requestedTaskID) { id in
            guard let id else { return }
            search = ""
            filter = .all
            priorityFilter = .all
            projectFilter = "all"
            providerFilter = .all
            selectedVSCodeSessionKey = nil
            selectedTaskID = id
            tasks.requestedTaskID = nil
        }
        .sheet(isPresented: $showingProjectWizard) {
            TaskProjectWizard(monitor: monitor, store: store, vscodeSessions: vscodeSessions) {
                store.config.taskWorkspaceWizardCompleted = true
                showingProjectWizard = false
            }
        }
    }

    private var taskHeader: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "checklist").foregroundStyle(Brand.periwinkle).font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Tasks").font(BrandFont.inter(16, .semibold))
                Text("HeyClicky & VS Code · \(monitor.taskCatalog.currentTaskCount) tasks · \(vscodeSessions.count) sessions")
                    .font(BrandFont.inter(9.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task {
                    refreshing = true
                    await refreshVSCodeSessions()
                    await monitor.refreshTaskCatalog()
                    await tasks.refresh()
                    refreshing = false
                }
            } label: {
                Label(refreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(refreshing)
            .accessibilityIdentifier("refresh-agent-tasks")
            Button("Review tasks & folders") { showingProjectWizard = true }
                .buttonStyle(.bordered)
                .help("Review first-word task suggestions and confirm or reject each task and workspace.")
                .accessibilityIdentifier("review-task-groups")
        }
    }

    private var taskControls: some View {
        VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 9) {
            TextField("Search tasks, projects, workspaces…", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("agent-task-search")
            Picker("Provider", selection: $providerFilter) {
                ForEach(TaskProviderFilter.allCases) { option in Text(option.title).tag(option) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            .accessibilityIdentifier("task-provider-filter")
        }
        DisclosureGroup("Sort & organization") {
        HStack(spacing: 9) {
            Menu {
                ForEach([TaskGrouping.project, .directory, .none]) { option in
                    Button {
                        store.config.taskGrouping = option
                        projectFilter = "all"
                    } label: {
                        let title = option == .directory ? "Group by workspace" : option == .project ? "Group by project" : "Flat task list"
                        if (groupedByWorkspace ? .directory : groupedByProject ? .project : .none) == option { Label(title, systemImage: "checkmark") }
                        else { Text(title) }
                    }
                }
            } label: { TaskMenuPill(title: groupedByWorkspace ? "Workspace groups" : groupedByProject ? "Project groups" : "Flat list", icon: "folder") }
            .accessibilityIdentifier("agent-task-layout")
            Menu {
                ForEach(TaskPriorityFilter.allCases) { option in
                    Button {
                        priorityFilter = option
                    } label: {
                        if priorityFilter == option { Label(option.title, systemImage: "checkmark") }
                        else { Text(option.title) }
                    }
                }
            } label: {
                TaskMenuPill(title: priorityFilter.title, icon: "flag")
            }
            .accessibilityLabel("Priority filter, \(priorityFilter.title)")
            .frame(width: 128)
            .accessibilityIdentifier("agent-task-priority-filter")
            Menu {
                ForEach(visibleSorts) { option in
                    Button {
                        store.config.taskSort = option
                    } label: {
                        if selectedSort == option { Label(option.title, systemImage: "checkmark") }
                        else { Text(option.title) }
                    }
                }
            } label: {
                TaskMenuPill(title: selectedSort.title, icon: "arrow.up.arrow.down")
            }
            .accessibilityLabel("Sort tasks, \(selectedSort.title)")
            .frame(width: 135)
            .accessibilityIdentifier("agent-task-sort")
        }
        }
        }
    }

    private var taskFilters: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(TaskListFilter.allCases) { option in
                    Button {
                        filter = option
                    } label: {
                        if filter == option { Label(option.title, systemImage: "checkmark") }
                        else { Text(option.title) }
                    }
                }
            } label: { TaskMenuPill(title: filter.title, icon: "line.3.horizontal.decrease.circle") }
            .accessibilityIdentifier("agent-task-filter")
            Menu {
                Button("All projects & workspaces") { projectFilter = "all" }
                ForEach(projectChoices) { group in
                    Button(group.title) { projectFilter = group.id }
                }
            } label: { TaskMenuPill(title: projectFilterTitle, icon: "folder") }
            .accessibilityIdentifier("agent-project-filter")
            Spacer(minLength: 0)
            Text("\(visibleTaskCount) shown")
                .font(BrandFont.inter(9)).foregroundStyle(.secondary)
        }
    }

    private var taskContentColumns: some View {
        HStack(spacing: 0) {
            taskListColumn.frame(width: 310).frame(maxHeight: .infinity)
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
            taskDetailColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var taskListColumn: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("TASKS & SESSIONS")
                        .font(BrandFont.inter(9, .bold)).tracking(0.8).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(visibleTaskCount)").font(BrandFont.mono(9)).foregroundStyle(.tertiary)
                }
                ForEach(unifiedGroups) { group in
                    if !group.title.isEmpty {
                        Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .lineLimit(1).help(group.title).padding(.top, 5)
                    }
                ForEach(group.entries) { entry in
                    switch entry {
                    case .clicky(let task): taskListButton(task)
                    case .vscode(let session): vscodeSessionRow(session)
                    }
                    }
                }
                if visibleTaskCount == 0 {
                    Text(tasks.loading ? "Reading agent tasks…" : "Nothing matches these filters.")
                        .font(BrandFont.inter(11)).foregroundStyle(.secondary).padding(12)
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("task-sidebar-scroll")
        .focusable()
        .onMoveCommand { direction in
            let entries = unifiedEntries
            guard !entries.isEmpty else { return }
            let index = entries.firstIndex(where: { $0.id == selectedEntryID }) ?? 0
            if direction == .up { selectEntry(entries[max(0, index - 1)]) }
            if direction == .down { selectEntry(entries[min(entries.count - 1, index + 1)]) }
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
        ScrollView(.vertical) { taskDetailContent }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityIdentifier("task-detail-scroll")
    }

    private func vscodeSessionRow(_ session: VSCodeVisibleSession) -> some View {
        let selected = selectedVSCodeSessionKey == session.key
        let workspace = session.workspaceTitle ?? session.discoveredDirectory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Workspace not identified"
        return Button {
            selectedTaskID = nil
            selectedVSCodeSessionKey = session.key
        } label: {
            HStack(alignment: .top, spacing: 7) {
                Circle().fill(session.ambiguous ? Brand.youBadge : taskAccent(session.state)).frame(width: 6, height: 6).padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(session.title).font(BrandFont.inter(10, .medium)).lineLimit(1)
                        if session.ambiguous { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.youBadge) }
                    }
                    Text("VS Code · \(workspace) · \(session.state)")
                        .font(BrandFont.inter(8.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Brand.navy.opacity(0.75) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Brand.periwinkle.opacity(0.5) : Color.clear))
        }
        .buttonStyle(.plain)
        .disabled(session.ambiguous)
        .help(session.ambiguous ? "This session identity is ambiguous; no actions are available." : "Select this exact VS Code session. VS Code exposes relative update labels, not a creation timestamp; dated sorts place unknown timestamps last.")
        .accessibilityIdentifier("vscode-task-row-\(session.id)")
    }

    @ViewBuilder
    private var taskDetailContent: some View {
        if let session = selectedVSCodeSession {
            VSCodeTasksSection(session: session, store: store, monitor: monitor)
                .id(session.key)
                .padding(12)
        } else if let current = selectedTask {
            TaskProjectRow(task: current, projects: projectGroups.map(\.project), store: store,
                           tasks: tasks, monitor: monitor,
                           assign: { monitor.assignProject($0, to: current.id) },
                           reset: { monitor.resetProject(for: current.id) }, initiallyExpanded: false)
                .id(current.id)
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
        let selected = selectedVSCodeSessionKey == nil && selectedTaskID == item.id
        return Button { selectedVSCodeSessionKey = nil; selectedTaskID = item.id } label: {
            HStack(alignment: .top, spacing: 7) {
                Circle().fill(taskAccent(item.status)).frame(width: 6, height: 6).padding(.top, 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(BrandFont.inter(10.5, .medium)).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        Text("HeyClicky · \(item.status.replacingOccurrences(of: "_", with: " ").capitalized)")
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
            if !store.config.taskWorkspaceWizardCompleted, !workspaceWizardAutoPresented,
               !monitor.taskCatalog.nameSuggestionGroups().isEmpty {
                workspaceWizardAutoPresented = true
                showingProjectWizard = true
            }
            if projectFilter != "all" && !projectGroups.contains(where: { $0.id == projectFilter }) {
                projectFilter = "all"
            }
        }
    }
}

private struct TaskProjectWizard: View {
    @ObservedObject var monitor: ClickyMonitor
    @ObservedObject var store: ConfigStore
    var vscodeSessions: [VSCodeVisibleSession] = []
    let close: () -> Void
    @State private var folderTaskID: String?
    @State private var selectingFolder = false
    @State private var folderError: String?
    @State private var folderVSCodeKey: String?

    private var vscodeSuggestions: [String: [VSCodeVisibleSession]] {
        Dictionary(grouping: vscodeSessions.filter { store.config.vscodeTaskProjects[$0.key] == nil }) {
            Matcher.normalize($0.title.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? $0.title)
        }
    }

    private var suggestions: [TaskCatalog.NameSuggestionGroup] {
        monitor.taskCatalog.nameSuggestionGroups()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review tasks and workspaces").font(.title3.weight(.semibold))
            Text("Matching first words are suggestions only. Confirm each task or mark it as not part of that group. Suggested folders need your confirmation; choosing a folder for a task saves it immediately.")
                .font(.caption).foregroundStyle(.secondary)
            if suggestions.isEmpty && vscodeSuggestions.isEmpty {
                ContentUnavailableView("No unassigned tasks to review", systemImage: "checkmark.folder",
                                       description: Text("You can reopen this review from the task list at any time."))
                    .frame(minHeight: 180)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(suggestions) { group in
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Starts with “\(group.firstWord)”").font(.headline)
                                ForEach(group.tasks) { item in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.name).font(.caption.weight(.medium)).lineLimit(2)
                                        if let path = item.project.directoryPath {
                                            Label("Suggested folder · \(path)", systemImage: "folder.badge.questionmark")
                                                .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                        } else {
                                            Label("No workspace folder confirmed", systemImage: "folder")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                        HStack {
                                            Button("Choose folder…") {
                                                folderVSCodeKey = nil
                                                folderTaskID = item.id
                                                selectingFolder = true
                                            }
                                            .help("Choosing a folder saves it to this task as confirmed immediately.")
                                            .accessibilityIdentifier("wizard-choose-folder-\(item.id)")
                                            Button("Confirm task") {
                                                var project = item.project
                                                if project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                                    project.name = group.firstWord
                                                }
                                                monitor.assignProject(project, to: item.id)
                                            }
                                            .accessibilityIdentifier("wizard-confirm-\(item.id)")
                                            Button("Not this group") {
                                                monitor.assignProject(TaskProject(), to: item.id)
                                            }
                                            .accessibilityIdentifier("wizard-reject-\(item.id)")
                                        }
                                        .font(.caption)
                                    }
                                    .padding(.vertical, 3)
                                    Divider()
                                }
                            }
                            .padding(10)
                            .background(Brand.card, in: RoundedRectangle(cornerRadius: 9))
                        }
                        vscodeReviewRows
                    }
                }
            }
            if let folderError {
                Text(folderError).font(.caption2).foregroundStyle(Brand.youBadge)
            }
            HStack {
                Spacer()
                Button("Finish review", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
        .fileImporter(isPresented: $selectingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first, let key = folderVSCodeKey,
                   let session = vscodeSessions.first(where: { $0.key == key }) {
                    var project = TaskProject()
                    project.name = session.title.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? session.title
                    project.directory = url.standardizedFileURL.path
                    store.config.vscodeTaskProjects[key] = project
                    folderError = nil
                    return
                }
                guard let url = urls.first, let taskID = folderTaskID,
                      let item = monitor.taskCatalog.tasks.first(where: { $0.id == taskID }),
                      let group = suggestions.first(where: { $0.tasks.contains(where: { $0.id == taskID }) }) else { return }
                var project = item.project
                if project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { project.name = group.firstWord }
                project.directory = url.standardizedFileURL.path
                monitor.assignProject(project, to: taskID)
                folderError = nil
            case .failure(let error):
                folderError = error.localizedDescription
            }
        }
    }

    private var vscodeReviewRows: some View {
        ForEach(vscodeSuggestions.keys.sorted(), id: \.self) { firstWord in
            VStack(alignment: .leading, spacing: 7) {
                Text("Starts with “\(firstWord)” · VS Code").font(.headline)
                ForEach(vscodeSuggestions[firstWord] ?? []) { session in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(session.title).font(.caption.weight(.medium))
                        if let path = session.discoveredDirectory {
                            Text("Suggested, not confirmed: \(path)").font(.caption2).textSelection(.enabled)
                            Button("Confirm task & suggested folder") {
                                var project = TaskProject()
                                project.name = firstWord
                                project.directory = path
                                store.config.vscodeTaskProjects[session.key] = project
                            }
                        }
                        HStack {
                            Button("Choose folder…") {
                                folderVSCodeKey = session.key
                                selectingFolder = true
                            }
                            Button("Not this group") {
                                store.config.vscodeTaskProjects[session.key] = TaskProject()
                            }
                        }
                    }
                    .font(.caption)
                }
            }
            .padding(10).background(Brand.card, in: RoundedRectangle(cornerRadius: 9))
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
    @State private var choosingFolder = false
    @State private var definingDone = false
    @State private var definitionDraft = ""
    @State private var showingDetails = false
    @State private var draftingBump = false
    @State private var sendingBump = false
    @State private var workspaceBranches: [String] = []
    @State private var newBranchName = ""
    @State private var workspaceGitStatus: String?
    @State private var bumpDraftMessage: String?
    @State private var bumpDraftFingerprint: String?
    @State private var bumpDraftDefinition: String?
    @State private var bumpDraftWorkflowKey: String?
    @State private var bumpDraftAssessment: ClickyTaskAssessment?
    @State private var bumpDraftError: String?
    @State private var bumpSendStatus: String?
    @State private var sendingLifecycleNotice = false
    @State private var lifecycleNoticeStatus: String?
    @State private var confirmingSavedRecordDeletion = false

    private var details: ClickyAgentTask? { tasks.task(task.id) }
    private var stateLabel: String {
        let state = Matcher.normalize(task.status)
        return ["done", "complete", "completed", "reported done"].contains(state) ? "Ready for your review" : task.status.replacingOccurrences(of: "_", with: " ").capitalized
    }
    private var nextAction: String {
        guard details != nil else { return "History only — no matching current HeyClicky task." }
        if flow.current == nil, assessment?.meetsDefinition == true { return "Check the report evidence, then mark the task finished." }
        return flow.nextAction
    }
    private var reviewed: Bool { assessment != nil && draftGate != .reviewLatestReport }
    private var flow: TaskFlow {
        let ambiguous = details.map { ClickyTaskLibrary.ambiguousNames(tasks.tasks).contains(Matcher.normalize($0.name)) } ?? false
        let reviewBlocker: TaskBlocker? = if let details {
            details.dismissed ? TaskBlocker("This task is dismissed in HeyClicky, so Cruise can't read or bump it.", fix: .showInHeyClicky)
                : !details.hasReport ? TaskBlocker("HeyClicky hasn't posted a response in this task yet. Cruise reviews it as soon as one appears.", fix: .showInHeyClicky)
                : details.isWorking ? TaskBlocker("HeyClicky is still working on this task. Cruise reviews it when the turn finishes.", fix: .showInHeyClicky)
                : ambiguous ? TaskBlocker("Another HeyClicky task has the same name, so Cruise won't target either. Rename one in HeyClicky.", fix: .showInHeyClicky)
                : nil
        } else { TaskBlocker("This task isn't in HeyClicky's current task list.", fix: .refreshTasks) }
        let key = ClickyMonitor.clickyKey(task.id)
        let record = monitor.engine.records[key]
        let activity: String? = sendingBump ? "Sending this draft to HeyClicky"
            : monitor.engineActivity.flatMap { $0.key == key ? $0.text : nil }
        return TaskFlow(
            hasFolder: hasConfirmedWorkspace, hasDefinition: definition != nil,
            reviewBlocker: reviewBlocker, reviewed: reviewed,
            draftBlocker: messagePolicyBlocker.map { TaskBlocker($0, fix: .defineDone) }
                ?? (draftGate == .ready ? nil : draftBlocker),
            hasDraft: bumpDraftMessage != nil,
            sendBlocker: store.config.mode == .rest
                ? TaskBlocker("Rest mode pauses sending. Switch to Manual or Cruise mode.", fix: .automationSettings)
                : record?.stage == .held ? record?.blocker : nil,
            activity: activity)
    }
    private var draftBlocker: TaskBlocker {
        switch draftGate {
        case .taskStopped: TaskBlocker("You stopped this task in HeyClicky, so Cruise holds its follow-ups. Resume auto-bump to continue.", fix: .resumeStopped)
        case .needsUser: TaskBlocker("HeyClicky asked you a question in this task. Answer it there; Cruise won't answer for you.", fix: .showInHeyClicky)
        case .reviewLatestReport: TaskBlocker(TaskDraftGate.reviewLatestReport.message, fix: .reviewReport)
        case .ambiguousTask: TaskBlocker(TaskDraftGate.ambiguousTask.message, fix: .showInHeyClicky)
        case .noActionableGaps: TaskBlocker("The latest response appears to cover Done. Check its evidence in HeyClicky.", fix: .showInHeyClicky)
        default: TaskBlocker(draftGate.message, fix: .showInHeyClicky)
        }
    }
    private func goThere(_ fix: TaskFix) {
        switch fix {
        case .defineDone:
            definitionDraft = store.config.clickyDefinitionsOfDone[task.id] ?? ""
            definingDone = true
        case .chooseFolder:
            choosingFolder = true
        default:
            Task { if let message = await monitor.perform(fix, key: ClickyMonitor.clickyKey(task.id)) { bumpSendStatus = message } }
        }
    }
    private var autoBumpLockReason: String? {
        if definition == nil { return "Define what done looks like first (step 2)." }
        if details?.dismissed == true { return TaskDraftGate.taskDismissed.message }
        if !hasConfirmedWorkspace { return "Confirm a project folder first." }
        return TaskWorkflow.autoBumpBlocker(plan: store.config.taskPlans[task.id] ?? TaskPlan())
    }
    private var suggestedFolder: String? {
        task.projectAssigned ? nil : task.project.directoryPath
    }
    private func chooseFolder(_ path: String) {
        var project = task.projectAssigned ? task.project : TaskProject()
        project.directory = path
        if project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            project.name = task.project.name.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : task.project.name
        }
        assign(project)
    }
    private var definition: String? { DefinitionOfDone.normalized(store.config.clickyDefinitionsOfDone[task.id]) }

    private func refreshWorkspaceBranches() {
        guard hasConfirmedWorkspace, let path = task.project.directoryPath else {
            workspaceBranches = []
            workspaceGitStatus = nil
            return
        }
        do {
            workspaceBranches = try TaskWorkspaceGit.branches(in: path)
            workspaceGitStatus = workspaceBranches.isEmpty
                ? "No local branches found."
                : "Found \(workspaceBranches.count) local branch\(workspaceBranches.count == 1 ? "" : "es")."
        } catch {
            workspaceBranches = []
            workspaceGitStatus = error.localizedDescription
        }
    }

    private func createWorkspaceBranch() {
        guard hasConfirmedWorkspace, let path = task.project.directoryPath else { return }
        let name = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try TaskWorkspaceGit.createBranch(name, in: path)
            newBranchName = ""
            refreshWorkspaceBranches()
            workflowBinding(\.workBranch).wrappedValue = name
            workspaceGitStatus = "Created local branch “\(name)” and selected it for this task."
        } catch {
            workspaceGitStatus = error.localizedDescription
        }
    }

    /// The same evidence-corrected review the engine drafts and sends from.
    private var assessment: ClickyTaskAssessment? {
        guard let details, let definition else { return nil }
        return monitor.engineAssessment(details, definition: definition)
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
    private var hasConfirmedWorkspace: Bool {
        task.projectAssigned && task.project.directoryPath != nil
    }

    private func workflowBinding<Value>(_ keyPath: WritableKeyPath<TaskPlan, Value>) -> Binding<Value> {
        Binding(
            get: { store.config.taskPlans[task.id, default: TaskPlan()][keyPath: keyPath] },
            set: { store.config.taskPlans[task.id, default: TaskPlan()][keyPath: keyPath] = $0 }
        )
    }

    private var workflowPlanBinding: Binding<TaskPlan> {
        Binding(
            get: { store.config.taskPlans[task.id] ?? TaskPlan() },
            set: { store.config.taskPlans[task.id] = $0 }
        )
    }
    private var draftGate: TaskDraftGate {
        guard let details else { return .latestReportUnavailable }
        return TaskDraftGate.evaluate(
            task: details,
            definition: definition,
            assessment: assessment,
            finished: false,
            ambiguous: ClickyTaskLibrary.ambiguousNames(tasks.tasks).contains(Matcher.normalize(details.name))
        )
    }
    private var messagePolicyBlocker: String? {
        TaskWorkflow.messageBlocker(project: hasConfirmedWorkspace ? task.project : TaskProject(),
                                    plan: store.config.taskPlans[task.id] ?? TaskPlan())
    }
    private var canDraftBump: Bool { draftGate == .ready && messagePolicyBlocker == nil }
    private var previewKey: String {
        let plan = store.config.taskPlans[task.id] ?? TaskPlan()
        return [task.id, details?.fingerprint ?? "", definition ?? "",
                TaskWorkflow.finishRequestKey(project: task.project, plan: plan, definition: definition)].joined(separator: "\u{1F}")
    }
    private var canShowTaskInHeyClicky: Bool {
        details != nil && details?.dismissed != true
    }

    /// Shows the engine's cached draft for the current review. The engine examines every task in the background and,
    /// for auto-bump tasks, sends this same draft itself, so the panel never sends on its own.
    private func prepareCurrentPreview() async {
        guard definition != nil, canDraftBump, bumpDraftMessage == nil else { return }
        await createBumpDraft()
    }

    private func reviewLatestReport() async {
        guard definition != nil else { return }
        monitor.requestEngineExamination(ClickyMonitor.clickyKey(task.id))
        bumpDraftMessage = nil
        bumpDraftError = nil
        bumpSendStatus = "Queued for examination by local Ollama — the status card above shows progress."
    }

    private func createBumpDraft() async {
        guard let details, let definition, let reviewed = assessment, canDraftBump else {
            bumpDraftError = "Review the latest report first; drafting requires a current review with concrete gaps."
            return
        }
        let expectedFingerprint = details.fingerprint
        let expectedDefinition = definition
        let expectedWorkflowKey = previewKey
        draftingBump = true
        bumpDraftMessage = nil
        bumpDraftError = nil
        bumpSendStatus = nil
        defer { draftingBump = false }

        do {
            // Same text the engine caches and auto-sends, so what you see is exactly what goes out.
            try Task.checkCancellation()
            let draft = ChatBump.Draft(unfinished: true,
                message: monitor.heyClickyFollowUp(details, definition: expectedDefinition, missing: reviewed.missing, config: store.config))
            guard let latest = tasks.task(task.id), latest.fingerprint == expectedFingerprint,
                  DefinitionOfDone.normalized(store.config.clickyDefinitionsOfDone[task.id]) == expectedDefinition,
                  previewKey == expectedWorkflowKey,
                  monitor.engineAssessment(latest, definition: expectedDefinition) == reviewed,
                  !latest.isWorking, !monitor.stopHeld(latest), !latest.dismissed,
                  !TaskAudit.requiresUser(latest.lastMessage) else {
                bumpDraftError = "The task report or criteria changed while drafting. Review again before drafting."
                return
            }
            bumpDraftMessage = draft.message
            bumpDraftFingerprint = expectedFingerprint
            bumpDraftDefinition = expectedDefinition
            bumpDraftWorkflowKey = expectedWorkflowKey
            bumpDraftAssessment = reviewed
        } catch {
            bumpDraftError = error.localizedDescription
        }
    }


    private func sendBumpDraft() async {
        guard let message = bumpDraftMessage, let details, let definition, let reviewed = assessment,
              bumpDraftFingerprint == details.fingerprint, bumpDraftDefinition == definition,
              bumpDraftWorkflowKey == previewKey,
              bumpDraftAssessment == reviewed, canDraftBump else {
            bumpDraftMessage = nil
            bumpDraftError = "The draft is stale. Refreshing the current review and continuation."
            await prepareCurrentPreview()
            return
        }
        sendingBump = true
        bumpSendStatus = nil
        defer { sendingBump = false }
        let result = await monitor.sendReviewedTaskDraft(taskID: task.id, text: message,
                                                         definition: definition, reportFingerprint: details.fingerprint,
                                                         missing: reviewed.missing)
        if let result {
            bumpSendStatus = result
        } else {
            bumpSendStatus = "Sent and confirmed in HeyClicky."
            bumpDraftMessage = nil
        }
    }

    private func closeTask() async {
        guard !sendingLifecycleNotice else { return }
        sendingLifecycleNotice = true
        lifecycleNoticeStatus = "Finish requested: checking the current HeyClicky job before opening its sidebar…"
        defer { sendingLifecycleNotice = false }

        if let result = await monitor.closeHeyClickyTask(taskID: task.id) {
            lifecycleNoticeStatus = result
            return
        }
        lifecycleNoticeStatus = "Dismissed from HeyClicky's active tasks. History, caches and all project files are preserved."
    }

    private var lifecycleActions: some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox").foregroundStyle(.secondary)
            Text("HeyClicky task")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            if details == nil {
                Menu("Saved record") {
                    if task.localDisposition != nil {
                        Button("Restore to active history") {
                            monitor.manageSavedTask(task.id, disposition: nil)
                        }
                    }
                    Button("Archive locally") {
                        monitor.manageSavedTask(task.id, disposition: .archived)
                    }
                    Button("Mark finished locally") {
                        monitor.manageSavedTask(task.id, disposition: .finished)
                    }
                    Divider()
                    Button("Delete saved record…", role: .destructive) {
                        confirmingSavedRecordDeletion = true
                    }
                }
                .confirmationDialog("Delete this saved Cruise record?", isPresented: $confirmingSavedRecordDeletion) {
                    Button("Delete saved record", role: .destructive) {
                        monitor.manageSavedTask(task.id, disposition: nil, delete: true)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Removes only this unmatched entry from Cruise's catalog. HeyClicky history, reports, caches and project files are not deleted.")
                }
            } else if details?.dismissed == true {
                Text("Dismissed · history preserved").font(.caption).foregroundStyle(.secondary)
            } else {
                Button(sendingLifecycleNotice ? "Finishing…" : "Mark as Finished") { Task { await closeTask() } }
                    .buttonStyle(ClickyPillButtonStyle(primary: false))
                    .disabled(sendingLifecycleNotice)
                    .accessibilityIdentifier("close-task-\(task.id)")
            }
        }
        .padding(.top, 4)
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
                        if details?.dismissed == true {
                            Text("Dismissed in HeyClicky").font(.caption2).foregroundStyle(.secondary)
                        }
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
                    TaskMenuPill(title: priority.title, icon: "flag")
                }
                .help("Cruise review priority only; it does not change HeyClicky's queue.")
                .disabled(details == nil)

                Button(showingDetails ? "Hide details" : "Details") { showingDetails.toggle() }
                    .buttonStyle(TaskControlPillStyle(selected: showingDetails))
                    .accessibilityIdentifier("task-details-\(task.id)")
            }

            Label("Next: \(nextAction)", systemImage: "arrow.turn.down.right")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("task-next-action-\(task.id)")

            if details == nil {
                Text("This saved record is not matched to a current HeyClicky job.")
                    .font(.caption).foregroundStyle(.secondary)
                if let disposition = task.localDisposition {
                    Text(disposition == .archived ? "Archived locally · restore from Saved record." : "Finished locally · not a verified agent completion.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Archive or finish locally to move it to Closed. No agent action is performed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let details {
                TaskFolderStep(confirmed: hasConfirmedWorkspace ? task.project.directoryPath : nil,
                               suggested: suggestedFolder, flow: flow, identifier: "choose-folder-\(task.id)",
                               useSuggestion: { assign(task.project) },
                               choose: { choosingFolder = true })
                TaskDoneCriteriaControl(definition: definition, identifier: "define-done-\(task.id)", flow: flow) {
                    definitionDraft = store.config.clickyDefinitionsOfDone[task.id] ?? ""
                    definingDone = true
                }
                if hasConfirmedWorkspace {
                    DoneWorkflowPolicyEditor(
                        plan: workflowPlanBinding, confirmedWorkspace: hasConfirmedWorkspace,
                        branches: workspaceBranches, newBranchName: $newBranchName,
                        branchStatus: workspaceGitStatus, onCreateBranch: createWorkspaceBranch)
                }
                latestResponseCard(details)
                TaskEngineStatusCard(record: monitor.engine.records[ClickyMonitor.clickyKey(task.id)],
                                     activity: monitor.engineActivity.flatMap { $0.key == ClickyMonitor.clickyKey(task.id) ? $0.text : nil },
                                     goThere: goThere)
                TaskFlowRow(step: .review, flow: flow) {
                    TaskFlowButton(title: monitor.engine.records[ClickyMonitor.clickyKey(task.id)]?.stage == .examining && monitor.engineActivity?.key == ClickyMonitor.clickyKey(task.id) ? "Examining…" : "Review latest response",
                                   systemImage: "text.magnifyingglass", step: .review, flow: flow,
                                   help: "Refreshes this HeyClicky task, then compares its newest response with your saved completion criteria.",
                                   identifier: "review-task-\(task.id)") {
                        Task { await reviewLatestReport() }
                    }
                    if reviewed {
                        Label("Gaps reviewed", systemImage: "checkmark.circle.fill")
                            .font(.caption2).foregroundStyle(Brand.periwinkle)
                    }
                }
                criteriaSummary(details)
                let progress = tasks.record(task.id).progress
                if let deliveredAt = progress.deliveredAt {
                    Label("Delivery confirmed in this HeyClicky task · \(deliveredAt.formatted(date: .abbreviated, time: .shortened))",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(Brand.periwinkle)
                } else if monitor.pendingMessage?.completionTarget?.taskID == task.id {
                    Text("Delivery pending: \(monitor.pendingMessage?.holdReason ?? "waiting for HeyClicky's receipt")")
                        .font(.caption2).foregroundStyle(Brand.youBadge)
                }
                HStack(spacing: 10) {
                    Toggle("Auto-bump this task", isOn: Binding(
                        get: { autoBumpEnabled },
                        set: { store.config.taskPlans[task.id, default: TaskPlan()].autoBump = $0 }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(autoBumpLockReason != nil && !autoBumpEnabled)
                    Spacer(minLength: 0)
                }
                .help(autoBumpLockReason ?? "Opt this task into automatic follow-ups when a fresh report falls short of its saved criteria.")
                Text(autoBumpLockReason.map { "Auto-bump locked: \($0)" }
                     ?? (autoBumpEnabled && store.config.mode != .rest
                     ? "Auto-bump is on: Cruise sends each draft as soon as it's ready, in Manual or Cruise mode. Anything holding it is shown above with a Go there fix."
                     : autoBumpEnabled
                        ? "Auto-bump is selected, but Rest mode pauses sending."
                        : "Cruise examines this task and keeps a draft ready in the background. Sending stays under your control."))
                    .font(.caption2).foregroundStyle(.secondary)
                TaskFlowRow(step: .draft, flow: flow) {
                    TaskFlowButton(title: draftingBump ? "Drafting…" : "Generate response", systemImage: "doc.text",
                                   step: .draft, flow: flow,
                                   help: "Drafts a follow-up for the gaps found in the review. Nothing is sent yet.",
                                   identifier: "draft-task-\(task.id)") {
                        Task { await createBumpDraft() }
                    }
                }
                if let bumpDraftMessage {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Draft · not sent", systemImage: "doc.text")
                            .font(.caption.weight(.semibold)).foregroundStyle(Brand.periwinkle)
                        Text(bumpDraftMessage).font(.caption).textSelection(.enabled)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.card.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                }
                TaskFlowRow(step: .send, flow: flow) {
                    TaskFlowButton(title: sendingBump ? "Sending…" : "Send to HeyClicky", systemImage: "paperplane.fill",
                                   step: .send, flow: flow,
                                   help: "Sends exactly the visible draft to this uniquely matched HeyClicky task after freshness and safety checks.",
                                   identifier: "bump-task-\(task.id)") {
                        Task { await sendBumpDraft() }
                    }
                    Button {
                        Task {
                            let result = await monitor.showTaskInHeyClicky(task.id)
                            if let result {
                                bumpSendStatus = result
                            }
                        }
                    } label: {
                        Label("Show in HeyClicky", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(ClickyPillButtonStyle(primary: false))
                    .disabled(!canShowTaskInHeyClicky)
                    .help(canShowTaskInHeyClicky ? "Opens this task in HeyClicky's expanded chat." : "This task is dismissed in HeyClicky.")
                    .accessibilityIdentifier("show-task-\(task.id)")
                }
                if let bumpDraftError {
                    Text("Workflow paused: \(bumpDraftError)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                } else if bumpDraftMessage == nil && !canDraftBump {
                    Text("Workflow paused: \(draftGate.message)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .accessibilityIdentifier("draft-gate-status-\(task.id)")
                }
                if let bumpSendStatus {
                    Text(bumpSendStatus).font(.caption).foregroundStyle(bumpSendStatus.hasPrefix("Sent") ? Brand.periwinkle : Brand.youBadge)
                        .textSelection(.enabled)
                }
            }

            lifecycleActions
            if let lifecycleNoticeStatus {
                Text(lifecycleNoticeStatus)
                    .font(.caption).foregroundStyle(lifecycleNoticeStatus.localizedCaseInsensitiveContains("not confirmed") ? Brand.youBadge : Brand.periwinkle)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("lifecycle-notice-status-\(task.id)")
            }

            if showingDetails {
                Divider()
                detailsPanel(details)
            }
        }
        .padding(.vertical, 8)
        .task(id: previewKey + (assessment == nil ? "" : "\u{1F}reviewed")) { await prepareCurrentPreview() }
        .environment(\.taskGoThere, goThere)
        .onReceive(NotificationCenter.default.publisher(for: ClickyMonitor.engineFixNotification)) { note in
            guard note.userInfo?["key"] as? String == ClickyMonitor.clickyKey(task.id),
                  let raw = note.userInfo?["fix"] as? String, let fix = TaskFix(rawValue: raw) else { return }
            goThere(fix)
        }
        .onAppear { showingDetails = initiallyExpanded }
        .onChange(of: task.id) { _, _ in
            showingDetails = initiallyExpanded
            bumpDraftMessage = nil
            bumpDraftError = nil
            bumpSendStatus = nil
        }
        .onChange(of: details?.fingerprint) { _, _ in
            bumpDraftMessage = nil
            bumpDraftError = nil
            bumpSendStatus = nil
        }
        .onChange(of: definition) { _, _ in
            bumpDraftMessage = nil
            bumpDraftError = nil
            bumpSendStatus = nil
        }
        .onAppear { refreshWorkspaceBranches() }
        .onChange(of: task.project.directoryPath) { _, _ in refreshWorkspaceBranches() }
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

                Text("Choosing a folder immediately saves it to this task as its confirmed workspace. Suggested folders still need an explicit Confirm task. Cruise will not move or edit files here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fileImporter(isPresented: $selectingWorkspace, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                        if case .success(let urls) = result, let url = urls.first {
                            projectDraft.directory = url.standardizedFileURL.path
                            if projectDraft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                projectDraft.name = task.project.name
                            }
                            assign(projectDraft)
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
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                chooseFolder(url.standardizedFileURL.path)
            }
        }
        .sheet(isPresented: $definingDone) {
            TaskDoneDefinitionEditor(
                taskName: task.name, agentName: "HeyClicky", definition: $definitionDraft,
                plan: workflowPlanBinding, confirmedWorkspace: hasConfirmedWorkspace,
                branches: workspaceBranches, newBranchName: $newBranchName,
                branchStatus: workspaceGitStatus, onCreateBranch: createWorkspaceBranch
            ) {
                store.config.clickyDefinitionsOfDone[task.id] = DefinitionOfDone.normalized(definitionDraft)
            }
        }
    }

    @ViewBuilder
    private func latestResponseCard(_ details: ClickyAgentTask) -> some View {
        if !details.lastMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            TaskLatestResponseCard(agentName: "HeyClicky", text: details.lastMessage,
                                   updatedAt: details.lastMessageAt ?? details.updatedAt)
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
                Text("Assessment: \(assessment.state.title) · \(assessment.reason)")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let question = assessment.clarificationQuestion {
                    Label("Please clarify Done: \(question)", systemImage: "person.fill.questionmark")
                        .font(.caption).foregroundStyle(Brand.youBadge)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Clarify Done…") {
                        definitionDraft = definition ?? ""
                        definingDone = true
                    }
                    .buttonStyle(ClickyPillButtonStyle(primary: false))
                    Text("Automatic and manual continuation are paused until you clarify the saved definition.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(Array(assessment.missing.prefix(6)), id: \.self) { gap in
                    Label(gap, systemImage: "arrow.turn.down.right")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let criteria = assessment.criteria {
                    ForEach(Array(criteria.enumerated()), id: \.offset) { _, criterion in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(criterion.status.rawValue.capitalized): \(criterion.criterion)")
                                .font(.caption2.weight(.semibold))
                            Text(criterion.evidence.isEmpty ? "No supporting evidence in the current report." : "Evidence: \(criterion.evidence)")
                                .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                if assessment.missing.count > 6 {
                    Text("And \(assessment.missing.count - 6) more gaps in Details.").font(.caption2).foregroundStyle(.secondary)
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
                    if assessment != nil {
                        Label("Review is current", systemImage: "checkmark.circle")
                            .font(.caption2).foregroundStyle(Brand.periwinkle)
                    }
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
                        TaskReportContent(text: String(details.lastMessage.prefix(6_000)))
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

struct TaskControlPillStyle: ButtonStyle {
    let selected: Bool
    @State private var hovering = false
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BrandFont.inter(9.5, .semibold))
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.82))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(selected ? Brand.navy : hovering ? Color.white.opacity(0.10) : Brand.card.opacity(0.7), in: Capsule())
            .overlay(Capsule().strokeBorder(isFocused ? Color.white.opacity(0.95) : selected ? Brand.periwinkle.opacity(0.7) : Color.white.opacity(hovering ? 0.16 : 0.08), lineWidth: isFocused ? 2 : 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .onHover { hovering = $0 }
            .contentShape(Capsule())
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct TaskMenuPill: View {
    let title: String
    let icon: String
    @State private var hovering = false
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(title).font(BrandFont.inter(9.5, .semibold)).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
        }
        .foregroundStyle(Color.white.opacity(0.88))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(hovering ? Color.white.opacity(0.10) : Brand.card.opacity(0.7), in: Capsule())
        .overlay(Capsule().strokeBorder(isFocused ? Color.white.opacity(0.95) : Color.white.opacity(hovering ? 0.18 : 0.09), lineWidth: isFocused ? 2 : 1))
        .contentShape(Capsule())
        .onHover { hovering = $0 }
    }
}
