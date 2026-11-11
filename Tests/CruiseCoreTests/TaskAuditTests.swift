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

    @Test func definitionFollowUpMustRequestActionRatherThanRestateGap() {
        #expect(TaskAudit.definitionFollowUpIsActionable("Cruise Control follow-up: Cruise Audio Mixer: Please build and verify the volume controls."))
        #expect(!TaskAudit.definitionFollowUpIsActionable("Cruise Control follow-up: Cruise Audio Mixer: The volume controls have not been built or verified."))
        #expect(!TaskAudit.definitionFollowUpIsActionable("Cruise Control follow-up: Cruise Audio Mixer: Please note the controls are incomplete."))
        #expect(!TaskAudit.definitionFollowUpIsActionable("Cruise Control follow-up: Cruise Audio Mixer: Please enable System Audio Recording Only access before live testing and verify the controls."))
        #expect(!TaskAudit.definitionFollowUpIsActionable("Cruise Control follow-up: Cruise Audio Mixer: Please grant microphone access and test."))
        #expect(TaskAudit.definitionFollowUpIsActionable("Cruise Control follow-up: Cruise Audio Mixer: Please verify the controls with current grants and report any blocker."))
    }

    @Test func doesNotReviveUserBlockedOrPublishingTasks() {
        #expect(TaskAudit.requiresUser("Can you make the @heyclicky composer available?"))
        #expect(TaskAudit.requiresUser("Brave is signed into @iLoveSpectra."))
        #expect(TaskAudit.requiresUser("Proceed with upload and publish the post once."))
        #expect(!TaskAudit.requiresUser("The position reader is source-only. Automated recording and export remain unverified."))
    }

    @Test func historicalAssetPublicationDoesNotBlockMissingDeliverables() {
        #expect(!TaskAudit.requiresUser("No app releases or drafts were published."))
        #expect(!TaskAudit.requiresUser("Neither app has matching published installer assets; drafts are excluded."))
        #expect(TaskAudit.requiresUser("Please approve the published installer assets before we continue."))
        #expect(TaskAudit.requiresUser("We need your approval to publish the release."))
        #expect(TaskAudit.requiresUser("No app releases were published. Please sign in to continue."))
    }

    @Test func conditionalFuturePermissionIsNotMisclassifiedAsCurrentBlocker() {
        let hypothetical = "If macOS requests System Audio Recording Only access, enable it before live testing."
        #expect(!TaskAudit.requiresUser(hypothetical))
        #expect(!TaskAudit.requiresUser("The controls are not implemented or tested yet. \(hypothetical)"))
        #expect(TaskAudit.requiresUser("macOS is requesting System Audio Recording Only access now."))
        #expect(TaskAudit.requiresUser("The app cannot continue until you grant microphone permission."))
        #expect(TaskAudit.requiresUser("\(hypothetical) The actual permission prompt is open and requires your approval."))
        #expect(!TaskAudit.requiresUser("If permission is needed, pause then. Implementation remains unverified."))
        #expect(!TaskAudit.requiresUser("The permission is needed for macOS process-audio capture; the design does not require a virtual driver. No install or permission change has been made."))
        #expect(TaskAudit.requiresUser("Permission is needed now; cannot continue until you approve the prompt."))
        #expect(!TaskAudit.requiresUser("The approved landing-page changes are **pushed to `main`** as `24ca211`. Live verification is still pending."))
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

    @Test func cruiseTreatsClosingQuestionAsYesWhenWorkRemains() {
        let report = """
        The six site-counter changes remain on main; app-source pushes, new packages, and live-page checks are still pending. \
        I couldn't continue the repository and website work in this turn.
        The job stopped without pushing app changes, building packages, or testing live pages.
        It gave no stopping reason or recovery attempt; shall I retry in smaller checkpoints?
        """
        let evidence = TaskAudit.unfinishedEvidence(report)
        #expect(evidence.contains { $0.contains("still pending") })
        #expect(evidence.contains { $0.contains("couldn't continue") })
        #expect(evidence.allSatisfy { report.contains($0) })
        #expect(!TaskAudit.requiresUser("Could you confirm? Tests are not run yet.", implicitYes: true))
        #expect(TaskAudit.requiresUser("Could you confirm? Tests are not run yet."))
        #expect(TaskAudit.requiresUser("Please sign in to GitHub; pushes are still pending.", implicitYes: true))

        let message = TaskAudit.implicitYesFollowUp(task: "Portfolio Scribe", evidence: evidence)
        #expect(message.hasPrefix("Cruise Control follow-up: Portfolio Scribe: Yes"))
        #expect(evidence.allSatisfy { message.contains($0) })
        let encoded = try! JSONEncoder().encode(ChatBump.Draft(unfinished: true, message: message))
        #expect(ChatBump.parse(String(decoding: encoded, as: UTF8.self)) != nil)
        #expect(!TaskAudit.requiresUser(message))
    }

    @Test func detectsEachUnfinishedPhrasing() {
        for line in [
            "The migration is unfinished.", "The icon asset is missing.", "The UI flow is incomplete.",
            "Download counts are unconfirmed.", "The release still needs a signed build.",
            "The installer was not tested.", "The fix was not pushed to GitHub.", "The suite was not run locally.",
            "I haven't made any changes to the repo.", "The download issue remains on Saturday Tube.",
            "The landing page is in the same state as before.", "I didn't change any files this turn.",
            "I made no edits to the worker.", "Saturday Tube still says sources unavailable.",
        ] {
            #expect(!TaskAudit.unfinishedEvidence(line).isEmpty, "\(line)")
        }
        #expect(TaskAudit.unfinishedEvidence("All six sites are deployed and verified live.").isEmpty)
    }

    @Test func latestTurnStartsAtTheNewestTaskCard() {
        let long = String(repeating: "Old report text. ", count: 15)
        let transcript = [long, "Old item is pending.", "— Portfolio Scribe, done, 9:04 AM —",
                          "The six site-counter changes remain on main; live-page checks are still pending."]
        let turn = TaskAudit.latestTurn(transcript, report: long)
        #expect(turn?.contains("still pending") == true)
        #expect(turn?.contains("Old item") == false)
        #expect(TaskAudit.latestTurn([long, "Then: tests not run yet."], report: long)?.contains("not run") == true)
    }
}

import Testing
@testable import CruiseCore

@Test func agentStatusQuestionsAreRoutedToHeyClicky() {
    #expect(DefinitionOfDone.isAgentStatusQuestion("Was the volume knob implemented and does it match the clicky style?"))
    #expect(!DefinitionOfDone.isAgentStatusQuestion("Which background image should be used?"))
    #expect(!DefinitionOfDone.isAgentStatusQuestion("Do you want the dark theme or the light one?"))
}

@Test func ollamaNeedsYouWithoutAUserAskIsRedirectedToHeyClicky() {
    let a = ClickyTaskAssessment(state: .needsYou, reason: "USER CRITERION requires user sign-in", meetsDefinition: false,
                                 missing: [], definition: "screenshots of each landing page", fingerprint: "f", source: "ollama (x)", assessedAt: Date())
    #expect(DefinitionOfDone.needsAgentFollowUp(a, report: "Counters are live and match GitHub totals."))
    let r = DefinitionOfDone.redirectedToAgent(a, definition: "screenshots of each landing page")
    #expect(r.state == .unfinished && !r.missing.isEmpty && r.clarificationQuestion == nil)
    #expect(!DefinitionOfDone.needsAgentFollowUp(a, report: "Please sign in to GitHub so I can continue."))
}
