import SwiftUI
import Charts

enum OverviewQuotaSummary {
    static func window(_ rows: [RateLimitSnapshotRecord], now: Date = Date()) -> RateLimitSnapshotRecord? {
        rows.filter { $0.isCurrentQuotaWindow(at: Int64(now.timeIntervalSince1970)) }
            .min { $0.remainingPercent < $1.remainingPercent }
    }
    static func title(_ row: RateLimitSnapshotRecord) -> String {
        if row.limitId != "codex" { return row.limitId }
        switch row.windowDurationMins {
        case 300: return L10n.text("5 小时额度", "5-hour quota")
        case 10080: return L10n.text("周额度", "Weekly quota")
        default: return row.windowDurationMins.map { "\($0) min" } ?? L10n.text("额度", "Quota")
        }
    }
}

struct OverviewSummaryCard: View {
    @ObservedObject var accounts: CodexAccountsStore
    let usage: DashboardMetricsDTO?
    let onOpen: () -> Void
    var body: some View {
        HStack(spacing: 18) {
            ToolAppIcon(tool: MonitoringToolID(rawValue: accounts.provider.rawValue), size: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(accounts.provider.localizedName).font(.headline)
                Text(L10n.format("%lld accounts", zhHans: "%lld 个账号", Int64(accounts.accounts.filter(\.canQuery).count)))
                    .foregroundStyle(.secondary).font(.caption)
            }
            Spacer()
            if accounts.accounts.contains(where: { !$0.canQuery }) {
                Text(L10n.text("有账号待验证或需要重新授权", "Some accounts need verification or reauthorization"))
                    .font(.callout).foregroundStyle(.orange)
            }
            VStack(alignment: .trailing, spacing: 6) {
                Text(L10n.text("今天", "Today")).font(.caption).foregroundStyle(.secondary)
                Text(usage.map { UsageNumberFormatter.compactTokenCount($0.totalTokens.canonicalTotalTokens) + " Tokens" } ?? "—")
                    .monospacedDigit()
            }
            Button(L10n.text("查看详情", "View details"), action: onOpen)
        }.modifier(OverviewSurface())
        .buttonStyle(AppActionButtonStyle())
        .task { await accounts.refreshAvailableAccounts() }
    }
}

struct OverviewResourceGroup: View {
    @ObservedObject var state: AppState
    @ObservedObject var accounts: CodexAccountsStore
    var automaticallyRefresh = true
    let onView: (String) -> Void
    @State private var managing = false

    private var activeKey: String? {
        switch accounts.provider {
        case .codex: return state.account?.accountKey
        case .claude: return state.latestClaudeUsage?.accountKey
        case .antigravity: return state.latestAntigravityQuota?.accountKey
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ToolAppIcon(tool: MonitoringToolID(rawValue: accounts.provider.rawValue), size: 24)
                Text(accounts.provider.localizedName).font(.headline)
                Spacer()
                if accounts.isRefreshing { ProgressView().controlSize(.small) }
                Button(L10n.text("账号管理", "Account management")) { managing = true }
            }
            if accounts.accounts.filter(\.canQuery).isEmpty {
                Text(L10n.text("添加并验证账号后查看实时额度", "Add and verify an account to view live quota"))
                    .foregroundStyle(.secondary)
            }
            ForEach(accounts.accounts.filter(\.canQuery)) { account in
                Divider()
                let rows = accounts.accountSnapshots[account.accountKey] ?? []
                let row = OverviewQuotaSummary.window(rows)
                let stale = accounts.accountErrors[account.accountKey] != nil
                    || account.verifiedAt.map { Date().timeIntervalSince($0) > 300 } ?? true
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(account.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 8) {
                            if let plan = rows.first?.planType { Text(plan.uppercased()) }
                            if activeKey == account.accountKey { Text(L10n.text("工具当前使用", "Active in tool")) }
                            if accounts.selectedKey == account.accountKey { Text(L10n.text("正在查看", "Viewing")) }
                        }.font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 5) {
                        if let row {
                            Text(UsageNumberFormatter.percent(row.remainingPercent, maximumFractionDigits: 0)).monospacedDigit()
                            Text(OverviewQuotaSummary.title(row)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else { Text("—") }
                    }.frame(width: 185, alignment: .trailing)
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(stale ? L10n.text("使用缓存", "Cached data") : L10n.text("已验证", "Verified"))
                            .foregroundStyle(stale ? Color.orange : Color.secondary)
                        if let date = account.verifiedAt { Text(date, style: .relative).foregroundStyle(.secondary) }
                    }.font(.caption).frame(width: 70, alignment: .trailing)
                    Button(L10n.text("查看详情", "View details")) { onView(account.accountKey) }
                }.padding(.vertical, 5)
            }
            if accounts.accounts.contains(where: { !$0.canQuery }) {
                Button(L10n.text("有账号待验证或需要重新授权", "Some accounts need verification or reauthorization")) { managing = true }
                    .buttonStyle(.plain).foregroundStyle(.orange).font(.caption)
            }
        }.modifier(OverviewSurface())
        .buttonStyle(AppActionButtonStyle())
        .sheet(isPresented: $managing) { QueryAccountsManagerView(state: state, accounts: accounts) }
        .task {
            guard automaticallyRefresh else { return }
            while !Task.isCancelled {
                await accounts.refreshAvailableAccounts()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }
}

enum DistributionDimension: String, CaseIterable, Identifiable {
    case tools, projects, models
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tools: return L10n.text("工具", "Tools")
        case .projects: return L10n.text("项目", "Projects")
        case .models: return L10n.text("模型", "Models")
        }
    }
}

struct GlobalUsageRow: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    var tokens: Int64
    var previousTokens: Int64?
    var providers: Set<UsageProvider>
}

enum GlobalUsageDistribution {
    static func rows(_ analyses: [UsageProvider: OverviewAnalysis], dimension: DistributionDimension) -> [GlobalUsageRow] {
        var result: [String: GlobalUsageRow] = [:]
        for (provider, analysis) in analyses {
            switch dimension {
            case .tools:
                result[provider.rawValue] = .init(id: provider.rawValue, title: provider.localizedName,
                    subtitle: L10n.text("本地记录", "Local records"), tokens: analysis.current.totalTokens.canonicalTotalTokens,
                    previousTokens: analysis.previous.totalTokens.canonicalTotalTokens, providers: [provider])
            case .models:
                for name in Set(analysis.current.modelDistribution.map(\.modelCanonical) + analysis.previous.modelDistribution.map(\.modelCanonical)) {
                    let id = provider.rawValue + ":" + name
                    result[id] = .init(id: id, title: name, subtitle: provider.localizedName,
                        tokens: analysis.current.modelDistribution.first { $0.modelCanonical == name }?.tokens.canonicalTotalTokens ?? 0,
                        previousTokens: analysis.previous.modelDistribution.first { $0.modelCanonical == name }?.tokens.canonicalTotalTokens ?? 0,
                        providers: [provider])
                }
            case .projects:
                guard analysis.contributionsAvailable else { continue }
                let current = analysis.projects
                let previous = analysis.previousProjects
                let projectIDs = Set(current.map(\.id) + (previous?.map(\.id) ?? []))
                for projectID in projectIDs {
                    guard let project = current.first(where: { $0.id == projectID }) ?? previous?.first(where: { $0.id == projectID }) else { continue }
                    let tokens = current.first { $0.id == projectID }?.tokens ?? 0
                    let prior = previous.map { $0.first { $0.id == projectID }?.tokens ?? 0 }
                    let id = project.path ?? "unassigned:" + provider.rawValue
                    if var row = result[id] {
                        row.tokens += tokens
                        if let old = row.previousTokens, let prior { row.previousTokens = old + prior }
                        else { row.previousTokens = nil }
                        row.providers.insert(provider)
                        result[id] = row
                    } else {
                        result[id] = .init(id: id, title: project.title, subtitle: project.path ?? provider.localizedName,
                            tokens: tokens, previousTokens: prior, providers: [provider])
                    }
                }
            }
        }
        return result.values.sorted { $0.tokens == $1.tokens ? $0.id < $1.id : $0.tokens > $1.tokens }
    }
}

struct GlobalDistributionPanel: View {
    let analyses: [UsageProvider: OverviewAnalysis]
    let onOpen: (UsageProvider, ToolPage) -> Void
    @State private var dimension: DistributionDimension = .tools
    @State private var search = ""
    @State private var expanded = false
    @State private var sortByChange = false
    @Environment(\.colorScheme) private var scheme
    private var rows: [GlobalUsageRow] {
        let values = GlobalUsageDistribution.rows(analyses, dimension: dimension).filter {
            search.isEmpty || ($0.title + $0.subtitle).localizedCaseInsensitiveContains(search)
        }
        guard sortByChange else { return values }
        return values.sorted { left, right in
            let a = left.previousTokens.map { left.tokens - $0 } ?? Int64.min
            let b = right.previousTokens.map { right.tokens - $0 } ?? Int64.min
            return a == b ? left.id < right.id : a > b
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                AppSegmentedPicker(selection: $dimension, options: DistributionDimension.allCases, title: { $0.title })
                    .frame(width: 260)
                Spacer()
                TextField(L10n.text("搜索", "Search"), text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            Text(L10n.text("按已记录的 Tokens 比较，不代表工具能力或完整云端用量。", "Compare recorded tokens, not tool quality or complete cloud usage."))
                .font(.callout).foregroundStyle(.secondary)
            Toggle(L10n.text("按变化排序", "Sort by change"), isOn: $sortByChange).toggleStyle(.switch).controlSize(.small)
            if let first = analyses.values.first {
                HStack {
                    Text(first.period.start, format: .dateTime.month().day())
                    Text("—")
                    Text(first.period.end, format: .dateTime.month().day().hour().minute())
                }.font(.caption).foregroundStyle(.secondary)
            }
            if dimension == .projects, analyses.values.contains(where: { !$0.contributionsAvailable }) {
                Text(L10n.text("明细与汇总暂未对齐，请刷新后重试。", "Details and totals are not aligned yet. Refresh and try again."))
                    .foregroundStyle(.orange)
            }
            if rows.isEmpty {
                Text(L10n.text("暂无本地用量记录", "No local usage records")).foregroundStyle(.secondary).padding(.vertical, 30)
            } else {
                if rows.count > 1 {
                Chart(Array(rows.prefix(8))) { row in
                    BarMark(x: .value("Tokens", row.tokens), y: .value("Source", row.id))
                        .foregroundStyle(Color.accentColor.opacity(0.8)).cornerRadius(3)
                }
                .chartYScale(domain: Array(rows.prefix(8).map(\.id).reversed()))
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let count = value.as(Double.self) {
                                Text(count, format: .number.notation(.compactName).locale(L10n.locale))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let id = value.as(String.self), let row = rows.first(where: { $0.id == id }) {
                                Text(dimension == .tools ? row.title : row.title + " · " + row.providers.map(\.localizedName).sorted().joined(separator: ", "))
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .frame(height: CGFloat(min(rows.count, 8)) * 34 + 30)
                }
                HStack {
                    Text(dimension.title).font(.headline)
                    Spacer()
                    Text(L10n.text("记录用量", "Recorded usage")).frame(width: 95, alignment: .trailing)
                    Text(L10n.text("上期同期", "Previous matched period")).frame(width: 95, alignment: .trailing)
                    Text(L10n.text("查看详情", "View details")).frame(width: 140)
                }.font(.caption).foregroundStyle(.secondary)
                ForEach(Array(rows.prefix(expanded ? rows.count : 12))) { row in
                    Divider()
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.title).font(.callout).lineLimit(1)
                            Text(row.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(UsageNumberFormatter.compactTokenCount(row.tokens)).monospacedDigit().frame(width: 95, alignment: .trailing)
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(row.previousTokens.map(UsageNumberFormatter.compactTokenCount) ?? "—")
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 95, alignment: .trailing)
                            if let previous = row.previousTokens {
                                let change = row.tokens - previous
                                Text((change >= 0 ? "+" : "−") + UsageNumberFormatter.compactTokenCount(abs(change)))
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        Menu(L10n.text("在工具中查看", "Open in tool")) {
                            ForEach(row.providers.sorted { $0.rawValue < $1.rawValue }) { provider in
                                Button(provider.localizedName) { onOpen(provider, dimension == .projects ? .sessions : .usage) }
                            }
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.visible)
                        .modifier(AppActionSurface()).fixedSize()
                        .frame(width: 140)
                    }
                }
                if rows.count > 12 {
                    Button(expanded ? L10n.text("收起", "Collapse") : L10n.text("查看全部明细", "View all details")) { expanded.toggle() }
                }
            }
        }.modifier(OverviewSurface())
        .buttonStyle(AppActionButtonStyle())
        .tint(AppTheme.accentCyan(for: scheme))
        .onChange(of: dimension) { _, _ in search = ""; expanded = false }
    }
}
