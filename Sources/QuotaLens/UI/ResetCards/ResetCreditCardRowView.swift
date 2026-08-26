import SwiftUI

public struct ResetCreditCardRowView: View {
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject public var state: AppState
    public let credit: ResetCreditDisplay
    public var isCompact: Bool
    public var isConsuming: Bool
    public var onUse: (() -> Void)?

    public init(
        credit: ResetCreditDisplay,
        state: AppState,
        isCompact: Bool = false,
        isConsuming: Bool = false,
        onUse: (() -> Void)? = nil
    ) {
        self.credit = credit
        self.state = state
        self.isCompact = isCompact
        self.isConsuming = isConsuming
        self.onUse = onUse
    }

    public var body: some View {
        let amber = AppTheme.accentAmber(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)

        HStack(alignment: .center, spacing: 14) {
            iconView(color: amber)

            VStack(alignment: .leading, spacing: isCompact ? 3 : 5) {
                HStack(spacing: 8) {
                    Text(credit.displayTitle)
                        .font(.system(size: isCompact ? 13 : 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                        .lineLimit(1)

                    statusBadge(color: emerald)
                }

                if isCompact {
                    Text(dateRangeText)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        .lineLimit(1)
                } else {
                    HStack(spacing: 14) {
                        dateField(
                            icon: "tray.and.arrow.down.fill",
                            title: L10n.text("获取", "Granted"),
                            value: displayDate(credit.grantedAt)
                        )

                        dateField(
                            icon: "clock.badge.exclamationmark.fill",
                            title: L10n.text("过期", "Expires"),
                            value: displayDate(credit.expiresAt)
                        )
                    }
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    remainingBadge(color: amber, now: context.date)
                }

                if let onUse {
                    Button(action: onUse) {
                        HStack(spacing: 5) {
                            Image(systemName: isConsuming ? "hourglass" : "bolt.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text(isConsuming ? L10n.text("使用中", "Using") : L10n.text("立即使用", "Use Now"))
                                .font(.system(size: 11, weight: .heavy, design: .rounded))
                        }
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            LinearGradient(
                                colors: [amber, Color(red: 0.92, green: 0.42, blue: 0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isConsuming)
                    .help(L10n.text("使用这张重置卡", "Use this reset card"))
                }
            }
        }
        .padding(isCompact ? 10 : 14)
        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
        )
    }

    private func iconView(color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(colorScheme == .dark ? 0.18 : 0.12))
                .frame(width: isCompact ? 32 : 36, height: isCompact ? 32 : 36)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(color.opacity(0.35), lineWidth: 0.8)
                )

            Image(systemName: "ticket.fill")
                .font(.system(size: isCompact ? 14 : 15, weight: .bold))
                .foregroundStyle(color)
        }
    }

    private func statusBadge(color: Color) -> some View {
        Text(L10n.text("可用", "Available"))
            .font(.system(size: 10, weight: .heavy, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(color.opacity(colorScheme == .dark ? 0.15 : 0.10), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(color.opacity(0.35), lineWidth: 0.8)
        )
    }

    private func remainingBadge(color: Color, now: Date) -> some View {
        Text(remainingText(now: now))
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(colorScheme == .dark ? 0.15 : 0.10), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(color.opacity(0.4), lineWidth: 0.8)
            )
            .monospacedDigit()
    }

    private func dateField(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(AppTheme.accentCyan(for: colorScheme))

            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))

            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme).opacity(0.88))
                .monospacedDigit()
        }
    }

    private var dateRangeText: String {
        L10n.format(
            "Granted %@  ~  Expires %@",
            zhHans: "获取 %@  ~  截止 %@",
            displayDate(credit.grantedAt),
            displayDate(credit.expiresAt)
        )
    }

    private func remainingText(now: Date) -> String {
        guard let expiresAt = credit.expiresAt else {
            return L10n.text("长期有效", "No expiry")
        }

        let diff = expiresAt - Int64(now.timeIntervalSince1970)
        if diff <= 0 {
            return L10n.text("即将过期", "Expiring")
        }
        return L10n.format("%@ left", zhHans: "剩余 %@", state.preciseDurationString(seconds: diff))
    }

    private func displayDate(_ timestamp: Int64?) -> String {
        guard let timestamp else { return L10n.text("未知", "Unknown") }
        return state.formatFullDate(timestamp)
    }
}

public struct ResetCreditDetailsPendingRowView: View {
    @Environment(\.colorScheme) private var colorScheme
    public let count: Int
    public var isCompact: Bool

    public init(count: Int, isCompact: Bool = false) {
        self.count = count
        self.isCompact = isCompact
    }

    public var body: some View {
        let amber = AppTheme.accentAmber(for: colorScheme)
        let cyan = AppTheme.accentCyan(for: colorScheme)

        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(amber.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    .frame(width: isCompact ? 32 : 36, height: isCompact ? 32 : 36)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(amber.opacity(0.35), lineWidth: 0.8)
                    )

                Image(systemName: "ticket.fill")
                    .font(.system(size: isCompact ? 14 : 15, weight: .bold))
                    .foregroundStyle(amber)
            }

            VStack(alignment: .leading, spacing: isCompact ? 3 : 5) {
                HStack(spacing: 8) {
                    Text(titleText)
                        .font(.system(size: isCompact ? 13 : 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                    Text(L10n.text("可用", "Available"))
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundStyle(AppTheme.accentEmerald(for: colorScheme))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(AppTheme.accentEmerald(for: colorScheme).opacity(colorScheme == .dark ? 0.15 : 0.10), in: Capsule())
                }

                Text(L10n.text("后台已确认可用，卡片明细正在同步", "Availability confirmed; card details are syncing"))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(cyan)
                .padding(8)
                .background(cyan.opacity(colorScheme == .dark ? 0.15 : 0.10), in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(isCompact ? 10 : 14)
        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
        )
    }

    private var titleText: String {
        if count == 1 {
            return L10n.text("重置卡", "Reset card")
        }
        return L10n.format("%d reset cards", zhHans: "%d 张重置卡", count)
    }
}

public struct ResetCreditUseNotice: Identifiable {
    public let id = UUID()
    public let title: String
    public let message: String
}

public struct ResetCreditUseAlertModifier: ViewModifier {
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var state: AppState
    @Binding var pendingCredit: ResetCreditDisplay?
    @Binding var consumingCreditId: String?
    @State private var notice: ResetCreditUseNotice?

    public func body(content: Content) -> some View {
        content
            .overlay {
                if pendingCredit != nil || notice != nil {
                    ZStack {
                        // 柔和毛玻璃暗化背景
                        Color.black.opacity(colorScheme == .dark ? 0.62 : 0.40)
                            .ignoresSafeArea()
                            .onTapGesture {
                                if consumingCreditId == nil {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                        pendingCredit = nil
                                        notice = nil
                                    }
                                }
                            }

                        if let credit = pendingCredit {
                            ResetCreditUseConfirmDialog(
                                title: L10n.text("确认使用重置卡？", "Use this reset card?"),
                                message: confirmMessage(for: credit),
                                credit: credit,
                                remainingPercent: state.hasQuotaSnapshot ? state.currentRemainingPercent : nil,
                                remainingPercentString: state.currentRemainingPercentString,
                                isConsuming: consumingCreditId == credit.id,
                                onCancel: {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                        pendingCredit = nil
                                    }
                                },
                                onConfirm: {
                                    consume(credit)
                                }
                            )
                        } else if let notice {
                            ResetCreditUseNoticeDialog(
                                notice: notice,
                                onDismiss: {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                        self.notice = nil
                                    }
                                }
                            )
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: pendingCredit?.id)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: notice?.id)
    }

    private func confirmMessage(for credit: ResetCreditDisplay) -> String {
        // 规则 1: 如果剩余额度不是 0, 那么文案就是: 当前剩余可用额度还有xx%, 你确定要使用重置卡吗?
        if state.hasQuotaSnapshot, state.currentRemainingPercent > 0 {
            return L10n.format(
                "Current remaining available quota is %@. Are you sure you want to use a reset card?",
                zhHans: "当前剩余可用额度还有 %@，你确定要使用重置卡吗？",
                state.currentRemainingPercentString
            )
        }

        // 规则 2: 如果额度为 0 了, 距离自然重置时间不到 2 天了, 则文案是: 距离自然重置还剩余x天x小时x分x秒, 是否继续使用重置卡?
        if state.hasQuotaSnapshot,
           state.currentRemainingPercent <= 0,
           let resetsAt = state.latestRateLimit?.resetsAt {
            let diff = resetsAt - Int64(Date().timeIntervalSince1970)
            if diff > 0 && diff < 172_800 {
                return L10n.format(
                    "Natural reset is in %@. Continue using a reset card?",
                    zhHans: "距离自然重置还剩余 %@，是否继续使用重置卡？",
                    state.preciseDurationString(seconds: diff)
                )
            }
        }

        // 规则 3: 其他时候文案就是: 你确定要使用重置卡吗?
        return L10n.text("你确定要使用重置卡吗？", "Are you sure you want to use a reset card?")
    }

    private func consume(_ credit: ResetCreditDisplay) {
        pendingCredit = nil
        consumingCreditId = credit.id

        Task { @MainActor in
            defer {
                if consumingCreditId == credit.id {
                    consumingCreditId = nil
                }
            }

            do {
                let outcome = try await env.consumeResetCredit(credit)
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    notice = notice(for: outcome)
                }
            } catch {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    notice = ResetCreditUseNotice(
                        title: L10n.text("使用失败", "Use Failed"),
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func notice(for outcome: ConsumeRateLimitResetCreditOutcome) -> ResetCreditUseNotice {
        switch outcome {
        case .reset:
            return ResetCreditUseNotice(
                title: L10n.text("重置卡已使用", "Reset Card Used"),
                message: L10n.text("额度已重置，正在同步最新状态。", "Quota was reset and the latest state is syncing.")
            )
        case .nothingToReset:
            return ResetCreditUseNotice(
                title: L10n.text("当前无需重置", "Nothing to Reset"),
                message: L10n.text("当前额度窗口不符合重置条件，重置卡未被使用。", "No current rate-limit window is eligible, so the reset card was not used.")
            )
        case .noCredit:
            return ResetCreditUseNotice(
                title: L10n.text("没有可用重置卡", "No Reset Card Available"),
                message: L10n.text("后台返回当前没有可用重置卡。", "The backend reported that no reset card is currently available.")
            )
        case .alreadyRedeemed:
            return ResetCreditUseNotice(
                title: L10n.text("请求已完成", "Request Already Completed"),
                message: L10n.text("同一次使用请求此前已经成功完成。", "This same use request had already completed successfully.")
            )
        }
    }
}

private struct ResetCreditUseConfirmDialog: View {
    @Environment(\.colorScheme) var colorScheme
    let title: String
    let message: String
    let credit: ResetCreditDisplay
    let remainingPercent: Double?
    let remainingPercentString: String
    let isConsuming: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        let amber = AppTheme.accentAmber(for: colorScheme)
        let orange = Color(red: 0.94, green: 0.44, blue: 0.05)
        let isDark = colorScheme == .dark

        VStack(alignment: .leading, spacing: 16) {
            // 1. Header (立体发光图标 + 标题/副标 + 右上角关闭按钮)
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [amber, orange],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.4), lineWidth: 1.0)
                        )
                        .shadow(color: amber.opacity(isDark ? 0.45 : 0.25), radius: 8, x: 0, y: 3)

                    Image(systemName: "ticket.fill")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                    Text(L10n.text("重置卡核销与额度更新", "Reset Card Consumption"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }

                Spacer()

                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        .frame(width: 26, height: 26)
                        .background(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(isConsuming)
            }

            CyberDivider(glowColor: amber.opacity(0.25))

            // 2. 核心提示文案卡片 (根据 3 条规则精确生成的 message)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(amber)
                    .padding(.top, 1)

                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(amber.opacity(isDark ? 0.35 : 0.22), lineWidth: 0.8)
            )

            // 3. 待使用重置卡信息卡
            HStack(spacing: 10) {
                Image(systemName: "ticket.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(amber)

                Text(credit.displayTitle)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                Spacer()

                if let expiresAt = credit.expiresAt {
                    Text(displayRemaining(expiresAt))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(AppTheme.insetSurface(for: colorScheme).opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
            )

            // 4. 底部操作按钮组
            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text(L10n.text("取消", "Cancel"))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
                        )
                        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                }
                .buttonStyle(.plain)
                .disabled(isConsuming)

                Button(action: onConfirm) {
                    HStack(spacing: 6) {
                        if isConsuming {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 11, weight: .bold))
                        }
                        Text(isConsuming ? L10n.text("使用中...", "Using...") : L10n.text("确认使用", "Use Now"))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        LinearGradient(
                            colors: [amber, orange],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .shadow(color: amber.opacity(isDark ? 0.35 : 0.22), radius: 6, x: 0, y: 2)
                    .foregroundStyle(Color.white)
                }
                .buttonStyle(.plain)
                .disabled(isConsuming)
            }
        }
        .padding(22)
        .frame(width: 420)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isDark ? Color(red: 0.085, green: 0.105, blue: 0.165) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(amber.opacity(isDark ? 0.38 : 0.28), lineWidth: 1.0)
        )
        .shadow(color: Color.black.opacity(isDark ? 0.55 : 0.22), radius: 28, x: 0, y: 14)
    }

    private func displayRemaining(_ expiresAt: Int64) -> String {
        let diff = expiresAt - Int64(Date().timeIntervalSince1970)
        if diff <= 0 {
            return L10n.text("即将过期", "Expiring")
        }
        let days = diff / 86400
        let hours = (diff % 86400) / 3600
        if days > 0 {
            return "\(days)d \(hours)h"
        }
        let mins = (diff % 3600) / 60
        return "\(hours)h \(mins)m"
    }
}

private struct ResetCreditUseNoticeDialog: View {
    @Environment(\.colorScheme) var colorScheme
    let notice: ResetCreditUseNotice
    let onDismiss: () -> Void

    var body: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)
        let isDark = colorScheme == .dark

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [emerald, cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.4), lineWidth: 1.0)
                        )
                        .shadow(color: emerald.opacity(isDark ? 0.45 : 0.25), radius: 8, x: 0, y: 3)

                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title)
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                    Text(L10n.text("重置卡核销与额度更新", "Reset Card Consumption"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        .frame(width: 26, height: 26)
                        .background(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
            }

            CyberDivider(glowColor: emerald.opacity(0.25))

            Text(notice.message)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme).opacity(0.9))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
                )

            Button(action: onDismiss) {
                Text(L10n.text("知道了", "OK"))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        LinearGradient(
                            colors: [cyan, AppTheme.accentBlue(for: colorScheme)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .shadow(color: cyan.opacity(isDark ? 0.35 : 0.22), radius: 6, x: 0, y: 2)
                    .foregroundStyle(Color.white)
            }
            .buttonStyle(.plain)
        }
        .padding(22)
        .frame(width: 400)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isDark ? Color(red: 0.085, green: 0.105, blue: 0.165) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(cyan.opacity(isDark ? 0.38 : 0.28), lineWidth: 1.0)
        )
        .shadow(color: Color.black.opacity(isDark ? 0.55 : 0.22), radius: 28, x: 0, y: 14)
    }
}

public extension View {
    func resetCreditUseAlerts(
        state: AppState,
        pendingCredit: Binding<ResetCreditDisplay?>,
        consumingCreditId: Binding<String?>
    ) -> some View {
        modifier(ResetCreditUseAlertModifier(
            state: state,
            pendingCredit: pendingCredit,
            consumingCreditId: consumingCreditId
        ))
    }
}
