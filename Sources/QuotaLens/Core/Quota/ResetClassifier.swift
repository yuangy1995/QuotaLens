// QuotaLens 额度重置与重锚定事件分类器
// 严格遵循实施计划 12.3 节规则，精确分类重置原因

import Foundation

public enum ResetType: String, Sendable {
    case normalReset = "normal_reset"
    case earnedReset = "earned_reset"
    case serverReanchor = "server_reanchor_unknown"
    case reportingCorrection = "reporting_correction"
    case meterPolicyChanged = "meter_policy_changed"
    case none = "none"
}

public struct ResetClassifier: Sendable {
    /// 对前后两次快照判定是否发生重置及重置类别
    public static func classify(
        previous: RateLimitSnapshotRecord,
        current: RateLimitSnapshotRecord,
        hasResetCreditEvidence: Bool = false
    ) -> (ResetType, String) {
        // 1. 检查 limitId 或窗口长度是否改变
        if previous.limitId != current.limitId ||
            previous.windowDurationMins != current.windowDurationMins ||
            previous.planType != current.planType {
            return (.meterPolicyChanged, "额度池或窗口长度发生结构性变更: \(previous.limitId) -> \(current.limitId)")
        }

        guard let oldResetsAt = previous.resetsAt, let newResetsAt = current.resetsAt else {
            return (.none, "重置时间戳不足")
        }

        let oldPercent = Double(previous.usedPercentMilli) / 1000.0
        let newPercent = Double(current.usedPercentMilli) / 1000.0
        let percentDrop = oldPercent - newPercent

        // 如果百分比没有显著下降且重置时间没变
        if percentDrop < 2.0 && oldResetsAt == newResetsAt {
            return (.none, "额度正常消耗或微小波动")
        }

        // 如果百分比微跌但重置时间未变 -> 统计小幅修正
        if percentDrop > 0 && oldResetsAt == newResetsAt {
            return (.reportingCorrection, "服务端用量微幅修正 (跌幅 \(String(format: "%.1f", percentDrop))%)")
        }

        // 如果 resetsAt 发生变更
        if oldResetsAt != newResetsAt {
            let durationSeconds = Int64((current.windowDurationMins ?? 10080) * 60)
            let isNearOldReset = abs(current.observedAt - oldResetsAt) < 3600 * 2

            if isNearOldReset && abs((newResetsAt - oldResetsAt) - durationSeconds) < 3600 * 2 {
                return (.normalReset, "达到自然周期边界，正常重置并开启新自然周期")
            } else if hasResetCreditEvidence && percentDrop >= 2.0 {
                return (.earnedReset, "检测到重置券证据，额度已重置")
            } else if percentDrop >= 2.0 {
                return (.serverReanchor, "重置时间改变且额度下降；未检测到重置券证据，按服务端重新锚定处理")
            } else {
                return (.serverReanchor, "重置时间改变但额度下降证据不足；按服务端重新锚定待复核")
            }
        }

        return (.none, "无重置变化")
    }
}
