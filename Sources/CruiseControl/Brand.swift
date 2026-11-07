import SwiftUI
import CoreText
import CruiseCore

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
    // Sampled from HeyClicky's notch prompt: lavender glyph tile, navy face, periwinkle primary button.
    static let lavender = Color(red: 0.86, green: 0.89, blue: 1.0)
    static let periwinkle = Color(red: 0.71, green: 0.78, blue: 1.0)
    static let navy = Color(red: 0.16, green: 0.21, blue: 0.55)
    static let royal = Color(red: 0.24, green: 0.29, blue: 0.86)
    static let card = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let youBadge = Color(red: 0.89, green: 0.66, blue: 0.27)

    static let primaryFill = LinearGradient(
        colors: [Color(red: 0.80, green: 0.85, blue: 1.0), Color(red: 0.64, green: 0.72, blue: 1.0)],
        startPoint: .top, endPoint: .bottom
    )
    static let secondaryFill = LinearGradient(
        colors: [Color.white, Color(red: 0.86, green: 0.86, blue: 0.88)],
        startPoint: .top, endPoint: .bottom
    )

    static func accent(for mode: DriveMode) -> Color {
        switch mode {
        case .manual: return Color.white.opacity(0.7)
        case .rest: return youBadge
        case .cruise: return Color(red: 0.36, green: 0.88, blue: 0.56)
        }
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
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.05, green: 0.08, blue: 0.27),
                                              Color(red: 0.16, green: 0.25, blue: 0.84),
                                              Color(red: 0.43, green: 0.55, blue: 1.0)],
                                     startPoint: .topLeading, endPoint: .bottom))
            let line = StrokeStyle(lineWidth: size * 0.0625, lineCap: .round)
            CruiseGauge(part: .travelled).stroke(Color.white, style: line)
            CruiseGauge(part: .remaining).stroke(Color.white.opacity(0.3), style: line)
            CruiseGauge(part: .needle).fill(Color.white)
        }
        .frame(width: size, height: size)
    }
}

/// Pill-shaped button styled like HeyClicky's "Go ahead" / "Not now" buttons.
struct ClickyPillButtonStyle: ButtonStyle {
    var primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BrandFont.inter(11.5, .semibold))
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(primary ? Brand.primaryFill : Brand.secondaryFill)
            )
            .overlay(
                Capsule().strokeBorder(primary ? Brand.royal : Color.black.opacity(0.25), lineWidth: 1.5)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
