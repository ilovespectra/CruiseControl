import Foundation
import SQLite3
import Testing
@testable import CruiseCore

struct ClickyThreadEvidenceTests {
    @Test func changedConversationFileIsReReadInsteadOfServedFromCache() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "AgentHarness/h1-mac/cached-thread/turns.json"
        try write(["1": ["text": "Build in /projects/Old"]], path, root: root)
        let first = try #require(ClickyThreadEvidence.load(threadIDs: ["cached-thread"], root: root)["cached-thread"])
        #expect(first.references.map(\.text).joined().contains("/projects/Old"))
        try write(["1": ["text": "Build in /projects/NewerName"]], path, root: root)
        let second = try #require(ClickyThreadEvidence.load(threadIDs: ["cached-thread"], root: root)["cached-thread"])
        #expect(second.references.map(\.text).joined().contains("/projects/NewerName"))
        #expect(!second.references.map(\.text).joined().contains("/projects/Old"))
    }

    @Test func intelHarnessEvidenceIsReadWithoutDependingOnCodexMetadata() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(["1": ["text": "Build in /projects/Intel"]],
                  "AgentHarness/h1-mac/intel-thread/turns.json", root: root)
        try write(["cfg": ["workspace": "/projects/Intel"]],
                  "AgentHarness/h1-mac/intel-thread/job.json", root: root)
        let result = try #require(ClickyThreadEvidence.load(threadIDs: ["intel-thread"], root: root)["intel-thread"])
        #expect(result.references.count == 2)
        #expect(result.references.allSatisfy { $0.source.contains("h1-mac/intel-thread/") })
        #expect(result.errors.isEmpty)
    }

    @Test func unavailableWALSidecarRetriesQueryAndReportsCheckpointOnlyMetadata() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("CodexHome/sqlite")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, """
        PRAGMA journal_mode=WAL;
        CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, git_origin_url TEXT);
        INSERT INTO threads VALUES ('owned', '/projects/Intel', NULL);
        PRAGMA wal_checkpoint(TRUNCATE);
        """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        // A directory at SQLite's shared-memory path deterministically denies sidecar access,
        // including on test runners that can bypass POSIX read-only permissions.
        let shm = URL(fileURLWithPath: url.path + "-shm")
        if FileManager.default.fileExists(atPath: shm.path) { try FileManager.default.removeItem(at: shm) }
        try FileManager.default.createDirectory(at: shm, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let before = try Data(contentsOf: url)
        let result = try #require(ClickyThreadEvidence.load(threadIDs: ["owned"], root: root)["owned"])
        #expect(result.references.contains { $0.text.contains("/projects/Intel") })
        #expect(result.errors.contains { $0.contains("Partial thread metadata") && $0.contains("checkpointed") })
        #expect(try Data(contentsOf: url) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: shm.path).isEmpty)
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-evidence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ value: Any, _ relative: String, root: URL) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value).write(to: url)
    }

    @Test func joinsConversationPathsOnlyToExactThreadIDsNotSimilarNames() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(["1": ["text": "Use /projects/Alpha and https://github.com/owner/Alpha"]],
                  "AgentHarness/h1-local/thread-a/turns.json", root: root)
        try write(["cfg": ["workspace": "/projects/Alpha"]],
                  "AgentHarness/h1-local/thread-a/job.json", root: root)
        try write([["userMessages": ["Continue the Alpha project."],
                    "assistantMessages": ["The files are in /projects/Alpha/Sources."]]],
                  "HomeSpaceCache/transcript-thread-a.json", root: root)
        try write(["1": ["text": "Use /projects/Wrong and https://github.com/other/Wrong"]],
                  "AgentHarness/h1-local/thread-a-extra/turns.json", root: root)
        try write(["1": ["text": "Unrelated /projects/Other"]],
                  "AgentHarness/h1-local/thread-b/turns.json", root: root)
        let jobs = """
        [{"id":"a","nickname":"Same nickname","threadID":"thread-a"},
         {"id":"b","nickname":"Same nickname","threadID":"thread-b"}]
        """
        let tasks = try ClickyTaskLibrary.load(jobsData: Data(jobs.utf8), root: root)
        let a = try #require(tasks.first { $0.id == "a" })
        let b = try #require(tasks.first { $0.id == "b" })
        #expect(a.threadReferences.count == 4)
        #expect(a.threadReferences.allSatisfy { $0.threadID == "thread-a" })
        #expect(ProjectInference.pathEvidence(for: a).joined().contains("/projects/Alpha"))
        #expect(!ProjectInference.evidence(for: a).contains("/projects/Wrong"))
        #expect(!ProjectInference.evidence(for: a).contains("/projects/Other"))
        #expect(!ProjectInference.evidence(for: b).contains("/projects/Alpha"))
        #expect(a.lastMessage.isEmpty, "Historical project evidence must not become a current completion report.")
        #expect(!a.hasReport)
        #expect(a.evidenceErrors.isEmpty)
    }

    @Test func multipleRunsJoinAllOwnedThreadsWithoutDuplicatingCurrentThread() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        for id in ["first", "second"] {
            try write(["1": ["text": "Work in /projects/\(id)"]],
                      "AgentHarness/h1-local/\(id)/turns.json", root: root)
        }
        let jobs = """
        [{"id":"a","threadID":"second","runs":[{"threadID":"first"},{"threadID":"second"}]}]
        """
        let task = try #require(ClickyTaskLibrary.load(jobsData: Data(jobs.utf8), root: root).first)
        #expect(task.threadIDs == ["first", "second"])
        #expect(task.threadReferences.map(\.threadID) == ["first", "second"])
        #expect(task.threadReferences.allSatisfy { $0.source.contains("/\($0.threadID)/") })
    }

    @Test func missingCachesAreOptionalButCorruptionIsReported() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = ClickyThreadEvidence.load(threadIDs: ["missing"], root: root)
        #expect(empty["missing"]?.references.isEmpty == true)
        #expect(empty["missing"]?.errors.isEmpty == true)
        try write(["unexpected": "shape"], "HomeSpaceCache/transcript-corrupt.json", root: root)
        let result = ClickyThreadEvidence.load(threadIDs: ["corrupt"], root: root)
        #expect(result["corrupt"]?.errors.count == 1)
        #expect(result["corrupt"]?.references.isEmpty == true)
    }

    @Test func traversalAndSymlinkEscapesNeverOpenUnownedCacheFiles() throws {
        let root = try root()
        let outside = try self.root()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try write(["1": ["text": "Do not import this /outside/Secret"]],
                  "turns.json", root: outside)
        let parent = root.appendingPathComponent("AgentHarness/h1-local")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: parent.appendingPathComponent("linked"), withDestinationURL: outside)
        try write(["1": ["text": "Other thread's /projects/Secret"]],
                  "AgentHarness/h1-local/other/turns.json", root: root)
        try FileManager.default.createSymbolicLink(at: parent.appendingPathComponent("wrong-thread"),
                                                  withDestinationURL: parent.appendingPathComponent("other"))
        let result = ClickyThreadEvidence.load(threadIDs: ["../escape", "/absolute", "linked", "wrong-thread"], root: root)
        for id in ["../escape", "/absolute", "linked", "wrong-thread"] {
            #expect(result[id]?.references.isEmpty == true)
            #expect(result[id]?.errors.isEmpty == false)
        }
    }

    @Test func codexWorkingDirectoryJoinsByPrimaryKeyAndDatabaseIsUnchanged() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("CodexHome/sqlite/state_5.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, """
        CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, git_origin_url TEXT);
        INSERT INTO threads VALUES ('owned', '/projects/Alpha', 'https://github.com/owner/Alpha');
        INSERT INTO threads VALUES ('owned-other', '/projects/Secret', 'https://github.com/other/Secret');
        """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: url)
        let results = ClickyThreadEvidence.load(threadIDs: ["owned", "missing"], root: root)
        let result = try #require(results["owned"])
        #expect(result.references.count == 2)
        #expect(result.references.allSatisfy { $0.threadID == "owned" })
        #expect(result.references.contains { $0.text.contains("/projects/Alpha") })
        #expect(!result.references.contains { $0.text.contains("/projects/Secret") })
        #expect(results["missing"]?.references.isEmpty == true)
        #expect(result.errors.isEmpty)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func incompatibleCodexSchemaIsAnExplicitErrorNotAnEmptySuccess() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("CodexHome/sqlite/state_5.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE threads (id TEXT);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let result = ClickyThreadEvidence.load(threadIDs: ["owned"], root: root)
        #expect(result["owned"]?.errors.count == 1)
        #expect(result["owned"]?.errors.first?.contains("metadata") == true)
    }

    @Test func longTurnRetainsLatePathReferencesAndExposesProvenance() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(["1": ["text": String(repeating: "Unrelated context. ", count: 300)
                         + "\nThe actual checkout is /projects/Correct/Sources."]],
                  "AgentHarness/h1-local/owned/turns.json", root: root)
        let result = try #require(ClickyThreadEvidence.load(threadIDs: ["owned"], root: root)["owned"])
        #expect(result.references.first?.text.contains("/projects/Correct/Sources") == true)
        #expect(result.references.first?.source == "AgentHarness/h1-local/owned/turns.json#1")
    }
}
