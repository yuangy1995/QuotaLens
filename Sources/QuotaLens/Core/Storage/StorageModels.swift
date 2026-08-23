// QuotaLens 数据库实体与存储模型定义
// 遵循实施计划第 14 节数据库设计规范，所有 Token 与微单位采用整数避免浮点误差

import Foundation

/// 账户信息
public struct AccountRecord: Identifiable, Codable, Sendable {
    public var id: String { accountKey }
    public let accountKey: String
    public let emailHash: String?
    public let planType: String?
    public let firstSeenAt: Int64
    public let lastSeenAt: Int64

    public init(accountKey: String, emailHash: String?, planType: String?, firstSeenAt: Int64, lastSeenAt: Int64) {
        self.accountKey = accountKey
        self.emailHash = emailHash
        self.planType = planType
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
    }
}

/// 设备信息
public struct DeviceRecord: Identifiable, Codable, Sendable {
    public var id: String { deviceId }
    public let deviceId: String
    public let platform: String
    public let appInstallId: String
    public let firstSeenAt: Int64
    public let lastSeenAt: Int64
    public let syncEnabled: Bool

    public init(deviceId: String, platform: String = "macOS", appInstallId: String, firstSeenAt: Int64, lastSeenAt: Int64, syncEnabled: Bool = false) {
        self.deviceId = deviceId
        self.platform = platform
        self.appInstallId = appInstallId
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.syncEnabled = syncEnabled
    }
}

/// 账户日总量快照状态
public enum DailyDataState: String, Codable, Sendable {
    case live
    case pendingReconciliation = "pending_reconciliation"
    case stable
    case finalized
    case reopened
}

/// 账户日用量快照记录 (account/usage/read 结果)
public struct AccountDailySnapshotRecord: Identifiable, Codable, Sendable {
    public var id: String { "\(accountKey)_\(serverStartDate)_\(observedAt)" }
    public let dbId: Int64?
    public let accountKey: String
    public let serverStartDate: String // 如 "2026-08-22"
    public let observedAt: Int64       // Unix 秒
    public let totalTokens: Int64      // 当日全账户总 Token
    public let dataState: DailyDataState
    public let rawJson: String

    public init(dbId: Int64? = nil, accountKey: String, serverStartDate: String, observedAt: Int64, totalTokens: Int64, dataState: DailyDataState, rawJson: String) {
        self.dbId = dbId
        self.accountKey = accountKey
        self.serverStartDate = serverStartDate
        self.observedAt = observedAt
        self.totalTokens = totalTokens
        self.dataState = dataState
        self.rawJson = rawJson
    }
}

/// 额度窗口快照记录 (account/rateLimits/read 结果)
public struct RateLimitSnapshotRecord: Identifiable, Codable, Sendable {
    public let id: Int64?
    public let accountKey: String
    public let observedAt: Int64
    public let limitId: String               // 如 "codex-primary"
    public let slot: String                  // "primary" / "secondary" / "other"
    public let usedPercentMilli: Int         // 千分比，47000 代表 47.000%
    public let windowDurationMins: Int?      // 如 10080 (7天), 300 (5小时)
    public let resetsAt: Int64?              // Unix 秒
    public let planType: String?             // "pro", "plus", "team", "enterprise"
    public let rawJson: String

    public init(id: Int64? = nil, accountKey: String, observedAt: Int64, limitId: String, slot: String, usedPercentMilli: Int, windowDurationMins: Int?, resetsAt: Int64?, planType: String?, rawJson: String) {
        self.id = id
        self.accountKey = accountKey
        self.observedAt = observedAt
        self.limitId = limitId
        self.slot = slot
        self.usedPercentMilli = usedPercentMilli
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
        self.planType = planType
        self.rawJson = rawJson
    }
}

/// 线程用量快照记录
public struct ThreadUsageSnapshotRecord: Identifiable, Codable, Sendable {
    public let id: Int64?
    public let deviceId: String
    public let observedAt: Int64
    public let threadId: String
    public let modelRaw: String?
    public let modelCanonical: String?
    public let reasoningEffort: String?
    public let serviceTier: String?
    public let inputTokens: Int64
    public let cachedInputTokens: Int64
    public let outputTokens: Int64
    public let totalTokens: Int64
    public let estimatedCreditsMicros: Int64
    public let rawJson: String

    public init(id: Int64? = nil, deviceId: String, observedAt: Int64, threadId: String, modelRaw: String?, modelCanonical: String?, reasoningEffort: String?, serviceTier: String?, inputTokens: Int64, cachedInputTokens: Int64, outputTokens: Int64, totalTokens: Int64, estimatedCreditsMicros: Int64, rawJson: String) {
        self.id = id
        self.deviceId = deviceId
        self.observedAt = observedAt
        self.threadId = threadId
        self.modelRaw = modelRaw
        self.modelCanonical = modelCanonical
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.estimatedCreditsMicros = estimatedCreditsMicros
        self.rawJson = rawJson
    }
}

/// 用量增量切片事件
public struct UsageEventRecord: Identifiable, Codable, Sendable {
    public var id: String { eventId }
    public let eventId: String
    public let deviceId: String
    public let intervalStart: Int64 // Unix 秒
    public let intervalEnd: Int64   // Unix 秒
    public let threadId: String?
    public let modelRaw: String?
    public let modelCanonical: String?
    public let reasoningEffort: String?
    public let serviceTier: String?
    public let inputTokens: Int64
    public let cachedInputTokens: Int64
    public let outputTokens: Int64
    public let totalTokens: Int64
    public let meterVersionId: String?
    public let cycleId: String?
    public let allocationQuality: String // "exact", "ambiguous_interval", "baseline_only"
    public let source: String            // "app_server", "otel", "synced"

    public init(eventId: String, deviceId: String, intervalStart: Int64, intervalEnd: Int64, threadId: String?, modelRaw: String?, modelCanonical: String?, reasoningEffort: String?, serviceTier: String?, inputTokens: Int64, cachedInputTokens: Int64, outputTokens: Int64, totalTokens: Int64, meterVersionId: String?, cycleId: String?, allocationQuality: String, source: String) {
        self.eventId = eventId
        self.deviceId = deviceId
        self.intervalStart = intervalStart
        self.intervalEnd = intervalEnd
        self.threadId = threadId
        self.modelRaw = modelRaw
        self.modelCanonical = modelCanonical
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.meterVersionId = meterVersionId
        self.cycleId = cycleId
        self.allocationQuality = allocationQuality
        self.source = source
    }
}

/// 计量版本记录
public struct MeterVersionRecord: Identifiable, Codable, Sendable {
    public var id: String { meterVersionId }
    public let meterVersionId: String
    public let effectiveFrom: Int64
    public let effectiveTo: Int64?
    public let reason: String
    public let source: String
    public let confidence: String

    public init(meterVersionId: String, effectiveFrom: Int64, effectiveTo: Int64?, reason: String, source: String, confidence: String) {
        self.meterVersionId = meterVersionId
        self.effectiveFrom = effectiveFrom
        self.effectiveTo = effectiveTo
        self.reason = reason
        self.source = source
        self.confidence = confidence
    }
}

/// 额度周期记录
public struct QuotaCycleRecord: Identifiable, Codable, Sendable {
    public var id: String { cycleId }
    public let cycleId: String
    public let accountKey: String
    public let limitId: String
    public let slot: String
    public let startAt: Int64
    public let endAt: Int64?
    public let expectedEndAt: Int64?
    public let windowDurationMins: Int?
    public let boundaryReason: String // "natural_reset", "earned_reset", "server_reanchor", "active"
    public let isComplete: Bool
    public let predecessorCycleId: String?

    public init(cycleId: String, accountKey: String, limitId: String, slot: String, startAt: Int64, endAt: Int64?, expectedEndAt: Int64?, windowDurationMins: Int?, boundaryReason: String, isComplete: Bool, predecessorCycleId: String?) {
        self.cycleId = cycleId
        self.accountKey = accountKey
        self.limitId = limitId
        self.slot = slot
        self.startAt = startAt
        self.endAt = endAt
        self.expectedEndAt = expectedEndAt
        self.windowDurationMins = windowDurationMins
        self.boundaryReason = boundaryReason
        self.isComplete = isComplete
        self.predecessorCycleId = predecessorCycleId
    }
}

/// 周期内的计量切片 (Segments)
public struct QuotaCycleSegmentRecord: Identifiable, Codable, Sendable {
    public var id: String { segmentId }
    public let segmentId: String
    public let cycleId: String
    public let startAt: Int64
    public let endAt: Int64
    public let meterVersionId: String
    public let boundaryQuality: String

    public init(segmentId: String, cycleId: String, startAt: Int64, endAt: Int64, meterVersionId: String, boundaryQuality: String) {
        self.segmentId = segmentId
        self.cycleId = cycleId
        self.startAt = startAt
        self.endAt = endAt
        self.meterVersionId = meterVersionId
        self.boundaryQuality = boundaryQuality
    }
}

/// 周容量估算记录
public struct QuotaEstimateRecord: Identifiable, Codable, Sendable {
    public var id: String { estimateId }
    public let estimateId: String
    public let cycleId: String
    public let meterVersionId: String
    public let capacityUnitsMicros: Int64? // 估算的有效容量微单位
    public let confidenceLowMicros: Int64? // 95% 置信区间下界
    public let confidenceHighMicros: Int64?// 95% 置信区间上界
    public let accountTokens: Int64
    public let attributedTokens: Int64
    public let coveragePpm: Int            // 百万分比 (例如 985,000 = 98.5%)
    public let percentSpanMilli: Int       // 服务端已用百分比跨度 (千分比)
    public let sampleCount: Int
    public let residualMicros: Int64?
    public let confidenceLevel: String     // "high", "medium", "low"
    public let algorithmVersion: String
    public let calculatedAt: Int64

    public init(estimateId: String, cycleId: String, meterVersionId: String, capacityUnitsMicros: Int64?, confidenceLowMicros: Int64?, confidenceHighMicros: Int64?, accountTokens: Int64, attributedTokens: Int64, coveragePpm: Int, percentSpanMilli: Int, sampleCount: Int, residualMicros: Int64?, confidenceLevel: String, algorithmVersion: String, calculatedAt: Int64) {
        self.estimateId = estimateId
        self.cycleId = cycleId
        self.meterVersionId = meterVersionId
        self.capacityUnitsMicros = capacityUnitsMicros
        self.confidenceLowMicros = confidenceLowMicros
        self.confidenceHighMicros = confidenceHighMicros
        self.accountTokens = accountTokens
        self.attributedTokens = attributedTokens
        self.coveragePpm = coveragePpm
        self.percentSpanMilli = percentSpanMilli
        self.sampleCount = sampleCount
        self.residualMicros = residualMicros
        self.confidenceLevel = confidenceLevel
        self.algorithmVersion = algorithmVersion
        self.calculatedAt = calculatedAt
    }
}

/// 额度事件与异常告警记录
public struct QuotaEventRecord: Identifiable, Codable, Sendable {
    public var id: String { eventId }
    public let eventId: String
    public let occurredAt: Int64
    public let eventType: String  // "reset", "reanchor", "capacity_anomaly"
    public let severity: String   // "info", "warning", "critical"
    public let limitId: String?
    public let oldCycleId: String?
    public let newCycleId: String?
    public let evidenceJson: String

    public init(eventId: String, occurredAt: Int64, eventType: String, severity: String, limitId: String?, oldCycleId: String?, newCycleId: String?, evidenceJson: String) {
        self.eventId = eventId
        self.occurredAt = occurredAt
        self.eventType = eventType
        self.severity = severity
        self.limitId = limitId
        self.oldCycleId = oldCycleId
        self.newCycleId = newCycleId
        self.evidenceJson = evidenceJson
    }
}
