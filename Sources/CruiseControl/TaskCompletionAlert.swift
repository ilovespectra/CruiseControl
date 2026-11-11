import AppKit
import Combine
import CruiseCore
import SwiftUI

@MainActor
final class TaskCompletionAlertController {
    private let tasks = ClickyTaskStore.shared
    private let panel: NSPanel
    private var cancellables: Set<AnyCancellable> = []

    init() {
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
                self?.update(notices.first)
            }
            .store(in: &cancellables)
    }

    private func update(_ notice: TaskCompletionNotice?) {
        guard let notice, let screen = NSScreen.main else {
            panel.orderOut(nil)
            return
        }
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: visible.maxX - 418, y: visible.minY + 28, width: 400, height: 164), display: true)
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
                 : "Cruise reviewed the new report: it is still short of your Done definition. \(notice.reviewSummary ?? "")")
                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            HStack {
                Button("Review task") { action(true) }
                Spacer()
                Button("Dismiss") { action(false) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .preferredColorScheme(.dark)
    }
}
