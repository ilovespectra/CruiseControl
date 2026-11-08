import SwiftUI
import CruiseCore

struct NotchRootView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var monitor: ClickyMonitor
    var expanded: Bool
    var menuBarHeight: CGFloat
    var side: PillSide
    var toggle: () -> Void

    var body: some View {
        Group {
            if expanded {
                ExpandedPanel(store: store, monitor: monitor, menuBarHeight: menuBarHeight, toggle: toggle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                CollapsedPill(mode: store.config.mode, monitor: monitor, height: menuBarHeight, side: side, toggle: toggle)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

// MARK: Collapsed "notch wing"

struct CollapsedPill: View {
    var mode: DriveMode
    @ObservedObject var monitor: ClickyMonitor
    var height: CGFloat
    var side: PillSide
    var toggle: () -> Void

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            CruiseGlyph(size: min(17, height - 12))
                .scaleEffect(pulse ? 1.18 : 1)
            Circle()
                .fill(Brand.accent(for: mode))
                .frame(width: 6, height: 6)
                .shadow(color: Brand.accent(for: mode).opacity(0.9), radius: 3)
                .opacity(monitor.clickyRunning ? 1 : 0.35)
            Text(mode.shortTitle)
                .font(BrandFont.inter(10.5, .heavy))
                .tracking(0.8)
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
            Image(systemName: "chevron.down")
                .font(BrandFont.inter(8, .bold))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            UnevenRoundedRectangle(
                bottomLeadingRadius: side == .right ? 6 : 12,
                bottomTrailingRadius: side == .right ? 12 : 6,
                style: .continuous
            )
            .fill(Color.black)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .help("cruise control · \(mode.title)")
        .onChange(of: monitor.lastActionAt) { _, _ in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.4)) { pulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation(.easeOut(duration: 0.3)) { pulse = false }
            }
        }
    }
}

// MARK: Expanded dropdown

struct ExpandedPanel: View {
    @ObservedObject private var updates = AppUpdates.shared
    @ObservedObject var store: ConfigStore
    @ObservedObject var monitor: ClickyMonitor
    var menuBarHeight: CGFloat
    var toggle: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(DriveMode.allCases) { mode in
                ModeRow(mode: mode, selected: store.config.mode == mode) {
                    store.config.mode = mode
                }
            }
            Button {
                toggle()
                NotificationCenter.default.post(name: SettingsController.openNotification, object: nil)
            } label: {
                Label(updates.available == nil ? "settings" : "settings · Update Available", systemImage: "gearshape")
                    .font(BrandFont.inter(13, .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
        }
        .padding(14)
        .padding(.top, menuBarHeight * 0.25)
        .frame(width: 330)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24)
                .fill(Color.black)
        )
    }
}

struct SettingsContent: View {
    @ObservedObject private var updates = AppUpdates.shared
    @ObservedObject var store: ConfigStore
    @ObservedObject var monitor: ClickyMonitor

    var body: some View {
        TabView {
            settingsPage {
                settingsSection("Cruise Control updates", detail: "Installed: \(updates.installedVersion). Public GitHub releases are checked on launch and every six hours.") {
                    Text(updates.status).textSelection(.enabled)
                    HStack {
                        Button("Check for updates") { Task { await updates.check() } }.disabled(updates.busy)
                        if updates.available != nil {
                            Button("Download update…") { Task { await updates.install() } }.disabled(updates.busy)
                        }
                    }
                    Text("Packages are unsigned unless the publisher configures Developer ID signing. macOS warnings are expected; no security protections are disabled.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            settingsPage {
                settingsSection("HeyClicky", detail: "Controls for drive requests, unfinished tasks and app updates.") {
                    continueToggle
                    updateToggle
                    Toggle("Resume interrupted tasks", isOn: $store.config.resumeAfterInterrupt)
                    Toggle("Check other recent tasks for unfinished work", isOn: $store.config.auditClickyTasks)
                    Text("Checks up to three recent tasks and explicitly tracked tasks while idle. A Done badge is not proof of completion.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Tracked tasks (comma separated)", text: Binding(
                        get: { store.config.trackedClickyTasks.joined(separator: ", ") },
                        set: { store.config.trackedClickyTasks = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
                    ))
                    Toggle("Reply when HeyClicky goes quiet", isOn: $store.config.replyToStalls)
                    Toggle("Answer HeyClicky system permission dialogs", isOn: $store.config.autoAnswerSystemDialogs)
                }
                settingsSection("VS Code", detail: "Independent opt-in controls. Higher-cost model switches always require confirmation.") {
                    vscodeToggle
                    modelToggle
                    chatBumpToggle
                    Picker("Stop Cruise Control at Copilot usage", selection: $store.config.vscodeUsageCutoff) {
                        Text("Off").tag(Int?.none)
                        ForEach(CopilotUsage.cutoffs, id: \.self) { cutoff in
                            Text("\(cutoff)%").tag(Optional(cutoff))
                        }
                    }
                    Text(store.config.vscodeObservedUsage.map { "Highest observed usage warning: \($0.formatted())%." }
                         ?? "No Copilot usage warning observed yet.")
                        .font(.caption).foregroundStyle(.secondary)
                    if store.config.usageCutoffReached {
                        Label("Usage cutoff reached — automation disabled", systemImage: "hand.raised.fill")
                    }
                    if store.config.vscodeObservedUsage != nil {
                        Button("Reset observed usage for a new billing period…") {
                            let alert = NSAlert()
                            alert.messageText = "Reset the recorded Copilot usage?"
                            alert.informativeText = "Only reset this after your credits renew. This clears the spending guard's recorded warning, not your actual GitHub usage. Automation stays off until you enable it again."
                            alert.addButton(withTitle: "Cancel")
                            alert.addButton(withTitle: "Reset recorded usage")
                            if alert.runModal() == .alertSecondButtonReturn { store.config.vscodeObservedUsage = nil }
                        }
                    }
                    Text("Watches accessible VS Code usage notifications, including background windows. At the selected limit, switches to Manual and disables VS Code approvals, follow-ups, model selection and HeyClicky updates. Running agents are not cancelled. Warnings can arrive late or be missed: this is not a hard billing cap.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                settingsSection("Local Ollama", detail: "Reviews and drafts use this endpoint. Localhost keeps conversation text on this Mac.") {
                    Toggle("Use Ollama for HeyClicky nudges", isOn: $store.config.ollamaEnabled)
                    TextField("Endpoint", text: $store.config.ollamaURL)
                    TextField("Model (empty uses first installed)", text: $store.config.ollamaModel)
                }
            }
            .tabItem { Label("Automation", systemImage: "steeringwheel") }
            settingsPage {
                settingsSection("Recorded activity", detail: "Real action counts since \(monitor.stats.trackingSince.formatted(date: .abbreviated, time: .shortened)). Saved across app restarts; historical logs are not guessed or backfilled.") {
                    stats
                }
                settingsSection("Recent activity", detail: "The complete history is available in the activity log.") {
                    activity
                    Button("Open activity log") { NSWorkspace.shared.open(monitor.logFileURL) }
                }
            }
            .tabItem { Label("Activity", systemImage: "chart.bar") }
            settingsPage {
                settingsSection("Documentation & safety", detail: "Cruise Control is an independent open-source project, not affiliated with HeyClicky.") {
                    Text("Auto-approval removes a human checkpoint. Agents can delete files, expose secrets, install malware, spend money, or change accounts. Ollama review and rate limits are not a security boundary. Use backups and restricted accounts; supervise important work.")
                    Text("To stop automation, select Manual and disable the separate VS Code approval and model switches. Hiding the notch does not stop automation, and switching modes does not cancel already-running agents.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Link("Documentation & warnings", destination: URL(string: "https://cruise.kolektivkrog.si/docs.html")!)
                        Link("GitHub source", destination: URL(string: "https://github.com/ilovespectra/CruiseControl")!)
                    }
                }
                settingsSection("Permissions", detail: "Accessibility is required to read controls and press buttons. Screen recording is an optional HeyClicky OCR fallback.") {
                    permissionStatus
                    permissions
                    Toggle("Screen OCR fallback", isOn: $store.config.ocrFallback)
                }
                settingsSection("Appearance & startup", detail: "The dashboard light remains visible in Cruise mode. Hiding the notch does not disable automation.") {
                    Picker("Notch side", selection: $store.config.pillSide) {
                        Text("Left").tag(PillSide.left)
                        Text("Right").tag(PillSide.right)
                    }
                    Toggle("Only show notch while HeyClicky is running", isOn: $store.config.showOnlyWithClicky)
                    footer
                }
            }
            .tabItem { Label("App & permissions", systemImage: "gearshape") }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 540)
        .preferredColorScheme(.dark)
        .tint(Brand.periwinkle)
    }

    private func settingsPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18, content: content)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func settingsSection<Content: View>(_ title: String, detail: String,
                                                @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Divider()
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private var permissionStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(monitor.axTrusted ? "Accessibility granted" : "Accessibility required",
                  systemImage: monitor.axTrusted ? "checkmark.circle" : "exclamationmark.circle")
            Label(monitor.screenTrusted ? "Screen recording granted" : "Screen recording not granted",
                  systemImage: monitor.screenTrusted ? "checkmark.circle" : "exclamationmark.circle")
            Text(monitor.clickyRunning ? "HeyClicky is running" : "HeyClicky is not running")
                .foregroundStyle(.secondary)
        }
    }

    private var continueToggle: some View {
        Toggle(isOn: $store.config.autoContinueReports) {
            VStack(alignment: .leading, spacing: 1) {
                Text("keep unfinished tasks going")
                    .font(BrandFont.inter(12, .semibold))
                    .foregroundStyle(.white)
                Text("full report or “needs you” → nudges clicky to keep going")
                    .font(BrandFont.inter(10.5))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Brand.royal)
        .disabled(store.config.mode == .manual)
        .opacity(store.config.mode == .manual ? 0.5 : 1)
        .padding(.horizontal, 4)
    }

    private var updateToggle: some View {
        Toggle(isOn: $store.config.autoUpdateClicky) {
            VStack(alignment: .leading, spacing: 1) {
                Text("keep heyclicky updated")
                    .font(BrandFont.inter(12, .semibold))
                    .foregroundStyle(.white)
                Text("presses “update app”, then nudges clicky after it relaunches")
                    .font(BrandFont.inter(10.5))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Brand.royal)
        .padding(.horizontal, 4)
    }

    private var vscodeToggle: some View {
        Toggle(isOn: Binding(
            get: { store.config.vscodeAutoApprove },
            set: { on in
                if !on { store.config.vscodeAutoApprove = false }
                else if VSCodeDisclaimer.confirm() { store.config.vscodeAutoApprove = true }
            }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text("always allow in vscode")
                    .font(BrandFont.inter(12, .semibold))
                    .foregroundStyle(store.config.vscodeAutoApprove ? Brand.accent(for: .cruise) : .white)
                Text(store.config.vscodeAutoApprove
                     ? "ollama screens each request, then “allow once” · \(monitor.stats.vscodeApproved) so far"
                     : "auto-approve copilot tool requests after a local ollama check")
                    .font(BrandFont.inter(10.5))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Brand.royal)
        .padding(.horizontal, 4)
        .help("risky — read the warning that appears when you turn it on")
    }

    private var modelToggle: some View {
        Toggle(isOn: $store.config.autoSelectVSCodeModel) {
            VStack(alignment: .leading, spacing: 1) {
                Text("use cheaper vscode models")
                    .font(BrandFont.inter(12, .semibold))
                    .foregroundStyle(.white)
                Text("mai-code flash first · ask you before any escalation")
                    .font(BrandFont.inter(10.5))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Brand.royal)
        .padding(.horizontal, 4)
        .help("changes only the active chat, between turns. same history, no cancellation. 3 unresolved failures, an evidenced regression, or 20 minutes of stalled progress prompts you to approve escalation to GPT-6.1 Sol. never escalates automatically. configure models and limits in config.")
    }

    private var chatBumpToggle: some View {
        Toggle(isOn: $store.config.vscodeTaskBumps) {
            VStack(alignment: .leading, spacing: 1) {
                Text("keep vscode tasks going")
                    .font(BrandFont.inter(12, .semibold))
                    .foregroundStyle(.white)
                Text("quiet unfinished chat → a task-specific text follow-up")
                    .font(BrandFont.inter(10.5))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Brand.royal)
        .padding(.horizontal, 4)
        .help("Cruise mode only, after 5 quiet minutes while you're idle. Local Ollama checks for unfinished work. No screenshots, draft overwrites, permission answers or interruption of running tools. 15-minute cooldown.")
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !monitor.axTrusted {
                PermissionRow(title: "accessibility", detail: "so i can press clicky's buttons") {
                    monitor.requestPermissionsIfNeeded()
                    monitor.openPrivacyPane("Privacy_Accessibility")
                }
            }
            if store.config.ocrFallback && !monitor.screenTrusted {
                PermissionRow(title: "screen recording", detail: "backup for reading clicky's notch prompt") {
                    monitor.requestPermissionsIfNeeded()
                    monitor.openPrivacyPane("Privacy_ScreenCapture")
                }
            }
        }
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("HeyClicky").font(.subheadline.bold())
            HStack(spacing: 24) {
                StatChip(symbol: "checkmark.circle.fill", value: monitor.stats.approved, label: "approved")
                StatChip(symbol: "hand.raised.fill", value: monitor.stats.declined, label: "declined")
                StatChip(symbol: "arrow.clockwise.circle.fill", value: monitor.stats.continued, label: "continued")
            }
            Text("VS Code").font(.subheadline.bold())
            HStack(spacing: 24) {
                StatChip(symbol: "checkmark.circle.fill", value: monitor.stats.vscodeApproved, label: "approved")
                StatChip(symbol: "hand.raised.fill", value: monitor.stats.vscodeHeldForReview, label: "held for review")
                StatChip(symbol: "arrow.clockwise.circle.fill", value: monitor.stats.vscodeContinued, label: "follow-ups")
                StatChip(symbol: "arrow.triangle.swap", value: monitor.stats.vscodeModelSwitches, label: "model switches")
            }
            Text("Held requests are left for you, not clicked Decline. Failed reviews and unsent follow-ups do not count as successful actions.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(monitor.log.suffix(30).reversed()) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(line.date, format: .dateTime.hour().minute())
                        .foregroundStyle(.white.opacity(0.35))
                    Text(line.text)
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(BrandFont.mono(10.5))
            }
        }
        .padding(.horizontal, 4)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: LaunchAgent.isInstalled ? "bolt.fill" : "bolt.slash")
                Text(LaunchAgent.isInstalled ? "auto-starts" : "not auto-starting")
            }
            .font(BrandFont.inter(10.5))
            .foregroundStyle(.white.opacity(0.45))
            .help(LaunchAgent.isInstalled
                  ? "a launch agent keeps cruise control running. it shows up whenever heyclicky is open."
                  : "run scripts/build-app.sh --install to keep cruise control running in the background.")
            Spacer()
            Button("config") { NSWorkspace.shared.open(store.fileURL) }
                .buttonStyle(ClickyPillButtonStyle(primary: false))
            Button("log") { NSWorkspace.shared.open(monitor.logFileURL) }
                .buttonStyle(ClickyPillButtonStyle(primary: false))
            Button("hide") { NotificationCenter.default.post(name: LaunchAgent.hideNotification, object: nil) }
                .buttonStyle(ClickyPillButtonStyle(primary: true))
                .help("hides the pill until heyclicky launches again (or you open cruise control). your mode keeps working in the background.")
        }
        .padding(.top, 2)
    }
}

struct ModeRow: View {
    var mode: DriveMode
    var selected: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: Brand.symbol(for: mode))
                    .font(BrandFont.inter(13, .semibold))
                    .foregroundStyle(selected ? Brand.navy : Brand.accent(for: mode))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(selected ? Color.white.opacity(0.7) : Color.white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.title)
                        .font(BrandFont.inter(13, .bold))
                    Text(mode.subtitle)
                        .font(BrandFont.inter(10.5))
                        .opacity(0.65)
                }
                .foregroundStyle(selected ? Color.black.opacity(0.85) : .white)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(BrandFont.inter(11, .heavy))
                        .foregroundStyle(Brand.navy)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Brand.primaryFill) : AnyShapeStyle(Color.white.opacity(hovering ? 0.10 : 0.05)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(selected ? Brand.royal : Color.white.opacity(0.08), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct PermissionRow: View {
    var title: String
    var detail: String
    var grant: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Brand.youBadge)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(BrandFont.inter(11.5, .semibold)).foregroundStyle(.white)
                Text(detail).font(BrandFont.inter(10)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Button("grant", action: grant)
                .buttonStyle(ClickyPillButtonStyle(primary: true))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.youBadge.opacity(0.12)))
    }
}

struct StatChip: View {
    var symbol: String
    var value: Int
    var label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(Brand.periwinkle)
            Text("\(value)").fontWeight(.bold).foregroundStyle(.white)
            Text(label).foregroundStyle(.white.opacity(0.45))
        }
        .font(BrandFont.inter(10.5))
    }
}

enum VSCodeDisclaimer {
    /// Shown every time the toggle is switched on. Returns true only if the user explicitly accepts.
    @MainActor
    static func confirm() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Let Cruise Control approve VS Code agent requests?"
        alert.informativeText = """
        When Copilot (or any VS Code chat agent) asks “Allow?” before running a terminal command or tool, Cruise \
        Control will read the request, ask your local Ollama model whether it looks malicious, and press “Allow Once” \
        if it doesn't. You won't see most of these requests.

        What can go wrong — far more than losing a cache:
        • Data loss: a mistaken rm, git reset/clean, database drop or overwrite can destroy work that isn't backed up.
        • Secrets: commands can read .env files, tokens, SSH/cloud keys or browser data and send them anywhere.
        • Prompt injection: a web page, README, issue or package the agent reads can tell it to run hostile commands. \
        The same text can try to talk the reviewer into saying “safe”.
        • Supply chain: approved installs (npm/pip/brew/curl) can pull in malware that runs with your permissions.
        • Money & accounts: deploys, cloud resources, emails, payments, pushes and API calls happen for real.
        • Ollama is a small local model, not a security product. It misses things and can be wrong both ways. A fixed \
        blocklist catches only the most obvious disasters (sudo, rm -rf ~, curl | sh, keychain dumps, force-push…).

        Safeguards: it only presses “Allow Once” (never “always”), only in VS Code, only after a review it could \
        actually run. If Ollama is down, its answer is unclear, or the request is flagged, the prompt stays on screen \
        for you. Every decision is written to the Cruise Control log.

        Only turn this on for projects you'd be fine restoring from backup, and keep git + Time Machine current.
        """
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "I understand — turn it on")
        alert.buttons.first?.keyEquivalent = "\r"
        alert.buttons.last?.keyEquivalent = ""
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }
}
