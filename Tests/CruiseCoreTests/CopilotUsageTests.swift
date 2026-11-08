import Foundation
import Testing
@testable import CruiseCore

@Suite struct CopilotUsageTests {
    @Test func parsesRealWarningVariants() {
        #expect(CopilotUsage.percentage(in: "You've used 75% of your credits.") == 75)
        #expect(CopilotUsage.percentage(in: "You’ve used 90% of your monthly credits") == 90)
        #expect(CopilotUsage.percentage(in: "You have used 25.5% of your included credits") == 25.5)
        #expect(CopilotUsage.percentage(in: "You've used 100% of your premium requests") == 100)
        #expect(CopilotUsage.percentage(in: "You've used 25% of your credits. You've used 50% of your credits.") == 50)
    }

    @Test func rejectsUnrelatedPercentages() {
        for text in ["CPU used 90%", "You have 25% of your credits remaining", "You've used 101% of your credits",
                     "You've used -25% of your credits", "75% tests passed", "You've used 75% of your disk"] {
            #expect(CopilotUsage.percentage(in: text) == nil)
        }
    }

    @Test func stopsExactlyAtEachThreshold() {
        for cutoff in CopilotUsage.cutoffs {
            var config = Config()
            config.vscodeUsageCutoff = cutoff
            config.mode = .cruise
            config.vscodeAutoApprove = true
            config.vscodeTaskBumps = true
            config.autoSelectVSCodeModel = true
            config.vscodeObservedUsage = Double(cutoff) - 0.1
            let below = config.stopAtUsageCutoff()
            #expect(!below)
            #expect(config.mode == .cruise)
            config.vscodeObservedUsage = Double(cutoff)
            let stopped = config.stopAtUsageCutoff()
            #expect(stopped)
            #expect(config.mode == .manual)
            #expect(!config.vscodeAutoApprove && !config.vscodeTaskBumps && !config.autoSelectVSCodeModel && !config.autoUpdateClicky)
            #expect(config.usageCutoffReached)
            let again = config.stopAtUsageCutoff()
            #expect(!again)
            config.vscodeAutoApprove = true
            let reenabled = config.stopAtUsageCutoff()
            #expect(reenabled)
            #expect(!config.vscodeAutoApprove)
        }
    }

    @Test func defaultsAndRestartPersistence() throws {
        var config = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        #expect(config.vscodeUsageCutoff == nil && config.vscodeObservedUsage == nil)
        config.vscodeObservedUsage = 90
        #expect(!config.usageCutoffReached)
        config.vscodeUsageCutoff = 75
        let restored = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(restored.usageCutoffReached)
        #expect(restored.vscodeObservedUsage == 90)
    }

    @Test func rejectsInvalidConfiguration() {
        for json in [#"{"vscodeUsageCutoff":-1}"#, #"{"vscodeUsageCutoff":101}"#, #"{"vscodeObservedUsage":101}"#] {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
            }
        }
    }
}
