import Foundation
import Testing
@testable import CruiseCore

@Suite struct ActivityStatsTests {
    @Test func persistsIndependentActualActionCounts() throws {
        var stats = ActivityStats()
        stats.approved = 4
        stats.declined = 2
        stats.continued = 3
        stats.vscodeApproved = 9
        stats.vscodeHeldForReview = 1
        stats.vscodeContinued = 2
        stats.vscodeModelSwitches = 1
        let restored = try JSONDecoder().decode(ActivityStats.self, from: JSONEncoder().encode(stats))
        #expect(restored == stats)
        #expect(restored.approved == 4)
        #expect(restored.vscodeApproved == 9)
    }

    @Test func startsAtZeroWithoutFabricatingHistory() {
        let stats = ActivityStats()
        #expect(stats.approved == 0 && stats.declined == 0 && stats.continued == 0)
        #expect(stats.vscodeApproved == 0 && stats.vscodeContinued == 0)
        #expect(stats.vscodeHeldForReview == 0 && stats.vscodeModelSwitches == 0)
    }
}
