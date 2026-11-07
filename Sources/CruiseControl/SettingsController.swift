import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsController {
    static let openNotification = Notification.Name("CruiseControl.openSettings")
    private let window: NSWindow
    private let store: ConfigStore
    private var cancellables: Set<AnyCancellable> = []

    init(store: ConfigStore, monitor: ClickyMonitor) {
        self.store = store
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 640),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Cruise Control Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 660, height: 580)
        window.contentView = NSHostingView(rootView: SettingsContent(store: store, monitor: monitor))
        window.center()
        NotificationCenter.default.publisher(for: Self.openNotification)
            .sink { [weak self] _ in self?.show() }
            .store(in: &cancellables)
        DistributedNotificationCenter.default().publisher(for: Self.openNotification)
            .sink { [weak self] _ in self?.show() }
            .store(in: &cancellables)
    }

    func show() {
        store.reloadFromDisk()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
