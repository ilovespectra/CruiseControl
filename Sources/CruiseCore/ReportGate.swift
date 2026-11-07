import Foundation

/// Decides when a "Full report" button is a genuinely new, unfinished task worth auto-continuing.
///
/// HeyClicky keeps a "Full report" button on every historical message, so we only act when exactly
/// one previously-unseen report appears at the end of the transcript while we were already watching.
public struct ReportGate: Sendable {
    public enum Decision: Equatable, Sendable {
        case none
        case seeded(Int)
        case disabled
        case stale
        case rateLimited
        case trigger(index: Int)
    }

    public struct Limits: Sendable {
        public var freshness: TimeInterval
        public var maxPerHour: Int
        public var minInterval: TimeInterval

        public init(freshness: TimeInterval, maxPerHour: Int, minInterval: TimeInterval) {
            self.freshness = freshness
            self.maxPerHour = maxPerHour
            self.minInterval = minInterval
        }

        public init(config: Config) {
            self.init(
                freshness: config.reportFreshnessMinutes * 60,
                maxPerHour: config.maxContinuesPerHour,
                minInterval: config.minSecondsBetweenContinues
            )
        }
    }

    public private(set) var known: Set<String>
    public private(set) var warm = false
    public private(set) var continueTimes: [Date] = []

    public init(known: Set<String> = [], continueTimes: [Date] = []) {
        self.known = known
        self.continueTimes = continueTimes
    }

    /// Call when HeyClicky isn't running so the next sighting re-seeds instead of triggering.
    public mutating func coolDown() {
        warm = false
    }

    public mutating func evaluate(
        fingerprints: [String],
        headers: [String],
        enabled: Bool,
        now: Date,
        limits: Limits,
        calendar: Calendar = .current
    ) -> Decision {
        let unknown = fingerprints.indices.filter { !known.contains(fingerprints[$0]) }
        if known.count > 5000 { known = [] }
        known.formUnion(fingerprints)
        let wasWarm = warm
        warm = true

        guard !unknown.isEmpty else { return .none }
        guard wasWarm, unknown.count == 1, unknown[0] == fingerprints.count - 1 else {
            return .seeded(unknown.count)
        }
        guard enabled else { return .disabled }

        let index = unknown[0]
        let header = index < headers.count ? headers[index] : ""
        guard Matcher.isFresh(header: header, now: now, maxAge: limits.freshness, calendar: calendar) else {
            return .stale
        }

        return canContinue(now: now, limits: limits) ? .trigger(index: index) : .rateLimited
    }

    /// Shared budget for every automatic message (full-report continues and needs-you nudges).
    public mutating func canContinue(now: Date, limits: Limits) -> Bool {
        continueTimes = continueTimes.filter { now.timeIntervalSince($0) < 3600 }
        if continueTimes.count >= limits.maxPerHour { return false }
        if let last = continueTimes.last, now.timeIntervalSince(last) < limits.minInterval { return false }
        return true
    }

    public mutating func recordContinue(at date: Date) {
        continueTimes.append(date)
    }
}
