import SwiftUI

struct OverviewQuotaPeekSelection: Identifiable {
    let provider: UsageProvider
    let accountKey: String?
    var id: String { provider.rawValue + ":" + (accountKey ?? "all") }
}

/// A read-only presentation of the existing quota snapshots. Opening it does not
/// change the selected query account, navigation route, filters or scroll position.
struct OverviewQuotaPeek: View {
    @ObservedObject var accounts: CodexAccountsStore
    let accountKey: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                ToolAppIcon(tool: MonitoringToolID(rawValue: accounts.provider.rawValue), size: 26)
                Text(accounts.provider.localizedName + " · " + L10n.text("额度详情", "Quota details")).font(.headline)
                Spacer()
                Button(L10n.text("关闭", "Close")) { dismiss() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(accounts.accounts.filter { account in accountKey == nil ? account.canQuery : account.accountKey == accountKey }) { account in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(account.name).font(.headline).textSelection(.enabled)
                            HStack {
                                Text(account.statusMessage)
                                Spacer()
                                if let date = account.verifiedAt {
                                    Text(L10n.text("最近验证", "Last verified"))
                                    Text(date, format: .dateTime)
                                }
                            }.font(.caption).foregroundStyle(.secondary)
                            ForEach(Array((accounts.accountSnapshots[account.accountKey] ?? []).enumerated()), id: \.offset) { _, row in
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack {
                                        Text(OverviewQuotaSummary.title(row)).font(.callout)
                                        Spacer()
                                        if row.isCurrentQuotaWindow(at: Int64(Date().timeIntervalSince1970)) {
                                            Text(UsageNumberFormatter.percent(row.remainingPercent)).monospacedDigit()
                                        } else { Text(L10n.text("使用缓存", "Cached data")).foregroundStyle(.secondary) }
                                    }
                                    ProgressView(value: row.remainingPercent, total: 100)
                                    if let reset = row.resetsAt {
                                        HStack {
                                            Text(L10n.text("重置", "Reset"))
                                            Text(Date(timeIntervalSince1970: Double(reset)), format: .dateTime)
                                        }.font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            if let error = accounts.accountErrors[account.accountKey] {
                                Text(error).font(.callout).foregroundStyle(.orange)
                            }
                        }.modifier(OverviewSurface())
                    }
                }
            }
        }
        .padding(20).frame(width: 680, height: 500)
        .background(scheme == .dark ? Color(white: 0.075) : Color(white: 0.965))
        .buttonStyle(AppActionButtonStyle())
        .tint(AppTheme.accentCyan(for: scheme))
    }
}
