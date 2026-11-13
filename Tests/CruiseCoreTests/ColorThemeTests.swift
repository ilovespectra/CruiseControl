import Foundation
import Testing
@testable import CruiseCore

struct ColorThemeTests {
    @Test func importsSupportedHeyClickyCursorColors() {
        #expect(ColorTheme.heyClickyCursorTheme(hex: "#26C281") == .green)
        #expect(ColorTheme.heyClickyCursorTheme(hex: "#FF4545") == .red)
        #expect(ColorTheme.heyClickyCursorTheme(hex: "#FFD52A") == .yellow)
        #expect(ColorTheme.heyClickyCursorTheme(hex: "#3478F6") == .blue)
        for invalid in ["", "green", "#GGGGGG", "#FFFFFF", "#000000", "#FF00FF", "#12345678"] {
            #expect(ColorTheme.heyClickyCursorTheme(hex: invalid) == nil)
        }
    }
    @Test func legacyConfigDefaultsToBlue() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        #expect(config.colorTheme == .blue)
    }

    @Test func everyThemePersistsWithoutChangingAutomation() throws {
        for theme in ColorTheme.allCases {
            var config = Config()
            config.colorTheme = theme
            config.mode = .rest
            config.vscodeAutoBumpChatKeys = ["explicit-opt-in"]
            let restored = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
            #expect(restored == config)
        }
    }

    @Test func paletteMatchesSuppliedArtworkPixels() {
        #expect(ColorTheme.allCases.map(\.accentRGB) == [0xF92517, 0xFEE743, 0x2967F8, 0x24AF20])
        #expect(ColorTheme.allCases.map(\.shadowRGB) == [0x640000, 0xF38F03, 0x071292, 0x024C0D])
        #expect(ColorTheme.allCases.map(\.glyphRGB) == [0xFEF7ED, 0xBF750C, 0xDDEAFD, 0xEBFCDA])
    }
}
