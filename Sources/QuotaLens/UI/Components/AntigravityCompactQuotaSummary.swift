import SwiftUI

struct AntigravityCompactQuotaSummary: View {
    @ObservedObject var state: AppState
    var onToggleMode: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let onToggleMode {
                Button(action: onToggleMode) {
                    content
                }
                .buttonStyle(.plain)
                .help(L10n.text("点击切换已用和可用视角", "Click to switch between used and available"))
            } else {
                content
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var content: some View {
        let buckets = state.latestAntigravityQuota?.orderedCompactFiveHourBuckets ?? []
        return HStack(spacing: 4) {
            Text(state.quotaDisplayMode.shortTitle)
            Text("5h")
            if buckets.isEmpty {
                Text("--")
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            } else {
                ForEach(Array(buckets.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Text("·")
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    }
                    let shown = state.quotaDisplayMode == .used
                        ? max(0, 100 - item.bucket.remainingPercent)
                        : item.bucket.remainingPercent
                    Text("\(item.shortTitle) \(UsageNumberFormatter.percent(shown, maximumFractionDigits: 0))")
                        .foregroundStyle(quotaColor(for: item.bucket.remainingPercent))
                        .help(tooltip(for: item, shown: shown))
                }
            }
        }
        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
        .monospacedDigit()
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
    }

    private var accessibilityLabel: String {
        guard let quota = state.latestAntigravityQuota else {
            return L10n.text("Antigravity 5 小时额度暂无数据", "Antigravity 5-hour quota is not available")
        }
        let buckets = quota.orderedCompactFiveHourBuckets
        guard !buckets.isEmpty else {
            return L10n.text("Antigravity 5 小时额度暂无数据", "Antigravity 5-hour quota is not available")
        }
        let values = buckets.map { item in
            let shown = state.quotaDisplayMode == .used
                ? max(0, 100 - item.bucket.remainingPercent)
                : item.bucket.remainingPercent
            return tooltip(for: item, shown: shown)
        }.joined(separator: "\n")
        return "Antigravity\n" + values
    }

    private func tooltip(
        for item: AntigravityQuotaSnapshot.CompactFiveHourBucket,
        shown: Double
    ) -> String {
        L10n.format(
            "%@ · 5-hour %@: %@",
            zhHans: "%@ · 5 小时%@：%@",
            item.displayTitle,
            state.quotaDisplayMode.shortTitle,
            UsageNumberFormatter.percent(shown, maximumFractionDigits: 2)
        )
    }

    private func quotaColor(for remaining: Double) -> Color {
        if remaining <= 15 { return AppTheme.accentRose(for: colorScheme) }
        if remaining <= 35 { return AppTheme.accentAmber(for: colorScheme) }
        return AppTheme.accentEmerald(for: colorScheme)
    }
}
