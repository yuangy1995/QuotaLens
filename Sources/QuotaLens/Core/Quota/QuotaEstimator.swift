// QuotaLens 周额度有效容量加权区间回归估算器
// 严格遵循实施计划第 13 节规范，输出容量点估计与 95% 置信区间

import Foundation

public struct EstimationInputPoint: Sendable {
    public let usedPercent: Double    // 服务端已用百分比 (0.0 ~ 100.0)
    public let normalizedUnits: Double// 累计消耗标准单位
    public let coverageRatio: Double  // 明细覆盖率 (0.0 ~ 1.0)
    public let timestamp: Int64

    public init(usedPercent: Double, normalizedUnits: Double, coverageRatio: Double, timestamp: Int64) {
        self.usedPercent = usedPercent
        self.normalizedUnits = normalizedUnits
        self.coverageRatio = coverageRatio
        self.timestamp = timestamp
    }
}

public struct EstimationResult: Sendable {
    public let capacityUnits: Double?
    public let confidenceLow: Double?
    public let confidenceHigh: Double?
    public let confidenceLevel: String // "high", "medium", "low"
    public let sampleCount: Int
    public let percentSpan: Double
    public let residualError: Double?
    public let message: String
}

public struct QuotaEstimator: Sendable {
    /// 执行加权最小二乘区间回归
    public static func estimateCapacity(points: [EstimationInputPoint]) -> EstimationResult {
        guard points.count >= 3 else {
            return EstimationResult(
                capacityUnits: nil, confidenceLow: nil, confidenceHigh: nil,
                confidenceLevel: "low", sampleCount: points.count, percentSpan: 0,
                residualError: nil, message: "样本点数量过少 (当前: \(points.count)，最少需要 3 个)"
            )
        }

        // 检查百分比跨度
        let minPercent = points.map { $0.usedPercent }.min() ?? 0.0
        let maxPercent = points.map { $0.usedPercent }.max() ?? 0.0
        let percentSpan = maxPercent - minPercent

        if percentSpan < 2.0 {
            return EstimationResult(
                capacityUnits: nil, confidenceLow: nil, confidenceHigh: nil,
                confidenceLevel: "low", sampleCount: points.count, percentSpan: percentSpan,
                residualError: nil, message: "额度消耗跨度不足 2% (当前: \(String(format: "%.1f", percentSpan))%)，无法进行收敛回归"
            )
        }

        // 计算加权均值
        var totalWeight: Double = 0.0
        var weightedSumQ: Double = 0.0
        var weightedSumP: Double = 0.0

        for pt in points {
            let weight = max(0.1, pt.coverageRatio)
            totalWeight += weight
            weightedSumQ += weight * pt.normalizedUnits
            weightedSumP += weight * pt.usedPercent
        }

        guard totalWeight > 0 else {
            return EstimationResult(capacityUnits: nil, confidenceLow: nil, confidenceHigh: nil, confidenceLevel: "low", sampleCount: points.count, percentSpan: percentSpan, residualError: nil, message: "权重总和为 0")
        }

        let meanQ = weightedSumQ / totalWeight
        let meanP = weightedSumP / totalWeight

        var numerator: Double = 0.0
        var denominator: Double = 0.0

        for pt in points {
            let weight = max(0.1, pt.coverageRatio)
            let diffQ = pt.normalizedUnits - meanQ
            let diffP = pt.usedPercent - meanP
            numerator += weight * diffQ * diffP
            denominator += weight * diffQ * diffQ
        }

        guard denominator > 1e-9 else {
            return EstimationResult(
                capacityUnits: nil, confidenceLow: nil, confidenceHigh: nil,
                confidenceLevel: "low", sampleCount: points.count, percentSpan: percentSpan,
                residualError: nil, message: "用量变化为 0，矩阵奇异"
            )
        }

        let slopeBeta = numerator / denominator
        guard slopeBeta > 1e-12 else {
            return EstimationResult(
                capacityUnits: nil, confidenceLow: nil, confidenceHigh: nil,
                confidenceLevel: "low", sampleCount: points.count, percentSpan: percentSpan,
                residualError: nil, message: "回归斜率非正，数据异常"
            )
        }

        // 有效容量估计 C = 100 / beta
        let capacity = 100.0 / slopeBeta

        // 计算残差方差
        var sumResidualSq: Double = 0.0
        for pt in points {
            let predictedP = meanP + slopeBeta * (pt.normalizedUnits - meanQ)
            let residual = pt.usedPercent - predictedP
            sumResidualSq += residual * residual
        }
        let residualVariance = sumResidualSq / Double(max(1, points.count - 2))
        let seSlope = sqrt(residualVariance / denominator)

        // 95% 置信区间 (使用 t 分布近似系数 2.0)
        let tValue = 2.0
        let betaLow = max(1e-12, slopeBeta - tValue * seSlope)
        let betaHigh = slopeBeta + tValue * seSlope

        let confLow = 100.0 / betaHigh
        let confHigh = 100.0 / betaLow

        let avgCoverage = points.map { $0.coverageRatio }.reduce(0, +) / Double(points.count)

        let level: String
        if avgCoverage >= 0.98 && percentSpan >= 50.0 && points.count >= 20 {
            level = "high"
        } else if avgCoverage >= 0.80 && percentSpan >= 20.0 {
            level = "medium"
        } else {
            level = "low"
        }

        if level == "low" {
            return EstimationResult(
                capacityUnits: nil,
                confidenceLow: nil,
                confidenceHigh: nil,
                confidenceLevel: level,
                sampleCount: points.count,
                percentSpan: percentSpan,
                residualError: sqrt(residualVariance),
                message: "覆盖率或百分比跨度不足，仅保留趋势证据，不输出精确容量点估计"
            )
        }

        return EstimationResult(
            capacityUnits: capacity,
            confidenceLow: confLow,
            confidenceHigh: confHigh,
            confidenceLevel: level,
            sampleCount: points.count,
            percentSpan: percentSpan,
            residualError: sqrt(residualVariance),
            message: "回归拟合完成"
        )
    }
}
