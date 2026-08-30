import SwiftUI

public struct ResetCardsView: View {
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) var colorScheme
    @State private var pendingCredit: ResetCreditDisplay?
    @State private var consumingCreditId: String?

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                summaryCards
                resetCardsList
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

    private var summaryCards: some View {
        HStack(spacing: 14) {
            ResetCardSummaryTile(
                title: L10n.text("可用重置卡", "Available Reset Cards"),
                value: availableCountText(state.resetCreditAvailableCount),
                icon: "ticket.fill",
                color: state.resetCreditAvailableCount > 0 ? AppTheme.accentAmber(for: colorScheme) : AppTheme.textSecondary(for: colorScheme)
            )

            ResetCardSummaryTile(
                title: L10n.text("最近过期", "Nearest Expiry"),
                value: nearestExpiryText,
                icon: "clock.badge.exclamationmark.fill",
                color: state.nearestValidResetCredit == nil ? AppTheme.textSecondary(for: colorScheme) : AppTheme.accentAmber(for: colorScheme)
            )
        }
    }

    private var resetCardsList: some View {
        let amber = AppTheme.accentAmber(for: colorScheme)
        let validCredits = state.validResetCredits
        let missingDetailCount = state.resetCreditMissingDetailCount

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                CyberSectionHeader(
                    title: L10n.text("有效重置卡", "Valid Reset Cards"),
                    icon: "ticket.fill"
                )

                Text(availableCountText(state.resetCreditAvailableCount))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(amber)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(amber.opacity(colorScheme == .dark ? 0.15 : 0.10), in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(amber.opacity(0.35), lineWidth: 0.8)
                    )

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.2.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.accentCyan(for: colorScheme))
                    Text(state.codexSyncStatusText)
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

            CyberDivider(glowColor: amber.opacity(0.3))

            if validCredits.isEmpty && missingDetailCount == 0 {
                emptyState
            } else {
                VStack(spacing: 10) {
                    ForEach(validCredits) { credit in
                        ResetCreditCardRowView(
                            credit: credit,
                            state: state,
                            isConsuming: consumingCreditId == credit.id
                        ) {
                            pendingCredit = credit
                        }
                    }

                    if missingDetailCount > 0 {
                        ResetCreditDetailsPendingRowView(count: missingDetailCount)
                    }
                }
            }
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 9) {
                Image(systemName: "ticket")
                    .font(.system(size: 34))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme).opacity(0.48))

                Text(L10n.text("暂无有效重置卡", "No valid reset cards"))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                Text(emptyStateDetail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }
            .padding(.vertical, 28)
            Spacer()
        }
    }

    private var emptyStateDetail: String {
        if state.resetCreditAvailableCount > 0 {
            return L10n.text("后台只返回了数量，暂未返回可展示的卡片明细。", "The backend returned only a count and no displayable card details yet.")
        }
        return L10n.text("后台当前没有返回有效期内的可用重置卡。", "The backend is not currently returning any available reset card within its validity period.")
    }

    private var nearestExpiryText: String {
        guard let expiresAt = state.nearestValidResetCredit?.expiresAt else {
            return L10n.text("无", "None")
        }
        return state.formatFullDate(expiresAt)
    }

    private func availableCountText(_ count: Int) -> String {
        if count == 1 {
            return L10n.text("1 张可用", "1 available")
        }
        return L10n.format("%d available", zhHans: "%d 张可用", count)
    }
}

private struct ResetCardSummaryTile: View {
    @Environment(\.colorScheme) var colorScheme
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 26, height: 26)
                    .background(color.opacity(colorScheme == .dark ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(color.opacity(colorScheme == .dark ? 0.45 : 0.3), lineWidth: 0.8)
                    )

                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))

                Spacer()
            }

            Text(value)
                .font(.system(.title2, design: .rounded, weight: .heavy))
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.74)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cyberCard(cornerRadius: 12, padding: 14)
    }
}
