import Testing
import Foundation
@testable import CruiseCore

@Suite struct WorkflowChoiceTests {
    @Test func plainFolderNeedsNoGitPolicies() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var project = TaskProject()
        project.directory = folder.path
        var plan = TaskPlan()
        #expect(TaskWorkflow.messageBlocker(project: project, plan: plan) != nil)
        #expect(TaskWorkflow.messageBlocker(project: project, plan: plan, requiresBuildLocation: false) == nil)
        plan.buildLocation = .localWorkspace
        #expect(TaskWorkflow.messageBlocker(project: project, plan: plan) == nil)
        let before = TaskWorkflow.finishRequestKey(project: project, plan: plan)
        plan.commitPendingOnFinish = true
        plan.workBranch = "old-branch"
        plan.deliveryStyle = .pullRequest
        #expect(TaskWorkflow.instructions(project: project, plan: plan)?.contains("Ignore any stale") == true)
        #expect(TaskWorkflow.finishCommitMessage(taskName: "Local", project: project, plan: plan) == nil)
        var config = Config()
        config.continueUntilDefinedDone = true
        config.vscodeAutoBumpChatKeys.insert("local")
        config.vscodeTaskProjects["local"] = project
        #expect(!TaskPlanning.vscodeAutoBumpEnabled(chatKey: "local", config: config))
        config.vscodeDefinitionsOfDone["local"] = "Verify the files"
        #expect(TaskPlanning.vscodeAutoBumpEnabled(chatKey: "local", config: config))
        config.clickyDefinitionsOfDone["local"] = "Verify the files"
        config.taskPlans["local", default: TaskPlan()].autoBump = true
        config.taskPlans["local"]?.buildLocation = .localWorkspace
        let target = PendingMessage.CompletionTarget(taskID: "local", definition: "Verify the files",
                                                     reportFingerprint: "report", workspace: folder.path)
        let pending = PendingMessage(task: "Local", text: "Continue", transcript: [], completionTarget: target)
        #expect(pending.automationAllowed(config: config))
        let restored = try JSONDecoder().decode(PendingMessage.self, from: JSONEncoder().encode(pending))
        #expect(restored.completionTarget?.workspace == folder.path)
        config.clickyDefinitionsOfDone["local"] = nil
        #expect(!pending.automationAllowed(config: config))
        config.clickyDefinitionsOfDone["local"] = "Verify the files"
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
        #expect(!pending.automationAllowed(config: config))
        #expect(!TaskPlanning.vscodeAutoBumpEnabled(chatKey: "local", config: config))
        #expect(TaskWorkflow.messageBlocker(project: project, plan: TaskPlan()) != nil)
        #expect(TaskWorkflow.finishRequestKey(project: project, plan: TaskPlan()) != before)
    }

    @Test func plainFolderBuildDestinationsPersistAndGuideAgents() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var project = TaskProject()
        project.directory = folder.path
        var plan = TaskPlan()
        plan.buildLocation = .externalFolder
        #expect(TaskWorkflow.messageBlocker(project: project, plan: plan) != nil)
        plan.externalBuildDirectory = folder.path
        #expect(TaskWorkflow.messageBlocker(project: project, plan: plan) == nil)
        #expect(TaskWorkflow.instructions(project: project, plan: plan)?.contains("user-selected external folder at \(folder.path)") == true)
        let restored = try JSONDecoder().decode(TaskPlan.self, from: JSONEncoder().encode(plan))
        #expect(restored == plan)
        let externalKey = TaskWorkflow.finishRequestKey(project: project, plan: plan)
        plan.buildLocation = .heyClickyCache
        #expect(TaskWorkflow.finishRequestKey(project: project, plan: plan) != externalKey)
        #expect(TaskWorkflow.instructions(project: project, plan: plan, clickyCacheLocations: ["/task/cache"])?.contains("/task/cache") == true)
        let vscode = TaskWorkflow.instructions(project: project, plan: plan, agentName: "VS Code")
        #expect(vscode?.contains("Build location: local workspace at \(folder.path)") == true)
        #expect(vscode?.contains("ClickyCache") == false)
        plan.externalBuildDirectory = "/missing/\(UUID().uuidString)"
        plan.buildLocation = .externalFolder
        #expect(TaskWorkflow.messageBlocker(project: project, plan: plan) != nil)
    }

    @Test func repositoryDetectionIncludesParentsAndWorktreeFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let child = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!TaskWorkspaceGit.isRepository(child.path))
        try "gitdir: /some/worktree".write(to: root.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(TaskWorkspaceGit.isRepository(root.path))
        #expect(TaskWorkspaceGit.isRepository(child.path))
        #expect(TaskWorkflow.autoBumpBlocker(plan: TaskPlan(), workspace: child.path) != nil)
    }

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
