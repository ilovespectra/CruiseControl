import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CruiseCore

@MainActor
private final class CacheInventoryStore: ObservableObject {
    @Published private(set) var items: [CacheInventoryItem] = []
    @Published private(set) var scanning = false
    @Published private(set) var scannedAt: Date?
    @Published private(set) var error: String?

    var totalCacheBytes: Int64 { CacheInventory.totalCacheBytes(in: items) }
    var unknownCacheCount: Int { CacheInventory.unknownCacheCount(in: items) }

    func scan(tasks: [ClickyAgentTask], catalog: TaskCatalog, root: URL) async {
        guard !scanning else { return }
        scanning = true
        error = nil
        defer { scanning = false }
        let sources = CacheInventory.sources(tasks: tasks, catalog: catalog, root: root)
        let scanned = await Task.detached(priority: .utility) {
            CacheInventory.scan(sources: sources)
        }.value
        items = scanned
        scannedAt = Date()
    }
}

struct CacheManagerSettingsView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var monitor: ClickyMonitor
    @ObservedObject private var tasks = ClickyTaskStore.shared
    @StateObject private var inventory = CacheInventoryStore()
    @State private var choosingRoot = false
    @State private var rootDraft = ""
    @State private var sort: CacheInventorySort = .largest
    @State private var showing: CacheInventoryKind?
    @State private var search = ""

    private var selectedRoot: URL {
        let raw = store.config.clickyCacheInventoryLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: (raw.isEmpty ? ClickyTaskLibrary.defaultRoot.path : (raw as NSString).expandingTildeInPath))
            .standardizedFileURL
    }

    private var visibleItems: [CacheInventoryItem] {
        CacheInventory.filteredAndSorted(inventory.items, kind: showing, query: search, sort: sort)
    }

    private var cacheTotalLabel: String {
        let measured = ByteCountFormatter.string(fromByteCount: inventory.totalCacheBytes, countStyle: .file)
        return inventory.unknownCacheCount == 0 ? measured : "\(measured) + \(inventory.unknownCacheCount) unknown"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Storage").font(BrandFont.inter(22, .semibold))
                    Text("A read-only map of task caches and working folders used by local HeyClicky jobs.")
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
                .disabled(inventory.scanning || tasks.loading)
            }

            HStack(spacing: 10) {
                metric("MEASURED TASK CACHE", cacheTotalLabel,
                       icon: "externaldrive.fill", accent: Brand.periwinkle)
                metric("TASKS MAPPED", "\(tasks.tasks.count)", icon: "checklist", accent: Brand.accent(for: .cruise))
                metric("WORKSPACE PATHS", "\(inventory.items.filter { $0.kind == .workspace }.count)",
                       icon: "folder.fill", accent: Brand.lavender)
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label("Cache inventory location", systemImage: "externaldrive")
                        .font(BrandFont.inter(13, .semibold))
                    Spacer()
                    Button("Use HeyClicky default") { setRoot("") }
                        .buttonStyle(.plain).foregroundStyle(Brand.periwinkle)
                        .disabled(store.config.clickyCacheInventoryLocation.isEmpty)
                }
                HStack(spacing: 8) {
                    TextField("Cache root folder", text: $rootDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(BrandFont.mono(10))
                        .onSubmit { setRoot(rootDraft) }
                    Button("Set") { setRoot(rootDraft) }
                    Button("Choose…") { choosingRoot = true }
                }
                Text("Default: ~/Library/Application Support/Clicky. Changing this field changes Cruise’s scan scope only; it does not move files or modify HeyClicky’s own storage settings.")
                    .font(BrandFont.inter(10.5)).foregroundStyle(.secondary)
                Text("Cruise has no supported HeyClicky API for relocating its live cache. Use HeyClicky’s own storage controls for that change; this view stays read-only.")
                    .font(BrandFont.inter(10.5)).foregroundStyle(.secondary)
                Text("Delete, move, edit, and automatic task-notice actions are disabled. Any future change must be itemized, approved, and verified.")
                    .font(BrandFont.inter(10.5, .semibold)).foregroundStyle(Brand.periwinkle)
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
                if let scannedAt = inventory.scannedAt {
                    Text("Updated \(scannedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(BrandFont.inter(10)).foregroundStyle(.tertiary)
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
                            Image(systemName: inventory.scannedAt == nil ? "externaldrive.badge.questionmark" : "checkmark.circle")
                                .font(.title2).foregroundStyle(Brand.periwinkle)
                            Text(inventory.scannedAt == nil ? "Scan to see task storage" : "No matching folders found")
                                .font(BrandFont.inter(14, .semibold))
                            Text("Cruise only lists paths associated with current or saved tasks; it never sweeps unrelated files.")
                                .font(BrandFont.inter(11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(32)
                        .background(Brand.card, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
        .padding(8)
        .fileImporter(isPresented: $choosingRoot, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                setRoot(url.standardizedFileURL.path)
            }
        }
        .task {
            rootDraft = selectedRoot.path
            if inventory.scannedAt == nil { await refreshAndScan() }
        }
    }

    private func metric(_ title: String, _ value: String, icon: String, accent: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(accent).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(BrandFont.inter(9, .semibold)).tracking(0.6).foregroundStyle(.secondary)
                Text(value).font(BrandFont.inter(17, .semibold)).foregroundStyle(.white)
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
                    Text(item.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown size")
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
                    if let error = item.error { Text("· \(error)").foregroundStyle(Brand.youBadge) }
                }
                .font(BrandFont.inter(9.5)).foregroundStyle(.secondary)
            }
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: item.path)) } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.plain).help("Reveal path in Finder")
            .disabled(item.error != nil)
        }
        .padding(11)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("storage-path-\(item.id)")
    }

    private func setRoot(_ path: String) {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (value as NSString).expandingTildeInPath
        guard value.isEmpty || expanded.hasPrefix("/") else { return }
        store.config.clickyCacheInventoryLocation = expanded == ClickyTaskLibrary.defaultRoot.path ? "" : expanded
        rootDraft = selectedRoot.path
        Task { await refreshAndScan() }
    }

    private func refreshAndScan() async {
        await tasks.refresh()
        await monitor.refreshTaskCatalog()
        await inventory.scan(tasks: tasks.tasks, catalog: monitor.taskCatalog, root: selectedRoot)
    }
}
