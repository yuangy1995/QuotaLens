// QuotaLens 核心指标全息卡片组件 (Dual Theme Metric Tile)

import SwiftUI

public struct MetricCardView: View {
    @Environment(\.colorScheme) var colorScheme
    public let title: String
    public let value: String
    public let subtitle: String?
    public let icon: String
    public let iconColor: Color?
    public var trendText: String? = nil
    public var isPositiveTrend: Bool? = nil

    public init(
        title: String,
        value: String,
        subtitle: String? = nil,
        icon: String,
        iconColor: Color? = nil,
        trendText: String? = nil,
        isPositiveTrend: Bool? = nil
    ) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.icon = icon
        self.iconColor = iconColor
        self.trendText = trendText
        self.isPositiveTrend = isPositiveTrend
    }

    public var body: some View {
        let activeColor = iconColor ?? AppTheme.accentCyan(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)
        let rose = AppTheme.accentRose(for: colorScheme)
        let isDark = colorScheme == .dark

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(activeColor.opacity(isDark ? 0.15 : 0.12))
                        .frame(width: 28, height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(activeColor.opacity(0.4), lineWidth: 1)
                        )

                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(activeColor)
                }

                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))

                Spacer()

                if let trend = trendText {
                    let trendColor = (isPositiveTrend == true ? emerald : (isPositiveTrend == false ? rose : AppTheme.textSecondary(for: colorScheme)))
                    Text(trend)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(
                            trendColor.opacity(isDark ? 0.15 : 0.10),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(trendColor.opacity(0.35), lineWidth: 0.8)
                        )
                        .foregroundStyle(trendColor)
                }
            }

            Text(value)
                .font(.system(.title2, design: .rounded, weight: .heavy))
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if let sub = subtitle {
                Text(sub)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    .lineLimit(2)
            }
        }
        .cyberCard(cornerRadius: 12, padding: 14)
    }
}
