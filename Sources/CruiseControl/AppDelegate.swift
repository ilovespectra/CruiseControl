import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ConfigStore!
    private var monitor: ClickyMonitor!
    private var notch: NotchController!
    private var indicator: CruiseIndicatorController!

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
        notch = NotchController(store: store, monitor: monitor)
        indicator = CruiseIndicatorController(store: store)
        monitor.setOverlayHidden = { [weak notch] hidden in notch?.setHidden(hidden) }
        monitor.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DistributedNotificationCenter.default().postNotificationName(
            LaunchAgent.showNotification, object: nil, userInfo: nil, deliverImmediately: true)
        return false
    }
}
