import SwiftUI

struct ResetCreditHistoryPanel: View {
    @ObservedObject var store: ResetCreditHistoryStore
    let refresh: () -> Void
    let loadMore: () -> Void
    @State private var onlyUsed = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                CyberSectionHeader(title: L10n.text("重置卡历史", "Reset card history"), icon: "clock.arrow.circlepath")
                Spacer()
                Toggle(L10n.text("仅已使用", "Used only"), isOn: $onlyUsed).toggleStyle(.checkbox)
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .help(L10n.text("刷新", "Refresh")).disabled(store.loading)
            }
            if let start = store.windowStart, let end = store.asOf {
                HStack {
                    Text(L10n.text("接口历史范围", "API history window"))
                    Text(start, format: .dateTime.year().month().day())
                    Text("—")
                    Text(end, format: .dateTime.year().month().day())
                }.font(.caption).foregroundStyle(.secondary)
            }
            Text(L10n.text("历史仅供查看，不会消耗或恢复重置卡。", "History is read-only; it does not consume or restore reset cards."))
                .font(.caption).foregroundStyle(.secondary)
            if let error = store.error { Text(error).font(.callout).foregroundStyle(.orange) }
            if store.loading { ProgressView().controlSize(.small) }
            let events = store.events.filter { !onlyUsed || $0.isUsed }
            if events.isEmpty, !store.loading, store.error == nil, store.asOf != nil {
                Text(L10n.text("当前范围内没有重置卡历史", "No reset card history in this window"))
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
            }
            ForEach(events) { event in
                HStack(spacing: 12) {
                    Image(systemName: event.isUsed ? "checkmark.circle" : "ticket")
                        .foregroundStyle(event.isUsed ? AppTheme.textSecondary(for: scheme) : AppTheme.accentAmber(for: scheme))
                    Text(event.title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(event.occurredAt, format: .dateTime.year().month().day().hour().minute())
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                .padding(12)
                .background(AppTheme.insetSurface(for: scheme), in: RoundedRectangle(cornerRadius: 8))
            }
            if store.nextCursor != nil {
                Button(L10n.text("加载更多", "Load more"), action: loadMore).disabled(store.loading)
            }
        }.cyberCard(cornerRadius: 16, padding: 18)
    }
}
