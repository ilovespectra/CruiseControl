import AppKit

@MainActor
enum GitHubWorkspaceSetup {
    static func open(workspace: String) {
        let alert = NSAlert()
        alert.messageText = "Set up Git and GitHub for this folder?"
        alert.informativeText = "Terminal will initialize local Git if needed and run GitHub CLI browser login. Complete login and 2FA yourself. No files are committed, pushed, or uploaded."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open Terminal")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            let directory = ConfigStore.directory.appendingPathComponent("terminal-setup", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let script = directory.appendingPathComponent("\(UUID().uuidString).command")
            let quoted = "'" + workspace.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let text = """
            #!/bin/bash
            trap 'rm -- "$0"' EXIT
            export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
            cd -- \(quoted) || exit 1
            if ! git rev-parse --git-dir >/dev/null 2>&1; then
                git init --initial-branch=main || exit 1
            fi
            if ! command -v gh >/dev/null 2>&1; then
                echo "Git is ready. Install GitHub CLI from https://cli.github.com, then run gh auth login --web --git-protocol https."
                exit 1
            fi
            gh auth login --hostname github.com --web --git-protocol https || exit 1
            gh auth setup-git --hostname github.com || exit 1
            echo "GitHub login is ready. Return to Cruise and refresh the workspace. Creating a remote repository is a separate explicit action."
            """
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            guard NSWorkspace.shared.open(script) else {
                throw NSError(domain: "CruiseGitSetup", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Could not open the setup command in Terminal."])
            }
        } catch {
            NSLog("Cruise Git setup failed: %@", error.localizedDescription)
            let failure = NSAlert(error: error)
            failure.runModal()
        }
    }
}
