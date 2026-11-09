import Foundation

public enum DriveMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case manual
    case rest
    case cruise

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .manual: return "manual"
        case .rest: return "rest area"
        case .cruise: return "cruise control"
        }
    }

    public var shortTitle: String {
        switch self {
        case .manual: return "MANUAL"
        case .rest: return "REST"
        case .cruise: return "CRUISE"
        }
    }

    public var subtitle: String {
        switch self {
        case .manual: return "i'm at my desk, i'll answer clicky myself"
        case .rest: return "always say “not now”"
        case .cruise: return "always say “go ahead” / “let clicky drive”"
        }
    }
}

public enum PillSide: String, Codable, Sendable {
    case left
    case right
}

public struct Config: Codable, Equatable, Sendable {
    public var mode: DriveMode = .manual
    public var autoContinueReports = true
    public var continuePrompt = "Please continue the users request to implement this particular feature based on your findings"

    public var allowLabels = ["Go ahead", "Let Clicky Drive", "Let HeyClicky drive"]
    public var denyLabels = ["Not right now", "Not now"]
    public var reportLabels = ["Show Full Report", "Full report"]
    public var sendLabels = ["Up", "Send", "Arrow Up", "Send message"]
    public var clickyBundleIDs = ["com.humansongs.clicky", "com.yourcompany.leanring-buddy"]

    public var pollInterval: Double = 1.0
    public var ocrFallback = true
    public var ocrInterval: Double = 2.0

    /// Only "Full report" buttons whose message timestamp is this recent are auto-continued.
    public var reportFreshnessMinutes: Double = 20
    public var maxContinuesPerHour = 10
    public var minSecondsBetweenContinues: Double = 90

    /// "{task} Needs you" notch card: close it, then send an Ollama-drafted nudge into that task's chat.
    public var needsYouLabels = ["Needs you"]
    public var dismissLabels = ["Close", "xmark", "Dismiss"]
    public var maxNudgesPerTaskPerHour = 6
    public var ollamaEnabled = true
    public var ollamaURL = "http://127.0.0.1:11434"
    /// Empty = first model installed in Ollama.
    public var ollamaModel = ""
    /// Sent when Ollama is unavailable or returns nothing usable.
    public var fallbackNudge = "I'm away from the desk, so please don't wait on me. Look back at what blocked you, try a different approach, make reasonable assumptions where you need to, and keep going until this task is done."

    /// Press HeyClicky's "Update app" button (it relaunches), then nudge the interrupted tasks to keep going.
    public var autoUpdateClicky = true
    public var updateLabels = ["Update app", "Install Update & Relaunch", "Install & Relaunch", "Install and Relaunch", "Restart to update"]
    public var updateCheckMinutes: Double = 30
    /// Cruise Control only hovers the notch, opens HeyClicky's chat or types into it after mouse and keyboard have been idle this long.
    public var awayIdleSeconds: Double = 30
    /// HeyClicky went quiet (task "done", unanswered question): reply with an Ollama-drafted message so it keeps going.
    /// macOS automation / permission dialogs (e.g. "HeyClicky wants access to control Reason"): approve them in cruise
    /// mode, deny in rest. Only dialogs that name HeyClicky (`clickyAppNames`) are ever touched.
    public var autoAnswerSystemDialogs = true
    public var systemDialogBundleIDs = ["com.apple.UserNotificationCenter", "com.apple.coreservices.uiagent", "com.apple.controlcenter"]
    public var clickyAppNames = ["HeyClicky", "Clicky"]
    public var systemAllowLabels = ["Allow", "OK", "Always Allow"]
    public var systemDenyLabels = ["Don’t Allow", "Don't Allow", "Deny"]
    public var replyToStalls = true
    /// Minutes without any new chat line before it counts as stalled (`busyStallMinutes` while a card still says working/sent).
    public var stallMinutes: Double = 5
    public var busyStallMinutes: Double = 20
    /// Once you've been idle this long you're treated as "away", and the quiet thresholds below replace the ones
    /// above — so a stop (e.g. HeyClicky wrongly thinking you took over) gets nudged quickly instead of in 5–20 min.
    public var awayAfterMinutes: Double = 4
    public var awayStallMinutes: Double = 2
    public var awayBusyStallMinutes: Double = 8
    /// How often to peek at the notch panel for a stall when no chat window is open.
    public var stallCheckMinutes: Double = 2
    public var openChatLabels = ["Open in a window"]
    /// When you accidentally take over mid-drive, HeyClicky hands control back with a line like "Ok, it's all yours".
    /// In cruise mode, apologise and ask it to continue.
    public var resumeAfterInterrupt = true
    public var interruptLabels = ["it's all yours", "all yours", "you've got it", "you have control", "you take it", "it's yours", "over to you", "go ahead and take over", "handing it back"]
    public var interruptedNudge = "Sorry, I interrupted you by accident — please continue exactly where you left off and keep going."
    /// Sent after the relaunch when Ollama is unavailable.
    public var relaunchNudge = "HeyClicky just updated and restarted, which interrupted you. Please pick up exactly where you left off on this task and keep going until it's done."
    /// A task card that says "Interrupted · It was cut off before it finished" (e.g. after the Mac restarted): send this
    /// polite bump into that task's chat, or press the card's "Retry" if the chat can't be opened.
    public var interruptedStatuses = ["interrupted", "cut off"]
    public var retryLabels = ["Retry", "Try again"]
    public var interruptedCardNudge = "Sorry about that — you got cut off before you finished (probably a restart on my end). Please pick up exactly where you left off on this task and keep going until it's done."

    /// Approve VS Code / Copilot chat tool confirmations ("Allow Once") after a local Ollama safety review.
    /// Off by default — see the README for the risks. Anything the review flags, or anything that can't be reviewed
    /// (Ollama down), is left on screen for you.
    public var vscodeAutoApprove = false
    /// Opt in to reviewing write-file metadata when VS Code does not expose the full diff.
    public var vscodeAllowWriteMetadata = false
    /// Allow session-scoped tool/provider grants after review of the exposed tool identity.
    public var vscodeAllowToolPermissions = false
    public var vscodeBundleIDs = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium"]
    public var vscodeAllowLabels = ["Allow Once", "Allow", "Continue", "Run"]
    public var vscodeCheckSeconds: Double = 1.5
    public var vscodeUsageCutoff: Int?
    public var vscodeObservedUsage: Double?

    public var usageCutoffReached: Bool {
        guard let cutoff = vscodeUsageCutoff, let usage = vscodeObservedUsage else { return false }
        return usage >= Double(cutoff)
    }

    @discardableResult
    public mutating func stopAtUsageCutoff() -> Bool {
        guard usageCutoffReached else { return false }
        let changed = mode != .manual || vscodeAutoApprove || vscodeTaskBumps || autoSelectVSCodeModel || autoUpdateClicky
        mode = .manual
        vscodeAutoApprove = false
        vscodeTaskBumps = false
        autoSelectVSCodeModel = false
        autoUpdateClicky = false
        return changed
    }

    public var autoSelectVSCodeModel = false
    public var economyModel = "MAI-Code-1.1-Flash"
    public var escalationModel = "GPT-6.1 Sol"
    public var modelEscalationFailures = 3
    public var modelEscalationMinutes: Double = 20
    public var modelReviewMinutes: Double = 5
    public var modelSwitchCooldownMinutes: Double = 10
    public var vscodeTaskBumps = false
    public var vscodeBumpQuietMinutes: Double = 5
    public var vscodeBumpCooldownMinutes: Double = 15
    public var auditClickyTasks = true
    public var trackedClickyTasks: [String] = []
    public var clickyTaskAuditMinutes: Double = 5

    public var pillSide: PillSide = .right
    /// In Manual and Rest modes, only show the notch pill while HeyClicky is running.
    public var showOnlyWithClicky = true

    public func shouldShowNotch(clickyRunning: Bool) -> Bool {
        mode == .cruise || clickyRunning || !showOnlyWithClicky
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        mode = try c.decodeIfPresent(DriveMode.self, forKey: .mode) ?? d.mode
        autoContinueReports = try c.decodeIfPresent(Bool.self, forKey: .autoContinueReports) ?? d.autoContinueReports
        continuePrompt = try c.decodeIfPresent(String.self, forKey: .continuePrompt) ?? d.continuePrompt
        allowLabels = try c.decodeIfPresent([String].self, forKey: .allowLabels) ?? d.allowLabels
        denyLabels = try c.decodeIfPresent([String].self, forKey: .denyLabels) ?? d.denyLabels
        reportLabels = try c.decodeIfPresent([String].self, forKey: .reportLabels) ?? d.reportLabels
        sendLabels = try c.decodeIfPresent([String].self, forKey: .sendLabels) ?? d.sendLabels
        clickyBundleIDs = try c.decodeIfPresent([String].self, forKey: .clickyBundleIDs) ?? d.clickyBundleIDs
        pollInterval = max(0.25, try c.decodeIfPresent(Double.self, forKey: .pollInterval) ?? d.pollInterval)
        ocrFallback = try c.decodeIfPresent(Bool.self, forKey: .ocrFallback) ?? d.ocrFallback
        ocrInterval = max(0.5, try c.decodeIfPresent(Double.self, forKey: .ocrInterval) ?? d.ocrInterval)
        reportFreshnessMinutes = try c.decodeIfPresent(Double.self, forKey: .reportFreshnessMinutes) ?? d.reportFreshnessMinutes
        maxContinuesPerHour = try c.decodeIfPresent(Int.self, forKey: .maxContinuesPerHour) ?? d.maxContinuesPerHour
        minSecondsBetweenContinues = try c.decodeIfPresent(Double.self, forKey: .minSecondsBetweenContinues) ?? d.minSecondsBetweenContinues
        needsYouLabels = try c.decodeIfPresent([String].self, forKey: .needsYouLabels) ?? d.needsYouLabels
        dismissLabels = try c.decodeIfPresent([String].self, forKey: .dismissLabels) ?? d.dismissLabels
        maxNudgesPerTaskPerHour = try c.decodeIfPresent(Int.self, forKey: .maxNudgesPerTaskPerHour) ?? d.maxNudgesPerTaskPerHour
        ollamaEnabled = try c.decodeIfPresent(Bool.self, forKey: .ollamaEnabled) ?? d.ollamaEnabled
        ollamaURL = try c.decodeIfPresent(String.self, forKey: .ollamaURL) ?? d.ollamaURL
        ollamaModel = try c.decodeIfPresent(String.self, forKey: .ollamaModel) ?? d.ollamaModel
        fallbackNudge = try c.decodeIfPresent(String.self, forKey: .fallbackNudge) ?? d.fallbackNudge
        autoUpdateClicky = try c.decodeIfPresent(Bool.self, forKey: .autoUpdateClicky) ?? d.autoUpdateClicky
        updateLabels = try c.decodeIfPresent([String].self, forKey: .updateLabels) ?? d.updateLabels
        updateCheckMinutes = max(5, try c.decodeIfPresent(Double.self, forKey: .updateCheckMinutes) ?? d.updateCheckMinutes)
        awayIdleSeconds = max(5, try c.decodeIfPresent(Double.self, forKey: .awayIdleSeconds) ?? d.awayIdleSeconds)
        autoAnswerSystemDialogs = try c.decodeIfPresent(Bool.self, forKey: .autoAnswerSystemDialogs) ?? d.autoAnswerSystemDialogs
        systemDialogBundleIDs = try c.decodeIfPresent([String].self, forKey: .systemDialogBundleIDs) ?? d.systemDialogBundleIDs
        clickyAppNames = try c.decodeIfPresent([String].self, forKey: .clickyAppNames) ?? d.clickyAppNames
        systemAllowLabels = try c.decodeIfPresent([String].self, forKey: .systemAllowLabels) ?? d.systemAllowLabels
        systemDenyLabels = try c.decodeIfPresent([String].self, forKey: .systemDenyLabels) ?? d.systemDenyLabels
        replyToStalls = try c.decodeIfPresent(Bool.self, forKey: .replyToStalls) ?? d.replyToStalls
        stallMinutes = max(1, try c.decodeIfPresent(Double.self, forKey: .stallMinutes) ?? d.stallMinutes)
        busyStallMinutes = max(2, try c.decodeIfPresent(Double.self, forKey: .busyStallMinutes) ?? d.busyStallMinutes)
        awayAfterMinutes = max(1, try c.decodeIfPresent(Double.self, forKey: .awayAfterMinutes) ?? d.awayAfterMinutes)
        awayStallMinutes = max(1, try c.decodeIfPresent(Double.self, forKey: .awayStallMinutes) ?? d.awayStallMinutes)
        awayBusyStallMinutes = max(1, try c.decodeIfPresent(Double.self, forKey: .awayBusyStallMinutes) ?? d.awayBusyStallMinutes)
        stallCheckMinutes = max(0.5, try c.decodeIfPresent(Double.self, forKey: .stallCheckMinutes) ?? d.stallCheckMinutes)
        openChatLabels = try c.decodeIfPresent([String].self, forKey: .openChatLabels) ?? d.openChatLabels
        resumeAfterInterrupt = try c.decodeIfPresent(Bool.self, forKey: .resumeAfterInterrupt) ?? d.resumeAfterInterrupt
        interruptLabels = try c.decodeIfPresent([String].self, forKey: .interruptLabels) ?? d.interruptLabels
        interruptedNudge = try c.decodeIfPresent(String.self, forKey: .interruptedNudge) ?? d.interruptedNudge
        relaunchNudge = try c.decodeIfPresent(String.self, forKey: .relaunchNudge) ?? d.relaunchNudge
        interruptedStatuses = try c.decodeIfPresent([String].self, forKey: .interruptedStatuses) ?? d.interruptedStatuses
        retryLabels = try c.decodeIfPresent([String].self, forKey: .retryLabels) ?? d.retryLabels
        interruptedCardNudge = try c.decodeIfPresent(String.self, forKey: .interruptedCardNudge) ?? d.interruptedCardNudge
        vscodeAutoApprove = try c.decodeIfPresent(Bool.self, forKey: .vscodeAutoApprove) ?? d.vscodeAutoApprove
        vscodeAllowWriteMetadata = try c.decodeIfPresent(Bool.self, forKey: .vscodeAllowWriteMetadata) ?? d.vscodeAllowWriteMetadata
        vscodeAllowToolPermissions = try c.decodeIfPresent(Bool.self, forKey: .vscodeAllowToolPermissions) ?? d.vscodeAllowToolPermissions
        vscodeBundleIDs = try c.decodeIfPresent([String].self, forKey: .vscodeBundleIDs) ?? d.vscodeBundleIDs
        vscodeAllowLabels = try c.decodeIfPresent([String].self, forKey: .vscodeAllowLabels) ?? d.vscodeAllowLabels
        vscodeCheckSeconds = max(0.5, try c.decodeIfPresent(Double.self, forKey: .vscodeCheckSeconds) ?? d.vscodeCheckSeconds)
        vscodeUsageCutoff = try c.decodeIfPresent(Int.self, forKey: .vscodeUsageCutoff)
        if let cutoff = vscodeUsageCutoff, !CopilotUsage.cutoffs.contains(cutoff) {
            throw DecodingError.dataCorruptedError(forKey: .vscodeUsageCutoff, in: c, debugDescription: "Unsupported Copilot usage cutoff.")
        }
        vscodeObservedUsage = try c.decodeIfPresent(Double.self, forKey: .vscodeObservedUsage)
        if let usage = vscodeObservedUsage, !usage.isFinite || !(0...100).contains(usage) {
            throw DecodingError.dataCorruptedError(forKey: .vscodeObservedUsage, in: c, debugDescription: "Copilot usage must be between 0 and 100.")
        }
        autoSelectVSCodeModel = try c.decodeIfPresent(Bool.self, forKey: .autoSelectVSCodeModel) ?? d.autoSelectVSCodeModel
        economyModel = try c.decodeIfPresent(String.self, forKey: .economyModel) ?? d.economyModel
        escalationModel = try c.decodeIfPresent(String.self, forKey: .escalationModel) ?? d.escalationModel
        modelEscalationFailures = max(2, try c.decodeIfPresent(Int.self, forKey: .modelEscalationFailures) ?? d.modelEscalationFailures)
        modelEscalationMinutes = max(5, try c.decodeIfPresent(Double.self, forKey: .modelEscalationMinutes) ?? d.modelEscalationMinutes)
        modelReviewMinutes = max(1, try c.decodeIfPresent(Double.self, forKey: .modelReviewMinutes) ?? d.modelReviewMinutes)
        modelSwitchCooldownMinutes = max(1, try c.decodeIfPresent(Double.self, forKey: .modelSwitchCooldownMinutes) ?? d.modelSwitchCooldownMinutes)
        vscodeTaskBumps = try c.decodeIfPresent(Bool.self, forKey: .vscodeTaskBumps) ?? d.vscodeTaskBumps
        vscodeBumpQuietMinutes = max(1, try c.decodeIfPresent(Double.self, forKey: .vscodeBumpQuietMinutes) ?? d.vscodeBumpQuietMinutes)
        vscodeBumpCooldownMinutes = max(5, try c.decodeIfPresent(Double.self, forKey: .vscodeBumpCooldownMinutes) ?? d.vscodeBumpCooldownMinutes)
        auditClickyTasks = try c.decodeIfPresent(Bool.self, forKey: .auditClickyTasks) ?? d.auditClickyTasks
        trackedClickyTasks = try c.decodeIfPresent([String].self, forKey: .trackedClickyTasks) ?? d.trackedClickyTasks
        clickyTaskAuditMinutes = max(1, try c.decodeIfPresent(Double.self, forKey: .clickyTaskAuditMinutes) ?? d.clickyTaskAuditMinutes)
        pillSide = try c.decodeIfPresent(PillSide.self, forKey: .pillSide) ?? d.pillSide
        showOnlyWithClicky = try c.decodeIfPresent(Bool.self, forKey: .showOnlyWithClicky) ?? d.showOnlyWithClicky
    }
}
