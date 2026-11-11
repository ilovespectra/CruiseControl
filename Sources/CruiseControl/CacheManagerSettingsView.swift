import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CruiseCore

enum HeyClickyStorageLocation {
    static func agentRoot(bundleIDs: [String]) throws -> URL {
        guard let app = bundleIDs.lazy.compactMap({
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first { !$0.isTerminated }
        }).first, let domain = app.bundleIdentifier else {
            throw NSError(domain: "CruiseControl.Storage", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Open HeyClicky so Cruise can read its configured Agent folder. No default folder was substituted.",
            ])
        }
        CFPreferencesAppSynchronize(domain as CFString)
        let saved = CFPreferencesCopyAppValue("userSelectedAgentWorkingDirectoryPath" as CFString, domain as CFString) as? String
        guard let root = ClickyTaskLibrary.configuredAgentRoot(saved) else {
            throw NSError(domain: "CruiseControl.Storage", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "HeyClicky's Agent folder preference is missing or invalid. Set it in Settings > Agents, then retry. No default folder was substituted.",
            ])
        }
        return root
    }
}

@MainActor
private final class CacheInventoryStore: ObservableObject {
    static let shared = CacheInventoryStore()

    @Published private(set) var report: CacheInventoryReport?
    @Published private(set) var partialReport: CacheInventoryReport?
    @Published private(set) var scanning = false
    @Published private(set) var scanPhase: String?
    @Published private(set) var scannedAt: Date?
    @Published private(set) var error: String?

    private var activeScanID: UUID?
    private var scanWork: Task<CacheInventoryReport, Never>?
    private let savedURL = ConfigStore.directory.appendingPathComponent("storage-inventory.json")
    private struct Saved: Codable {
        let report: CacheInventoryReport
        let scannedAt: Date
    }

    init() {
        guard FileManager.default.fileExists(atPath: savedURL.path) else { return }
        do {
            let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: savedURL))
            report = saved.report
            scannedAt = saved.scannedAt
        } catch {
            self.error = "Couldn't read previous storage results: \(error.localizedDescription). Scan again to measure current sizes."
        }
    }

    var displayedReport: CacheInventoryReport? { partialReport ?? report }
    var items: [CacheInventoryItem] {
        guard let partialReport else { return report?.items ?? [] }
        let previousIDs = Set(report?.items.map(\.id) ?? [])
        let currentIDs = Set(partialReport.items.filter { $0.bytes != nil }.map(\.id))
        return partialReport.items.filter { $0.bytes != nil || !previousIDs.contains($0.id) }
            + (report?.items.filter { !currentIDs.contains($0.id) }.map {
                CacheInventoryItem(kind: $0.kind, path: $0.path, taskIDs: $0.taskIDs, taskNames: $0.taskNames,
                                   bytes: $0.bytes, modifiedAt: $0.modifiedAt,
                                   error: "Previous scan; waiting for current measurement")
            } ?? [])
    }

    func update(_ progress: CacheInventoryScanProgress, for id: UUID) {
        guard activeScanID == id else { return }
        partialReport = progress.report
        scanPhase = "Reading \(progress.rootLabel) · \(progress.entriesVisited.formatted()) entries · partial sizes update live"
    }

    func beginScan() -> UUID? {
        guard !scanning else { return nil }
        let id = UUID()
        activeScanID = id
        scanning = true
        partialReport = nil
        scanPhase = "Refreshing task associations…"
        error = nil
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000_000)
            self?.timeOut(id)
        }
        return id
    }

    func isCurrent(_ id: UUID) -> Bool { activeScanID == id }

    func cancel() {
        guard let id = activeScanID else { return }
        fail("Scan cancelled. Partial measurements and previous completed sizes were kept.", for: id)
    }

    func setPhase(_ phase: String, for id: UUID, timeoutSeconds: UInt64? = nil,
                  timeoutMessage: String? = nil) {
        guard activeScanID == id else { return }
        scanPhase = phase
        if let timeoutSeconds, let timeoutMessage {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                guard let self, self.activeScanID == id, self.scanPhase == phase else { return }
                self.fail(timeoutMessage, for: id)
            }
        }
    }

    func attach(_ work: Task<CacheInventoryReport, Never>, to id: UUID) {
        guard activeScanID == id else { work.cancel(); return }
        scanWork = work
    }

    func finish(_ report: CacheInventoryReport, for id: UUID) {
        guard activeScanID == id else { return }
        if report.isPartial {
            partialReport = report
            fail("Scan ended with incomplete coverage. See the path errors below; measured lower bounds and the previous completed report were kept.", for: id)
            return
        }
        self.report = report
        partialReport = nil
        scannedAt = Date()
        error = nil
        scanPhase = nil
        scanning = false
        activeScanID = nil
        scanWork = nil
        do {
            try JSONEncoder().encode(Saved(report: report, scannedAt: scannedAt ?? Date()))
                .write(to: savedURL, options: .atomic)
        } catch {
            self.error = "Scan completed, but results couldn't be saved for next launch: \(error.localizedDescription)"
        }
    }

    func fail(_ message: String, for id: UUID) {
        guard activeScanID == id else { return }
        error = message
        scanPhase = nil
        scanning = false
        activeScanID = nil
        scanWork?.cancel()
        scanWork = nil
    }

    private func timeOut(_ id: UUID) {
        guard activeScanID == id else { return }
        let phase = scanPhase ?? "filesystem scan"
        if phase.contains("task associations") {
            fail("HeyClicky task refresh timed out. Previous storage results were kept; check that the task list is responsive, then retry.", for: id)
        } else {
            fail("Storage scan timed out after 15 minutes while \(phase). Measured partial sizes and previous completed results were kept; check that both configured roots are mounted and readable, then retry.", for: id)
        }
    }
}

struct CacheManagerSettingsView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var monitor: ClickyMonitor
    @ObservedObject private var tasks = ClickyTaskStore.shared
    @ObservedObject private var inventory = CacheInventoryStore.shared
    @State private var heyClickyAgentRoot: URL?
    @State private var sort: CacheInventorySort = .largest
    @State private var showing: CacheInventoryKind?
    @State private var search = ""

    private var visibleItems: [CacheInventoryItem] {
        CacheInventory.filteredAndSorted(inventory.items, kind: showing, query: search, sort: sort)
    }

    private func formattedTotal(_ bytes: Int64?, incomplete: Bool) -> String {
        guard let bytes else { return "Unavailable" }
        let measured = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        if incomplete && bytes == 0 { return "Partial" }
        return incomplete ? "≥ \(measured)" : measured
    }

    private func sizeLabel(_ bytes: Int64?) -> String {
        bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unavailable"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Storage").font(BrandFont.inter(22, .semibold))
                    Text("Full Clicky support and Agent-folder footprint, with task-linked caches available below.")
                        .font(BrandFont.inter(12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await refreshAndScan() }
                } label: {
                    Label(inventory.scanning ? "Scanning…" : "Scan now", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.royal)
                .disabled(inventory.scanning)
                if inventory.scanning {
                    Button("Cancel scan") { inventory.cancel() }
                        .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 10) {
                let report = inventory.displayedReport
                metric("CLICKY STORAGE FOOTPRINT",
                       formattedTotal(report?.clickyStorageApparentBytes, incomplete: report?.storageIsPartial ?? true),
                       detail: report.map {
                           "\(sizeLabel($0.clickyStorageAllocatedBytes)) allocated · \($0.storageRoots.filter { $0.error == nil }.count)/\($0.storageRoots.count) roots"
                       } ?? "Not measured yet",
                       icon: "externaldrive.badge.checkmark", accent: Brand.accent(for: .cruise))
                metric("TASK-LINKED CACHE",
                       formattedTotal(report.map { $0.taskCacheBytes }, incomplete: inventory.scanning || (report.map { $0.cacheIssueCount > 0 } ?? true)),
                       detail: report.map { "\($0.measuredCachePathCount) / \($0.expectedCachePathCount) paths · \($0.taskCount) tasks" } ?? "Not measured yet",
                       icon: "externaldrive.fill", accent: Brand.periwinkle)
                metric("WORKSPACE DATA",
                       formattedTotal(report.map { $0.workspaceBytes }, incomplete: inventory.scanning || (report.map { $0.workspaceIssueCount > 0 || $0.workspaceScopeIssue != nil } ?? true)),
                       detail: report.map { "\($0.measuredWorkspacePathCount) / \($0.expectedWorkspacePathCount) scoped paths" } ?? "Not measured yet",
                       icon: "folder.fill", accent: Brand.lavender)
                metric("OTHER / SUPPORT",
                       formattedTotal(report?.otherSupportBytes, incomplete: report?.storageIsPartial ?? true),
                       detail: "Non-task-linked support data",
                       icon: "archivebox", accent: Brand.periwinkle)
            }

            VStack(alignment: .leading, spacing: 9) {
                Label("Storage locations from HeyClicky", systemImage: "folder")
                    .font(BrandFont.inter(13, .semibold))
                Text("App support/cache: \(ClickyTaskLibrary.defaultRoot.path)\nAgent folder: \(heyClickyAgentRoot?.path ?? inventory.displayedReport?.storageRoots.first(where: { $0.label == "HeyClicky Agent folder" })?.path ?? "Not read from the running HeyClicky instance yet")")
                    .font(BrandFont.inter(10.5)).foregroundStyle(.secondary).textSelection(.enabled)
                Text("The Agent folder is read directly from the running HeyClicky instance’s Settings › Agents preference on every scan, never guessed or overridden in Cruise. Change it in HeyClicky, then Scan now. Root totals count apparent file bytes and allocated disk bytes separately; overlapping roots and resolved aliases count once in the headline.")
                    .font(BrandFont.inter(10.5)).foregroundStyle(.secondary)
                Text("Delete, move, edit, and automatic task-notice actions remain disabled.")
                    .font(BrandFont.inter(10.5, .semibold)).foregroundStyle(Brand.periwinkle)
                if let roots = inventory.displayedReport?.storageRoots {
                    ForEach(roots) { root in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: root.error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(root.error == nil ? Brand.accent(for: .cruise) : Brand.youBadge)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(root.label).font(BrandFont.inter(10, .semibold))
                                Text(root.path).font(BrandFont.mono(9)).textSelection(.enabled).lineLimit(1)
                                if let resolved = root.resolvedPath, resolved != root.path {
                                    Text("Resolved to \(resolved)").font(BrandFont.mono(8.5)).textSelection(.enabled).lineLimit(1)
                                }
                                if let error = root.error {
                                    Text("Coverage incomplete: \(error)").font(BrandFont.inter(9)).foregroundStyle(Brand.youBadge)
                                }
                            }
                            Spacer(minLength: 4)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(root.apparentBytes.map {
                                    let size = ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                                    return root.error == nil ? size : "≥ \(size)"
                                } ?? "Unavailable")
                                    .font(BrandFont.mono(9.5)).foregroundStyle(root.error == nil ? .white : Brand.youBadge)
                                Text("apparent · \(root.error == nil ? "" : "≥ ")\(sizeLabel(root.allocatedBytes)) allocated")
                                    .font(BrandFont.inter(8.5)).foregroundStyle(.tertiary)
                                Text("\(root.error == nil ? "" : "≥ ")\(root.fileCount) files")
                                    .font(BrandFont.inter(8.5)).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.top, 5)
                    }
                }
            }
            .padding(14)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: 14))

            HStack(spacing: 7) {
                filterChip("All paths", kind: nil)
                filterChip("Task caches", kind: .cache)
                filterChip("Workspaces", kind: .workspace)
                TextField("Filter paths or tasks", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .font(BrandFont.inter(10.5))
                    .frame(width: 190)
                if !search.isEmpty {
                    Button("Clear") { search = "" }.buttonStyle(.plain).foregroundStyle(Brand.periwinkle)
                }
                Spacer(minLength: 4)
                Picker("Sort", selection: $sort) {
                    ForEach(CacheInventorySort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                if inventory.scanning, let scannedAt = inventory.scannedAt {
                    Text("Refreshing · last completed \(scannedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(BrandFont.inter(10)).foregroundStyle(.tertiary)
                } else if let scannedAt = inventory.scannedAt {
                    Text("Last completed scan \(scannedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(BrandFont.inter(10)).foregroundStyle(.tertiary)
                } else if inventory.scanning {
                    Text("Live partial measurements").font(BrandFont.inter(10)).foregroundStyle(.tertiary)
                }
            }

            if inventory.scanning, let phase = inventory.scanPhase {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(phase)
                    if inventory.report != nil { Text("Unmeasured rows retain previous sizes.").foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                }
                .font(BrandFont.inter(10.5)).foregroundStyle(.secondary)
            }

            if let report = inventory.displayedReport {
                HStack(spacing: 7) {
                    Image(systemName: report.storageIsPartial ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(report.storageIsPartial ? Brand.youBadge : Brand.accent(for: .cruise))
                    Text(inventory.scanning ? "Scanning: sizes marked ≥ are measured so far, not final totals."
                         : report.storageIsPartial
                         ? "Clicky footprint is partial: inaccessible or unresolved roots are called out above; measured figures are lower bounds."
                         : "Both Clicky roots were scanned. Apparent and allocated sizes are separate; overlaps and resolved aliases count once in the headline.")
                    Spacer(minLength: 0)
                }
                .font(BrandFont.inter(10.5)).foregroundStyle(.secondary)
                Text("Task-linked paths: \(report.measuredCachePathCount)/\(report.expectedCachePathCount) measured; \(report.missingCachePathCount) cache locations absent (normal if no local cache). Workspace rows: \(report.measuredWorkspacePathCount)/\(report.expectedWorkspacePathCount). Filtering does not change root totals.")
                    .font(BrandFont.inter(9.5)).foregroundStyle(.tertiary)
                if let scopeIssue = report.workspaceScopeIssue {
                    Text("Workspace row coverage issue: \(scopeIssue)").font(BrandFont.inter(9.5)).foregroundStyle(Brand.youBadge)
                }
            }

            if let error = inventory.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(BrandFont.inter(11)).foregroundStyle(Brand.youBadge)
            }
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(visibleItems) { item in
                        inventoryRow(item)
                    }
                    if visibleItems.isEmpty {
                        VStack(spacing: 8) {
                            if inventory.scanning {
                                ProgressView().controlSize(.small)
                                Text(inventory.scanPhase ?? "Scanning configured Clicky storage…")
                                    .font(BrandFont.inter(14, .semibold))
                            } else {
                                Image(systemName: inventory.report == nil ? "externaldrive.badge.questionmark" : "checkmark.circle")
                                    .font(.title2).foregroundStyle(Brand.periwinkle)
                                Text(inventory.report == nil ? "No successful scan yet" : "No task-associated paths match this view")
                                    .font(BrandFont.inter(14, .semibold))
                            }
                            Text(inventory.error ?? "Cruise lists task-associated detail rows separately from full Clicky root totals; it never sweeps unrelated paths.")
                                .font(BrandFont.inter(11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(32)
                        .background(Brand.card, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
        .padding(8)
        .task {
            if inventory.scannedAt == nil { await refreshAndScan() }
        }
    }

    private func metric(_ title: String, _ value: String, detail: String, icon: String, accent: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(accent).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(BrandFont.inter(9, .semibold)).tracking(0.6).foregroundStyle(.secondary)
                Text(value).font(BrandFont.inter(17, .semibold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.65)
                Text(detail).font(BrandFont.inter(8.5)).foregroundStyle(.tertiary).lineLimit(1).minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private func filterChip(_ title: String, kind: CacheInventoryKind?) -> some View {
        let active = showing == kind
        return Button { showing = kind } label: {
            Text(title).font(BrandFont.inter(10.5, .semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(active ? Brand.navy : Brand.card, in: Capsule())
                .overlay(Capsule().strokeBorder(active ? Brand.periwinkle.opacity(0.7) : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private func inventoryRow(_ item: CacheInventoryItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind == .cache ? "doc.zipper" : "folder.fill")
                .foregroundStyle(item.kind == .cache ? Brand.periwinkle : Brand.accent(for: .cruise))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(URL(fileURLWithPath: item.path).lastPathComponent)
                        .font(BrandFont.inter(12, .semibold)).lineLimit(1)
                    Text(item.kind.rawValue.uppercased()).font(BrandFont.inter(8, .bold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Brand.navy, in: Capsule())
                    Spacer()
                    Text(item.bytes.map {
                        let size = ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                        return item.error == nil ? "\(size) apparent" : "≥ \(size) apparent"
                    } ?? "Unknown size")
                        .font(BrandFont.mono(10)).foregroundStyle(item.error == nil ? .white : Brand.youBadge)
                }
                Text(item.path).font(BrandFont.mono(9.5)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.taskNames.isEmpty ? "Task association unknown" : item.taskNames.joined(separator: ", "))
                        .lineLimit(1).help(item.taskIDs.joined(separator: ", "))
                    if let date = item.modifiedAt {
                        Text("· changed \(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date()))")
                            .help(date.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let error = item.error {
                        Text("· \(item.bytes == nil ? "unavailable" : "partial"): \(error)").foregroundStyle(Brand.youBadge)
                    }
                }
                .font(BrandFont.inter(9.5)).foregroundStyle(.secondary)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show in Finder")
            .help("Show this path in Finder")
            .disabled(item.error == "Path does not exist")
        }
        .padding(11)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("storage-path-\(item.id)")
    }

    private func refreshAndScan() async {
        guard let scanID = inventory.beginScan() else { return }
        let agentRoot: URL
        do {
            agentRoot = try HeyClickyStorageLocation.agentRoot(bundleIDs: store.config.clickyBundleIDs)
            heyClickyAgentRoot = agentRoot
        } catch {
            inventory.fail(error.localizedDescription, for: scanID)
            return
        }
        let heyClickyAgentRoot = agentRoot
        inventory.setPhase("Refreshing HeyClicky task associations…", for: scanID, timeoutSeconds: 90,
                           timeoutMessage: "HeyClicky task refresh did not finish within 90 seconds. Previous storage results were kept; check the task store, then retry.")
        let storageTasks: [ClickyAgentTask]
        do {
            storageTasks = try await Task.detached(priority: .userInitiated) {
                try ClickyTaskLibrary.tasks(jobs: ClickyTaskLibrary.decodeJobs(ClickyTaskStore.readJobsData()), activity: [:])
            }.value
        } catch {
            inventory.fail("Could not read HeyClicky task associations: \(error.localizedDescription). Previous storage results were kept.", for: scanID)
            return
        }
        guard inventory.isCurrent(scanID) else { return }
        if let error = monitor.taskCatalogError {
            inventory.fail("Could not refresh the saved task catalog. Previous storage results were kept. \(error)", for: scanID)
            return
        }

        var sources = CacheInventory.sources(tasks: storageTasks, catalog: monitor.taskCatalog,
                                             cacheRoot: ClickyTaskLibrary.defaultRoot, workspaceRoot: heyClickyAgentRoot)
        sources.append(CacheInventorySource(kind: .workspace, path: heyClickyAgentRoot.path,
                                            taskName: "HeyClicky Agent workspaces", includeMissing: true))
        let projects = ClickyTaskLibrary.defaultRoot.appendingPathComponent("projects")
        if FileManager.default.fileExists(atPath: projects.path) {
            sources.append(CacheInventorySource(kind: .workspace, path: projects.path, taskName: "HeyClicky projects"))
        }
        var isDirectory: ObjCBool = false
        let scopeIssue: String? = FileManager.default.fileExists(atPath: heyClickyAgentRoot.path, isDirectory: &isDirectory)
            && isDirectory.boolValue ? nil : "Workspace scan folder is missing or is not a folder"
        let roots = [
            CacheInventoryRoot(label: "Clicky support / cache", path: ClickyTaskLibrary.defaultRoot.path),
            CacheInventoryRoot(label: "HeyClicky Agent folder", path: heyClickyAgentRoot.path),
        ]
        inventory.setPhase("Measuring Clicky support and Agent folder…", for: scanID)
        let taskCount = storageTasks.count
        let inventoryStore = inventory
        let progressHandler: @Sendable (CacheInventoryScanProgress) -> Void = { progress in
            Task { @MainActor in inventoryStore.update(progress, for: scanID) }
        }
        let work = Task.detached(priority: .utility) {
            CacheInventory.scanReport(sources: sources, taskCount: taskCount,
                                      workspaceScopeIssue: scopeIssue, storageRoots: roots,
                                      progress: progressHandler)
        }
        inventory.attach(work, to: scanID)
        let scanned = await work.value
        guard inventory.isCurrent(scanID) else { return }
        inventory.finish(scanned, for: scanID)
    }
}
