import AppKit

@MainActor
final class BinaryPublisher: ObservableObject {
    @Published var repositoryPath = UserDefaults.standard.string(forKey: "publisherRepositoryPath") ?? "" {
        didSet { UserDefaults.standard.set(repositoryPath, forKey: "publisherRepositoryPath") }
    }
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

    func openConsole() {
        guard !running else { return }
        let root = URL(fileURLWithPath: repositoryPath, isDirectory: true)
        let script = root.appendingPathComponent("scripts/dev-console.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            log = "Choose the CruiseControl source checkout containing scripts/dev-console.py."
            return
        }
        let child = Process()
        let pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = ["python3", script.path, "--start"]
        child.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        child.environment = environment
        child.standardOutput = pipe
        child.standardError = pipe
        running = true
        log = "Starting persistent local console…"
        process = child
        child.terminationHandler = { [weak self] process in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                guard let self else { return }
                self.running = false
                self.log = process.terminationStatus == 0
                    ? "Web console opened. Builds continue after closing this launcher or browser."
                    : "Console failed (exit \(process.terminationStatus)):\n\(output)"
                self.process = nil
            }
        }
        do { try child.run() }
        catch {
            running = false
            process = nil
            log = "Could not start developer console: \(error.localizedDescription)"
        }
    }
}
