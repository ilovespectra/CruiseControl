import Foundation

/// User stops outlive recovery attempts and app relaunches. An observed new running turn clears them, as does the
/// user explicitly opting the task back into Auto-bump; a released stop is not re-learned from the same old turn.
public struct TaskRecovery: Codable, Equatable, Sendable {
    public private(set) var stoppedTasks: Set<String> = []
    public private(set) var releasedTasks: Set<String> = []
    /// Explicit user stops are sticky until the user resumes or releases the task in Cruise.
    public private(set) var manualStops: Set<String> = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stoppedTasks = try container.decodeIfPresent(Set<String>.self, forKey: .stoppedTasks) ?? []
        releasedTasks = try container.decodeIfPresent(Set<String>.self, forKey: .releasedTasks) ?? []
        manualStops = try container.decodeIfPresent(Set<String>.self, forKey: .manualStops) ?? []
    }

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
        let key = Matcher.normalize(task)
        return stoppedTasks.contains(key) || manualStops.contains(key)
    }

    public mutating func release(task: String) {
        let key = Matcher.normalize(task)
        stoppedTasks.remove(key)
        manualStops.remove(key)
        releasedTasks.insert(key)
    }

    public mutating func observe(task: String, status: String?, latestTurnStatus: String?) {
        let key = Matcher.normalize(task)
        guard !key.isEmpty else { return }
        if manualStops.contains(key) {
            stoppedTasks.insert(key)
            releasedTasks.remove(key)
            return
        }
        if StallTracker.isBusy(latestTurnStatus ?? status) {
            stoppedTasks.remove(key)
            releasedTasks.remove(key)
        } else if Self.isStopped(status) || Self.isStopped(latestTurnStatus), !releasedTasks.contains(key) {
            stoppedTasks.insert(key)
        }
    }

    /// An explicit user stop (Mark as Finished) always applies, even after a release.
    public mutating func stopByUser(task: String) {
        let key = Matcher.normalize(task)
        releasedTasks.remove(key)
        manualStops.insert(key)
        stoppedTasks.insert(key)
    }
}
