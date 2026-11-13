import AppKit

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

    @MainActor
    static func quit() {
        guard isManagedByLaunchd else {
            NSApp.terminate(nil)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let alert = NSAlert()
                alert.messageText = "Could not stop automatic restart"
                alert.informativeText = "Cruise Control remains running. launchctl exited with status \(process.terminationStatus)."
                alert.runModal()
                return
            }
            NSApp.terminate(nil)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    /// Posted by the dropdown's "hide" button; the pill returns the next time HeyClicky launches.
    static let hideNotification = Notification.Name("CruiseControlHideUntilClickyRelaunch")

    /// Sent (cross-process) when the app is opened again from Finder/Spotlight while already running.
    static let showNotification = Notification.Name("com.ilovespectra.cruisecontrol.show")
}
