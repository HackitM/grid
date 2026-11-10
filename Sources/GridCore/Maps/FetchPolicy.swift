import Foundation

/// Backoff and daily budget for polite, serial fetching (Overpass). Throttling statuses
/// (429, 406, 504) back off exponentially from `base` up to `max`; success resets the backoff.
/// Every request counts once toward the budget, which resets each UTC day.
public struct FetchPolicy: Codable, Sendable, Equatable {
    public let base: TimeInterval
    public let maxBackoff: TimeInterval
    public let dailyBudget: Int
    public private(set) var backoff: TimeInterval = 0
    public private(set) var retryAt: Date?
    private var dayKey: Int = Int.min
    private var used: Int = 0

    public init(base: TimeInterval = 30, max: TimeInterval = 600, dailyBudget: Int = 60) {
        let b = base.isFinite ? Swift.max(1, base) : 30
        self.base = b
        self.maxBackoff = max.isFinite ? Swift.max(b, max) : 600
        self.dailyBudget = Swift.max(0, dailyBudget)
    }

    private static func day(_ d: Date) -> Int { Int((d.timeIntervalSince1970 / 86_400).rounded(.down)) }

    private mutating func rollDay(_ now: Date) {
        let d = Self.day(now)
        if d != dayKey { dayKey = d; used = 0 }
    }

    /// Requests made today (UTC).
    public func usedToday(now: Date) -> Int { Self.day(now) == dayKey ? used : 0 }

    public mutating func failed(status: Int, now: Date) {
        rollDay(now)
        used += 1
        if status == 429 || status == 406 || status == 504 {
            backoff = backoff <= 0 ? base : Swift.min(maxBackoff, backoff * 2)
            retryAt = now.addingTimeInterval(backoff)
        }
    }

    public mutating func succeeded(now: Date) {
        rollDay(now)
        used += 1
        backoff = 0
        retryAt = nil
    }

    public func canRequest(now: Date) -> Bool {
        if let r = retryAt, now < r { return false }
        return usedToday(now: now) < dailyBudget
    }
}
