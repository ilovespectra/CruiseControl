import Foundation

public enum NotchInspection {
    public static func shouldInspect(workingCount: Int?, mode: DriveMode, idleSeconds: Double,
                                     lastProbe: Date, now: Date, config: Config) -> Bool {
        mode != .manual && (workingCount ?? 0) <= 0
            && idleSeconds >= config.awayIdleSeconds
            && now.timeIntervalSince(lastProbe) >= config.stallCheckMinutes * 60
    }
}
