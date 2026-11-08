import AppKit
import CoreGraphics

/// Synthetic mouse/keyboard input (requires Accessibility permission).
enum InputSynth {
    private static let source = CGEventSource(stateID: .hidSystemState)

    static func click(at point: CGPoint, restoreCursor: Bool = true) {
        let original = CGEvent(source: nil)?.location
        post(.mouseMoved, at: point)
        usleep(40_000)
        post(.leftMouseDown, at: point)
        usleep(50_000)
        post(.leftMouseUp, at: point)
        usleep(40_000)
        if restoreCursor, let original {
            post(.mouseMoved, at: original)
        }
    }

    @MainActor
    final class UserInteractionWatch {
        private(set) var interrupted = false
        private var global: Any?
        private var local: Any?

        init() {
            let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                               .mouseMoved, .leftMouseDragged, .scrollWheel]
            global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                guard event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else { return }
                Task { @MainActor in self?.interrupted = true }
            }
            local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                if event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) {
                    self?.interrupted = true
                }
                return event
            }
        }

        func stop() {
            if let global { NSEvent.removeMonitor(global) }
            if let local { NSEvent.removeMonitor(local) }
            global = nil
            local = nil
        }
    }

    static func move(to point: CGPoint) {
        post(.mouseMoved, at: point)
    }

    static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        usleep(20_000)
        up?.post(tap: .cghidEventTap)
        usleep(30_000)
    }

    static let keyA: CGKeyCode = 0
    static let keyV: CGKeyCode = 9
    static let keyReturn: CGKeyCode = 36

    private static func post(_ type: CGEventType, at point: CGPoint) {
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
}

/// Runs blocking Accessibility / input work off the main thread.
enum Worker {
    static let queue = DispatchQueue(label: "cruisecontrol.worker", qos: .userInitiated)

    static func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
