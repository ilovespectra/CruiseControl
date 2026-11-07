import AppKit
import Combine
import SwiftUI
import CruiseCore

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the borderless panel that sits beside the notch and grows into the dropdown.
/// The panel is only shown while HeyClicky is running (unless `showOnlyWithClicky` is off).
@MainActor
final class NotchController {
    private let panel: NotchPanel
    private let host: NSHostingView<NotchRootView>
    private let store: ConfigStore
    private let monitor: ClickyMonitor
    private var outsideClickMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    private var expanded = false
    private var hiddenForClick = false
    private var hiddenByUser = false
    private var menuBarHeight: CGFloat = 32

    private let pillWidth: CGFloat = 128
    private let expandedWidth: CGFloat = 330

    init(store: ConfigStore, monitor: ClickyMonitor) {
        self.store = store
        self.monitor = monitor
        panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        host = NSHostingView(rootView: NotchRootView(store: store, monitor: monitor, expanded: false, menuBarHeight: 32, side: .right, toggle: {}))
        host.sizingOptions = []
        panel.contentView = host

        layout()
        updateVisibility()

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.layout() }
            .store(in: &cancellables)
        store.$config
            .map { [$0.pillSide.rawValue, "\($0.showOnlyWithClicky)"] }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.layout()
                    self?.updateVisibility()
                }
            }
            .store(in: &cancellables)
        monitor.$clickyRunning
            .removeDuplicates()
            .sink { [weak self] running in
                DispatchQueue.main.async {
                    if running { self?.hiddenByUser = false }
                    self?.updateVisibility()
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: LaunchAgent.hideNotification)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.hiddenByUser = true
                    self?.updateVisibility()
                }
            }
            .store(in: &cancellables)
        DistributedNotificationCenter.default().publisher(for: LaunchAgent.showNotification)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.hiddenByUser = false
                    self?.updateVisibility()
                }
            }
            .store(in: &cancellables)
        // Dropdown height depends on permission rows / log lines.
        monitor.objectWillChange
            .merge(with: store.objectWillChange)
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.expanded else { return }
                self.layout()
            }
            .store(in: &cancellables)
    }

    /// Temporarily hides the panel so synthetic clicks can't land on it.
    func setHidden(_ hidden: Bool) {
        hiddenForClick = hidden
        updateVisibility()
    }

    private var shouldShow: Bool {
        !hiddenForClick && !hiddenByUser && (monitor.clickyRunning || !store.config.showOnlyWithClicky)
    }

    private func updateVisibility() {
        if shouldShow {
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else {
            if expanded { setExpanded(false) }
            panel.orderOut(nil)
        }
    }

    func setExpanded(_ expanded: Bool) {
        if expanded { store.reloadFromDisk() }
        self.expanded = expanded
        layout()
        if expanded {
            panel.orderFrontRegardless()
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.setExpanded(false) }
            }
        } else if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func layout() {
        guard let screen = targetScreen() else { return }
        let frame = screen.frame
        menuBarHeight = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness, frame.maxY - screen.visibleFrame.maxY)
        let side = store.config.pillSide

        // Reassigning rootView re-renders synchronously, so fittingSize below is accurate.
        host.rootView = NotchRootView(
            store: store,
            monitor: monitor,
            expanded: expanded,
            menuBarHeight: menuBarHeight,
            side: side,
            toggle: { [weak self] in
                guard let self else { return }
                self.setExpanded(!self.expanded)
            }
        )

        let pillX: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let notchMinX = frame.minX + left.width
            let notchMaxX = frame.maxX - right.width
            pillX = side == .right ? notchMaxX + 4 : notchMinX - 4 - pillWidth
        } else {
            pillX = frame.midX - pillWidth / 2
        }

        var size = CGSize(width: pillWidth, height: menuBarHeight)
        var x = pillX
        if expanded {
            // Measure the dropdown on its own; the hosted root fills whatever frame it's given.
            let measure = NSHostingView(rootView: ExpandedPanel(store: store, monitor: monitor, menuBarHeight: menuBarHeight, toggle: {})
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.colorScheme, .dark))
            let fitting = measure.fittingSize
            size = CGSize(width: expandedWidth, height: min(max(fitting.height, 120), frame.height - 40))
            x = side == .right ? pillX : pillX + pillWidth - size.width
        }
        x = min(max(x, frame.minX + 4), frame.maxX - size.width - 4)
        panel.setFrame(NSRect(x: x, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }
}
