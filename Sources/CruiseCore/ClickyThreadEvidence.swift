import Foundation
import SQLite3

/// Read-only, thread-owned project evidence. Never consumes tool traces or writes to HeyClicky's stores.
public enum ClickyThreadEvidence {
    public struct Reference: Equatable, Sendable {
        public let threadID: String
        public let source: String
        public let text: String
    }

    public struct Result: Sendable {
        public var references: [Reference] = []
        public var errors: [String] = []
        public init() {}
    }

    public static func validThreadID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 200 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }

    public static func load(threadIDs: Set<String>, root: URL) -> [String: Result] {
        var results: [String: Result] = [:]
        for id in threadIDs.sorted() {
            guard validThreadID(id) else {
                var result = Result()
                result.errors = ["Invalid thread ID; no cache paths were opened."]
                results[id] = result
                continue
            }
            var result = Result()
            let journalPath = "HomeSpaceCache/turn-journal/\(id)"
            let journal = root.appendingPathComponent(journalPath)
            if FileManager.default.fileExists(atPath: journal.path) {
                do {
                    guard isContained(journal, root: root) else { throw EvidenceError.outsideRoot(journalPath) }
                    let files = try FileManager.default.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil)
                    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
                        let relative = "\(journalPath)/\(file.lastPathComponent)"
                        readJSON(relative, root: root, result: &result) { object, result in
                            guard let envelope = object as? [String: Any], let turn = envelope["turn"] as? [String: Any] else {
                                throw EvidenceError.shape(relative)
                            }
                            for field in ["userMessages", "assistantMessages"] {
                                guard let messages = turn[field] as? [String] else {
                                    if turn[field] != nil { throw EvidenceError.shape(relative) }
                                    continue
                                }
                                for text in messages { append(text, threadID: id, source: "\(relative)#\(field)", to: &result) }
                            }
                        }
                    }
                } catch {
                    result.errors.append("Couldn't read \(journalPath): \(error.localizedDescription)")
                }
            }
            let turnsPath = "AgentHarness/h1-local/\(id)/turns.json"
            readJSON(turnsPath, root: root, result: &result) { object, result in
                guard let turns = object as? [String: Any] else { throw EvidenceError.shape(turnsPath) }
                for key in turns.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                    guard let turn = turns[key] as? [String: Any], let text = turn["text"] as? String else {
                        throw EvidenceError.shape(turnsPath)
                    }
                    append(text, threadID: id, source: "\(turnsPath)#\(key)", to: &result)
                }
            }
            let jobPath = "AgentHarness/h1-local/\(id)/job.json"
            readJSON(jobPath, root: root, result: &result) { object, result in
                guard let job = object as? [String: Any], let cfg = job["cfg"] as? [String: Any] else {
                    throw EvidenceError.shape(jobPath)
                }
                if let path = cfg["workspace"] as? String, path.hasPrefix("/") {
                    append("Working directory: \(path)", threadID: id, source: "\(jobPath)#cfg.workspace", to: &result)
                }
            }
            let transcriptPath = "HomeSpaceCache/transcript-\(id).json"
            readJSON(transcriptPath, root: root, result: &result) { object, result in
                guard let turns = object as? [[String: Any]] else { throw EvidenceError.shape(transcriptPath) }
                for (index, turn) in turns.enumerated() {
                    for field in ["userMessages", "assistantMessages"] {
                        guard let messages = turn[field] as? [String] else {
                            if turn[field] != nil { throw EvidenceError.shape(transcriptPath) }
                            continue
                        }
                        for text in messages {
                            append(text, threadID: id, source: "\(transcriptPath)#\(index).\(field)", to: &result)
                        }
                    }
                }
            }
            results[id] = result
        }
        readCodexMetadata(threadIDs: threadIDs.filter(validThreadID), root: root, results: &results)
        return results
    }

    private static func append(_ text: String, threadID: String, source: String, to result: inout Result) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Keep both the start of the request and actual path/link lines even in a long conversation turn.
        let lines = text.split(separator: "\n").filter {
            $0.contains("/") || $0.localizedCaseInsensitiveContains("project")
        }.prefix(12).map { String($0.prefix(1400)) }
        let excerpt = ([String(text.prefix(2400))] + lines).joined(separator: "\n")
        guard !result.references.contains(where: { $0.text == excerpt && $0.source == source }) else { return }
        result.references.append(Reference(threadID: threadID, source: source, text: excerpt))
        if result.references.count > 80 { result.references.removeFirst(result.references.count - 80) }
    }

    private static func readJSON(_ relative: String, root: URL, result: inout Result,
                                 consume: (Any, inout Result) throws -> Void) {
        let url = root.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            guard isContained(url, root: root) else { throw EvidenceError.outsideRoot(relative) }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 32 * 1024 * 1024 else { throw EvidenceError.tooLarge(relative) }
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            try consume(object, &result)
        } catch {
            result.errors.append("Couldn't read \(relative): \(error.localizedDescription)")
        }
    }

    private static func isContained(_ url: URL, root: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return false }
        let relative = String(path.dropFirst(rootPath.count))
        return resolved == root.resolvingSymlinksInPath().standardizedFileURL.path + relative
    }

    private static func readCodexMetadata(threadIDs: Set<String>, root: URL, results: inout [String: Result]) {
        let relative = "CodexHome/sqlite/state_5.sqlite"
        let url = root.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var db: OpaquePointer?
        defer { if let db { sqlite3_close(db) } }
        do {
            guard isContained(url, root: root) else { throw EvidenceError.outsideRoot(relative) }
            guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                throw EvidenceError.database(db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
            }
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT cwd, git_origin_url FROM threads WHERE id = ?1", -1, &query, nil) == SQLITE_OK else {
                throw EvidenceError.database(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(query) }
            for id in threadIDs.sorted() {
                sqlite3_reset(query)
                sqlite3_clear_bindings(query)
                let status = id.withCString { sqlite3_bind_text(query, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                guard status == SQLITE_OK else { throw EvidenceError.database(String(cString: sqlite3_errmsg(db))) }
                var result = results[id] ?? Result()
                var step = sqlite3_step(query)
                while step == SQLITE_ROW {
                    for (column, field) in [(0, "cwd"), (1, "git_origin_url")] {
                        if let raw = sqlite3_column_text(query, Int32(column)) {
                            let text = String(cString: raw)
                            if !text.isEmpty {
                                append("\(field): \(text)", threadID: id, source: "\(relative)#threads.\(field)", to: &result)
                            }
                        }
                    }
                    step = sqlite3_step(query)
                }
                guard step == SQLITE_DONE else { throw EvidenceError.database(String(cString: sqlite3_errmsg(db))) }
                results[id] = result
            }
        } catch {
            for id in threadIDs {
                results[id, default: Result()].errors.append("Couldn't read thread metadata from \(relative): \(error.localizedDescription)")
            }
        }
    }

    private enum EvidenceError: LocalizedError {
        case shape(String), outsideRoot(String), tooLarge(String), database(String)
        var errorDescription: String? {
            switch self {
            case .shape(let file): return "Unexpected conversation format in \(file)."
            case .outsideRoot(let file): return "Refusing a cache path outside the HeyClicky root: \(file)."
            case .tooLarge(let file): return "Conversation file exceeds the 32 MB read limit: \(file)."
            case .database(let message): return "Read-only thread metadata query failed: \(message)"
            }
        }
    }
}
