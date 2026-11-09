import Foundation

public enum VSCodeApprovalContext {
    public static let writeMetadataPrefix = "Write-file approval (metadata only; full diff and absolute paths unavailable):"

    public static func isToolPermissionDialog(_ description: String) -> Bool {
        description.hasPrefix("Chat Confirmation Dialog Allow tool from ")
    }

    public static func toolPermissionRequest(description: String, allowLabel: String) -> String? {
        let prefix = "Chat Confirmation Dialog Allow tool from "
        guard isToolPermissionDialog(description),
              ["allow in this session", "allow once"].contains(Matcher.normalize(allowLabel)),
              let separator = description.range(of: "? ", range: description.index(description.startIndex, offsetBy: prefix.count)..<description.endIndex)
        else { return nil }
        let provider = String(description[description.index(description.startIndex, offsetBy: prefix.count)..<separator.lowerBound])
        let detail = String(description[separator.upperBound...])
        guard !provider.isEmpty, provider.count <= 200,
              detail.hasPrefix(provider + ": "),
              detail.count > provider.count + 2, detail.count <= 1000,
              !detail.contains("…"), !detail.contains("..."),
              !provider.contains("\n"), !detail.contains("\n") else { return nil }
        let scope = Matcher.normalize(allowLabel) == "allow in this session" ? "this VS Code session" : "this request only"
        return "Tool permission approval (identity only; tool inputs unavailable):\nProvider: \(provider)\nTool: \(detail.dropFirst(provider.count + 2))\nGrant scope: \(scope)\nThis grant can permit subsequent tool calls without individual confirmation."
    }

    public static func isFileMutationDialog(_ description: String) -> Bool {
        description.hasPrefix("Chat Confirmation Dialog Write file? ")
            || description.hasPrefix("Chat Confirmation Dialog Create file? ")
    }

    public static func isFileChangeSummary(_ label: String) -> Bool {
        label.range(of: #"^\d+ files? (changed|created), \d+ lines? added, \d+ lines? removed$"#,
                    options: .regularExpression) != nil
    }

    public static func writeMetadataRequest(description: String, files: [String], summaries: [String]) -> String? {
        guard isFileMutationDialog(description),
              !files.isEmpty, files.count <= 20 else { return nil }
        let names = files.map {
            $0.unicodeScalars.filter { $0.properties.generalCategory != .privateUse }
                .map(String.init).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard names.allSatisfy({ !$0.isEmpty && !$0.contains("…") && !$0.contains("\n") }),
              !summaries.isEmpty,
              summaries.allSatisfy(isFileChangeSummary) else { return nil }
        let action = description.hasPrefix("Chat Confirmation Dialog Create file? ") ? "\nAction: create file" : ""
        let request = "\(writeMetadataPrefix)\(action)\nFiles: \(names.joined(separator: ", "))\nChanges: \(summaries.joined(separator: "; "))"
        return request.count <= 3500 ? request : nil
    }

    /// The sidebar preview is clipped, but the Allow button's aria-label includes the entire approval label.
    public static func sidebarRequest(_ label: String) -> String? {
        let prefix = "Allow once: "
        guard label.hasPrefix(prefix) else { return nil }
        let command = String(label.dropFirst(prefix.count))
        let structured = command.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
        let request = structured ? "Tool approval inputs (operation unspecified):\n\(command)" : "Run in terminal:\n\(command)"
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.count <= 4000,
              !command.contains("…"), !command.contains("...") else { return nil }
        if structured {
            guard let data = command.data(using: .utf8),
                  let inputs = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  !inputs.isEmpty else { return nil }
            return request
        }
        // Generic approval questions contain no tool inputs. Leave those for the full dialog.
        let executable = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let knownCommands: Set<String> = [
            "cd", "pwd", "ls", "cat", "head", "tail", "grep", "rg", "find", "git",
            "swift", "xcrun", "xcodebuild", "python", "python3", "node", "npm", "npx",
            "pnpm", "yarn", "bun", "go", "cargo", "make", "cmake", "bash", "sh",
            "zsh", "env", "curl", "wget", "gh", "mkdir", "cp", "mv", "rm", "echo",
            "printf", "sed", "awk", "test", "uname", "date", "which", "command",
        ]
        guard knownCommands.contains(executable)
                || executable.hasPrefix("/") || executable.hasPrefix("./") else { return nil }
        return request
    }

    public static func request(matching title: String, in requests: [String]) -> String? {
        let normalized = Matcher.normalize(title)
        guard !normalized.isEmpty else { return nil }
        let candidates = requests.flatMap { request in
            request.components(separatedBy: ", Run in terminal: ").enumerated().map { index, text in
                index == 0 ? text : "Run in terminal: \(text)"
            }
        }.filter { request in
            let parts = request.components(separatedBy: ": ")
            return (1..<parts.count).contains { index in
                Matcher.normalize(parts.prefix(index).joined(separator: ": ")) == normalized
                    && !parts.suffix(from: index).joined(separator: ": ").isEmpty
            }
        }
        let matches = Set(candidates)
        return matches.count == 1 ? matches.first : nil
    }

    /// Electron can leave the conversation's confirmation description stale while the carousel advances.
    /// Prefer complete structured inputs on the live dialog over that older request.
    public static func dialogRequest(title: String, description: String, requests: [String]) -> String? {
        if let marker = description.range(of: "Input{") {
            let input = description[marker.upperBound...]
            guard let end = input.lastIndex(of: "}"),
                  ["", "See more"].contains(input[input.index(after: end)...].trimmingCharacters(in: .whitespacesAndNewlines))
            else { return nil }
            let raw = "{" + input[...end]
            var json = ""
            var quoted = false
            var escaped = false
            for character in raw {
                if character == "\"", !escaped { quoted.toggle() }
                json.append(!quoted && character == "\u{00a0}" ? " " : character)
                escaped = character == "\\" && !escaped
            }
            guard !json.contains("…"), !json.contains("..."), json.count <= 3500,
                  let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  !object.isEmpty else { return nil }
            return "Tool approval inputs (operation unspecified):\n\(json)"
        }
        return request(matching: title, in: requests)
    }

    public static func threadTitle(_ label: String) -> String? {
        guard let state = label.range(of: ", State: ", options: .backwards) else { return nil }
        var title = String(label[..<state.lowerBound])
        if let updated = title.range(of: ", updated ", options: .backwards) {
            title = String(title[..<updated.lowerBound])
        }
        return title.isEmpty ? nil : title
    }

    public static func needsAttention(_ label: String) -> Bool {
        guard let state = label.range(of: ", State: ", options: .backwards) else { return false }
        let status = Matcher.normalize(String(label[state.upperBound...]))
        return ["attention needed", "needs input", "input needed", "needs attention"].contains(status)
    }

    public static func needsInspection(_ label: String, hasInlineApproval: Bool) -> Bool {
        threadTitle(label) != nil && (needsAttention(label) || hasInlineApproval)
    }
}
