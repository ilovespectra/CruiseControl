import AppKit
import CoreGraphics

/// Synthetic mouse/keyboard input (requires Accessibility permission).
enum InputSynth {
    private static let source = CGEventSource(stateID: .hidSystemState)

    final class ActionPermission: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var allowed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ allowed: Bool) {
            lock.lock()
            defer { lock.unlock() }
            value = allowed
        }
    }

    static func click(at point: CGPoint, restoreCursor: Bool = true) {
        _ = click(at: point, restoreCursor: restoreCursor, shouldContinue: { true })
    }

    static func click(at point: CGPoint, restoreCursor: Bool, shouldContinue: () -> Bool) -> Bool {
        guard shouldContinue() else { return false }
        let original = CGEvent(source: nil)?.location
        post(.mouseMoved, at: point)
        usleep(40_000)
        guard shouldContinue() else { return false }
        post(.leftMouseDown, at: point)
        usleep(50_000)
        post(.leftMouseUp, at: point)
        usleep(40_000)
        if restoreCursor, let original {
            post(.mouseMoved, at: original)
        }
        return true
    }

    @MainActor
    final class UserInteractionWatch {
        private final class Interruption: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false

            var interrupted: Bool {
                lock.lock()
                defer { lock.unlock() }
                return value
            }

            func interrupt() {
                lock.lock()
                defer { lock.unlock() }
                value = true
            }
        }

        private let interruption = Interruption()
        nonisolated var interrupted: Bool { interruption.interrupted }
        private var global: Any?
        private var local: Any?

        init(includeMouseMovement: Bool = true) {
            var mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                               .leftMouseDragged, .scrollWheel]
            if includeMouseMovement { mask.insert(.mouseMoved) }
            let interruption = interruption
            global = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
                guard event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else { return }
                interruption.interrupt()
            }
            local = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
                if event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) {
                    interruption.interrupt()
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
        CGWarpMouseCursorPosition(point)
        post(.mouseMoved, at: point)
    }

    static func scroll(at point: CGPoint, pixels: Int32) {
        let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                            wheel1: pixels, wheel2: 0, wheel3: 0)
        event?.location = point
        event?.post(tap: .cghidEventTap)
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
    private static let vscodeScanQueue = DispatchQueue(label: "cruisecontrol.vscode-scan", qos: .utility)

    static func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    static func scanVSCode<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            vscodeScanQueue.async { continuation.resume(returning: work()) }
        }
    }
}
