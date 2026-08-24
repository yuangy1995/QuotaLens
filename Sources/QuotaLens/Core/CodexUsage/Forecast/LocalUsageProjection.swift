// QuotaLens 本机用量趋势投影引擎 (EWMA + 星期季节性 + 预测区间)

import Foundation

public enum LocalUsageProjection {
    /// 预测未来 N 天的本机 Token 消耗与估算价值
    public static func project(
        history: [DayUsageSummaryDTO],
        horizonDays: Int = 7,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> LocalUsageForecastDTO {
        guard history.count >= 3 else {
            return LocalUsageForecastDTO(
                daysHorizon: horizonDays,
                projectedTotalTokens: 0,
                projectedTotalCost: .zero,
                confidence: .insufficientData,
                dailyProjections: []
            )
        }

        let sorted = history.sorted { $0.date < $1.date }

        // 1. 计算加权移动平均日消耗 (EWMA)
        let alpha = 0.25
        var ewmaTokens: Double = Double(sorted.first?.tokens.canonicalTotalTokens ?? 0)
        var ewmaCost: Double = Double(sorted.first?.estimatedCost.rawValue ?? 0)

        // 星期几分布统计 (1 = Sunday ... 7 = Saturday)
        var weekdaySums: [Int: Double] = [:]
        var weekdayCounts: [Int: Int] = [:]

        for day in sorted {
            let tokens = Double(day.tokens.canonicalTotalTokens)
            let cost = Double(day.estimatedCost.rawValue)
            ewmaTokens = alpha * tokens + (1.0 - alpha) * ewmaTokens
            ewmaCost = alpha * cost + (1.0 - alpha) * ewmaCost

            let weekday = calendar.component(.weekday, from: day.date)
            weekdaySums[weekday, default: 0.0] += tokens
            weekdayCounts[weekday, default: 0] += 1
        }

        // 计算星期季节性乘数 (平均基准为 1.0)
        let overallDailyAvg = max(1.0, ewmaTokens)
        var weekdayMultipliers: [Int: Double] = [:]
        for w in 1...7 {
            let count = weekdayCounts[w] ?? 0
            if count > 0 {
                let avg = (weekdaySums[w] ?? 0) / Double(count)
                weekdayMultipliers[w] = min(max(avg / overallDailyAvg, 0.4), 2.5)
            } else {
                weekdayMultipliers[w] = 1.0
            }
        }

        // 2. 生成未来天数的投影序列
        var projectedPoints: [LocalUsageForecastDTO.DailyProjectionPoint] = []
        var totalProjectedTokens: Int64 = 0
        var totalProjectedCostNano: Int64 = 0

        for i in 1...horizonDays {
            guard let targetDate = calendar.date(byAdding: .day, value: i, to: now) else { continue }
            let dayKey = LocalDayKey(date: targetDate, calendar: calendar)
            let weekday = calendar.component(.weekday, from: targetDate)
            let seasonMult = weekdayMultipliers[weekday] ?? 1.0

            let p50Token = max(0, Int64(ewmaTokens * seasonMult))
            let p10Token = max(0, Int64(Double(p50Token) * 0.6))
            let p90Token = max(0, Int64(Double(p50Token) * 1.5))
            let p50CostNano = max(0, Int64(ewmaCost * seasonMult))

            totalProjectedTokens += p50Token
            totalProjectedCostNano += p50CostNano

            projectedPoints.append(
                LocalUsageForecastDTO.DailyProjectionPoint(
                    dayKey: dayKey,
                    date: targetDate,
                    p50Tokens: p50Token,
                    p10Tokens: p10Token,
                    p90Tokens: p90Token,
                    p50Cost: MoneyNanoUSD(p50CostNano)
                )
            )
        }

        let confidence: ForecastConfidence = sorted.count >= 14 ? .high : (sorted.count >= 7 ? .medium : .low)

        return LocalUsageForecastDTO(
            daysHorizon: horizonDays,
            projectedTotalTokens: totalProjectedTokens,
            projectedTotalCost: MoneyNanoUSD(totalProjectedCostNano),
            confidence: confidence,
            dailyProjections: projectedPoints
        )
    }
}
