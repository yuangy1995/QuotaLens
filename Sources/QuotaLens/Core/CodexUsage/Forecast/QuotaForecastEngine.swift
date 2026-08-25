// QuotaLens 服务器额度耗尽预测引擎 (Theil-Sen 中位斜率 + 加权最小二乘)

import Foundation

public enum QuotaForecastEngine {
    public struct QuotaCycleKey: Hashable, Sendable {
        public let accountID: String
        public let limitID: String
        public let slot: String
        public let resetAt: Int64

        public init(accountID: String, limitID: String, slot: String, resetAt: Int64) {
            self.accountID = accountID
            self.limitID = limitID
            self.slot = slot
            self.resetAt = resetAt
        }
    }

    public struct RateSnapshotPoint: Sendable {
        public let timestamp: Date
        public let usedPercent: Double
        public let cycleKey: QuotaCycleKey

        public init(timestamp: Date, usedPercent: Double, cycleKey: QuotaCycleKey) {
            self.timestamp = timestamp
            self.usedPercent = usedPercent
            self.cycleKey = cycleKey
        }
    }

    /// 评估服务器在线配额耗尽预测
    public static func forecast(
        currentUsedPercent: Double,
        resetsAt: Int64?,
        currentCycleKey: QuotaCycleKey?,
        snapshots: [RateSnapshotPoint],
        now: Date = Date()
    ) -> QuotaForecastDTO {
        guard let resetsAt = resetsAt,
              let currentCycleKey,
              currentCycleKey.resetAt == resetsAt else {
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

        // 过滤有效数据点（按时间升序），并在明显百分比回退处切分周期。
        let filteredSorted = snapshots
            .filter { $0.cycleKey == currentCycleKey }
            .filter { $0.timestamp <= now && $0.timestamp < resetDate }
            .filter { (0.0...100.0).contains($0.usedPercent) }
            .sorted { $0.timestamp < $1.timestamp }
        var rawSorted: [RateSnapshotPoint] = []
        for point in filteredSorted {
            if let previous = rawSorted.last,
               point.timestamp.timeIntervalSince(previous.timestamp) < 60 {
                rawSorted[rawSorted.count - 1] = point
            } else {
                rawSorted.append(point)
            }
        }
        var cycleStartIndex = 0
        if rawSorted.count >= 2 {
            for index in 1..<rawSorted.count {
                if rawSorted[index].usedPercent + 5.0 < rawSorted[index - 1].usedPercent {
                    cycleStartIndex = index
                }
            }
        }
        let sorted = Array(rawSorted.dropFirst(cycleStartIndex))
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
        let sampleFreshnessSeconds = now.timeIntervalSince(last.timestamp)
        guard timeSpanSeconds >= 900, sampleFreshnessSeconds <= 3_600 else { // 至少 15 分钟跨度且最后样本不超过 1 小时
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
                slopes.append(slope)
            }
        }

        let initialMedianSlope: Double
        if slopes.isEmpty {
            initialMedianSlope = 0.0
        } else {
            slopes.sort()
            initialMedianSlope = median(slopes)
        }

        // Reject slope and residual outliers using MAD, then fit a recency-weighted
        // least-squares line. The final rate blends two robust estimators.
        let slopeMAD = median(slopes.map { abs($0 - initialMedianSlope) })
        let slopeTolerance = max(0.05, slopeMAD * 4.4478)
        let robustSlopes = slopes.filter { abs($0 - initialMedianSlope) <= slopeTolerance }
        let medianSlopePerHour = robustSlopes.isEmpty ? initialMedianSlope : median(robustSlopes)

        let origin = first.timestamp
        let intercepts = sorted.map {
            $0.usedPercent - medianSlopePerHour * ($0.timestamp.timeIntervalSince(origin) / 3_600.0)
        }
        let robustIntercept = median(intercepts)
        let residuals = sorted.map {
            $0.usedPercent - (robustIntercept + medianSlopePerHour * ($0.timestamp.timeIntervalSince(origin) / 3_600.0))
        }
        let residualMedian = median(residuals)
        let residualMAD = median(residuals.map { abs($0 - residualMedian) })
        let residualTolerance = max(0.15, residualMAD * 4.4478)
        let inliers = zip(sorted, residuals).compactMap { point, residual in
            abs(residual - residualMedian) <= residualTolerance ? point : nil
        }
        let weightedSlope = weightedLeastSquaresSlope(points: inliers, now: now)
        let effectiveBurnRate = max(0.0, median([medianSlopePerHour, weightedSlope ?? medianSlopePerHour]))
        let fitQuality = coefficientOfDetermination(
            points: inliers,
            slope: effectiveBurnRate,
            origin: origin
        )

        // 2. Pace Ratio 与耗尽时间评估
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
        if inliers.count >= 10 && timeSpanSeconds >= 86400 && fitQuality >= 0.75 {
            confidence = .high
        } else if inliers.count >= 4 && timeSpanSeconds >= 14400 && fitQuality >= 0.40 {
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
            samplePointsCount: inliers.count,
            fitQuality: fitQuality,
            lastSampleAgeSeconds: sampleFreshnessSeconds
        )
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2.0
            : sorted[mid]
    }

    private static func weightedLeastSquaresSlope(points: [RateSnapshotPoint], now: Date) -> Double? {
        guard points.count >= 2 else { return nil }
        let origin = points[0].timestamp
        let weighted = points.map { point -> (x: Double, y: Double, weight: Double) in
            let x = point.timestamp.timeIntervalSince(origin) / 3_600.0
            let ageHours = max(0, now.timeIntervalSince(point.timestamp) / 3_600.0)
            let weight = exp(-ageHours / 24.0)
            return (x, point.usedPercent, weight)
        }
        let sumW = weighted.reduce(0.0) { $0 + $1.weight }
        guard sumW > 0 else { return nil }
        let meanX = weighted.reduce(0.0) { $0 + $1.x * $1.weight } / sumW
        let meanY = weighted.reduce(0.0) { $0 + $1.y * $1.weight } / sumW
        let numerator = weighted.reduce(0.0) { $0 + $1.weight * ($1.x - meanX) * ($1.y - meanY) }
        let denominator = weighted.reduce(0.0) { $0 + $1.weight * pow($1.x - meanX, 2) }
        guard denominator > 0 else { return nil }
        return numerator / denominator
    }

    private static func coefficientOfDetermination(
        points: [RateSnapshotPoint],
        slope: Double,
        origin: Date
    ) -> Double {
        guard points.count >= 2 else { return 0 }
        let intercept = median(points.map {
            $0.usedPercent - slope * ($0.timestamp.timeIntervalSince(origin) / 3_600.0)
        })
        let mean = points.reduce(0.0) { $0 + $1.usedPercent } / Double(points.count)
        let total = points.reduce(0.0) { $0 + pow($1.usedPercent - mean, 2) }
        guard total > 0.000_001 else { return slope <= 0.01 ? 1.0 : 0.0 }
        let residual = points.reduce(0.0) { partial, point in
            let predicted = intercept + slope * (point.timestamp.timeIntervalSince(origin) / 3_600.0)
            return partial + pow(point.usedPercent - predicted, 2)
        }
        return min(1.0, max(0.0, 1.0 - residual / total))
    }
}
