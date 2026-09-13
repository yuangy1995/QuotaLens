import SwiftUI

struct OverviewMetricLayout: Layout {
    static func columnCount(width: CGFloat) -> Int { width >= 850 ? 4 : 2 }
    private let spacing: CGFloat = 16

    private func dimensions(width: CGFloat, subviews: Subviews) -> (Int, CGFloat, [CGFloat]) {
        let columns = Self.columnCount(width: width)
        let cell = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        var heights: [CGFloat] = []
        for start in stride(from: 0, to: subviews.count, by: columns) {
            let height = (start..<min(start + columns, subviews.count)).map {
                subviews[$0].sizeThatFits(.init(width: cell, height: nil)).height
            }.max() ?? 0
            heights.append(height)
        }
        return (columns, cell, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        let (_, _, heights) = dimensions(width: width, subviews: subviews)
        return .init(width: width, height: heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (columns, cell, heights) = dimensions(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (cell + spacing), y: y),
                    anchor: .topLeading, proposal: .init(width: cell, height: height))
            }
            y += height + spacing
        }
    }
}

struct OverviewAccountNotices: View {
    @ObservedObject var accounts: CodexAccountsStore
    var maximumItems: Int = 6

    var body: some View {
        let items = notices()
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(accounts.provider.localizedName + " · " + L10n.text("待关注", "Needs attention")).font(.headline)
                ForEach(Array(items.prefix(maximumItems)), id: \.self) { item in
                    Label(item, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
            }.modifier(OverviewSurface())
        }
    }

    private func notices(now: Date = Date()) -> [String] {
        var result: [String] = []
        for account in accounts.accounts {
            if !account.canQuery {
                result.append(account.name + " · " + account.statusMessage)
                continue
            }
            if accounts.accountErrors[account.accountKey] != nil {
                result.append(account.name + " · " + L10n.text("查询失败，保留上次成功结果", "Query failed; last successful result retained"))
                continue
            }
            guard let verified = account.verifiedAt, now.timeIntervalSince(verified) <= 300 else {
                result.append(account.name + " · " + L10n.text("使用缓存", "Cached data"))
                continue
            }
            let windows = (accounts.accountSnapshots[account.accountKey] ?? []).filter {
                $0.isCurrentQuotaWindow(at: Int64(now.timeIntervalSince1970))
            }
            if let low = windows.min(by: { $0.remainingPercent < $1.remainingPercent }), low.remainingPercent <= 25 {
                result.append(account.name + " · " + L10n.text("额度偏低", "Quota running low") + " " + UsageNumberFormatter.percent(low.remainingPercent))
            }
            if let reset = windows.compactMap(\.resetsAt).min(),
               Double(reset) - now.timeIntervalSince1970 <= 86400 {
                result.append(account.name + " · " + L10n.text("即将重置", "Upcoming reset") + " · "
                    + Date(timeIntervalSince1970: Double(reset)).formatted(date: .abbreviated, time: .shortened))
            }
        }
        return Array(Set(result)).sorted()
    }
}
