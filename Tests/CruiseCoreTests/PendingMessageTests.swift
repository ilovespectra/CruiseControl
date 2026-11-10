import Foundation
import Testing
@testable import CruiseCore

@Suite struct PendingMessageTests {
    private let message = PendingMessage(task: "Portfolio Scribe", text: "Cruise Control follow-up: finish testing.", transcript: ["report"])

    @Test func onlyTranscriptEvidenceConfirmsDelivery() {
        #expect(message.delivery(selectedTask: message.task, input: "", transcript: ["report", message.text]) == .delivered)
        #expect(message.delivery(selectedTask: message.task, input: "", transcript: ["report"]) == .ready)
        #expect(message.delivery(selectedTask: message.task, input: nil, transcript: ["report", message.text]) == .held)
        #expect(message.delivery(selectedTask: "Other", input: "", transcript: ["report", message.text]) == .held)
    }

    @Test func retriesOnlyItsOwnUnchangedDraft() {
        #expect(message.delivery(selectedTask: message.task, input: message.text, transcript: [message.text, "report"]) == .ready)
        #expect(message.delivery(selectedTask: message.task, input: "User draft", transcript: ["report"]) == .held)
        #expect(message.delivery(selectedTask: message.task, input: "", transcript: ["new report"]) == .superseded)
        #expect(message.delivery(selectedTask: message.task, input: message.text, transcript: [message.text, "report", "new report"]) == .superseded)
    }

    @Test func priorIdenticalMessageIsNotNewDelivery() {
        let repeated = PendingMessage(task: message.task, text: message.text, transcript: ["report", message.text])
        #expect(repeated.delivery(selectedTask: message.task, input: "", transcript: repeated.transcript) == .ready)
        #expect(repeated.delivery(selectedTask: message.task, input: message.text, transcript: [message.text] + repeated.transcript) == .ready)
    }

    @Test func survivesRestart() throws {
        let restored = try JSONDecoder().decode(PendingMessage.self, from: JSONEncoder().encode(message))
        #expect(restored == message)
        #expect(restored.delivery(selectedTask: message.task, input: "", transcript: ["report"]) == .ready)
    }

    @Test func uncertainSubmissionIsNeverRepeatedAfterRestart() throws {
        var attempted = message
        attempted.submissionAttempted = true
        let restored = try JSONDecoder().decode(PendingMessage.self, from: JSONEncoder().encode(attempted))
        #expect(restored.delivery(selectedTask: message.task, input: "", transcript: ["report"]) == .held)
        #expect(restored.delivery(selectedTask: message.task, input: message.text, transcript: [message.text, "report"]) == .ready)
        #expect(restored.delivery(selectedTask: message.task, input: "", transcript: ["report", message.text]) == .delivered)
        #expect(restored.delivery(selectedTask: message.task, input: "", transcript: ["report", "User continued manually"]) == .superseded)
    }

    @Test func staleMessagesExpire() {
        let old = PendingMessage(task: "T", text: "x", transcript: [], createdAt: Date(timeIntervalSinceNow: -PendingMessage.maxAge - 1))
        #expect(old.isExpired())
        #expect(!message.isExpired())
    }

    @Test func heldMessageSurvivesRestartWithoutBeingResentOrLost() throws {
        var pending = message
        pending.hold("Conversation moved on")
        let restored = try JSONDecoder().decode(PendingMessage.self, from: JSONEncoder().encode(pending))
        #expect(restored.text == message.text)
        #expect(restored.holdReason == "Conversation moved on")
        #expect(restored.delivery(selectedTask: message.task, input: message.text, transcript: [message.text, "report"]) == .held)
        #expect(restored.delivery(selectedTask: message.task, input: "", transcript: ["report", message.text]) == .delivered)
    }

    @Test func oldDeliveryRecordWithoutHoldFieldRemainsReadable() throws {
        let data = Data(#"{"task":"Portfolio Scribe","text":"go","transcript":["report"],"createdAt":0,"submissionAttempted":false}"#.utf8)
        let restored = try JSONDecoder().decode(PendingMessage.self, from: data)
        #expect(restored.holdReason == nil)
        #expect(restored.text == "go")
    }

    @Test func releaseRequestIsRetriedAfterDraftLossButNeverOnAnotherTask() throws {
        let text = "Please open the Cruise Control dev console on your end and bump to the next version. Once done, test if the updates are displayed correctly on the cruise.kolektivkrog.si landing page and within the cruisecontrol app itself. Report the results and any issues for further action."
        let pending = PendingMessage(task: "Release Console", text: text,
            transcript: ["Message Release Console…", "Latest release report"])
        let restored = try JSONDecoder().decode(PendingMessage.self, from: JSONEncoder().encode(pending))
        #expect(restored.delivery(selectedTask: "Release Console", input: text,
            transcript: [text, "Latest release report"]) == .ready)
        #expect(restored.delivery(selectedTask: "Release Console", input: "",
            transcript: ["Message Release Console…", "Latest release report"]) == .ready)
        #expect(restored.delivery(selectedTask: "Other", input: "",
            transcript: ["Latest release report"]) == .held)
        #expect(restored.delivery(selectedTask: "Release Console", input: "",
            transcript: ["Latest release report", text]) == .delivered)
    }

    @Test func trimmedTranscriptHistoryIsNotNewActivity() {
        let long = (0..<60).map { "line \($0)" }
        let pending = PendingMessage(task: "T", text: "go", transcript: long)
        #expect(pending.delivery(selectedTask: "T", input: "go", transcript: ["go"] + long.dropFirst(30)) == .ready)
        #expect(pending.delivery(selectedTask: "T", input: "", transcript: Array(long.dropFirst(30)) + ["go "]) == .delivered)
    }

    @Test func composerPlaceholderOnlyShownWhenEmptyIsIgnored() {
        let pending = PendingMessage(task: "Portfolio Scribe", text: "go", transcript: ["Message Portfolio Scribe…", "report"])
        #expect(pending.delivery(selectedTask: "Portfolio Scribe", input: "go", transcript: ["go", "report"]) == .ready)
        #expect(pending.delivery(selectedTask: "Portfolio Scribe", input: "", transcript: ["Message Portfolio Scribe…", "report"]) == .ready)
        #expect(pending.delivery(selectedTask: "Portfolio Scribe", input: "", transcript: ["Message Portfolio Scribe…", "report", "go"]) == .delivered)
    }
}
