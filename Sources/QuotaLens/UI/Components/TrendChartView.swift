// QuotaLens 基于 Swift Charts 的趋势与堆叠图表组件 (Dual Theme Trend Chart)

import SwiftUI
import Charts

public struct DailyChartItem: Identifiable, Sendable {
    public var id: String { date }
    public let date: String
    public let tokens: Double // 以 Millions (M) 或 Billions (B) 为单位
    public let state: DailyDataState
}

public struct TrendChartView: View {
    @Environment(\.colorScheme) var colorScheme
    public let items: [DailyChartItem]
    public var title: String

    public init(items: [DailyChartItem], title: String = L10n.text("每日总用量趋势", "Daily Usage Trend")) {
        self.items = items
        self.title = title
    }

    public var body: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let blue = AppTheme.accentBlue(for: colorScheme)
        let amber = AppTheme.accentAmber(for: colorScheme)

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                Spacer()
                Text(L10n.text("最近 7 日", "Last 7 Days"))
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }

            if items.isEmpty {
                ContentUnavailableView(L10n.text("暂无趋势数据", "No trend data"), systemImage: "chart.line.uptrend.xyaxis")
                    .frame(height: 160)
            } else {
                Chart {
                    ForEach(items) { item in
                        BarMark(
                            x: .value(L10n.text("日期", "Date"), item.date),
                            y: .value("Token (B)", item.tokens)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [cyan, blue],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .cornerRadius(6)

                        LineMark(
                            x: .value(L10n.text("日期", "Date"), item.date),
                            y: .value("Token (B)", item.tokens)
                        )
                        .foregroundStyle(amber)
                        .symbol(Circle())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 160)
            }
        }
        .cyberCard()
    }
}
