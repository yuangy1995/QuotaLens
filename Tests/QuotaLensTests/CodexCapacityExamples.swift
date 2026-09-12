import Foundation
@testable import QuotaLens

// 测试数据仅用于验证计算器，不进入应用。
enum CodexCapacityExamples {
    static func observations(now: Int64, minutes: Int) -> [CodexCapacityObservation] {
        var result: [CodexCapacityObservation] = []
            let duration = Int64(minutes * 60)
            let capacities: [Int64] = minutes == 300 ? [1000000, 920000, 1050000, 840000, 700000, 620000]
                : [10000000, 5000000, 6200000, 5600000, 4900000, 4200000]
            let lengths = capacities.indices.map { $0 == 1 ? duration / 3 : duration }
            var start = now - lengths.reduce(0, +) + 600
            var total: Int64 = 0
            for (index, capacity) in capacities.enumerated() {
                let end = start + duration
                for (offset, percent) in [(Int64(0), 0.0), (lengths[index] / 2, 50.0)] where start + offset <= now {
                    result.append(CodexCapacityObservation(accountKey: "example", observedAt: start + offset,
                        lifetimeTokens: total + Int64(Double(capacity) * percent / 100), planType: "plus", subscriptionPlan: nil,
                        windows: [.init(minutes: minutes, usedPercent: percent, resetsAt: end)]))
                }
                total += capacity / 2
                start += lengths[index]
            }
        return result
    }
}
