import Foundation
import Testing
@testable import CruiseCore

@Suite struct TaskAuditTests {
    @Test func identifiesTaskFromComposerNotFromAnotherCard() {
        #expect(TaskAudit.composerTask("Message Rippa Repair…") == "Rippa Repair")
        #expect(TaskAudit.composerTask("Message Video Publisher...") == "Video Publisher")
        #expect(TaskAudit.composerTask("Rippa Repair, Done") == nil)
        #expect(TaskAudit.composerTask("Message …") == nil)
    }

    @Test func prioritizesTrackedTasksAndBoundsRecentHistory() {
        #expect(TaskAudit.candidates(tracked: ["Rippa Repair"], recent: [
            "Video Publisher", "Rippa Repair", "Cruise Autopilot", "Old Task"
        ]) == ["Rippa Repair", "Video Publisher", "Cruise Autopilot"])
        #expect(TaskAudit.candidates(tracked: ["Rippa Repair", "rippa repair"], recent: []) == ["Rippa Repair"])
    }

    @Test func boundsContextWithoutLosingOriginalGoalOrLatestReport() {
        let transcript = "Original recording goal\n" + String(repeating: "x", count: 20000)
            + "\nAutomated export remains unverified."
        let context = TaskAudit.context(task: "Rippa Repair", transcript: transcript)
        #expect(context.contains("Original recording goal"))
        #expect(context.contains("Automated export remains unverified."))
        #expect(context.count < 12100)
    }

    @Test func doesNotReviveUserBlockedOrPublishingTasks() {
        #expect(TaskAudit.requiresUser("Can you make the @heyclicky composer available?"))
        #expect(TaskAudit.requiresUser("Brave is signed into @iLoveSpectra."))
        #expect(TaskAudit.requiresUser("Proceed with upload and publish the post once."))
        #expect(!TaskAudit.requiresUser("The position reader is source-only. Automated recording and export remain unverified."))
    }

    @Test func auditStateSurvivesRestartAndDoesNotDuplicateUnchangedReports() throws {
        var state = ChatBump.State()
        let now = Date()
        state.observe("source only; automation unverified", now: now.addingTimeInterval(-600))
        #expect(state.eligible(now: now, quietMinutes: 5, cooldownMinutes: 5))
        state.answeredTranscript = state.transcript
        let restored = try JSONDecoder().decode(ChatBump.State.self, from: JSONEncoder().encode(state))
        #expect(!restored.eligible(now: now, quietMinutes: 5, cooldownMinutes: 5))
    }
}
