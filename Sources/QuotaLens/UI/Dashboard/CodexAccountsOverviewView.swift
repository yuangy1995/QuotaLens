import SwiftUI

struct CodexAccountsOverviewView: View {
    @ObservedObject var state: AppState
    @ObservedObject var accounts: CodexAccountsStore
    @State private var editingName = false
    @State private var name = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                CodexViewingAccountPicker(state: state, accounts: accounts)
                if !accounts.selectedKey.isEmpty {
                    Button(L10n.text("备注", "Rename")) {
                        name = accounts.name(for: accounts.selectedKey, state: state)
                        editingName = true
                    }
                }
                Spacer()
                if accounts.isAuthorizing {
                    ProgressView().controlSize(.small)
                    Button(L10n.text("取消", "Cancel")) { Task { await accounts.cancelAuthorization() } }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            if accounts.selectedKey.isEmpty {
                if accounts.isAuthorizing || accounts.error != nil { authorizationStatus.padding(.horizontal, 24) }
                ContentUnavailableView(L10n.text("添加并验证账号后查看实时额度", "Add and verify an account to view live quota"),
                                       systemImage: "person.crop.circle.badge.plus")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(accounts.name(for: accounts.selectedKey, state: state)).font(.title2.bold())
                                Text(accounts.accounts.first { $0.accountKey == accounts.selectedKey }?.source == .independent
                                    ? L10n.text("已独立授权", "Independently authorized")
                                    : L10n.text("已验证的导入凭据", "Verified imported credentials"))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                Task { await accounts.loadSelection(refresh: true) }
                            } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel(L10n.text("刷新", "Refresh"))
                            .disabled(!isAuthorized || accounts.isRefreshing)
                            if accounts.isRefreshing { ProgressView().controlSize(.small) }
                        }
                        Text(L10n.text("仅切换查询身份，不改变工具登录。", "Only the query identity changes, not the tool login."))
                            .font(.callout).foregroundStyle(.secondary)
                        authorizationStatus
                        if accounts.snapshots.isEmpty {
                            ContentUnavailableView(L10n.text("暂无额度数据", "No quota data"), systemImage: "gauge.with.needle")
                        }
                        ForEach(accounts.snapshots.indices, id: \.self) { index in
                            quotaRow(accounts.snapshots[index])
                        }
                    }.padding(24)
                }
            }
        }
        .task(id: accounts.selectedKey) {
            await accounts.loadSelection(refresh: true)
            while !Task.isCancelled, !accounts.selectedKey.isEmpty {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                await accounts.loadSelection(refresh: true)
            }
        }
        .alert(L10n.text("备注", "Rename"), isPresented: $editingName) {
            TextField(L10n.text("备注", "Rename"), text: $name)
            Button(L10n.text("保存", "Save")) { accounts.rename(accounts.selectedKey, to: name, state: state) }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
        }
    }

    private var isAuthorized: Bool { accounts.accounts.contains { $0.accountKey == accounts.selectedKey && $0.status == .available } }

    @ViewBuilder private var authorizationStatus: some View {
        if accounts.isAuthorizing {
            Text(L10n.text("请在浏览器中完成账号授权。", "Complete account authorization in your browser."))
        }
        if let error = accounts.error { Text(error).foregroundStyle(.red) }
    }

    private func quotaRow(_ snapshot: RateLimitSnapshotRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(snapshot.limitId).font(.headline)
                if let minutes = snapshot.windowDurationMins {
                    Text(Duration.seconds(minutes * 60).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let plan = snapshot.planType { Text(plan.uppercased()).font(.caption.bold()) }
            }
            if snapshot.isCurrentQuotaWindow(at: Int64(Date().timeIntervalSince1970)) {
                Text(L10n.format("Remaining: %.0f%%", zhHans: "剩余可用：%.0f%%", 100 - Double(snapshot.usedPercentMilli) / 1000))
                    .font(.title.bold())
                ProgressView(value: max(0, min(100, 100 - Double(snapshot.usedPercentMilli) / 1000)), total: 100)
            } else {
                Text(L10n.text("快照已过期，请刷新后查看当前额度。", "This snapshot has expired. Refresh to see the current quota."))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(L10n.text("更新时间", "Updated"))
                Text(Date(timeIntervalSince1970: Double(snapshot.observedAt)), format: .dateTime)
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }
}
