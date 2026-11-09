import Testing
@testable import CruiseCore

@Suite struct NotchVisibilityTests {
    @Test func cruiseModeRemainsVisibleWithoutClicky() {
        for onlyWithClicky in [true, false] {
            var config = Config()
            config.mode = .cruise
            config.showOnlyWithClicky = onlyWithClicky
            #expect(config.shouldShowNotch(clickyRunning: false))
            #expect(config.shouldShowNotch(clickyRunning: true))
        }
    }

    @Test func otherModesPreserveClickyVisibilityPreference() {
        for mode in [DriveMode.manual, .rest] {
            var config = Config()
            config.mode = mode
            #expect(!config.shouldShowNotch(clickyRunning: false))
            #expect(config.shouldShowNotch(clickyRunning: true))
            config.showOnlyWithClicky = false
            #expect(config.shouldShowNotch(clickyRunning: false))
        }
    }

    @Test func modeChangesImmediatelyChangeVisibilityPolicy() {
        var config = Config()
        #expect(!config.shouldShowNotch(clickyRunning: false))
        config.mode = .cruise
        #expect(config.shouldShowNotch(clickyRunning: false))
        config.mode = .manual
        #expect(!config.shouldShowNotch(clickyRunning: false))
    }
}
