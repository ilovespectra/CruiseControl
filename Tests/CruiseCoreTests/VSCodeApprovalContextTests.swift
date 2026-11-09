import Testing
@testable import CruiseCore

@Suite struct VSCodeApprovalContextTests {
    @Test func liveCarouselInputsOverrideStaleConversationRequest() {
        let description = "Chat Confirmation Dialog Allow reading file outside of workspace? Read old.swiftShow MoreInput{\u{00a0}\"path\":\u{00a0}\"/tmp/current.swift\"\u{00a0}}See more"
        let request = VSCodeApprovalContext.dialogRequest(
            title: "Allow reading file outside of workspace?", description: description,
            requests: [#"Allow reading file outside of workspace?: {"path":"/tmp/old.swift"}"#])
        #expect(request == "Tool approval inputs (operation unspecified):\n{ \"path\": \"/tmp/current.swift\" }")
        #expect(VSCodeApprovalContext.request(matching: "Allow reading file outside of workspace?",
            in: [#"Allow reading file outside of workspace?: {"path":"/tmp/file"}"#])
            == #"Allow reading file outside of workspace?: {"path":"/tmp/file"}"#)
    }

    @Test func rejectsIncompleteLiveInputsInsteadOfReviewingAnOlderRequest() {
        for input in ["{invalid}See more", "{}See more", #"{"path":"…"}See more"#,
                      #"{"path":"x"}trailing"#, #"{"path":"x""#] {
            #expect(VSCodeApprovalContext.dialogRequest(title: "Read file",
                description: "Chat Confirmation Dialog Input\(input)",
                requests: ["Read file: old.swift"]) == nil)
        }
        let request = VSCodeApprovalContext.dialogRequest(title: "Tool",
            description: #"Chat Confirmation Dialog Input{"command":"rm\u0020-rf\u0020/"}See more"#,
            requests: [])
        #expect(request.flatMap(ApprovalReview.hardBlockReason) != nil)
    }

    @Test func carouselPreservesQuotedWhitespaceAndEscapedQuotes() {
        let request = VSCodeApprovalContext.dialogRequest(title: "Tool",
            description: "Chat Confirmation Dialog Input{\"path\":\"/tmp/a\u{00a0}b\", \"value\":\"a\\\"b\"}See more",
            requests: [])
        #expect(request?.contains("/tmp/a\u{00a0}b") == true)
        #expect(request?.contains("a\\\"b") == true)
    }

    @Test func reviewsStructuredSidebarInputsWithoutInventingToolName() {
        let input = #"{"url":"http://127.0.0.1:11434/api/tags"}"#
        #expect(VSCodeApprovalContext.sidebarRequest("Allow once: \(input)")
                == "Tool approval inputs (operation unspecified):\n\(input)")
        let unsafe = VSCodeApprovalContext.sidebarRequest(#"Allow once: {"command":"rm\u0020-rf\u0020/"}"#)
        #expect(unsafe.flatMap(ApprovalReview.hardBlockReason) != nil)
        for input in ["{}", "{invalid}", #"{"url":"http://localhost"} trailing"#] {
            #expect(VSCodeApprovalContext.sidebarRequest("Allow once: \(input)") == nil)
        }
    }

    @Test func readsFullSidebarCommandInsteadOfPreview() {
        let command = "cd /tmp/project && python3 - <<'PY'\nprint('test')\nPY"
        #expect(VSCodeApprovalContext.sidebarRequest("Allow once: \(command)") == "Run in terminal:\n\(command)")
        #expect(VSCodeApprovalContext.sidebarRequest("Allow once: swift test; rm -rf /")
                == "Run in terminal:\nswift test; rm -rf /")
        #expect(VSCodeApprovalContext.sidebarRequest("Allow once: ./scripts/build.sh") != nil)
        let unsafe = VSCodeApprovalContext.sidebarRequest("Allow once: swift test; rm -rf /")
        #expect(unsafe.flatMap(ApprovalReview.hardBlockReason) != nil)
    }

    @Test func rejectsIncompleteSidebarApprovalLabels() {
        for label in ["Allow", "Allow All", "Allow once: ", "Allow once: swift test…",
                      "Allow once: swift test...", "Allow once: Allow reading file outside of workspace?",
                      "Allow once: Run tests", "Allow once: Read file"] {
            #expect(VSCodeApprovalContext.sidebarRequest(label) == nil)
        }
        #expect(VSCodeApprovalContext.sidebarRequest("Allow once: echo " + String(repeating: "x", count: 4000)) == nil)
    }

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
