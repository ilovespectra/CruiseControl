import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsController: NSObject, NSToolbarDelegate {
    static let openNotification = Notification.Name("CruiseControl.openSettings")
    static let openOllamaNotification = Notification.Name("CruiseControl.openOllamaSettings")
    static let focusOllamaSettingsNotification = Notification.Name("CruiseControl.focusOllamaSettings")
    static let openTasksNotification = Notification.Name("CruiseControl.openTasksSettings")
    static let focusTasksNotification = Notification.Name("CruiseControl.focusTasksSettings")
    private static let audioToolbarItemID = NSToolbarItem.Identifier("CruiseControl.audioControls")

    private let store: ConfigStore
    private let monitor: ClickyMonitor
    private let ollama: OllamaSetupController
    private let audio: AudioVolumeController?
    private var window: NSWindow!
    private var dashboardContentView: NSView!
    private var isShowingAudio = false
    private var cancellables: Set<AnyCancellable> = []

    init(store: ConfigStore, monitor: ClickyMonitor, ollama: OllamaSetupController,
         audio: AudioVolumeController?) {
        self.store = store
        self.monitor = monitor
        self.ollama = ollama
        self.audio = audio
        super.init()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Cruise Control Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 660, height: 580)
        dashboardContentView = NSHostingView(rootView: SettingsContent(store: store, monitor: monitor, ollama: ollama))
        window.contentView = dashboardContentView
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("CruiseControl.settingsToolbar"))
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        if audio != nil { window.toolbar = toolbar }
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
        if isShowingAudio {
            isShowingAudio = false
            window.contentView = dashboardContentView
            window.title = "Cruise Control Settings"
            window.minSize = NSSize(width: 660, height: 580)
            updateAudioToolbarItem()
        }
        store.reloadFromDisk()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.audioToolbarItemID]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.audioToolbarItemID]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.audioToolbarItemID else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Audio controls"
        item.paletteLabel = "Audio controls"
        item.toolTip = "Open independent HeyClicky and VS Code volume controls"
        item.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "Audio controls")
        item.target = self
        item.action = #selector(toggleAudioControls)
        return item
    }

    @objc private func toggleAudioControls() {
        guard let audio else { return }
        guard isShowingAudio else {
            isShowingAudio = true
            window.contentView = NSHostingView(rootView: AudioVolumeSettingsView(controller: audio))
            window.title = "Cruise Control · Audio controls"
            window.minSize = NSSize(width: 760, height: 540)
            updateAudioToolbarItem()
            store.reloadFromDisk()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        show()
    }

    private func updateAudioToolbarItem() {
        guard let item = window.toolbar?.items.first(where: { $0.itemIdentifier == Self.audioToolbarItemID }) else { return }
        item.label = isShowingAudio ? "Settings" : "Audio controls"
        item.paletteLabel = item.label
        item.toolTip = isShowingAudio ? "Back to Cruise Control settings" : "Open independent HeyClicky and VS Code volume controls"
        item.image = NSImage(systemSymbolName: isShowingAudio ? "gearshape" : "speaker.wave.2",
                              accessibilityDescription: item.label)
    }
}
