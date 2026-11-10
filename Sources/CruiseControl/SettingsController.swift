import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsController {
    static let openNotification = Notification.Name("CruiseControl.openSettings")
    static let openOllamaNotification = Notification.Name("CruiseControl.openOllamaSettings")
    static let focusOllamaSettingsNotification = Notification.Name("CruiseControl.focusOllamaSettings")
    static let openTasksNotification = Notification.Name("CruiseControl.openTasksSettings")
    static let focusTasksNotification = Notification.Name("CruiseControl.focusTasksSettings")
    private let window: NSWindow
    private let store: ConfigStore
    private var cancellables: Set<AnyCancellable> = []

    init(store: ConfigStore, monitor: ClickyMonitor, ollama: OllamaSetupController) {
        self.store = store
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 640),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Cruise Control Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 660, height: 580)
        window.contentView = NSHostingView(rootView: SettingsContent(store: store, monitor: monitor, ollama: ollama))
        window.center()
        NotificationCenter.default.publisher(for: Self.openNotification)
            .sink { [weak self] _ in self?.show() }
            .store(in: &cancellables)
        DistributedNotificationCenter.default().publisher(for: Self.openNotification)
            .sink { [weak self] _ in self?.show() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: Self.openOllamaNotification)
            .sink { [weak self] _ in self?.showOllamaSettings() }
            .store(in: &cancellables)
        DistributedNotificationCenter.default().publisher(for: Self.openOllamaNotification)
            .sink { [weak self] _ in self?.showOllamaSettings() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: Self.openTasksNotification)
            .sink { [weak self] _ in self?.showTasksSettings() }
            .store(in: &cancellables)
        DistributedNotificationCenter.default().publisher(for: Self.openTasksNotification)
            .sink { [weak self] _ in self?.showTasksSettings() }
            .store(in: &cancellables)
    }

    private func showOllamaSettings() {
        show()
        NotificationCenter.default.post(name: Self.focusOllamaSettingsNotification, object: nil)
    }

    private func showTasksSettings() {
        show()
        NotificationCenter.default.post(name: Self.focusTasksNotification, object: nil)
    }

    func show() {
        store.reloadFromDisk()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
