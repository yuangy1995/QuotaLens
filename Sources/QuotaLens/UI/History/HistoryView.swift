// QuotaLens 按日历史分析状态中枢与视图 (HistoryView)

import SwiftUI
import Combine

@MainActor
public final class HistoryStore: ObservableObject {
    @Published public var days: [DayUsageSummaryDTO] = []
    @Published public var selectedDayKey: LocalDayKey? = nil {
        didSet {
            guard oldValue != selectedDayKey else { return }
            Task { await loadSelectedDayDetail() }
        }
    }
    @Published public var selectedDayDetail: DayDetailDTO? = nil
    @Published public var selectedRangeDays: Int = 30 {
        didSet { Task { await loadHistory() } }
    }
    public let providerFilter: UsageProviderFilter
    @Published public var isLoading: Bool = false
    @Published public var isLoadingDetail: Bool = false
    @Published public var isLoadingMoreEvents: Bool = false
    @Published public var errorMessage: String? = nil

    private let facade: UsageQueryFacade
    private let eventPageSize = 500
    private var historyGeneration = 0
    private var detailGeneration = 0

    public init(facade: UsageQueryFacade, providerFilter: UsageProviderFilter) {
        self.facade = facade
        self.providerFilter = providerFilter
    }

    public func loadHistory() async {
        historyGeneration += 1
        detailGeneration += 1
        let generation = historyGeneration
        let rangeDays = selectedRangeDays
        let filter = providerFilter
        isLoading = true
        errorMessage = nil
        defer {
            if generation == historyGeneration {
                isLoading = false
            }
        }
        do {
            let list = try await facade.getHistoryDays(
                daysCount: rangeDays,
                providerFilter: filter
            )
            guard generation == historyGeneration else { return }
            self.days = list
            if selectedDayKey == nil || !list.contains(where: { $0.dayKey == selectedDayKey }) {
                self.selectedDayKey = list.first?.dayKey
            } else {
                await loadSelectedDayDetail()
            }
        } catch {
            guard generation == historyGeneration else { return }
            self.errorMessage = Self.userFacingError(error)
        }
    }

    public var selectedDaySummary: DayUsageSummaryDTO? {
        guard let key = selectedDayKey else { return days.first }
        return days.first(where: { $0.dayKey == key })
    }

    public func loadSelectedDayDetail() async {
        detailGeneration += 1
        let generation = detailGeneration
        guard let dayKey = selectedDayKey else {
            selectedDayDetail = nil
            return
        }
        let filter = providerFilter
        isLoadingDetail = true
        defer {
            if generation == detailGeneration {
                isLoadingDetail = false
            }
        }
        do {
            let detail = try await facade.getDayDetail(
                dayKey: dayKey,
                eventLimit: eventPageSize,
                providerFilter: filter
            )
            guard generation == detailGeneration,
                  selectedDayKey == dayKey,
                  providerFilter == filter else { return }
            selectedDayDetail = detail
        } catch {
            guard generation == detailGeneration else { return }
            errorMessage = Self.userFacingError(error)
        }
    }

    public func loadMoreSelectedDayEvents() async {
        guard !isLoadingDetail,
              !isLoadingMoreEvents,
              let dayKey = selectedDayKey,
              let current = selectedDayDetail,
              current.hasMoreEvents,
              let cursor = current.nextEventCursor else { return }
        isLoadingMoreEvents = true
        let filter = providerFilter
        defer { isLoadingMoreEvents = false }
        do {
            let page = try await facade.getDayDetail(
                dayKey: dayKey,
                eventLimit: eventPageSize,
                eventCursor: cursor,
                providerFilter: filter
            )
            guard selectedDayKey == dayKey,
                  providerFilter == filter,
                  let existing = selectedDayDetail else { return }
            selectedDayDetail = Self.mergeDayDetail(existing: existing, page: page)
        } catch {
            errorMessage = Self.userFacingError(error)
        }
    }

    private static func userFacingError(_ error: Error) -> String {
        if let description = (error as? SessionDeletionError)?.errorDescription {
            return description
        }
        return L10n.text(
            "暂时无法读取本地历史记录，请稍后重试。",
            "Local history could not be loaded right now. Try again later."
        )
    }

    private static func mergeDayDetail(existing: DayDetailDTO, page: DayDetailDTO) -> DayDetailDTO {
        let pageBySession = Dictionary(uniqueKeysWithValues: page.sessions.map { ($0.session.sessionId, $0) })
        var seenEvents = Set(existing.sessions.flatMap(\.events).map(\.eventId))
        let mergedSessions = existing.sessions.map { slice -> DaySessionSliceDTO in
            let newEvents = (pageBySession[slice.session.sessionId]?.events ?? [])
                .filter { seenEvents.insert($0.eventId).inserted }
            return DaySessionSliceDTO(
                session: pageBySession[slice.session.sessionId]?.session ?? slice.session,
                dayTokens: slice.dayTokens,
                dayCost: slice.dayCost,
                dayEventCount: slice.dayEventCount,
                events: slice.events + newEvents
            )
        }
        return DayDetailDTO(
            summary: page.summary,
            sessions: mergedSessions,
            totalEventCount: page.totalEventCount,
            loadedEventCount: mergedSessions.reduce(0) { $0 + $1.events.count },
            hasMoreEvents: page.hasMoreEvents,
            nextEventCursor: page.nextEventCursor
        )
    }
}

struct ProviderHistoryView: View {
    @StateObject private var store: HistoryStore
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.colorScheme) var colorScheme

    init(facade: UsageQueryFacade, providerFilter: UsageProviderFilter) {
        _store = StateObject(
            wrappedValue: HistoryStore(
                facade: facade,
                providerFilter: providerFilter
            )
        )
    }

    public var body: some View {
        HSplitView {
            // 左栏：日期时间线选择列表
            historySidebar
                .frame(minWidth: 260, idealWidth: 280, maxWidth: 340)

            // 右栏：单日用量剖析
            dayDetailArea
                .frame(minWidth: 460, maxWidth: .infinity)
        }
        .task {
            guard !isRelevantScanActive else { return }
            await store.loadHistory()
        }
        .onChange(of: env.scanCoordinator.isScanning) { _, isScanning in
            guard store.providerFilter == .codex, !isScanning else { return }
            Task {
                await store.loadHistory()
            }
        }
        .onChange(of: env.claudeScanCoordinator.isScanning) { _, isScanning in
            guard store.providerFilter == .claude, !isScanning else { return }
            Task { await store.loadHistory() }
        }
    }

    private var isRelevantScanActive: Bool {
        switch store.providerFilter {
        case .codex: return env.scanCoordinator.isScanning
        case .claude: return env.claudeScanCoordinator.isScanning
        case .all: return env.scanCoordinator.isScanning || env.claudeScanCoordinator.isScanning
        }
    }

    // MARK: - 左栏：按日聚合列表
    private var historySidebar: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let isDark = colorScheme == .dark

        return VStack(spacing: 0) {
            // 范围选择芯片
            HStack(spacing: 6) {
                ForEach([7, 30, 90, 365], id: \.self) { rangeDays in
                    let isSelected = store.selectedRangeDays == rangeDays
                    Button(action: { store.selectedRangeDays = rangeDays }) {
                        Text("\(rangeDays)D")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                isSelected ? cyan.opacity(isDark ? 0.24 : 0.18) : (isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)),
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(isSelected ? cyan.opacity(0.7) : (isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)), lineWidth: 0.8)
                            )
                            .foregroundStyle(isSelected ? cyan : AppTheme.textPrimary(for: colorScheme))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(10)

            CyberDivider()

            if store.isLoading && store.days.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(L10n.text("正在汇总按日数据…", "Summarizing history..."))
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.days.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 24))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme).opacity(0.6))
                    Text(L10n.text("该时间段暂无用量", "No usage in this period"))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(store.days) { day in
                            let isSelected = store.selectedDayKey == day.dayKey
                            DaySidebarRow(
                                day: day,
                                isSelected: isSelected,
                                colorScheme: colorScheme,
                                onSelect: { store.selectedDayKey = day.dayKey }
                            )
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(AppTheme.sidebarGradient(for: colorScheme))
    }

    // MARK: - 右栏：单日用量明细
    private var dayDetailArea: some View {
        Group {
            if let day = store.selectedDaySummary {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        // 1. 日度全息指标卡
                        dayHeaderCard(day: day)

                        // 2. Token 与价值构成
                        dayBreakdownCard(day: day)

                        // 3. 当日模型占比
                        if !day.modelSummaries.isEmpty {
                            dayModelDistributionCard(day: day)
                        }

                        if store.isLoadingDetail {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.vertical, 8)
                        } else if let detail = store.selectedDayDetail, !detail.sessions.isEmpty {
                            daySessionTimelineCard(detail: detail)
                        }
                    }
                    .padding(18)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.system(size: 32))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme).opacity(0.5))
                    Text(L10n.text("请在左侧选择日期", "Select a date on the left"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func dayHeaderCard(day: DayUsageSummaryDTO) -> some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)
        let purple = AppTheme.accentPurple(for: colorScheme)
        let amber = AppTheme.accentAmber(for: colorScheme)

        let totalTok = day.tokens.canonicalTotalTokens
        let hitRate = day.tokens.cacheHitRatio

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(day.dayKey.yyyyMMdd)
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                    Text(L10n.format("%d sessions active", zhHans: "共 %d 个会话活跃", day.sessionCount))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }
                Spacer()
            }

            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    MetricHUDTile(
                        title: L10n.text("当日消耗 Token", "Day Tokens"),
                        value: UsageNumberFormatter.formattedTokenCount(totalTok),
                        caption: UsageNumberFormatter.compactTokenCount(totalTok),
                        icon: "sparkles",
                        accentColor: cyan
                    )

                    MetricHUDTile(
                        title: L10n.text("当日 API 等价价值", "Daily API Equivalent Value"),
                        value: UsageNumberFormatter.currencyUSD(day.estimatedCost),
                        caption: dayPricingCaption(day),
                        icon: "dollarsign.circle.fill",
                        accentColor: emerald
                    )
                }

                GridRow {
                    MetricHUDTile(
                        title: L10n.text("缓存命中率", "Cache Hit Rate"),
                        value: UsageNumberFormatter.percent(hitRate * 100.0, maximumFractionDigits: 1),
                        caption: "\(UsageNumberFormatter.compactTokenCount(day.tokens.cachedInputTokens)) cached",
                        icon: "bolt.badge.clock.fill",
                        accentColor: purple
                    )

                    MetricHUDTile(
                        title: L10n.text("交互调用次数", "Calls Count"),
                        value: "\(day.eventCount)",
                        caption: L10n.format("%d events", zhHans: "%d 次调用", day.eventCount),
                        icon: "bubble.left.fill",
                        accentColor: amber
                    )
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

    private func dayBreakdownCard(day: DayUsageSummaryDTO) -> some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let blue = AppTheme.accentBlue(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)
        let purple = AppTheme.accentPurple(for: colorScheme)
        let amber = AppTheme.accentAmber(for: colorScheme)

        let tokens = day.tokens
        let uncached = Double(tokens.uncachedInputTokens)
        let cached = Double(tokens.cachedInputTokens)
        let cacheWrite = Double(tokens.cacheWriteInputTokens)
        let output = Double(max(0, tokens.outputTokens - tokens.reasoningOutputTokens))
        let reasoning = Double(tokens.reasoningOutputTokens)
        let total = max(1.0, uncached + cached + cacheWrite + output + reasoning)

        return VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("当日 Token 细分", "Day Token Breakdown"))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

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

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 108), spacing: 8, alignment: .leading)],
                alignment: .leading,
                spacing: 6
            ) {
                LegendItem(color: cyan, title: L10n.text("全新输入", "Uncached"), value: UsageNumberFormatter.compactTokenCount(tokens.uncachedInputTokens))
                LegendItem(color: blue, title: L10n.text("命中缓存", "Cached"), value: UsageNumberFormatter.compactTokenCount(tokens.cachedInputTokens))
                LegendItem(color: amber, title: L10n.text("缓存写入", "Cache Write"), value: UsageNumberFormatter.compactTokenCount(tokens.cacheWriteInputTokens))
                LegendItem(color: emerald, title: L10n.text("常规生成", "Output"), value: UsageNumberFormatter.compactTokenCount(max(0, tokens.outputTokens - tokens.reasoningOutputTokens)))
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

    private func dayModelDistributionCard(day: DayUsageSummaryDTO) -> some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)

        return VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("当日模型占比", "Day Model Breakdown"))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

            VStack(spacing: 4) {
                ForEach(day.modelSummaries) { model in
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

    private func daySessionTimelineCard(detail: DayDetailDTO) -> some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("当日会话与事件时间线", "Day Sessions & Event Timeline"))
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

            if detail.sessions.isEmpty {
                Text(L10n.text("当日暂无详细会话与调用记录", "No session or activity details for this day"))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(detail.sessions) { slice in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(slice.session.displayTitle)
                                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                                        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                                        .lineLimit(1)
                                    Text(L10n.format("%d events", zhHans: "%d 条事件", slice.dayEventCount))
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                                }
                                Spacer()
                                Text(UsageNumberFormatter.compactTokenCount(slice.dayTokens.canonicalTotalTokens))
                                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(cyan)
                                Text(UsageNumberFormatter.currencyUSD(slice.dayCost))
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(emerald)
                            }

                            ForEach(slice.events) { event in
                                HStack(spacing: 8) {
                                    Text(event.timestamp.formatted(date: .omitted, time: .standard))
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                                        .frame(width: 72, alignment: .leading)
                                    Text(event.modelCanonical)
                                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(cyan)
                                        .lineLimit(1)

                                    if let effort = event.reasoningEffort, !effort.isEmpty {
                                        ReasoningEffortBadge(effort: effort)
                                    }

                                    Spacer()
                                    Text(UsageNumberFormatter.compactTokenCount(event.tokens.canonicalTotalTokens))
                                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                                    Text(event.pricingStatus.isPriced
                                        ? UsageNumberFormatter.currencyUSD(event.estimatedCost)
                                        : L10n.text("未计价", "Unpriced"))
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(event.pricingStatus.isPriced ? emerald : AppTheme.accentAmber(for: colorScheme))
                                        .frame(width: 66, alignment: .trailing)
                                        .help(event.pricingStatus.localizedDescription)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .padding(10)
                        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.7)
                        )
                    }
                }

                if detail.hasMoreEvents {
                    Button {
                        Task { await store.loadMoreSelectedDayEvents() }
                    } label: {
                        HStack(spacing: 6) {
                            if store.isLoadingMoreEvents {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            Text(store.isLoadingMoreEvents
                                ? L10n.text("正在加载…", "Loading...")
                                : L10n.text("加载更多事件", "Load More Events"))
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .foregroundStyle(cyan)
                        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isLoadingMoreEvents)
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

    private func dayPricingCaption(_ day: DayUsageSummaryDTO) -> String {
        if !day.unpricedReasonCounts.isEmpty {
            return L10n.text("部分记录未计价", "Some records are unpriced")
        }
        if day.legacyAggregateCost.rawValue > 0 || day.legacyAggregateTokens > 0 {
            return L10n.text("含历史记录", "Includes historical records")
        }
        return L10n.text("按 API 价格折算", "Converted at API rates")
    }
}

// MARK: - 日期侧栏行组件
private struct DaySidebarRow: View {
    let day: DayUsageSummaryDTO
    let isSelected: Bool
    let colorScheme: ColorScheme
    let onSelect: () -> Void

    var body: some View {
        let isDark = colorScheme == .dark
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)

        Button(action: onSelect) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(day.dayKey.yyyyMMdd)
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.white : AppTheme.textPrimary(for: colorScheme))

                    Text(L10n.format("%d sessions", zhHans: "%d 个会话", day.sessionCount))
                        .font(.system(size: 9.5, design: .rounded))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : AppTheme.textSecondary(for: colorScheme))
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(UsageNumberFormatter.compactTokenCount(day.tokens.canonicalTotalTokens))
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.white : AppTheme.textPrimary(for: colorScheme))

                    if day.estimatedCost.rawValue > 0 {
                        Text(UsageNumberFormatter.currencyUSD(day.estimatedCost))
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(isSelected ? Color.white : emerald)
                    }
                    if day.legacyAggregateCost.rawValue > 0 || day.legacyAggregateTokens > 0 {
                        Text(L10n.text("历史金额", "Historical"))
                            .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.85) : AppTheme.accentAmber(for: colorScheme))
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(LinearGradient(
                        colors: [cyan, AppTheme.accentBlue(for: colorScheme)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )) : AnyShapeStyle(isDark ? Color.white.opacity(0.03) : Color.black.opacity(0.02)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? cyan.opacity(0.6) : (isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }
}

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
                .help(caption)
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
