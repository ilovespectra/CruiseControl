import AppKit
import Combine
import SwiftUI
import ApplicationServices
import CruiseCore

private final class VSCodeRequestAlertPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Read-only, all-Spaces alert surface for VS Code chats that expose an explicit pending-user state.
@MainActor
final class VSCodeRequestAlertController {
    private struct SoundSettings: Equatable {
        let enabled: Bool
        let sound: Bool
    }

    private let store: ConfigStore
    private let monitor: ClickyMonitor
    private var panels: [NSPanel] = []
    private var current: [VSCodePendingRequestNotice] = []
    private var previousIDs = Set<String>()
    private var acknowledgedRequests: [String: String] = [:]
    private var requestClickMonitor: Any?
    private var lastSoundAt = Date.distantPast
    private var cancellables: Set<AnyCancellable> = []

    init(store: ConfigStore, monitor: ClickyMonitor) {
        self.store = store
        self.monitor = monitor
        requestClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let point = event.cgEvent?.location else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
                for notice in self.current where notice.appPID == pid {
                    let targets = notice.interactionTargets + [notice.navigationRow].compactMap { $0 }
                    if targets.contains(where: {
                        AX.frame($0)?.contains(point) == true && AX.isUnderPointer($0, at: point)
                    }) {
                        self.acknowledge(notice)
                        break
                    }
                }
            }
        }
        rebuildPanels()
        monitor.$pendingVSCodeAlerts
            .sink { [weak self] notices in self?.update(notices) }
            .store(in: &cancellables)
        store.$config
            .map { SoundSettings(enabled: $0.vscodeRequestAlertsEnabled, sound: $0.vscodeRequestAlertSound) }
            .removeDuplicates()
            .sink { [weak self] settings in
                guard let self else { return }
                if !settings.enabled {
                    self.current = []
                    self.previousIDs.removeAll()
                    self.updateVisibility()
                } else {
                    self.update(self.monitor.pendingVSCodeAlerts)
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.rebuildPanels() }
            .store(in: &cancellables)
    }

    private func update(_ notices: [VSCodePendingRequestNotice]) {
        guard store.config.vscodeRequestAlertsEnabled else {
            current = []
            previousIDs.removeAll()
            updateVisibility()
            return
        }
        let ids = Set(notices.map(\.id))
        acknowledgedRequests = acknowledgedRequests.filter { id, request in
            notices.contains { $0.id == id && ($0.requestKey ?? $0.detail) == request }
        }
        let newlyVisible = !ids.subtracting(previousIDs).isEmpty
        if newlyVisible, store.config.vscodeRequestAlertSound,
           Date().timeIntervalSince(lastSoundAt) >= 12 {
            playGentleSound()
            lastSoundAt = Date()
        }
        previousIDs = ids
        current = notices.filter { acknowledgedRequests[$0.id] != ($0.requestKey ?? $0.detail) }
        updateVisibility()
    }

    private func playGentleSound() {
        guard let sound = NSSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true) else { return }
        sound.volume = 0.32
        sound.play()
    }

    private func rebuildPanels() {
        panels.forEach { $0.orderOut(nil) }
        panels = NSScreen.screens.map { screen in
            let panel = VSCodeRequestAlertPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.title = "Cruise Control · VS Code is waiting for you"
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 2)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel.ignoresMouseEvents = false
            panel.hidesOnDeactivate = false
            panel.isMovable = false
            let host = NSHostingView(rootView: VSCodeRequestAlertView(notices: current) { [weak self] notice in
                self?.navigate(to: notice)
            })
            host.sizingOptions = []
            panel.contentView = host
            return panel
        }
        updateVisibility()
    }

    private func updateVisibility() {
        guard store.config.vscodeRequestAlertsEnabled, !current.isEmpty else {
            panels.forEach { $0.orderOut(nil) }
            return
        }
        for (index, panel) in panels.enumerated() {
            let screens = NSScreen.screens
            guard screens.indices.contains(index) else { continue }
            let screen = screens[index]
            let count = min(current.count, 5)
            let width: CGFloat = 420
            let height = min(CGFloat(520), CGFloat(116 + count * 76))
            let visible = screen.visibleFrame
            panel.setFrame(NSRect(x: visible.maxX - width - 18,
                                  y: visible.maxY - height - 18,
                                  width: width, height: height), display: true)
            let host = panel.contentView as? NSHostingView<VSCodeRequestAlertView>
            host?.rootView = VSCodeRequestAlertView(notices: current) { [weak self] notice in
                self?.navigate(to: notice)
            }
            panel.orderFrontRegardless()
        }
    }

    private func navigate(to notice: VSCodePendingRequestNotice) {
        guard !monitor.safetyReviewInProgress else {
            monitor.record("safety guide: finish the current held request before opening another request")
            return
        }
        acknowledge(notice)
        guard let app = NSRunningApplication(processIdentifier: notice.appPID), !app.isTerminated else { return }
        app.activate(options: [.activateAllWindows])
        _ = AXUIElementPerformAction(notice.window, kAXRaiseAction as CFString)
        guard notice.navigationRow != nil else { return }

        // Resolve a fresh row after the target window is raised; only select the chat row, never an approval button.
        let config = store.config
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !app.isTerminated else { return }
            let fresh = await Worker.scanVSCode { VSCodeScanner(config: config).pendingRequestNotices().first { $0.id == notice.id } }
            guard let fresh, let row = fresh.navigationRow else { return }
            _ = await Worker.run { AX.press(row) }
        }
    }

    private func acknowledge(_ notice: VSCodePendingRequestNotice) {
        acknowledgedRequests[notice.id] = notice.requestKey ?? notice.detail
        current.removeAll { $0.id == notice.id }
        updateVisibility()
    }

    deinit {
        if let requestClickMonitor { NSEvent.removeMonitor(requestClickMonitor) }
    }
}

private struct VSCodeRequestAlertView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let notices: [VSCodePendingRequestNotice]
    let select: (VSCodePendingRequestNotice) -> Void
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Brand.youBadge.opacity(reduceMotion ? 0.24 : (pulse ? 0.42 : 0.18)))
                        .frame(width: 38, height: 38)
                        .scaleEffect(reduceMotion ? 1 : (pulse ? 1.17 : 0.88))
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Brand.youBadge)
                        .shadow(color: Brand.youBadge.opacity(reduceMotion ? 0.8 : (pulse ? 1 : 0.5)), radius: pulse && !reduceMotion ? 12 : 6)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("VS CODE · WAITING ON YOU")
                        .font(BrandFont.inter(13, .heavy))
                        .tracking(0.8)
                        .foregroundStyle(.white)
                    Text(notices.count == 1 ? "A chat needs your attention" : "\(notices.count) chats need your attention")
                        .font(BrandFont.inter(11, .medium))
                        .foregroundStyle(.white.opacity(0.72))
                }
                Spacer(minLength: 0)
                Image(systemName: "sparkle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.youBadge.opacity(0.9))
            }

            ScrollView(.vertical) {
                VStack(spacing: 7) {
                    ForEach(notices.prefix(5)) { notice in
                        Button { select(notice) } label: {
                            HStack(spacing: 9) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(notice.title)
                                        .font(BrandFont.inter(12, .bold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text(notice.workspace)
                                        .font(BrandFont.inter(10, .medium))
                                        .foregroundStyle(.white.opacity(0.48))
                                        .lineLimit(1)
                                    Text(notice.detail)
                                        .font(BrandFont.inter(10.5, .semibold))
                                        .foregroundStyle(Brand.youBadge)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.forward.app.fill")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(Brand.periwinkle)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Brand.youBadge.opacity(pulse && !reduceMotion ? 0.68 : 0.38), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(notice.title) in VS Code. \(notice.detail)")
                        .help("Open this exact waiting VS Code chat; Cruise will not approve the request")
                    }
                }
            }
            .frame(maxHeight: 376)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.055, green: 0.065, blue: 0.10).opacity(0.98))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Brand.youBadge.opacity(pulse && !reduceMotion ? 0.92 : 0.58), lineWidth: 2)
                }
                .shadow(color: Brand.youBadge.opacity(reduceMotion ? 0.35 : (pulse ? 0.78 : 0.36)), radius: reduceMotion ? 11 : (pulse ? 24 : 11))
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { pulse = true }
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { pulse = false }
            else { withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { pulse = true } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cruise Control alert: VS Code is waiting for you")
    }
}
