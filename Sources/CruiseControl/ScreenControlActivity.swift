import Foundation

/// Announces UI mutations before they execute, including background Accessibility actions.
enum ScreenControlActivity {
    static let notification = Notification.Name("CruiseControl.screenControlActivity")
    private static let lock = NSLock()
    private static var enabled = false

    static func enable() {
        lock.lock()
        enabled = true
        lock.unlock()
    }

    static func announce(_ action: String) {
        lock.lock()
        let shouldAnnounce = enabled
        lock.unlock()
        guard shouldAnnounce else { return }
        let notify = {
            NotificationCenter.default.post(name: notification, object: action)
        }
        if Thread.isMainThread { notify() }
        else { DispatchQueue.main.sync(execute: notify) }
    }
}
