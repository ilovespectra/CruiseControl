import Foundation
import Testing
@testable import CruiseCore

@Suite struct DoneEvidenceTests {
    let breakout = "i want to play a game of breakout that looks like the slovenian flag"

    @Test func unrelatedReportLacksEvidence() {
        let report = "Fixed message persistence: pending messages are now saved to disk and restored on relaunch. Tests pass."
        #expect(DefinitionOfDone.reportLacksEvidence(definition: breakout, report: report))
    }

    @Test func reportCoveringTheGoalHasEvidence() {
        let report = "Built a Breakout game in breakout.py with Slovenian flag colors (white, blue, red) and the flag crest. Play with `python3 breakout.py`."
        #expect(!DefinitionOfDone.reportLacksEvidence(definition: breakout, report: report))
    }

    @Test func keyTermsDropFillerAndShortWords() {
        #expect(DefinitionOfDone.keyTerms(breakout) == ["play", "game", "breakout", "slovenian", "flag"])
        #expect(!DefinitionOfDone.reportLacksEvidence(definition: nil, report: "anything"))
    }
}
