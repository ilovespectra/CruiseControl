import Testing
@testable import CruiseCore

@Suite struct WorkflowChoiceTests {
    @Test func autoBumpRequiresEveryWorkflowChoice() {
        var plan = TaskPlan()
        #expect(TaskWorkflow.autoBumpBlocker(plan: plan) != nil)
        plan.buildLocation = .localWorkspace
        plan.deliveryStyle = .pullRequest
        plan.branchStrategy = .featureBranch
        plan.workBranch = "feature/game"
        #expect(TaskWorkflow.autoBumpBlocker(plan: plan) != nil)
        plan.finishMergeTarget = .doNotMerge
        #expect(TaskWorkflow.autoBumpBlocker(plan: plan) == nil)
        plan.finishMergeTarget = .selectedBranch
        #expect(TaskWorkflow.autoBumpBlocker(plan: plan) == nil)
        plan.finishMergeBranch = "main"
        #expect(TaskWorkflow.autoBumpBlocker(plan: plan) == nil)
        plan.workBranch = " "
        #expect(TaskWorkflow.autoBumpBlocker(plan: plan) != nil)
    }

    @Test func legacyVSCodeOptInCannotBypassWorkflowChoices() {
        var config = Config()
        config.continueUntilDefinedDone = true
        config.vscodeAutoBumpChatKeys.insert("chat")
        config.vscodeDefinitionsOfDone["chat"] = "Build the game"
        #expect(!TaskPlanning.vscodeAutoBumpEnabled(chatKey: "chat", config: config))
        var plan = TaskPlan()
        plan.buildLocation = .localWorkspace
        plan.deliveryStyle = .commit
        plan.branchStrategy = .main
        plan.workBranch = "main"
        plan.finishMergeTarget = .doNotMerge
        config.vscodeTaskPlans["chat"] = plan
        #expect(TaskPlanning.vscodeAutoBumpEnabled(chatKey: "chat", config: config))
        config.vscodeAutoBumpChatKeys.remove("chat")
        #expect(!TaskPlanning.vscodeAutoBumpEnabled(chatKey: "chat", config: config))
        config.vscodeTaskBumps = true
        config.autoSelectVSCodeModel = true
        #expect(!TaskPlanning.vscodeAutoBumpEnabled(chatKey: "chat", config: config))
    }

    @Test func explicitBuildChoiceNeedsUserEvenWithImplicitYes() {
        let report = """
        Added a playable rainbow-court game, its Cruise menu entry, and focused unit tests.
        Swift syntax checks pass, but I haven't built or run it because the build location is still unselected.
        Which location should I use for the build and test: HeyClicky ClickyCache or the local workspace?
        """
        #expect(TaskAudit.requiresUser(report))
        #expect(TaskAudit.requiresUser(report, implicitYes: true))
    }

    @Test func statusAndContinuationAreNotWorkflowChoices() {
        #expect(!TaskAudit.hasUnresolvedWorkflowChoice("Built and tested in the local workspace. All tests pass."))
        #expect(!TaskAudit.hasUnresolvedWorkflowChoice("The build location is the local workspace. Shall I continue?"))
        #expect(!TaskAudit.hasUnresolvedWorkflowChoice("Which files implement the paddle? Inspect the local workspace."))
    }

    @Test func branchAndDeliveryChoicesNeedUser() {
        #expect(TaskAudit.requiresUser("Should I use a dedicated branch or one shared branch?", implicitYes: true))
        #expect(TaskAudit.requiresUser("Do you want a pull request or commit and push?", implicitYes: true))
        #expect(TaskAudit.requiresUser("Full build and test — waiting on your build-location choice.", implicitYes: true))
    }
}
