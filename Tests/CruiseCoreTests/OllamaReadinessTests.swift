import Testing
@testable import CruiseCore

@Suite struct OllamaReadinessTests {
    @Test func distinguishesMissingInstallationFromStoppedService() {
        #expect(OllamaReadiness.evaluate(installed: false, reachable: false, models: [], configuredModel: "") == .missingInstallation)
        #expect(OllamaReadiness.evaluate(installed: true, reachable: false, models: [], configuredModel: "") == .serviceStopped)
    }

    @Test func identifiesMissingAndReadyModels() {
        #expect(OllamaReadiness.evaluate(installed: true, reachable: true, models: [], configuredModel: "") == .noModel)
        #expect(OllamaReadiness.evaluate(installed: true, reachable: true, models: ["nomic-embed-text"], configuredModel: "") == .noModel)
        #expect(OllamaReadiness.evaluate(installed: true, reachable: true, models: ["qwen2.5:3b"], configuredModel: "") == .ready("qwen2.5:3b"))
        #expect(OllamaReadiness.evaluate(installed: true, reachable: true, models: ["qwen2.5:3b"], configuredModel: "missing-model") == .configuredModelMissing("missing-model"))
    }

    @Test func treatsLatestTagAsEquivalent() {
        #expect(OllamaReadiness.evaluate(installed: true, reachable: true, models: ["qwen2.5:3b"], configuredModel: "qwen2.5:3b:latest") == .ready("qwen2.5:3b"))
        #expect(OllamaReadiness.evaluate(installed: true, reachable: true, models: ["qwen2.5:3b:latest"], configuredModel: "qwen2.5:3b") == .ready("qwen2.5:3b:latest"))
    }
}
