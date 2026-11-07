import AppKit
import CruiseCore
import ScreenCaptureKit
import Vision

struct OCRConsentHit {
    let allow: CGPoint
    let deny: CGPoint
}

/// Fallback when HeyClicky's consent prompt isn't exposed to Accessibility:
/// screenshot only HeyClicky's own windows near the notch, OCR them, and locate the two buttons.
enum ScreenOCR {
    static func findConsent(config: Config) async -> OCRConsentHit? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
            return nil
        }
        let apps = content.applications.filter { config.clickyBundleIDs.contains($0.bundleIdentifier) }
        guard !apps.isEmpty else { return nil }

        for display in content.displays {
            let df = display.frame
            let width = min(df.width, 1100)
            let height = min(df.height, 380)
            let band = CGRect(x: (df.width - width) / 2, y: 0, width: width, height: height)

            let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = band
            cfg.width = Int(width * 2)
            cfg.height = Int(height * 2)
            cfg.showsCursor = false

            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else {
                continue
            }
            guard let boxes = recognize(image, config: config) else { continue }

            func toGlobal(_ r: CGRect) -> CGPoint {
                CGPoint(
                    x: df.minX + band.minX + r.midX * band.width,
                    y: df.minY + band.minY + (1 - r.midY) * band.height
                )
            }
            let allow = toGlobal(boxes.allow)
            let deny = toGlobal(boxes.deny)
            // Both buttons belong to the same small prompt card.
            guard hypot(allow.x - deny.x, allow.y - deny.y) < 400 else { continue }
            return OCRConsentHit(allow: allow, deny: deny)
        }
        return nil
    }

    private static func recognize(_ image: CGImage, config: Config) -> (allow: CGRect, deny: CGRect)? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])

        var allow: CGRect?
        var deny: CGRect?
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            if allow == nil, let r = Matcher.allowRange(in: text, config: config) {
                allow = (try? candidate.boundingBox(for: r))?.boundingBox ?? observation.boundingBox
            }
            if deny == nil, let r = Matcher.denyRange(in: text, config: config) {
                deny = (try? candidate.boundingBox(for: r))?.boundingBox ?? observation.boundingBox
            }
        }
        guard let allow, let deny else { return nil }
        return (allow, deny)
    }
}
