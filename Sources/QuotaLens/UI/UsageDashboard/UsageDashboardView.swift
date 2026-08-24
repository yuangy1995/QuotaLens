// QuotaLens 用量大盘状态管理与视图 (UsageDashboardView)

import SwiftUI
import Charts
import Combine

@MainActor
public final class UsageDashboardStore: ObservableObject {
    @Published public var selectedRangeDays: Int = 30 {
        didSet { Task { await loadDashboardData() } }
    }
    @Published public var metrics: DashboardMetricsDTO? = nil
    @Published public var todayMetrics: DashboardMetricsDTO? = nil
    @Published public var sevenDayMetrics: DashboardMetricsDTO? = nil
    @Published public var thirtyDayMetrics: DashboardMetricsDTO? = nil
    @Published public var heatmapCells: [ActivityHeatmapCellDTO] = []
    @Published public var quotaForecast: QuotaForecastDTO? = nil
    @Published public var localForecast: LocalUsageForecastDTO? = nil
    @Published public var isLoading: Bool = false
    @Published public var errorMessage: String? = nil

    private let facade: UsageQueryFacade

    public init(facade: UsageQueryFacade) {
        self.facade = facade
    }

    public func loadDashboardData(
        currentUsedPercent: Double = 0.0,
        resetsAt: Int64? = nil,
        rateSnapshots: [QuotaForecastEngine.RateSnapshotPoint] = []
    ) async {
        isLoading = true
        errorMessage = nil
        do {
            async let selectedMetrics = facade.getDashboardMetrics(days: selectedRangeDays)
            async let today = facade.getDashboardMetrics(days: 1)
            async let sevenDay = facade.getDashboardMetrics(days: 7)
            async let thirtyDay = facade.getDashboardMetrics(days: 30)
            let (m, todayM, sevenM, thirtyM) = try await (selectedMetrics, today, sevenDay, thirtyDay)
            self.metrics = m
            self.todayMetrics = todayM
            self.sevenDayMetrics = sevenM
            self.thirtyDayMetrics = thirtyM

            let heatmap = try await facade.getActivityHeatmap()
            self.heatmapCells = heatmap

            // 计算双重预测
            self.quotaForecast = QuotaForecastEngine.forecast(
                currentUsedPercent: currentUsedPercent,
                resetsAt: resetsAt,
                snapshots: rateSnapshots
            )

            self.localForecast = LocalUsageProjection.project(
                history: m.dailyBuckets,
                horizonDays: 7
            )
        } catch {
            self.errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

public struct UsageDashboardView: View {
    @StateObject private var store: UsageDashboardStore
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.colorScheme) var colorScheme
    @State private var hoveredTrendDayID: String?
    @State private var hoveredHeatmapCellID: String?

    public init(facade: UsageQueryFacade) {
        _store = StateObject(wrappedValue: UsageDashboardStore(facade: facade))
    }

    public var body: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)

        ScrollView {
            VStack(spacing: 20) {
                // 1. 顶部控制栏与时间范围选择
                headerControlBar

                if store.isLoading && store.metrics == nil {
                    VStack(spacing: 8) {
                        ProgressView()
                            .tint(cyan)
                        Text(L10n.text("正在计算全局指标与趋势…", "Computing metrics..."))
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else if let metrics = store.metrics {
                    // 2. 核心 KPI 卡片
                    kpiSection(metrics: metrics)

                    // 3. 缓存命中率独立概览
                    cacheHitRateStrip

                    // 4. 双重智能预测引擎 (服务器额度耗尽 + 本机未来 7 天趋势)
                    if UsageFeatureFlags.shared.isForecastEnabled {
                        dualForecastSection
                    }

                    // 5. Swift Charts 历史消耗趋势图
                    usageTrendChartSection(dailyBuckets: metrics.dailyBuckets)

                    // 6. GitHub 风格年度活跃热力图
                    activityHeatmapSection

                    // 7. 模型使用分布
                    modelCompositionSection(models: metrics.modelDistribution)
                }
            }
            .padding(24)
        }
        .task {
            env.scanCoordinator.triggerScan()
            await reloadData()
        }
        .onReceive(env.scanCoordinator.$dataGeneration.dropFirst()) { _ in
            Task {
                await reloadData()
            }
        }
    }

    private func reloadData() async {
        let snap = env.state.latestRateLimit
        let used = env.state.currentUsedPercent
        let resetsAt = snap?.resetsAt

        var points: [QuotaForecastEngine.RateSnapshotPoint] = []
        if let storedSnaps = try? env.repositories.getRecentRateLimitSnapshots(
            accountKey: env.state.selectedAccountKey ?? env.state.account?.accountKey,
            limit: 50
        ) {
            points = storedSnaps.map { s in
                QuotaForecastEngine.RateSnapshotPoint(
                    timestamp: Date(timeIntervalSince1970: Double(s.observedAt)),
                    usedPercent: Double(s.usedPercentMilli) / 1000.0
                )
            }
        }

        await store.loadDashboardData(
            currentUsedPercent: used,
            resetsAt: resetsAt,
            rateSnapshots: points
        )
    }

    // MARK: - 1. 顶部控制栏
    private var headerControlBar: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let isDark = colorScheme == .dark

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("Codex 用量分析大盘", "Codex Usage Dashboard"))
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                Text(L10n.text("本机精确日志解析 · 多模型构成 · 双重趋势预测", "Exact local logs · Model breakdown · Dual forecast"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }

            Spacer()

            // 时间跨度芯片选择器
            HStack(spacing: 6) {
                ForEach([7, 30, 90, 365], id: \.self) { rangeDays in
                    let isSelected = store.selectedRangeDays == rangeDays
                    Button(action: { store.selectedRangeDays = rangeDays }) {
                        Text(L10n.format("%d Days", zhHans: "%d 天", rangeDays))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                isSelected ? cyan.opacity(isDark ? 0.24 : 0.18) : (isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(isSelected ? cyan.opacity(0.7) : (isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)), lineWidth: 0.8)
                            )
                            .foregroundStyle(isSelected ? cyan : AppTheme.textPrimary(for: colorScheme))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 2. 核心 KPI 卡片
    private func kpiSection(metrics: DashboardMetricsDTO) -> some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)
        let amber = AppTheme.accentAmber(for: colorScheme)

        let totalTok = metrics.totalTokens.canonicalTotalTokens

        return HStack(spacing: 14) {
            DashboardKPICard(
                title: L10n.text("区间总消耗 Token", "Total Range Tokens"),
                value: UsageNumberFormatter.formattedTokenCount(totalTok),
                caption: UsageNumberFormatter.compactTokenCount(totalTok),
                icon: "sparkles",
                color: cyan
            )

            DashboardKPICard(
                title: L10n.text("API 等价价值估算", "API Equivalent Value"),
                value: UsageNumberFormatter.currencyUSD(metrics.totalCost),
                caption: L10n.text("按官方列表价核算", "Official list price"),
                icon: "dollarsign.circle.fill",
                color: emerald
            )

            DashboardKPICard(
                title: L10n.text("活跃天数 / 会话数", "Active Days / Sessions"),
                value: L10n.format("%d days", zhHans: "%d 天", metrics.activeDaysCount),
                caption: L10n.format("%d sessions", zhHans: "共 %d 个会话", metrics.totalSessions),
                icon: "calendar.badge.checkmark",
                color: amber
            )
        }
    }

    private var cacheHitRateStrip: some View {
        let purple = AppTheme.accentPurple(for: colorScheme)
        let isDark = colorScheme == .dark

        return HStack(spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(purple)
                    .frame(width: 7, height: 7)

                Text(L10n.text("缓存命中率", "Cache Hit Rate"))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }

            Spacer(minLength: 12)

            CacheHitPeriodView(
                label: L10n.text("今日", "Today"),
                value: cacheHitDisplayText(store.todayMetrics)
            )

            CacheHitDivider()

            CacheHitPeriodView(
                label: L10n.text("近 7 天", "Last 7 Days"),
                value: cacheHitDisplayText(store.sevenDayMetrics)
            )

            CacheHitDivider()

            CacheHitPeriodView(
                label: L10n.text("近 30 天", "Last 30 Days"),
                value: cacheHitDisplayText(store.thirtyDayMetrics)
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            purple.opacity(isDark ? 0.12 : 0.08),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(purple.opacity(isDark ? 0.24 : 0.18), lineWidth: 0.8)
        )
    }

    private func cacheHitDisplayText(_ metrics: DashboardMetricsDTO?) -> String {
        guard let metrics, metrics.totalTokens.inputTokens > 0 else {
            return "—"
        }
        return UsageNumberFormatter.percent(metrics.cacheHitRatio * 100.0, maximumFractionDigits: 1)
    }

    // MARK: - 3. 双重智能预测引擎
    private var dualForecastSection: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)
        let amber = AppTheme.accentAmber(for: colorScheme)
        let rose = AppTheme.accentRose(for: colorScheme)
        let isDark = colorScheme == .dark

        return HStack(spacing: 14) {
            // 左卡：服务器额度耗尽预测
            if let qf = store.quotaForecast {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(qf.risk == .critical ? rose : (qf.risk == .warning ? amber : cyan))
                            Text(L10n.text("服务器额度耗尽预测", "Rate Limit Burn Forecast"))
                                .font(.system(size: 13, weight: .black, design: .rounded))
                                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                        }

                        Spacer()

                        Text(qf.risk.localizedTitle)
                            .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background((qf.risk == .critical ? rose : (qf.risk == .warning ? amber : emerald)).opacity(isDark ? 0.18 : 0.12), in: Capsule())
                            .foregroundStyle(qf.risk == .critical ? rose : (qf.risk == .warning ? amber : emerald))
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("每小时消耗:", "Used per Hour:"))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                            Text(String(format: "%.2f%% / h", qf.burnRatePercentPerHour))
                                .font(.system(size: 14, weight: .heavy, design: .rounded))
                                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("当前速度:", "Current Speed:"))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                            Text(quotaForecastSpeedText(qf))
                                .font(.system(size: 14, weight: .heavy, design: .rounded))
                                .foregroundStyle(quotaForecastAccentColor(qf, emerald: emerald, amber: amber, rose: rose))
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(quotaForecastOutcomeLabel(qf))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                            Text(quotaForecastOutcomeValue(qf))
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(quotaForecastAccentColor(qf, emerald: emerald, amber: amber, rose: rose))
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder((qf.risk == .critical ? rose : cyan).opacity(0.35), lineWidth: 0.8)
                )
            }

            // 右卡：本机未来 7 天趋势投影
            if let lf = store.localForecast {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(emerald)
                            Text(L10n.text("本机未来 7 天趋势估算", "Local 7-Day Usage Projection"))
                                .font(.system(size: 13, weight: .black, design: .rounded))
                                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                        }

                        Spacer()

                        Text(lf.confidence.localizedDescription)
                            .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(emerald.opacity(isDark ? 0.18 : 0.12), in: Capsule())
                            .foregroundStyle(emerald)
                    }

                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("预计总 Token:", "Projected Tokens:"))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                            Text(UsageNumberFormatter.compactTokenCount(lf.projectedTotalTokens))
                                .font(.system(size: 14, weight: .heavy, design: .rounded))
                                .foregroundStyle(cyan)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("预计 API 等价值:", "Projected Value:"))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                            Text(UsageNumberFormatter.currencyUSD(lf.projectedTotalCost))
                                .font(.system(size: 14, weight: .heavy, design: .rounded))
                                .foregroundStyle(emerald)
                        }

                        Spacer()
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(emerald.opacity(0.35), lineWidth: 0.8)
                )
            }
        }
    }

    private func quotaForecastSpeedText(_ forecast: QuotaForecastDTO) -> String {
        switch forecast.risk {
        case .critical:
            return L10n.text("会提前用尽", "Will run out early")
        case .warning:
            return L10n.text("用量偏快", "Usage is high")
        case .onTrack:
            return L10n.text("可撑到重置", "Lasts until reset")
        case .underPaced:
            return L10n.text("用量平稳", "Usage is light")
        case .insufficientData:
            return L10n.text("数据收集中", "Collecting data")
        }
    }

    private func quotaForecastOutcomeLabel(_ forecast: QuotaForecastDTO) -> String {
        if forecast.risk == .critical, forecast.hoursUntilExhaustion != nil {
            return L10n.text("预计还可用:", "Time Remaining:")
        }
        if forecast.projectedRemainingAtReset != nil {
            return L10n.text("重置时预计剩余:", "Remaining at Reset:")
        }
        return L10n.text("预测状态:", "Forecast Status:")
    }

    private func quotaForecastOutcomeValue(_ forecast: QuotaForecastDTO) -> String {
        if forecast.risk == .critical, let hours = forecast.hoursUntilExhaustion {
            return UsageNumberFormatter.remainingDurationString(seconds: hours * 3600.0)
        }
        if let remaining = forecast.projectedRemainingAtReset {
            return UsageNumberFormatter.percent(remaining, maximumFractionDigits: 0)
        }
        return forecast.confidence.localizedDescription
    }

    private func quotaForecastAccentColor(_ forecast: QuotaForecastDTO, emerald: Color, amber: Color, rose: Color) -> Color {
        switch forecast.risk {
        case .critical:
            return rose
        case .warning:
            return amber
        case .onTrack, .underPaced:
            return emerald
        case .insufficientData:
            return AppTheme.textSecondary(for: colorScheme)
        }
    }

    // MARK: - 4. Swift Charts 历史趋势图表
    private func usageTrendChartSection(dailyBuckets: [DayUsageSummaryDTO]) -> some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let chartData = dailyBuckets.sorted { $0.dayKey < $1.dayKey }

        return VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("历史消耗趋势 (Swift Charts)", "Usage Trend"))
                .font(.system(size: 14, weight: .black, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

            if chartData.isEmpty {
                Text(L10n.text("暂无足够数据绘制图表", "Not enough data for chart"))
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    .frame(height: 160)
            } else {
                let hoveredDay = chartData.first { $0.id == hoveredTrendDayID }

                ZStack(alignment: .topTrailing) {
                    Chart {
                        ForEach(chartData) { day in
                            BarMark(
                                x: .value(L10n.text("日期", "Date"), day.date, unit: .day),
                                y: .value(L10n.text("Token", "Tokens"), day.tokens.canonicalTotalTokens)
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [cyan, AppTheme.accentBlue(for: colorScheme)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .opacity(hoveredTrendDayID == nil || hoveredTrendDayID == day.id ? 1.0 : 0.34)
                            .cornerRadius(3)
                        }

                        if let hoveredDay {
                            RuleMark(x: .value(L10n.text("日期", "Date"), hoveredDay.date, unit: .day))
                                .foregroundStyle(cyan.opacity(0.55))
                                .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 6)) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(monthDayString(date))
                                        .font(.system(size: 9, design: .monospaced))
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let count = value.as(Int64.self) {
                                    Text(UsageNumberFormatter.compactTokenCount(count))
                                        .font(.system(size: 9, design: .monospaced))
                                }
                            }
                        }
                    }
                    .chartOverlay { chartProxy in
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        guard let plotFrameAnchor = chartProxy.plotFrame else {
                                            hoveredTrendDayID = nil
                                            return
                                        }
                                        let plotFrame = geometry[plotFrameAnchor]
                                        guard plotFrame.contains(location) else {
                                            hoveredTrendDayID = nil
                                            return
                                        }
                                        let relativeX = location.x - plotFrame.origin.x
                                        if let date = chartProxy.value(atX: relativeX, as: Date.self) {
                                            hoveredTrendDayID = nearestTrendDayID(to: date, in: chartData)
                                        }
                                    case .ended:
                                        hoveredTrendDayID = nil
                                    }
                                }
                        }
                    }

                    if let hoveredDay {
                        usageTrendHoverCard(hoveredDay)
                            .padding(8)
                            .transition(.opacity)
                    }
                }
                .frame(height: 180)
            }
        }
        .padding(16)
        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
        )
    }

    // MARK: - 5. GitHub 风格年度热力图
    private var activityHeatmapSection: some View {
        let cells = store.heatmapCells
        let rowCount = 7
        let columnCount = max(1, Int(ceil(Double(max(cells.count, rowCount)) / Double(rowCount))))

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("年度活跃热力图 (Activity Heatmap)", "Annual Activity Heatmap"))
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                Spacer()

                HStack(spacing: 4) {
                    Text(L10n.text("少", "Less"))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    heatmapSquare(level: 0)
                    heatmapSquare(level: 1)
                    heatmapSquare(level: 2)
                    heatmapSquare(level: 3)
                    heatmapSquare(level: 4)
                    Text(L10n.text("多", "More"))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }
            }

            ZStack(alignment: .topTrailing) {
                GeometryReader { proxy in
                    let spacing = adaptiveHeatmapSpacing(width: proxy.size.width)
                    let squareSize = adaptiveHeatmapSquareSize(
                        width: proxy.size.width,
                        columns: columnCount,
                        spacing: spacing
                    )
                    LazyHGrid(
                        rows: Array(repeating: GridItem(.fixed(squareSize), spacing: spacing), count: rowCount),
                        spacing: spacing
                    ) {
                        ForEach(cells) { cell in
                            heatmapSquare(
                                level: cell.intensityLevel,
                                size: squareSize,
                                isHighlighted: hoveredHeatmapCellID == cell.id
                            )
                            .onHover { hovering in
                                if hovering {
                                    hoveredHeatmapCellID = cell.id
                                } else if hoveredHeatmapCellID == cell.id {
                                    hoveredHeatmapCellID = nil
                                }
                            }
                            .help(heatmapHelpText(cell))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let hoveredCell = cells.first(where: { $0.id == hoveredHeatmapCellID }) {
                    heatmapHoverCard(hoveredCell)
                        .padding(8)
                        .transition(.opacity)
                }
            }
            .aspectRatio(Double(columnCount) / Double(rowCount), contentMode: .fit)
        }
        .padding(16)
        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
        )
    }

    private func adaptiveHeatmapSpacing(width: CGFloat) -> CGFloat {
        min(max(width / 420.0, 2.0), 5.0)
    }

    private func adaptiveHeatmapSquareSize(width: CGFloat, columns: Int, spacing: CGFloat) -> CGFloat {
        let columnCount = max(1, columns)
        let totalSpacing = spacing * CGFloat(max(0, columnCount - 1))
        return max(6.0, (width - totalSpacing) / CGFloat(columnCount))
    }

    private func heatmapSquare(level: Int, size: CGFloat = 10, isHighlighted: Bool = false) -> some View {
        let emerald = AppTheme.accentEmerald(for: colorScheme)
        let isDark = colorScheme == .dark

        let color: Color
        switch level {
        case 1: color = emerald.opacity(isDark ? 0.35 : 0.30)
        case 2: color = emerald.opacity(isDark ? 0.55 : 0.50)
        case 3: color = emerald.opacity(isDark ? 0.75 : 0.70)
        case 4: color = emerald
        default: color = isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)
        }

        return RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(
                        isHighlighted ? AppTheme.textPrimary(for: colorScheme).opacity(isDark ? 0.85 : 0.70) : .clear,
                        lineWidth: isHighlighted ? 1.2 : 0
                    )
            )
            .scaleEffect(isHighlighted ? 1.18 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHighlighted)
    }

    private func usageTrendHoverCard(_ day: DayUsageSummaryDTO) -> some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)

        return hoverCard {
            Text(L10n.text("每日用量", "Daily Usage"))
                .font(.system(size: 10.5, weight: .black, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))

            Text(longDayString(day.date))
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

            hoverMetricRow(
                label: L10n.text("Token 总量", "Total Tokens"),
                value: UsageNumberFormatter.formattedTokenCount(day.tokens.canonicalTotalTokens),
                color: cyan
            )
            hoverMetricRow(
                label: L10n.text("费用", "Cost"),
                value: UsageNumberFormatter.currencyUSD(day.estimatedCost),
                color: emerald
            )
            hoverMetricRow(
                label: L10n.text("会话", "Session Count"),
                value: "\(day.sessionCount)",
                color: AppTheme.textPrimary(for: colorScheme)
            )
            hoverMetricRow(
                label: L10n.text("调用", "Events"),
                value: "\(day.eventCount)",
                color: AppTheme.textPrimary(for: colorScheme)
            )
            hoverMetricRow(
                label: L10n.text("缓存", "Cache"),
                value: UsageNumberFormatter.percent(day.tokens.cacheHitRatio * 100.0, maximumFractionDigits: 1),
                color: AppTheme.accentPurple(for: colorScheme)
            )
        }
    }

    private func heatmapHoverCard(_ cell: ActivityHeatmapCellDTO) -> some View {
        let emerald = AppTheme.accentEmerald(for: colorScheme)

        return hoverCard {
            Text(L10n.text("活跃明细", "Activity Details"))
                .font(.system(size: 10.5, weight: .black, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))

            Text(longDayString(cell.date))
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

            if cell.tokenCount == 0 && cell.eventCount == 0 {
                Text(L10n.text("暂无用量", "No usage"))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            } else {
                hoverMetricRow(
                    label: L10n.text("Token 总量", "Total Tokens"),
                    value: UsageNumberFormatter.formattedTokenCount(cell.tokenCount),
                    color: emerald
                )
                hoverMetricRow(
                    label: L10n.text("费用", "Cost"),
                    value: UsageNumberFormatter.currencyUSD(cell.estimatedCost),
                    color: AppTheme.accentEmerald(for: colorScheme)
                )
                hoverMetricRow(
                    label: L10n.text("调用", "Events"),
                    value: "\(cell.eventCount)",
                    color: AppTheme.textPrimary(for: colorScheme)
                )
            }
        }
    }

    private func hoverCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let isDark = colorScheme == .dark

        return VStack(alignment: .leading, spacing: 6) {
            content()
        }
        .padding(10)
        .frame(width: 188, alignment: .leading)
        .background(
            isDark ? Color.black.opacity(0.78) : Color.white.opacity(0.96),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(isDark ? 0.32 : 0.12), radius: 14, y: 6)
    }

    private func hoverMetricRow(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
    }

    private func heatmapHelpText(_ cell: ActivityHeatmapCellDTO) -> String {
        [
            longDayString(cell.date),
            "\(L10n.text("Token 总量", "Total Tokens")): \(UsageNumberFormatter.formattedTokenCount(cell.tokenCount))",
            "\(L10n.text("费用", "Cost")): \(UsageNumberFormatter.currencyUSD(cell.estimatedCost))",
            "\(L10n.text("调用", "Events")): \(cell.eventCount)"
        ].joined(separator: "\n")
    }

    private func nearestTrendDayID(to date: Date, in days: [DayUsageSummaryDTO]) -> String? {
        days.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }?.id
    }

    private func monthDayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }

    private func longDayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateFormat = L10n.isChinese ? "yyyy年M月d日" : "MMM d, yyyy"
        return formatter.string(from: date)
    }

    // MARK: - 6. 模型使用分布
    private func modelCompositionSection(models: [ModelUsageSummaryDTO]) -> some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)

        return VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("多模型消耗与费用分布", "Model Breakdown"))
                .font(.system(size: 14, weight: .black, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(models) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.modelCanonical)
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(cyan)
                            Text(L10n.format("%d events", zhHans: "%d 次调用", model.eventCount))
                                .font(.system(size: 9.5, design: .rounded))
                                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(UsageNumberFormatter.compactTokenCount(model.tokens.canonicalTotalTokens))
                                .font(.system(size: 11.5, weight: .heavy, design: .monospaced))
                                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                            Text(UsageNumberFormatter.currencyUSD(model.estimatedCost))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(emerald)
                        }
                    }
                    .padding(10)
                    .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
                    )
                }
            }
        }
        .padding(16)
        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
        )
    }
}

private struct CacheHitPeriodView: View {
    @Environment(\.colorScheme) var colorScheme
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                .lineLimit(1)

            Text(value)
                .font(.system(size: 11.5, weight: .black, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
    }
}

private struct CacheHitDivider: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Rectangle()
            .fill(AppTheme.insetBorder(for: colorScheme))
            .frame(width: 1, height: 18)
    }
}

// MARK: - 大盘 KPI 卡片
private struct DashboardKPICard: View {
    @Environment(\.colorScheme) var colorScheme
    let title: String
    let value: String
    let caption: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }

            Text(value)
                .font(.system(size: 18, weight: .black, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(caption)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
        )
    }
}
