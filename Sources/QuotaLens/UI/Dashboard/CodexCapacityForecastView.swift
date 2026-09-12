import SwiftUI
import Charts

struct CodexCapacityForecastView: View {
    @ObservedObject var state: AppState
    @ObservedObject var accounts: CodexAccountsStore
    let database: SQLiteDatabase
    @State private var windows: [CodexCapacityWindow] = []
    @State private var loadFailed = false
    @State private var loading = false
    @State private var displayedScope = ""

    private var accountKey: String { accounts.selectedKey.isEmpty ? state.account?.accountKey ?? "" : accounts.selectedKey }
    private var loadKey: String {
        "\(accountKey)|\(state.codexCapacityRevision)|\(accounts.snapshots.first?.observedAt ?? 0)|\(state.lastRefreshAttemptAt?.timeIntervalSince1970 ?? 0)|\(accounts.isRefreshing)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    CodexViewingAccountPicker(state: state, accounts: accounts)
                    if loading { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if accounts.selectedKey.isEmpty, let warning = state.codexStorageErrorText {
                    Text(warning).font(.callout).foregroundStyle(.orange)
                }
                if let error = accounts.error, !accounts.selectedKey.isEmpty {
                    Text(error).font(.callout).foregroundStyle(.orange)
                }
                if loadFailed {
                    ContentUnavailableView(L10n.text("历史暂时无法读取，请刷新后重试。", "History is unavailable. Refresh and try again."),
                                           systemImage: "exclamationmark.triangle")
                } else if windows.isEmpty {
                    CapacityEmptyState(isLoading: loading)
                        .frame(maxWidth: .infinity).frame(height: 200)
                } else {
                    ForEach(windows) { window in
                        CapacityWindowCard(window: window)
                    }
                }
            }.frame(maxWidth: 1200).padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task(id: accounts.selectedKey) {
            guard !accounts.selectedKey.isEmpty else { return }
            await accounts.loadSelection(refresh: true)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                await accounts.loadSelection(refresh: true)
            }
        }
        .task(id: loadKey) {
            let scope = accountKey
            if displayedScope != scope {
                windows = []
                displayedScope = scope
            }
            loadFailed = false
            loading = true
            let key = accountKey
            let store = CodexCapacityStore(database: database)
            let now = Int64(Date().timeIntervalSince1970)
            let result = await Task.detached(priority: .utility) {
                Result { () throws -> [CodexCapacityWindow] in
                    return CodexCapacityForecast.analyze(try store.observations(accountKey: key), accountKey: key, now: now)
                }
            }.value
            guard !Task.isCancelled else { return }
            loading = false
            switch result {
            case .success(let value): windows = value
            case .failure: loadFailed = true
            }
        }
    }
}

private struct CapacityEmptyState: View {
    var isLoading = false
    var awaitingCloudUsage = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 24, weight: .light)).foregroundStyle(.secondary)
            Text(isLoading ? L10n.text("加载中", "Loading") : awaitingCloudUsage
                 ? L10n.text("等待云端用量", "Waiting for cloud usage") : L10n.text("等待用量记录", "Waiting for usage"))
                .font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

struct CapacityWindowCard: View {
    let window: CodexCapacityWindow
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedIndex: Int?

    private var cyan: Color { AppTheme.accentCyan(for: colorScheme) }
    private var purple: Color { AppTheme.accentPurple(for: colorScheme) }
    private var hasTrend: Bool { window.cycles.contains { $0.capacity != nil } }
    private var selectedCycle: CodexCapacityCycle? {
        guard let selectedIndex, window.cycles.indices.contains(selectedIndex), window.cycles[selectedIndex].capacity != nil else { return nil }
        return window.cycles[selectedIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                Image(systemName: window.minutes == 300 ? "clock" : "calendar")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(cyan)
                    .frame(width: 36, height: 36)
                    .background(cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                Text(window.minutes == 300 ? L10n.text("5 小时额度", "5-hour quota") : L10n.text("周额度", "Weekly quota"))
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                if window.current?.awaitingCloudUsage == true, hasTrend {
                    Text(L10n.text("等待云端用量", "Waiting for cloud usage"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if let current = window.current, window.isAvailable {
                    Text(L10n.format("Remaining: %.0f%%", zhHans: "剩余可用：%.0f%%", current.remainingPercent))
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(cyan).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(cyan.opacity(0.08), in: Capsule())
                } else {
                    Text(L10n.text("历史", "History")).font(.caption).foregroundStyle(.secondary)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { metrics }
                VStack(alignment: .leading, spacing: 12) { metrics }
            }
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Text(L10n.text("额度趋势", "Quota trend")).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if hasTrend {
                        legend(L10n.text("历史", "History"), color: cyan)
                        legend(L10n.text("估算中", "In progress"), color: .orange)
                        legend(L10n.text("下一周期", "Next cycle"), color: purple)
                    }
                }
                if hasTrend { chart }
                else {
                    CapacityEmptyState(awaitingCloudUsage: window.cycles.last?.awaitingCloudUsage ?? false).frame(height: 120)
                        .background(.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            if let cycle = selectedCycle { cycleDetail(cycle) }
        }
        .padding(22)
        .background(colorScheme == .dark ? Color.white.opacity(0.045) : Color.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.5))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.08 : 0.025), radius: 8, y: 3)
        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
    }

    @ViewBuilder private var metrics: some View {
        metric(L10n.text("本周期预估总量", "Current cycle estimate"), tokens: window.current?.capacity)
        metric(L10n.text("预计还可使用", "Estimated remaining tokens"), tokens: window.isAvailable ? window.current?.remainingTokens : nil)
        metric(L10n.text("下一周期预估", "Next cycle estimate"), tokens: window.prediction?.tokens,
               change: window.prediction.flatMap { $0.followsTrend ? $0.changePercent : nil }, highlighted: true)
    }

    private func metric(_ title: String, tokens: Double?, change: Double? = nil, highlighted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                Spacer(minLength: 0)
                if highlighted { Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(purple) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(tokens.map(number) ?? "—").font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(tokens == nil ? AppTheme.textMuted(for: colorScheme) : AppTheme.textPrimary(for: colorScheme))
                if tokens != nil { Text("tokens").font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                if let change {
                    Text(String(format: "%+.1f%%", change)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(change >= 0 ? cyan : AppTheme.accentAmber(for: colorScheme))
                        .help(L10n.format("%+.1f%% vs. last completed cycle", zhHans: "较最近已结束周期 %+.1f%%", change))
                }
            }
        }.padding(16).frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? purple.opacity(0.055) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(highlighted ? purple.opacity(0.12) : Color.clear, lineWidth: 0.5))
    }

    private var chart: some View {
        Chart {
            ForEach(Array(window.cycles.enumerated()), id: \.element.id) { index, cycle in
                if let capacity = cycle.capacity {
                    if cycle.endAt != nil {
                        LineMark(x: .value("Cycle", index), y: .value("Tokens", capacity),
                                 series: .value("Segment", segment(at: index)))
                            .foregroundStyle(cyan).lineStyle(StrokeStyle(lineWidth: 2.5))
                    }
                    PointMark(x: .value("Cycle", index), y: .value("Tokens", capacity))
                        .foregroundStyle(cycle.endAt == nil ? .orange : cyan)
                        .symbolSize(selectedIndex == index ? 95 : 45)
                        .accessibilityLabel(date(cycle.endAt ?? cycle.observedThrough))
                        .accessibilityValue(number(capacity) + " tokens")
                }
            }
            if let prediction = window.prediction,
               let lastIndex = window.cycles.lastIndex(where: { $0.endAt != nil && $0.capacity != nil }),
               let lastCapacity = window.cycles[lastIndex].capacity {
                LineMark(x: .value("Cycle", lastIndex), y: .value("Tokens", lastCapacity), series: .value("Segment", "forecast"))
                    .foregroundStyle(purple).lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 5]))
                LineMark(x: .value("Cycle", window.cycles.count), y: .value("Tokens", prediction.tokens), series: .value("Segment", "forecast"))
                    .foregroundStyle(purple).lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 5]))
                PointMark(x: .value("Cycle", window.cycles.count), y: .value("Tokens", prediction.tokens))
                    .foregroundStyle(purple).symbol(.diamond).symbolSize(70)
            }
            if let selectedIndex, window.cycles.indices.contains(selectedIndex) {
                RuleMark(x: .value("Cycle", selectedIndex)).foregroundStyle(.secondary.opacity(0.3))
            }
        }
        .chartXScale(domain: -0.3...(Double(max(1, window.cycles.count)) + 0.5))
        .chartXSelection(value: $selectedIndex)
        .chartXAxis {
            AxisMarks(values: axisIndices) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let index = value.as(Int.self) {
                        if index == window.cycles.count {
                            Text(L10n.text("下一周期", "Next cycle"))
                        } else if window.cycles.indices.contains(index) {
                            let stamp = Date(timeIntervalSince1970: Double(window.cycles[index].endAt ?? window.cycles[index].observedThrough))
                            VStack(spacing: 2) {
                                Text(stamp, format: .dateTime.month(.twoDigits).day(.twoDigits))
                                if window.minutes == 300 { Text(stamp, format: .dateTime.hour().minute()) }
                            }
                        }
                    }
                }
            }
        }
        .chartYAxis { AxisMarks(position: .leading) { value in
            AxisGridLine()
            AxisValueLabel { if let n = value.as(Double.self) { Text(number(n)) } }
        } }
        .frame(height: 250)
    }

    private var axisIndices: [Int] {
        let step = max(1, (window.cycles.count + 3) / 4)
        var result = Array(stride(from: 0, to: window.cycles.count, by: step))
        if window.prediction != nil { result.append(window.cycles.count) }
        return result
    }

    private func segment(at index: Int) -> String {
        let prefix = window.cycles.prefix(index + 1)
        let breakIndex = prefix.lastIndex(where: { $0.capacity == nil || $0.hasPrecedingGap }) ?? 0
        return "\(window.cycles[index].stage):\(breakIndex)"
    }

    private func cycleDetail(_ cycle: CodexCapacityCycle) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(date(cycle.startAt) + " — " + date(cycle.endAt ?? cycle.observedThrough)).font(.callout.bold())
                Spacer()
                Text(reason(cycle)).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 20) {
                Text((cycle.capacity.map(number) ?? "—") + " tokens").fontWeight(.semibold)
                Text(L10n.format("Remaining: %.0f%%", zhHans: "剩余可用：%.0f%%", cycle.remainingPercent))
            }.font(.callout)
            if let capacity = cycle.capacity,
               let index = window.cycles.firstIndex(where: { $0.id == cycle.id }), index > 0,
               window.cycles[index - 1].stage == cycle.stage, !cycle.hasPrecedingGap,
               let previous = window.cycles[index - 1].capacity {
                Text(L10n.format("Change: %@ tokens (%+.1f%%)", zhHans: "较上周期：%@ tokens（%+.1f%%）",
                                 (capacity >= previous ? "+" : "−") + number(abs(capacity - previous)), (capacity / previous - 1) * 100))
                    .font(.callout.bold()).foregroundStyle(capacity >= previous ? cyan : .orange)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .help(cycle.hasGap ? L10n.text("部分时段未记录，仅使用时间对应的用量和额度变化估算。",
                                          "Some periods are missing. Only matched usage and quota changes are used.") : "")
    }

    private func reason(_ cycle: CodexCapacityCycle) -> String {
        switch cycle.endReason {
        case .natural: return L10n.text("正常重置", "Scheduled reset")
        case .restored: return L10n.text("提前恢复额度", "Early quota recovery")
        case .planChanged: return L10n.text("套餐变更", "Plan changed")
        case .awaitingRefresh: return L10n.text("等待重置确认", "Awaiting reset confirmation")
        case nil: return L10n.text("估算中", "In progress")
        }
    }
    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 7, height: 7); Text(title).font(.caption).foregroundStyle(.secondary) }
    }
    private func number(_ value: Double) -> String {
        UsageNumberFormatter.compactTokenCount(Int64(min(max(0, value), Double(Int64.max / 2))))
    }
    private func date(_ time: Int64) -> String {
        Date(timeIntervalSince1970: Double(time)).formatted(.dateTime.locale(L10n.locale).month(.twoDigits).day(.twoDigits).hour().minute())
    }
}
