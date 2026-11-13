import Foundation
import Testing
@testable import CruiseCore

@Suite struct TaskFlowTests {
    @Test func freshTaskStartsAtDoneAndFolderNeverGates() {
        let flow = TaskFlow(hasFolder: false, hasDefinition: false)
        #expect(flow.current == .done)
        #expect(flow.state(.folder) == .current)
        #expect(flow.state(.done) == .current)
        for step in [TaskFlow.Step.review, .draft, .send] {
            #expect(flow.state(step).fix == .defineDone)
            #expect(flow.state(step).reason?.contains("folder") != true)
        }
    }

    @Test func stepsIlluminateInOrder() {
        var flow = TaskFlow(hasFolder: true, hasDefinition: false)
        #expect(flow.current == .done)
        #expect(flow.state(.folder) == .complete)
        #expect(flow.state(.review).reason?.contains("done") == true)

        flow.hasDefinition = true
        #expect(flow.current == .review)
        #expect(flow.state(.draft).fix == .reviewReport)

        flow.reviewed = true
        #expect(flow.current == .draft)
        #expect(flow.state(.send).reason?.contains("Generate") == true)

        flow.hasDraft = true
        #expect(flow.current == .send)
        #expect(flow.state(.draft) == .complete)
    }

    @Test func blockersLockLaterStepsWithTheirReasonAndFix() {
        let stopped = TaskBlocker("Stopped by you.", fix: .resumeStopped)
        let working = TaskFlow(hasFolder: true, hasDefinition: true, reviewBlocker: stopped)
        #expect(working.state(.review) == .locked("Stopped by you.", .resumeStopped))
        #expect(working.state(.draft) == .locked("Stopped by you.", .resumeStopped))
        #expect(working.state(.send) == .locked("Stopped by you.", .resumeStopped))
        #expect(working.current == nil)
        #expect(working.nextAction == "Stopped by you.")
        #expect(working.nextFix == .resumeStopped)

        let met = TaskFlow(hasFolder: true, hasDefinition: true, reviewed: true, draftBlocker: TaskBlocker("Criteria met."))
        #expect(met.state(.review) == .complete)
        #expect(met.state(.draft) == .locked("Criteria met."))
        #expect(met.state(.send) == .locked("Criteria met."))

        let rest = TaskFlow(hasFolder: true, hasDefinition: true, reviewed: true, hasDraft: true,
                            sendBlocker: TaskBlocker("Rest mode.", fix: .automationSettings))
        #expect(rest.state(.send) == .locked("Rest mode.", .automationSettings))
    }

    @Test func reviewDoesNotNeedAFolder() {
        let flow = TaskFlow(hasFolder: false, hasDefinition: true)
        #expect(flow.state(.done) == .complete)
        #expect(flow.state(.review) == .current)
        #expect(flow.current == .review)
    }

    @Test func activityNamesExactlyWhatIsRunning() {
        let flow = TaskFlow(hasFolder: true, hasDefinition: true, activity: "Examining “Silo” with local Ollama (4 s)")
        #expect(flow.state(.folder) == .complete)
        #expect(flow.state(.done) == .complete)
        #expect(flow.state(.review).reason == "In progress: Examining “Silo” with local Ollama (4 s)")
        #expect(flow.nextAction.contains("Examining “Silo”"))
    }
}
