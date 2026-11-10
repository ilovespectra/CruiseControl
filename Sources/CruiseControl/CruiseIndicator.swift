import AppKit
import Combine
import SwiftUI
import CruiseCore

private final class CruiseIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CruiseIndicatorController {
    private let store: ConfigStore
    private var panels: [NSPanel] = []
    private var cancellables: Set<AnyCancellable> = []
    private let size = CGSize(width: 224, height: 96)

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

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if mode == .rest {
                    Image(systemName: Brand.symbol(for: .rest))
                        .font(.system(size: 38, weight: .semibold))
                } else {
                    ZStack {
                        let stroke = StrokeStyle(lineWidth: 4, lineCap: .round)
                        CruiseGauge(part: .travelled).stroke(accent, style: stroke)
                        CruiseGauge(part: .remaining).stroke(accent.opacity(0.35), style: stroke)
                        CruiseGauge(part: .needle).fill(accent)
                    }
                }
            }
            .frame(width: 68, height: 68)
            Text(mode.shortTitle)
                .font(BrandFont.inter(20, .bold))
                .tracking(1.6)
        }
        .foregroundStyle(accent)
        .shadow(color: accent.opacity(0.65), radius: 8)
        .padding(.horizontal, 18)
        .background {
            Capsule()
                .fill(Color.black.opacity(0.88))
                .overlay { Capsule().strokeBorder(accent.opacity(0.45), lineWidth: 2) }
        }
        .padding(10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mode == .rest ? "Cruise Control rest area is active" : "Cruise Control is active")
        .allowsHitTesting(false)
    }
}
