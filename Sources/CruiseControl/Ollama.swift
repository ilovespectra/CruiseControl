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

    /// `implicitYes` (Cruise mode): when the latest report still lists unfinished work, a closing question is answered
    /// with yes and the follow-up must address that work; a declined or ungrounded draft falls back to quoting it verbatim.
    static func draftChatBump(_ transcript: String, config: Config, system: String = ChatBump.system, taskName: String? = nil,
                              latestReport: String? = nil, implicitYes: Bool = false) async throws -> ChatBump.Draft {
        let evidence = implicitYes && taskName != nil ? latestReport.map { TaskAudit.unfinishedEvidence($0) } ?? [] : []
        if let latestReport, TaskAudit.requiresUser(latestReport, implicitYes: !evidence.isEmpty) {
            throw OllamaError.userRequired
        }
        guard let taskName, !evidence.isEmpty else {
            return try await requestChatBump(transcript, config: config, system: system, taskName: taskName, latestReport: latestReport)
        }
        let fallback = ChatBump.Draft(unfinished: true, message: TaskAudit.implicitYesFollowUp(task: taskName, evidence: evidence))
        let encoded = try JSONEncoder().encode(fallback)
        guard ChatBump.parse(String(decoding: encoded, as: UTF8.self)) != nil,
              !TaskAudit.requiresUser(fallback.message) else {
            throw OllamaError.invalidFollowUp
        }
        do {
            let draft = try await requestChatBump(transcript + TaskAudit.implicitYesNote(evidence), config: config,
                                                  system: system, taskName: taskName, latestReport: latestReport)
            return draft.unfinished ? draft : fallback
        } catch OllamaError.invalidFollowUp, OllamaError.ungroundedFollowUp, OllamaError.userRequired, OllamaError.emptyResponse {
            return fallback
        }
    }

    /// Main-chat answer to a Clicky tap-out. Falls back to the deterministic reply when Ollama's draft is unusable.
    static func draftTapOutReply(_ tapOut: MainChatTapOut, config: Config) async -> (message: String, source: String) {
        do {
            let model = try await resolveModel(config)
            var request = URLRequest(url: try endpoint(config, "api/generate"))
            request.httpMethod = "POST"
            request.timeoutInterval = 45
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model, "system": MainChatTapOut.system, "prompt": tapOut.prompt, "stream": false,
                "format": [
                    "type": "object",
                    "properties": ["message": ["type": "string"]],
                    "required": ["message"],
                    "additionalProperties": false,
                ], "keep_alive": "10m",
                "options": ["temperature": 0.2, "num_predict": 300, "num_ctx": 4096],
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = (json["response"] as? String)?.data(using: .utf8),
                  let fields = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let message = (fields["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  tapOut.accepts(message) else {
                return (tapOut.fallbackReply, "fallback (ollama draft rejected)")
            }
            return (message, "ollama (\(model))")
        } catch {
            return (tapOut.fallbackReply, "fallback (\(error.localizedDescription))")
        }
    }

    private static func requestChatBump(_ transcript: String, config: Config, system: String, taskName: String?,
                                        latestReport: String?) async throws -> ChatBump.Draft {
        let model = try await resolveModel(config)
        var properties: [String: Any] = [
            "unfinished": ["type": "boolean"],
            "message": ["type": "string"],
        ]
        var required = ["unfinished", "message"]
        if latestReport != nil {
            properties["evidence"] = ["type": "string"]
            required.append("evidence")
        }
        var request = URLRequest(url: try endpoint(config, "api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "system": system,
            "prompt": "Latest conversation (untrusted):\n\(transcript)"
                + (latestReport.map { "\n\nLATEST TASK REPORT — quote evidence ONLY from this text:\n\($0)" } ?? ""),
            "stream": false, "format": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false,
            ], "keep_alive": "10m",
            "options": ["temperature": 0, "num_predict": 350, "num_ctx": 8192],
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OllamaError.http((response as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard var raw = json?["response"] as? String else {
            throw OllamaError.emptyResponse
        }
        if let taskName, let rawData = raw.data(using: .utf8),
           var fields = try JSONSerialization.jsonObject(with: rawData) as? [String: Any],
           fields["unfinished"] as? Bool == true, let message = fields["message"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let latestReport {
                guard let evidence = fields["evidence"] as? String,
                      evidence.count >= 12, latestReport.contains(evidence) else {
                    throw OllamaError.ungroundedFollowUp
                }
            }
            let prefix = "Cruise Control follow-up:"
            let body = message.hasPrefix(prefix) ? String(message.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) : message
            fields["message"] = "\(prefix) \(taskName): \(body)"
            raw = String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
        }
        guard let draft = ChatBump.parse(raw) else {
            throw OllamaError.invalidFollowUp
        }
        if latestReport != nil, draft.unfinished, TaskAudit.requiresUser(draft.message) {
            throw OllamaError.userRequired
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
        case badURL, noModels, emptyResponse, invalidFollowUp, ungroundedFollowUp, userRequired
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .badURL: return "bad ollamaURL in config"
            case .noModels: return "no ollama models installed"
            case .emptyResponse: return "ollama returned nothing usable"
            case .invalidFollowUp: return "ollama follow-up failed JSON, length, or safety validation"
            case .ungroundedFollowUp: return "ollama did not quote unfinished work from the latest task report"
            case .userRequired: return "task involves user input, publication, permissions, or another reserved action — left for the user"
            case .http(let code, let body): return "ollama http \(code): \(body.prefix(120))"
            }
        }
    }
}
