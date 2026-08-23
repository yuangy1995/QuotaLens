// QuotaLens 线程快照差分与用量增量切片计算器
// 严格遵循第 6.3 节规则：首次发现旧线程仅建立基线(baseline_only)，不误记到当前时刻

import Foundation

public struct DifferResult: Sendable {
    public let newEvents: [UsageEventRecord]
    public let updatedSnapshots: [ThreadUsageSnapshotRecord]
}

public struct UsageSnapshotDiffer: Sendable {
    /// 对新抓取的一组线程快照与上一轮基线进行差分计算
    public static func diffSnapshots(
        currentSnapshots: [ThreadUsageSnapshotRecord],
        previousSnapshotsMap: [String: ThreadUsageSnapshotRecord],
        activeMeterVersionId: String?,
        currentCycleId: String?
    ) -> DifferResult {
        var events: [UsageEventRecord] = []
        var nextSnapshots: [ThreadUsageSnapshotRecord] = []

        for current in currentSnapshots {
            nextSnapshots.append(current)

            guard let previous = previousSnapshotsMap[current.threadId] else {
                // 首次发现该线程：仅作为基线记录 (baseline_only)，不产生增量用量事件
                continue
            }

            if current.inputTokens < previous.inputTokens ||
                current.cachedInputTokens < previous.cachedInputTokens ||
                current.outputTokens < previous.outputTokens ||
                current.totalTokens < previous.totalTokens {
                continue
            }

            // 计算增量
            let deltaInput = max(0, current.inputTokens - previous.inputTokens)
            let deltaCachedInput = max(0, current.cachedInputTokens - previous.cachedInputTokens)
            let deltaOutput = max(0, current.outputTokens - previous.outputTokens)
            let deltaTotal = max(0, current.totalTokens - previous.totalTokens)

            // 如果有增量发生
            if deltaTotal > 0 || deltaInput > 0 || deltaOutput > 0 {
                let quality = allocationQuality(previousObservedAt: previous.observedAt, currentObservedAt: current.observedAt)
                let canBindVersions = quality == "exact"
                let event = UsageEventRecord(
                    eventId: UUID().uuidString,
                    deviceId: current.deviceId,
                    intervalStart: previous.observedAt,
                    intervalEnd: current.observedAt,
                    threadId: current.threadId,
                    modelRaw: current.modelRaw,
                    modelCanonical: current.modelCanonical,
                    reasoningEffort: current.reasoningEffort,
                    serviceTier: current.serviceTier,
                    inputTokens: deltaInput,
                    cachedInputTokens: deltaCachedInput,
                    outputTokens: deltaOutput,
                    totalTokens: deltaTotal > 0 ? deltaTotal : (deltaInput + deltaCachedInput + deltaOutput),
                    meterVersionId: canBindVersions ? activeMeterVersionId : nil,
                    cycleId: currentCycleId,
                    allocationQuality: quality,
                    source: "app_server"
                )
                events.append(event)
            }
        }

        return DifferResult(newEvents: events, updatedSnapshots: nextSnapshots)
    }

    private static func allocationQuality(previousObservedAt: Int64, currentObservedAt: Int64) -> String {
        guard currentObservedAt > previousObservedAt else {
            return "ambiguous_interval"
        }

        let previousDate = Date(timeIntervalSince1970: Double(previousObservedAt))
        let currentDate = Date(timeIntervalSince1970: Double(currentObservedAt))
        if !Calendar.current.isDate(previousDate, inSameDayAs: currentDate) {
            return "ambiguous_interval"
        }

        if currentObservedAt - previousObservedAt > 3600 {
            return "ambiguous_interval"
        }

        return "exact"
    }
}
