import Foundation

/// Explains whether the manual follow-up action may create/send a draft for the latest report.
/// A missing or stale review is actionable as a UI message, but never authorizes drafting.
public enum TaskDraftGate: Equatable, Sendable {
    case defineCriteria
    case latestReportUnavailable
    case reviewLatestReport
    case taskWorking
    case taskStopped
    case needsUser
    case taskDismissed
    case taskFinished
    case ambiguousTask
    case noActionableGaps
    case ready

    public var message: String {
        switch self {
        case .defineCriteria:
            "Save completion criteria before drafting a follow-up."
        case .latestReportUnavailable:
            "There is no latest task response to compare yet."
        case .reviewLatestReport:
            "Review the latest response against the saved criteria before drafting."
        case .taskWorking:
            "Wait until HeyClicky finishes this task before drafting a follow-up."
        case .taskStopped:
            "This task is stopped; review it manually before any follow-up."
        case .needsUser:
            "This task needs your decision; Cruise will not draft a follow-up automatically."
        case .taskDismissed:
            "This task is dismissed in HeyClicky and cannot be bumped."
        case .taskFinished:
            "This task is marked finished in Cruise; reopen it before drafting."
        case .ambiguousTask:
            "More than one HeyClicky task has this name, so the target is not safe to draft."
        case .noActionableGaps:
            "The current review found no concrete unfinished criteria to draft against."
        case .ready:
            "Current review found concrete gaps. Drafting is available."
        }
    }

    public static func evaluate(task: ClickyAgentTask, definition: String?, assessment: ClickyTaskAssessment?,
                                finished: Bool, ambiguous: Bool) -> Self {
        guard let definition = DefinitionOfDone.normalized(definition) else { return .defineCriteria }
        guard task.hasReport else { return .latestReportUnavailable }
        guard !task.isWorking else { return .taskWorking }
        guard !task.isStopped else { return .taskStopped }
        guard !TaskAudit.requiresUser(task.lastMessage) else { return .needsUser }
        guard !task.dismissed else { return .taskDismissed }
        guard !finished else { return .taskFinished }
        guard !ambiguous else { return .ambiguousTask }
        guard let assessment, assessment.isCurrent(for: task, definition: definition) else { return .reviewLatestReport }
        guard assessment.source.hasPrefix("ollama"), assessment.evaluatesUserCriteria(definition) else { return .reviewLatestReport }
        guard assessment.clarificationQuestion == nil else { return .needsUser }
        guard ![.working, .stopped, .needsYou].contains(assessment.state) else {
            switch assessment.state {
            case .working: return .taskWorking
            case .stopped: return .taskStopped
            case .needsYou: return .needsUser
            default: break
            }
            return .noActionableGaps
        }
        guard assessment.meetsDefinition == false, !assessment.missing.isEmpty,
              [.unfinished, .failed].contains(assessment.state) else { return .noActionableGaps }
        return .ready
    }
}
