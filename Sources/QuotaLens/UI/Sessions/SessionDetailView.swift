// QuotaLens 会话详情、Token 构成与事件时间线视图 (SessionDetailView)

import SwiftUI
import AppKit

public struct SessionDetailView: View {
    let detail: CodexSessionDetailDTO
    let onBackToRoot: () -> Void
    let onSelectSubagent: (String) -> Void
    let onLoadMoreEvents: () -> Void
    let isLoadingMoreEvents: Bool
    @Environment(\.colorScheme) var colorScheme
    @State private var isCopiedId = false

    public init(
        detail: CodexSessionDetailDTO,
        onBackToRoot: @escaping () -> Void,
        onSelectSubagent: @escaping (String) -> Void,
        onLoadMoreEvents: @escaping () -> Void = {},
        isLoadingMoreEvents: Bool = false
    ) {
        self.detail = detail
        self.onBackToRoot = onBackToRoot
        self.onSelectSubagent = onSelectSubagent
        self.onLoadMoreEvents = onLoadMoreEvents
        self.isLoadingMoreEvents = isLoadingMoreEvents
    }

    public var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if detail.session.isSubagent {
                    HStack {
                        Button(action: onBackToRoot) {
                            Label(
                                L10n.text("返回主会话", "Back to Main Session"),
                                systemImage: "chevron.left"
                            )
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .foregroundStyle(AppTheme.accentCyan(for: colorScheme))
                            .background(
                                AppTheme.insetSurface(for: colorScheme),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("sessions.backToMainSession")

                        Spacer()
                    }
                }

                // 1. 顶部全息信息头
                sessionHeaderCard

                // 2. 四大核心指标卡
                kpiMetricsGrid

                // 3. Token 构成可视化条形图
                tokenCompositionCard

                // 4. 多模型占比汇总
                if !detail.modelSummaries.isEmpty {
                    modelDistributionCard
                }

                // 5. 子会话分身列表 (Subagents)
                if !detail.subagents.isEmpty {
                    subagentsSectionCard
                }

                // 6. 事件流时间线
                if !detail.recentEvents.isEmpty {
                    eventTimelineCard
                }
            }
            .padding(18)
        }
    }

    // MARK: - 1. 顶部全息信息头
    private var sessionHeaderCard: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let isDark = colorScheme == .dark

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(detail.session.displayTitle)
                            .font(.system(size: 16, weight: .black, design: .rounded))
                            .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                        if let project = detail.session.projectName {
                            Text(project)
                                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                                .foregroundStyle(cyan)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(cyan.opacity(isDark ? 0.16 : 0.12), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }

                    HStack(spacing: 6) {
                        Text("ID: \(detail.session.sessionId)")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))

                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(detail.session.sessionId, forType: .string)
                            isCopiedId = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { isCopiedId = false }
                        }) {
                            Image(systemName: isCopiedId ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 9))
                                .foregroundStyle(isCopiedId ? AppTheme.accentEmerald(for: colorScheme) : cyan)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                // 在 Finder 中定位源文件
                if !detail.sourcePath.isEmpty {
                    Button(action: {
                        let url = URL(fileURLWithPath: (detail.sourcePath as NSString).expandingTildeInPath)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 10))
                            Text(L10n.text("在 Finder 中显示", "Show in Finder"))
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(cyan.opacity(isDark ? 0.15 : 0.12), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(cyan.opacity(0.4), lineWidth: 0.8)
                        )
                        .foregroundStyle(cyan)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let cwd = detail.session.cwd, !cwd.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 9.5))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    Text(cwd)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(14)
        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
        )
    }

    // MARK: - 2. 核心指标 KPI
    private var kpiMetricsGrid: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)
        let purple = AppTheme.accentPurple(for: colorScheme)
        let amber = AppTheme.accentAmber(for: colorScheme)

        let totalTok = detail.session.tokens.canonicalTotalTokens
        let hitRate = detail.session.tokens.cacheHitRatio

        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                MetricHUDTile(
                    title: L10n.text("总消耗 Token", "Total Tokens"),
                    value: UsageNumberFormatter.formattedTokenCount(totalTok),
                    caption: UsageNumberFormatter.compactTokenCount(totalTok),
                    icon: "sparkles",
                    accentColor: cyan
                )

                MetricHUDTile(
                    title: L10n.text("API 等价价值 · Beta", "API Equivalent Value · Beta"),
                    value: UsageNumberFormatter.currencyUSD(detail.session.estimatedCost),
                    caption: detail.session.pricingStatus.isPriced
                        ? L10n.text("不是订阅账单金额", "Not a bill")
                        : detail.session.pricingStatus.localizedDescription,
                    icon: "dollarsign.circle.fill",
                    accentColor: emerald
                )
            }

            GridRow {
                MetricHUDTile(
                    title: L10n.text("缓存命中率", "Cache Hit Rate"),
                    value: UsageNumberFormatter.percent(hitRate * 100.0, maximumFractionDigits: 1),
                    caption: "\(UsageNumberFormatter.compactTokenCount(detail.session.tokens.cachedInputTokens)) cached",
                    icon: "bolt.badge.clock.fill",
                    accentColor: purple
                )

                MetricHUDTile(
                    title: L10n.text("交互事件总数", "Total Events"),
                    value: "\(detail.session.eventCount)",
                    caption: detail.subagents.isEmpty ? L10n.text("无子代理", "No subagents") : L10n.format("%d subagents", zhHans: "%d 个子代理", detail.subagents.count),
                    icon: "bubble.left.and.bubble.right.fill",
                    accentColor: amber
                )
            }
        }
    }

    // MARK: - 3. Token 构成条形图
    private var tokenCompositionCard: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let blue = AppTheme.accentBlue(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)
        let purple = AppTheme.accentPurple(for: colorScheme)
        let amber = AppTheme.accentAmber(for: colorScheme)

        let tokens = detail.session.tokens
        let uncached = Double(tokens.uncachedInputTokens)
        let cached = Double(tokens.cachedInputTokens)
        let cacheWrite = Double(tokens.cacheWriteInputTokens)
        let output = Double(max(0, tokens.outputTokens - tokens.reasoningOutputTokens))
        let reasoning = Double(tokens.reasoningOutputTokens)
        let total = max(1.0, uncached + cached + cacheWrite + output + reasoning)

        return VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Token 构成比例", "Token Breakdown"))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

            // 彩色堆叠条形图
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Rectangle().fill(cyan).frame(width: max(2, geo.size.width * CGFloat(uncached / total)))
                    Rectangle().fill(blue).frame(width: max(2, geo.size.width * CGFloat(cached / total)))
                    Rectangle().fill(amber).frame(width: max(2, geo.size.width * CGFloat(cacheWrite / total)))
                    Rectangle().fill(emerald).frame(width: max(2, geo.size.width * CGFloat(output / total)))
                    Rectangle().fill(purple).frame(width: max(2, geo.size.width * CGFloat(reasoning / total)))
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 10)

            // 图例与数值
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 108), spacing: 8, alignment: .leading)],
                alignment: .leading,
                spacing: 6
            ) {
                LegendItem(color: cyan, title: L10n.text("全新输入", "Uncached Input"), value: UsageNumberFormatter.compactTokenCount(tokens.uncachedInputTokens))
                LegendItem(color: blue, title: L10n.text("命中缓存", "Cached Input"), value: UsageNumberFormatter.compactTokenCount(tokens.cachedInputTokens))
                LegendItem(color: amber, title: L10n.text("缓存写入", "Cache Write"), value: UsageNumberFormatter.compactTokenCount(tokens.cacheWriteInputTokens))
                LegendItem(color: emerald, title: L10n.text("常规生成", "Standard Output"), value: UsageNumberFormatter.compactTokenCount(max(0, tokens.outputTokens - tokens.reasoningOutputTokens)))
                LegendItem(color: purple, title: L10n.text("深度推理", "Reasoning"), value: UsageNumberFormatter.compactTokenCount(tokens.reasoningOutputTokens))
            }
        }
        .padding(12)
        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
        )
    }

    // MARK: - 4. 模型分布汇总
    private var modelDistributionCard: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)

        return VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("模型使用构成", "Model Distribution"))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

            VStack(spacing: 4) {
                ForEach(detail.modelSummaries) { model in
                    HStack {
                        Text(model.modelCanonical)
                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(cyan)

                        Spacer()

                        Text(UsageNumberFormatter.formattedTokenCount(model.tokens.canonicalTotalTokens))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                        Text(UsageNumberFormatter.currencyUSD(model.estimatedCost))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(emerald)
                            .frame(width: 65, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                }
            }
        }
        .padding(12)
        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
        )
    }

    // MARK: - 5. 子会话分身卡片
    private var subagentsSectionCard: some View {
        let purple = AppTheme.accentPurple(for: colorScheme)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(purple)
                Text(L10n.format("子代理会话 (%d)", zhHans: "子代理会话 (%d)", detail.subagents.count))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
            }

            LazyVStack(spacing: 4) {
                ForEach(detail.subagents) { sub in
                    Button(action: { onSelectSubagent(sub.sessionId) }) {
                        HStack {
                            Text(sub.displayTitle)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                                .lineLimit(1)

                            Spacer()

                            Text(UsageNumberFormatter.compactTokenCount(sub.tokens.canonicalTotalTokens))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))

                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        }
                        .padding(8)
                        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
        )
    }

    // MARK: - 6. 事件流时间线
    private var eventTimelineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("事件明细时间线", "Event Timeline"))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                Spacer()

                Text(L10n.format(
                    "%d/%d loaded",
                    zhHans: "已加载 %d/%d",
                    detail.loadedEventCount,
                    detail.totalEventCount
                ))
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }

            LazyVStack(spacing: 4) {
                ForEach(detail.recentEvents) { event in
                    UsageEventRow(event: event, colorScheme: colorScheme)
                }
            }

            if detail.hasMoreEvents {
                Button(action: onLoadMoreEvents) {
                    HStack(spacing: 6) {
                        if isLoadingMoreEvents {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 11, weight: .bold))
                        }
                        Text(isLoadingMoreEvents
                            ? L10n.text("正在加载…", "Loading...")
                            : L10n.text("加载更多事件", "Load More Events"))
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .foregroundStyle(AppTheme.accentCyan(for: colorScheme))
                    .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isLoadingMoreEvents)
            }
        }
        .padding(12)
        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
        )
    }
}

// MARK: - 单条事件明细行
public struct UsageEventRow: View {
    public let event: CodexUsageEventDTO
    public let colorScheme: ColorScheme

    public init(event: CodexUsageEventDTO, colorScheme: ColorScheme) {
        self.event = event
        self.colorScheme = colorScheme
    }

    public var body: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)

        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("T\(event.turnIndex)")
                        .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                        .foregroundStyle(cyan)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(cyan.opacity(colorScheme == .dark ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 3))

                    Text(event.modelCanonical)
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                    if let tier = event.serviceTier, ServiceTierBadge.shouldDisplay(tier) {
                        ServiceTierBadge(tier: tier)
                    }

                    if let effort = event.reasoningEffort, !effort.isEmpty {
                        ReasoningEffortBadge(effort: effort)
                    }
                }

                Text(event.usageDerivation.localizedDescription)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(UsageNumberFormatter.formattedTokenCount(event.tokens.canonicalTotalTokens))
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                if event.estimatedCost.rawValue > 0 {
                    Text(UsageNumberFormatter.currencyUSD(event.estimatedCost))
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(emerald)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(colorScheme == .dark ? Color.white.opacity(0.02) : Color.black.opacity(0.015), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - 辅助微型指标卡
private struct MetricHUDTile: View {
    @Environment(\.colorScheme) var colorScheme
    let title: String
    let value: String
    let caption: String
    let icon: String
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(accentColor)
                Text(title)
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }

            Text(value)
                .font(.system(size: 15, weight: .black, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(caption)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
        )
    }
}

// MARK: - 图例微项
private struct LegendItem: View {
    @Environment(\.colorScheme) var colorScheme
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                Text(value)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
            }
        }
    }
}
