import Foundation

/// The user's update preferences and what follows from them: when to check, and whether a found
/// release should be offered. Pure value logic so it can be tested.
public struct UpdatePolicy: Codable, Equatable, Sendable {
    /// nil until the user has answered the one-time "check daily?" question.
    public var checkDaily: Bool?
    public var includePrereleases = false
    public var lastCheck: Date?
    /// A version the user chose to skip (hidden until something newer appears).
    public var skipped: String?
    /// "Later": no notice until this date.
    public var snoozedUntil: Date?
    /// The version whose status-bar notice was already shown and dismissed or opened.
    public var noticed: String?

    public static let interval: TimeInterval = 24 * 3600
    public static let snooze: TimeInterval = 7 * 24 * 3600

    public init(checkDaily: Bool? = nil) { self.checkDaily = checkDaily }

    /// Whether an automatic (background) check is due. Manual checks ignore this.
    public func isCheckDue(now: Date) -> Bool {
        guard checkDaily == true else { return false }
        guard let last = lastCheck else { return true }
        // A little early is fine (the scheduler has tolerance); a clock set back still checks.
        return now.timeIntervalSince(last) >= Self.interval - 3600 || now < last
    }

    /// Whether `latest` is newer than the running version at all.
    public static func isNewer(_ latest: SemanticVersion, than current: SemanticVersion) -> Bool { current < latest }

    /// Whether to offer `latest` unprompted (status bar). Settings always shows it.
    public func shouldNotify(_ latest: SemanticVersion, current: SemanticVersion, now: Date) -> Bool {
        guard Self.isNewer(latest, than: current) else { return false }
        if let s = skipped.flatMap(SemanticVersion.init), latest <= s { return false }
        if let until = snoozedUntil, now < until { return false }
        if noticed == latest.description { return false }
        return true
    }

    public mutating func skip(_ v: SemanticVersion) { skipped = v.description }
    public mutating func later(now: Date) { snoozedUntil = now.addingTimeInterval(Self.snooze) }
}
