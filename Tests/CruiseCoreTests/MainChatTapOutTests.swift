import Testing
@testable import CruiseCore

@Suite struct MainChatTapOutTests {
    let tapOut = [
        "push the changes please",
        "Sent to Portfolio Scribe",
        "— Portfolio Scribe, sent, 9:03 AM —",
        "— Portfolio Scribe, done, 9:04 AM —",
        "The six site-counter changes remain on main; app-source pushes, new packages, and live-page checks are still pending. I couldn’t continue the repository and website work in this turn.",
        "The job stopped without pushing app changes, building packages, or testing live pages.",
        "It gave no stopping reason or recovery attempt; shall I retry in smaller checkpoints?",
    ]

    @Test func detectsUnansweredTapOutWithUnfinishedWork() throws {
        let found = try #require(MainChatTapOut.detect(tapOut))
        #expect(found.task == "Portfolio Scribe")
        #expect(found.status == "done")
        #expect(found.lines.count == 3)
        #expect(found.evidence.contains { $0.contains("still pending") })
    }

    @Test func ignoresAnsweredOrFinishedTurns() {
        #expect(MainChatTapOut.detect(tapOut + ["yes go ahead", "Sent to Portfolio Scribe"]) == nil)
        #expect(MainChatTapOut.detect(tapOut + ["— Portfolio Scribe, working, 9:05 AM —"]) == nil)
        #expect(MainChatTapOut.detect([
            "— Portfolio Scribe, done, 7:46 AM —",
            "All six updates are pushed to GitHub and verified on their remote branches.",
            "Want me to do anything else?",
        ]) == nil)
        #expect(MainChatTapOut.detect([
            "— Portfolio Scribe, done, 9:04 AM —",
            "The app-source pushes are still pending.",
        ]) == nil)
        #expect(MainChatTapOut.detect(["shall I retry?"]) == nil)
    }

    @Test func acceptsImageBadgeHeaders() {
        let found = MainChatTapOut.detect([
            "— Saturday Shuffle · done —",
            "Packaging was not tested and the release is still pending. Should I continue?",
        ])
        #expect(found?.task == "Saturday Shuffle")
    }

    @Test func fallbackAsksForSmallVerifiableStepsAndQuotesEvidence() throws {
        let found = try #require(MainChatTapOut.detect(tapOut))
        let reply = found.fallbackReply
        #expect(reply.hasPrefix("Yes"))
        #expect(reply.contains("Portfolio Scribe"))
        #expect(reply.contains("\"The job stopped without pushing app changes, building packages, or testing live pages.\""))
        #expect(reply.count <= 800)
        #expect(found.accepts(reply))
        #expect(!TaskAudit.requiresUser(reply))
    }

    @Test func rejectsOffTargetOllamaReplies() throws {
        let found = try #require(MainChatTapOut.detect(tapOut))
        #expect(!found.accepts("Sure!"))
        #expect(!found.accepts("Yes, please retry in smaller checkpoints and verify each step before moving on to the next one."))
        #expect(!found.accepts("Yes, the task is to portfolio scribe. Break it into small steps and verify each one before the next."))
        #expect(found.accepts("Yes, retry Portfolio Scribe in small checkpoints: push the app changes, build packages, then test live pages — verify each before the next."))
    }

    @Test func liveReleaseConsoleTapOutQuotesEveryUnfinishedLine() throws {
        let found = try #require(MainChatTapOut.detect([
            "— Release Console, done, 10:19 AM —",
            "Silo’s 2.3.9 build is unverified: the latest console attempt was still queued when last checked. No package was confirmed built or installed.",
            "Silo 2.3.9 remains unbuilt; 2 console attempts failed, and the third was queued.",
            "The site remains 2.3.7 and app 2.3.8; shall I resume from the queued attempt?",
        ]))
        #expect(found.evidence.count >= 2)
        #expect(found.fallbackReply.contains("Silo 2.3.9 remains unbuilt"))
    }
}
