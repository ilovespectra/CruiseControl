import AppKit
import Combine
import CruiseCore
import SwiftUI

@MainActor
final class TaskCompletionAlertController {
    private let tasks = ClickyTaskStore.shared
    private let store: ConfigStore
    private let panel: NSPanel
    private var cancellables: Set<AnyCancellable> = []

    init(store: ConfigStore) {
        self.store = store
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        tasks.$records
            .sink { [weak self] records in
                let notices = records.values.compactMap(\.completionNotice)
                    .filter { $0.acknowledgedAt == nil }
                    .sorted { $0.completedAt < $1.completedAt }
                guard let self else { return }
                // Short reports on Auto-bump tasks are Auto-bump's job, not a review prompt for the user.
                self.update(notices.first { $0.meetsDefinition == true || !self.autoBumpOn($0.taskID) })
            }
            .store(in: &cancellables)
    }

    private func autoBumpOn(_ taskID: String) -> Bool {
        let config = store.config
        return config.continueUntilDefinedDone && config.taskPlans[taskID]?.autoBump == true
            && DefinitionOfDone.normalized(config.clickyDefinitionsOfDone[taskID]) != nil
    }

    private func update(_ notice: TaskCompletionNotice?) {
        guard let notice, let screen = NSScreen.main else {
            panel.orderOut(nil)
            return
        }
        let visible = screen.visibleFrame
        // Stack the status light immediately below the notice so it never covers the notice's actions.
        let lightShown = store.config.mode != .manual
        let height: CGFloat = 200
        let y = visible.minY + 16 + (lightShown ? 96 : 0)
        panel.setFrame(NSRect(x: visible.maxX - 416, y: y, width: 400, height: height), display: true)
        panel.contentView = NSHostingView(rootView: TaskCompletionAlertView(notice: notice) { [weak self] open in
            guard let self else { return }
            guard self.tasks.acknowledgeCompletion(notice) else {
                NSLog("Cruise completion acknowledgement failed: %@", self.tasks.loadError ?? "saved notice changed")
                return
            }
            if open {
                self.tasks.requestedTaskID = notice.taskID
                NotificationCenter.default.post(name: SettingsController.openTasksNotification, object: nil)
            }
        })
        panel.orderFrontRegardless()
    }
}

private struct TaskCompletionAlertView: View {
    let notice: TaskCompletionNotice
    let action: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("CRUISE CONTROL · TASK STATE CHANGED", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption.bold()).foregroundStyle(Brand.periwinkle)
            Text(notice.taskName).font(.headline).lineLimit(1)
            Text(notice.meetsDefinition == true
                 ? "Cruise reviewed the new report and it appears to meet your Done definition. Only you can mark it finished."
                 : notice.autoBump == true
                    ? "Still short of your Done definition — Auto-bump is drafting the gap and sending it to HeyClicky. \(notice.reviewSummary ?? "")"
                    : "Still short of your Done definition. Open the task, choose Generate response, then Send to HeyClicky. \(notice.reviewSummary ?? "")")
                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            HStack {
                Button("Review task") { action(true) }
                Spacer()
                Button("Dismiss") { action(false) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .preferredColorScheme(.dark)
    }
}
