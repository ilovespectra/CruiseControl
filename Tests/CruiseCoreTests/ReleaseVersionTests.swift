import Testing
@testable import CruiseCore

@Suite struct ReleaseVersionTests {
    @Test func ordersNumericVersions() {
        #expect(ReleaseVersion("v1.0.10")! > ReleaseVersion("1.0.9")!)
        #expect(ReleaseVersion("2.0.0")! > ReleaseVersion("1.99.99")!)
        #expect(ReleaseVersion("v1.0.0") == ReleaseVersion("1.0.0"))
    }
    @Test func rejectsMalformedVersions() {
        for raw in ["1", "1.0", "1..0", "1.0.0-beta", "-1.0.0", "main", "1.0.0.0"] {
            #expect(ReleaseVersion(raw) == nil)
        }
    }
}
