import Foundation
import Testing
@testable import CruiseCore

@Suite struct TaskRecoveryTests {
    @Test func recognizesTimeoutToastAndInlineRetryWithoutGuessingTask() {
        let error = "model: model: network: timeout: no response in 25 s"
        #expect(Matcher.failedTask("Didn't finish Release Console. \(error)", selectedTask: "Other") == "Release Console")
        #expect(Matcher.failedTask("Didn't finish. \(error)", selectedTask: "Release Console") == "Release Console")
        #expect(Matcher.failedTask("Didn't finish. \(error)", selectedTask: nil) == nil)
        #expect(Matcher.failedTask("Didn't finish ", selectedTask: "Other") == nil)
        #expect(Matcher.failedTask("A report says Didn't finish Example. error", selectedTask: "Other") == nil)
        #expect(Matcher.failedTask("Stopped by you.", selectedTask: "Release Console") == nil)
        #expect(Matcher.isRetry("Retry, button", config: Config()))
        #expect(!Matcher.isRetry("Retry everything", config: Config()))
    }

    @Test(arguments: [
        "Stopped", "Stopped by you.", "30s · Stopped by you.", "  STOPPED!  ",
        "Paused", "Cancelled", "Canceled",
    ])
    func recognizesStopStates(label: String) {
        #expect(TaskRecovery.isStopped(label))
    }

    @Test(arguments: [
        "Interrupted", "cut off", "done", "working", "Retry",
        "The transport stopped at 1.1.1.", "Please check why it stopped by you.",
    ])
    func doesNotTreatProseOrCrashesAsManualStops(label: String) {
        #expect(!TaskRecovery.isStopped(label))
    }

    @Test func stopFooterOverridesInterruptedBadgeAndOtherTasksKeepRunning() {
        var recovery = TaskRecovery()
        recovery.observe(task: "Rippa Repair", status: "Interrupted", latestTurnStatus: "30s · Stopped by you.")
        recovery.observe(task: "Another Task", status: "working", latestTurnStatus: "sent")
        #expect(recovery.isStopped(task: "rippa repair"))
        #expect(!recovery.isStopped(task: "Another Task"))
    }

    @Test func stopSurvivesAuditRelaunchAndMissingStatus() throws {
        var recovery = TaskRecovery()
        recovery.observe(task: "Rippa Repair", status: "Stopped", latestTurnStatus: nil)
        var restored = try JSONDecoder().decode(TaskRecovery.self, from: JSONEncoder().encode(recovery))
        for status in ["Interrupted", "done", "needs you", "failed"] {
            restored.observe(task: "Rippa Repair", status: status, latestTurnStatus: status)
            #expect(restored.isStopped(task: "Rippa Repair"))
        }
        restored.observe(task: "Rippa Repair", status: nil, latestTurnStatus: nil)
        #expect(restored.isStopped(task: "Rippa Repair"))
    }

    @Test func explicitlyResumedTurnClearsStopButStaleWorkingBadgeDoesNot() {
        var recovery = TaskRecovery()
        recovery.observe(task: "Rippa Repair", status: "working", latestTurnStatus: "Stopped by you")
        #expect(recovery.isStopped(task: "Rippa Repair"))
        recovery.observe(task: "Rippa Repair", status: "working", latestTurnStatus: "sent")
        #expect(!recovery.isStopped(task: "Rippa Repair"))
        recovery.observe(task: "Rippa Repair", status: "Interrupted", latestTurnStatus: "Stopped")
        #expect(recovery.isStopped(task: "Rippa Repair"))
    }

    @Test func legacyConfigCannotTreatStoppedCardsAsRecoverableInterruptions() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(
            #"{"interruptedStatuses":["interrupted","cut off","stopped","stopped by you","paused"]}"#.utf8))
        for status in ["Stopped", "Stopped by you", "Paused"] {
            #expect(Matcher.interruptedCardTask("Rippa Repair, \(status)", config: config) == nil)
        }
        #expect(Matcher.interruptedCardTask("Rippa Repair, Interrupted", config: config) == "Rippa Repair")
        #expect(Matcher.interruptedCardTask("Rippa Repair, cut off", config: config) == "Rippa Repair")
        #expect(TaskRow.resumable(["Rippa Repair, Stopped", "Other, working"]) == ["Other"])
    }
}
