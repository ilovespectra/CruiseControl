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

    @Test func notchPillNestsBesideHeyClickyOnNotchedDisplays() {
        let right = NotchPlacement.pillX(screenMinX: 0, screenMaxX: 1440, pillWidth: 96,
                                         notchLeftWidth: 520, notchRightWidth: 520, sideIsRight: true)
        let left = NotchPlacement.pillX(screenMinX: 0, screenMaxX: 1440, pillWidth: 96,
                                        notchLeftWidth: 520, notchRightWidth: 520, sideIsRight: false)
        #expect(right > 720)
        #expect(left < 720 - 96)
    }

    @Test func notchPillUsesScreenEdgeWhenDisplayHasNoNotchGeometry() {
        #expect(NotchPlacement.pillX(screenMinX: 0, screenMaxX: 1920, pillWidth: 96,
                                     notchLeftWidth: nil, notchRightWidth: nil, sideIsRight: true) == 1824)
        #expect(NotchPlacement.pillX(screenMinX: -1920, screenMaxX: 0, pillWidth: 96,
                                     notchLeftWidth: nil, notchRightWidth: nil, sideIsRight: false) == -1920)
    }
}
