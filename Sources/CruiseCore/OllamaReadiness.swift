import Foundation

/// Describes whether Cruise Control can reach a usable local Ollama model.
public enum OllamaReadiness: Equatable, Sendable {
    case missingInstallation
    case serviceStopped
    case noModel
    case configuredModelMissing(String)
    case ready(String)

    public static func evaluate(installed: Bool, reachable: Bool, models: [String], configuredModel: String) -> Self {
        guard reachable else { return installed ? .serviceStopped : .missingInstallation }

        let configured = configuredModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            guard let model = models.first(where: { matches($0, configured) }) else {
                return .configuredModelMissing(configured)
            }
            return .ready(model)
        }

        guard let model = models.first(where: { !$0.lowercased().contains("embed") }) else {
            return .noModel
        }
        return .ready(model)
    }

    private static func matches(_ installed: String, _ configured: String) -> Bool {
        func normalized(_ value: String) -> String {
            let value = value.lowercased()
            return value.hasSuffix(":latest") ? String(value.dropLast(7)) : value
        }
        return normalized(installed) == normalized(configured)
    }
}
