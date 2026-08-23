// QuotaLens 全息科技双环表盘组件 (Dual Theme Hologram Gauge)

import SwiftUI

public struct CircularProgressView: View {
    @Environment(\.colorScheme) var colorScheme
    public let progress: Double // 0.0 ~ 1.0
    public let riskProgress: Double // 0.0 ~ 1.0
    public var lineWidth: CGFloat = 14
    public var size: CGFloat = 160
    public var title: String
    public var valueText: String? = nil
    public var subtitle: String? = nil

    public init(
        progress: Double,
        riskProgress: Double? = nil,
        lineWidth: CGFloat = 14,
        size: CGFloat = 160,
        title: String = L10n.text("本周可用", "Available This Week"),
        valueText: String? = nil,
        subtitle: String? = nil
    ) {
        self.progress = min(max(progress, 0.0), 1.0)
        self.riskProgress = min(max(riskProgress ?? progress, 0.0), 1.0)
        self.lineWidth = lineWidth
        self.size = size
        self.title = title
        self.valueText = valueText
        self.subtitle = subtitle
    }

    private var progressGradient: LinearGradient {
        let isDark = colorScheme == .dark
        if riskProgress >= 0.85 {
            let rose = AppTheme.accentRose(for: colorScheme)
            return LinearGradient(
                colors: isDark ? [AppTheme.neonRose, Color(red: 0.95, green: 0.15, blue: 0.35)] : [rose, Color(red: 1.0, green: 0.35, blue: 0.45)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else if riskProgress >= 0.65 {
            let amber = AppTheme.accentAmber(for: colorScheme)
            return LinearGradient(
                colors: isDark ? [AppTheme.neonAmber, Color(red: 1.0, green: 0.45, blue: 0.0)] : [amber, Color(red: 1.0, green: 0.65, blue: 0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            let cyan = AppTheme.accentCyan(for: colorScheme)
            let blue = AppTheme.accentBlue(for: colorScheme)
            return LinearGradient(
                colors: [cyan, blue],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var glowColor: Color {
        if riskProgress >= 0.85 {
            return AppTheme.accentRose(for: colorScheme)
        } else if riskProgress >= 0.65 {
            return AppTheme.accentAmber(for: colorScheme)
        } else {
            return AppTheme.accentCyan(for: colorScheme)
        }
    }

    public var body: some View {
        let isDark = colorScheme == .dark

        ZStack {
            // 1. 最外层科技点阵/虚线刻度环
            Circle()
                .stroke(
                    isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.08),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 6])
                )
                .frame(width: size + 16, height: size + 16)

            // 2. 内部槽道
            Circle()
                .stroke(
                    isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06),
                    lineWidth: lineWidth
                )
                .frame(width: size, height: size)

            // 3. 动态弧线外层发光晕影 (Glow Halo)
            if progress > 0.01 {
                Circle()
                    .trim(from: 0.0, to: CGFloat(progress))
                    .stroke(
                        progressGradient,
                        style: StrokeStyle(lineWidth: lineWidth + 4, lineCap: .round)
                    )
                    .blur(radius: isDark ? 6 : 4)
                    .opacity(isDark ? 0.5 : 0.25)
                    .rotationEffect(.degrees(-90))
                    .frame(width: size, height: size)
                    .animation(.spring(response: 0.8, dampingFraction: 0.75), value: progress)
            }

            // 4. 高亮动态主进度弧线
            Circle()
                .trim(from: 0.0, to: CGFloat(progress))
                .stroke(
                    progressGradient,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: size, height: size)
                .animation(.spring(response: 0.8, dampingFraction: 0.75), value: progress)

            // 5. 端点高亮科技信标光球
            if progress > 0.02 && progress < 0.98 {
                let angle = Angle.degrees(progress * 360.0 - 90.0)
                let radius = size / 2.0
                Circle()
                    .fill(Color.white)
                    .frame(width: max(4, lineWidth * 0.45), height: max(4, lineWidth * 0.45))
                    .shadow(color: glowColor, radius: isDark ? 4 : 2)
                    .offset(
                        x: CGFloat(cos(angle.radians)) * radius,
                        y: CGFloat(sin(angle.radians)) * radius
                    )
                    .animation(.spring(response: 0.8, dampingFraction: 0.75), value: progress)
            }

            // 6. 中心科技 HUD 数据流
            VStack(spacing: size < 120 ? 1 : 4) {
                // 顶部小标签
                Text(title)
                    .font(.system(size: max(9, size * 0.075), weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    .textCase(.uppercase)

                // 核心大数字
                Text(valueText ?? UsageNumberFormatter.percent(progress * 100.0))
                    .font(.system(size: size * 0.22, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                    .monospacedDigit()
                    .shadow(color: glowColor.opacity(isDark ? 0.35 : 0.15), radius: isDark ? 8 : 3, x: 0, y: 1.5)

                // 底部副状态
                if let sub = subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: max(8, size * 0.065), weight: .bold, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        .lineLimit(1)
                }
            }
            .padding(size * 0.05)
        }
        .frame(width: size + 20, height: size + 20)
    }
}
