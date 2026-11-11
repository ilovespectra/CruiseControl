import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ConfigStore!
    private var monitor: ClickyMonitor!
    private var ollama: OllamaSetupController!
    private var notch: NotchController!
    private var indicator: CruiseIndicatorController!
    private var audioVolumeController: AudioVolumeController?
    private var settings: SettingsController!
    private var vscodeRequestAlerts: VSCodeRequestAlertController!
    private var drivingIndicator: CruiseDrivingController!
    private var taskCompletionAlerts: TaskCompletionAlertController!

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
        taskCompletionAlerts = TaskCompletionAlertController()
        vscodeRequestAlerts = VSCodeRequestAlertController(store: store, monitor: monitor)
        ollama = OllamaSetupController(store: store)
        notch = NotchController(store: store, monitor: monitor, ollama: ollama)
        indicator = CruiseIndicatorController(store: store)
        drivingIndicator = CruiseDrivingController(monitor: monitor)
        if Bundle.main.object(forInfoDictionaryKey: "CruiseControlAudioControlsEnabled") as? Bool != false {
            audioVolumeController = AudioVolumeController()
        }
        settings = SettingsController(store: store, monitor: monitor, ollama: ollama,
                                      audio: audioVolumeController)
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
}
