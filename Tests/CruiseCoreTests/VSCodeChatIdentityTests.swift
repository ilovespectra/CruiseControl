import Testing
@testable import CruiseCore

@Suite struct VSCodeChatIdentityTests {
    @Test func supportsModernAndLegacySessionsWithoutChoosingAmbiguousTargets() {
        #expect(VSCodeChatIdentity.taskName(sessionLabels: ["Session: Current task"], legacyTask: nil) == "Current task")
        #expect(VSCodeChatIdentity.taskName(sessionLabels: [], legacyTask: "Old task") == "Old task")
        #expect(VSCodeChatIdentity.taskName(sessionLabels: ["Session: A", "Session: B"], legacyTask: nil) == nil)
        #expect(VSCodeChatIdentity.taskName(sessionLabels: ["Session: A"], legacyTask: "B") == nil)
        #expect(VSCodeChatIdentity.taskName(sessionLabels: ["Chat: not a session"], legacyTask: nil) == nil)
        #expect(VSCodeChatIdentity.taskName(sessionLabels: ["Session: "], legacyTask: nil) == nil)
    }

    @Test func followUpReceiptRequiresExactNewMessageNotJustRunningOrChangedTranscript() {
        let message = "Cruise Control follow-up: Please verify the remaining checkout test."
        #expect(VSCodeChatIdentity.confirmsFollowUp(message, before: "Old report", after: "Old report\n\(message)"))
        #expect(!VSCodeChatIdentity.confirmsFollowUp(message, before: "Old report", after: "Tool is running"))
        #expect(!VSCodeChatIdentity.confirmsFollowUp(message, before: message, after: message + "\nWorking"))
        #expect(!VSCodeChatIdentity.confirmsFollowUp("", before: "", after: "Changed"))
    }
}
