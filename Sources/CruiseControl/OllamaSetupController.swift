import AppKit
import Combine
import CruiseCore
import Foundation

@MainActor
final class OllamaSetupController: ObservableObject {
    private let store: ConfigStore
    private var cancellables: Set<AnyCancellable> = []
    private var serverProcess: Process?
    private var refreshInFlight = false

    @Published private(set) var readiness: OllamaReadiness = .missingInstallation
    @Published private(set) var isChecking = true
    @Published private(set) var isPulling = false
    @Published private(set) var pullProgress = ""
    @Published private(set) var actionMessage: String?
    @Published private(set) var serviceReachable = false
    @Published private(set) var detectedModels: [String] = []

    var integrationEnabled: Bool {
        let config = store.config
        return config.ollamaEnabled || config.vscodeAutoApprove || config.autoSelectVSCodeModel || config.vscodeTaskBumps
    }

    init(store: ConfigStore) {
        self.store = store
        store.$config
            .map { config in
                [config.ollamaURL, config.ollamaModel, "\(config.ollamaEnabled)", "\(config.vscodeAutoApprove)",
                 "\(config.autoSelectVSCodeModel)", "\(config.vscodeTaskBumps)"]
            }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
            .store(in: &cancellables)
        Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in Task { @MainActor in await self?.refresh() } }
            .store(in: &cancellables)
        Task { await refresh() }
    }

    func refresh() async {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        isChecking = true
        defer {
            isChecking = false
            refreshInFlight = false
        }

        let config = store.config
        let localEndpoint = Self.isLocalEndpoint(config.ollamaURL)
        let installed = Self.isInstalled || !localEndpoint
        do {
            guard let baseURL = URL(string: config.ollamaURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let url = URL(string: "api/tags", relativeTo: baseURL)?.absoluteURL else {
                serviceReachable = false
                detectedModels = []
                readiness = OllamaReadiness.evaluate(installed: installed, reachable: false, models: [], configuredModel: config.ollamaModel)
                return
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                serviceReachable = false
                detectedModels = []
                readiness = OllamaReadiness.evaluate(installed: installed, reachable: false, models: [], configuredModel: config.ollamaModel)
                return
            }
            let models = (json["models"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            serviceReachable = true
            detectedModels = models
            readiness = OllamaReadiness.evaluate(installed: installed, reachable: true, models: models, configuredModel: config.ollamaModel)
        } catch {
            serviceReachable = false
            detectedModels = []
            readiness = OllamaReadiness.evaluate(installed: installed, reachable: false, models: [], configuredModel: config.ollamaModel)
        }
    }

    func openInstaller() {
        guard let url = URL(string: "https://ollama.com/download/mac") else { return }
        NSWorkspace.shared.open(url)
    }

    func openSettings() {
        NotificationCenter.default.post(name: SettingsController.openOllamaNotification, object: nil)
    }

    var canStartLocalService: Bool { Self.isLocalEndpoint(store.config.ollamaURL) }

    func startService() {
        guard Self.isLocalEndpoint(store.config.ollamaURL) else {
            actionMessage = "This is a remote endpoint. Check its address or service in Settings."
            return
        }
        if let app = Self.ollamaAppURL {
            guard NSWorkspace.shared.open(app) else {
                actionMessage = "Couldn't open Ollama. Use the official installer link, then try again."
                return
            }
            actionMessage = "Opened Ollama. Waiting for its local service…"
            scheduleRefresh(after: 2)
            return
        }
        guard let executable = Self.ollamaExecutableURL else {
            actionMessage = "Ollama wasn't found. Install it from ollama.com first."
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            serverProcess = process
            actionMessage = "Started Ollama's local service. Checking health…"
            scheduleRefresh(after: 2)
        } catch {
            actionMessage = "Couldn't start Ollama: \(error.localizedDescription)"
        }
    }

    func pullModel(_ rawName: String) {
        let model = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.count <= 120, !isPulling else {
            actionMessage = "Enter a model name before downloading."
            return
        }
        guard serviceReachable else {
            actionMessage = "Start Ollama and check its service before downloading a model."
            return
        }
        Task { await performPull(model) }
    }

    private func performPull(_ model: String) async {
        isPulling = true
        actionMessage = nil
        pullProgress = "Preparing download…"
        defer { isPulling = false }
        do {
            let config = store.config
            guard let baseURL = URL(string: config.ollamaURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let url = URL(string: "api/pull", relativeTo: baseURL)?.absoluteURL else {
                throw SetupError.badURL
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 3600
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["name": model, "stream": true])
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw SetupError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            var completed = false
            for try await line in bytes.lines {
                guard let lineData = line.data(using: .utf8),
                      let payload = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
                if let error = payload["error"] as? String { throw SetupError.server(error) }
                if let status = payload["status"] as? String {
                    if status == "success" { completed = true }
                    if let total = payload["total"] as? Int64, total > 0,
                       let done = payload["completed"] as? Int64 {
                        let percentage = min(100, Int(Double(done) / Double(total) * 100))
                        pullProgress = "\(status) · \(percentage)%"
                    } else {
                        pullProgress = status
                    }
                }
            }
            guard completed else { throw SetupError.incomplete }
            store.config.ollamaModel = model
            actionMessage = "Downloaded and selected \(model)."
            pullProgress = ""
            await refresh()
        } catch {
            actionMessage = "Model download failed: \(error.localizedDescription)"
            pullProgress = ""
            await refresh()
        }
    }

    private func scheduleRefresh(after seconds: Double) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            await refresh()
        }
    }

    private static func isLocalEndpoint(_ rawURL: String) -> Bool {
        guard let host = URL(string: rawURL)?.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static var isInstalled: Bool {
        ollamaAppURL != nil || ollamaExecutableURL != nil
    }

    private static var ollamaAppURL: URL? {
        let candidates = ["/Applications/Ollama.app", "\(NSHomeDirectory())/Applications/Ollama.app"]
        return candidates.map(URL.init(fileURLWithPath:)).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static var ollamaExecutableURL: URL? {
        let candidates = [
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama",
            "\(NSHomeDirectory())/Applications/Ollama.app/Contents/Resources/ollama",
        ]
        return candidates.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private enum SetupError: LocalizedError {
        case badURL
        case http(Int)
        case server(String)
        case incomplete

        var errorDescription: String? {
            switch self {
            case .badURL: return "The Ollama endpoint isn't a valid URL."
            case .http(let code): return "Ollama returned HTTP \(code)."
            case .server(let detail): return detail
            case .incomplete: return "Ollama closed the download stream before reporting success."
            }
        }
    }
}
