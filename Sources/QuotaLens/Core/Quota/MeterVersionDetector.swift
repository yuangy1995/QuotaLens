// QuotaLens 计量版本探测器

import Foundation

public struct MeterVersionDetector: Sendable {
    public static let initialMeterVersionId = "meter-2026-07-v1"

    /// 评估是否需要创建新计量版本
    public static func evaluateMeterVersionChange(
        currentMeterVersion: MeterVersionRecord?,
        limitIdChanged: Bool,
        windowDurationChanged: Bool,
        slopeDriftDetected: Bool,
        reason: String?
    ) -> MeterVersionRecord? {
        let now = Int64(Date().timeIntervalSince1970)

        if limitIdChanged || windowDurationChanged {
            let newId = "meter-\(now)-structural"
            return MeterVersionRecord(
                meterVersionId: newId,
                effectiveFrom: now,
                effectiveTo: nil,
                reason: reason ?? "额度结构变更",
                source: "server_rate_limits",
                confidence: "high"
            )
        }

        if slopeDriftDetected {
            let newId = "meter-\(now)-slope"
            return MeterVersionRecord(
                meterVersionId: newId,
                effectiveFrom: now,
                effectiveTo: nil,
                reason: reason ?? "回归消耗斜率显著偏移",
                source: "regression_detector",
                confidence: "medium"
            )
        }

        return nil
    }
}
