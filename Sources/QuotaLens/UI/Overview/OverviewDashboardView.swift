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
            LazyVStack(alignment: .leading, spacing: 18) {
                toolStatusGrid
                if !attentionItems.isEmpty {
                    attentionCard
                }
                resetTimelineCard
                usageComparisonCard
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
    }

    private var toolStatusGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
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
        return VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Image(systemName: descriptor.systemImage)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(colorScheme == .dark ? 0.16 : 0.11), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.displayName)
                        .font(.system(size: 15, weight: .black, design: .rounded))
                    Text(toolPlanText(descriptor.id))
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }

            ForEach(quotaRows(for: descriptor.id), id: \.title) { row in
                VStack(spacing: 5) {
                    HStack {
                        Text(row.title)
                        Spacer()
                        Text(row.value)
                            .foregroundStyle(row.tint)
                    }
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    ProgressView(value: row.progress)
                        .tint(row.tint)
                }
            }

            HStack {
                Label(toolSyncText(descriptor.id), systemImage: "arrow.triangle.2.circlepath")
                Spacer()
                Text(nextResetText(descriptor.id))
            }
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
        }
        .cyberCard(cornerRadius: 16, padding: 16)
    }

    private var attentionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CyberSectionHeader(title: L10n.text("需要处理", "Needs Attention"), icon: "exclamationmark.triangle.fill")
            CyberDivider()
            ForEach(Array(attentionItems.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 8) {
                    Image(systemName: item.icon)
                        .foregroundStyle(item.tint)
                    Text(item.text)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    Spacer()
                }
                .padding(10)
                .background(item.tint.opacity(colorScheme == .dark ? 0.10 : 0.07), in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    private var resetTimelineCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CyberSectionHeader(title: L10n.text("即将重置", "Upcoming Resets"), icon: "clock.arrow.circlepath")
            CyberDivider()
            if resetItems.isEmpty {
                Text(L10n.text("暂时没有可用的重置时间", "No reset times are available yet"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            } else {
                ForEach(resetItems) { item in
                    HStack(spacing: 10) {
                        Circle().fill(item.tint).frame(width: 7, height: 7)
                        Text(item.tool)
                            .font(.system(size: 11, weight: .black, design: .rounded))
                            .frame(width: 64, alignment: .leading)
                        Text(item.window)
                            .font(.system(size: 10.5, weight: .semibold))
                        Spacer()
                        Text(UsageNumberFormatter.relativeTimeString(from: item.date))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(item.tint)
                    }
                }
            }
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    private var usageComparisonCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CyberSectionHeader(title: L10n.text("本地用量对比", "Local Usage Comparison"), icon: "chart.bar.xaxis")
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small) }
            }
            CyberDivider()
            ForEach(env.enabledToolsStore.enabledDescriptors) { descriptor in
                let metrics = store.usage[descriptor.id]
                HStack(spacing: 12) {
                    Label(descriptor.displayName, systemImage: descriptor.systemImage)
                        .font(.system(size: 11.5, weight: .black, design: .rounded))
                        .foregroundStyle(accent(for: descriptor))
                        .frame(width: 100, alignment: .leading)
                    usageCell(title: "7D", metrics: metrics?.sevenDay)
                    usageCell(title: "30D", metrics: metrics?.thirtyDay)
                }
                .padding(10)
                .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    private func usageCell(title: String, metrics: DashboardMetricsDTO?) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            Text(UsageNumberFormatter.compactTokenCount(metrics?.totalTokens.canonicalTotalTokens ?? 0))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
            Spacer()
            Text(UsageNumberFormatter.currencyUSD(metrics?.totalCost ?? .zero))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(AppTheme.accentEmerald(for: colorScheme))
        }
        .frame(maxWidth: .infinity)
    }

    private var syncHealthCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CyberSectionHeader(title: L10n.text("同步状态", "Sync Health"), icon: "arrow.triangle.2.circlepath")
                Spacer()
                Button {
                    Task { await env.refreshAllData() }
                } label: {
                    Label(L10n.text("全部刷新", "Refresh All"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(state.isRefreshing || state.isRefreshingClaudeUsage)
            }
            CyberDivider()
            HStack {
                syncRow("Codex", active: env.enabledToolsStore.isEnabled(.codex), healthy: state.connectionStatus.isConnected)
                Spacer()
                syncRow("Claude", active: env.enabledToolsStore.isEnabled(.claude), healthy: state.latestClaudeUsage?.hasQuota == true)
                Spacer()
                Text(L10n.format(
                    "Last synced %@",
                    zhHans: "最后同步 %@",
                    UsageNumberFormatter.relativeTimeString(from: state.lastRefreshTime)
                ))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    private func syncRow(_ name: String, active: Bool, healthy: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(!active ? Color.gray : (healthy ? AppTheme.accentEmerald(for: colorScheme) : AppTheme.accentAmber(for: colorScheme)))
                .frame(width: 7, height: 7)
            Text(name)
            Text(!active
                ? L10n.text("已关闭", "Off")
                : (healthy ? L10n.text("正常", "Healthy") : L10n.text("等待同步", "Waiting")))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
        }
        .font(.system(size: 10.5, weight: .bold, design: .rounded))
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
        default:
            date = nil
        }
        guard let date else { return L10n.text("重置时间未知", "Reset Unknown") }
        return UsageNumberFormatter.relativeTimeString(from: date)
    }

    private struct QuotaRow {
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
                return makeQuotaRow(title: title, used: snapshot.usedPercent)
            }
        case .claude:
            guard let usage = state.latestClaudeUsage else { return [] }
            return ([usage.fiveHourForDisplay, usage.sevenDay].compactMap { $0 } + usage.scopedWeekly).map {
                makeQuotaRow(title: $0.localizedTitle, used: $0.usedPercent)
            }
        default:
            return []
        }
    }

    private func makeQuotaRow(title: String, used: Double) -> QuotaRow {
        let displayed = state.quotaDisplayMode == .used ? used : 100 - used
        let tint: Color = used >= 85
            ? AppTheme.accentRose(for: colorScheme)
            : (used >= 60 ? AppTheme.accentAmber(for: colorScheme) : AppTheme.accentEmerald(for: colorScheme))
        return QuotaRow(
            title: title,
            value: UsageNumberFormatter.percent(displayed, maximumFractionDigits: 0),
            progress: min(max(displayed / 100, 0), 1),
            tint: tint
        )
    }

    private struct AttentionItem {
        let text: String
        let icon: String
        let tint: Color
    }

    private var attentionItems: [AttentionItem] {
        var items: [AttentionItem] = []
        if env.enabledToolsStore.isEnabled(.codex) {
            if !state.connectionStatus.isConnected {
                items.append(AttentionItem(
                    text: L10n.text("Codex 尚未连接，请检查登录或程序环境。", "Codex is not connected. Check sign-in or its app environment."),
                    icon: "bolt.slash.fill",
                    tint: AppTheme.accentAmber(for: colorScheme)
                ))
            } else if state.preferredDisplayRemainingPercent <= 15 {
                items.append(AttentionItem(
                    text: L10n.text("Codex 可用额度已经较低。", "Codex available quota is running low."),
                    icon: "exclamationmark.triangle.fill",
                    tint: AppTheme.accentRose(for: colorScheme)
                ))
            }
        }
        if env.enabledToolsStore.isEnabled(.claude) {
            if let error = state.claudeUsageErrorText {
                items.append(AttentionItem(text: error, icon: "sparkles", tint: AppTheme.accentAmber(for: colorScheme)))
            } else if let usage = state.latestClaudeUsage {
                let remaining = ([usage.fiveHourForDisplay, usage.sevenDay].compactMap { $0 } + usage.scopedWeekly)
                    .map(\.remainingPercent)
                    .min()
                if let remaining, remaining <= 15 {
                items.append(AttentionItem(
                    text: L10n.text("Claude 可用额度已经较低。", "Claude available quota is running low."),
                    icon: "exclamationmark.triangle.fill",
                    tint: AppTheme.accentRose(for: colorScheme)
                ))
                }
            }
        }
        return items
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
        return items.sorted { $0.date < $1.date }
    }
}
