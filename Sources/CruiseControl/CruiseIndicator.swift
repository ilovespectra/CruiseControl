import AppKit
import Combine
import SwiftUI
import CruiseCore

private final class CruiseIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CruiseDrivingController {
    private var taskName: String?
    private var inputAction: String?
    private var hideWork: DispatchWorkItem?
    private var visibilityGeneration = 0
    private var panels: [NSPanel] = []
    private var cancellables: Set<AnyCancellable> = []

    init(monitor: ClickyMonitor) {
        taskName = monitor.drivingTaskName
        rebuildPanels()
        NotificationCenter.default.publisher(for: ScreenControlActivity.notification)
            .sink { [weak self] notification in
                guard let self, let action = notification.object as? String else { return }
                self.hideWork?.cancel()
                let changed = self.inputAction != action
                self.inputAction = action
                if changed { self.update() }
                let work = DispatchWorkItem { [weak self] in
                    self?.inputAction = nil
                    self?.update()
                }
                self.hideWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
            }
            .store(in: &cancellables)
        ScreenControlActivity.enable()
        monitor.$drivingTaskName.combineLatest(monitor.$preparingFinish)
            .sink { [weak self] task, preparing in
                self?.taskName = preparing ? nil : task
                self?.update()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.rebuildPanels() }
            .store(in: &cancellables)
    }

    private func rebuildPanels() {
        panels.forEach { $0.orderOut(nil) }
        panels = NSScreen.screens.map { screen in
            let panel = CruiseIndicatorPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                             backing: .buffered, defer: false)
            panel.title = "Cruise Control is controlling the screen"
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 3)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            return panel
        }
        update()
    }

    private func update() {
        visibilityGeneration += 1
        let generation = visibilityGeneration
        for panel in panels {
            guard let task = taskName.map({ "HeyClicky: \($0)" }) ?? inputAction else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.7
                    panel.animator().alphaValue = 0
                } completionHandler: { [weak self, weak panel] in
                    guard self?.visibilityGeneration == generation else { return }
                    panel?.orderOut(nil)
                }
                continue
            }
            let host = NSHostingView(rootView: CruiseDrivingView(task: task))
            host.sizingOptions = []
            panel.contentView = host
            let wasVisible = panel.isVisible
            if !wasVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            panel.displayIfNeeded()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.7
                panel.animator().alphaValue = 1
            }
        }
    }
}

private struct CruiseDrivingView: View {
    let task: String

    private var title: String {
        let app = task.contains("VS Code") ? "VS Code" : task.contains("HeyClicky") ? "HeyClicky" : "app controls"
        return task.hasPrefix("Preparing") ? "Cruise preparing · \(app)" : "Cruise is driving \(app)"
    }

    var body: some View {
        ZStack(alignment: .top) {
            GeometryReader { geometry in
                let depth = min(90.0, min(geometry.size.width, geometry.size.height) * 0.12)
                ZStack {
                    LinearGradient(colors: [Brand.tint.opacity(0.65), Brand.tint.opacity(0.18), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: depth).frame(maxWidth: .infinity, alignment: .leading)
                    LinearGradient(colors: [Brand.tint.opacity(0.65), Brand.tint.opacity(0.18), .clear],
                                   startPoint: .trailing, endPoint: .leading)
                        .frame(width: depth).frame(maxWidth: .infinity, alignment: .trailing)
                    LinearGradient(colors: [Brand.tint.opacity(0.65), Brand.tint.opacity(0.18), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: depth).frame(maxHeight: .infinity, alignment: .top)
                    LinearGradient(colors: [Brand.tint.opacity(0.65), Brand.tint.opacity(0.18), .clear],
                                   startPoint: .bottom, endPoint: .top)
                        .frame(height: depth).frame(maxHeight: .infinity, alignment: .bottom)
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Brand.tint.opacity(0.9), lineWidth: 3)
                }
            }
            HStack(spacing: 8) {
                ModeGlyph(mode: .cruise, size: 24)
                Text(title)
            }
                .font(BrandFont.inter(13, .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Brand.card, in: Capsule())
                .padding(.top, 36)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cruise Control is controlling the screen. \(task).")
        .allowsHitTesting(false)
    }

}

@MainActor
final class CruiseIndicatorController {
    private let store: ConfigStore
    private var panels: [NSPanel] = []
    private var cancellables: Set<AnyCancellable> = []
    private let size = CGSize(width: 96, height: 96)

    init(store: ConfigStore) {
        self.store = store
        rebuildPanels()
        store.$config
            .map(\.mode)
            .removeDuplicates()
            .sink { [weak self] mode in self?.updateVisibility(mode: mode) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.rebuildPanels() }
            .store(in: &cancellables)
    }

    private func rebuildPanels() {
        panels.forEach { $0.orderOut(nil) }
        panels = NSScreen.screens.map { screen in
            let available = screen.visibleFrame
            let panel = CruiseIndicatorPanel(
                contentRect: CGRect(x: available.maxX - size.width - 16,
                                    y: available.minY + 16,
                                    width: size.width, height: size.height),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
            )
            panel.title = "Cruise Control active"
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isMovable = false
            let host = NSHostingView(rootView: CruiseIndicatorView(store: store))
            host.sizingOptions = []
            panel.contentView = host
            return panel
        }
        updateVisibility(mode: store.config.mode)
    }

    private func updateVisibility(mode: DriveMode) {
        for panel in panels {
            panel.title = mode == .rest ? "Cruise Control rest area" : "Cruise Control active"
            if mode != .manual { panel.orderFrontRegardless() }
            else { panel.orderOut(nil) }
        }
    }
}

private struct CruiseIndicatorView: View {
    @ObservedObject var store: ConfigStore

    private var mode: DriveMode { store.config.mode }
    private var accent: Color { Brand.accent(for: mode) }

    @State private var breathe = false

    var body: some View {
        ZStack {
            // Soft ambient bloom behind the mark, like light on glass rather than a sticker.
            Circle()
                .fill(RadialGradient(colors: [accent.opacity(0.32), accent.opacity(0.08), .clear],
                                     center: .center, startRadius: 2, endRadius: 46))
                .scaleEffect(breathe ? 1.06 : 0.94)
                .opacity(breathe ? 1 : 0.7)
            mark
                .frame(width: 52, height: 52)
                .foregroundStyle(LinearGradient(colors: [.white.opacity(0.95), accent],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: accent.opacity(0.9), radius: 2)
                .shadow(color: accent.opacity(0.55), radius: 8)
                .shadow(color: accent.opacity(breathe ? 0.4 : 0.2), radius: 18)
        }
        .frame(width: 96, height: 96)
        .onAppear {
            withAnimation(.easeInOut(duration: mode == .rest ? 3.2 : 2.2).repeatForever(autoreverses: true)) { breathe = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mode == .rest ? "Cruise Control rest area is active" : "Cruise Control is active")
        .allowsHitTesting(false)
    }

    @ViewBuilder private var mark: some View {
        ModeGlyph(mode: mode, size: 52)
    }
}
