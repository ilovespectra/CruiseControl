import Foundation
import Testing
@testable import CruiseCore

struct TaskPlanningTests {
    private func answer(_ name: String, repository: String = "", confidence: Double = 0.95,
                        quote: String) throws -> ProjectInference.Answer {
        let data = try JSONSerialization.data(withJSONObject: [
            "name": name, "repository": repository, "confidence": confidence, "evidence": quote,
        ])
        return try JSONDecoder().decode(ProjectInference.Answer.self, from: data)
    }

    @Test func inferenceRequiresHighConfidenceAndLiteralConversationEvidence() throws {
        let evidence = "Please update Cruise Control documentation, not the unrelated tools."
        let strong = try answer("Cruise Control", quote: "Cruise Control documentation")
        #expect(ProjectInference.project(from: strong, evidence: evidence, known: [])?.name == "Cruise Control")
        let weak = try answer("Cruise Control", confidence: 0.89, quote: "Cruise Control documentation")
        #expect(ProjectInference.project(from: weak, evidence: evidence, known: []) == nil)
        let invented = try answer("Another Project", quote: "Cruise Control documentation")
        #expect(ProjectInference.project(from: invented, evidence: evidence, known: []) == nil)
        let fabricated = try answer("Cruise Control", quote: "Cruise Control source code repository")
        #expect(ProjectInference.project(from: fabricated, evidence: evidence, known: []) == nil)
        let impossible = try answer("Cruise Control", confidence: 1.1, quote: "Cruise Control documentation")
        #expect(ProjectInference.project(from: impossible, evidence: evidence, known: []) == nil)
        let generic = try answer("Documentation", quote: "Update Documentation for the release.")
        #expect(ProjectInference.project(from: generic, evidence: "Update Documentation for the release.", known: []) == nil)
    }

    @Test func projectAndGitHubAreOneEntityAndKnownLabelsAreReused() throws {
        var known = TaskProject()
        known.name = "Cruise Control"
        known.repository = "ilovespectra/CruiseControl"
        let evidence = "Working in https://github.com/ilovespectra/CruiseControl"
        let result = ProjectInference.project(
            from: try answer("Some invented label", repository: "ilovespectra/CruiseControl", quote: evidence),
            evidence: evidence, known: [known])
        #expect(result == known)
        let nameOnlyQuote = "Please update Cruise Control documentation."
        let knownIdentity = try answer("Cruise Control", repository: "ilovespectra/CruiseControl", quote: nameOnlyQuote)
        #expect(ProjectInference.project(from: knownIdentity, evidence: nameOnlyQuote, known: [known]) == known)
        let wrongOwner = try answer("Cruise Control", repository: "other/CruiseControl", quote: evidence)
        #expect(ProjectInference.project(from: wrongOwner, evidence: evidence, known: [known]) == nil)
        let newName = try answer("DumDev", repository: "invented/dumdev", quote: "Please open DumDev's console.")
        let nameOnly = ProjectInference.project(from: newName, evidence: "Please open DumDev's console.", known: [])
        #expect(nameOnly?.name == "DumDev")
        #expect(nameOnly?.repository.isEmpty == true)
        var other = known
        other.repository = "other/CruiseControl"
        let ambiguous = try answer("Cruise Control", quote: "Cruise Control documentation")
        #expect(ProjectInference.project(from: ambiguous, evidence: "Cruise Control documentation", known: [known, other]) == nil)
    }

    @Test func differentOwnersWithIdenticalProjectNamesNeverMerge() {
        var catalog = TaskCatalog()
        for owner in ["one", "two"] {
            catalog.observe(name: owner, status: "done")
            var project = TaskProject()
            project.name = "SharedName"
            project.repository = "\(owner)/SharedName"
            catalog.assign(project, to: owner)
        }
        let groups = catalog.groups(by: .project, sort: .name)
        #expect(groups.count == 2)
        #expect(Set(groups.map { $0.project.repositoryName }) == ["one/SharedName", "two/SharedName"])
    }

    @Test func inferencePersistsButNeverOverwritesManualCorrectionsOrUnspecifiedChoice() throws {
        let task = ClickyTasksTests.task()
        var catalog = TaskCatalog()
        try catalog.synchronize([task])
        var inferred = TaskProject()
        inferred.name = "Inferred"
        let fingerprint = ProjectInference.fingerprint(for: task)
        catalog.infer(inferred, for: task.id, fingerprint: fingerprint, model: "local")
        var restored = try JSONDecoder().decode(TaskCatalog.self, from: JSONEncoder().encode(catalog))
        try restored.synchronize([task])
        #expect(restored.tasks.first?.project.name == "Inferred")
        #expect(restored.tasks.first?.inferenceFingerprint == fingerprint)
        restored.assign(TaskProject(), to: task.id)
        restored.infer(inferred, for: task.id, fingerprint: "two", model: "local")
        #expect(restored.tasks.first?.project.title == nil)
        #expect(restored.tasks.first?.projectAssigned == true)
        restored.resetProject(for: task.id)
        restored.infer(nil, for: task.id, fingerprint: "three", model: "local")
        #expect(restored.tasks.first?.projectAssigned == false)
        #expect(restored.tasks.first?.project.title == nil)
        #expect(restored.tasks.first?.inferenceFingerprint == "three")
    }

    @Test func staleAutomaticLabelsAreRemovedBeforeReclassificationButUserAssignmentsSurvive() throws {
        var task = ClickyTasksTests.task()
        var catalog = TaskCatalog()
        try catalog.synchronize([task])
        var project = TaskProject()
        project.name = "Previous project"
        catalog.infer(project, for: task.id, fingerprint: "obsolete-classifier", model: "local")
        try catalog.synchronize([task])
        #expect(catalog.tasks.first?.project.title == nil)
        #expect(catalog.tasks.first?.inferredBy == nil)
        catalog.assign(project, to: task.id)
        task.projectEvidence = ["A different project was mentioned."]
        try catalog.synchronize([task])
        #expect(catalog.tasks.first?.project == project)
        #expect(catalog.tasks.first?.projectAssigned == true)
    }

    @Test func allTasksCanKeepOriginalOrder() {
        var catalog = TaskCatalog()
        for name in ["Z", "A", "B"] { catalog.observe(name: name, status: "done") }
        #expect(catalog.groups(by: .none, sort: .sourceOrder)[0].tasks.map(\.name) == ["Z", "A", "B"])
    }

    @Test func taskBumpContextUsesHeyClickyLabelsDefinitionAndCurrentReport() {
        var task = ClickyTasksTests.task("The app bundle has not been rebuilt or verified.", name: "Cruise Docs Scribe")
        task.prompt = "Update the Cruise Control docs and app links."
        task.latestAsk = "Finish the new task settings flow."
        task.outcome = "failed"
        var project = TaskProject()
        project.name = "Cruise Control"
        project.repository = "ilovespectra/CruiseControl"
        let prompt = TaskAudit.definitionBumpContext(task: task, definition: "Build succeeds and the new UI is verified.",
                                                     projectLabel: project.title ?? "Unassigned",
                                                     repository: project.repositoryName ?? "", priority: .high,
                                                     missing: ["The new UI is unverified"])
        #expect(prompt.contains("HEYCLICKY TASK LABEL: Cruise Docs Scribe"))
        #expect(prompt.contains("PROJECT LABEL: Cruise Control"))
        #expect(prompt.contains("ilovespectra/CruiseControl"))
        #expect(prompt.contains("CRUISE PRIORITY: High"))
        #expect(prompt.contains("Build succeeds and the new UI is verified."))
        #expect(prompt.contains("The app bundle has not been rebuilt or verified."))
        #expect(prompt.contains("The new UI is unverified"))
        #expect(TaskAudit.definitionBumpSystem.contains("Priority is only a local sorting label"))
    }

    @Test func automaticBumpRequiresGlobalAndPerTaskOptInAndDefinition() {
        let task = ClickyTasksTests.task("Tests remain incomplete.")
        var config = Config()
        config.clickyDefinitionsOfDone[task.id] = "Tests pass"
        config.taskPlans[task.id] = TaskPlan()
        config.taskPlans[task.id]?.autoBump = true
        #expect(TaskPlanning.autoBumpEnabled(task, config: config))
        config.taskPlans[task.id]?.enabled = true
        config.taskPlans[task.id]?.autoBump = false
        #expect(!TaskPlanning.autoBumpEnabled(task, config: config), "Legacy review opt-in must not turn on sending.")
        config.taskPlans[task.id]?.autoBump = true
        config.continueUntilDefinedDone = false
        #expect(!TaskPlanning.autoBumpEnabled(task, config: config))
        config.continueUntilDefinedDone = true
        config.taskPlans[task.id]?.enabled = false
        #expect(TaskPlanning.autoBumpEnabled(task, config: config), "Background-review opt-in is independent from Auto-bump opt-in.")
        config.taskPlans[task.id]?.enabled = true
        config.clickyDefinitionsOfDone[task.id] = nil
        #expect(!TaskPlanning.autoBumpEnabled(task, config: config))
    }

    @Test func manualBumpNeedsARecentSafeReportAndDoesNotNeedPersistentOptIn() {
        let task = ClickyTasksTests.task("The tests have not run.")
        var config = Config()
        config.mode = .cruise
        config.continueUntilDefinedDone = true
        config.autoContinueReports = true
        config.ollamaEnabled = true
        config.ollamaURL = "http://127.0.0.1:11434"
        config.clickyDefinitionsOfDone[task.id] = "Tests pass"
        #expect(TaskPlanning.manualBumpAvailable(task, allTasks: [task], config: config))
        config.mode = .manual
        #expect(!TaskPlanning.manualBumpAvailable(task, allTasks: [task], config: config))
        config.mode = .cruise
        config.ollamaURL = "https://example.com"
        #expect(!TaskPlanning.manualBumpAvailable(task, allTasks: [task], config: config))
        config.ollamaURL = "http://127.0.0.1:11434"
        #expect(!TaskPlanning.manualBumpAvailable(ClickyTasksTests.task("Please grant permission."), allTasks: [task], config: config))
        #expect(!TaskPlanning.manualBumpAvailable(ClickyTasksTests.task("Working", outcome: "working"), allTasks: [task], config: config))
        #expect(!TaskPlanning.manualBumpAvailable(ClickyTasksTests.task("Stopped", outcome: "stopped"), allTasks: [task], config: config))
        let duplicate = ClickyTasksTests.task("Second report", name: task.name, id: "job2")
        #expect(!TaskPlanning.manualBumpAvailable(task, allTasks: [task, duplicate], config: config))
    }

    @Test func unchangedGapsAndFailedReportsDoNotTriggerAnotherAutomaticBump() {
        let task = ClickyTasksTests.task("The tests still have not run.")
        let assessment = ClickyTaskAssessment(state: .unfinished, reason: "Tests have not run.", meetsDefinition: false,
                                              missing: ["Tests have not run"], definition: "Tests pass",
                                              fingerprint: task.fingerprint, source: "ollama (qwen)", assessedAt: Date())
        var progress = DoneProgress()
        progress.definition = "Tests pass"
        progress.lastMissing = ["Tests have not run"]
        #expect(DefinitionOfDone.hasNoProgress(assessment, progress: progress))
        #expect(!DefinitionOfDone.shouldContinue(task, definition: "Tests pass", assessment: assessment,
                                                  progress: progress, maxRounds: 8))
        var failed = assessment
        failed.state = .failed
        progress.lastMissing = nil
        #expect(!DefinitionOfDone.shouldContinue(task, definition: "Tests pass", assessment: failed,
                                                  progress: progress, maxRounds: 8))
    }

    @Test func oldTaskPlanDoesNotOptIntoAutoBumping() throws {
        let old = try JSONDecoder().decode(TaskPlan.self, from: Data(#"{"enabled":true,"priority":"high"}"#.utf8))
        #expect(old.enabled)
        #expect(old.priority == .high)
        #expect(!old.autoBump)
    }

    @Test func backgroundReviewIsIndependentOfDriveAndApprovalFeaturesButRequiresExplicitTaskOptIn() {
        let task = ClickyTasksTests.task("Tests remain incomplete.")
        var config = Config()
        config.mode = .manual
        config.autoContinueReports = false
        config.continueUntilDefinedDone = false
        config.autoAnswerSystemDialogs = false
        config.vscodeAutoApprove = false
        config.backgroundTaskReview = true
        config.clickyDefinitionsOfDone[task.id] = "Tests pass"
        #expect(!TaskPlanning.eligible(task, config: config))
        config.taskPlans[task.id] = TaskPlan()
        config.taskPlans[task.id]?.enabled = true
        #expect(TaskPlanning.eligible(task, config: config))
        #expect(config.mode == .manual && !config.vscodeAutoApprove && !config.autoAnswerSystemDialogs)
        config.mode = .rest
        #expect(TaskPlanning.eligible(task, config: config))
        config.clickyDefinitionsOfDone[task.id] = nil
        #expect(!TaskPlanning.eligible(task, config: config))
        config.clickyDefinitionsOfDone[task.id] = "Tests pass"
        config.ollamaEnabled = false
        #expect(!TaskPlanning.eligible(task, config: config))
    }

    @Test func workingStoppedDismissedEmptyAndUserBlockedTasksAreNotReviewed() {
        var config = Config()
        config.backgroundTaskReview = true
        config.taskPlans["job1"] = TaskPlan()
        config.taskPlans["job1"]?.enabled = true
        config.clickyDefinitionsOfDone["job1"] = "Tests pass"
        for task in [
            ClickyTasksTests.task("Still working", outcome: "working"),
            ClickyTasksTests.task("Stopped", outcome: "stopped"),
            ClickyTasksTests.task("unfinished", dismissed: true),
            ClickyTasksTests.task(""),
            ClickyTasksTests.task("Please enter your password to continue."),
        ] {
            #expect(!TaskPlanning.eligible(task, config: config))
        }
        config.vscodeUsageCutoff = 75
        config.vscodeObservedUsage = 80
        #expect(!TaskPlanning.eligible(ClickyTasksTests.task("Tests incomplete."), config: config))
    }

    @Test func rankedTasksUseProjectDefaultWithTaskOverrideWithoutStarvingLowerPriorities() throws {
        let tasks = ["a", "b", "c"].map { ClickyTasksTests.task("Tests incomplete.", id: $0) }
        var catalog = TaskCatalog()
        try catalog.synchronize(tasks)
        var project = TaskProject()
        project.name = "Example"
        project.repository = "owner/Example"
        catalog.assign(project, to: "a")
        catalog.assign(project, to: "b")
        var config = Config()
        config.backgroundTaskReview = true
        config.projectPriorities[project.priorityKey] = .high
        for task in tasks {
            config.clickyDefinitionsOfDone[task.id] = "Tests pass"
            config.taskPlans[task.id] = TaskPlan()
            config.taskPlans[task.id]?.enabled = true
        }
        config.taskPlans["a"]?.priority = .low
        #expect(TaskPlanning.ranked(tasks, catalog: catalog, config: config).map(\.id) == ["b", "c", "a"])
        let restored = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(restored.taskPlans == config.taskPlans)
        #expect(restored.projectPriorities == config.projectPriorities)
        #expect(restored.clickyDefinitionsOfDone == config.clickyDefinitionsOfDone)
        let old = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        #expect(!old.backgroundTaskReview && old.taskPlans.isEmpty && old.inferTaskProjects)
    }

    @Test func projectEvidenceIncludesBothSidesOfEarlierThreadAndAffectsFreshness() {
        var task = ClickyTasksTests.task()
        let before = ProjectInference.fingerprint(for: task)
        task.projectEvidence = ["User: Work on https://github.com/owner/Example", "Assistant: Checking Example."]
        let evidence = ProjectInference.evidence(for: task)
        #expect(evidence.contains("github.com/owner/Example"))
        #expect(evidence.contains("Assistant: Checking Example"))
        #expect(ProjectInference.fingerprint(for: task) != before)
    }
}
