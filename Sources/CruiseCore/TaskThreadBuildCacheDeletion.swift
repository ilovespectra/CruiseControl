import Darwin
import Foundation

/// Restricts user-requested cleanup to one exact task-owned agent build folder.
/// Shared Clicky storage, thread journals, transcripts, and all workspace data are excluded.
public enum TaskThreadBuildCacheDeletion {
    public enum DeletionError: LocalizedError {
        case unsafePath
        case notDirectory

        public var errorDescription: String? {
            switch self {
            case .unsafePath: "Only an exact AgentHarness/h1-local|h1-mac/<thread-id> folder can be deleted."
            case .notDirectory: "The selected agent-thread build folder is missing or is not a directory."
            }
        }
    }

    public static func allowedDirectory(path: String,
                                        root: URL = ClickyTaskLibrary.defaultRoot) -> URL? {
        let rootPath = root.standardizedFileURL.path
        let target = URL(fileURLWithPath: path).standardizedFileURL
        let targetPath = target.path
        guard targetPath.hasPrefix(rootPath + "/") else { return nil }
        let relative = String(targetPath.dropFirst(rootPath.count + 1))
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "AgentHarness",
              ["h1-local", "h1-mac"].contains(parts[1]),
              ClickyThreadEvidence.validThreadID(parts[2]) else { return nil }

        var rootInfo = stat()
        guard lstat(rootPath, &rootInfo) == 0,
              rootInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return nil }
        var parent = URL(fileURLWithPath: rootPath, isDirectory: true)
        for component in parts {
            parent.appendPathComponent(component, isDirectory: true)
            var info = stat()
            guard lstat(parent.path, &info) == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return nil }
        }
        return target
    }

    public static func disposableDirectory(path: String, workspace: String) -> URL? {
        let parent = URL(fileURLWithPath: workspace).standardizedFileURL
        let target = URL(fileURLWithPath: path).standardizedFileURL
        let manifests = [".build": "Package.swift", "node_modules": "package.json"]
        guard let manifest = manifests[target.lastPathComponent],
              target.deletingLastPathComponent() == parent,
              FileManager.default.fileExists(atPath: parent.appendingPathComponent(manifest).path) else { return nil }
        for url in [parent, target] {
            var info = stat()
            guard lstat(url.path, &info) == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  url.resolvingSymlinksInPath().path == url.path else { return nil }
        }
        return target
    }

    public static func deleteDisposable(path: String, workspace: String) throws {
        guard let target = disposableDirectory(path: path, workspace: workspace) else { throw DeletionError.unsafePath }
        try FileManager.default.removeItem(at: target)
    }

    @discardableResult
    public static func delete(path: String,
                              root: URL = ClickyTaskLibrary.defaultRoot,
                              fileManager: FileManager = .default) throws -> URL {
        guard let target = allowedDirectory(path: path, root: root) else {
            throw DeletionError.unsafePath
        }
        var info = stat()
        guard lstat(target.path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw DeletionError.notDirectory
        }
        try fileManager.removeItem(at: target)
        guard !fileManager.fileExists(atPath: target.path) else { throw DeletionError.notDirectory }
        return target
    }
}
