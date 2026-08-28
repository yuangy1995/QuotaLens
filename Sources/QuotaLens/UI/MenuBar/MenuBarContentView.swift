// QuotaLens 科技风菜单栏全息浮窗视图 (Dual Theme MenuBar Popover)

import SwiftUI
import Combine

@MainActor
private final class MenuBarLocalUsageStore: ObservableObject {
    @Published var sevenDayMetrics: DashboardMetricsDTO?
    @Published var thirtyDayMetrics: DashboardMetricsDTO?
    @Published var quotaForecast: QuotaForecastDTO?
    @Published var isLoading = false

    private let facade: UsageQueryFacade
    private var forecastPoints: [QuotaForecastEngine.RateSnapshotPoint] = []

    init(facade: UsageQueryFacade) {
        self.facade = facade
    }

    func load(accountKey: String?, currentUsedPercent: Double, currentSnapshot: RateLimitSnapshotRecord?) async {
        guard UsageFeatureFlags.shared.isAnalyticsEnabled else {
            sevenDayMetrics = nil
            thirtyDayMetrics = nil
            quotaForecast = nil
            return
        }
        guard !isLoading else { return }

        isLoading = true
        defer { isLoading = false }

        sevenDayMetrics = try? await facade.getDashboardMetrics(days: 7)
        thirtyDayMetrics = try? await facade.getDashboardMetrics(days: 30)

        guard currentUsedPercent < 99.999_9 else {
            quotaForecast = nil
            return
        }

        let storedSnaps = (try? await facade.getRecentRateLimitSnapshots(accountKey: accountKey, limit: 300)) ?? []
        forecastPoints = storedSnaps.compactMap { snapshot -> QuotaForecastEngine.RateSnapshotPoint? in
            guard let resetAt = snapshot.resetsAt else { return nil }
            return QuotaForecastEngine.RateSnapshotPoint(
                timestamp: Date(timeIntervalSince1970: Double(snapshot.observedAt)),
                usedPercent: Double(snapshot.usedPercentMilli) / 1000.0,
                cycleKey: QuotaForecastEngine.QuotaCycleKey(
                    accountID: snapshot.accountKey,
                    limitID: snapshot.limitId,
                    slot: snapshot.slot,
                    resetAt: resetAt,
                    windowDurationMins: snapshot.windowDurationMins
                )
            )
        }
        updateForecast(currentUsedPercent: currentUsedPercent, currentSnapshot: currentSnapshot)
    }

    func updateForecast(currentUsedPercent: Double, currentSnapshot: RateLimitSnapshotRecord?) {
        guard currentUsedPercent < 99.999_9 else {
            quotaForecast = nil
            return
        }

        let currentCycleKey = currentSnapshot.flatMap { snapshot -> QuotaForecastEngine.QuotaCycleKey? in
            guard let resetAt = snapshot.resetsAt else { return nil }
            return QuotaForecastEngine.QuotaCycleKey(
                accountID: snapshot.accountKey,
                limitID: snapshot.limitId,
                slot: snapshot.slot,
                resetAt: resetAt,
                windowDurationMins: snapshot.windowDurationMins
            )
        }
        quotaForecast = QuotaForecastEngine.forecast(
            currentUsedPercent: currentUsedPercent,
            resetsAt: currentSnapshot?.resetsAt,
            currentCycleKey: currentCycleKey,
            snapshots: forecastPoints
        )
    }
}

public struct MenuBarContentView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var scanCoordinator: CodexUsageScanCoordinator
    @StateObject private var localUsageStore: MenuBarLocalUsageStore
    @Environment(\.colorScheme) var colorScheme
    var onOpenMainWindow: () -> Void
    var onRefresh: () -> Void

    public init(
        state: AppState,
        usageFacade: UsageQueryFacade,
        onOpenMainWindow: @escaping () -> Void,
        onRefresh: @escaping () -> Void
    ) {
        self.state = state
        self.scanCoordinator = .shared
        self.onOpenMainWindow = onOpenMainWindow
        self.onRefresh = onRefresh
        _localUsageStore = StateObject(wrappedValue: MenuBarLocalUsageStore(facade: usageFacade))
    }

    public var body: some View {
        let isDark = colorScheme == .dark
        let cyan = AppTheme.accentCyan(for: colorScheme)

        VStack(spacing: 12) {
            // 顶部 HUD 品牌与连接状态栏
            headerBar

            CyberDivider()

            // 主全息遥测区域 (已收敛内嵌模式切换)
            if state.hasQuotaSnapshot {
                quotaHUDView
            } else {
                quotaUnavailableHUDView
            }

            CyberDivider(glowColor: isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.08))

            // 底部操作坞 (Action Dock)
            actionDock
        }
        .padding(16)
        .frame(width: 340)
        .background(
            AppTheme.popoverGradient(for: colorScheme)
        )
        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
        .tint(cyan)
        .preferredColorScheme(state.colorScheme)
        .task {
            await refreshLocalUsageStore()
        }
        .onChange(of: scanCoordinator.isScanning) { _, isScanning in
            guard !isScanning else { return }
            Task {
                await refreshLocalUsageStore()
            }
        }
        .onReceive(state.$latestRateLimit.dropFirst()) { _ in
            updateLocalUsageForecast()
        }
        .onReceive(state.$currentQuotaSnapshots.dropFirst()) { _ in
            updateLocalUsageForecast()
        }
        .onChange(of: state.selectedAccountKey) { _, _ in
            Task {
                await refreshLocalUsageStore()
            }
        }
    }

    private func refreshLocalUsageStore() async {
        guard !scanCoordinator.isScanning else { return }

        let forecastSnapshot = state.preferredQuotaForecastSnapshot
        await localUsageStore.load(
            accountKey: state.selectedAccountKey ?? state.account?.accountKey,
            currentUsedPercent: forecastSnapshot?.usedPercent ?? 0.0,
            currentSnapshot: forecastSnapshot
        )
    }

    private func updateLocalUsageForecast() {
        localUsageStore.updateForecast(
            currentUsedPercent: state.preferredQuotaForecastSnapshot?.usedPercent ?? 0.0,
            currentSnapshot: state.preferredQuotaForecastSnapshot
        )
    }

    // MARK: - 顶部品牌与状态栏
    private var headerBar: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let blue = AppTheme.accentBlue(for: colorScheme)

        return HStack(alignment: .center) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [cyan, blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
                        )
                        .shadow(color: cyan.opacity(colorScheme == .dark ? 0.5 : 0.25), radius: 5)

                    Image(systemName: "gauge.with.needle.fill")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text("QUOTALENS")
                            .font(.system(size: 13, weight: .black, design: .rounded))
                            .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                        Text(L10n.text("状态", "Status"))
                            .font(.system(size: 9, weight: .heavy, design: .monospaced))
                            .foregroundStyle(cyan)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(cyan.opacity(colorScheme == .dark ? 0.15 : 0.12), in: RoundedRectangle(cornerRadius: 3))
                    }

                    Text(state.displayName(for: state.account?.accountKey))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        .lineLimit(1)
                }
            }

            Spacer()

            StatusBadge.forConnection(state.connectionStatus)
        }
    }

    // MARK: - 主配额 HUD 视图 (左右对齐布局：左侧大表盘，右侧模式切换+核心指标)
    private var quotaHUDView: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let amber = AppTheme.accentAmber(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)
        let rose = AppTheme.accentRose(for: colorScheme)
        let isDark = colorScheme == .dark
        let renewalColor = renewalBadgeColor(emerald: emerald, amber: amber, rose: rose, fallback: cyan)

        return VStack(spacing: 12) {
            // 上半区：发光全息主双环量表卡片 (左图右文垂直对齐)
            HStack(alignment: .top, spacing: 14) {
                // 左侧：双环量表 (扩大展示空间)
                Button(action: {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        state.toggleQuotaDisplayMode()
                    }
                }) {
                    CircularProgressView(
                        progress: state.preferredDisplayQuotaProgress,
                        riskProgress: state.preferredDisplayQuotaRiskProgress,
                        lineWidth: 12.5,
                        size: 104,
                        title: state.quotaDisplayMode.ringTitle(for: state.preferredDisplayQuotaWindowKind),
                        valueText: state.preferredDisplayQuotaPercentString,
                        subtitle: "\(state.quotaDisplayMode.complementLabel) \(state.preferredDisplayComplementQuotaPercentString)"
                    )
                }
                .buttonStyle(.plain)
                .help(L10n.text("点击切换已用/可用视角", "Click to toggle used/available view"))

                Spacer(minLength: 8)

                // 右侧：2 (模式微胶囊) 与 3 (核心数据指标) 垂直排布
                VStack(alignment: .leading, spacing: 18) {
                    // 2: 紧凑模式微胶囊
                    QuotaMiniModeToggle(
                        selection: Binding(
                            get: { state.quotaDisplayMode },
                            set: { state.setQuotaDisplayMode($0) }
                        )
                    )

                    // 3: 核心指标数值
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 4) {
                            Text(state.quotaDisplayMode.primaryLabel)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                            Text(state.preferredDisplayQuotaPercentString)
                                .font(.system(size: 18, weight: .black, design: .rounded))
                                .foregroundStyle(cyan)
                                .monospacedDigit()
                        }

                        HStack(spacing: 4) {
                            Text(state.quotaDisplayMode.complementLabel)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                            Text(state.preferredDisplayComplementQuotaPercentString)
                                .font(.system(size: 18, weight: .black, design: .rounded))
                                .foregroundStyle(state.preferredDisplayQuotaSeverityColor)
                                .monospacedDigit()
                        }
                    }
                    .padding(.top, 3)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(
                isDark ? Color.black.opacity(0.35) : Color.white.opacity(0.92),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(cyan.opacity(isDark ? 0.45 : 0.35), lineWidth: 0.9)
            )
            .shadow(color: isDark ? Color.black.opacity(0.25) : Color.black.opacity(0.04), radius: 6, y: 2)

            if state.isQuotaExhausted {
                quotaExhaustedStatusStrip
            } else if let prediction = quotaPacePrediction {
                quotaPacePredictionStrip(prediction)
            }

            // 下半区：2x2 结构化微型指标卡
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        MicroHUDTile(
                            icon: "hourglass",
                            iconColor: amber,
                            title: L10n.text("重置倒计时", "Reset Countdown"),
                            value: state.preferredDisplayResetCountdownString,
                            caption: state.preferredDisplayResetExactDateString ?? L10n.text("下周期自动重置", "Auto-resets next cycle")
                        )
                    }

                    MicroHUDTile(
                        icon: "ticket.fill",
                        iconColor: state.resetCreditAvailableCount > 0 ? amber : AppTheme.textSecondary(for: colorScheme),
                        title: L10n.text("重置卡储备", "Reset Cards"),
                        value: L10n.format("%d available", zhHans: "%d 张可用", state.resetCreditAvailableCount),
                        caption: state.nearestResetCreditExpiryShortString != nil ? L10n.format("Expires %@", zhHans: "截止 %@", state.nearestResetCreditExpiryShortString!) : L10n.text("随时可用", "Ready")
                    )
                }

                GridRow {
                    MicroHUDTile(
                        icon: "calendar.badge.clock",
                        iconColor: cyan,
                        title: L10n.text("订阅有效期", "Subscription"),
                        value: state.subscriptionPlanTitle.uppercased(),
                        caption: state.hasSubscriptionPeriod ? state.subscriptionPeriodRangeShortText : L10n.text("有效周期内", "Within active period"),
                        badgeText: state.subscriptionRenewalStatusShortText,
                        badgeColor: renewalColor
                    )

                    MicroHUDTile(
                        icon: "bolt.horizontal.fill",
                        iconColor: emerald,
                        title: L10n.text("刷新频率", "Refresh Rate"),
                        value: L10n.format("Every %@", zhHans: "每 %@", state.refreshIntervalDescription),
                        caption: L10n.format("Sync: %@", zhHans: "同步: %@", state.formatTime(state.lastRefreshTime))
                    )
                }
            }

            // 本地分析快捷卡片
            if UsageFeatureFlags.shared.isAnalyticsEnabled {
                localAnalyticsSnapshotCard
            }
        }
    }

    private var localAnalyticsSnapshotCard: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)
        let isDark = colorScheme == .dark

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(cyan)

                Text(L10n.text("本地用量分析", "Local Analytics"))
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))

                Spacer()

                if localUsageStore.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if let thirty = localUsageStore.thirtyDayMetrics {
                    Text(L10n.format("%d sessions", zhHans: "%d 个会话", thirty.totalSessions))
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(cyan)
                }
            }

            HStack(spacing: 8) {
                MenuBarUsagePill(
                    title: "7D",
                    tokens: localUsageStore.sevenDayMetrics?.totalTokens.canonicalTotalTokens ?? 0,
                    cost: localUsageStore.sevenDayMetrics?.totalCost ?? .zero,
                    accent: cyan
                )

                MenuBarUsagePill(
                    title: "30D",
                    tokens: localUsageStore.thirtyDayMetrics?.totalTokens.canonicalTotalTokens ?? 0,
                    cost: localUsageStore.thirtyDayMetrics?.totalCost ?? .zero,
                    accent: emerald
                )
            }

            if scanCoordinator.isScanning {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(cyan)
                        Text(L10n.text("正在扫描本地记录", "Scanning local history"))
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        Spacer()
                        if let progress = scanCoordinator.progress {
                            Text(UsageNumberFormatter.percent(progress * 100.0, maximumFractionDigits: 0))
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(cyan)
                        }
                    }

                    if let progress = scanCoordinator.progress {
                        ProgressView(value: progress)
                            .tint(cyan)
                    } else {
                        ProgressView()
                            .tint(cyan)
                    }

                    if !scanCoordinator.statusText.isEmpty {
                        Text(scanCoordinator.statusText)
                            .font(.system(size: 8.5, weight: .medium, design: .rounded))
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                            .lineLimit(1)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.05), lineWidth: 0.8)
        )
    }

    private func quotaPacePredictionStrip(_ prediction: (text: String, color: Color)) -> some View {
        let isDark = colorScheme == .dark

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(prediction.color)

                Text(L10n.text("额度预测", "Quota Forecast"))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))

                Spacer()

                Text(state.preferredDisplayUsedPercentString)
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(prediction.color)
            }

            ProgressView(value: state.preferredDisplayQuotaRiskProgress)
                .tint(prediction.color)

            Text(prediction.text)
                .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                .foregroundStyle(prediction.color)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            prediction.color.opacity(isDark ? 0.12 : 0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(prediction.color.opacity(isDark ? 0.34 : 0.24), lineWidth: 0.8)
        )
    }

    private var quotaExhaustedStatusStrip: some View {
        let rose = AppTheme.accentRose(for: colorScheme)
        let isDark = colorScheme == .dark

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(rose)

                Text(L10n.text("额度状态", "Quota Status"))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))

                Spacer()

                Text(state.quotaExhaustionStatusTitle)
                    .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                    .foregroundStyle(rose)
            }

            Text(state.quotaExhaustionStatusMessage)
                .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                .foregroundStyle(rose)
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            rose.opacity(isDark ? 0.12 : 0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(rose.opacity(isDark ? 0.34 : 0.24), lineWidth: 0.8)
        )
    }

    private func renewalBadgeColor(emerald: Color, amber: Color, rose: Color, fallback: Color) -> Color {
        switch state.subscriptionRenewalState {
        case .autoRenews:
            return emerald
        case .ending:
            return rose
        case .changing:
            return amber
        case .unknown:
            return fallback
        }
    }

    private var quotaPacePrediction: (text: String, color: Color)? {
        guard state.hasQuotaSnapshot, !state.isQuotaExhausted else {
            return nil
        }

        guard let forecast = localUsageStore.quotaForecast else {
            return (
                L10n.text("数据收集中", "Collecting data"),
                AppTheme.textSecondary(for: colorScheme)
            )
        }

        switch forecast.risk {
        case .critical:
            let duration = forecast.hoursUntilExhaustion.map { UsageNumberFormatter.remainingDurationString(seconds: $0 * 3600.0) }
                ?? L10n.text("较快用尽", "Runs out soon")
            return (
                L10n.format("At current pace, exhausts in %@", zhHans: "按当前速度，%@ 后用尽", duration),
                AppTheme.accentRose(for: colorScheme)
            )
        case .warning:
            return (
                L10n.text("用量偏快，预计可撑到重置", "Usage is high, still likely lasts until reset"),
                AppTheme.accentAmber(for: colorScheme)
            )
        case .onTrack, .underPaced:
            return (
                L10n.text("按当前速度，可撑到重置", "At current pace, lasts until reset"),
                AppTheme.accentEmerald(for: colorScheme)
            )
        case .insufficientData:
            return (
                L10n.text("数据收集中", "Collecting data"),
                AppTheme.textSecondary(for: colorScheme)
            )
        }
    }

    // MARK: - 额度不可用浮窗提示
    private var quotaUnavailableHUDView: some View {
        let amber = AppTheme.accentAmber(for: colorScheme)
        let isDark = colorScheme == .dark

        return VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(amber)

            Text(state.quotaUnavailableTitle)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

            Text(state.quotaUnavailableDescription)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 140)
        .background(
            isDark ? Color.black.opacity(0.35) : Color.white.opacity(0.92),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(amber.opacity(isDark ? 0.45 : 0.35), lineWidth: 0.9)
        )
    }

    // MARK: - 底部操作坞
    private var actionDock: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let blue = AppTheme.accentBlue(for: colorScheme)
        let rose = AppTheme.accentRose(for: colorScheme)
        let isDark = colorScheme == .dark

        return HStack(spacing: 8) {
            Button(action: onOpenMainWindow) {
                HStack(spacing: 6) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 11, weight: .bold))
                    Text(L10n.text("打开 QuotaLens", "Open QuotaLens"))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    LinearGradient(
                        colors: [cyan, blue],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .foregroundStyle(.white)
                .shadow(color: cyan.opacity(isDark ? 0.35 : 0.20), radius: 4)
            }
            .buttonStyle(.plain)

            // 外观主题深浅双态切换 (浅色 / 深色)
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if state.themeMode == .dark {
                        state.setThemeMode(.light)
                    } else {
                        state.setThemeMode(.dark)
                    }
                }
            }) {
                Image(systemName: state.themeMode == .dark ? "moon.fill" : "sun.max.fill")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 30, height: 28)
                    .background(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(isDark ? Color.white.opacity(0.15) : Color.black.opacity(0.10), lineWidth: 0.8)
                    )
                    .foregroundStyle(cyan)
            }
            .buttonStyle(.plain)
            .help(state.themeMode == .dark ? L10n.text("当前深色模式 (点击切换为浅色)", "Dark mode active (click for light)") : L10n.text("当前浅色模式 (点击切换为深色)", "Light mode active (click for dark)"))

            // 刷新
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 30, height: 28)
                    .background(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(isDark ? Color.white.opacity(0.15) : Color.black.opacity(0.10), lineWidth: 0.8)
                    )
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
            }
            .buttonStyle(.plain)
            .help(L10n.text("立即刷新数据", "Refresh data now"))
            .disabled(state.isRefreshing)

            // 退出
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 30, height: 28)
                    .background(rose.opacity(isDark ? 0.15 : 0.10), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(rose.opacity(isDark ? 0.35 : 0.25), lineWidth: 0.8)
                    )
                    .foregroundStyle(rose)
            }
            .buttonStyle(.plain)
            .help(L10n.text("退出 QuotaLens", "Quit QuotaLens"))
        }
    }
}

// MARK: - 紧凑型 HUD 指标微卡 (MicroHUDTile)
private struct MicroHUDTile: View {
    @Environment(\.colorScheme) var colorScheme
    let icon: String
    let iconColor: Color
    let title: String
    let value: String
    let caption: String
    var badgeText: String? = nil
    var badgeColor: Color? = nil

    var body: some View {
        let isDark = colorScheme == .dark

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(iconColor)

                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))

                Spacer()
            }

            HStack(spacing: 5) {
                Text(value)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                if let badgeText, let badgeColor {
                    RenewalStatusChip(text: badgeText, color: badgeColor)
                        .layoutPriority(1)
                }
            }

            Text(caption)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isDark ? Color(red: 0.145, green: 0.180, blue: 0.285).opacity(0.94) : Color.white.opacity(0.95),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isDark ? Color.white.opacity(0.18) : Color.black.opacity(0.10), lineWidth: 1.0)
        )
    }
}

private struct MenuBarUsagePill: View {
    @Environment(\.colorScheme) var colorScheme
    let title: String
    let tokens: Int64
    let cost: MoneyNanoUSD
    let accent: Color

    var body: some View {
        let isDark = colorScheme == .dark

        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(accent)

            Text(UsageNumberFormatter.compactTokenCount(tokens))
                .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(UsageNumberFormatter.currencyUSD(cost))
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .background(
            isDark ? Color.white.opacity(0.045) : Color.white.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(accent.opacity(isDark ? 0.22 : 0.18), lineWidth: 0.8)
        )
    }
}

// MARK: - 订阅续费状态胶囊
private struct RenewalStatusChip: View {
    @Environment(\.colorScheme) var colorScheme
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .heavy, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(colorScheme == .dark ? 0.16 : 0.12), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(color.opacity(colorScheme == .dark ? 0.42 : 0.34), lineWidth: 0.8)
            )
            .foregroundStyle(color)
    }
}

// MARK: - 迷你套餐标签
private struct PlanMiniChip: View {
    @Environment(\.colorScheme) var colorScheme
    let plan: String?

    var body: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        Text((plan ?? "PLUS").uppercased())
            .font(.system(size: 9, weight: .black, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(cyan.opacity(colorScheme == .dark ? 0.15 : 0.12), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(cyan.opacity(0.4), lineWidth: 0.8)
            )
            .foregroundStyle(cyan)
    }
}

// MARK: - 紧凑模式微胶囊切换器 (QuotaMiniModeToggle)
private struct QuotaMiniModeToggle: View {
    @Environment(\.colorScheme) var colorScheme
    @Binding var selection: QuotaDisplayMode

    var body: some View {
        let isDark = colorScheme == .dark
        let cyan = AppTheme.accentCyan(for: colorScheme)

        HStack(spacing: 2) {
            ForEach(QuotaDisplayMode.allCases) { mode in
                let isSelected = selection == mode
                Button(action: {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        selection = mode
                    }
                }) {
                    Text(mode.shortTitle)
                        .font(.system(size: 10, weight: isSelected ? .bold : .medium, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(
                            isSelected ? cyan.opacity(isDark ? 0.22 : 0.16) : Color.clear,
                            in: Capsule()
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(isSelected ? cyan.opacity(isDark ? 0.55 : 0.40) : Color.clear, lineWidth: 0.8)
                        )
                        .foregroundStyle(isSelected ? cyan : AppTheme.textSecondary(for: colorScheme))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.045),
            in: Capsule()
        )
    }
}
