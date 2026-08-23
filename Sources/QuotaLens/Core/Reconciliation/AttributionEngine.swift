// QuotaLens 三本账数据归因与日对账引擎
// 严格区分：账户总账、本机/多Mac明细账、额度账

import Foundation

public struct DailyReconciliationResult: Sendable, Identifiable {
    public var id: String { serverStartDate }
    public let serverStartDate: String
    public let accountTotalTokens: Int64
    public let localAttributedTokens: Int64
    public let syncedAttributedTokens: Int64
    public let totalAttributedTokens: Int64
    public let unattributedTokens: Int64
    public let reconciliationDeltaTokens: Int64
    public let coveragePpm: Int // 百万分比 (例如 580000 = 58.0%)
    public let state: DailyDataState
    public let isReconciled: Bool
}

public struct AttributionEngine: Sendable {
    /// 对指定日期桶进行归因与对账计算
    public static func reconcileDay(
        snapshot: AccountDailySnapshotRecord,
        events: [UsageEventRecord],
        isCurrentDay: Bool
    ) -> DailyReconciliationResult {
        var localTokens: Int64 = 0
        var syncedTokens: Int64 = 0

        for ev in events {
            if ev.source == "synced" {
                syncedTokens += ev.totalTokens
            } else {
                localTokens += ev.totalTokens
            }
        }

        let totalAttributed = localTokens + syncedTokens
        let accountTotal = snapshot.totalTokens
        let delta = accountTotal - totalAttributed
        let unattributed = max(0, delta)

        let coveragePpm: Int
        if accountTotal > 0 {
            let ratio = Double(totalAttributed) / Double(accountTotal)
            coveragePpm = min(1_000_000, Int(ratio * 1_000_000))
        } else {
            coveragePpm = 0
        }

        let tolerance = max(Int64(100_000), Int64(Double(accountTotal) * 0.001))
        let isReconciled = abs(delta) <= tolerance

        let state: DailyDataState
        if isCurrentDay {
            state = .live
        } else if !isReconciled {
            state = .pendingReconciliation
        } else {
            state = snapshot.dataState == .reopened ? .reopened : .finalized
        }

        return DailyReconciliationResult(
            serverStartDate: snapshot.serverStartDate,
            accountTotalTokens: accountTotal,
            localAttributedTokens: localTokens,
            syncedAttributedTokens: syncedTokens,
            totalAttributedTokens: totalAttributed,
            unattributedTokens: unattributed,
            reconciliationDeltaTokens: delta,
            coveragePpm: coveragePpm,
            state: state,
            isReconciled: isReconciled
        )
    }
}
