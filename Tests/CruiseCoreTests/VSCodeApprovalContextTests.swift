import Testing
@testable import CruiseCore

@Suite struct VSCodeApprovalContextTests {
    @Test func isolatesCarouselRequest() {
        let requests = ["Run in terminal: Lint: npm run lint, Run in terminal: Check types: npx tsc --noEmit"]
        #expect(VSCodeApprovalContext.request(matching: "Run in terminal: Check types", in: requests)
                == "Run in terminal: Check types: npx tsc --noEmit")
        #expect(VSCodeApprovalContext.request(matching: "Run in terminal: Lint", in: requests)
                == "Run in terminal: Lint: npm run lint")
    }

    @Test func rejectsAmbiguousAndMissingCommands() {
        #expect(VSCodeApprovalContext.request(matching: "Read file", in: ["Read file: a.swift"]) == "Read file: a.swift")
        #expect(VSCodeApprovalContext.request(matching: "Run in terminal: Test", in:
            ["Run in terminal: Test: swift test", "Run in terminal: Test: rm -rf project"]) == nil)
        #expect(VSCodeApprovalContext.request(matching: "Run in terminal: Test", in: ["Run in terminal: Test"]) == nil)
        #expect(VSCodeApprovalContext.request(matching: "", in: ["anything"]) == nil)
    }

    @Test func recognizesOnlyAttentionThreads() {
        #expect(VSCodeApprovalContext.needsAttention("Cruise Control upgrades, State: Attention Needed"))
        #expect(VSCodeApprovalContext.threadTitle("Cruise Control upgrades, updated 1 min ago, State: Attention Needed")
                == "Cruise Control upgrades")
        #expect(!VSCodeApprovalContext.needsAttention("A task, State: In Progress"))
        #expect(!VSCodeApprovalContext.needsAttention("A task, State: Completed"))
        #expect(VSCodeApprovalContext.threadTitle("CruiseControl, 2") == nil)
    }

    @Test func inlineApprovalOverridesStaleRunningStatus() {
        #expect(VSCodeApprovalContext.needsInspection("Twitter agent, State: In Progress", hasInlineApproval: true))
        #expect(!VSCodeApprovalContext.needsInspection("Twitter agent, State: In Progress", hasInlineApproval: false))
        #expect(!VSCodeApprovalContext.needsInspection("CruiseControl, 2", hasInlineApproval: true))
    }
}
