import SwiftUI
import Charts

public struct CodexUsageDashboardView: View {
    private let facade: UsageQueryFacade

    public init(facade: UsageQueryFacade) {
        self.facade = facade
    }

    public var body: some View {
        ProviderUsageDashboardView(facade: facade, providerFilter: .codex)
    }
}

public struct ClaudeUsageDashboardView: View {
    private let facade: UsageQueryFacade

    public init(facade: UsageQueryFacade) {
        self.facade = facade
    }

    public var body: some View {
        ProviderUsageDashboardView(facade: facade, providerFilter: .claude)
    }
}

public struct AntigravityUsageDashboardView: View {
    private let facade: UsageQueryFacade

    public init(facade: UsageQueryFacade) {
        self.facade = facade
    }

    public var body: some View {
        ProviderUsageDashboardView(facade: facade, providerFilter: .antigravity)
    }
}

public struct CodexHistoryView: View {
    private let facade: UsageQueryFacade

    public init(facade: UsageQueryFacade) {
        self.facade = facade
    }

    public var body: some View {
        ProviderHistoryView(facade: facade, providerFilter: .codex)
    }
}

public struct ClaudeHistoryView: View {
    private let facade: UsageQueryFacade

    public init(facade: UsageQueryFacade) {
        self.facade = facade
    }

    public var body: some View {
        ProviderHistoryView(facade: facade, providerFilter: .claude)
    }
}

public struct CodexSessionsView: View {
    private let facade: UsageQueryFacade

    public init(facade: UsageQueryFacade) {
        self.facade = facade
    }

    public var body: some View {
        ProviderSessionsView(facade: facade, providerFilter: .codex)
    }
}

public struct ClaudeSessionsView: View {
    private let facade: UsageQueryFacade

    public init(facade: UsageQueryFacade) {
        self.facade = facade
    }

    public var body: some View {
        ProviderSessionsView(facade: facade, providerFilter: .claude)
    }
}

public struct AntigravitySessionsView: View {
    private let facade: UsageQueryFacade

    public init(facade: UsageQueryFacade) {
        self.facade = facade
    }

    public var body: some View {
        ProviderSessionsView(facade: facade, providerFilter: .antigravity)
    }
}

public struct AntigravityOverviewView: View {
    @ObservedObject private var state: AppState
    @Environment(\.colorScheme) private var colorScheme

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        AntigravityQuotaAnalyticsView(state: state)
    }

    private var header: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(cyan.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    .frame(width: 48, height: 48)
                ToolAppIcon(tool: .antigravity, size: 30)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Antigravity")
                    .font(.system(size: 20, weight: .black, design: .rounded))
                Text(statusText)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }
            Spacer()
            if let plan = state.latestAntigravityQuota?.planName, !plan.isEmpty {
                Text(plan.uppercased())
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(cyan)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(cyan.opacity(colorScheme == .dark ? 0.14 : 0.10), in: Capsule())
            }
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if state.isRefreshingAntigravityQuota || state.antigravityQuotaStatus == .loading {
                ProgressView().controlSize(.small)
            } else {
                ToolAppIcon(tool: .antigravity, size: 34)
            }
            Text(state.antigravityQuotaErrorText ?? L10n.text(
                "尚未读取到 Antigravity 额度",
                "Antigravity quota is not available yet"
            ))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    private func modelCard(_ models: [AntigravityQuotaSnapshot.Model]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CyberSectionHeader(
                title: L10n.text("模型余量", "Model Availability"),
                icon: "list.bullet.rectangle"
            )
            CyberDivider()
            ForEach(models) { model in
                HStack(spacing: 10) {
                    Text(model.displayName ?? L10n.text("其他模型", "Other model"))
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Spacer()
                    Text(UsageNumberFormatter.percent(model.remainingPercent, maximumFractionDigits: 0))
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(quotaTint(model.remainingPercent))
                }
            }
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    private var statusText: String {
        if let capturedAt = state.latestAntigravityQuota?.capturedAt {
            return L10n.format(
                "Last synced %@",
                zhHans: "最后同步 %@",
                UsageNumberFormatter.relativeTimeString(from: capturedAt)
            )
        }
        return state.antigravityQuotaErrorText ?? L10n.text("等待首次同步", "Waiting for the first sync")
    }

    private func quotaTint(_ remaining: Double) -> Color {
        if remaining <= 15 { return AppTheme.accentRose(for: colorScheme) }
        if remaining <= 35 { return AppTheme.accentAmber(for: colorScheme) }
        return AppTheme.accentEmerald(for: colorScheme)
    }
}

public struct AntigravityActivityView: View {
    @ObservedObject private var state: AppState
    @Environment(\.colorScheme) private var colorScheme

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        AntigravityActivityAnalyticsView(state: state)
    }

    private var activityHeader: some View {
        HStack {
            CyberSectionHeader(
                title: L10n.text("Antigravity 本机活动", "Antigravity Local Activity"),
                icon: "chart.bar.xaxis"
            )
            Spacer()
            if let latest = state.latestAntigravityActivity?.latestActivityAt {
                Text(L10n.format("Updated %@", zhHans: "%@更新", UsageNumberFormatter.relativeTimeString(from: latest)))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }
        }
    }

    private func activityMetrics(_ activity: AntigravityActivitySnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            ActivityMetricCard(title: L10n.text("最近 7 天任务", "Tasks · 7 Days"), value: "\(activity.taskCount7Days)", color: AppTheme.accentCyan(for: colorScheme))
            ActivityMetricCard(title: L10n.text("最近 30 天任务", "Tasks · 30 Days"), value: "\(activity.taskCount30Days)", color: AppTheme.accentCyan(for: colorScheme))
            ActivityMetricCard(title: L10n.text("活跃天数", "Active Days"), value: "\(activity.activeDays30Days)", color: AppTheme.accentEmerald(for: colorScheme))
            ActivityMetricCard(title: L10n.text("操作步骤", "Steps"), value: UsageNumberFormatter.compactTokenCount(activity.stepCount30Days), color: AppTheme.accentAmber(for: colorScheme))
        }
    }

    private func activityChart(_ activity: AntigravityActivitySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CyberSectionHeader(title: L10n.text("每日活动", "Daily Activity"), icon: "chart.bar.fill")
            CyberDivider()
            Chart(activity.daily) { day in
                BarMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Tasks", day.taskCount)
                )
                .foregroundStyle(AppTheme.accentCyan(for: colorScheme))
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 180)
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    private func projectCard(_ activity: AntigravityActivitySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CyberSectionHeader(title: L10n.text("项目活动", "Project Activity"), icon: "folder.fill")
            CyberDivider()
            if activity.projectCounts.isEmpty {
                Text(L10n.text("暂无项目活动", "No project activity"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            } else {
                ForEach(activity.projectCounts.sorted { $0.value > $1.value }, id: \.key) { project, count in
                    HStack {
                        Text(project)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                        Spacer()
                        Text("\(count)")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(AppTheme.accentCyan(for: colorScheme))
                    }
                }
            }
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }
}

private struct AntigravityBucketCard: View {
    let groupTitle: String
    let bucket: AntigravityQuotaSnapshot.Bucket
    let displayMode: QuotaDisplayMode
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shown = displayMode == .used ? 100 - bucket.remainingPercent : bucket.remainingPercent
        let tint: Color = bucket.remainingPercent <= 15
            ? AppTheme.accentRose(for: colorScheme)
            : (bucket.remainingPercent <= 35 ? AppTheme.accentAmber(for: colorScheme) : AppTheme.accentEmerald(for: colorScheme))
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(groupTitle)
                        .font(.system(size: 14, weight: .black, design: .rounded))
                    Text(bucket.window.localizedTitle)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }
                Spacer()
                Text(UsageNumberFormatter.percent(shown, maximumFractionDigits: shown < 10 ? 1 : 0))
                    .font(.system(size: 23, weight: .black, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }
            AntigravityAdaptiveQuotaProgress(value: shown / 100, tint: tint)
            HStack {
                Text(displayMode.pickerTitle)
                Spacer()
                if let resetAt = bucket.resetAt {
                    Text(L10n.format("Resets %@", zhHans: "%@重置", UsageNumberFormatter.relativeTimeString(from: resetAt)))
                }
            }
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
        }
        .cyberCard(cornerRadius: 15, padding: 16)
    }
}

private struct AntigravityAdaptiveQuotaProgress: View {
    let value: Double
    let tint: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(AppTheme.insetBorder(for: colorScheme).opacity(colorScheme == .dark ? 0.9 : 0.72))
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 7)
    }
}

private struct ActivityMetricCard: View {
    let title: String
    let value: String
    let color: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            Text(value)
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cyberCard(cornerRadius: 14, padding: 15)
    }
}

@MainActor
private final class ToolUsageSummaryStore: ObservableObject {
    @Published var sevenDay: DashboardMetricsDTO?
    @Published var thirtyDay: DashboardMetricsDTO?
    @Published var isLoading = false

    private let facade: UsageQueryFacade
    private let providerFilter: UsageProviderFilter
    private var generation = 0

    init(facade: UsageQueryFacade, providerFilter: UsageProviderFilter) {
        self.facade = facade
        self.providerFilter = providerFilter
    }

    func load() async {
        generation += 1
        let request = generation
        isLoading = true
        defer {
            if generation == request { isLoading = false }
        }
        async let seven = try? facade.getDashboardMetrics(days: 7, providerFilter: providerFilter)
        async let thirty = try? facade.getDashboardMetrics(days: 30, providerFilter: providerFilter)
        let values = await (seven, thirty)
        guard generation == request else { return }
        sevenDay = values.0
        thirtyDay = values.1
    }
}

public struct ClaudeOverviewView: View {
    @ObservedObject private var state: AppState
    @StateObject private var usageStore: ToolUsageSummaryStore
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.colorScheme) private var colorScheme

    public init(state: AppState, facade: UsageQueryFacade) {
        self.state = state
        _usageStore = StateObject(
            wrappedValue: ToolUsageSummaryStore(facade: facade, providerFilter: .claude)
        )
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                statusHeader

                if let usage = state.latestClaudeUsage, usage.hasQuota {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 220), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(quotaWindows(from: usage)) { window in
                            ClaudeQuotaWindowCard(window: window, displayMode: state.quotaDisplayMode)
                        }
                    }
                } else {
                    ClaudeQuotaEmptyState(
                        statusText: state.claudeUsageErrorText,
                        isLoading: state.isRefreshingClaudeUsage || state.claudeUsageStatus == .loading
                    )
                }

                localUsageCard
            }
            .padding(24)
        }
        .task {
            guard !env.claudeScanCoordinator.isScanning else { return }
            await usageStore.load()
        }
        .onChange(of: env.claudeScanCoordinator.isScanning) { _, scanning in
            guard !scanning else { return }
            Task { await usageStore.load() }
        }
    }

    private var statusHeader: some View {
        let amber = AppTheme.accentAmber(for: colorScheme)
        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(amber.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    .frame(width: 48, height: 48)
                ToolAppIcon(tool: .claude, size: 30)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Claude")
                    .font(.system(size: 20, weight: .black, design: .rounded))
                Text(claudeStatusDescription)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }
            Spacer()
            if let tier = state.latestClaudeUsage?.tier, !tier.isEmpty {
                Text(tier.uppercased())
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(amber)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(amber.opacity(colorScheme == .dark ? 0.14 : 0.10), in: Capsule())
            }
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    private var localUsageCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                CyberSectionHeader(
                    title: L10n.text("Claude 本地用量", "Claude Local Usage"),
                    icon: "chart.bar.xaxis"
                )
                Spacer()
                if usageStore.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            CyberDivider()
            HStack(spacing: 12) {
                usageMetric(title: L10n.text("最近 7 天", "Last 7 Days"), metrics: usageStore.sevenDay)
                usageMetric(title: L10n.text("最近 30 天", "Last 30 Days"), metrics: usageStore.thirtyDay)
            }
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    private func usageMetric(title: String, metrics: DashboardMetricsDTO?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            Text(UsageNumberFormatter.compactTokenCount(metrics?.totalTokens.canonicalTotalTokens ?? 0))
                .font(.system(size: 20, weight: .black, design: .rounded))
                .monospacedDigit()
            Text(UsageNumberFormatter.currencyUSD(metrics?.totalCost ?? .zero))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(AppTheme.accentEmerald(for: colorScheme))
            Text(L10n.format("%d sessions", zhHans: "%d 个会话", metrics?.totalSessions ?? 0))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
        )
    }

    private func quotaWindows(from usage: ClaudeUsageSnapshot) -> [ClaudeUsageSnapshot.Window] {
        [usage.fiveHourForDisplay, usage.sevenDay].compactMap { $0 } + usage.scopedWeekly
    }

    private var claudeStatusDescription: String {
        if state.claudeUsageErrorText != nil {
            return L10n.text("等待同步", "Waiting for Sync")
        }
        if let capturedAt = state.latestClaudeUsage?.capturedAt {
            return L10n.format(
                "Last synced %@",
                zhHans: "最后同步 %@",
                UsageNumberFormatter.relativeTimeString(from: capturedAt)
            )
        }
        return L10n.text("等待首次同步", "Waiting for the first sync")
    }
}

private struct ClaudeQuotaWindowCard: View {
    let window: ClaudeUsageSnapshot.Window
    let displayMode: QuotaDisplayMode
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let displayed = displayMode == .used ? window.usedPercent : window.remainingPercent
        let tint = quotaTint(window.usedPercent)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(window.localizedTitle)
                        .font(.system(size: 14, weight: .black, design: .rounded))
                    Text(window.isStale
                        ? L10n.text("窗口已重置，等待更新", "Window reset; waiting for update")
                        : L10n.format(
                            "Resets %@",
                            zhHans: "%@重置",
                            UsageNumberFormatter.relativeTimeString(from: window.resetAt)
                        ))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }
                Spacer()
                Text(UsageNumberFormatter.percent(displayed, maximumFractionDigits: displayed < 10 ? 1 : 0))
                    .font(.system(size: 23, weight: .black, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }
            ProgressView(value: displayed / 100)
                .tint(tint)
            HStack {
                Text(displayMode.pickerTitle)
                Spacer()
                Text(L10n.format(
                    "%@ remaining",
                    zhHans: "剩余可用 %@",
                    UsageNumberFormatter.percent(window.remainingPercent, maximumFractionDigits: 0)
                ))
            }
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
        }
        .opacity(window.isStale ? 0.65 : 1)
        .cyberCard(cornerRadius: 15, padding: 16)
    }

    private func quotaTint(_ used: Double) -> Color {
        if used >= 85 { return AppTheme.accentRose(for: colorScheme) }
        if used >= 60 { return AppTheme.accentAmber(for: colorScheme) }
        return AppTheme.accentEmerald(for: colorScheme)
    }
}

private struct ClaudeQuotaEmptyState: View {
    let statusText: String?
    let isLoading: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 10) {
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                ToolAppIcon(tool: .claude, size: 34)
            }
            Text(statusText ?? L10n.text("尚未读取到 Claude 额度", "Claude quota is not available yet"))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .cyberCard(cornerRadius: 16, padding: 18)
    }
}

public struct MonitoringSetupView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(AppTheme.accentCyan(for: colorScheme).opacity(colorScheme == .dark ? 0.18 : 0.12))
                    .frame(width: 78, height: 78)
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(AppTheme.accentCyan(for: colorScheme))
            }
            Text(L10n.text("选择要监控的 AI 工具", "Choose AI Tools to Monitor"))
                .font(.system(size: 22, weight: .black, design: .rounded))
            Text(L10n.text(
                "启用 Codex、Claude 或 Antigravity 后，QuotaLens 会显示对应的额度和本机活动。",
                "Enable Codex, Claude, or Antigravity to see its quota and local activity."
            ))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 460)
            Button {
                env.navigationStore.showFixedDestination(.appSettings)
            } label: {
                Label(L10n.text("打开应用设置", "Open App Settings"), systemImage: "gearshape.2.fill")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
