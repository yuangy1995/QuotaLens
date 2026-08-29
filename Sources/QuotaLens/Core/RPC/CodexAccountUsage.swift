import Foundation

public struct CodexAccountUsagePayload: Decodable, Sendable {
    public struct Summary: Decodable, Sendable {
        public let lifetimeTokens: Int64?
        public let peakDailyTokens: Int64?
        public let longestRunningTurnSec: Int64?
        public let currentStreakDays: Int64?
        public let longestStreakDays: Int64?
    }

    public struct DailyBucket: Decodable, Sendable {
        public let startDate: String
        public let tokens: Int64

        fileprivate func date(in calendar: Calendar) -> Date? {
            let bytes = Array(startDate.utf8)
            guard bytes.count == 10,
                  bytes[4] == 0x2D,
                  bytes[7] == 0x2D,
                  bytes.enumerated().allSatisfy({ index, byte in
                      index == 4 || index == 7 || (0x30...0x39).contains(byte)
                  }),
                  let year = Int(startDate.prefix(4)),
                  let month = Int(startDate.dropFirst(5).prefix(2)),
                  let day = Int(startDate.suffix(2)) else { return nil }
            let components = DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day
            )
            guard let parsed = calendar.date(from: components) else { return nil }
            let roundTrip = calendar.dateComponents([.year, .month, .day], from: parsed)
            guard roundTrip.year == year,
                  roundTrip.month == month,
                  roundTrip.day == day else { return nil }
            return calendar.startOfDay(for: parsed)
        }
    }

    public let summary: Summary
    public let dailyUsageBuckets: [DailyBucket]?
}

public struct CodexAccountUsageSnapshot: Sendable {
    public struct Day: Identifiable, Sendable {
        public var id: Date { date }
        public let date: Date
        public let tokens: Int64
    }

    public let lifetimeTokens: Int64?
    public let peakDailyTokens: Int64?
    public let longestRunningTurnSeconds: Int64?
    public let currentStreakDays: Int64?
    public let longestStreakDays: Int64?
    public let daily: [Day]
    public let isDailyUsageAvailable: Bool
    public let capturedAt: Date

    public init(
        payload: CodexAccountUsagePayload,
        trailingDays: Int = 365,
        capturedAt: Date = Date()
    ) {
        func nonnegative(_ value: Int64?) -> Int64? {
            guard let value, value >= 0 else { return nil }
            return value
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: capturedAt)
        var byDate: [Date: Int64] = [:]
        for bucket in payload.dailyUsageBuckets ?? [] where bucket.tokens >= 0 {
            guard let day = bucket.date(in: calendar), day <= today else { continue }
            let (sum, overflow) = byDate[day, default: 0].addingReportingOverflow(bucket.tokens)
            byDate[day] = overflow ? Int64.max : sum
        }
        self.lifetimeTokens = nonnegative(payload.summary.lifetimeTokens)
        self.peakDailyTokens = nonnegative(payload.summary.peakDailyTokens)
        self.longestRunningTurnSeconds = nonnegative(payload.summary.longestRunningTurnSec)
        self.currentStreakDays = nonnegative(payload.summary.currentStreakDays)
        self.longestStreakDays = nonnegative(payload.summary.longestStreakDays)
        self.isDailyUsageAvailable = payload.dailyUsageBuckets != nil
        if payload.dailyUsageBuckets != nil, trailingDays > 0 {
            let end = byDate.keys.max() ?? today
            self.daily = (0..<trailingDays).compactMap { offset in
                guard let date = calendar.date(
                    byAdding: .day,
                    value: offset - trailingDays + 1,
                    to: end
                ) else { return nil }
                let day = calendar.startOfDay(for: date)
                return Day(date: day, tokens: byDate[day, default: 0])
            }
        } else {
            self.daily = []
        }
        self.capturedAt = capturedAt
    }
}
