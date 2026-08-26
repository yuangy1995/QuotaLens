// QuotaLens 用量日桶计算器
// 统一使用 Swift Calendar 与显式 TimeZone，避免 SQLite localtime 与系统时区状态不一致。

import Foundation

public struct UsageDayBucket: Hashable, Sendable {
    public let dayKey: LocalDayKey
    public let dayStartMs: Int64
    public let timeZoneIdentifier: String
}

public enum UsageDayBucketer {
    public static func bucket(
        timestampMs: Int64,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> UsageDayBucket {
        var resolvedCalendar = calendar
        resolvedCalendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: Double(timestampMs) / 1_000.0)
        let dayKey = LocalDayKey(date: date, calendar: resolvedCalendar)
        let dayStart = resolvedCalendar.startOfDay(for: date)
        return UsageDayBucket(
            dayKey: dayKey,
            dayStartMs: Int64((dayStart.timeIntervalSince1970 * 1_000).rounded()),
            timeZoneIdentifier: timeZone.identifier
        )
    }

    public static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }
}
