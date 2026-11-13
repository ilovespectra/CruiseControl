import Foundation

/// The order for working a task in the task manager: Done → review → draft → send, with the workspace folder
/// recommended but never required. Locked steps carry the exact reason and where the user can fix it.
public struct TaskFlow: Equatable, Sendable {
    public enum Step: Int, CaseIterable, Sendable {
        case folder = 1, done, review, draft, send
    }

    public enum State: Equatable, Sendable {
        case complete
        case current
        case locked(String, TaskFix? = nil)

        public var isEnabled: Bool { if case .locked = self { false } else { true } }
        public var reason: String? { if case .locked(let reason, _) = self { reason } else { nil } }
        public var fix: TaskFix? { if case .locked(_, let fix) = self { fix } else { nil } }
    }

    public var hasFolder: Bool
    public var hasDefinition: Bool
    /// Why the latest response can't be reviewed right now (no report, agent still working, unreadable…).
    public var reviewBlocker: TaskBlocker?
    public var reviewed: Bool
    /// Why a reviewed report can't be drafted against (criteria met, needs your decision…).
    public var draftBlocker: TaskBlocker?
    public var hasDraft: Bool
    public var sendBlocker: TaskBlocker?
    /// What Cruise is doing for this task right now, e.g. "Examining with local Ollama (12 s)".
    public var activity: String?

    public init(hasFolder: Bool, hasDefinition: Bool, reviewBlocker: TaskBlocker? = nil, reviewed: Bool = false,
                draftBlocker: TaskBlocker? = nil, hasDraft: Bool = false, sendBlocker: TaskBlocker? = nil,
                activity: String? = nil) {
        self.hasFolder = hasFolder
        self.hasDefinition = hasDefinition
        self.reviewBlocker = reviewBlocker
        self.reviewed = reviewed
        self.draftBlocker = draftBlocker
        self.hasDraft = hasDraft
        self.sendBlocker = sendBlocker
        self.activity = activity
    }

    public var busy: Bool { activity != nil }

    public func state(_ step: Step) -> State {
        let state = baseState(step)
        if let activity, state.isEnabled, step != .folder, step != .done { return .locked("In progress: \(activity)") }
        return state
    }

    private func baseState(_ step: Step) -> State {
        switch step {
        case .folder:
            return hasFolder ? .complete : .current
        case .done:
            return hasDefinition ? .complete : .current
        case .review:
            if !hasDefinition { return .locked("Define what done looks like first (step 2).", .defineDone) }
            if let reviewBlocker { return .locked(reviewBlocker.reason, reviewBlocker.fix) }
            return reviewed ? .complete : .current
        case .draft:
            if case .locked(let reason, let fix) = baseState(.review) { return .locked(reason, fix) }
            if let draftBlocker { return .locked(draftBlocker.reason, draftBlocker.fix) }
            if hasDraft { return .complete }
            if !reviewed { return .locked("Review the latest response against Done first (step 3).", .reviewReport) }
            if let draftBlocker { return .locked(draftBlocker.reason, draftBlocker.fix) }
            return .current
        case .send:
            if let draftBlocker { return .locked(draftBlocker.reason, draftBlocker.fix) }
            if !hasDraft {
                if case .locked(let reason, let fix) = baseState(.draft) { return .locked(reason, fix) }
                return .locked("Generate a response first (step 4).")
            }
            if let sendBlocker { return .locked(sendBlocker.reason, sendBlocker.fix) }
            return .current
        }
    }

    /// The step that most needs the user. The folder is optional, so it's suggested only once nothing else is pending.
    public var current: Step? {
        [Step.done, .review, .draft, .send, .folder].first { baseState($0) == .current }
    }

    /// One-line guidance for the "Next:" label.
    public var nextAction: String {
        if let activity { return "Cruise is working: \(activity)" }
        switch current {
        case .folder: return "Optional: assign the task's workspace folder so follow-ups name it."
        case .done: return "Define a short, verifiable Done goal."
        case .review: return "Review the latest response against Done."
        case .draft: return "Generate a follow-up for the remaining Done gaps."
        case .send: return "Read the draft, then send it."
        case nil:
            return [Step.review, .draft, .send].lazy.compactMap { baseState($0).reason }.first ?? "Nothing to do right now."
        }
    }

    /// The fix target for whatever currently blocks progress, if any.
    public var nextFix: TaskFix? {
        guard current == nil || current == .folder else { return nil }
        return [Step.review, .draft, .send].lazy.compactMap { baseState($0).fix }.first
    }
}
