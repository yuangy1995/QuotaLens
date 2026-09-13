import SwiftUI

struct DiagnosticIssueTarget: Identifiable {
    enum Kind { case antigravity, history(UsageProvider), storage }
    let kind: Kind
    let message: String
    var id: String {
        switch kind {
        case .antigravity: return "antigravity-scan"
        case .history(let provider): return provider.rawValue + "-history"
        case .storage: return "storage"
        }
    }
}

struct ScanProblemDetailsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var coordinator: AntigravityActivityScanCoordinator
    let target: DiagnosticIssueTarget
    let retry: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var retrying = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.text("问题详情", "Problem details")).font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.text("关闭", "Close")) { dismiss() }
            }
            switch target.kind {
            case .antigravity:
                AntigravityScanProblems(coordinator: coordinator, retry: retry)
            case .history(let provider):
                Text(provider.localizedName + " · " + L10n.text("历史记录", "History")).font(.headline)
                Text(state.historyWarningText(for: provider) ?? L10n.text("该问题当前未再报告。", "This issue is no longer being reported."))
                    .textSelection(.enabled)
                Text(L10n.text("当前未提供具体失败来源数量，不能据此显示为 0。", "The affected source count is unavailable; it must not be shown as zero."))
                    .font(.callout).foregroundStyle(.secondary)
                Button(L10n.text("重新读取", "Retry reading")) {
                    retrying = true
                    Task { await retry(); retrying = false }
                }.disabled(retrying)
                if retrying { ProgressView().controlSize(.small) }
                Spacer()
            case .storage:
                Text(target.message).textSelection(.enabled)
                Text(L10n.text("这是启动时的存储问题；重新启动可再次检查。不会自动清空数据库。", "This is a startup storage issue. Restart to check again; the database will not be cleared automatically."))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(24).frame(width: 740, height: 540, alignment: .topLeading)
            .buttonStyle(AppActionButtonStyle())
    }
}

struct AntigravityScanProblems: View {
    @ObservedObject var coordinator: AntigravityActivityScanCoordinator
    let retry: () async -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Antigravity · " + L10n.text("扫描问题", "Scan issues")).font(.headline)
                Spacer()
                if coordinator.isScanning { ProgressView().controlSize(.small) }
                Button(L10n.text("重新读取", "Retry reading")) { Task { await retry() } }
                    .disabled(coordinator.isScanning)
            }
            HStack(spacing: 20) {
                count(L10n.text("读取失败来源", "Unreadable sources"), kind: .read)
                count(L10n.text("格式不兼容来源", "Incompatible sources"), kind: .format)
                Spacer()
                if let date = coordinator.diagnostics.checkedAt {
                    VStack(alignment: .trailing) {
                        Text(L10n.text("最近检查", "Last checked"))
                        Text(date, format: .dateTime.month().day().hour().minute().second())
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
            if coordinator.diagnostics.checkedAt == nil {
                Text(L10n.text("尚未检查，不代表没有问题。", "Not checked yet; this does not mean there are no issues."))
                    .font(.callout).foregroundStyle(.secondary)
            } else if !coordinator.diagnostics.sourcesFound {
                Text(L10n.text("本次未找到可读取来源，已有缓存未重新验证。", "No readable sources were found; existing cached data was not revalidated."))
                    .font(.callout).foregroundStyle(.secondary)
            } else if coordinator.diagnostics.issues.isEmpty {
                Text(L10n.text("本次 Antigravity 扫描未报告问题。", "This Antigravity scan reported no issues."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text(L10n.text("以下来源未完整更新，相关统计保留上次结果。", "These sources were not fully updated; related statistics retain the last result."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !coordinator.diagnostics.issues.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(coordinator.diagnostics.issues) { issue in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(issue.source?.lastPathComponent ?? L10n.text("扫描未完成", "Scan incomplete"))
                                .font(.headline)
                            if let source = issue.source {
                                Text(source.path).font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Text(issue.reason).font(.callout).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.frame(maxHeight: 320)
            }
        }.buttonStyle(AppActionButtonStyle())
    }
    private func count(_ title: String, kind: LocalScanIssue.Kind) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(coordinator.diagnostics.checkedAt == nil ? L10n.text("未检查", "Not checked")
                 : coordinator.diagnostics.count(kind).map(String.init) ?? L10n.text("未知", "Unknown"))
                .font(.headline).monospacedDigit()
        }
    }
}
