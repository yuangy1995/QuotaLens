// Compact, user-facing formatting for token counts and currency.

import Foundation

public enum UsageNumberFormatter {
    public static func compactTokenCount(_ count: Int64) -> String {
        let absCount = abs(count)
        let sign = count < 0 ? "-" : ""

        if absCount >= 100_000_000 {
            if L10n.isChinese {
                return L10n.compactHundredMillionUnit(roundedCompact(Double(absCount) / 100_000_000.0), sign: sign)
            }
            return "\(sign)\(roundedCompact(Double(absCount) / 1_000_000.0))M"
        }
        if absCount >= 10_000 {
            if L10n.isChinese {
                return L10n.compactTenThousandUnit(roundedCompact(Double(absCount) / 10_000.0), sign: sign)
            }
            return "\(sign)\(roundedCompact(Double(absCount) / 1_000.0))K"
        }
        return "\(count)"
    }

    public static func formattedTokenCount(_ count: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    public static func currencyUSD(_ nanoUsd: MoneyNanoUSD) -> String {
        let decimalVal = nanoUsd.toDecimal
        if nanoUsd.rawValue > 0 && nanoUsd.rawValue < 10_000_000 { // 小于 0.01 USD
            return "<$0.01"
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: decimalVal)) ?? String(format: "$%.2f", nanoUsd.toDouble)
    }

    public static func percent(_ value: Double, maximumFractionDigits: Int = 2) -> String {
        "\(roundedCompact(value, maximumFractionDigits: maximumFractionDigits))%"
    }

    public static func remainingDurationString(seconds: Double) -> String {
        let totalMinutes = max(1, Int((max(0.0, seconds) / 60.0).rounded(.up)))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return L10n.format("About %d d %d h", zhHans: "约 %d 天 %d 小时", days, hours)
        }
        if hours > 0 {
            return L10n.format("About %d h %d min", zhHans: "约 %d 小时 %d 分钟", hours, minutes)
        }
        return L10n.format("About %d min", zhHans: "约 %d 分钟", totalMinutes)
    }

    public static func roundedCompact(_ value: Double, maximumFractionDigits: Int = 2) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    public static func relativeTimeString(from date: Date, relativeTo now: Date = Date()) -> String {
        let diff = now.timeIntervalSince(date)
        if diff < 0 {
            return remainingDurationString(seconds: -diff)
        }
        if diff < 60 {
            return L10n.text("刚刚", "Just now")
        }
        if diff < 3600 {
            let mins = max(1, Int(diff / 60))
            return L10n.format("%d mins ago", zhHans: "%d 分钟前", mins)
        }
        if diff < 86400 {
            let hours = max(1, Int(diff / 3600))
            return L10n.format("%d hours ago", zhHans: "%d 小时前", hours)
        }
        let days = max(1, Int(diff / 86400))
        if days == 1 {
            return L10n.text("昨天", "Yesterday")
        }
        if days < 30 {
            return L10n.format("%d days ago", zhHans: "%d 天前", days)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
