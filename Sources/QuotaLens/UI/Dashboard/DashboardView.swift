// QuotaLens 科技风全息总览仪表盘视图 (Dual Theme Dashboard)

import SwiftUI

public struct DashboardView: View {
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) var colorScheme
    @State private var pendingCredit: ResetCreditDisplay?
    @State private var consumingCreditId: String?

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // 核心 Hero 主控舱：周额度全息仪表与数据流
                Group {
                    if state.hasQuotaSnapshot {
                        quotaHeroHUDCard
                    } else {
                        quotaUnavailableHUDCard
                    }
                }

                // 智能建议模块 (有活跃建议时展示，无建议时自动隐藏)
                if let suggestion = state.activeDashboardSuggestion {
                    suggestionBannerCard(suggestion)
                }

                // 指标矩阵
                telemetryMetricsMatrix

                // 重置卡列表
                resetCreditsHangarView
            }
            .padding(24)
        }
        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
        .resetCreditUseAlerts(
            state: state,
            pendingCredit: $pendingCredit,
            consumingCreditId: $consumingCreditId
        )
    }

    // MARK: - 核心配额卡片
    private var quotaHeroHUDCard: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        return VStack(alignment: .leading, spacing: 18) {
            // 顶部小标头与右侧操作流
            HStack(alignment: .center, spacing: 12) {
                CyberSectionHeader(
                    title: L10n.text("额度概览", "Quota Overview"),
                    icon: "gauge.with.needle.fill"
                )

                PlanPillView(plan: state.subscriptionPlanTitle)

                Spacer()

                // 高对比度科技风分段控制器（已用/剩余可用）
                CyberSegmentedPicker(selection: Binding(
                    get: { state.quotaDisplayMode },
                    set: { state.setQuotaDisplayMode($0) }
                ))

                // 同步时间微徽章
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.2.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(cyan)
                    Text(L10n.format("Sync: %@", zhHans: "同步: %@", state.formatTime(state.lastRefreshTime)))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
                )
            }

            CyberDivider()

            HStack(spacing: 28) {
                // 全息双环表盘
                CircularProgressView(
                    progress: state.displayedQuotaProgress,
                    riskProgress: state.quotaRiskProgress,
                    lineWidth: 16,
                    size: 160,
                    title: state.quotaDisplayMode.ringTitle(for: state.quotaWindowKind),
                    valueText: state.displayedQuotaPercentString,
                    subtitle: "\(state.quotaDisplayMode.complementLabel) \(state.complementQuotaPercentString)"
                )

                // 结构化指标网格
                VStack(alignment: .leading, spacing: 14) {
                    // 主额度遥测大字卡 + 建议日均消耗微卡片
                    HStack(alignment: .top, spacing: 16) {
                        HStack(spacing: 24) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(state.quotaDisplayMode.primaryLabel)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                                Text(state.displayedQuotaPercentString)
                                    .font(.system(size: 30, weight: .black, design: .rounded))
                                    .foregroundStyle(cyan)
                                    .monospacedDigit()
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(state.quotaDisplayMode.complementLabel)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                                Text(state.complementQuotaPercentString)
                                    .font(.system(size: 30, weight: .black, design: .rounded))
                                    .foregroundStyle(state.quotaSeverityColor)
                                    .monospacedDigit()
                            }
                        }

                        Spacer(minLength: 8)

                        // 建议日均可用消耗微卡片
                        dailyBudgetPaceCard
                    }

                    CyberDivider()

                    // 下次重置周期与订阅期限
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                        GridRow {
                            HStack(spacing: 5) {
                                Image(systemName: "hourglass")
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppTheme.accentAmber(for: colorScheme))
                                Text(L10n.text("重置倒计时:", "Reset in:"))
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                            }

                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                HStack(spacing: 6) {
                                    Text(state.resetCountdownString)
                                        .font(.system(size: 13, weight: .heavy, design: .monospaced))
                                        .foregroundStyle(AppTheme.accentAmber(for: colorScheme))

                                    if let resetDate = state.resetExactDateString {
                                        Text("(\(resetDate))")
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                                    }
                                }
                            }
                        }

                        if state.hasSubscriptionPeriod {
                            GridRow {
                                HStack(spacing: 5) {
                                    Image(systemName: "calendar.badge.clock")
                                        .font(.system(size: 11))
                                        .foregroundStyle(cyan)
                                    Text(L10n.text("当前订阅周期:", "Current period:"))
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                                }

                                Text(state.subscriptionPeriodText)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.85)
                            }
                        }
                    }
                }
            }
        }
        .cyberCard(cornerRadius: 16, padding: 22, isHighlighted: true, glowColor: cyan)
    }

    // MARK: - 建议日均配额消耗微卡片
    private var dailyBudgetPaceCard: some View {
        let isDark = colorScheme == .dark
        let emerald = AppTheme.accentEmerald(for: colorScheme)
        let rose = AppTheme.accentRose(for: colorScheme)
        let isExhausted = state.isQuotaExhausted
        let accent = isExhausted ? rose : emerald

        return TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: isExhausted ? "exclamationmark.octagon.fill" : "chart.line.uptrend.xyaxis")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(accent)

                    Text(isExhausted
                        ? L10n.text("本周期额度已用尽", "Quota Exhausted")
                        : state.recommendedQuotaPaceTitle)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))

                    Spacer(minLength: 4)

                    Text(isExhausted
                        ? L10n.text("等待重置", "Waiting")
                        : L10n.text("匀速", "Paced"))
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(accent.opacity(isDark ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 3.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3.5)
                                .strokeBorder(accent.opacity(0.35), lineWidth: 0.6)
                        )
                }

                if isExhausted {
                    Text(L10n.text("已用尽", "Exhausted"))
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .foregroundStyle(accent)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(state.recommendedQuotaPacePercentString(now: context.date))
                            .font(.system(size: 18, weight: .black, design: .rounded))
                            .foregroundStyle(accent)
                            .monospacedDigit()

                        Text("/" + state.recommendedQuotaPaceUnit)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    }
                }

                Text(isExhausted
                    ? L10n.text("等待下周期重置恢复", "Will restore on next reset")
                    : state.recommendedQuotaPaceSubtitle(now: context.date))
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme).opacity(0.88))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minWidth: 156)
            .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(accent.opacity(isDark ? 0.28 : 0.20), lineWidth: 0.8)
            )
        }
    }

    // MARK: - 智能建议横幅
    private func suggestionBannerCard(_ suggestion: DashboardSuggestion) -> some View {
        let amber = AppTheme.accentAmber(for: colorScheme)
        let orange = Color(red: 0.94, green: 0.44, blue: 0.05)
        let isDark = colorScheme == .dark

        return HStack(alignment: .center, spacing: 16) {
            // 左侧立体图标徽章
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [amber, orange],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 38, height: 38)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.4), lineWidth: 0.8)
                    )
                    .shadow(color: amber.opacity(isDark ? 0.4 : 0.2), radius: 6, x: 0, y: 2)

                Image(systemName: suggestion.icon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            }

            // 中间文本内容
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(L10n.text("智能建议", "Smart Suggestion"))
                        .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                        .foregroundStyle(amber)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(amber.opacity(isDark ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(amber.opacity(0.35), lineWidth: 0.6)
                        )

                    Text(suggestion.title)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                }

                Text(suggestion.message)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            // 右侧操作流
            HStack(spacing: 10) {
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        state.dismissSuggestion(suggestion.id)
                    }
                } label: {
                    Text(suggestion.dismissActionTitle)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
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

                Button {
                    if case .resetCredit(let credit) = suggestion.payload {
                        pendingCredit = credit
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text(suggestion.primaryActionTitle)
                            .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6.5)
                    .background(
                        LinearGradient(
                            colors: [amber, orange],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .shadow(color: amber.opacity(isDark ? 0.35 : 0.2), radius: 5, x: 0, y: 2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppTheme.insetSurface(for: colorScheme),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(amber.opacity(isDark ? 0.38 : 0.28), lineWidth: 1.0)
        )
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.98)).combined(with: .move(edge: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.98)).combined(with: .move(edge: .top))
        ))
    }

    // MARK: - 指标矩阵
    private var telemetryMetricsMatrix: some View {
        HStack(spacing: 14) {
            StatMetricCard(
                title: L10n.text("额度健康状态", "Quota Health"),
                value: healthStatusTitle,
                subtitle: healthStatusSubtitle,
                icon: "shield.lefthalf.filled.badge.checkmark",
                color: healthStatusColor
            )

            StatMetricCard(
                title: L10n.text("刷新频率", "Refresh Rate"),
                value: state.refreshIntervalDescription,
                subtitle: L10n.text("后台自动刷新", "Automatic background refresh"),
                icon: "arrow.triangle.2.circlepath",
                color: AppTheme.accentCyan(for: colorScheme)
            )

            StatMetricCard(
                title: L10n.text("重置卡储备", "Reset Card Reserve"),
                value: availableCardCountText(state.resetCreditAvailableCount),
                subtitle: state.nearestResetCredit?.expiresAt != nil ? nearestDeadlineText(state.formatFullDate(state.nearestResetCredit!.expiresAt!)) : L10n.text("全周期备用储备", "Reserve available for the full cycle"),
                icon: "ticket.fill",
                color: state.resetCreditAvailableCount > 0 ? AppTheme.accentAmber(for: colorScheme) : AppTheme.textSecondary(for: colorScheme)
            )
        }
    }

    private var healthStatusTitle: String {
        guard state.hasQuotaSnapshot else {
            return L10n.text("等待同步", "Waiting for sync")
        }
        if state.currentRemainingPercent <= 15.0 {
            return L10n.text("严重告急", "Critical")
        } else if state.currentRemainingPercent <= 35.0 {
            return L10n.text("余量偏低", "Low reserve")
        } else {
            return L10n.text("储备充沛", "Healthy reserve")
        }
    }

    private var healthStatusSubtitle: String {
        guard state.hasQuotaSnapshot else {
            return L10n.text("当前账号额度待读取", "Quota is pending for the current account")
        }
        return L10n.format("%@ remaining", zhHans: "剩余可用 %@", state.currentRemainingPercentString)
    }

    private var healthStatusColor: Color {
        guard state.hasQuotaSnapshot else {
            return AppTheme.textSecondary(for: colorScheme)
        }
        if state.currentRemainingPercent <= 15.0 {
            return AppTheme.accentRose(for: colorScheme)
        } else if state.currentRemainingPercent <= 35.0 {
            return AppTheme.accentAmber(for: colorScheme)
        } else {
            return AppTheme.accentEmerald(for: colorScheme)
        }
    }

    // MARK: - 额度不可用提示卡
    private var quotaUnavailableHUDCard: some View {
        let amber = AppTheme.accentAmber(for: colorScheme)
        return VStack(spacing: 16) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(amber.opacity(colorScheme == .dark ? 0.15 : 0.10))
                        .frame(width: 54, height: 54)
                        .overlay(
                            Circle()
                                .strokeBorder(amber.opacity(0.4), lineWidth: 1)
                        )

                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(amber)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(state.quotaUnavailableTitle)
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                    }

                    Text(state.quotaUnavailableDescription)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }

                Spacer()
            }
        }
        .cyberCard(cornerRadius: 16, padding: 22, isHighlighted: false)
        .frame(minHeight: 140)
    }

    // MARK: - 重置卡列表
    private var resetCreditsHangarView: some View {
        let amber = AppTheme.accentAmber(for: colorScheme)
        let countColor = state.resetCreditAvailableCount > 0 ? amber : AppTheme.textSecondary(for: colorScheme)
        let dashboardCredits = state.dashboardResetCredits
        let missingDetailCount = state.resetCreditMissingDetailCount

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                CyberSectionHeader(
                    title: L10n.text("重置卡", "Reset Cards"),
                    icon: "ticket.fill"
                )

                Text(resetCreditCountText)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(countColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(countColor.opacity(colorScheme == .dark ? 0.15 : 0.10), in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(countColor.opacity(0.35), lineWidth: 0.8)
                    )

                Spacer()

                if let nearest = state.nearestResetCredit?.expiresAt {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.system(size: 10))
                            .foregroundStyle(amber)
                        Text(nearestDeadlineText(state.formatFullDate(nearest)))
                    }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }
            }

            CyberDivider(glowColor: amber.opacity(0.3))

            if dashboardCredits.isEmpty && missingDetailCount == 0 {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "ticket")
                            .font(.system(size: 28))
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme).opacity(0.5))
                        Text(L10n.text("暂无可用重置卡", "No reset cards reported yet."))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    }
                    .padding(.vertical, 16)
                    Spacer()
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(dashboardCredits) { credit in
                        ResetCreditCardRowView(credit: credit, state: state, isCompact: true)
                    }

                    if dashboardCredits.isEmpty && missingDetailCount > 0 {
                        ResetCreditDetailsPendingRowView(count: missingDetailCount, isCompact: true)
                    }
                }
            }
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    private var resetCreditCountText: String {
        if state.resetCreditAvailableCount > 0 {
            let key = state.resetCreditAvailableCount == 1 ? "%d available reset card" : "%d available reset cards"
            return L10n.format(key, zhHans: "%d 张可用重置卡", state.resetCreditAvailableCount)
        }
        return L10n.text("无可用卡", "No cards")
    }

    private func availableCardCountText(_ count: Int) -> String {
        L10n.format("%d available", zhHans: "%d 张可用", count)
    }

    private func nearestDeadlineText(_ date: String) -> String {
        L10n.format("Nearest deadline: %@", zhHans: "最近截止: %@", date)
    }
}

// MARK: - 套餐胶囊
private struct PlanPillView: View {
    @Environment(\.colorScheme) var colorScheme
    let plan: String?

    var body: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let blue = AppTheme.accentBlue(for: colorScheme)

        HStack(spacing: 6) {
            Circle()
                .fill(cyan)
                .frame(width: 6, height: 6)
                .shadow(color: cyan.opacity(colorScheme == .dark ? 0.8 : 0.4), radius: 3)

            Text(L10n.text("套餐", "Plan"))
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(cyan)

            Text((plan ?? "UNKNOWN").uppercased())
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            LinearGradient(
                colors: [cyan.opacity(colorScheme == .dark ? 0.2 : 0.12), blue.opacity(colorScheme == .dark ? 0.12 : 0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: Capsule()
        )
        .overlay(
            Capsule()
                .strokeBorder(cyan.opacity(0.4), lineWidth: 1)
        )
    }
}
