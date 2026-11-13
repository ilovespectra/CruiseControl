import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ConfigStore!
    private var monitor: ClickyMonitor!
    private var ollama: OllamaSetupController!
    private var notch: NotchController!
    private var indicator: CruiseIndicatorController!
    private var safetyGuide: SafetyRequestGuide!
    private var settings: SettingsController!
    private var vscodeRequestAlerts: VSCodeRequestAlertController!
    private var drivingIndicator: CruiseDrivingController!
    private var taskCompletionAlerts: TaskCompletionAlertController!
    private var pridePongWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Cruise Control")
        let playPongItem = NSMenuItem(title: "Play Pride Pong…", action: #selector(openPridePong), keyEquivalent: "")
        playPongItem.target = self
        appMenu.addItem(playPongItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Cruise Control", action: #selector(quitCruise), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
            ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
            ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a"),
        ] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        if let id = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .filter { $0.processIdentifier != getpid() && !$0.isTerminated }
            if !others.isEmpty {
                // launchd keeps its instance alive, so it wins; a manually opened copy steps aside.
                if LaunchAgent.isManagedByLaunchd {
                    others.forEach { $0.terminate() }
                } else {
                    DistributedNotificationCenter.default().postNotificationName(
                        LaunchAgent.showNotification, object: nil, userInfo: nil, deliverImmediately: true)
                    DistributedNotificationCenter.default().postNotificationName(
                        SettingsController.openNotification, object: nil, userInfo: nil, deliverImmediately: true)
                    NSApp.terminate(nil)
                    return
                }
            }
        }

        store = ConfigStore()
        BrandFont.register()
        monitor = ClickyMonitor(store: store)
        taskCompletionAlerts = TaskCompletionAlertController(store: store)
        vscodeRequestAlerts = VSCodeRequestAlertController(store: store, monitor: monitor)
        ollama = OllamaSetupController(store: store)
        notch = NotchController(store: store, monitor: monitor, ollama: ollama)
        indicator = CruiseIndicatorController(store: store)
        safetyGuide = SafetyRequestGuide(store: store, monitor: monitor)
        drivingIndicator = CruiseDrivingController(monitor: monitor)
        settings = SettingsController(store: store, monitor: monitor, ollama: ollama,
                                      audio: nil)
        monitor.setOverlayHidden = { [weak notch] hidden in notch?.setHidden(hidden) }
        monitor.start()
        AppUpdates.shared.start()
        if !LaunchAgent.isManagedByLaunchd { settings.show() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        notch.show()
        settings.show()
        return false
    }

    @objc private func openPridePong() {
        let window: NSWindow
        if let pridePongWindow {
            window = pridePongWindow
        } else {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
            created.title = "Pride Pong"
            created.minSize = NSSize(width: 760, height: 520)
            created.isReleasedWhenClosed = false
            created.contentView = NSHostingView(rootView: PridePongView())
            created.center()
            pridePongWindow = created
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func quitCruise() {
        LaunchAgent.quit()
    }
}
