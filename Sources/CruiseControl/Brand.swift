import SwiftUI
import CoreText
import CruiseCore
import Observation

@Observable
final class BrandPalette {
    static let shared = BrandPalette()
    var theme: ColorTheme = .blue
}

/// Same open-license families heyclicky.com uses: Inter (UI), Instrument Serif (display), Geist Mono (logs).
enum BrandFont {
    static func register() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        let fonts = urls.filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
        CTFontManagerRegisterFontURLs(fonts as CFArray, .process, true, nil)
    }

    static func inter(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Inter", size: size).weight(weight)
    }

    static func serif(_ size: CGFloat) -> Font {
        .custom("Instrument Serif", size: size)
    }

    static func mono(_ size: CGFloat) -> Font {
        .custom("Geist Mono", size: size)
    }
}

enum Brand {
    static func color(_ rgb: UInt32) -> Color {
        Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
              green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
    }

    static var tint: Color { color(BrandPalette.shared.theme.accentRGB) }
    static var lavender: Color { color(BrandPalette.shared.theme.glyphRGB) }
    static var periwinkle: Color { tint }
    static var navy: Color { color(BrandPalette.shared.theme.shadowRGB) }
    static var royal: Color { tint }
    static var onAccent: Color { BrandPalette.shared.theme == .yellow ? .black : .white }
    static let card = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let youBadge = Color(red: 0.89, green: 0.66, blue: 0.27)

    static var primaryFill: LinearGradient { LinearGradient(
        colors: [tint, navy],
        startPoint: .top, endPoint: .bottom
    ) }
    static let secondaryFill = LinearGradient(
        colors: [Color.white, Color(red: 0.86, green: 0.86, blue: 0.88)],
        startPoint: .top, endPoint: .bottom
    )

    static func accent(for mode: DriveMode) -> Color {
        tint
    }

    static func symbol(for mode: DriveMode) -> String {
        switch mode {
        case .manual: return "hand.tap.fill"
        case .rest: return "cup.and.saucer.fill"
        case .cruise: return "steeringwheel"
        }
    }
}

/// HeyClicky's "^\_ ^" face.
/// Cruise Control's own mark: a speedometer arc with a navigation-arrow needle (autopilot).
/// Coordinates match site/icon.svg (1024 grid).
struct CruiseGauge: Shape {
    var part: Part
    enum Part { case travelled, remaining, needle }

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 1024
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        let center = p(512, 600)
        var path = Path()
        switch part {
        case .travelled:
            path.addArc(center: center, radius: 300 * s, startAngle: .degrees(160), endAngle: .degrees(315), clockwise: false)
        case .remaining:
            path.addArc(center: center, radius: 300 * s, startAngle: .degrees(315), endAngle: .degrees(20), clockwise: false)
        case .needle:
            var arrow = Path()
            arrow.move(to: p(512, 330))
            arrow.addLine(to: p(586, 528))
            arrow.addQuadCurve(to: p(438, 528), control: p(512, 492))
            arrow.closeSubpath()
            let t = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: .pi / 4)
                .translatedBy(x: -center.x, y: -center.y)
            path.addPath(arrow, transform: t)
            path.addEllipse(in: CGRect(x: center.x - 34 * s, y: center.y - 34 * s, width: 68 * s, height: 68 * s))
        }
        return path
    }
}

struct CruiseGlyph: View {
    var size: CGFloat

    var body: some View {
        ModeGlyph(mode: .cruise, size: size)
    }
}

struct ModeGlyph: View {
    var mode: DriveMode
    var size: CGFloat

    var body: some View {
        Group {
            if mode == .manual {
                Image(systemName: Brand.symbol(for: mode))
                    .resizable().scaledToFit()
                    .foregroundStyle(Brand.tint)
                    .padding(size * 0.16)
            } else {
                Image(nsImage: BrandIcons.image(theme: BrandPalette.shared.theme, mode: mode))
                    .resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(mode.title)
    }
}

enum BrandIcons {
    private static let images: [String: NSImage] = {
        let packaged = Bundle.main.resourceURL?
            .appendingPathComponent("CruiseControl_CruiseControl.bundle", isDirectory: true)
        let bundle: Bundle
        if let packaged, let installed = Bundle(url: packaged) {
            bundle = installed
        } else {
            bundle = .module
        }
        var images: [String: NSImage] = [:]
        for theme in ColorTheme.allCases {
            for mode in ["cruise", "rest"] {
                let name = "\(theme.rawValue)-\(mode)"
                guard let url = bundle.url(forResource: name, withExtension: "png"),
                      let image = NSImage(contentsOf: url), image.isValid else {
                    preconditionFailure("Missing or invalid brand icon: \(name).png in \(bundle.bundlePath)")
                }
                image.isTemplate = false
                images[name] = image
            }
        }
        return images
    }()

    static func image(theme: ColorTheme, mode: DriveMode) -> NSImage {
        let name = "\(theme.rawValue)-\(mode == .rest ? "rest" : "cruise")"
        guard let image = images[name] else { preconditionFailure("Unknown brand icon: \(name)") }
        return image
    }

    static func validate() {
        _ = images
    }
}

/// Pill-shaped button styled like HeyClicky's "Go ahead" / "Not now" buttons.
struct ClickyPillButtonStyle: ButtonStyle {
    var primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, primary: primary)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let primary: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(BrandFont.inter(11.5, .semibold))
                .foregroundStyle(primary && isEnabled ? Brand.onAccent : Color.black.opacity(isEnabled ? 0.85 : 0.35))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(primary && isEnabled ? Brand.primaryFill : Brand.secondaryFill)
                )
                .overlay(
                    Capsule().strokeBorder(primary && isEnabled ? Brand.royal : Color.black.opacity(isEnabled ? 0.25 : 0.12), lineWidth: 1.5)
                )
                .saturation(isEnabled ? 1 : 0)
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.55)
        }
    }
}
