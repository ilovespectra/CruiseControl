import Foundation

enum LaunchAgent {
    static let label = "com.ilovespectra.cruisecontrol"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static var isManagedByLaunchd: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label
    }

    /// Posted by the dropdown's "hide" button; the pill returns the next time HeyClicky launches.
    static let hideNotification = Notification.Name("CruiseControlHideUntilClickyRelaunch")

    /// Sent (cross-process) when the app is opened again from Finder/Spotlight while already running.
    static let showNotification = Notification.Name("com.ilovespectra.cruisecontrol.show")
}
