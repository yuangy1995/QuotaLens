// QuotaLens Codex 本地用量领域模型与核心数据结构
// 包含 Token 统计、nano-USD 运算、计价状态、派生推导及分页排序模型

import Foundation

public enum UsageProvider: String, CaseIterable, Identifiable, Sendable, Codable, Hashable {
    case codex
    case claude
    case antigravity

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .antigravity: return "Antigravity"
    }
}
}

public enum UsageProviderFilter: String, CaseIterable, Identifiable, Sendable, Codable, Hashable {
    case all
    case codex
    case claude
    case antigravity

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .all: return L10n.text("全部", "All")
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .antigravity: return "Antigravity"
        }
    }

    public var provider: UsageProvider? {
        switch self {
        case .all: return nil
        case .codex: return .codex
        case .claude: return .claude
        case .antigravity: return .antigravity
        }
    }
}

// MARK: - nano-USD 货币模型 (1 USD = 1,000,000,000 nano_usd)
public struct MoneyNanoUSD: Hashable, Comparable, Sendable, Codable {
    public static let nanoMultiplier: Int64 = 1_000_000_000
    public static let zero = MoneyNanoUSD(0)

    public let rawValue: Int64

    public init(_ rawValue: Int64) {
        self.rawValue = rawValue
    }

    public init(usdDecimal: Decimal) {
        let multiplied = usdDecimal * Decimal(Self.nanoMultiplier)
        let doubleVal = NSDecimalNumber(decimal: multiplied).doubleValue
        self.rawValue = Int64(doubleVal.rounded())
    }

    public var toDecimal: Decimal {
        Decimal(rawValue) / Decimal(Self.nanoMultiplier)
    }

    public var toDouble: Double {
        Double(rawValue) / Double(Self.nanoMultiplier)
    }

    public static func < (lhs: MoneyNanoUSD, rhs: MoneyNanoUSD) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public static func + (lhs: MoneyNanoUSD, rhs: MoneyNanoUSD) -> MoneyNanoUSD {
        let (res, overflow) = lhs.rawValue.addingReportingOverflow(rhs.rawValue)
        return MoneyNanoUSD(overflow ? (lhs.rawValue > 0 ? Int64.max : Int64.min) : res)
    }

    public static func - (lhs: MoneyNanoUSD, rhs: MoneyNanoUSD) -> MoneyNanoUSD {
        let (res, overflow) = lhs.rawValue.subtractingReportingOverflow(rhs.rawValue)
        return MoneyNanoUSD(overflow ? (lhs.rawValue > 0 ? Int64.max : Int64.min) : res)
    }
}

// MARK: - Token 细分模型
public struct TokenBreakdown: Hashable, Sendable, Codable {
    public let inputTokens: Int64
    public let cachedInputTokens: Int64
    public let cacheWriteInputTokens: Int64
    public let outputTokens: Int64
    public let reasoningOutputTokens: Int64
    public let sourceTotalTokens: Int64?

    public init(
        inputTokens: Int64 = 0,
        cachedInputTokens: Int64 = 0,
        cacheWriteInputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        reasoningOutputTokens: Int64 = 0,
        sourceTotalTokens: Int64? = nil
    ) {
        let normalizedCached = max(0, cachedInputTokens)
        let normalizedCacheWrite = max(0, cacheWriteInputTokens)
        let normalizedReasoning = max(0, reasoningOutputTokens)
        self.inputTokens = max(max(0, inputTokens), normalizedCached + normalizedCacheWrite)
        self.cachedInputTokens = normalizedCached
        self.cacheWriteInputTokens = normalizedCacheWrite
        self.outputTokens = max(max(0, outputTokens), normalizedReasoning)
        self.reasoningOutputTokens = normalizedReasoning
        self.sourceTotalTokens = sourceTotalTokens
    }

    /// 未命中缓存的输入 Token（计全价）
    public var uncachedInputTokens: Int64 {
        max(0, inputTokens - cachedInputTokens - cacheWriteInputTokens)
    }

    /// 标准总量回退值：优先使用上游明确 total，否则为 input + output（cached/reasoning 不重复累加）
    public var canonicalTotalTokens: Int64 {
        if let sourceTotal = sourceTotalTokens, sourceTotal > 0 {
            return sourceTotal
        }
        return inputTokens + outputTokens
    }

    /// 缓存命中率
    public var cacheHitRatio: Double {
        guard inputTokens > 0 else { return 0.0 }
        return Double(cachedInputTokens) / Double(inputTokens)
    }

    public static let zero = TokenBreakdown()

    public static func + (lhs: TokenBreakdown, rhs: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            cacheWriteInputTokens: lhs.cacheWriteInputTokens + rhs.cacheWriteInputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            reasoningOutputTokens: lhs.reasoningOutputTokens + rhs.reasoningOutputTokens,
            sourceTotalTokens: (lhs.canonicalTotalTokens + rhs.canonicalTotalTokens)
        )
    }
}

// MARK: - 增量派生依据
public enum UsageDerivation: String, Hashable, Sendable, Codable {
    case explicitLastUsage = "explicit_last_usage"
    case totalUsageDelta = "total_usage_delta"
    case totalUsageRestart = "total_usage_restart"
    case syntheticInitialSnapshot = "synthetic_initial_snapshot"

    public var localizedDescription: String {
        switch self {
        case .explicitLastUsage:
            return L10n.text("单条用量记录", "Single usage record")
        case .totalUsageDelta:
            return L10n.text("根据累计用量计算", "Calculated from cumulative usage")
        case .totalUsageRestart:
            return L10n.text("用量计数重置后计算", "Calculated after usage count reset")
        case .syntheticInitialSnapshot:
            return L10n.text("初始用量记录", "Initial usage record")
        }
    }
}

// MARK: - 模型归属质量
public enum AttributionQuality: String, Hashable, Sendable, Codable {
    case directTurnContext = "direct_turn_context"
    case threadSettingFallback = "thread_setting_fallback"
    case sessionFallback = "session_fallback"
    case unknownDefault = "unknown_default"

    public var localizedDescription: String {
        switch self {
        case .directTurnContext:
            return L10n.text("轮次上下文精确匹配", "Direct turn context")
        case .threadSettingFallback:
            return L10n.text("线程配置回退", "Thread settings fallback")
        case .sessionFallback:
            return L10n.text("会话级回退", "Session fallback")
        case .unknownDefault:
            return L10n.text("未知模型，未使用默认计价", "Unknown model, no default pricing")
        }
    }
}

// MARK: - 时间戳质量
public enum TimestampQuality: String, Hashable, Sendable, Codable {
    case eventTimestamp = "event_timestamp"
    case fileNameTimestamp = "file_name_timestamp"
    case sessionTimestamp = "session_timestamp"
    case fileModificationTime = "file_modification_time"
    case unresolved = "unresolved"

    public var isUsableForAnalytics: Bool {
        self != .unresolved
    }

    public var localizedDescription: String {
        switch self {
        case .eventTimestamp:
            return L10n.text("事件时间戳", "Event timestamp")
        case .fileNameTimestamp:
            return L10n.text("文件名时间", "Filename timestamp")
        case .sessionTimestamp:
            return L10n.text("会话元数据时间", "Session metadata timestamp")
        case .fileModificationTime:
            return L10n.text("文件修改时间", "File modification time")
        case .unresolved:
            return L10n.text("缺失时间戳", "Missing timestamp")
        }
    }
}

// MARK: - 时间戳来源
public enum TimestampSource: String, Hashable, Sendable, Codable {
    case topLevelTimestamp = "top_level_timestamp"
    case payloadTimestamp = "payload_timestamp"
    case infoTimestamp = "info_timestamp"
    case metadataTimestamp = "metadata_timestamp"
    case createdAt = "created_at"
    case startedAt = "started_at"
    case taskStartedAt = "task_started_at"
    case fileName = "file_name"
    case sessionMetadata = "session_metadata"
    case fileModification = "file_modification"
    case unresolved = "unresolved"

    public var quality: TimestampQuality {
        switch self {
        case .topLevelTimestamp, .payloadTimestamp, .infoTimestamp, .metadataTimestamp, .createdAt, .startedAt, .taskStartedAt:
            return .eventTimestamp
        case .fileName:
            return .fileNameTimestamp
        case .sessionMetadata:
            return .sessionTimestamp
        case .fileModification:
            return .fileModificationTime
        case .unresolved:
            return .unresolved
        }
    }
}

// MARK: - 汇总来源
public enum SummaryProvenance: String, Hashable, Sendable, Codable {
    case eventLedger = "eventLedger"
    case legacyAggregate = "legacyAggregate"
    case reconstructed = "reconstructed"

    public init(storedValue: String?) {
        guard let storedValue,
              let value = SummaryProvenance(rawValue: storedValue) else {
            self = .eventLedger
            return
        }
        self = value
    }

    public var localizedDescription: String {
        switch self {
        case .eventLedger:
            return L10n.text("事件账本", "Event ledger")
        case .legacyAggregate:
            return L10n.text("旧版聚合", "Legacy aggregate")
        case .reconstructed:
            return L10n.text("原始日志重建", "Reconstructed from source")
        }
    }
}

// MARK: - 价格迁移状态
public enum PricingMigrationState: String, Hashable, Sendable, Codable {
    case fullyCurrent = "fullyCurrent"
    case mixedLegacy = "mixedLegacy"
    case pendingSources = "pendingSources"
    case failed = "failed"

    public init(storedValue: String?) {
        guard let storedValue else {
            self = .fullyCurrent
            return
        }
        if let value = PricingMigrationState(rawValue: storedValue) {
            self = value
            return
        }
        switch storedValue {
        case "completed":
            self = .fullyCurrent
        case "pending":
            self = .pendingSources
        case "mixedLegacy":
            self = .mixedLegacy
        case "failed":
            self = .failed
        default:
            self = .pendingSources
        }
    }

    public var localizedDescription: String {
        switch self {
        case .fullyCurrent:
            return L10n.text("费用已更新", "Costs updated")
        case .mixedLegacy:
            return L10n.text("部分历史记录保留原金额", "Some older records keep their original amounts")
        case .pendingSources:
            return L10n.text("部分记录暂时无法读取", "Some records cannot be read right now")
        case .failed:
            return L10n.text("费用更新未完成，请重试", "Cost update did not finish. Try again.")
        }
    }
}

// MARK: - 计价状态
public enum PricingStatus: String, Hashable, Sendable, Codable {
    case priced = "priced"
    case unpricedUnknownModel = "unpricedUnknownModel"
    case unpricedHistoricalRuleMissing = "unpricedHistoricalRuleMissing"
    case unpricedUnsupportedServiceMode = "unpricedUnsupportedServiceMode"
    case unpricedUnsupportedContextLength = "unpricedUnsupportedContextLength"
    case unpricedInvalidTokenRecord = "unpricedInvalidTokenRecord"
    case unpricedCalculationOverflow = "unpricedCalculationOverflow"

    public var isPriced: Bool { self == .priced }

    public var localizedDescription: String {
        switch self {
        case .priced:
            return L10n.text("按 API 价格折算", "Converted at API rates")
        case .unpricedUnknownModel:
            return L10n.text("无法识别模型", "Model not recognized")
        case .unpricedHistoricalRuleMissing:
            return L10n.text("缺少当时价格", "Price at that time is unavailable")
        case .unpricedUnsupportedServiceMode:
            return L10n.text("该服务模式暂无法估算", "This service mode cannot be estimated yet")
        case .unpricedUnsupportedContextLength:
            return L10n.text("这类记录暂无法估算", "This kind of record cannot be estimated yet")
        case .unpricedInvalidTokenRecord:
            return L10n.text("记录不完整，无法估算", "Incomplete record, cannot estimate")
        case .unpricedCalculationOverflow:
            return L10n.text("数值异常，无法估算", "Unusual value, cannot estimate")
        }
    }
}

// MARK: - 聚合计价状态
public enum AggregatePricingStatus: String, Hashable, Sendable, Codable {
    case fullyPriced
    case partiallyPriced
    case fullyUnpriced

    public var isPriced: Bool { self == .fullyPriced }

    public init(eventCount: Int, unpricedEventCount: Int) {
        if eventCount <= 0 {
            self = .fullyUnpriced
        } else if unpricedEventCount <= 0 {
            self = .fullyPriced
        } else if unpricedEventCount >= eventCount {
            self = .fullyUnpriced
        } else {
            self = .partiallyPriced
        }
    }

    public init(storedValue: String?) {
        guard let storedValue else {
            self = .fullyUnpriced
            return
        }
        if let status = AggregatePricingStatus(rawValue: storedValue) {
            self = status
            return
        }
        let legacy = PricingStatus(rawValue: storedValue)
        self = legacy?.isPriced == true ? .fullyPriced : .fullyUnpriced
    }

    public var localizedDescription: String {
        switch self {
        case .fullyPriced:
            return L10n.text("费用已估算", "Cost estimated")
        case .partiallyPriced:
            return L10n.text("部分费用无法估算", "Some costs cannot be estimated")
        case .fullyUnpriced:
            return L10n.text("费用无法估算", "Cost cannot be estimated")
        }
    }
}

// MARK: - 未计价原因分布
public struct UnpricedReasonCounts: Hashable, Sendable, Codable {
    public var unknownModelEvents: Int
    public var unknownModelTokens: Int64
    public var unsupportedTierEvents: Int
    public var unsupportedTierTokens: Int64
    public var historicalRuleMissingEvents: Int
    public var historicalRuleMissingTokens: Int64
    public var unsupportedContextEvents: Int
    public var unsupportedContextTokens: Int64
    public var invalidRecordEvents: Int
    public var invalidRecordTokens: Int64
    public var overflowEvents: Int
    public var overflowTokens: Int64

    public init(
        unknownModelEvents: Int = 0,
        unknownModelTokens: Int64 = 0,
        unsupportedTierEvents: Int = 0,
        unsupportedTierTokens: Int64 = 0,
        historicalRuleMissingEvents: Int = 0,
        historicalRuleMissingTokens: Int64 = 0,
        unsupportedContextEvents: Int = 0,
        unsupportedContextTokens: Int64 = 0,
        invalidRecordEvents: Int = 0,
        invalidRecordTokens: Int64 = 0,
        overflowEvents: Int = 0,
        overflowTokens: Int64 = 0
    ) {
        self.unknownModelEvents = unknownModelEvents
        self.unknownModelTokens = unknownModelTokens
        self.unsupportedTierEvents = unsupportedTierEvents
        self.unsupportedTierTokens = unsupportedTierTokens
        self.historicalRuleMissingEvents = historicalRuleMissingEvents
        self.historicalRuleMissingTokens = historicalRuleMissingTokens
        self.unsupportedContextEvents = unsupportedContextEvents
        self.unsupportedContextTokens = unsupportedContextTokens
        self.invalidRecordEvents = invalidRecordEvents
        self.invalidRecordTokens = invalidRecordTokens
        self.overflowEvents = overflowEvents
        self.overflowTokens = overflowTokens
    }

    public static let zero = UnpricedReasonCounts()

    public var totalEvents: Int {
        unknownModelEvents
            + unsupportedTierEvents
            + historicalRuleMissingEvents
            + unsupportedContextEvents
            + invalidRecordEvents
            + overflowEvents
    }

    public var totalTokens: Int64 {
        unknownModelTokens
            + unsupportedTierTokens
            + historicalRuleMissingTokens
            + unsupportedContextTokens
            + invalidRecordTokens
            + overflowTokens
    }

    public var isEmpty: Bool {
        totalEvents == 0 && totalTokens == 0
    }

    public static func + (lhs: UnpricedReasonCounts, rhs: UnpricedReasonCounts) -> UnpricedReasonCounts {
        UnpricedReasonCounts(
            unknownModelEvents: lhs.unknownModelEvents + rhs.unknownModelEvents,
            unknownModelTokens: lhs.unknownModelTokens + rhs.unknownModelTokens,
            unsupportedTierEvents: lhs.unsupportedTierEvents + rhs.unsupportedTierEvents,
            unsupportedTierTokens: lhs.unsupportedTierTokens + rhs.unsupportedTierTokens,
            historicalRuleMissingEvents: lhs.historicalRuleMissingEvents + rhs.historicalRuleMissingEvents,
            historicalRuleMissingTokens: lhs.historicalRuleMissingTokens + rhs.historicalRuleMissingTokens,
            unsupportedContextEvents: lhs.unsupportedContextEvents + rhs.unsupportedContextEvents,
            unsupportedContextTokens: lhs.unsupportedContextTokens + rhs.unsupportedContextTokens,
            invalidRecordEvents: lhs.invalidRecordEvents + rhs.invalidRecordEvents,
            invalidRecordTokens: lhs.invalidRecordTokens + rhs.invalidRecordTokens,
            overflowEvents: lhs.overflowEvents + rhs.overflowEvents,
            overflowTokens: lhs.overflowTokens + rhs.overflowTokens
        )
    }

    public mutating func add(status: PricingStatus, tokenCount: Int64) {
        guard !status.isPriced else { return }
        let tokens = max(0, tokenCount)
        switch status {
        case .priced:
            return
        case .unpricedUnknownModel:
            unknownModelEvents += 1
            unknownModelTokens += tokens
        case .unpricedHistoricalRuleMissing:
            historicalRuleMissingEvents += 1
            historicalRuleMissingTokens += tokens
        case .unpricedUnsupportedServiceMode:
            unsupportedTierEvents += 1
            unsupportedTierTokens += tokens
        case .unpricedUnsupportedContextLength:
            unsupportedContextEvents += 1
            unsupportedContextTokens += tokens
        case .unpricedInvalidTokenRecord:
            invalidRecordEvents += 1
            invalidRecordTokens += tokens
        case .unpricedCalculationOverflow:
            overflowEvents += 1
            overflowTokens += tokens
        }
    }

    public var localizedSummary: String {
        let parts = [
            (unknownModelEvents, L10n.text("模型无法识别", "model not recognized")),
            (unsupportedTierEvents, L10n.text("服务模式暂无法估算", "service mode cannot be estimated")),
            (historicalRuleMissingEvents, L10n.text("缺少当时价格", "price at that time unavailable")),
            (unsupportedContextEvents, L10n.text("记录规格暂无法估算", "record type cannot be estimated")),
            (invalidRecordEvents, L10n.text("记录不完整", "incomplete record")),
            (overflowEvents, L10n.text("数值异常", "unusual value"))
        ]
        .filter { $0.0 > 0 }
        .map { "\($0.0) \($0.1)" }
        guard !parts.isEmpty else {
            return L10n.text("没有无法估算的记录", "No records are missing estimates")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 计价覆盖率
public enum PricingCoverage: Hashable, Sendable {
    case fullyPriced
    case partiallyPriced(coveredEvents: Int, totalEvents: Int)
    case unpriced(totalEvents: Int)

    public var coverageRatio: Double {
        switch self {
        case .fullyPriced: return 1.0
        case .partiallyPriced(let covered, let total):
            guard total > 0 else { return 1.0 }
            return Double(covered) / Double(total)
        case .unpriced: return 0.0
        }
    }
}

// MARK: - 本地日历日键 (LocalDayKey)
public struct LocalDayKey: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(date: Date, calendar: Calendar = UsageDayBucketer.calendar()) {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        self.year = comps.year ?? 1970
        self.month = comps.month ?? 1
        self.day = comps.day ?? 1
    }

    public var yyyyMMdd: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var description: String { yyyyMMdd }

    public static func < (lhs: LocalDayKey, rhs: LocalDayKey) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }

    public func date(calendar: Calendar = UsageDayBucketer.calendar()) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 0
        comps.minute = 0
        comps.second = 0
        return calendar.date(from: comps) ?? Date()
    }
}

// MARK: - 会话存储桶
public enum SessionBucket: String, Hashable, Sendable, Codable {
    case active = "active"
    case archived = "archived"

    public var localizedDescription: String {
        switch self {
        case .active: return L10n.text("活跃会话", "Active Sessions")
        case .archived: return L10n.text("归档会话", "Archived Sessions")
        }
    }
}

// MARK: - 会话排序规则
public enum SessionSort: String, CaseIterable, Identifiable, Sendable {
    case lastActivityDesc = "lastActivityDesc"
    case totalTokensDesc = "totalTokensDesc"
    case estimatedCostDesc = "estimatedCostDesc"
    case createdDesc = "createdDesc"

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .lastActivityDesc: return L10n.text("最近活动", "Recent Activity")
        case .totalTokensDesc: return L10n.text("Token 最多", "Most Tokens")
        case .estimatedCostDesc: return L10n.text("价值最高", "Highest Value")
        case .createdDesc: return L10n.text("创建时间", "Created Date")
        }
    }
}

// MARK: - 用量统计时间跨度
public enum UsageRange: Hashable, Sendable {
    case days(Int)
    case all
    case custom(Date, Date)

    public var dayCount: Int? {
        switch self {
        case .days(let d): return d
        case .all: return nil
        case .custom(let start, let end):
            let diff = end.timeIntervalSince(start)
            return max(1, Int(ceil(diff / 86400.0)))
        }
    }
}

// MARK: - 加载状态
public enum LoadState<T: Sendable>: Sendable {
    case idle
    case loading
    case loaded(T)
    case failed(String)
}

// MARK: - 数据新鲜度状态
public enum DataFreshness: Hashable, Sendable {
    case current
    case stale(lastUpdated: Date)
    case indexing(progress: Double?)
}
