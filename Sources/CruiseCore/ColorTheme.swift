import Foundation

public enum ColorTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case red, yellow, blue, green

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    public static func heyClickyCursorTheme(hex: String) -> ColorTheme? {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 7, value.first == "#",
              let rgb = UInt32(value.dropFirst(), radix: 16) else { return nil }
        let r = Double((rgb >> 16) & 255) / 255
        let g = Double((rgb >> 8) & 255) / 255
        let b = Double(rgb & 255) / 255
        let high = max(r, g, b), low = min(r, g, b)
        let delta = high - low
        guard high > 0.15, delta / high > 0.3 else { return nil }
        var hue: Double
        if high == r { hue = 60 * (g - b) / delta }
        else if high == g { hue = 60 * (2 + (b - r) / delta) }
        else { hue = 60 * (4 + (r - g) / delta) }
        if hue < 0 { hue += 360 }
        switch hue {
        case 0..<40, 340..<360: return .red
        case 40..<75: return .yellow
        case 75..<180: return .green
        case 180..<260: return .blue
        default: return nil
        }
    }

    // Exact sRGB pixels from each supplied gauge: (148, 40), (148, 235), (148, 75).
    public var accentRGB: UInt32 {
        switch self {
        case .red: return 0xF92517
        case .yellow: return 0xFEE743
        case .blue: return 0x2967F8
        case .green: return 0x24AF20
        }
    }

    public var shadowRGB: UInt32 {
        switch self {
        case .red: return 0x640000
        case .yellow: return 0xF38F03
        case .blue: return 0x071292
        case .green: return 0x024C0D
        }
    }

    public var glyphRGB: UInt32 {
        switch self {
        case .red: return 0xFEF7ED
        case .yellow: return 0xBF750C
        case .blue: return 0xDDEAFD
        case .green: return 0xEBFCDA
        }
    }
}
