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

    @Test func followUpReceiptToleratesMarkdownRendering() {
        let message = "Target VS Code task: demo\n\nCruise Control follow-up: **verify** these:\n- build the `breakout` game"
        let rendered = "Old report\nTarget VS Code task: demo Cruise Control follow-up: verify these: build the breakout game"
        #expect(VSCodeChatIdentity.confirmsFollowUp(message, before: "Old report", after: rendered))
    }

    @Test func latestTurnIgnoresRowsScrolledOutOfTheTop() {
        let older = String(repeating: "earlier exchange about persistence. ", count: 20)
        let latest = "Agent: I fixed the pending message store and verified relaunch restores it; all tests pass."
        #expect(VSCodeChatIdentity.sameLatestTurn(older + latest, latest))
        #expect(!VSCodeChatIdentity.sameLatestTurn(older + latest, latest + "\nAgent: new response arrived with more work"))
    }

    @Test func keyIgnoresWorkspaceHeadersAndWindowTitles() {
        let key = VSCodeChatIdentity.stableKey(bundleIdentifier: "com.microsoft.VSCode", taskTitle: "message persistence issue")
        #expect(key == VSCodeChatIdentity.stableKey(bundleIdentifier: "com.microsoft.VSCode", taskTitle: "Message  persistence issue"))
        #expect(key != VSCodeChatIdentity.stableKey(bundleIdentifier: "com.microsoft.VSCode", taskTitle: "other chat"))
        #expect(key != VSCodeChatIdentity.legacyKey(bundleIdentifier: "com.microsoft.VSCode", workspace: nil,
                                                    windowTitle: "README.md — CruiseControl", taskTitle: "message persistence issue"))
    }

    @Test func savedSettingsMoveToCurrentKeyWithoutOverwriting() {
        var config = Config()
        config.vscodeDefinitionsOfDone = ["old": "breakout", "taken": "keep"]
        config.vscodeAutoBumpChatKeys = ["old"]
        config.vscodeAutoBumpRounds = ["old": 2]
        config.vscodeTaskProjects = ["old": TaskProject()]
        let moved = config.adoptVSCodeSettings(from: "old", to: "new")
        #expect(moved)
        #expect(config.vscodeDefinitionsOfDone == ["new": "breakout", "taken": "keep"])
        #expect(config.vscodeAutoBumpChatKeys == ["new"])
        #expect(config.vscodeAutoBumpRounds == ["new": 2])
        #expect(config.vscodeTaskProjects["new"] != nil && config.vscodeTaskProjects["old"] == nil)
        let same = config.adoptVSCodeSettings(from: "new", to: "new")
        #expect(!same)

        config.vscodeDefinitionsOfDone["older"] = "stale"
        let overwrite = config.adoptVSCodeSettings(from: "older", to: "taken")
        #expect(!overwrite)
        #expect(config.vscodeDefinitionsOfDone["taken"] == "keep")
    }
}
