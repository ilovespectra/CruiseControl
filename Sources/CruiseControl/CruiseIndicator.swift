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
    private var panels: [NSPanel] = []
    private var cancellables: Set<AnyCancellable> = []

    init(monitor: ClickyMonitor) {
        taskName = monitor.drivingTaskName
        rebuildPanels()
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
            panel.title = "Cruise Control driving HeyClicky"
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
        for panel in panels {
            guard let task = taskName else {
                panel.orderOut(nil)
                continue
            }
            let host = NSHostingView(rootView: CruiseDrivingView(task: task))
            host.sizingOptions = []
            panel.contentView = host
            panel.orderFrontRegardless()
        }
    }
}

private struct CruiseDrivingView: View {
    let task: String

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Brand.periwinkle.opacity(0.85), lineWidth: 24)
                .blur(radius: 22)
                .padding(-6)
            Text("Cruise is driving HeyClicky: \(task) · Esc stops")
                .font(BrandFont.inter(13, .semibold))
                .foregroundStyle(Brand.lavender)
                .padding(12)
                .background(Brand.card, in: Capsule())
                .padding(.top, 114)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cruise is driving HeyClicky to finish \(task). Escape or any input stops before the X is clicked.")
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
        if mode == .rest {
            Image(systemName: Brand.symbol(for: .rest))
                .resizable().scaledToFit()
                .fontWeight(.medium)
                .padding(6)
        } else {
            ZStack {
                let stroke = StrokeStyle(lineWidth: 3, lineCap: .round)
                CruiseGauge(part: .remaining).stroke(accent.opacity(0.25), style: stroke)
                CruiseGauge(part: .travelled).stroke(style: stroke)
                CruiseGauge(part: .needle)
            }
        }
    }
}
