import AppKit
import Combine
import SwiftUI
import CruiseCore

struct SafetyHeldRequest: Identifiable {
    let confirmation: VSCodeConfirmation
    let reason: String
    var id: String { confirmation.key }
}

@MainActor
final class SafetyRequestGuide {
    private let store: ConfigStore
    private let monitor: ClickyMonitor
    private var queue: [SafetyHeldRequest] = []
    private var activeID: String?
    private var observedActivePrompt = false
    private var resolutionObserved = false
    private var panel: NSPanel?
    private var checking = false
    private var cancellables: Set<AnyCancellable> = []

    init(store: ConfigStore, monitor: ClickyMonitor) {
        self.store = store
        self.monitor = monitor
        monitor.$safetyHeldRequests
            .sink { [weak self] requests in self?.enqueue(requests) }
            .store(in: &cancellables)
        store.$config.map(\.mode).removeDuplicates()
            .sink { [weak self] mode in
                guard let self else { return }
                self.monitor.safetyReviewInProgress = mode == .cruise && !self.queue.isEmpty
                if mode != .cruise { self.panel?.orderOut(nil) }
            }
            .store(in: &cancellables)
        Timer.publish(every: 2, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.tick() }
            .store(in: &cancellables)
    }

    private func enqueue(_ requests: [SafetyHeldRequest]) {
        for request in requests where !queue.contains(where: { $0.id == request.id }) {
            queue.append(request)
        }
        monitor.safetyReviewInProgress = !queue.isEmpty && store.config.mode == .cruise
        tick()
    }

    private func tick() {
        guard store.config.mode == .cruise, !checking, let first = queue.first else { return }
        checking = true
        Task {
            defer { checking = false }
            let config = store.config
            let pending = first.confirmation
            let canResolve = activeID == first.id && observedActivePrompt
            // A hidden or unreadable thread is not evidence that the user decided.
            let resolved = await Worker.scanVSCode {
                guard canResolve else { return false }
                let scanner = VSCodeScanner(config: config)
                if pending.sidebarThread == nil {
                    guard let title = pending.threadTitle,
                          scanner.selectedThread(in: pending.window) == title else { return false }
                }
                return scanner.isResolved(pending) == true
            }
            guard store.config.mode == .cruise, queue.first?.id == first.id else { return }
            if resolved && resolutionObserved {
                queue.removeFirst()
                monitor.resolveSafetyHeldRequest(first.id)
                activeID = nil
                observedActivePrompt = false
                resolutionObserved = false
                panel?.orderOut(nil)
                return
            }
            resolutionObserved = resolved
            if activeID == nil {
                // Warn before the single navigation; later arrivals never displace this prompt.
                let interaction = InputSynth.UserInteractionWatch()
                defer { interaction.stop() }
                ScreenControlActivity.announce("Preparing to show a safety-held VS Code request")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !interaction.interrupted, store.config.mode == .cruise else { return }
                activeID = first.id
                monitor.safetyReviewInProgress = true
                ScreenControlActivity.announce("Opening a safety-held VS Code request")
                guard let app = NSRunningApplication(processIdentifier: pending.appPID), !app.isTerminated else {
                    monitor.record("safety guide: request's app is no longer available; retaining it for review")
                    return
                }
                app.activate(options: [.activateAllWindows])
                _ = AXUIElementPerformAction(pending.window, kAXRaiseAction as CFString)
                if let row = pending.navigationRow, !AX.press(row) {
                    monitor.record("safety guide: could not open the held request's thread; no approval was pressed")
                }
            }
            await highlight(first)
        }
    }

    private func highlight(_ request: SafetyHeldRequest) async {
        let config = store.config
        let fresh = await Worker.scanVSCode {
            VSCodeScanner(config: config).scanAll().first { $0.key == request.id }
        }
        guard store.config.mode == .cruise, queue.first?.id == request.id,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == request.confirmation.appPID,
              let fresh, let bounds = AX.frame(fresh.allow),
              bounds.width > 0, bounds.height > 0 else {
            panel?.orderOut(nil)
            return
        }
        observedActivePrompt = true
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(
            CGPoint(x: bounds.midX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - bounds.midY)
        ) }) else { return }
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let target = CGRect(x: bounds.minX, y: desktopTop - bounds.maxY,
                            width: bounds.width, height: bounds.height)
        if panel == nil {
            let overlay = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
            overlay.isOpaque = false
            overlay.backgroundColor = .clear
            overlay.ignoresMouseEvents = true
            overlay.level = .floating
            overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel = overlay
        }
        guard let panel else { return }
        // The panel is click-through: only the user can choose the underlying Allow/Deny controls.
        let visible = screen.visibleFrame
        let width: CGFloat = min(360, visible.width)
        let frame = CGRect(x: min(max(target.midX - width / 2, visible.minX), visible.maxX - width),
                           y: max(visible.minY, target.minY - 76), width: width,
                           height: target.height + 84)
        panel.setFrame(frame, display: true)
        let localTarget = target.offsetBy(dx: -frame.minX, dy: -frame.minY)
        panel.contentView = NSHostingView(rootView: SafetyPromptHighlight(
            target: CGRect(x: localTarget.minX, y: frame.height - localTarget.maxY,
                           width: localTarget.width, height: localTarget.height),
            reason: request.reason))
        panel.orderFrontRegardless()
    }
}

private struct SafetyPromptHighlight: View {
    let target: CGRect
    let reason: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Brand.youBadge, lineWidth: 3)
                .frame(width: target.width + 8, height: target.height + 8)
                .position(x: target.midX, y: target.midY)
            Text("Review required · \(reason)")
                .font(BrandFont.inter(11, .semibold))
                .foregroundStyle(.white)
                .lineLimit(3)
                .padding(8)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, target.maxY + 10)
        }
        .allowsHitTesting(false)
        .accessibilityLabel("Cruise left this request for your decision. \(reason)")
    }
}
