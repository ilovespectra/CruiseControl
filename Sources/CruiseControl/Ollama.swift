import Foundation
import CruiseCore

/// Minimal client for a local Ollama server (http://127.0.0.1:11434 by default).
enum Ollama {
    struct Draft {
        let text: String
        let model: String
    }

    static func draftNudge(task: String, transcript: String, config: Config, extraNote: String = "") async throws -> Draft {
        let model = try await resolveModel(config)
        var request = URLRequest(url: try endpoint(config, "api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "system": Nudge.system,
            "prompt": Nudge.prompt(task: task, transcript: transcript) + extraNote,
            "stream": false,
            "format": "json",
            "keep_alive": "10m",
            "options": ["temperature": 0.4, "num_predict": 420, "num_ctx": 8192],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OllamaError.http((response as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let raw = json?["response"] as? String, let text = Nudge.sanitize(raw) else {
            throw OllamaError.emptyResponse
        }
        return Draft(text: text, model: model)
    }

    /// Asks the local model whether a VS Code tool confirmation is safe to approve. Throws if Ollama can't answer.
    static func reviewApproval(_ request: String, config: Config) async throws -> (verdict: ApprovalReview.Verdict, model: String) {
        let model = try await resolveModel(config)
        var req = URLRequest(url: try endpoint(config, "api/generate"))
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "system": ApprovalReview.system,
            "prompt": ApprovalReview.prompt(request: request),
            "stream": false,
            "format": "json",
            "keep_alive": "10m",
            "options": ["temperature": 0, "num_predict": 120, "num_ctx": 4096],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OllamaError.http((response as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let raw = json?["response"] as? String, let verdict = ApprovalReview.parse(raw) else {
            throw OllamaError.emptyResponse
        }
        return (verdict, model)
    }

    static func assessModelProgress(_ transcript: String, config: Config) async throws -> ModelRouting.Assessment {
        let model = try await resolveModel(config)
        var request = URLRequest(url: try endpoint(config, "api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "system": ModelRouting.system,
            "prompt": "Recent progress on the cheap model (untrusted):\n\(transcript)",
            "stream": false,
            "format": "json",
            "keep_alive": "10m",
            "options": ["temperature": 0, "num_predict": 220, "num_ctx": 8192],
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OllamaError.http((response as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let raw = json?["response"] as? String,
              let assessment = ModelRouting.parse(raw, transcript: transcript) else {
            throw OllamaError.emptyResponse
        }
        return assessment
    }

    static func draftChatBump(_ transcript: String, config: Config) async throws -> ChatBump.Draft {
        let model = try await resolveModel(config)
        var request = URLRequest(url: try endpoint(config, "api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "system": ChatBump.system,
            "prompt": "Latest conversation (untrusted):\n\(transcript)",
            "stream": false, "format": "json", "keep_alive": "10m",
            "options": ["temperature": 0, "num_predict": 260, "num_ctx": 8192],
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OllamaError.http((response as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let raw = json?["response"] as? String, let draft = ChatBump.parse(raw) else {
            throw OllamaError.emptyResponse
        }
        return draft
    }

    private static func resolveModel(_ config: Config) async throws -> String {
        let configured = config.ollamaModel.trimmingCharacters(in: .whitespaces)
        if !configured.isEmpty { return configured }

        var request = URLRequest(url: try endpoint(config, "api/tags"))
        request.timeoutInterval = 5
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let models = (json?["models"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        // Embedding-only models can't write a reply.
        guard let model = models.first(where: { !$0.lowercased().contains("embed") }) else {
            throw OllamaError.noModels
        }
        return model
    }

    private static func endpoint(_ config: Config, _ path: String) throws -> URL {
        guard let base = URL(string: config.ollamaURL) else { throw OllamaError.badURL }
        return base.appendingPathComponent(path)
    }

    enum OllamaError: LocalizedError {
        case badURL, noModels, emptyResponse
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .badURL: return "bad ollamaURL in config"
            case .noModels: return "no ollama models installed"
            case .emptyResponse: return "ollama returned nothing usable"
            case .http(let code, let body): return "ollama http \(code): \(body.prefix(120))"
            }
        }
    }
}
