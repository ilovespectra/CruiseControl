import Foundation
import Testing
@testable import CruiseCore

@Suite struct ClickyTasksTests {
    static let jobsJSON = """
    [
      {"id": "aaa111", "nickname": "Portfolio Scribe", "title": "Updating portfolio", "prompt": "Update the portfolio",
       "outcome": "done", "summary": "Portfolio updated", "replyText": "Pushed the portfolio to main as abc123.",
       "folderPath": "/Volumes/X/jobs/portfolio", "threadID": "t2",
       "createdAt": "2026-11-01T10:00:00Z", "finishedAt": "2026-11-01T11:00:00Z", "isDismissed": false,
       "runs": [
         {"threadID": "t1", "outcome": "done", "ask": "Update the portfolio", "startedAt": "2026-11-01T10:00:00Z", "finishedAt": "2026-11-01T10:30:00Z"},
         {"threadID": "t2", "outcome": "done", "ask": "Now push it", "startedAt": "2026-11-01T10:40:00Z", "finishedAt": "2026-11-01T11:00:00Z"}
       ]},
      {"id": "bbb222", "nickname": "Release Dock", "outcome": "working", "createdAt": "2026-11-05T09:00:00.500Z",
       "runs": [{"threadID": "t3", "ask": "Build the release", "startedAt": "2026-11-05T09:00:00Z"}]},
      {"id": "ccc333", "title": "Untitled job", "outcome": "done", "replyText": "", "summary": "",
       "createdAt": "2026-10-01T09:00:00Z", "isDismissed": true}
    ]
    """

    static func task(_ message: String = "All done and pushed to main.", outcome: String = "done", name: String = "Scribe",
                     id: String = "job1", runs: Int = 1, dismissed: Bool = false) -> ClickyAgentTask {
        ClickyAgentTask(id: id, name: name, title: "", prompt: "p", latestAsk: "Do the thing", outcome: outcome,
                        summary: "", lastMessage: message, lastMessageAt: nil, createdAt: nil, updatedAt: nil,
                        runCount: runs, messageCount: 2, threadIDs: [], folderPath: nil, dismissed: dismissed,
                        suggestedNext: [], cacheBytes: nil, folderBytes: nil)
    }

    // MARK: Reading HeyClicky's job list

    @Test func agentRootRequiresAnExplicitAbsoluteHeyClickySetting() {
        #expect(ClickyTaskLibrary.configuredAgentRoot(nil) == nil)
        #expect(ClickyTaskLibrary.configuredAgentRoot("") == nil)
        #expect(ClickyTaskLibrary.configuredAgentRoot("relative/Agent") == nil)
        #expect(ClickyTaskLibrary.configuredAgentRoot("  /Volumes/External/HeyClicky  ")?.path == "/Volumes/External/HeyClicky")
        #expect(ClickyTaskLibrary.configuredAgentRoot("~/Agents")?.path
                == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Agents").path)
    }

    @Test func buildsTasksFromJobsWithStableIDsAndNames() throws {
        let jobs = try ClickyTaskLibrary.decodeJobs(Data(Self.jobsJSON.utf8))
        let tasks = ClickyTaskLibrary.tasks(jobs: jobs, activity: [:])
        #expect(tasks.map(\.id) == ["aaa111", "bbb222", "ccc333"])
        let portfolio = tasks[0]
        #expect(portfolio.name == "Portfolio Scribe")
        #expect(portfolio.latestAsk == "Now push it")
        #expect(portfolio.prompt == "Update the portfolio")
        #expect(portfolio.threadIDs == ["t1", "t2"])
        #expect(portfolio.runCount == 2)
        #expect(portfolio.lastMessage == "Pushed the portfolio to main as abc123.")
        #expect(portfolio.createdAt == ClickyTaskLibrary.date("2026-11-01T10:00:00Z"))
        #expect(portfolio.updatedAt == ClickyTaskLibrary.date("2026-11-01T11:00:00Z"))
        #expect(tasks[1].isWorking)
        #expect(tasks[1].createdAt != nil, "fractional-second dates parse")
        #expect(tasks[2].name == "Untitled job", "falls back to the title without a nickname")
        #expect(tasks[2].dismissed)
        #expect(!tasks[2].hasReport)
    }

    @Test func newerJournalReplyReplacesOlderJobReply() throws {
        let jobs = try ClickyTaskLibrary.decodeJobs(Data(Self.jobsJSON.utf8))
        var newer = ClickyThreadActivity()
        newer.turns = 3
        newer.messages = 6
        newer.latestAssistant = "Follow-up: release verified."
        newer.latestAt = ClickyTaskLibrary.date("2026-11-02T08:00:00Z")
        newer.updatedAt = newer.latestAt
        var older = ClickyThreadActivity()
        older.turns = 1
        older.messages = 2
        older.latestAssistant = "Old reply"
        older.latestAt = ClickyTaskLibrary.date("2026-11-01T10:20:00Z")
        let task = ClickyTaskLibrary.tasks(jobs: jobs, activity: ["t1": older, "t2": newer])[0]
        #expect(task.lastMessage == "Follow-up: release verified.")
        #expect(task.messageCount == 8)
        #expect(task.runCount == 4)
        #expect(task.updatedAt == ClickyTaskLibrary.date("2026-11-02T08:00:00Z"))
    }

    @Test func readsTurnJournalAndThreadHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-tasks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("HomeSpaceCache/turn-journal/t3")
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        let turns = [
            #"{"turn":{"userMessages":["Build it"],"assistantMessages":["Building now"],"startedAt":"2026-11-05T09:00:00Z","finishedAt":"2026-11-05T09:10:00Z"}}"#,
            #"{"turn":{"userMessages":["Go on"],"assistantMessages":["Release built and verified.", " "],"startedAt":"2026-11-05T09:20:00Z","finishedAt":"2026-11-05T09:30:00Z","suggestedNextActions":["Publish"]}}"#,
        ]
        for (index, turn) in turns.enumerated() {
            try Data(turn.utf8).write(to: journal.appendingPathComponent("\(index).json"))
        }
        try Data("not json".utf8).write(to: journal.appendingPathComponent("broken.json"))
        try Data(#"[{"threadID":"t3","updatedAt":"2026-11-06T00:00:00Z"}]"#.utf8)
            .write(to: root.appendingPathComponent("HomeSpaceCache/thread-history.json"))

        let tasks = try ClickyTaskLibrary.load(jobsData: Data(Self.jobsJSON.utf8), root: root)
        let release = try #require(tasks.first { $0.id == "bbb222" })
        #expect(release.lastMessage == "Release built and verified.")
        #expect(release.messageCount == 4)
        #expect(release.runCount == 2)
        #expect(release.suggestedNext == ["Publish"])
        #expect(release.projectEvidence.contains("User: Build it"))
        #expect(release.projectEvidence.contains("Assistant: Release built and verified."))
        #expect(release.updatedAt == ClickyTaskLibrary.date("2026-11-06T00:00:00Z"))
        #expect(ClickyTaskLibrary.size(of: journal) > 0)
        #expect(ClickyTaskLibrary.cachePaths(threadIDs: ["t3"], root: root).map(\.path).contains(journal.path))
    }

    @Test func strictSizeReportsMissingItemsInsteadOfZero() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try ClickyTaskLibrary.measuredSize(of: root) == nil)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try Data(count: 10).write(to: root.appendingPathComponent("a/one"))
        try Data(count: 5).write(to: root.appendingPathComponent("a/b/two"))
        #expect(try ClickyTaskLibrary.measuredSize(of: root) == 15)
        #expect(try ClickyTaskLibrary.measuredSize(of: root.appendingPathComponent("a/one")) == 10)
    }

    @Test func sortsByEveryOrder() {
        var a = Self.task(id: "a", runs: 1)
        a.name = "beta"
        a.createdAt = Date(timeIntervalSince1970: 100)
        a.updatedAt = Date(timeIntervalSince1970: 900)
        a.cacheBytes = 10
        var b = Self.task(id: "b", runs: 5)
        b.name = "Alpha"
        b.createdAt = Date(timeIntervalSince1970: 300)
        b.updatedAt = Date(timeIntervalSince1970: 400)
        var c = Self.task(id: "c", runs: 2)
        c.name = "gamma"
        c.createdAt = Date(timeIntervalSince1970: 200)
        c.cacheBytes = 5
        c.folderBytes = 100
        let all = [a, b, c]
        #expect(ClickyTaskLibrary.sorted(all, by: .newest).map(\.id) == ["b", "c", "a"])
        #expect(ClickyTaskLibrary.sorted(all, by: .oldest).map(\.id) == ["a", "c", "b"])
        #expect(ClickyTaskLibrary.sorted(all, by: .recentlyUpdated).map(\.id) == ["a", "b", "c"])
        #expect(ClickyTaskLibrary.sorted(all, by: .longestThread).map(\.id) == ["b", "c", "a"])
        #expect(ClickyTaskLibrary.sorted(all, by: .largestCache).map(\.id) == ["c", "a", "b"])
        #expect(ClickyTaskLibrary.sorted(all, by: .name).map(\.id) == ["b", "a", "c"])
    }

    @Test func fingerprintFollowsTheReportOnly() {
        let task = Self.task()
        var same = task
        same.cacheBytes = 99
        same.messageCount = 40
        #expect(task.fingerprint == same.fingerprint)
        #expect(task.fingerprint == ClickyTaskLibrary.hash(["done", task.lastMessage, "1"].joined(separator: "\u{1F}")))
        var newReport = task
        newReport.lastMessage += " Also verified."
        #expect(task.fingerprint != newReport.fingerprint)
    }

    @Test func flagsDuplicateNamesBecauseTheSidebarHasNoJobIDs() {
        let tasks = [Self.task(name: "Docs Scribe", id: "1"), Self.task(name: "docs  scribe", id: "2"),
                     Self.task(name: "Release Dock", id: "3")]
        #expect(ClickyTaskLibrary.ambiguousNames(tasks) == [Matcher.normalize("Docs Scribe")])
    }

    // MARK: Definition of done

    @Test func parsesAValidAnswerAndKeepsUserCriteriaInsteadOfModelMissingItems() throws {
        let task = Self.task("The README is pushed but the release is not built.")
        let missing = (1...9).map { "\"item \($0) \(String(repeating: "x", count: 200))\"" } + ["\"item 1 \(String(repeating: "x", count: 200))\""]
        let raw = #"{"state":"unfinished","reason":"  Release not built.  ","meets_definition":false,"missing":[\#(missing.joined(separator: ","))],"criteria":[{"criterion":"Release built","status":"unmet","evidence":"the release is not built"}]}"#
        let assessment = try #require(DefinitionOfDone.parse(raw, task: task, definition: " Release built ", model: "m"))
        #expect(assessment.state == .unfinished)
        #expect(assessment.reason == "Release not built.")
        #expect(assessment.meetsDefinition == false)
        #expect(assessment.missing == ["Release built"])
        #expect(assessment.definition == "Release built")
        #expect(assessment.source == "ollama (m)")
        #expect(assessment.isCurrent(for: task, definition: "Release built"))
        #expect(!assessment.isCurrent(for: task, definition: "Something else"))
    }

    @Test func rejectsUnusableAnswers() {
        let task = Self.task()
        #expect(DefinitionOfDone.parse("not json", task: task, definition: nil, model: "m") == nil)
        #expect(DefinitionOfDone.parse(#"{"state":"maybe","reason":"x"}"#, task: task, definition: nil, model: "m") == nil)
        #expect(DefinitionOfDone.parse(#"{"state":"working","reason":"x"}"#, task: task, definition: nil, model: "m") == nil)
        #expect(DefinitionOfDone.parse(#"{"state":"done","reason":"  "}"#, task: task, definition: nil, model: "m") == nil)
        #expect(DefinitionOfDone.parse(#"{"state":"done","reason":"ok","missing":[]}"#, task: task, definition: "Shipped", model: "m") == nil,
                "a definition requires meets_definition")
    }

    @Test func unmetDefinitionWithoutItemsListsTheDefinition() throws {
        let raw = #"{"state":"done","reason":"Looks done.","meets_definition":false,"missing":[" "],"criteria":[{"criterion":"Download link works","status":"unknown","evidence":""}]}"#
        let assessment = try #require(DefinitionOfDone.parse(raw, task: Self.task(), definition: "Download link works", model: "m"))
        #expect(assessment.missing == ["Download link works"])
    }

    @Test func emptyReportsAreNeverDone() {
        let empty = Self.task("   ")
        let raw = #"{"state":"done","reason":"Done.","meets_definition":true,"missing":[]}"#
        #expect(DefinitionOfDone.parse(raw, task: empty, definition: "Shipped", model: "m") == nil)
        let fallback = DefinitionOfDone.fallback(task: empty, definition: "Shipped")
        #expect(fallback.state == .unknown)
        #expect(fallback.meetsDefinition == nil)
        #expect(!DefinitionOfDone.shouldContinue(empty, definition: "Shipped", assessment: fallback, progress: nil))
    }

    @Test func fallbackRulesReadTheReport() {
        #expect(DefinitionOfDone.fallback(task: Self.task("Something broke.", outcome: "failed"), definition: nil).state == .failed)
        #expect(DefinitionOfDone.fallback(task: Self.task("Please sign in to Vercel so I can deploy."), definition: nil).state == .needsYou)
        let unfinished = DefinitionOfDone.fallback(task: Self.task("Docs are written. The release is not built yet."), definition: "Released")
        #expect(unfinished.state == .unfinished)
        #expect(unfinished.meetsDefinition == false)
        #expect(unfinished.missing == ["The release is not built yet."])
        let done = DefinitionOfDone.fallback(task: Self.task(), definition: "Pushed")
        #expect(done.state == .done)
        #expect(done.meetsDefinition == nil, "rules can't prove a definition is met")
        #expect(done.source == "rules (rules)")
    }

    @Test func liveHeyClickyStatusOutranksTheReport() throws {
        let raw = #"{"state":"unfinished","reason":"Not built.","meets_definition":false,"missing":["build"],"criteria":[{"criterion":"Built","status":"unmet","evidence":"Not built."}]}"#
        let working = try #require(DefinitionOfDone.parse(raw, task: Self.task("Not built.", outcome: "working"), definition: "Built", model: "m"))
        #expect(working.state == .working)
        let stopped = DefinitionOfDone.fallback(task: Self.task("Not built.", outcome: "stopped"), definition: "Built")
        #expect(stopped.state == .stopped)
    }

    @Test func continuesOnlyForAFreshShortfall() throws {
        let task = Self.task("Docs pushed. The release is not built yet.")
        let raw = #"{"state":"unfinished","reason":"Release not built.","meets_definition":false,"missing":["Release built"],"criteria":[{"criterion":"Released","status":"unmet","evidence":"The release is not built yet."}]}"#
        let short = try #require(DefinitionOfDone.parse(raw, task: task, definition: "Released", model: "m"))
        #expect(DefinitionOfDone.shouldContinue(task, definition: "Released", assessment: short, progress: nil))
        #expect(!DefinitionOfDone.shouldContinue(task, definition: nil, assessment: short, progress: nil))
        #expect(!DefinitionOfDone.shouldContinue(task, definition: "Something else", assessment: short, progress: nil),
                "an assessment of another definition is stale")

        var progress = DoneProgress()
        progress.definition = "Released"
        progress.rounds = 1
        progress.lastFingerprint = task.fingerprint
        #expect(!DefinitionOfDone.shouldContinue(task, definition: "Released", assessment: short, progress: progress),
                "one follow-up per report")
        progress.lastFingerprint = "older"
        #expect(DefinitionOfDone.shouldContinue(task, definition: "Released", assessment: short, progress: progress))
        progress.rounds = 3
        #expect(!DefinitionOfDone.shouldContinue(task, definition: "Released", assessment: short, progress: progress, maxRounds: 3))
        progress.definition = "Older definition"
        #expect(DefinitionOfDone.shouldContinue(task, definition: "Released", assessment: short, progress: progress, maxRounds: 3),
                "editing the definition starts the count over")

        let met = try #require(DefinitionOfDone.parse(#"{"state":"done","reason":"Released.","meets_definition":true,"missing":[],"criteria":[{"criterion":"Released","status":"satisfied","evidence":"Docs pushed."}]}"#,
                                                      task: task, definition: "Released", model: "m"))
        #expect(!DefinitionOfDone.shouldContinue(task, definition: "Released", assessment: met, progress: nil))
        var needsYou = short
        needsYou.state = .needsYou
        #expect(!DefinitionOfDone.shouldContinue(task, definition: "Released", assessment: needsYou, progress: nil))
        let dismissed = Self.task("Docs pushed. The release is not built yet.", dismissed: true)
        #expect(!DefinitionOfDone.shouldContinue(dismissed, definition: "Released", assessment: short, progress: nil))
        let asksUser = Self.task("The release is not built yet; I need your approval to continue.")
        let asksUserAssessment = try #require(DefinitionOfDone.parse(raw, task: asksUser, definition: "Released", model: "m"))
        #expect(!DefinitionOfDone.shouldContinue(asksUser, definition: "Released", assessment: asksUserAssessment, progress: nil))
    }

    @Test func followUpNamesTheDefinitionMissingPartsAndRound() {
        let message = DefinitionOfDone.followUp(task: Self.task(), definition: "Release built and verified",
                                                missing: ["Release built", "Download verified"], round: 2, maxRounds: 5)
        #expect(message.contains("Scribe"))
        #expect(message.contains("“Release built and verified”"))
        #expect(message.contains("- Release built\n- Download verified"))
        #expect(message.contains("smallest next step you can verify"))
        #expect(message.contains("Round 2 of 5"))
    }

    @Test func normalizesDefinitions() {
        #expect(DefinitionOfDone.normalized(nil) == nil)
        #expect(DefinitionOfDone.normalized(" \n ") == nil)
        #expect(DefinitionOfDone.normalized(String(repeating: "a", count: 5000))?.count == DefinitionOfDone.maxDefinitionLength)
    }

    @Test func confidentDoneWithoutEvidenceIsUnprovenAndFullReportIsReviewed() throws {
        let report = String(repeating: "Context. ", count: 600) + "The installed version has not been verified."
        let task = Self.task(report)
        #expect(DefinitionOfDone.prompt(for: task, definition: "Installed version verified").contains(report))
        let raw = #"{"state":"done","reason":"Everything is complete.","meets_definition":true,"missing":[],"criteria":[{"criterion":"Installed version verified","status":"satisfied","evidence":"Version verified successfully."}]}"#
        let result = try #require(DefinitionOfDone.parse(raw, task: task, definition: "Installed version verified", model: "fixture"))
        #expect(result.meetsDefinition == false)
        #expect(result.criteria?.first?.status == .unknown)
        #expect(result.criteria?.first?.evidence == "")
        #expect(result.missing == ["Installed version verified"])
    }

    @Test func configDecodesDefinitionsOfDone() throws {
        let decoded = try JSONDecoder().decode(Config.self, from: Data(
            #"{"clickyDefinitionsOfDone":{"aaa111":"  Shipped  ","bbb222":"   "},"maxDefinitionRounds":99,"continueUntilDefinedDone":false}"#.utf8))
        #expect(decoded.clickyDefinitionsOfDone == ["aaa111": "Shipped"])
        #expect(decoded.maxDefinitionRounds == 30)
        #expect(!decoded.continueUntilDefinedDone)
        let defaults = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        #expect(defaults.clickyDefinitionsOfDone.isEmpty)
        #expect(defaults.continueUntilDefinedDone)
        #expect(defaults.maxDefinitionRounds == DefinitionOfDone.maxRounds)
        let restored = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(decoded))
        #expect(restored.clickyDefinitionsOfDone == decoded.clickyDefinitionsOfDone)
    }

    @Test func rejectsReportInventedCriteriaAndPartialDefinitionCoverage() {
        let task = Self.task("Docs pushed. The controls are not verified.")
        let wrong = #"{"state":"done","reason":"Done.","meets_definition":true,"missing":[],"criteria":[{"criterion":"Docs pushed","status":"satisfied","evidence":"Docs pushed."}]}"#
        #expect(DefinitionOfDone.parse(wrong, task: task, definition: "Controls verified", model: "fixture") == nil)
        let partial = #"{"state":"done","reason":"Done.","meets_definition":true,"missing":[],"criteria":[{"criterion":"Docs pushed","status":"satisfied","evidence":"Docs pushed."}]}"#
        #expect(DefinitionOfDone.parse(partial, task: task, definition: "Docs pushed\nControls verified", model: "fixture") == nil)
        #expect(DefinitionOfDone.userCriteria("  Volume 0–100% and independent knobs \n Styling matches Cruise  ")
                == ["Volume 0–100% and independent knobs", "Styling matches Cruise"])
        #expect(DefinitionOfDone.parse(#"{"state":"done","reason":"Done.","meets_definition":true,"criteria":[]}"#,
                                      task: task, definition: "Controls verified", model: "fixture") == nil)
    }

    @Test func ambiguityRequestsUserClarificationAndStopsBothContinuationPaths() throws {
        let task = Self.task("The controls are not verified.")
        let definition = "The controls work appropriately"
        let raw = #"{"state":"unfinished","reason":"Acceptance needs clarification.","meets_definition":false,"missing":[],"criteria":[{"criterion":"The controls work appropriately","status":"unknown","evidence":""}],"clarification_question":"Which controls and measurable volume range should be verified?"}"#
        let assessment = try #require(DefinitionOfDone.parse(raw, task: task, definition: definition, model: "fixture"))
        #expect(assessment.state == .needsYou)
        #expect(assessment.clarificationQuestion == "Which controls and measurable volume range should be verified?")
        #expect(!DefinitionOfDone.shouldContinue(task, definition: definition, assessment: assessment, progress: nil))
        #expect(TaskDraftGate.evaluate(task: task, definition: definition, assessment: assessment,
                                       finished: false, ambiguous: false) == .needsUser)
        #expect(assessment.definition == definition)
    }

    @Test func editingAmbiguousDefinitionClearsOnlyTheStaleClarificationAndRequiresFreshReview() throws {
        let task = Self.task("Implementation is ready; visual acceptance is not verified.")
        let ambiguous = "The appearance should be appropriate."
        let clarified = "Use a blue grid background."
        func review(_ definition: String, question: String) throws -> ClickyTaskAssessment {
            let json: [String: Any] = [
                "state": "unfinished", "reason": "Visual acceptance is not verified.",
                "meets_definition": false, "missing": [definition],
                "criteria": [["criterion": definition, "status": "unknown", "evidence": ""]],
                "clarification_question": question,
            ]
            return try #require(DefinitionOfDone.parse(
                String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self),
                task: task, definition: definition, model: "fixture"))
        }
        let old = try review(ambiguous, question: "Which background should be used?")
        #expect(TaskDraftGate.evaluate(task: task, definition: ambiguous, assessment: old,
                                       finished: false, ambiguous: false) == .needsUser)
        #expect(!old.isCurrent(for: task, definition: clarified))
        #expect(TaskDraftGate.evaluate(task: task, definition: clarified, assessment: old,
                                       finished: false, ambiguous: false) == .reviewLatestReport)
        let fresh = try review(clarified, question: "")
        #expect(fresh.clarificationQuestion == nil)
        #expect(TaskDraftGate.evaluate(task: task, definition: clarified, assessment: fresh,
                                       finished: false, ambiguous: false) == .ready)
        #expect(DefinitionOfDone.shouldContinue(task, definition: clarified, assessment: fresh, progress: nil))
    }

    @Test func reviewAndDraftContextsContainOnlyTheSelectedTasksGoal() {
        let task = Self.task("Previous requested work is complete.")
        let first = "Provide a printable illustrated recipe card."
        let second = "Create an interactive transit timetable."
        for (goal, unrelated) in [(first, second), (second, first)] {
            let review = DefinitionOfDone.prompt(for: task, definition: goal)
            let draft = TaskAudit.definitionBumpContext(task: task, definition: goal,
                                                       projectLabel: "Example", repository: "",
                                                       priority: .normal, missing: [goal])
            #expect(review.contains(goal))
            #expect(draft.contains(goal))
            #expect(!review.contains(unrelated))
            #expect(!draft.contains(unrelated))
            #expect(!DefinitionOfDone.system.contains(goal))
            #expect(!TaskAudit.definitionBumpSystem.contains(goal))
        }
    }

    @Test func completionRequiresCurrentLocalReviewWithEvidenceAndPreservesNotificationReceipt() throws {
        let task = Self.task("The illustrated recipe card is ready and print-tested.")
        let definition = "Provide an illustrated recipe card."
        let raw: [String: Any] = [
            "state": "done", "reason": "The requested card is ready.",
            "meets_definition": true, "missing": [],
            "criteria": [["criterion": definition, "status": "satisfied", "evidence": task.lastMessage]],
            "clarification_question": "",
        ]
        let assessment = try #require(DefinitionOfDone.parse(
            String(decoding: try JSONSerialization.data(withJSONObject: raw), as: UTF8.self),
            task: task, definition: definition, model: "fixture"))
        var notice = try #require(TaskCompletionNotice(task: task, definition: definition, assessment: assessment))
        #expect(notice.taskID == task.id)
        #expect(notice.definition == definition)
        #expect(notice.acknowledgedAt == nil)
        notice.acknowledgedAt = Date()
        #expect(try JSONDecoder().decode(TaskCompletionNotice.self, from: JSONEncoder().encode(notice)) == notice)
        #expect(TaskCompletionNotice(task: task, definition: "Another goal", assessment: assessment) == nil)
        #expect(TaskCompletionNotice(task: Self.task("Still building it.", outcome: "working"),
                                     definition: definition, assessment: assessment) == nil)
        #expect(TaskCompletionNotice(task: Self.task(task.lastMessage, dismissed: true),
                                     definition: definition, assessment: assessment) == nil)
        var rules = assessment
        rules.source = "rules"
        #expect(TaskCompletionNotice(task: task, definition: definition, assessment: rules) == nil)
        var unknown = assessment
        unknown.meetsDefinition = false
        #expect(TaskCompletionNotice(task: task, definition: definition, assessment: unknown)?.meetsDefinition == false)
        #expect(notice.meetsDefinition == true)
        var clarification = assessment
        clarification.clarificationQuestion = "Which format?"
        #expect(TaskCompletionNotice(task: task, definition: definition, assessment: clarification)?.meetsDefinition == false)
        var old = assessment
        old.reviewVersion = nil
        #expect(TaskCompletionNotice(task: task, definition: definition, assessment: old) == nil)
    }

    @Test func liveStatusChangesInvalidateReviewsEvenWithoutANewReport() throws {
        let definition = "Provide a printable card."
        let task = Self.task("The printable card is ready.")
        let raw = #"{"state":"done","reason":"Ready.","meets_definition":true,"missing":[],"criteria":[{"criterion":"Provide a printable card.","status":"satisfied","evidence":"The printable card is ready."}],"clarification_question":""}"#
        let assessment = try #require(DefinitionOfDone.parse(raw, task: task, definition: definition, model: "fixture"))
        for state in ["working", "needs you", "stopped by you", "failed"] {
            let changed = Self.task(task.lastMessage, outcome: state)
            #expect(changed.fingerprint != task.fingerprint)
            #expect(!assessment.isCurrent(for: changed, definition: definition))
            #expect(TaskCompletionNotice(task: changed, definition: definition, assessment: assessment) == nil)
        }
    }

    @Test func changedGoalOutranksOldDoneReportWithoutOverridingRealStops() throws {
        let task = Self.task("The original project is complete. All checks passed.")
        let definition = "The original task is done; now provide a printable illustrated recipe card."
        let fields: [String: Any] = [
            "state": "done", "reason": "The original project is complete.",
            "meets_definition": false, "missing": [definition],
            "criteria": [["criterion": definition, "status": "unknown", "evidence": ""]],
            "clarification_question": "",
        ]
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
        let review = try #require(DefinitionOfDone.parse(raw, task: task, definition: definition, model: "fixture"))
        #expect(review.state == .unfinished)
        #expect(review.meetsDefinition == false)
        #expect(review.definition == definition)
        #expect(DefinitionOfDone.shouldContinue(task, definition: definition, assessment: review, progress: nil))
        #expect(TaskDraftGate.evaluate(task: task, definition: definition, assessment: review,
                                       finished: false, ambiguous: false) == .ready)
        var oldReview = review
        oldReview.reviewVersion = nil
        #expect(!oldReview.isCurrent(for: task, definition: definition))
        #expect(!DefinitionOfDone.shouldContinue(task, definition: definition, assessment: oldReview, progress: nil))
        let stopped = Self.task(task.lastMessage, outcome: "stopped by you")
        #expect(!DefinitionOfDone.shouldContinue(stopped, definition: definition, assessment: review, progress: nil))
        let blocked = Self.task("Please sign in before I can continue.")
        #expect(!DefinitionOfDone.shouldContinue(blocked, definition: definition, assessment: review, progress: nil))
        var progress = DoneProgress()
        progress.definition = "A different goal"
        progress.lastMissing = review.missing
        #expect(!DefinitionOfDone.hasNoProgress(review, progress: progress))
        progress.definition = definition
        #expect(DefinitionOfDone.hasNoProgress(review, progress: progress))
    }

    @Test func taskXLabelsAreRecognizedWithoutMatchingUnrelatedActions() {
        for label in ["X Mark", "xmark", "X", "Close task", "Dismiss", "Close"] {
            #expect(Matcher.isTaskDismissButton(label))
        }
        for label in ["Close window", "Delete files", "Retry", "Cancel", "Canon Printer Diag, oops"] {
            #expect(!Matcher.isTaskDismissButton(label))
        }
    }

    @Test func draftGateRequiresSavedCriteriaAndCurrentReview() throws {
        let task = Self.task("Docs are pushed, but the application is not built yet.")
        let definition = "Build and verify the application"
        let raw = #"{"state":"unfinished","reason":"Build is not complete.","meets_definition":false,"missing":["Build and launch the application"],"criteria":[{"criterion":"Build and verify the application","status":"unmet","evidence":"the application is not built yet"}]}"#
        let current = try #require(DefinitionOfDone.parse(raw, task: task, definition: definition, model: "fixture"))

        #expect(TaskDraftGate.evaluate(task: task, definition: nil, assessment: current,
                                       finished: false, ambiguous: false) == .defineCriteria)
        #expect(TaskDraftGate.evaluate(task: task, definition: definition, assessment: nil,
                                       finished: false, ambiguous: false) == .reviewLatestReport)

        var newerReport = task
        newerReport.lastMessage += " New report."
        #expect(TaskDraftGate.evaluate(task: newerReport, definition: definition, assessment: current,
                                       finished: false, ambiguous: false) == .reviewLatestReport,
                "a report newer than the assessment invalidates Draft")
        #expect(TaskDraftGate.evaluate(task: task, definition: "A different saved criterion", assessment: current,
                                       finished: false, ambiguous: false) == .reviewLatestReport,
                "changed saved criteria invalidate Draft")

        #expect(TaskDraftGate.evaluate(task: task, definition: definition, assessment: current,
                                       finished: false, ambiguous: false) == .ready)
        var done = current
        done.meetsDefinition = true
        #expect(TaskDraftGate.evaluate(task: task, definition: definition, assessment: done,
                                       finished: false, ambiguous: false) == .noActionableGaps)
        var invented = current
        invented.criteria?[0].criterion = "A work item invented from the report"
        #expect(TaskDraftGate.evaluate(task: task, definition: definition, assessment: invented,
                                       finished: false, ambiguous: false) == .reviewLatestReport)
        #expect(TaskDraftGate.evaluate(task: task, definition: definition, assessment: current,
                                       finished: true, ambiguous: false) == .taskFinished)
        #expect(TaskDraftGate.evaluate(task: task, definition: definition, assessment: current,
                                       finished: false, ambiguous: true) == .ambiguousTask)
    }
}
