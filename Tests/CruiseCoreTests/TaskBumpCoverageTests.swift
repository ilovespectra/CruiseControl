import Foundation
import Testing
@testable import CruiseCore

@Suite struct TaskBumpCoverageTests {
    @Test func validatesEveryOriginalCriterionAndRejectsInventedCriteria() throws {
        let definition = "Create a puzzle with a watercolor lighthouse background.\nProvide a Linux run command."
        func response(_ criteria: [[String: Any]]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["criteria": criteria]), as: UTF8.self)
        }
        let criteria = DefinitionOfDone.userCriteria(definition)
        let omitted: [[String: Any]] = [
            ["criterion": criteria[0], "comparison": "Background absent.", "missing": ["watercolor lighthouse background"]],
            ["criterion": criteria[1], "comparison": "Run command requested.", "missing": []],
        ]
        #expect(TaskBumpCoverage.parse(try response(omitted), definition: definition) == [criteria[0]])
        #expect(TaskBumpCoverage.parse(try response([
            ["criterion": criteria[0], "comparison": "Background requested.", "missing": []],
            ["criterion": criteria[1], "comparison": "Run command requested.", "missing": []],
        ]), definition: definition) == [])
        #expect(TaskBumpCoverage.parse(try response([omitted[0]]), definition: definition) == nil)
        #expect(TaskBumpCoverage.parse(try response([
            ["criterion": "Add invented music", "comparison": "Invented.", "missing": ["music"]],
            omitted[1],
        ]), definition: definition) == nil)
        #expect(TaskBumpCoverage.parse(try response([]), definition: definition) == nil)
        #expect(TaskBumpCoverage.parse(try response([
            ["criterion": criteria[0], "comparison": "Unquoted or invented omission cannot authorize new scope.", "missing": ["Add music"]],
            omitted[1],
        ]), definition: definition) == [criteria[0]])
        #expect(TaskBumpCoverage.parse(try response([
            ["criterion": criteria[0], "comparison": "Invalid empty detail.", "missing": [""]],
            omitted[1],
        ]), definition: definition) == nil)
        #expect(TaskBumpCoverage.parse("invalid", definition: definition) == nil)
    }

    @Test func fullParagraphDetailsAreNotTruncatedInDraftContext() {
        let definition = String(repeating: "Prior context. ", count: 25)
            + "Create a puzzle with a watercolor lighthouse background and provide a Linux run command."
        let context = TaskAudit.definitionBumpContext(task: ClickyTasksTests.task(),
                                                     definition: definition, projectLabel: "Example",
                                                     repository: "", priority: .normal, missing: [definition])
        #expect(context.components(separatedBy: definition).count == 3)
    }

    @Test func partialProgressDoesNotStopRemainingDetailsOfTheSameParagraph() {
        let task = ClickyTasksTests.task("The puzzle is implemented; the background has not been added.")
        let definition = "Create a puzzle with a watercolor lighthouse background."
        var progress = DoneProgress()
        progress.definition = definition
        progress.lastMissing = [definition]
        progress.lastReport = "The previous project is complete."
        let assessment = ClickyTaskAssessment(state: .unfinished, reason: "Background missing.",
                                               meetsDefinition: false, missing: [definition], definition: definition,
                                               fingerprint: task.fingerprint, source: "ollama", assessedAt: Date())
        #expect(!DefinitionOfDone.hasNoProgress(assessment, progress: progress, task: task))
        progress.lastReport = task.lastMessage
        #expect(DefinitionOfDone.hasNoProgress(assessment, progress: progress, task: task))
    }

    @Test func omittedCriteriaAreAppendedVerbatimInsteadOfDiscardingDraft() {
        let draft = "Cruise Control follow-up: Downloads: Please verify the counters."
        let repaired = TaskBumpCoverage.appendingCriteria(["screenshots through real-browser views", "Please verify the counters."], to: draft)
        #expect(repaired.hasPrefix(draft))
        #expect(repaired.contains("- screenshots through real-browser views"))
        #expect(!repaired.contains("- Please verify the counters."))
        #expect(TaskAudit.definitionFollowUpIsActionable(repaired))
        #expect(TaskBumpCoverage.appendingCriteria([], to: draft) == draft)
    }

    @Test func definitionFollowUpRequestsCurrentStateAndEvidenceBeforeClarification() {
        let definition = "Add the requested controls.\nVerify the feature with tests."
        let message = DefinitionOfDone.criteriaFollowUp(task: "Cruise Audio", missing: DefinitionOfDone.userCriteria(definition))
        #expect(message.contains("inspect the current project/workspace"))
        #expect(message.contains("report the current state of each item"))
        #expect(message.contains("concrete evidence"))
        #expect(message.contains("Before asking the user to clarify requirements that are already stated"))
        #expect(message.contains("- Add the requested controls."))
        #expect(message.contains("- Verify the feature with tests."))
        #expect(TaskAudit.definitionFollowUpIsActionable(message))
    }

    @Test func deliverableRequestsAreNotClarifications() {
        let definition = "verify by screenshots of the landing pages. end by providing each screenshot and a markdown of the numbers."
        #expect(TaskAudit.clarificationRequestsDeliverables("Could you please provide the screenshots and markdown?", definition: definition))
        #expect(!TaskAudit.clarificationRequestsDeliverables("Which landing page domain should be used?", definition: definition))
        #expect(!TaskAudit.clarificationRequestsDeliverables("Could you provide the background image you want?", definition: "make snake with a custom background"))
    }

    @Test func releasedStopNoLongerHoldsTask() {
        var recovery = TaskRecovery()
        recovery.observe(task: "Sol Paper Trader", status: "Stopped by you", latestTurnStatus: nil)
        #expect(recovery.isStopped(task: "sol paper trader"))
        recovery.release(task: "Sol Paper Trader")
        #expect(!recovery.isStopped(task: "Sol Paper Trader"))
    }
}
