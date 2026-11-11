import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ConfigStore!
    private var monitor: ClickyMonitor!
    private var ollama: OllamaSetupController!
    private var notch: NotchController!
    private var indicator: CruiseIndicatorController!
    private var audioVolumeController: AudioVolumeController!
    private var settings: SettingsController!

    func applicationDidFinishLaunching(_ notification: Notification) {
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
                    NSApp.terminate(nil)
                    return
                }
            }
        }

        store = ConfigStore()
        BrandFont.register()
        monitor = ClickyMonitor(store: store)
        ollama = OllamaSetupController(store: store)
        notch = NotchController(store: store, monitor: monitor, ollama: ollama)
        indicator = CruiseIndicatorController(store: store)
        audioVolumeController = AudioVolumeController()
        settings = SettingsController(store: store, monitor: monitor, ollama: ollama,
                                      audio: audioVolumeController)
        monitor.setOverlayHidden = { [weak notch] hidden in notch?.setHidden(hidden) }
        monitor.start()
        AppUpdates.shared.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return false
    }
}
