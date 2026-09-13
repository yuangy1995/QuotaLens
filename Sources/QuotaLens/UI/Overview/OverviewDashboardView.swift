import SwiftUI
import Charts

@MainActor
final class OverviewDashboardStore: ObservableObject {
    @Published private(set) var analyses: [UsageProvider: OverviewAnalysis] = [:]
    @Published private(set) var errors: Set<UsageProvider> = []
    @Published private(set) var loading = false
    @Published private(set) var updatedAt: Date?
    private let facade: UsageQueryFacade
    private var generation = 0

    init(facade: UsageQueryFacade) { self.facade = facade }

    func load(days: Int, providers: [UsageProvider]) async {
        generation += 1
        let request = generation
        loading = true
        analyses = [:]
        errors = []
        let now = Date()
        var result: [UsageProvider: OverviewAnalysis] = [:]
        var failures: Set<UsageProvider> = []
        for provider in providers {
            do { result[provider] = try await facade.getOverviewAnalysis(days: days, provider: provider, now: now) }
            catch { failures.insert(provider) }
            guard !Task.isCancelled, request == generation else { return }
        }
        analyses = result
        errors = failures
        updatedAt = now
        loading = false
    }
}

struct OverviewSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(scheme == .dark ? Color(white: 0.115) : .white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }
}

public struct OverviewDashboardView: View {
    @ObservedObject private var state: AppState
    @StateObject private var store: OverviewDashboardStore
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.colorScheme) private var scheme
    @State private var days = 7
    @State private var peek: OverviewQuotaPeekSelection?
    let page: OverviewPage
    private let onSelectTool: (MonitoringToolID, ToolPage) -> Void

    public init(state: AppState, facade: UsageQueryFacade, page: OverviewPage = .summary,
                onSelectTool: @escaping (MonitoringToolID, ToolPage) -> Void) {
        self.state = state
        self.page = page
        self.onSelectTool = onSelectTool
        _store = StateObject(wrappedValue: OverviewDashboardStore(facade: facade))
    }
    private var providers: [UsageProvider] { env.enabledToolsStore.enabledDescriptors.map(\.usageProvider) }
    private var loadID: String { "\(page.rawValue)|\(days)|" + providers.map(\.rawValue).joined(separator: ",") }
    private func accounts(_ provider: UsageProvider) -> CodexAccountsStore {
        provider == .codex ? env.codexAccounts : provider == .claude ? env.claudeAccounts : env.antigravityAccounts
    }
    private func open(_ provider: UsageProvider, _ page: ToolPage) {
        onSelectTool(MonitoringToolID(rawValue: provider.rawValue), page)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if page == .distribution {
                        AppSegmentedPicker(selection: $days, options: [1, 7, 30]) { day in
                            day == 1 ? L10n.text("今天", "Today")
                                : day == 7 ? L10n.text("近 7 天", "Last 7 days") : L10n.text("近 30 天", "Last 30 days")
                        }.frame(width: 250)
                            .accessibilityLabel(L10n.text("时间范围", "Time range"))
                    }
                    Button {
                        Task {
                            if page != .distribution {
                                for provider in providers { await accounts(provider).refreshAvailableAccounts() }
                            }
                            await reload()
                        }
                    } label: { Image(systemName: "arrow.clockwise") }
                    .help(L10n.text("刷新", "Refresh"))
                }
                switch page {
                case .summary:
                    ForEach(providers) { provider in
                        OverviewSummaryCard(accounts: accounts(provider),
                            usage: store.analyses[provider]?.current,
                            onOpen: { peek = .init(provider: provider, accountKey: nil) })
                    }
                    ForEach(providers) { provider in OverviewAccountNotices(accounts: accounts(provider), maximumItems: 3) }
                case .resources:
                    ForEach(providers) { provider in
                        OverviewResourceGroup(state: state, accounts: accounts(provider)) { key in
                            peek = .init(provider: provider, accountKey: key)
                        }
                    }
                case .distribution:
                    if store.loading { ProgressView().frame(maxWidth: .infinity).padding(40) }
                    else {
                        if !store.errors.isEmpty {
                            Text(store.errors.sorted { $0.rawValue < $1.rawValue }.map(\.localizedName).joined(separator: ", ")
                                + " · " + L10n.text("本地统计读取失败，请重试。", "Local statistics could not be loaded. Try again."))
                                .foregroundStyle(.orange)
                        }
                        GlobalDistributionPanel(analyses: store.analyses, onOpen: open)
                    }
                }
            }
            .padding(24).frame(maxWidth: 1360).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(scheme == .dark ? Color(white: 0.075) : Color(white: 0.965))
        .foregroundStyle(.primary)
        .sheet(item: $peek) { selection in
            OverviewQuotaPeek(accounts: accounts(selection.provider), accountKey: selection.accountKey)
        }
        .buttonStyle(AppActionButtonStyle())
        .tint(AppTheme.accentCyan(for: scheme))
        .task(id: loadID) { await reload() }
        .onReceive(env.scanCoordinator.$isScanning.removeDuplicates().dropFirst()) { scanning in
            if !scanning { Task { await reload() } }
        }
        .onChange(of: env.claudeScanCoordinator.isScanning) { _, scanning in
            if !scanning { Task { await reload() } }
        }
        .onChange(of: env.antigravityActivityCoordinator.isScanning) { _, scanning in
            if !scanning { Task { await reload() } }
        }
    }
    private var subtitle: String {
        switch page {
        case .summary: return L10n.text("先看需要关注的事，详情可在当前页面查看。", "See what needs attention. View details without leaving this page.")
        case .resources: return L10n.text("跨工具查看账号；点击详情不会离开当前页面。", "View accounts across tools. Details open without leaving this page.")
        case .distribution: return L10n.text("比较本机使用分布，不重复工具内的明细页面。", "Compare local usage across tools without duplicating their detail pages.")
        }
    }
    private func reload() async {
        guard page != .resources else { return }
        await store.load(days: page == .summary ? 1 : days, providers: providers)
    }
}
