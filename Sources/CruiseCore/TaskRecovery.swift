import Foundation

/// User stops outlive recovery attempts and app relaunches. Only an observed new running turn clears them.
public struct TaskRecovery: Codable, Equatable, Sendable {
    public private(set) var stoppedTasks: Set<String> = []

    public init() {}

    public static func isStopped(_ label: String?) -> Bool {
        guard let label else { return false }
        let normalized = Matcher.normalize(label)
        if ["stopped", "stopped by you", "paused", "cancelled", "canceled"].contains(normalized) { return true }
        // Turn footers can include elapsed time, e.g. "30s · Stopped by you."
        guard let suffix = normalized.components(separatedBy: "·").last,
              normalized.contains("·") else { return false }
        return ["stopped", "stopped by you", "paused", "cancelled", "canceled"]
            .contains(suffix.trimmingCharacters(in: .whitespaces))
    }

    public func isStopped(task: String) -> Bool {
        stoppedTasks.contains(Matcher.normalize(task))
    }

    public mutating func observe(task: String, status: String?, latestTurnStatus: String?) {
        let key = Matcher.normalize(task)
        guard !key.isEmpty else { return }
        if Self.isStopped(status) || Self.isStopped(latestTurnStatus) {
            stoppedTasks.insert(key)
        } else if StallTracker.isBusy(latestTurnStatus ?? status) {
            stoppedTasks.remove(key)
        }
    }
}
