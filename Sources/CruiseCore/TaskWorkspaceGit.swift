import Foundation

public enum TaskWorkspaceGit {
    public static func branches(in workspace: String) throws -> [String] {
        let url = URL(fileURLWithPath: workspace).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else {
            throw GitError.notRepository
        }
        return try runGit(["-C", url.path, "branch", "--list", "--format=%(refname:short)"])
            .split(whereSeparator: \.isNewline).map(String.init).sorted()
    }

    public static func createBranch(_ name: String, in workspace: String) throws {
        guard !name.isEmpty else { throw GitError.invalidBranchName }
        _ = try runGit(["check-ref-format", "--branch", name])
        _ = try runGit(["-C", URL(fileURLWithPath: workspace).standardizedFileURL.path,
                        "branch", name])
    }

    private static func runGit(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.command(detail.isEmpty ? "git exited with status \(process.terminationStatus)" : detail)
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public enum GitError: LocalizedError {
        case notRepository
        case invalidBranchName
        case command(String)

        public var errorDescription: String? {
            switch self {
            case .notRepository: "The confirmed workspace is not an accessible Git repository."
            case .invalidBranchName: "Enter a valid branch name."
            case .command(let detail): "Git branch operation failed: \(detail)"
            }
        }
    }
}
