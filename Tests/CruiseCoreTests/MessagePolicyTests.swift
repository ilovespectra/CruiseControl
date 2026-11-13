import Foundation
import Testing
@testable import CruiseCore

struct MessagePolicyTests {
    @Test func mergeAlwaysUsesWorkBranchAndMigratesLegacyMain() throws {
        #expect(TaskMergeTarget.allCases == [.doNotMerge, .selectedBranch])
        var plan = try JSONDecoder().decode(TaskPlan.self, from: Data(
            #"{"finishMergeTarget":"main","finishMergeBranch":"wrong","workBranch":"release/current"}"#.utf8))
        #expect(plan.finishMergeTarget == .selectedBranch)
        var project = TaskProject()
        project.directory = "/tmp/workspace"
        for agent in ["HeyClicky", "VS Code"] {
            let instructions = TaskWorkflow.instructions(project: project, plan: plan, agentName: agent) ?? ""
            #expect(instructions.contains("merge associated task branches to release/current"))
            #expect(!instructions.contains("wrong"))
            #expect(!instructions.contains("branches to main"))
        }
        let key = TaskWorkflow.finishRequestKey(project: project, plan: plan)
        plan.finishMergeBranch = "another-obsolete-destination"
        #expect(TaskWorkflow.finishRequestKey(project: project, plan: plan) == key)
    }
    @Test func vscodeUsesConfirmedWorkspaceWithoutBuildChoiceOrCacheInstructions() {
        var plan = TaskPlan()
        plan.deliveryStyle = .commit
        plan.branchStrategy = .main
        plan.workBranch = "main"
        plan.finishMergeTarget = .doNotMerge
        var project = TaskProject()
        project.directory = "/tmp/workspace"
        #expect(TaskWorkflow.messageBlocker(project: project, plan: plan, requiresBuildLocation: false) == nil)
        #expect(TaskWorkflow.messageBlocker(project: TaskProject(), plan: plan, requiresBuildLocation: false) != nil)
        #expect(TaskWorkflow.messageBlocker(project: project, plan: plan) != nil)
        for build in [nil, TaskBuildLocation.heyClickyCache, .localWorkspace] {
            plan.buildLocation = build
            let instructions = TaskWorkflow.instructions(project: project, plan: plan, agentName: "VS Code") ?? ""
            #expect(instructions.contains("Build location: local workspace at /tmp/workspace"))
            #expect(!instructions.contains("ClickyCache"))
            #expect(!instructions.contains("Build location: not selected"))
        }
    }
    @Test func everyChoiceAndFolderAreRequiredForMessages() {
        var plan = TaskPlan()
        var project = TaskProject()
        project.directory = "/tmp/project"
        #expect(TaskWorkflow.messageBlocker(project: project, plan: plan) != nil)
        plan.buildLocation = .localWorkspace
        plan.deliveryStyle = .commit
        plan.branchStrategy = .main
        plan.workBranch = "main"
        plan.finishMergeTarget = .doNotMerge
        #expect(TaskWorkflow.messageBlocker(project: project, plan: plan) == nil)
        #expect(TaskWorkflow.messageBlocker(project: TaskProject(), plan: plan) != nil)
        plan.finishMergeTarget = .selectedBranch
        #expect(TaskWorkflow.messageBlocker(project: project, plan: plan) == nil)
        plan.finishMergeBranch = "release"
        #expect(TaskWorkflow.messageBlocker(project: project, plan: plan) == nil)
    }

    @Test func existingDraftCannotBypassMissingChoices() {
        let blocker = TaskBlocker("Complete workflow choices.", fix: .defineDone)
        let flow = TaskFlow(hasFolder: true, hasDefinition: true, reviewed: true,
                            draftBlocker: blocker, hasDraft: true)
        #expect(!flow.state(.draft).isEnabled)
        #expect(!flow.state(.send).isEnabled)
        #expect(flow.state(.review).isEnabled)
        #expect(flow.state(.send).fix == .defineDone)
    }
}
