// QuotaLens 周期生命周期状态机与切片引擎
// 依据 limitId + windowDurationMins + resetsAt 维护半开区间 [start_at, end_at)

import Foundation

public final class CycleStateMachine: @unchecked Sendable {
    private let repositories: Repositories
    private let lock = NSLock()

    public init(repositories: Repositories) {
        self.repositories = repositories
    }

    /// 在收到新额度快照时推进周期状态机
    public func processRateLimitSnapshot(
        currentSnapshot: RateLimitSnapshotRecord,
        previousSnapshot: RateLimitSnapshotRecord?
    ) throws -> QuotaCycleRecord {
        lock.lock()
        defer { lock.unlock() }

        let accountKey = currentSnapshot.accountKey
        let limitId = currentSnapshot.limitId
        let currentStart = cycleStart(from: currentSnapshot) ?? currentSnapshot.observedAt

        let activeCycle = try repositories.getLatestOpenQuotaCycle(
            accountKey: accountKey,
            limitId: limitId,
            slot: currentSnapshot.slot
        )

        if let activeCycle, isSameServerWindow(activeCycle, currentSnapshot: currentSnapshot, currentStart: currentStart) {
            let updatedActive = QuotaCycleRecord(
                cycleId: activeCycle.cycleId,
                accountKey: activeCycle.accountKey,
                limitId: activeCycle.limitId,
                slot: activeCycle.slot,
                startAt: activeCycle.startAt,
                endAt: nil,
                expectedEndAt: currentSnapshot.resetsAt ?? activeCycle.expectedEndAt,
                windowDurationMins: currentSnapshot.windowDurationMins ?? activeCycle.windowDurationMins,
                boundaryReason: "active",
                isComplete: false,
                predecessorCycleId: activeCycle.predecessorCycleId
            )
            try repositories.upsertQuotaCycle(updatedActive)
            try upsertOpenSegment(for: updatedActive)
            return updatedActive
        }

        if let prev = previousSnapshot {
            let (resetType, reason) = ResetClassifier.classify(previous: prev, current: currentSnapshot)

            if resetType != .none && resetType != .reportingCorrection {
                // 旧周期结束
                if let oldCycle = activeCycle {
                    let isCompleteCycle = resetType == .normalReset
                    let boundaryAt = boundaryTime(resetType: resetType, previous: prev, current: currentSnapshot)
                    let updatedOld = QuotaCycleRecord(
                        cycleId: oldCycle.cycleId,
                        accountKey: oldCycle.accountKey,
                        limitId: oldCycle.limitId,
                        slot: oldCycle.slot,
                        startAt: oldCycle.startAt,
                        endAt: boundaryAt,
                        expectedEndAt: oldCycle.expectedEndAt,
                        windowDurationMins: oldCycle.windowDurationMins,
                        boundaryReason: resetType.rawValue,
                        isComplete: isCompleteCycle,
                        predecessorCycleId: oldCycle.predecessorCycleId
                    )
                    try repositories.upsertQuotaCycle(updatedOld)

                    // 记录审计事件
                    let event = QuotaEventRecord(
                        eventId: UUID().uuidString,
                        occurredAt: currentSnapshot.observedAt,
                        eventType: resetType.rawValue,
                        severity: resetType == .normalReset ? "info" : "warning",
                        limitId: limitId,
                        oldCycleId: oldCycle.cycleId,
                        newCycleId: nil,
                        evidenceJson: "{\"reason\":\"\(reason)\"}"
                    )
                    try repositories.insertQuotaEvent(event)
                }

                // 开启新周期
                let newCycleId = cycleId(
                    accountKey: accountKey,
                    limitId: limitId,
                    slot: currentSnapshot.slot,
                    startAt: currentStart
                )
                let newCycle = QuotaCycleRecord(
                    cycleId: newCycleId,
                    accountKey: accountKey,
                    limitId: limitId,
                    slot: currentSnapshot.slot,
                    startAt: currentStart,
                    endAt: nil,
                    expectedEndAt: currentSnapshot.resetsAt,
                    windowDurationMins: currentSnapshot.windowDurationMins,
                    boundaryReason: "active",
                    isComplete: false,
                    predecessorCycleId: activeCycle?.cycleId
                )
                try repositories.upsertQuotaCycle(newCycle)
                try upsertOpenSegment(for: newCycle)
                return newCycle
            }
        }

        // 如果目前没有活跃周期，创建一个初始周期
        if activeCycle == nil {
            let initialCycle = QuotaCycleRecord(
                cycleId: cycleId(
                    accountKey: accountKey,
                    limitId: limitId,
                    slot: currentSnapshot.slot,
                    startAt: currentStart
                ),
                accountKey: accountKey,
                limitId: limitId,
                slot: currentSnapshot.slot,
                startAt: currentStart,
                endAt: nil,
                expectedEndAt: currentSnapshot.resetsAt,
                windowDurationMins: currentSnapshot.windowDurationMins,
                boundaryReason: "active",
                isComplete: false,
                predecessorCycleId: nil
            )
            try repositories.upsertQuotaCycle(initialCycle)
            try upsertOpenSegment(for: initialCycle)
            return initialCycle
        }

        return activeCycle!
    }

    private func isSameServerWindow(
        _ cycle: QuotaCycleRecord,
        currentSnapshot: RateLimitSnapshotRecord,
        currentStart: Int64
    ) -> Bool {
        guard cycle.accountKey == currentSnapshot.accountKey,
              cycle.limitId == currentSnapshot.limitId,
              cycle.slot == currentSnapshot.slot else {
            return false
        }

        let tolerance: Int64 = 60
        let startNear = abs(cycle.startAt - currentStart) <= tolerance
        let endNear: Bool
        if let oldEnd = cycle.expectedEndAt, let newEnd = currentSnapshot.resetsAt {
            endNear = abs(oldEnd - newEnd) <= tolerance
        } else {
            endNear = cycle.expectedEndAt == nil && currentSnapshot.resetsAt == nil
        }

        let durationSame = cycle.windowDurationMins == nil
            || currentSnapshot.windowDurationMins == nil
            || cycle.windowDurationMins == currentSnapshot.windowDurationMins

        return startNear && endNear && durationSame
    }

    private func cycleStart(from snapshot: RateLimitSnapshotRecord) -> Int64? {
        guard let resetsAt = snapshot.resetsAt, let duration = snapshot.windowDurationMins else {
            return nil
        }
        return resetsAt - Int64(duration * 60)
    }

    private func boundaryTime(resetType: ResetType, previous: RateLimitSnapshotRecord, current: RateLimitSnapshotRecord) -> Int64 {
        if resetType == .normalReset, let oldResetsAt = previous.resetsAt {
            return oldResetsAt
        }
        return cycleStart(from: current) ?? current.observedAt
    }

    private func cycleId(accountKey: String, limitId: String, slot: String, startAt: Int64) -> String {
        let raw = "\(accountKey)_\(limitId)_\(slot)_\(startAt)"
        let safe = raw.map { char in
            char.isLetter || char.isNumber ? char : "_"
        }
        return "cycle_\(String(safe))"
    }

    private func upsertOpenSegment(for cycle: QuotaCycleRecord) throws {
        guard let end = cycle.expectedEndAt, end > cycle.startAt else { return }
        let segment = QuotaCycleSegmentRecord(
            segmentId: "segment_\(cycle.cycleId)_\(cycle.startAt)",
            cycleId: cycle.cycleId,
            startAt: cycle.startAt,
            endAt: end,
            meterVersionId: MeterVersionDetector.initialMeterVersionId,
            boundaryQuality: cycle.boundaryReason == "active" ? "server_window" : cycle.boundaryReason
        )
        try repositories.upsertQuotaCycleSegment(segment)
    }
}
