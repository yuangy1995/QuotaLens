import SwiftUI

@MainActor
private final class OverviewDashboardStore: ObservableObject {
    struct UsagePair {
        let sevenDay: DashboardMetricsDTO?
        let thirtyDay: DashboardMetricsDTO?
    }

    @Published var usage: [MonitoringToolID: UsagePair] = [:]
    @Published var isLoading = false

    private let facade: UsageQueryFacade
    private var generation = 0

    init(facade: UsageQueryFacade) {
        self.facade = facade
    }

    func load(enabledTools: Set<MonitoringToolID>) async {
        generation += 1
        let request = generation
        isLoading = true
        defer {
            if generation == request { isLoading = false }
        }

        var result: [MonitoringToolID: UsagePair] = [:]
        if enabledTools.contains(.codex) {
            async let seven = try? facade.getDashboardMetrics(days: 7, providerFilter: .codex)
            async let thirty = try? facade.getDashboardMetrics(days: 30, providerFilter: .codex)
            result[.codex] = await UsagePair(sevenDay: seven, thirtyDay: thirty)
        }
        if enabledTools.contains(.claude) {
            async let seven = try? facade.getDashboardMetrics(days: 7, providerFilter: .claude)
            async let thirty = try? facade.getDashboardMetrics(days: 30, providerFilter: .claude)
            result[.claude] = await UsagePair(sevenDay: seven, thirtyDay: thirty)
        }
        if enabledTools.contains(.antigravity) {
            async let seven = try? facade.getDashboardMetrics(days: 7, providerFilter: .antigravity)
            async let thirty = try? facade.getDashboardMetrics(days: 30, providerFilter: .antigravity)
            result[.antigravity] = await UsagePair(sevenDay: seven, thirtyDay: thirty)
        }
        guard generation == request else { return }
        usage = result
    }
}

public struct OverviewDashboardView: View {
    @ObservedObject private var state: AppState
    @StateObject private var store: OverviewDashboardStore
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.colorScheme) private var colorScheme
    private let onSelectTool: (MonitoringToolID) -> Void

    public init(
        state: AppState,
        facade: UsageQueryFacade,
        onSelectTool: @escaping (MonitoringToolID) -> Void
    ) {
        self.state = state
        self.onSelectTool = onSelectTool
        _store = StateObject(wrappedValue: OverviewDashboardStore(facade: facade))
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                overviewHeroCard
                toolStatusGrid
                localActivityCard
                resetTimelineCard
                syncHealthCard
            }
            .padding(24)
        }
        .task {
            await store.load(enabledTools: env.enabledToolsStore.enabledToolIDs)
        }
        .onChange(of: env.scanCoordinator.isScanning) { _, scanning in
            guard !scanning else { return }
            Task { await store.load(enabledTools: env.enabledToolsStore.enabledToolIDs) }
        }
        .onChange(of: env.claudeScanCoordinator.isScanning) { _, scanning in
            guard !scanning else { return }
            Task { await store.load(enabledTools: env.enabledToolsStore.enabledToolIDs) }
        }
        .onChange(of: env.antigravityActivityCoordinator.isScanning) { _, scanning in
            guard !scanning else { return }
            Task { await store.load(enabledTools: env.enabledToolsStore.enabledToolIDs) }
        }
    }

    // MARK: - 全景全息决策主控台
    private var overviewHeroCard: some View {
        let topRecommendation = state.quotaRecommendations.first
        let insight = highestRiskInsight
        let status = overallStatus(topRecommendation)
        let enabledDescriptors = env.enabledToolsStore.enabledDescriptors

        return VStack(alignment: .leading, spacing: 18) {
            // 顶部顶栏：全局健康度 + 标题 + 工具接入胶囊
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    status.tint.opacity(colorScheme == .dark ? 0.22 : 0.14),
                                    status.tint.opacity(colorScheme == .dark ? 0.10 : 0.06)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(status.tint.opacity(colorScheme == .dark ? 0.40 : 0.25), lineWidth: 1)
                        )
                    Image(systemName: status.icon)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(status.tint)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(status.title)
                        .font(.system(size: 20, weight: .black, design: .rounded))
                    Text(status.message)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        .lineLimit(2)
                }

                Spacer()

                // 已接入工具胶囊
                HStack(spacing: 7) {
                    HStack(spacing: -5) {
                        ForEach(enabledDescriptors) { descriptor in
                            ToolAppIcon(tool: descriptor.id, size: 16)
                                .frame(width: 22, height: 22)
                                .background(AppTheme.insetSurface(for: colorScheme), in: Circle())
                                .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 1))
                        }
                    }
                    Text(L10n.format(
                        "%d tools enabled",
                        zhHans: "已启用 %d 个工具",
                        enabledDescriptors.count
                    ))
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AppTheme.insetSurface(for: colorScheme), in: Capsule())
                .overlay(
                    Capsule().strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
                )
            }

            // 核心双决策卡片
            if let insight {
                HStack(spacing: 14) {
                    // 最高风险额度池
                    heroDecisionCard(
                        tag: L10n.text("最高风险额度", "Highest-Risk Quota"),
                        title: quotaPoolTitle(insight),
                        subtitle: L10n.format(
                            "%@ available · %@",
                            zhHans: "可用 %@ · %@",
                            UsageNumberFormatter.percent(insight.remainingPercent, maximumFractionDigits: 0),
                            insight.input.windowTitle
                        ),
                        icon: insight.risk == .critical ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.67percent",
                        tint: insightTint(insight),
                        progress: insight.remainingPercent / 100.0
                    )

                    // 智能预测与消耗节奏
                    heroForecastDecisionCard(insight: insight)
                }
            }

            // 行动建议流
            if !state.quotaRecommendations.isEmpty {
                CyberDivider()
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(state.quotaRecommendations.prefix(3))) { recommendation in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: recommendation.severity.symbolName)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(recommendationTint(recommendation.severity))
                                .frame(width: 22, height: 22)
                                .background(
                                    recommendationTint(recommendation.severity).opacity(colorScheme == .dark ? 0.18 : 0.12),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(recommendation.title)
                                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                                Text(recommendation.message)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(recommendationTint(recommendation.severity).opacity(colorScheme == .dark ? 0.08 : 0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(recommendationTint(recommendation.severity).opacity(colorScheme == .dark ? 0.25 : 0.15), lineWidth: 0.8)
                        )
                    }
                }
            }
        }
        .cyberCard(cornerRadius: 18, padding: 22, isHighlighted: true, glowColor: status.tint)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("整体状态与建议", "Overall status and recommendations"))
    }

    private func heroDecisionCard(
        tag: String,
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        progress: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
                Text(tag)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                Spacer()
            }

            Text(title)
                .font(.system(size: 15, weight: .black, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                .lineLimit(1)

            AntigravityFlowProgressBar(value: progress, tint: tint, height: 6)

            Text(subtitle)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .padding(14)
        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
        )
    }

    private func heroForecastDecisionCard(insight: ProviderQuotaInsight) -> some View {
        let tint = insightTint(insight)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
                Text(L10n.text("预测结果", "Forecast"))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                Spacer()
                Text(insight.freshness.localizedTitle)
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(freshnessTint(insight.freshness))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(freshnessTint(insight.freshness).opacity(colorScheme == .dark ? 0.16 : 0.10), in: Capsule())
            }

            Text(forecastText(insight))
                .font(.system(size: 15, weight: .black, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)

            HStack(spacing: 6) {
                Text(L10n.text("消耗速度:", "Pace:"))
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                Text(rateText(insight))
                    .font(.system(size: 10.5, weight: .black, design: .monospaced))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                Spacer()
                Text(insight.forecast.confidence.localizedDescription)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .padding(14)
        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
        )
    }

    // MARK: - 多工具监控网格
    private var toolStatusGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 310), spacing: 16)], spacing: 16) {
            ForEach(env.enabledToolsStore.enabledDescriptors) { descriptor in
                Button {
                    onSelectTool(descriptor.id)
                } label: {
                    toolStatusCard(descriptor)
                }
                .buttonStyle(.plain)
                .accessibilityHint(L10n.text("打开工具专属页面", "Open the tool space"))
            }
        }
    }

    private func toolStatusCard(_ descriptor: MonitoringToolDescriptor) -> some View {
        let tint = accent(for: descriptor)
        let rows = quotaRows(for: descriptor.id)
        let insight = provider(for: descriptor.id).flatMap { state.primaryQuotaInsight(for: $0) }
        let isDark = colorScheme == .dark
        let planText = toolPlanText(descriptor.id)

        return VStack(alignment: .leading, spacing: 14) {
            // Header 头部
            HStack(spacing: 12) {
                ToolAppIcon(tool: descriptor.id, size: 36)
                    .frame(width: 42, height: 42)
                    .background(
                        LinearGradient(
                            colors: [
                                tint.opacity(isDark ? 0.20 : 0.12),
                                tint.opacity(isDark ? 0.08 : 0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(tint.opacity(isDark ? 0.35 : 0.20), lineWidth: 0.9)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(descriptor.displayName)
                            .font(.system(size: 16, weight: .black, design: .rounded))
                        if !planText.isEmpty {
                            Text(planText.uppercased())
                                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                .foregroundStyle(tint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(tint.opacity(isDark ? 0.15 : 0.09), in: Capsule())
                                .overlay(
                                    Capsule().strokeBorder(tint.opacity(isDark ? 0.35 : 0.22), lineWidth: 0.7)
                                )
                        }
                    }
                    HStack(spacing: 4) {
                        Circle()
                            .fill(freshnessTint(insight?.freshness ?? .unknown))
                            .frame(width: 5, height: 5)
                        Text(toolSyncText(descriptor.id))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    .frame(width: 24, height: 24)
                    .background(AppTheme.insetSurface(for: colorScheme), in: Circle())
            }

            // 额度池进度区
            VStack(spacing: 8) {
                ForEach(Array(rows.prefix(2))) { row in
                    VStack(spacing: 4) {
                        HStack {
                            Text(row.title)
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                            Spacer()
                            Text(row.value)
                                .font(.system(size: 11, weight: .black, design: .monospaced))
                                .foregroundStyle(row.tint)
                        }
                        AntigravityFlowProgressBar(value: row.progress, tint: row.tint, height: 5.5)
                    }
                }

                if rows.count > 2 {
                    HStack {
                        Spacer()
                        Text(L10n.format(
                            "%d more quota pools",
                            zhHans: "另有 %d 个额度池",
                            rows.count - 2
                        ))
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppTheme.insetSurface(for: colorScheme), in: Capsule())
                    }
                }
            }

            // 预测与速度双列嵌入卡片
            if let insight {
                HStack(spacing: 10) {
                    toolInsightCell(
                        icon: "chart.line.uptrend.xyaxis",
                        title: L10n.text("预测", "Forecast"),
                        value: forecastText(insight),
                        tint: insightTint(insight)
                    )
                    toolInsightCell(
                        icon: "speedometer",
                        title: L10n.text("消耗速度", "Usage Pace"),
                        value: rateText(insight),
                        tint: insightTint(insight)
                    )
                }
            }

            // 本机活动摘要条
            localSummary(for: descriptor.id)

            CyberDivider()

            // 底部同步与重置倒计时
            HStack {
                let freshness = insight?.freshness ?? .unknown
                HStack(spacing: 4) {
                    Image(systemName: freshness.symbolName)
                        .font(.system(size: 9))
                    Text(toolSyncText(descriptor.id))
                }
                .foregroundStyle(freshnessTint(freshness))

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                    Text(L10n.format(
                        "Reset %@",
                        zhHans: "%@重置",
                        nextResetText(descriptor.id)
                    ))
                }
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
        }
        .cyberCard(cornerRadius: 18, padding: 18)
    }

    private func toolInsightCell(icon: String, title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 8.5))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                Text(title)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }
            Text(value)
                .font(.system(size: 10.5, weight: .black, design: .monospaced))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func localSummary(for tool: MonitoringToolID) -> some View {
        if tool == .antigravity {
            let metrics = store.usage[tool]?.sevenDay
            let activity = state.latestAntigravityActivity?.sevenDayMetrics
            let change = tokenChange(for: tool)
            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 9.5))
                    Text(L10n.format(
                        "%d sessions",
                        zhHans: "%d 个会话",
                        metrics?.totalSessions ?? activity?.taskCount ?? 0
                    ))
                }
                Text("·")
                Text(UsageNumberFormatter.compactTokenCount(metrics?.totalTokens.canonicalTotalTokens ?? 0))
                if metrics?.totalCost.rawValue ?? 0 > 0 {
                    Text("·")
                    Text(UsageNumberFormatter.currencyUSD(metrics?.totalCost ?? .zero))
                        .foregroundStyle(AppTheme.accentEmerald(for: colorScheme))
                }
                Spacer()
                Text(changeText(change))
                    .foregroundStyle(changeTint(change))
            }
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 6))
        } else if let metrics = store.usage[tool]?.sevenDay {
            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 9))
                    Text(L10n.format("%d sessions", zhHans: "%d 个会话", metrics.totalSessions))
                }
                Text("·")
                Text(UsageNumberFormatter.compactTokenCount(metrics.totalTokens.canonicalTotalTokens))
                Text("·")
                Text(UsageNumberFormatter.currencyUSD(metrics.totalCost))
                    .foregroundStyle(AppTheme.accentEmerald(for: colorScheme))
                Spacer()
                Text(changeText(tokenChange(for: tool)))
                    .foregroundStyle(changeTint(tokenChange(for: tool)))
            }
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 6))
        } else {
            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                Text(L10n.text("本机数据正在同步", "Local data is syncing"))
            }
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
    }

    // MARK: - 即将重置时间线
    private var resetTimelineCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CyberSectionHeader(title: L10n.text("即将重置", "Upcoming Resets"), icon: "clock.arrow.circlepath")
            CyberDivider()
            if resetItems.isEmpty {
                Text(L10n.text("暂时没有可用的重置时间", "No reset times are available yet"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .center)
            } else {
                VStack(spacing: 8) {
                    ForEach(resetItems) { item in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(item.tint)
                                .frame(width: 7, height: 7)
                                .shadow(color: item.tint.opacity(0.5), radius: 2)

                            Text(item.tool)
                                .font(.system(size: 11.5, weight: .black, design: .rounded))
                                .frame(width: 72, alignment: .leading)

                            Text(item.window)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                            Spacer()

                            Text(UsageNumberFormatter.relativeTimeString(from: item.date))
                                .font(.system(size: 10.5, weight: .heavy, design: .monospaced))
                                .foregroundStyle(item.tint)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(item.tint.opacity(colorScheme == .dark ? 0.16 : 0.10), in: Capsule())
                        }
                        .padding(9)
                        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
        .cyberCard(cornerRadius: 18, padding: 20)
    }

    // MARK: - 本机活动总览
    private var localActivityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                CyberSectionHeader(title: L10n.text("本机活动", "Local Activity"), icon: "chart.bar.xaxis")
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small) }
            }
            Text(L10n.text(
                "各工具保留自己的统计单位，不进行跨工具排名。",
                "Each tool keeps its native units without cross-tool ranking."
            ))
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))

            CyberDivider()

            VStack(spacing: 10) {
                ForEach(env.enabledToolsStore.enabledDescriptors) { descriptor in
                    if descriptor.id == .antigravity {
                        antigravityActivityRow
                    } else {
                        let metrics = store.usage[descriptor.id]
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                HStack(spacing: 6) {
                                    ToolAppIcon(tool: descriptor.id, size: 20)
                                    Text(descriptor.displayName)
                                }
                                .font(.system(size: 12.5, weight: .black, design: .rounded))
                                .foregroundStyle(accent(for: descriptor))

                                Spacer()

                                Label(changeText(tokenChange(for: descriptor.id)), systemImage: changeIcon(tokenChange(for: descriptor.id)))
                                    .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                                    .foregroundStyle(changeTint(tokenChange(for: descriptor.id)))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(changeTint(tokenChange(for: descriptor.id)).opacity(colorScheme == .dark ? 0.16 : 0.10), in: Capsule())
                            }
                            HStack(spacing: 12) {
                                usageCell(title: "7D", metrics: metrics?.sevenDay)
                                usageCell(title: "30D", metrics: metrics?.thirtyDay)
                            }
                        }
                        .padding(12)
                        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
        }
        .cyberCard(cornerRadius: 18, padding: 20)
    }

    private func usageCell(title: String, metrics: DashboardMetricsDTO?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            HStack(spacing: 8) {
                Text(L10n.format(
                    "%d sessions",
                    zhHans: "%d 个会话",
                    metrics?.totalSessions ?? 0
                ))
                Text(UsageNumberFormatter.compactTokenCount(metrics?.totalTokens.canonicalTotalTokens ?? 0))
                Text(UsageNumberFormatter.currencyUSD(metrics?.totalCost ?? .zero))
                    .foregroundStyle(AppTheme.accentEmerald(for: colorScheme))
            }
            .font(.system(size: 11, weight: .bold, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(AppTheme.insetSurface(for: colorScheme).opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
    }

    private var antigravityActivityRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                HStack(spacing: 6) {
                    ToolAppIcon(tool: .antigravity, size: 20)
                    Text("Antigravity")
                    if !state.antigravityActivityProfiles.isEmpty {
                        Text(L10n.format(
                            "%d local sources",
                            zhHans: "%d 个本机来源",
                            state.antigravityActivityProfiles.count
                        ))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(AppTheme.insetSurface(for: colorScheme), in: Capsule())
                    }
                }
                .font(.system(size: 12.5, weight: .black, design: .rounded))
                .foregroundStyle(AppTheme.accentCyan(for: colorScheme))

                Spacer()

                let change = state.latestAntigravityActivity?.taskChangePercent(days: 7)
                Label(changeText(change), systemImage: changeIcon(change))
                    .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                    .foregroundStyle(changeTint(change))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(changeTint(change).opacity(colorScheme == .dark ? 0.16 : 0.10), in: Capsule())
            }
            HStack(spacing: 12) {
                overviewActivityCell(
                    title: "7D",
                    metrics: state.latestAntigravityActivity?.sevenDayMetrics,
                    usage: store.usage[.antigravity]?.sevenDay
                )
                overviewActivityCell(
                    title: "30D",
                    metrics: state.latestAntigravityActivity?.thirtyDayMetrics,
                    usage: store.usage[.antigravity]?.thirtyDay
                )
            }
        }
        .padding(12)
        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func overviewActivityCell(
        title: String,
        metrics: AntigravityActivitySnapshot.PeriodMetrics?,
        usage: DashboardMetricsDTO? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            HStack(spacing: 8) {
                if let usage {
                    Text(L10n.format(
                        "%d sessions",
                        zhHans: "%d 个会话",
                        usage.totalSessions
                    ))
                    Text(UsageNumberFormatter.compactTokenCount(usage.totalTokens.canonicalTotalTokens))
                } else {
                    Text(L10n.format("%d tasks", zhHans: "%d 个任务", metrics?.taskCount ?? 0))
                }
                Text(L10n.format(
                    "%@ steps",
                    zhHans: "%@ 步",
                    UsageNumberFormatter.compactTokenCount(metrics?.stepCount ?? 0)
                ))
                Text(L10n.format(
                    "%d active days",
                    zhHans: "%d 个活跃日",
                    metrics?.activeDays ?? 0
                ))
            }
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(AppTheme.accentCyan(for: colorScheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(AppTheme.insetSurface(for: colorScheme).opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
    }

    // MARK: - 同步健康矩阵
    private var syncHealthCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                CyberSectionHeader(title: L10n.text("同步状态", "Sync Health"), icon: "arrow.triangle.2.circlepath")
                Spacer()
                Button {
                    Task { await env.refreshAllData() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                        Text(L10n.text("全部刷新", "Refresh All"))
                    }
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                }
                .buttonStyle(.bordered)
                .disabled(state.isRefreshing || state.isRefreshingClaudeUsage || state.isRefreshingAntigravityQuota)
            }
            CyberDivider()
            VStack(spacing: 8) {
                ForEach(env.enabledToolsStore.enabledDescriptors) { descriptor in
                    syncRow(descriptor)
                }
            }
        }
        .cyberCard(cornerRadius: 18, padding: 20)
    }

    private func syncRow(_ descriptor: MonitoringToolDescriptor) -> some View {
        let details = syncDetails(for: descriptor.id)
        return HStack(spacing: 12) {
            ToolAppIcon(tool: descriptor.id, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(descriptor.displayName)
                        .font(.system(size: 12, weight: .black, design: .rounded))
                    HStack(spacing: 4) {
                        Image(systemName: details.icon)
                            .font(.system(size: 9))
                        Text(details.status)
                    }
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(details.tint)
                }
                if let error = details.error {
                    Text(error)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(AppTheme.accentAmber(for: colorScheme))
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(details.last.map {
                    L10n.format("Last %@", zhHans: "上次 %@", UsageNumberFormatter.relativeTimeString(from: $0))
                } ?? L10n.text("尚未成功", "No successful sync"))
                .font(.system(size: 10, weight: .bold, design: .monospaced))

                Text(details.next.map {
                    L10n.format("Next %@", zhHans: "下次 %@", UsageNumberFormatter.relativeTimeString(from: $0))
                } ?? L10n.text("等待安排", "Not scheduled"))
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }
        }
        .padding(10)
        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }


    private func accent(for descriptor: MonitoringToolDescriptor) -> Color {
        descriptor.accent == .amber
            ? AppTheme.accentAmber(for: colorScheme)
            : AppTheme.accentCyan(for: colorScheme)
    }

    private func toolPlanText(_ tool: MonitoringToolID) -> String {
        switch tool {
        case .codex: return state.subscriptionPlanTitle
        case .claude: return state.latestClaudeUsage?.tier ?? L10n.text("套餐待同步", "Plan Pending")
        case .antigravity: return state.latestAntigravityQuota?.planName ?? L10n.text("套餐待同步", "Plan Pending")
        default: return ""
        }
    }

    private func toolSyncText(_ tool: MonitoringToolID) -> String {
        switch tool {
        case .codex:
            return state.connectionStatus.isConnected ? L10n.text("同步正常", "Sync Healthy") : L10n.text("等待连接", "Waiting for Connection")
        case .claude:
            guard let date = state.latestClaudeUsage?.capturedAt else { return L10n.text("等待同步", "Waiting for Sync") }
            return L10n.format("Updated %@", zhHans: "%@更新", UsageNumberFormatter.relativeTimeString(from: date))
        case .antigravity:
            guard let date = state.latestAntigravityQuota?.capturedAt else { return L10n.text("等待同步", "Waiting for Sync") }
            return L10n.format("Updated %@", zhHans: "%@更新", UsageNumberFormatter.relativeTimeString(from: date))
        default:
            return L10n.text("等待同步", "Waiting for Sync")
        }
    }

    private func nextResetText(_ tool: MonitoringToolID) -> String {
        let date: Date?
        switch tool {
        case .codex:
            date = state.preferredDisplayQuotaSnapshot?.resetsAt.map { Date(timeIntervalSince1970: Double($0)) }
        case .claude:
            date = state.latestClaudeUsage?.fiveHourForDisplay?.resetAt ?? state.latestClaudeUsage?.sevenDay?.resetAt
        case .antigravity:
            date = state.latestAntigravityQuota?.buckets.compactMap(\.resetAt).min()
        default:
            date = nil
        }
        guard let date else { return L10n.text("重置时间未知", "Reset Unknown") }
        return UsageNumberFormatter.relativeTimeString(from: date)
    }

    private struct QuotaRow: Identifiable {
        let id: String
        let title: String
        let value: String
        let progress: Double
        let tint: Color
    }

    private func quotaRows(for tool: MonitoringToolID) -> [QuotaRow] {
        switch tool {
        case .codex:
            return [state.fiveHourQuotaSnapshot, state.weeklyQuotaSnapshot].compactMap { snapshot in
                guard let snapshot else { return nil }
                let title = QuotaWindowKind(windowDurationMins: snapshot.windowDurationMins) == .fiveHour
                    ? L10n.text("5 小时", "5 Hours")
                    : L10n.text("7 天", "7 Days")
                return makeQuotaRow(id: "codex-\(snapshot.limitId)-\(snapshot.slot)", title: title, used: snapshot.usedPercent)
            }
        case .claude:
            guard let usage = state.latestClaudeUsage else { return [] }
            return ([usage.fiveHourForDisplay, usage.sevenDay].compactMap { $0 } + usage.scopedWeekly).map {
                makeQuotaRow(id: "claude-\($0.id)", title: $0.localizedTitle, used: $0.usedPercent)
            }
        case .antigravity:
            guard let quota = state.latestAntigravityQuota else { return [] }
            return quota.orderedDisplayBuckets.map {
                makeQuotaRow(
                    id: "antigravity-\($0.id)",
                    title: "\(AntigravityQuotaSnapshot.groupDisplayTitle(for: $0.groupTitle)) · \($0.bucket.window.localizedTitle)",
                    used: 100 - $0.bucket.remainingPercent
                )
            }
        default:
            return []
        }
    }

    private func makeQuotaRow(id: String, title: String, used: Double) -> QuotaRow {
        let displayed = state.quotaDisplayMode == .used ? used : 100 - used
        let tint: Color = used >= 85
            ? AppTheme.accentRose(for: colorScheme)
            : (used >= 60 ? AppTheme.accentAmber(for: colorScheme) : AppTheme.accentEmerald(for: colorScheme))
        return QuotaRow(
            id: id,
            title: title,
            value: UsageNumberFormatter.percent(displayed, maximumFractionDigits: 0),
            progress: min(max(displayed / 100, 0), 1),
            tint: tint
        )
    }

    private struct OverallStatus {
        let title: String
        let message: String
        let icon: String
        let tint: Color
    }

    private func overallStatus(_ recommendation: QuotaRecommendation?) -> OverallStatus {
        guard let recommendation else {
            return OverallStatus(
                title: L10n.text("等待同步数据", "Waiting for synced data"),
                message: L10n.text(
                    "完成首次同步后，这里会汇总额度风险和行动建议。",
                    "Quota risks and recommended actions will appear after the first sync."
                ),
                icon: "ellipsis.circle.fill",
                tint: AppTheme.textSecondary(for: colorScheme)
            )
        }
        let title: String
        switch recommendation.severity {
        case .critical: title = L10n.text("有额度风险需要处理", "Quota risk needs attention")
        case .warning: title = L10n.text("当前消耗速度需要关注", "Current usage pace needs attention")
        case .information: title = L10n.text("正在完善用量判断", "Building a clearer usage picture")
        case .healthy: title = L10n.text("整体额度状态健康", "Overall quota status is healthy")
        }
        return OverallStatus(
            title: title,
            message: recommendation.message,
            icon: recommendation.severity.symbolName,
            tint: recommendationTint(recommendation.severity)
        )
    }

    private var highestRiskInsight: ProviderQuotaInsight? {
        let enabled = Set(env.enabledToolsStore.enabledToolIDs.compactMap(provider(for:)))
        return state.providerQuotaInsights
            .filter { enabled.contains($0.key) }
            .flatMap(\.value)
            .sorted {
                let left = insightPriority($0)
                let right = insightPriority($1)
                if left != right { return left > right }
                return $0.remainingPercent < $1.remainingPercent
            }
            .first
    }

    private func insightPriority(_ insight: ProviderQuotaInsight) -> Int {
        if insight.freshness == .stale { return 50 }
        switch insight.risk {
        case .critical: return 40
        case .warning: return 30
        case .onTrack: return 20
        case .underPaced: return 10
        case .insufficientData: return 5
        }
    }

    private func provider(for tool: MonitoringToolID) -> UsageProvider? {
        switch tool {
        case .codex: return .codex
        case .claude: return .claude
        case .antigravity: return .antigravity
        default: return nil
        }
    }

    private func quotaPoolTitle(_ insight: ProviderQuotaInsight) -> String {
        insight.input.groupTitle.caseInsensitiveCompare(insight.provider.localizedName) == .orderedSame
            ? insight.provider.localizedName
            : "\(insight.provider.localizedName) · \(insight.input.groupTitle)"
    }

    private func forecastText(_ insight: ProviderQuotaInsight) -> String {
        guard insight.hasUsableForecast else {
            return insight.freshness == .stale
                ? L10n.text("预测已暂停", "Forecast paused")
                : L10n.text("正在积累数据", "Collecting data")
        }
        if insight.risk == .critical, let exhaustion = insight.forecast.estimatedExhaustionDate {
            return L10n.format(
                "Runs out %@",
                zhHans: "%@耗尽",
                UsageNumberFormatter.relativeTimeString(from: exhaustion)
            )
        }
        guard let remaining = insight.forecast.projectedRemainingAtReset else {
            return L10n.text("正在积累数据", "Collecting data")
        }
        return L10n.format(
            "%@ left at reset",
            zhHans: "重置时剩余 %@",
            UsageNumberFormatter.percent(remaining, maximumFractionDigits: 0)
        )
    }

    private func rateText(_ insight: ProviderQuotaInsight) -> String {
        guard insight.hasUsableForecast else { return L10n.text("正在积累数据", "Collecting data") }
        return String(format: "%.2f %@", insight.burnRateForDisplay, insight.rateUnitTitle)
    }

    private func insightTint(_ insight: ProviderQuotaInsight) -> Color {
        if insight.freshness == .stale || insight.risk == .critical {
            return AppTheme.accentRose(for: colorScheme)
        }
        if insight.freshness == .delayed || insight.risk == .warning {
            return AppTheme.accentAmber(for: colorScheme)
        }
        return AppTheme.accentEmerald(for: colorScheme)
    }

    private func freshnessTint(_ freshness: ProviderDataFreshness) -> Color {
        switch freshness {
        case .fresh: return AppTheme.accentEmerald(for: colorScheme)
        case .delayed: return AppTheme.accentAmber(for: colorScheme)
        case .stale: return AppTheme.accentRose(for: colorScheme)
        case .unknown: return AppTheme.textSecondary(for: colorScheme)
        }
    }

    private func recommendationTint(_ severity: QuotaRecommendationSeverity) -> Color {
        switch severity {
        case .critical: return AppTheme.accentRose(for: colorScheme)
        case .warning: return AppTheme.accentAmber(for: colorScheme)
        case .information: return AppTheme.accentCyan(for: colorScheme)
        case .healthy: return AppTheme.accentEmerald(for: colorScheme)
        }
    }

    private func tokenChange(for tool: MonitoringToolID) -> Double? {
        guard let buckets = store.usage[tool]?.thirtyDay?.dailyBuckets.sorted(by: { $0.date < $1.date }),
              buckets.count >= 14 else { return nil }
        let current = buckets.suffix(7).reduce(Int64(0)) { $0 + $1.tokens.canonicalTotalTokens }
        let previous = buckets.dropLast(7).suffix(7).reduce(Int64(0)) { $0 + $1.tokens.canonicalTotalTokens }
        guard previous > 0 else { return current == 0 ? 0 : nil }
        return Double(current - previous) / Double(previous) * 100
    }

    private func changeText(_ change: Double?) -> String {
        guard let change else { return L10n.text("暂无上期基线", "No prior baseline") }
        if abs(change) < 0.5 { return L10n.text("与上期持平", "Unchanged from prior") }
        return L10n.format(
            "%+.0f%% vs prior period",
            zhHans: "较上期 %+.0f%%",
            change
        )
    }

    private func changeIcon(_ change: Double?) -> String {
        guard let change else { return "minus.circle" }
        if abs(change) < 0.5 { return "equal.circle.fill" }
        return change > 0 ? "arrow.up.right" : "arrow.down.right"
    }

    private func changeTint(_ change: Double?) -> Color {
        guard let change, abs(change) >= 0.5 else { return AppTheme.textSecondary(for: colorScheme) }
        return change > 0
            ? AppTheme.accentCyan(for: colorScheme)
            : AppTheme.accentAmber(for: colorScheme)
    }

    private struct SyncDetails {
        let status: String
        let icon: String
        let tint: Color
        let last: Date?
        let next: Date?
        let error: String?
    }

    private func syncDetails(for tool: MonitoringToolID) -> SyncDetails {
        let interval: TimeInterval
        let last: Date?
        let next: Date?
        let error: String?
        let isCoolingDown: Bool

        switch tool {
        case .codex:
            interval = TimeInterval(state.refreshIntervalSeconds)
            last = state.primaryQuotaInsight(for: .codex)?.input.capturedAt
                ?? state.lastSuccessfulRefreshAt
            next = last?.addingTimeInterval(interval)
            error = state.codexRefreshErrorText
                ?? state.codexStorageErrorText
                ?? (state.connectionStatus.isConnected ? nil : state.quotaUnavailableDescription)
            isCoolingDown = false
        case .claude:
            interval = TimeInterval(state.claudeRefreshIntervalSeconds)
            last = state.latestClaudeUsage?.capturedAt
            next = last?.addingTimeInterval(interval)
            error = state.claudeUsageErrorText
            isCoolingDown = false
        case .antigravity:
            interval = TimeInterval(state.antigravityRefreshIntervalSeconds)
            last = state.antigravitySyncState.lastSuccessAt ?? state.latestAntigravityQuota?.capturedAt
            isCoolingDown = state.antigravitySyncState.cooldownUntil.map { $0 > Date() } == true
            next = state.antigravitySyncState.cooldownUntil
                ?? state.antigravitySyncState.nextAttemptAt
                ?? last?.addingTimeInterval(interval)
            error = state.antigravityQuotaErrorText
        default:
            interval = 300
            last = nil
            next = nil
            error = nil
            isCoolingDown = false
        }

        let freshness = provider(for: tool).flatMap { state.primaryQuotaInsight(for: $0)?.freshness }
            ?? ProviderDataFreshness.evaluate(capturedAt: last, refreshInterval: interval)
        if isCoolingDown {
            return SyncDetails(
                status: L10n.text("刷新受限", "Refresh limited"),
                icon: "hourglass.badge.plus",
                tint: AppTheme.accentAmber(for: colorScheme),
                last: last,
                next: next,
                error: error
            )
        }
        if let error, !error.isEmpty {
            return SyncDetails(
                status: L10n.text("同步异常", "Sync issue"),
                icon: "exclamationmark.triangle.fill",
                tint: AppTheme.accentAmber(for: colorScheme),
                last: last,
                next: next,
                error: error
            )
        }
        return SyncDetails(
            status: freshness.localizedTitle,
            icon: freshness.symbolName,
            tint: freshnessTint(freshness),
            last: last,
            next: next,
            error: nil
        )
    }

    private struct ResetItem: Identifiable {
        let id: String
        let tool: String
        let window: String
        let date: Date
        let tint: Color
    }

    private var resetItems: [ResetItem] {
        var items: [ResetItem] = []
        if env.enabledToolsStore.isEnabled(.codex) {
            for snapshot in [state.fiveHourQuotaSnapshot, state.weeklyQuotaSnapshot].compactMap({ $0 }) {
                guard let reset = snapshot.resetsAt else { continue }
                let window = QuotaWindowKind(windowDurationMins: snapshot.windowDurationMins) == .fiveHour
                    ? L10n.text("5 小时额度", "5-Hour Quota")
                    : L10n.text("7 天额度", "7-Day Quota")
                items.append(ResetItem(
                    id: "codex-\(snapshot.slot)-\(reset)",
                    tool: "Codex",
                    window: window,
                    date: Date(timeIntervalSince1970: Double(reset)),
                    tint: AppTheme.accentCyan(for: colorScheme)
                ))
            }
        }
        if env.enabledToolsStore.isEnabled(.claude), let usage = state.latestClaudeUsage {
            for window in [usage.fiveHourForDisplay, usage.sevenDay].compactMap({ $0 }) + usage.scopedWeekly where !window.isStale {
                items.append(ResetItem(
                    id: "claude-\(window.id)-\(window.resetAt.timeIntervalSince1970)",
                    tool: "Claude",
                    window: window.localizedTitle,
                    date: window.resetAt,
                    tint: AppTheme.accentAmber(for: colorScheme)
                ))
            }
        }
        if env.enabledToolsStore.isEnabled(.antigravity), let quota = state.latestAntigravityQuota {
            for item in quota.orderedDisplayBuckets {
                guard let reset = item.bucket.resetAt else { continue }
                items.append(ResetItem(
                    id: "antigravity-\(item.id)-\(reset.timeIntervalSince1970)",
                    tool: "Antigravity",
                    window: "\(AntigravityQuotaSnapshot.groupDisplayTitle(for: item.groupTitle)) · \(item.bucket.window.localizedTitle)",
                    date: reset,
                    tint: AppTheme.accentCyan(for: colorScheme)
                ))
            }
        }
        return items.sorted { $0.date < $1.date }
    }
}
