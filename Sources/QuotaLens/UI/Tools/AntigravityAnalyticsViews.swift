import SwiftUI
import Charts

struct AntigravityQuotaAnalyticsView: View {
    @ObservedObject var state: AppState
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedInsightID: String?
    @State private var showsAllModels = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                quotaHero

                if state.antigravityQuotaInsights.isEmpty {
                    quotaEmptyState
                } else {
                    quotaPoolGrid
                    quotaTrendCard
                }

                if let quota = state.latestAntigravityQuota, !quota.models.isEmpty {
                    modelAvailabilityCard(quota)
                }
            }
            .padding(24)
        }
        .task {
            await env.refreshProviderQuotaInsights()
            normalizeSelection()
        }
        .onChange(of: state.antigravityQuotaInsights.map(\.id)) { _, _ in
            normalizeSelection()
        }
    }

    private var selectedInsight: ProviderQuotaInsight? {
        state.antigravityQuotaInsights.first { $0.id == selectedInsightID }
            ?? state.primaryAntigravityQuotaInsight
    }

    // MARK: - 核心 Hero 全息主控舱
    private var quotaHero: some View {
        let insight = state.primaryAntigravityQuotaInsight
        let tint = insightTint(insight)
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let shownPercent = insight.map {
            state.quotaDisplayMode == .used ? $0.input.usedPercent : $0.remainingPercent
        } ?? 0.0

        return VStack(alignment: .leading, spacing: 18) {
            // 顶部操作栏与身份徽标
            HStack(alignment: .center, spacing: 12) {
                ToolAppIcon(tool: .antigravity, size: 34)
                    .frame(width: 44, height: 44)
                    .background(
                        LinearGradient(
                            colors: [
                                cyan.opacity(colorScheme == .dark ? 0.22 : 0.14),
                                tint.opacity(colorScheme == .dark ? 0.12 : 0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(cyan.opacity(colorScheme == .dark ? 0.35 : 0.20), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Antigravity")
                            .font(.system(size: 20, weight: .black, design: .rounded))
                        if let plan = state.latestAntigravityQuota?.planName, !plan.isEmpty {
                            Text(plan.uppercased())
                                .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                                .foregroundStyle(cyan)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(cyan.opacity(colorScheme == .dark ? 0.16 : 0.10), in: Capsule())
                                .overlay(
                                    Capsule().strokeBorder(cyan.opacity(colorScheme == .dark ? 0.35 : 0.25), lineWidth: 0.8)
                                )
                        }
                    }
                    HStack(spacing: 6) {
                        Circle()
                            .fill(tint)
                            .frame(width: 6, height: 6)
                            .shadow(color: tint.opacity(0.6), radius: 3)
                        Text(heroStatusTitle(insight))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(tint)
                    }
                }

                Spacer()

                // 高对比度已用/可用视角分段器
                CyberSegmentedPicker(selection: Binding(
                    get: { state.quotaDisplayMode },
                    set: { state.setQuotaDisplayMode($0) }
                ))

                // 同步时间微徽章
                HStack(spacing: 5) {
                    Image(systemName: "clock.arrow.2.circlepath")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(cyan)
                    Text(syncShortTimeText)
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
                )
            }

            CyberDivider()

            if let insight {
                HStack(spacing: 24) {
                    // 全息双环表盘（以最紧俏池为主焦点）
                    CircularProgressView(
                        progress: shownPercent / 100.0,
                        riskProgress: (100.0 - insight.remainingPercent) / 100.0,
                        lineWidth: 15,
                        size: 148,
                        title: state.quotaDisplayMode.pickerTitle,
                        valueText: UsageNumberFormatter.percent(shownPercent, maximumFractionDigits: 0),
                        subtitle: L10n.text("最紧俏池", "Tightest Pool")
                    )

                    // 2x2 结构化遥测指标网格
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        heroTelemetryTile(
                            icon: "speedometer",
                            title: L10n.text("消耗速度", "Usage Pace"),
                            value: rateText(insight),
                            caption: sustainablePaceCaption(insight),
                            tint: tint
                        )
                        heroTelemetryTile(
                            icon: "chart.line.uptrend.xyaxis",
                            title: L10n.text("额度预测", "Quota Forecast"),
                            value: forecastValue(insight),
                            caption: insight.forecast.confidence.localizedDescription,
                            tint: forecastTint(insight)
                        )
                        heroTelemetryTile(
                            icon: "clock.arrow.circlepath",
                            title: L10n.text("额度重置", "Quota Reset"),
                            value: insight.input.resetAt.map { UsageNumberFormatter.relativeTimeString(from: $0) }
                                ?? L10n.text("时间未知", "Time unknown"),
                            caption: "\(insight.input.groupTitle) · \(insight.input.windowTitle)",
                            tint: AppTheme.accentAmber(for: colorScheme)
                        )
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            heroTelemetryTile(
                                icon: insight.freshness.symbolName,
                                title: L10n.text("同步状态", "Sync Status"),
                                value: insight.freshness.localizedTitle,
                                caption: syncCaption,
                                tint: freshnessTint(insight.freshness)
                            )
                        }
                    }
                }
            } else if let message = state.antigravityQuotaErrorText {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppTheme.accentAmber(for: colorScheme))
                    Text(message)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.accentAmber(for: colorScheme))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10))
            }

            // 智能建议与不均衡提示横幅
            if let recommendation = state.primaryRecommendation(for: .antigravity) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: recommendation.severity.symbolName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(recommendationTint(recommendation.severity))
                        .frame(width: 28, height: 28)
                        .background(
                            recommendationTint(recommendation.severity).opacity(colorScheme == .dark ? 0.18 : 0.12),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(recommendation.title)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                        Text(recommendation.message)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                            .lineSpacing(2)
                    }
                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(recommendationTint(recommendation.severity).opacity(colorScheme == .dark ? 0.10 : 0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(recommendationTint(recommendation.severity).opacity(colorScheme == .dark ? 0.35 : 0.20), lineWidth: 0.9)
                )
            }
        }
        .cyberCard(cornerRadius: 18, padding: 22, isHighlighted: true, glowColor: cyan)
    }

    private var syncShortTimeText: String {
        if let captured = state.latestAntigravityQuota?.capturedAt {
            return UsageNumberFormatter.relativeTimeString(from: captured)
        }
        return L10n.text("等待同步", "Waiting for Sync")
    }

    private func heroTelemetryTile(
        icon: String,
        title: String,
        value: String,
        caption: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }
            Text(value)
                .font(.system(size: 15, weight: .black, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
            Text(caption)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .padding(12)
        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
        )
    }

    // MARK: - 额度池卡片网格
    private var quotaPoolGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
            ForEach(state.antigravityQuotaInsights) { insight in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        selectedInsightID = insight.id
                    }
                } label: {
                    quotaPoolCard(insight)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.format(
                    "%@ %@ quota, %@ available",
                    zhHans: "%@ %@ 额度，可用 %@",
                    insight.input.groupTitle,
                    insight.input.windowTitle,
                    UsageNumberFormatter.percent(insight.remainingPercent, maximumFractionDigits: 0)
                ))
                .accessibilityHint(L10n.text("选择后查看该额度池趋势", "Select to view this quota pool trend"))
            }
        }
    }

    private func quotaPoolCard(_ insight: ProviderQuotaInsight) -> some View {
        let shown = state.quotaDisplayMode == .used ? insight.input.usedPercent : insight.remainingPercent
        let tint = insightTint(insight)
        let selected = selectedInsight?.id == insight.id
        let isDark = colorScheme == .dark

        return VStack(alignment: .leading, spacing: 14) {
            // 头部：模型组名称 + 周期胶囊 + 大号数值
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(insight.input.groupTitle)
                            .font(.system(size: 14.5, weight: .black, design: .rounded))
                            .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                            .lineLimit(1)

                        Text(insight.input.windowTitle)
                            .font(.system(size: 9, weight: .heavy, design: .monospaced))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tint.opacity(isDark ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(tint.opacity(isDark ? 0.35 : 0.22), lineWidth: 0.7)
                            )
                    }

                    if insight.risk == .critical {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                            Text(L10n.text("紧俏池", "Tight Pool"))
                                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(AppTheme.accentRose(for: colorScheme))
                    }
                }

                Spacer()

                Text(UsageNumberFormatter.percent(shown, maximumFractionDigits: shown < 10 ? 1 : 0))
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }

            // 流光圆角渐变进度条
            AntigravityFlowProgressBar(value: shown / 100.0, tint: tint)

            // 双列结构化指标
            HStack(spacing: 10) {
                poolMetric(
                    icon: "speedometer",
                    title: L10n.text("当前速度", "Current Pace"),
                    value: rateText(insight)
                )
                poolMetric(
                    icon: "chart.line.uptrend.xyaxis",
                    title: L10n.text("重置时预计", "At Reset"),
                    value: projectedRemainingText(insight)
                )
            }

            CyberDivider(glowColor: selected ? tint.opacity(0.4) : nil)

            // 底部视角与重置倒计时
            HStack {
                Text(state.quotaDisplayMode.pickerTitle)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                    Text(insight.input.resetAt.map {
                        L10n.format("Resets %@", zhHans: "%@重置", UsageNumberFormatter.relativeTimeString(from: $0))
                    } ?? L10n.text("重置时间未知", "Reset unknown"))
                }
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }
        }
        .cyberCard(cornerRadius: 16, padding: 18, isHighlighted: selected, glowColor: tint)
    }

    private func poolMetric(icon: String, title: String, value: String) -> some View {
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
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - 额度趋势图表卡片
    @ViewBuilder
    private var quotaTrendCard: some View {
        if let insight = selectedInsight {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    CyberSectionHeader(title: L10n.text("额度趋势", "Quota Trend"), icon: "chart.xyaxis.line")

                    Spacer()

                    // 当前查看的额度池标签
                    HStack(spacing: 6) {
                        Circle()
                            .fill(AppTheme.accentCyan(for: colorScheme))
                            .frame(width: 6, height: 6)
                        Text("\(insight.input.groupTitle) · \(insight.input.windowTitle)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(AppTheme.accentCyan(for: colorScheme))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AppTheme.accentCyan(for: colorScheme).opacity(colorScheme == .dark ? 0.15 : 0.09), in: Capsule())
                }

                HStack {
                    Text(L10n.text("当前周期 · 已用额度百分比变化", "Current cycle · used quota percentage over time"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    Spacer()
                    if insight.trendPoints.count >= 4 {
                        chartLegend
                    }
                }

                CyberDivider()

                if insight.trendPoints.count >= 4 {
                    quotaTrendChart(insight)
                } else {
                    trendCollectingPlaceholder(insight)
                }
            }
            .cyberCard(cornerRadius: 18, padding: 20)
        }
    }

    private var chartLegend: some View {
        HStack(spacing: 14) {
            Label(L10n.text("实际", "Actual"), systemImage: "minus")
                .foregroundStyle(AppTheme.accentCyan(for: colorScheme))
            Label(L10n.text("预测", "Forecast"), systemImage: "line.diagonal")
                .foregroundStyle(AppTheme.accentAmber(for: colorScheme))
            Label(L10n.text("可持续上限", "Sustainable limit"), systemImage: "ellipsis")
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
        }
        .font(.system(size: 9.5, weight: .bold, design: .rounded))
    }

    private func quotaTrendChart(_ insight: ProviderQuotaInsight) -> some View {
        let prediction = predictionPoints(insight)
        let sustainable = sustainablePoints(insight)
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let amber = AppTheme.accentAmber(for: colorScheme)

        return Chart {
            ForEach(insight.trendPoints) { point in
                AreaMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Used", point.usedPercent)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [cyan.opacity(0.28), cyan.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Used", point.usedPercent)
                )
                .foregroundStyle(cyan)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
            }
            ForEach(prediction) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Forecast", point.value)
                )
                .foregroundStyle(amber)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .interpolationMethod(.linear)
            }
            ForEach(sustainable) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Sustainable", point.value)
                )
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 4]))
                .interpolationMethod(.linear)
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine().foregroundStyle(AppTheme.insetBorder(for: colorScheme).opacity(0.55))
                AxisValueLabel {
                    if let value = value.as(Int.self) {
                        Text("\(value)%")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    }
                }
            }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
        .frame(height: 220)
        .accessibilityLabel(L10n.text("Antigravity 额度趋势图", "Antigravity quota trend chart"))
        .accessibilityValue(L10n.format(
            "Current used quota is %@.",
            zhHans: "当前已用额度为 %@。",
            UsageNumberFormatter.percent(insight.input.usedPercent, maximumFractionDigits: 1)
        ))
    }

    private func trendCollectingPlaceholder(_ insight: ProviderQuotaInsight) -> some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let sampleCount = insight.trendPoints.count
        let targetCount = 4
        let progress = min(Double(sampleCount) / Double(targetCount), 1.0)

        return HStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(cyan.opacity(colorScheme == .dark ? 0.2 : 0.12), lineWidth: 2)
                    .frame(width: 52, height: 52)
                Circle()
                    .stroke(
                        cyan,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [4, 6])
                    )
                    .frame(width: 44, height: 44)
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(cyan)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("正在积累趋势数据", "Collecting trend data"))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                Text(L10n.format(
                    "%d samples collected. The chart appears after more refreshes.",
                    zhHans: "已收集 %d 个样本，继续刷新后会自动呈现完整趋势图。",
                    sampleCount
                ))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))

                // 样本积累微进度条
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(L10n.format("Sample Progress: %d/%d", zhHans: "采样进度：%d/%d", sampleCount, targetCount))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 9, weight: .heavy, design: .monospaced))
                            .foregroundStyle(cyan)
                    }
                    AntigravityFlowProgressBar(value: progress, tint: cyan)
                }
                .frame(maxWidth: 240)
                .padding(.top, 2)
            }
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 模型余量卡片
    private func modelAvailabilityCard(_ quota: AntigravityQuotaSnapshot) -> some View {
        let models = quota.aggregatedModels
        let visible = showsAllModels ? models : Array(models.prefix(6))
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                CyberSectionHeader(title: L10n.text("模型余量", "Model Availability"), icon: "list.bullet.rectangle")
                Spacer()
                Text(L10n.format("%d model groups", zhHans: "%d 个模型组", models.count))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }
            CyberDivider()

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], spacing: 10) {
                ForEach(visible) { model in
                    modelRow(model)
                }
            }

            if models.count > 6 {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        showsAllModels.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(
                            showsAllModels
                                ? L10n.text("收起模型", "Show fewer models")
                                : L10n.format("Show all %d model groups", zhHans: "展开全部 %d 个模型组", models.count)
                        )
                        Image(systemName: showsAllModels ? "chevron.up" : "chevron.down")
                    }
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.accentCyan(for: colorScheme))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .cyberCard(cornerRadius: 18, padding: 20)
    }

    private func modelRow(_ model: AntigravityQuotaSnapshot.AggregatedModel) -> some View {
        let tint = remainingTint(model.remainingPercent)
        let isDark = colorScheme == .dark
        return HStack(spacing: 10) {
            Circle()
                .fill(AppTheme.colorForModel(model.displayName, scheme: colorScheme))
                .frame(width: 8, height: 8)

            Text(model.displayName)
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .lineLimit(1)

            if model.modelCount > 1 {
                Text("×\(model.modelCount)")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(AppTheme.insetSurface(for: colorScheme), in: Capsule())
            }

            Spacer()

            if let reset = model.resetAt {
                Text(UsageNumberFormatter.relativeTimeString(from: reset))
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }

            Text(UsageNumberFormatter.percent(model.remainingPercent, maximumFractionDigits: 0))
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(tint.opacity(isDark ? 0.16 : 0.10), in: Capsule())
        }
        .padding(10)
        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var quotaEmptyState: some View {
        VStack(spacing: 12) {
            if state.isRefreshingAntigravityQuota || state.antigravityQuotaStatus == .loading {
                ProgressView().controlSize(.small)
                Text(L10n.text("正在同步 Antigravity 额度…", "Syncing Antigravity quota..."))
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(AppTheme.accentAmber(for: colorScheme))
                Text(state.antigravityQuotaErrorText ?? L10n.text(
                    "尚未读取到 Antigravity 额度",
                    "Antigravity quota is not available yet"
                ))
            }
        }
        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
        .frame(maxWidth: .infinity, minHeight: 160)
        .cyberCard(cornerRadius: 18, padding: 22)
    }

    private var syncCaption: String {
        let attempt = state.antigravitySyncState.lastAttemptAt
        let success = state.antigravitySyncState.lastSuccessAt ?? state.latestAntigravityQuota?.capturedAt
        let next = state.antigravitySyncState.cooldownUntil
            ?? state.antigravitySyncState.nextAttemptAt

            ?? success?.addingTimeInterval(TimeInterval(state.antigravityRefreshIntervalSeconds))
        let attemptText = attempt.map { UsageNumberFormatter.relativeTimeString(from: $0) }
            ?? L10n.text("尚未尝试", "No attempt yet")
        let successText = success.map { UsageNumberFormatter.relativeTimeString(from: $0) }
            ?? L10n.text("尚未成功", "No successful sync")
        guard let next else {
            return L10n.format(
                "Attempt %@ · Success %@",
                zhHans: "尝试 %@ · 成功 %@",
                attemptText,
                successText
            )
        }
        if state.antigravitySyncState.cooldownUntil != nil {
            return L10n.format(
                "Attempt %@ · Success %@ · Retry %@",
                zhHans: "尝试 %@ · 成功 %@ · %@后重试",
                attemptText,
                successText,
                UsageNumberFormatter.relativeTimeString(from: next)
            )
        }
        return L10n.format(
            "Attempt %@ · Success %@ · Next %@",
            zhHans: "尝试 %@ · 成功 %@ · 下次 %@",
            attemptText,
            successText,
            UsageNumberFormatter.relativeTimeString(from: next)
        )
    }

    private func normalizeSelection() {
        let ids = Set(state.antigravityQuotaInsights.map(\.id))
        if selectedInsightID == nil || !ids.contains(selectedInsightID!) {
            selectedInsightID = state.primaryAntigravityQuotaInsight?.id
        }
    }

    private func rateText(_ insight: ProviderQuotaInsight) -> String {
        guard insight.hasUsableForecast else { return L10n.text("正在积累", "Collecting") }
        return String(format: "%.2f %@", insight.burnRateForDisplay, insight.rateUnitTitle)
    }

    private func sustainablePaceCaption(_ insight: ProviderQuotaInsight) -> String {
        guard insight.input.resetAt != nil else { return L10n.text("重置时间未知", "Reset time unknown") }
        return L10n.format(
            "Sustainable %.2f %@",
            zhHans: "可持续 %.2f %@",
            insight.sustainableRateForDisplay,
            insight.rateUnitTitle
        )
    }

    private func forecastValue(_ insight: ProviderQuotaInsight) -> String {
        guard insight.hasUsableForecast else { return L10n.text("正在积累", "Collecting") }
        if insight.risk == .critical, let date = insight.forecast.estimatedExhaustionDate {
            return L10n.format(
                "Runs out %@",
                zhHans: "%@耗尽",
                UsageNumberFormatter.relativeTimeString(from: date)
            )
        }
        return projectedRemainingText(insight)
    }

    private func projectedRemainingText(_ insight: ProviderQuotaInsight) -> String {
        guard insight.hasUsableForecast,
              let remaining = insight.forecast.projectedRemainingAtReset else {
            return L10n.text("正在积累", "Collecting")
        }
        return L10n.format(
            "%@ remaining",
            zhHans: "剩余 %@",
            UsageNumberFormatter.percent(remaining, maximumFractionDigits: 0)
        )
    }

    private func predictionPoints(_ insight: ProviderQuotaInsight) -> [QuotaChartProjectionPoint] {
        guard insight.hasUsableForecast else { return [] }
        let start = max(insight.input.capturedAt, insight.trendPoints.last?.timestamp ?? insight.input.capturedAt)
        if insight.risk == .critical, let exhaustion = insight.forecast.estimatedExhaustionDate, exhaustion > start {
            return [
                QuotaChartProjectionPoint(kind: "forecast", date: start, value: insight.input.usedPercent),
                QuotaChartProjectionPoint(kind: "forecast", date: exhaustion, value: 100)
            ]
        }
        guard let reset = insight.input.resetAt,
              reset > start,
              let remaining = insight.forecast.projectedRemainingAtReset else { return [] }
        return [
            QuotaChartProjectionPoint(kind: "forecast", date: start, value: insight.input.usedPercent),
            QuotaChartProjectionPoint(kind: "forecast", date: reset, value: 100 - remaining)
        ]
    }

    private func sustainablePoints(_ insight: ProviderQuotaInsight) -> [QuotaChartProjectionPoint] {
        guard let reset = insight.input.resetAt, reset > insight.input.capturedAt else { return [] }
        return [
            QuotaChartProjectionPoint(kind: "sustainable", date: insight.input.capturedAt, value: insight.input.usedPercent),
            QuotaChartProjectionPoint(kind: "sustainable", date: reset, value: 100)
        ]
    }

    private func heroStatusTitle(_ insight: ProviderQuotaInsight?) -> String {
        guard let insight else { return state.antigravityDataFreshness.localizedTitle }
        if insight.freshness == .stale { return insight.freshness.localizedTitle }
        return insight.risk.localizedTitle
    }

    private func heroStatusIcon(_ insight: ProviderQuotaInsight?) -> String {
        guard let insight else { return state.antigravityDataFreshness.symbolName }
        if insight.freshness == .stale { return insight.freshness.symbolName }
        switch insight.risk {
        case .critical: return "exclamationmark.triangle.fill"
        case .warning: return "speedometer"
        case .onTrack: return "checkmark.circle.fill"
        case .underPaced: return "leaf.fill"
        case .insufficientData: return "ellipsis.circle.fill"
        }
    }

    private func insightTint(_ insight: ProviderQuotaInsight?) -> Color {
        guard let insight else { return AppTheme.accentCyan(for: colorScheme) }
        if insight.freshness == .stale { return AppTheme.accentRose(for: colorScheme) }
        return forecastTint(insight)
    }

    private func forecastTint(_ insight: ProviderQuotaInsight) -> Color {
        switch insight.risk {
        case .critical: return AppTheme.accentRose(for: colorScheme)
        case .warning: return AppTheme.accentAmber(for: colorScheme)
        case .onTrack, .underPaced: return AppTheme.accentEmerald(for: colorScheme)
        case .insufficientData: return AppTheme.accentCyan(for: colorScheme)
        }
    }

    private func freshnessTint(_ freshness: ProviderDataFreshness) -> Color {
        switch freshness {
        case .fresh: return AppTheme.accentEmerald(for: colorScheme)
        case .delayed: return AppTheme.accentAmber(for: colorScheme)
        case .stale: return AppTheme.accentRose(for: colorScheme)
        case .unknown: return AppTheme.accentCyan(for: colorScheme)
        }
    }

    private func recommendationTint(_ severity: QuotaRecommendationSeverity) -> Color {
        switch severity {
        case .healthy: return AppTheme.accentEmerald(for: colorScheme)
        case .information: return AppTheme.accentCyan(for: colorScheme)
        case .warning: return AppTheme.accentAmber(for: colorScheme)
        case .critical: return AppTheme.accentRose(for: colorScheme)
        }
    }

    private func remainingTint(_ remaining: Double) -> Color {
        if remaining <= 15 { return AppTheme.accentRose(for: colorScheme) }
        if remaining <= 35 { return AppTheme.accentAmber(for: colorScheme) }
        return AppTheme.accentEmerald(for: colorScheme)
    }
}
private struct QuotaChartProjectionPoint: Identifiable {
    let kind: String
    let date: Date
    let value: Double

    var id: String { "\(kind)|\(date.timeIntervalSince1970)" }
}

struct AntigravityActivityAnalyticsView: View {
    @ObservedObject var state: AppState
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedDays = 7
    @State private var selectedProfile: AntigravityStateProfile? = nil

    private var availableProfiles: [AntigravityStateProfile] {
        state.antigravityActivityProfiles
    }

    private var displayedActivity: AntigravityActivitySnapshot? {
        state.antigravityActivitySnapshot(for: selectedProfile)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                activityHeader
                if let activity = displayedActivity {
                    activitySummary(activity)
                    if activity.metrics(days: selectedDays).taskCount > 0 {
                        activityChart(activity)
                    } else {
                        noRecentActivity(activity)
                    }
                    projectCard(activity)
                } else {
                    activityUnavailable
                }
            }
            .padding(24)
        }
        .task { await env.refreshProviderQuotaInsights() }
        .onChange(of: availableProfiles) { _, profiles in
            if let selectedProfile, !profiles.contains(selectedProfile) {
                self.selectedProfile = nil
            }
        }
    }

    private var activityHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ToolAppIcon(tool: .antigravity, size: 28)
                    .frame(width: 42, height: 42)
                    .background(AppTheme.accentCyan(for: colorScheme).opacity(colorScheme == .dark ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("Antigravity 本机活动", "Antigravity Local Activity"))
                        .font(.system(size: 18, weight: .black, design: .rounded))
                    if let activity = displayedActivity {
                        Text(activity.latestActivityAt.map {
                            L10n.format(
                                "Last activity %@",
                                zhHans: "最后活动 %@",
                                UsageNumberFormatter.relativeTimeString(from: $0)
                            )
                        } ?? L10n.text("尚无活动记录", "No activity recorded yet"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    }
                }
                Spacer()
                Picker("", selection: $selectedDays) {
                    Text(L10n.text("7 天", "7 Days")).tag(7)
                    Text(L10n.text("30 天", "30 Days")).tag(30)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .accessibilityLabel(L10n.text("活动时间范围", "Activity time range"))
            }

            HStack(spacing: 10) {
                if availableProfiles.count > 1 {
                    Picker("", selection: $selectedProfile) {
                        Text(L10n.format(
                            "All sources (%d)",
                            zhHans: "全部来源（%d）",
                            availableProfiles.count
                        ))
                        .tag(nil as AntigravityStateProfile?)
                        ForEach(availableProfiles, id: \.self) { profile in
                            Text(profile.displayName).tag(profile as AntigravityStateProfile?)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 390)
                    .accessibilityLabel(L10n.text("活动来源", "Activity source"))
                } else if let profile = availableProfiles.first {
                    Label(profile.displayName, systemImage: "externaldrive.fill")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.accentCyan(for: colorScheme))
                }

                Spacer()

                if let activity = displayedActivity {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(L10n.format(
                            "Scanned %@",
                            zhHans: "%@完成扫描",
                            UsageNumberFormatter.relativeTimeString(from: activity.capturedAt)
                        ))
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }
            }
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    private func activitySummary(_ activity: AntigravityActivitySnapshot) -> some View {
        let metrics = activity.metrics(days: selectedDays)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            activityMetric(
                title: L10n.text("任务数", "Tasks"),
                value: "\(metrics.taskCount)",
                caption: changeCaption(activity),
                icon: changeIcon(activity),
                tint: changeTint(activity)
            )
            activityMetric(
                title: L10n.text("活跃天数", "Active Days"),
                value: "\(metrics.activeDays)",
                caption: L10n.format("of %d days", zhHans: "共 %d 天", selectedDays),
                icon: "calendar",
                tint: AppTheme.accentEmerald(for: colorScheme)
            )
            activityMetric(
                title: L10n.text("操作步骤", "Steps"),
                value: UsageNumberFormatter.compactTokenCount(metrics.stepCount),
                caption: L10n.text("当前周期合计", "Total for this period"),
                icon: "point.3.connected.trianglepath.dotted",
                tint: AppTheme.accentAmber(for: colorScheme)
            )
            activityMetric(
                title: L10n.text("平均每任务步骤", "Steps per Task"),
                value: String(format: "%.1f", metrics.averageStepsPerTask),
                caption: L10n.text("任务复杂度参考", "A task complexity indicator"),
                icon: "divide.circle",
                tint: AppTheme.accentCyan(for: colorScheme)
            )
            activityMetric(
                title: L10n.text("每日活跃任务", "Tasks per Active Day"),
                value: String(format: "%.1f", metrics.tasksPerActiveDay),
                caption: L10n.text("仅计算有活动的日期", "Counts active days only"),
                icon: "chart.bar.fill",
                tint: AppTheme.accentPurple(for: colorScheme)
            )
        }
    }

    private func activityMetric(
        title: String,
        value: String,
        caption: String,
        icon: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            Text(value)
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
            Text(caption)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .cyberCard(cornerRadius: 14, padding: 14)
    }

    private func activityChart(_ activity: AntigravityActivitySnapshot) -> some View {
        let points = activity.dailyPoints(days: selectedDays)
        return VStack(alignment: .leading, spacing: 12) {
            CyberSectionHeader(title: L10n.text("每日任务趋势", "Daily Task Trend"), icon: "chart.bar.fill")
            Text(L10n.format("Last %d days · tasks per day", zhHans: "最近 %d 天 · 每日任务数", selectedDays))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            CyberDivider()
            Chart(points) { day in
                BarMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Tasks", day.taskCount)
                )
                .foregroundStyle(AppTheme.accentCyan(for: colorScheme))
                .cornerRadius(3)
                .annotation(position: .top, spacing: 2) {
                    if day.taskCount > 0 {
                        Text("\(day.taskCount)")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    }
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: selectedDays == 7 ? 7 : 8)) }
            .frame(height: 190)
            .accessibilityLabel(L10n.text("Antigravity 每日任务趋势图", "Antigravity daily task trend chart"))
            .accessibilityValue(L10n.format(
                "%d tasks across %d active days",
                zhHans: "%d 个任务，分布在 %d 个活跃日",
                activity.metrics(days: selectedDays).taskCount,
                activity.metrics(days: selectedDays).activeDays
            ))
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    private func noRecentActivity(_ activity: AntigravityActivitySnapshot) -> some View {
        VStack(spacing: 9) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 24))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            Text(selectedProfile.map { profile in
                L10n.format(
                    "%@ · No activity in the last %d days",
                    zhHans: "%@ · 最近 %d 天没有活动",
                    profile.displayName,
                    selectedDays
                )
            } ?? L10n.format(
                "No Antigravity activity in the last %d days",
                zhHans: "最近 %d 天没有 Antigravity 活动",
                selectedDays
            ))
            .font(.system(size: 12, weight: .bold, design: .rounded))
            if let latest = activity.latestActivityAt {
                Text(L10n.format(
                    "Last activity %@",
                    zhHans: "最后活动 %@",
                    UsageNumberFormatter.relativeTimeString(from: latest)
                ))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 130)
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    private func projectCard(_ activity: AntigravityActivitySnapshot) -> some View {
        let projects = activity.projectCounts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        return VStack(alignment: .leading, spacing: 12) {
            CyberSectionHeader(title: L10n.text("最近 30 天项目活动", "Project Activity · 30 Days"), icon: "folder.fill")
            CyberDivider()
            if projects.isEmpty {
                Text(L10n.text("暂无可统计的项目活动", "No project activity is available"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            } else {
                ForEach(Array(projects.prefix(8)), id: \.key) { project, count in
                    HStack(spacing: 10) {
                        Text(project)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                        Spacer()
                        Text(L10n.format("%d tasks", zhHans: "%d 个任务", count))
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(AppTheme.accentCyan(for: colorScheme))
                    }
                }
            }
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    private var activityUnavailable: some View {
        VStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text(L10n.text("尚未读取到 Antigravity 本机活动", "Antigravity local activity is not available yet"))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    private func changeCaption(_ activity: AntigravityActivitySnapshot) -> String {
        guard let change = activity.taskChangePercent(days: selectedDays) else {
            return L10n.text("上一周期为 0", "No tasks in the previous period")
        }
        if abs(change) < 0.5 { return L10n.text("与上一周期持平", "Unchanged from previous period") }
        return change > 0
            ? L10n.format("Up %.0f%% vs previous period", zhHans: "比上一周期增加 %.0f%%", change)
            : L10n.format("Down %.0f%% vs previous period", zhHans: "比上一周期减少 %.0f%%", abs(change))
    }

    private func changeIcon(_ activity: AntigravityActivitySnapshot) -> String {
        guard let change = activity.taskChangePercent(days: selectedDays) else { return "sparkles" }
        if change > 0.5 { return "arrow.up.right" }
        if change < -0.5 { return "arrow.down.right" }
        return "equal"
    }

    private func changeTint(_ activity: AntigravityActivitySnapshot) -> Color {
        guard let change = activity.taskChangePercent(days: selectedDays) else {
            return AppTheme.accentCyan(for: colorScheme)
        }
        if change > 0.5 { return AppTheme.accentCyan(for: colorScheme) }
        if change < -0.5 { return AppTheme.accentAmber(for: colorScheme) }
        return AppTheme.accentEmerald(for: colorScheme)
    }
}

// MARK: - 科技感流光进度条
public struct AntigravityFlowProgressBar: View {
    public let value: Double // 0.0 ~ 1.0
    public let tint: Color
    public var height: CGFloat = 7
    @Environment(\.colorScheme) private var colorScheme

    public init(value: Double, tint: Color, height: CGFloat = 7) {
        self.value = value
        self.tint = tint
        self.height = height
    }

    public var body: some View {
        let isDark = colorScheme == .dark
        let clamped = min(max(value, 0.0), 1.0)
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                // 背景槽道
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                    .frame(height: height)

                // 渐变进度填充
                if clamped > 0.005 {
                    RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    tint.opacity(0.80),
                                    tint
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(height, width * clamped), height: height)
                        .shadow(color: tint.opacity(isDark ? 0.35 : 0.20), radius: 3, x: 0, y: 1)
                }
            }
        }
        .frame(height: height)
    }
}
