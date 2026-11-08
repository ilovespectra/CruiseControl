import AppKit

@MainActor
final class BinaryPublisher: ObservableObject {
    @Published var repositoryPath = ""
    @Published private(set) var running = false
    @Published private(set) var log = ""
    private var process: Process?

    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { repositoryPath = url.path }
    }

    func publish(preview: Bool) {
        guard !running else { return }
        let root = URL(fileURLWithPath: repositoryPath, isDirectory: true)
        let script = root.appendingPathComponent("scripts/repackage-binaries.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            log = "Choose the CruiseControl source checkout containing scripts/repackage-binaries.sh."
            return
        }
        if !preview {
            let alert = NSAlert()
            alert.messageText = "Publish the next unsigned binary release?"
            alert.informativeText = "This builds the latest clean, pushed production commit and publishes a GitHub release. macOS warnings are expected. Failed builds do not advance the published version. GitHub CLI must already be authenticated."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Build and publish")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        let child = Process()
        let pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/bash")
        child.arguments = [script.path] + (preview ? ["--preview"] : ["--publish", "--unsigned"])
        child.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        child.environment = environment
        child.standardOutput = pipe
        child.standardError = pipe
        log = ""
        running = true
        process = child
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                guard let self else { return }
                self.log = String((self.log + text).suffix(60000))
            }
        }
        child.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self else { return }
                self.running = false
                self.log += "\n\(process.terminationStatus == 0 ? "Succeeded" : "Failed (exit \(process.terminationStatus))").\n"
                self.process = nil
            }
        }
        do { try child.run() }
        catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            running = false
            process = nil
            log = "Could not start repackaging: \(error.localizedDescription)"
        }
    }
}
