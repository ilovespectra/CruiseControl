import Foundation

public enum AudioVolumeTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case heyClicky
    case visualStudioCode

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .heyClicky: "HeyClicky"
        case .visualStudioCode: "VS Code audio"
        }
    }

    /// Only process bundles owned by the named app are eligible for interception.
    /// Shared browsers and system processes are intentionally excluded.
    public var bundleIdentifierPrefix: String {
        switch self {
        case .heyClicky: "com.humansongs.clicky"
        case .visualStudioCode: "com.microsoft.VSCode"
        }
    }

    public func matches(bundleIdentifier: String) -> Bool {
        bundleIdentifier == bundleIdentifierPrefix
            || bundleIdentifier.hasPrefix(bundleIdentifierPrefix + ".")
    }
}

/// Per-app linear gains, independent from the default output-device volume.
public struct AudioVolumePreferences: Codable, Equatable, Sendable {
    public private(set) var heyClicky: Float
    public private(set) var visualStudioCode: Float

    public init(heyClicky: Float = 1, visualStudioCode: Float = 1) {
        self.heyClicky = AudioVolumeMath.clampedGain(heyClicky)
        self.visualStudioCode = AudioVolumeMath.clampedGain(visualStudioCode)
    }

    public func volume(for target: AudioVolumeTarget) -> Float {
        switch target {
        case .heyClicky: heyClicky
        case .visualStudioCode: visualStudioCode
        }
    }

    public mutating func setVolume(_ value: Float, for target: AudioVolumeTarget) {
        let value = AudioVolumeMath.clampedGain(value)
        switch target {
        case .heyClicky: heyClicky = value
        case .visualStudioCode: visualStudioCode = value
        }
    }

    public var hasAttenuation: Bool {
        heyClicky < 1 || visualStudioCode < 1
    }
}

public enum AudioVolumeMath {
    @inline(__always)
    public static func clampedGain(_ value: Float) -> Float {
        guard value.isFinite else { return 1 }
        return min(1, max(0, value))
    }

    /// Applies a safe linear gain. Boosting above desktop level is deliberately unsupported.
    @inline(__always)
    public static func scaledSample(_ sample: Float, gain: Float) -> Float {
        min(1, max(-1, sample * clampedGain(gain)))
    }
}
