// Compact, user-facing formatting for token counts.

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

    public static func percent(_ value: Double, maximumFractionDigits: Int = 2) -> String {
        "\(roundedCompact(value, maximumFractionDigits: maximumFractionDigits))%"
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
}
