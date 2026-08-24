// QuotaLens 服务器额度耗尽预测引擎 (Theil-Sen 中位斜率 + 加权最小二乘)

import Foundation

public enum QuotaForecastEngine {
    public struct RateSnapshotPoint: Sendable {
        public let timestamp: Date
        public let usedPercent: Double

        public init(timestamp: Date, usedPercent: Double) {
            self.timestamp = timestamp
            self.usedPercent = usedPercent
        }
    }

    /// 评估服务器在线配额耗尽预测
    public static func forecast(
        currentUsedPercent: Double,
        resetsAt: Int64?,
        snapshots: [RateSnapshotPoint],
        now: Date = Date()
    ) -> QuotaForecastDTO {
        guard let resetsAt = resetsAt else {
            return QuotaForecastDTO(risk: .insufficientData, confidence: .insufficientData)
        }

        let resetDate = Date(timeIntervalSince1970: Double(resetsAt))
        let secondsUntilReset = resetDate.timeIntervalSince(now)
        guard secondsUntilReset > 0 else {
            return QuotaForecastDTO(
                risk: .onTrack,
                confidence: .medium,
                naturalResetDate: resetDate
            )
        }

        let hoursUntilReset = secondsUntilReset / 3600.0
        let remainingPercent = max(0.0, 100.0 - currentUsedPercent)
        let evenPaceSlopePerHour = remainingPercent / max(0.1, hoursUntilReset)

        // 过滤有效数据点（按时间升序）
        let sorted = snapshots.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count >= 2,
              let first = sorted.first,
              let last = sorted.last else {
            return QuotaForecastDTO(
                risk: .insufficientData,
                confidence: .insufficientData,
                naturalResetDate: resetDate
            )
        }

        let timeSpanSeconds = last.timestamp.timeIntervalSince(first.timestamp)
        guard timeSpanSeconds >= 900 else { // 至少需要 15 分钟跨度
            return QuotaForecastDTO(
                risk: .insufficientData,
                confidence: .insufficientData,
                naturalResetDate: resetDate,
                samplePointsCount: sorted.count
            )
        }

        // 1. 计算所有点对的 Theil-Sen 斜率 (% / hour)
        var slopes: [Double] = []
        for i in 0..<sorted.count {
            for j in (i + 1)..<sorted.count {
                let dtHours = sorted[j].timestamp.timeIntervalSince(sorted[i].timestamp) / 3600.0
                guard dtHours >= 0.05 else { continue }
                let dy = sorted[j].usedPercent - sorted[i].usedPercent
                let slope = dy / dtHours
                // 仅统计单调消耗 (>= 0)
                if slope >= 0 {
                    slopes.append(slope)
                }
            }
        }

        let medianSlopePerHour: Double
        if slopes.isEmpty {
            medianSlopePerHour = 0.0
        } else {
            slopes.sort()
            let mid = slopes.count / 2
            medianSlopePerHour = slopes.count % 2 == 0 ? (slopes[mid - 1] + slopes[mid]) / 2.0 : slopes[mid]
        }

        // 2. Pace Ratio 与耗尽时间评估
        let effectiveBurnRate = max(0.0, medianSlopePerHour)
        let paceRatio: Double = evenPaceSlopePerHour > 0 ? (effectiveBurnRate / evenPaceSlopePerHour) : 1.0

        var hoursUntilExhaustion: Double? = nil
        var exhaustionDate: Date? = nil
        if effectiveBurnRate > 0.01 {
            let h = remainingPercent / effectiveBurnRate
            hoursUntilExhaustion = h
            exhaustionDate = now.addingTimeInterval(h * 3600.0)
        }

        // 3. 计算在自然重置时的预计剩余额度
        let projectedUsageUntilReset = effectiveBurnRate * hoursUntilReset
        let projectedRemainingAtReset = max(0.0, min(100.0, remainingPercent - projectedUsageUntilReset))

        // 4. 风险与置信度裁决
        let risk: QuotaForecastRisk
        if let h = hoursUntilExhaustion, h < hoursUntilReset {
            risk = .critical
        } else if paceRatio > 1.25 {
            risk = .warning
        } else if paceRatio >= 0.75 {
            risk = .onTrack
        } else {
            risk = .underPaced
        }

        let confidence: ForecastConfidence
        if sorted.count >= 10 && timeSpanSeconds >= 86400 {
            confidence = .high
        } else if sorted.count >= 4 && timeSpanSeconds >= 14400 {
            confidence = .medium
        } else {
            confidence = .low
        }

        return QuotaForecastDTO(
            risk: risk,
            confidence: confidence,
            burnRatePercentPerHour: effectiveBurnRate,
            paceRatio: paceRatio,
            estimatedExhaustionDate: exhaustionDate,
            naturalResetDate: resetDate,
            hoursUntilExhaustion: hoursUntilExhaustion,
            projectedRemainingAtReset: projectedRemainingAtReset,
            samplePointsCount: sorted.count
        )
    }
}
