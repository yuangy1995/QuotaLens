// QuotaLens 本机用量趋势投影引擎 (EWMA + 星期季节性 + 预测区间)

import Foundation

public enum LocalUsageProjection {
    /// 预测未来 N 天的本机 Token 消耗与估算价值
    public static func project(
        history: [DayUsageSummaryDTO],
        horizonDays: Int = 7,
        calendar: Calendar = UsageDayBucketer.calendar(),
        now: Date = Date()
    ) -> LocalUsageForecastDTO {
        let completeHistory = history.filter { $0.date < calendar.startOfDay(for: now) }
        let totalEvents = completeHistory.reduce(0) { $0 + $1.eventCount }
        let unpricedEvents = completeHistory.reduce(0) { $0 + $1.unpricedEventCount }
        let unpricedTokens = completeHistory.reduce(Int64(0)) { $0 + $1.unpricedTokenCount }
        let totalObservedTokenCoverageBase = completeHistory.reduce(Int64(0)) {
            $0 + $1.tokens.canonicalTotalTokens
        }
        let eventPricingCoverage = totalEvents > 0
            ? max(0, min(1, Double(totalEvents - unpricedEvents) / Double(totalEvents)))
            : 1.0
        let tokenPricingCoverage = totalObservedTokenCoverageBase > 0
            ? max(0, min(1, Double(max(0, totalObservedTokenCoverageBase - unpricedTokens)) / Double(totalObservedTokenCoverageBase)))
            : 1.0
        let isCostForecastAvailable = tokenPricingCoverage >= 0.80
        let coverage: PricingCoverage = unpricedEvents == 0
            ? .fullyPriced
            : (unpricedEvents == totalEvents
                ? .unpriced(totalEvents: totalEvents)
                : .partiallyPriced(coveredEvents: totalEvents - unpricedEvents, totalEvents: totalEvents))
        guard completeHistory.count >= 7 else {
            return LocalUsageForecastDTO(
                daysHorizon: horizonDays,
                projectedTotalTokens: 0,
                projectedTotalCost: .zero,
                confidence: .insufficientData,
                dailyProjections: [],
                pricingCoverage: coverage,
                eventPricingCoverage: eventPricingCoverage,
                tokenPricingCoverage: tokenPricingCoverage,
                costForecastCoverage: tokenPricingCoverage,
                isCostForecastAvailable: isCostForecastAvailable,
                unpricedTokenCount: unpricedTokens
            )
        }

        let sorted = completeHistory.sorted { $0.date < $1.date }
        let tokenSamples = sorted.map { Double($0.tokens.canonicalTotalTokens) }
        let medianTokens = median(tokenSamples)
        let tokenMAD = max(1.0, median(tokenSamples.map { abs($0 - medianTokens) }))

        // 1. Winsorize outliers, then combine a robust median with EWMA.
        let winsorizedTokens = tokenSamples.map {
            clamp($0, max(0, medianTokens - tokenMAD * 3.0), medianTokens + tokenMAD * 3.0)
        }
        let alpha = 0.25
        var ewmaTokens: Double = medianTokens

        // 星期几分布统计 (1 = Sunday ... 7 = Saturday)
        var weekdaySums: [Int: Double] = [:]
        var weekdayCounts: [Int: Int] = [:]

        for (index, day) in sorted.enumerated() {
            let tokens = winsorizedTokens[index]
            ewmaTokens = alpha * tokens + (1.0 - alpha) * ewmaTokens

            let weekday = calendar.component(.weekday, from: day.date)
            weekdaySums[weekday, default: 0.0] += tokens
            weekdayCounts[weekday, default: 0] += 1
        }

        let baselineTokens = max(0, median([medianTokens, ewmaTokens]))
        let logSamples = winsorizedTokens.map { log1p(max(0, $0)) }
        let dailyLogSlope = clamp(theilSenSlope(logSamples), -0.08, 0.08)

        // Value is projected from priced-token coverage and the observed value
        // per priced token, not by reusing the Token trend as a cost trend.
        let totalObservedTokens = sorted.reduce(Int64(0)) { $0 + $1.tokens.canonicalTotalTokens }
        let pricedTokens = max(0, totalObservedTokens - unpricedTokens)
        let observedCostNano = sorted.reduce(Int64(0)) { partial, day in
            let (sum, overflow) = partial.addingReportingOverflow(day.estimatedCost.rawValue)
            return overflow ? Int64.max : sum
        }
        let costNanoPerPricedToken = pricedTokens > 0
            ? Double(observedCostNano) / Double(pricedTokens)
            : 0

        // 计算星期季节性乘数 (平均基准为 1.0)
        let overallDailyAvg = max(1.0, baselineTokens)
        var weekdayMultipliers: [Int: Double] = [:]
        for w in 1...7 {
            let count = weekdayCounts[w] ?? 0
            if sorted.count >= 28 && count > 0 {
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

        var random = DeterministicRandom(seed: UInt64(sorted.count * 31 + max(1, horizonDays)))
        for i in 1...max(1, horizonDays) {
            guard let targetDate = calendar.date(byAdding: .day, value: i, to: now) else { continue }
            let dayKey = LocalDayKey(date: targetDate, calendar: calendar)
            let weekday = calendar.component(.weekday, from: targetDate)
            let seasonMult = weekdayMultipliers[weekday] ?? 1.0

            let trendMultiplier = exp(dailyLogSlope * Double(min(i, 14)))
            let baselineScale = baselineTokens / max(1.0, medianTokens)
            var bootstrap: [Double] = []
            bootstrap.reserveCapacity(400)
            for _ in 0..<400 {
                let sample = winsorizedTokens[random.nextIndex(upperBound: winsorizedTokens.count)]
                bootstrap.append(max(0, sample * baselineScale * seasonMult * trendMultiplier))
            }
            bootstrap.sort()
            let p10Token = max(0, Int64(quantile(bootstrap, probability: 0.10).rounded()))
            let p50Token = max(p10Token, Int64(quantile(bootstrap, probability: 0.50).rounded()))
            let p90Token = max(p50Token, Int64(quantile(bootstrap, probability: 0.90).rounded()))
            let p50CostNano = isCostForecastAvailable
                ? max(0, Int64((Double(p50Token) * costNanoPerPricedToken).rounded()))
                : 0

            totalProjectedTokens += p50Token
            if isCostForecastAvailable {
                totalProjectedCostNano += p50CostNano
            }

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

        let sampleConfidence: ForecastConfidence = sorted.count >= 28 ? .high : (sorted.count >= 14 ? .medium : .low)
        let confidence: ForecastConfidence = tokenPricingCoverage < 0.95
            ? .low
            : sampleConfidence

        return LocalUsageForecastDTO(
            daysHorizon: horizonDays,
            projectedTotalTokens: totalProjectedTokens,
            projectedTotalCost: isCostForecastAvailable ? MoneyNanoUSD(totalProjectedCostNano) : .zero,
            confidence: confidence,
            dailyProjections: projectedPoints,
            pricingCoverage: coverage,
            eventPricingCoverage: eventPricingCoverage,
            tokenPricingCoverage: tokenPricingCoverage,
            costForecastCoverage: tokenPricingCoverage,
            isCostForecastAvailable: isCostForecastAvailable,
            unpricedTokenCount: unpricedTokens
        )
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2.0
        }
        return sorted[mid]
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    private static func theilSenSlope(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        var slopes: [Double] = []
        for i in 0..<(values.count - 1) {
            for j in (i + 1)..<values.count {
                slopes.append((values[j] - values[i]) / Double(j - i))
            }
        }
        return median(slopes)
    }

    private static func quantile(_ sortedValues: [Double], probability: Double) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let p = min(1, max(0, probability))
        let position = p * Double(sortedValues.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        guard lower != upper else { return sortedValues[lower] }
        let weight = position - Double(lower)
        return sortedValues[lower] * (1 - weight) + sortedValues[upper] * weight
    }

    private struct DeterministicRandom {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed == 0 ? 0x9e3779b97f4a7c15 : seed
        }

        mutating func nextIndex(upperBound: Int) -> Int {
            guard upperBound > 1 else { return 0 }
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state % UInt64(upperBound))
        }
    }
}
