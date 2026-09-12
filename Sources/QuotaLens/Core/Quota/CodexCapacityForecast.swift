import Foundation

/// 采集同一账号的云端总量与通用额度。同次读取不代表统计截止时间同步；不混入本机或独立模型额度池。
struct CodexCapacityObservation: Codable, Sendable {
    struct Window: Codable, Sendable {
        let minutes: Int
        let usedPercent: Double
        let resetsAt: Int64
    }
    let accountKey: String
    let observedAt: Int64
    let lifetimeTokens: Int64?
    let planType: String?
    let subscriptionPlan: String?
    let windows: [Window]

    static func make(accountKey: String, observedAt: Int64, usage: CodexAccountUsagePayload?,
                     snapshots: [RateLimitSnapshotRecord], subscriptionPlan: String? = nil) -> Self {
        let general = snapshots.filter { $0.accountKey == accountKey && $0.limitId == "codex" }
        let windows = [300, 10080].compactMap { minutes -> Window? in
            guard let row = general.first(where: { $0.windowDurationMins == minutes }),
                  let reset = row.resetsAt else { return nil }
            return Window(minutes: minutes, usedPercent: Double(row.usedPercentMilli) / 1000, resetsAt: reset)
        }
        return Self(accountKey: accountKey, observedAt: observedAt,
                    lifetimeTokens: usage?.summary.lifetimeTokens.flatMap { $0 >= 0 ? $0 : nil },
                    planType: general.first?.planType, subscriptionPlan: subscriptionPlan, windows: windows)
    }
}

enum CapacityCycleEnd: String, Sendable {
    case natural, restored, planChanged, awaitingRefresh
}

struct CodexCapacityCycle: Identifiable, Sendable {
    let id: String
    let minutes: Int
    let stage: Int
    let startAt: Int64
    var expectedEndAt: Int64
    var endAt: Int64?
    var endReason: CapacityCycleEnd?
    var observedThrough: Int64
    var measuredTokens: Double = 0
    var consumedPercent: Double = 0
    var remainingPercent: Double
    var hasGap: Bool = false
    var hasPrecedingGap: Bool = false
    var intervalCount: Int = 0
    var awaitingCloudUsage: Bool = false

    var capacity: Double? {
        // 小百分比的量化误差会被放大；至少积累 10 个百分点再显示容量。
        guard consumedPercent >= 10, measuredTokens > 0 else { return nil }
        let value = measuredTokens * 100 / consumedPercent
        return value.isFinite ? value : nil
    }
    var remainingTokens: Double? { capacity.map { $0 * remainingPercent / 100 } }
}

struct CodexCapacityPrediction: Sendable {
    let tokens: Double
    let changePercent: Double
    let followsTrend: Bool
    let sampleCount: Int
}

struct CodexCapacityWindow: Identifiable, Sendable {
    var id: Int { minutes }
    let minutes: Int
    let cycles: [CodexCapacityCycle]
    let isAvailable: Bool
    let prediction: CodexCapacityPrediction?
    var current: CodexCapacityCycle? { cycles.last.flatMap { $0.endAt == nil ? $0 : nil } }
}

enum CodexCapacityForecast {
    /// 重放原始观测，两个窗口分别切分。跨越某个窗口边界的 tokens 仅对该窗口失效。
    static func analyze(_ input: [CodexCapacityObservation], accountKey: String, now: Int64) -> [CodexCapacityWindow] {
        let observations = input.filter { $0.accountKey == accountKey && $0.observedAt <= now }
            .sorted { $0.observedAt < $1.observedAt }
        var stage = 0
        var lastPlan: String?
        var lastSubscription: String?
        let staged = observations.map { observation -> (CodexCapacityObservation, Int) in
            let coarseChanged = observation.planType.map { lastPlan != nil && lastPlan != $0 } ?? false
            let detailChanged = observation.subscriptionPlan.map { lastSubscription != nil && lastSubscription != $0 } ?? false
            if coarseChanged || detailChanged { stage += 1 }
            if coarseChanged { lastSubscription = nil }
            if let plan = observation.planType { lastPlan = plan }
            if let plan = observation.subscriptionPlan { lastSubscription = plan }
            return (observation, stage)
        }
        var windows: [CodexCapacityWindow] = []
        for minutes in [300, 10080] {
            if let window = buildCapacityWindow(
                minutes: minutes,
                staged: staged,
                accountKey: accountKey,
                now: now
            ) {
                windows.append(window)
            }
        }
        return windows
    }

    private struct CapacityAnchor {
        var tokens: Int64
        var percent: Double
    }

    // Swift 6.1.2 的整体优化会在 Optional<结构体> 反复原地修改时触发 SIL 所有权校验失败。
    // 可变状态仅留在本次同步计算内；归档时生成独立值快照，不能把引用对象泄露给历史结果。
    private final class ActiveCycleBuilder {
        let id: String
        let minutes: Int
        let stage: Int
        let startAt: Int64
        var expectedEndAt: Int64
        var endAt: Int64?
        var endReason: CapacityCycleEnd?
        var observedThrough: Int64
        var measuredTokens: Double = 0
        var consumedPercent: Double = 0
        var remainingPercent: Double
        var hasGap: Bool
        let hasPrecedingGap: Bool
        var intervalCount: Int = 0
        var awaitingCloudUsage: Bool = false

        init(
            id: String,
            minutes: Int,
            stage: Int,
            startAt: Int64,
            expectedEndAt: Int64,
            observedThrough: Int64,
            remainingPercent: Double,
            hasGap: Bool,
            hasPrecedingGap: Bool
        ) {
            self.id = id
            self.minutes = minutes
            self.stage = stage
            self.startAt = startAt
            self.expectedEndAt = expectedEndAt
            self.observedThrough = observedThrough
            self.remainingPercent = remainingPercent
            self.hasGap = hasGap
            self.hasPrecedingGap = hasPrecedingGap
        }

        func build() -> CodexCapacityCycle {
            CodexCapacityCycle(
                id: id,
                minutes: minutes,
                stage: stage,
                startAt: startAt,
                expectedEndAt: expectedEndAt,
                endAt: endAt,
                endReason: endReason,
                observedThrough: observedThrough,
                measuredTokens: measuredTokens,
                consumedPercent: consumedPercent,
                remainingPercent: remainingPercent,
                hasGap: hasGap,
                hasPrecedingGap: hasPrecedingGap,
                intervalCount: intervalCount,
                awaitingCloudUsage: awaitingCloudUsage
            )
        }
    }

    private static func buildCapacityWindow(
        minutes: Int,
        staged: [(CodexCapacityObservation, Int)],
        accountKey: String,
        now: Int64
    ) -> CodexCapacityWindow? {
        var cycles: [CodexCapacityCycle] = []
        var current: ActiveCycleBuilder?
        var previousWindow: CodexCapacityObservation.Window?
        var previousTime: Int64?
        var anchor: CapacityAnchor?
        var pairedTokens = 0.0
        var pairedPercent = 0.0
        var previousTokens: Int64?
        // 上周期有未结算消耗时，重置后的第一次迟到增量无法归属，必须先丢弃再建立基线。
        var unsettledResetCounter: Int64?
        var available = false

        for (observation, currentStage) in staged {
            guard previousTime == nil || observation.observedAt > previousTime! else { continue }
            previousTime = observation.observedAt
            guard let window = observation.windows.first(where: { $0.minutes == minutes }),
                  window.usedPercent.isFinite, (0...100).contains(window.usedPercent),
                  window.resetsAt > observation.observedAt else {
                available = false
                anchor = nil
                pairedTokens = 0
                pairedPercent = 0
                current?.hasGap = true
                continue
            }
            available = true
            var reason: CapacityCycleEnd?
            var boundary = observation.observedAt
            if let old = current, let previousWindow {
                if old.stage != currentStage {
                    reason = .planChanged
                } else if abs(window.resetsAt - old.expectedEndAt) > 60,
                          !(old.remainingPercent == 100 && old.consumedPercent == 0
                            && old.expectedEndAt > observation.observedAt) {
                    // 尚未开始使用时服务端可能持续返回“现在 + 窗口长度”，这不是反复重置。
                    if observation.observedAt >= old.expectedEndAt {
                        reason = .natural
                        boundary = old.expectedEndAt
                    } else {
                        reason = .restored
                    }
                } else if previousWindow.usedPercent - window.usedPercent >= 5 {
                    // 提前恢复可能保留原来的截止时间，不能仅使用 resetsAt 作为周期标识。
                    reason = .restored
                }
            }
            if let reason, let old = current {
                let unmatchedPercent: Double
                if let anchor {
                    let prevPercent = previousWindow?.usedPercent ?? anchor.percent
                    unmatchedPercent = prevPercent - anchor.percent - pairedPercent
                } else {
                    unmatchedPercent = 0
                }
                if unmatchedPercent >= 2 || unsettledResetCounter != nil {
                    let counterAdvancedAtBoundary = observation.lifetimeTokens.map { $0 != previousTokens } ?? false
                    unsettledResetCounter = counterAdvancedAtBoundary ? nil : previousTokens
                }
                old.endAt = boundary
                old.endReason = reason
                cycles.append(old.build())
                current = nil
                anchor = nil
                pairedTokens = 0
                pairedPercent = 0
            }
            if current == nil {
                let nominalStart = window.resetsAt - Int64(minutes * 60)
                let start = reason == .natural ? max(boundary, nominalStart) : observation.observedAt
                current = ActiveCycleBuilder(
                    id: "\(accountKey):\(minutes):\(observation.observedAt):\(currentStage)",
                    minutes: minutes,
                    stage: currentStage,
                    startAt: start,
                    expectedEndAt: window.resetsAt,
                    observedThrough: observation.observedAt,
                    remainingPercent: 100 - window.usedPercent,
                    hasGap: window.usedPercent > 0,
                    hasPrecedingGap: reason == .natural && nominalStart > boundary + 60
                )
                if let tokens = observation.lifetimeTokens {
                    anchor = CapacityAnchor(tokens: tokens, percent: window.usedPercent)
                } else {
                    anchor = nil
                }
            } else if let tokens = observation.lifetimeTokens, tokens >= 0 {
                if let pending = unsettledResetCounter {
                    if tokens != pending {
                        unsettledResetCounter = nil
                        anchor = CapacityAnchor(tokens: tokens, percent: window.usedPercent)
                        pairedTokens = 0
                        pairedPercent = 0
                        current?.hasGap = true
                    }
                } else if let base = anchor {
                    let drop = (previousWindow?.usedPercent ?? base.percent) - window.usedPercent
                    if tokens < base.tokens || previousTokens.map({ tokens < $0 }) == true || drop > 0.001 {
                        // 回补/修正无法归属到准确时段，断开配对，不把负消耗记进容量。
                        current?.hasGap = true
                        anchor = CapacityAnchor(tokens: tokens, percent: window.usedPercent)
                        pairedTokens = 0
                        pairedPercent = 0
                    } else {
                        let percent = window.usedPercent - base.percent
                        let delta = Double(tokens - base.tokens)
                        if percent >= 2, delta > pairedTokens {
                            // 用量批次到账时更新整段累计配对，而不是把数小时用量除以最后几次刷新的百分比。
                            // 用量未更新时保持已有估算，不随百分比继续下降而制造“容量缩水”。
                            current?.measuredTokens += delta - pairedTokens
                            current?.consumedPercent += percent - pairedPercent
                            current?.intervalCount += 1
                            pairedTokens = delta
                            pairedPercent = percent
                        }
                    }
                } else {
                    anchor = CapacityAnchor(tokens: tokens, percent: window.usedPercent)
                }
            } else {
                current?.hasGap = true
                // 额度窗口仍连续且未重置，短暂缺失累计 tokens 不影响前后端点相减。
            }
            let pendingUsageUpdate: Bool
            if let anchor {
                pendingUsageUpdate = (window.usedPercent - anchor.percent - pairedPercent >= 2)
            } else {
                pendingUsageUpdate = false
            }
            current?.awaitingCloudUsage = observation.lifetimeTokens == nil
                || unsettledResetCounter != nil
                || pendingUsageUpdate
            if let tokens = observation.lifetimeTokens, tokens >= 0 { previousTokens = tokens }
            current?.remainingPercent = 100 - window.usedPercent
            current?.observedThrough = observation.observedAt
            current?.expectedEndAt = window.resetsAt
            previousWindow = window
        }
        if let current {
            if current.expectedEndAt <= now {
                current.endAt = current.expectedEndAt
                current.endReason = .awaitingRefresh
                available = false
            }
            cycles.append(current.build())
        }
        guard !cycles.isEmpty else { return nil }
        // 数据缺口、换套餐和失效周期会截断预测样本，不把跨阶段数据连成连续趋势。
        let latestStage = staged.last?.1
        let eligible = filterEligibleCapacities(from: cycles, latestStage: latestStage)
        let sampleCapacities: [Double]
        if eligible.count > 5 {
            sampleCapacities = Array(eligible.suffix(5))
        } else {
            sampleCapacities = eligible
        }
        let prediction = predict(capacities: sampleCapacities)
        return CodexCapacityWindow(
            minutes: minutes,
            cycles: cycles,
            isAvailable: available,
            prediction: prediction
        )
    }

    private static func filterEligibleCapacities(from cycles: [CodexCapacityCycle], latestStage: Int?) -> [Double] {
        var result: [Double] = []
        for cycle in cycles {
            guard cycle.endAt != nil else { continue }
            guard cycle.stage == latestStage, cycle.endReason != .planChanged,
                  let capacity = cycle.capacity else {
                result.removeAll(keepingCapacity: true)
                continue
            }
            if cycle.hasPrecedingGap {
                result.removeAll(keepingCapacity: true)
            }
            result.append(capacity)
        }
        return result
    }

    /// 最近至多五个周期的相邻变化中位数，只有最近两次同向且总体同向时延续一半趋势。
    static func predict(capacities: [Double]) -> CodexCapacityPrediction? {
        let values: [Double]
        if capacities.count > 5 {
            values = Array(capacities.suffix(5))
        } else {
            values = capacities
        }
        guard let last = values.last, values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let changes = zip(values, values.dropFirst()).map { ($1 - $0) / $0 }
        var rate = 0.0
        if changes.count >= 2 {
            let sorted = changes.sorted()
            let middle = sorted.count / 2
            let median = sorted.count.isMultiple(of: 2)
                ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
            let recent = Array(changes.suffix(2))
            if recent.allSatisfy({ $0 > 0 }) && median > 0 || recent.allSatisfy({ $0 < 0 }) && median < 0 {
                rate = median * 0.5
            }
        }
        let tokens = last * (1 + rate)
        guard tokens.isFinite else { return nil }
        return CodexCapacityPrediction(tokens: tokens, changePercent: rate * 100,
                                       followsTrend: rate != 0, sampleCount: values.count)
    }
}
