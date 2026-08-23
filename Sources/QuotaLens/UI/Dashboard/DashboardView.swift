// QuotaLens 科技风全息总览仪表盘视图 (Dual Theme Dashboard)

import SwiftUI

public struct DashboardView: View {
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) var colorScheme

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // 顶部标题与状态栏
                headerHUDBar

                // 核心 Hero 主控舱：周额度全息仪表与数据流
                Group {
                    if state.hasQuotaSnapshot {
                        quotaHeroHUDCard
                    } else {
                        quotaUnavailableHUDCard
                    }
                }

                // 指标矩阵
                telemetryMetricsMatrix

                // 重置卡列表
                resetCreditsHangarView
            }
            .padding(24)
        }
        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
    }

    // MARK: - 顶部标题栏
    private var headerHUDBar: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(L10n.text("概览", "Overview"))
                        .font(.system(.title, design: .rounded, weight: .black))
                        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                }

                Text(L10n.text("监测当前账号额度消耗与重置周期", "Monitor quota usage and reset windows for the current account."))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }

            Spacer()

            HStack(spacing: 12) {
                // 高对比度科技风分段控制器
                CyberSegmentedPicker(selection: Binding(
                    get: { state.quotaDisplayMode },
                    set: { state.setQuotaDisplayMode($0) }
                ))

                StatusBadge.forConnection(state.connectionStatus)

                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.2.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(cyan)
                    Text(L10n.format("Sync: %@", zhHans: "同步: %@", state.formatTime(state.lastRefreshTime)))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
                )
            }
        }
    }

    // MARK: - 核心配额卡片
    private var quotaHeroHUDCard: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        return VStack(alignment: .leading, spacing: 18) {
            // 顶部小标头
            HStack {
                CyberSectionHeader(
                    tag: "01",
                    title: L10n.text("额度概览", "Quota Overview"),
                    icon: "gauge.with.needle.fill"
                )

                Spacer()

                PlanPillView(plan: state.subscriptionPlanTitle)
            }

            CyberDivider()

            HStack(spacing: 32) {
                // 全息双环表盘
                CircularProgressView(
                    progress: state.displayedQuotaProgress,
                    riskProgress: state.quotaRiskProgress,
                    lineWidth: 16,
                    size: 160,
                    title: state.quotaDisplayMode.ringTitle,
                    valueText: state.displayedQuotaPercentString,
                    subtitle: "\(state.quotaDisplayMode.complementLabel) \(state.complementQuotaPercentString)"
                )

                // 结构化指标网格
                VStack(alignment: .leading, spacing: 14) {
                    // 主额度遥测大字卡
                    HStack(spacing: 28) {
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

                        Spacer()
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

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                CyberSectionHeader(
                    tag: "02",
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

            if state.resetCredits.isEmpty {
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
                    ForEach(state.resetCredits) { credit in
                        ResetCreditHangarRow(credit: credit, state: state)
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

// MARK: - 重置卡行卡片
private struct ResetCreditHangarRow: View {
    @Environment(\.colorScheme) var colorScheme
    let credit: ResetCreditDisplay
    let state: AppState

    var body: some View {
        let amber = AppTheme.accentAmber(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)
        let iconColor = credit.isAvailable ? amber : AppTheme.textSecondary(for: colorScheme)

        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(iconColor.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    .frame(width: 32, height: 32)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(iconColor.opacity(0.35), lineWidth: 0.8)
                    )

                Image(systemName: "ticket.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(credit.displayTitle)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                    let statusColor = credit.isAvailable ? emerald : AppTheme.textSecondary(for: colorScheme)
                    Text(statusText(credit))
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(statusColor.opacity(colorScheme == .dark ? 0.15 : 0.10), in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(statusColor.opacity(0.35), lineWidth: 0.8)
                        )
                }

                Text(L10n.format("Granted %@  ~  Expires %@", zhHans: "获取 %@  ~  截止 %@", displayDate(credit.grantedAt), displayDate(credit.expiresAt)))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }

            Spacer()

            if credit.isAvailable, let expiresAt = credit.expiresAt {
                let diff = expiresAt - Int64(Date().timeIntervalSince1970)
                if diff > 0 {
                    let days = diff / 86400
                    Text(L10n.format("%d days left", zhHans: "剩余 %d 天", Int(days)))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(amber)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(amber.opacity(colorScheme == .dark ? 0.15 : 0.10), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(amber.opacity(0.4), lineWidth: 0.8)
                        )
                }
            }
        }
        .padding(10)
        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
        )
    }

    private func displayDate(_ timestamp: Int64?) -> String {
        guard let timestamp else { return L10n.text("未知", "Unknown") }
        return state.formatFullDate(timestamp)
    }

    private func statusText(_ credit: ResetCreditDisplay) -> String {
        switch (credit.status ?? "").lowercased() {
        case "available": return L10n.text("可用", "Available")
        case "used": return L10n.text("已用", "Used")
        case "expired": return L10n.text("已过期", "Expired")
        default: return L10n.text("已记录", "Recorded")
        }
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
