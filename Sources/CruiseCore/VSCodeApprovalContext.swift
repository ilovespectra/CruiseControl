import Foundation

public enum VSCodeApprovalContext {
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
        }.filter { Matcher.normalize($0).hasPrefix(normalized + ":") }
        let matches = Set(candidates)
        return matches.count == 1 ? matches.first : nil
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
