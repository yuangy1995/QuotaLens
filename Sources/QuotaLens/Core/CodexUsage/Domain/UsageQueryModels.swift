// QuotaLens 用量分析查询传输对象 (Query DTOs)
// 纯不可变数据类型，供 UI 视图、ViewModel 和预测引擎消费

import Foundation

// MARK: - 会话条目 DTO
public struct CodexSessionDTO: Identifiable, Hashable, Sendable {
    public var id: String { sessionId }

    public let sessionId: String
    public let rootSessionId: String
    public let parentSessionId: String?
    public let depth: Int
    public let title: String?
    public let projectName: String?
    public let cwd: String?
    public let agentType: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let lastEventAt: Date?
    public let eventCount: Int
    public let tokens: TokenBreakdown
    public let estimatedCost: MoneyNanoUSD
    public let pricingStatus: PricingStatus
    public let bucket: SessionBucket
    public let hasSubagents: Bool
    public let subagentCount: Int

    public init(
        sessionId: String,
        rootSessionId: String,
        parentSessionId: String? = nil,
        depth: Int = 0,
        title: String? = nil,
        projectName: String? = nil,
        cwd: String? = nil,
        agentType: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        lastEventAt: Date? = nil,
        eventCount: Int = 0,
        tokens: TokenBreakdown = .zero,
        estimatedCost: MoneyNanoUSD = .zero,
        pricingStatus: PricingStatus = .unpricedUnknownModel,
        bucket: SessionBucket = .active,
        hasSubagents: Bool = false,
        subagentCount: Int = 0
    ) {
        self.sessionId = sessionId
        self.rootSessionId = rootSessionId
        self.parentSessionId = parentSessionId
        self.depth = depth
        self.title = title
        self.projectName = projectName
        self.cwd = cwd
        self.agentType = agentType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastEventAt = lastEventAt
        self.eventCount = eventCount
        self.tokens = tokens
        self.estimatedCost = estimatedCost
        self.pricingStatus = pricingStatus
        self.bucket = bucket
        self.hasSubagents = hasSubagents
        self.subagentCount = subagentCount
    }

    public var displayTitle: String {
        if let title = title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        if let project = projectName, !project.isEmpty {
            return "\(project) · \(String(sessionId.prefix(8)))"
        }
        return String(sessionId.prefix(12))
    }

    public var isSubagent: Bool {
        parentSessionId != nil && depth > 0
    }
}

// MARK: - 会话 Keyset 分页 DTO
public struct CodexSessionPageDTO: Sendable {
    public let sessions: [CodexSessionDTO]
    public let nextCursor: String?

    public init(sessions: [CodexSessionDTO], nextCursor: String?) {
        self.sessions = sessions
        self.nextCursor = nextCursor
    }
}

// MARK: - 会话完整详情 DTO
public struct CodexSessionDetailDTO: Sendable {
    public let session: CodexSessionDTO
    public let subagents: [CodexSessionDTO]
    public let modelSummaries: [ModelUsageSummaryDTO]
    public let recentEvents: [CodexUsageEventDTO]
    public let sourcePath: String
    public let relativePath: String
    public let totalSubagentTokens: TokenBreakdown
    public let totalSubagentCost: MoneyNanoUSD

    public init(
        session: CodexSessionDTO,
        subagents: [CodexSessionDTO] = [],
        modelSummaries: [ModelUsageSummaryDTO] = [],
        recentEvents: [CodexUsageEventDTO] = [],
        sourcePath: String = "",
        relativePath: String = "",
        totalSubagentTokens: TokenBreakdown = .zero,
        totalSubagentCost: MoneyNanoUSD = .zero
    ) {
        self.session = session
        self.subagents = subagents
        self.modelSummaries = modelSummaries
        self.recentEvents = recentEvents
        self.sourcePath = sourcePath
        self.relativePath = relativePath
        self.totalSubagentTokens = totalSubagentTokens
        self.totalSubagentCost = totalSubagentCost
    }
}

// MARK: - 精确事件 DTO
public struct CodexUsageEventDTO: Identifiable, Hashable, Sendable {
    public var id: String { eventId }

    public let eventId: String
    public let sessionId: String
    public let rootSessionId: String
    public let turnIndex: Int
    public let callIndex: Int
    public let timestamp: Date
    public let modelRaw: String
    public let modelCanonical: String
    public let serviceTier: String?
    public let reasoningEffort: String?
    public let tokens: TokenBreakdown
    public let estimatedCost: MoneyNanoUSD
    public let pricingRuleId: String?
    public let pricingStatus: PricingStatus
    public let pricingCatalogVersion: String?
    public let usageDerivation: UsageDerivation
    public let attributionQuality: AttributionQuality
    public let timestampQuality: TimestampQuality
    public let isChildReplay: Bool
    public let sourcePath: String
    public let lineOffset: Int64

    public init(
        eventId: String,
        sessionId: String,
        rootSessionId: String,
        turnIndex: Int,
        callIndex: Int,
        timestamp: Date,
        modelRaw: String,
        modelCanonical: String,
        serviceTier: String? = nil,
        reasoningEffort: String? = nil,
        tokens: TokenBreakdown,
        estimatedCost: MoneyNanoUSD,
        pricingRuleId: String? = nil,
        pricingStatus: PricingStatus,
        pricingCatalogVersion: String? = nil,
        usageDerivation: UsageDerivation,
        attributionQuality: AttributionQuality,
        timestampQuality: TimestampQuality = .eventTimestamp,
        isChildReplay: Bool = false,
        sourcePath: String = "",
        lineOffset: Int64 = 0
    ) {
        self.eventId = eventId
        self.sessionId = sessionId
        self.rootSessionId = rootSessionId
        self.turnIndex = turnIndex
        self.callIndex = callIndex
        self.timestamp = timestamp
        self.modelRaw = modelRaw
        self.modelCanonical = modelCanonical
        self.serviceTier = serviceTier
        self.reasoningEffort = reasoningEffort
        self.tokens = tokens
        self.estimatedCost = estimatedCost
        self.pricingRuleId = pricingRuleId
        self.pricingStatus = pricingStatus
        self.pricingCatalogVersion = pricingCatalogVersion
        self.usageDerivation = usageDerivation
        self.attributionQuality = attributionQuality
        self.timestampQuality = timestampQuality
        self.isChildReplay = isChildReplay
        self.sourcePath = sourcePath
        self.lineOffset = lineOffset
    }
}

// MARK: - 模型用量汇总 DTO
public struct ModelUsageSummaryDTO: Identifiable, Hashable, Sendable {
    public var id: String { modelCanonical }

    public let modelCanonical: String
    public let tokens: TokenBreakdown
    public let estimatedCost: MoneyNanoUSD
    public let eventCount: Int
    public let unpricedCount: Int

    public init(
        modelCanonical: String,
        tokens: TokenBreakdown,
        estimatedCost: MoneyNanoUSD,
        eventCount: Int,
        unpricedCount: Int = 0
    ) {
        self.modelCanonical = modelCanonical
        self.tokens = tokens
        self.estimatedCost = estimatedCost
        self.eventCount = eventCount
        self.unpricedCount = unpricedCount
    }
}

// MARK: - 每日用量汇总 DTO
public struct DayUsageSummaryDTO: Identifiable, Hashable, Sendable {
    public var id: String { dayKey.yyyyMMdd }

    public let dayKey: LocalDayKey
    public let date: Date
    public let tokens: TokenBreakdown
    public let estimatedCost: MoneyNanoUSD
    public let eventCount: Int
    public let sessionCount: Int
    public let modelSummaries: [ModelUsageSummaryDTO]
    public let unpricedEventCount: Int
    public let unpricedTokenCount: Int64

    public init(
        dayKey: LocalDayKey,
        date: Date,
        tokens: TokenBreakdown = .zero,
        estimatedCost: MoneyNanoUSD = .zero,
        eventCount: Int = 0,
        sessionCount: Int = 0,
        modelSummaries: [ModelUsageSummaryDTO] = [],
        unpricedEventCount: Int = 0,
        unpricedTokenCount: Int64 = 0
    ) {
        self.dayKey = dayKey
        self.date = date
        self.tokens = tokens
        self.estimatedCost = estimatedCost
        self.eventCount = eventCount
        self.sessionCount = sessionCount
        self.modelSummaries = modelSummaries
        self.unpricedEventCount = unpricedEventCount
        self.unpricedTokenCount = unpricedTokenCount
    }
}

// MARK: - 单日内会话切片 DTO
public struct DaySessionSliceDTO: Identifiable, Hashable, Sendable {
    public var id: String { session.sessionId }

    public let session: CodexSessionDTO
    public let dayTokens: TokenBreakdown
    public let dayCost: MoneyNanoUSD
    public let dayEventCount: Int
    public let events: [CodexUsageEventDTO]

    public init(
        session: CodexSessionDTO,
        dayTokens: TokenBreakdown,
        dayCost: MoneyNanoUSD,
        dayEventCount: Int,
        events: [CodexUsageEventDTO] = []
    ) {
        self.session = session
        self.dayTokens = dayTokens
        self.dayCost = dayCost
        self.dayEventCount = dayEventCount
        self.events = events
    }
}

// MARK: - 单日详情 DTO
public struct DayDetailDTO: Sendable {
    public let summary: DayUsageSummaryDTO
    public let sessions: [DaySessionSliceDTO]

    public init(summary: DayUsageSummaryDTO, sessions: [DaySessionSliceDTO] = []) {
        self.summary = summary
        self.sessions = sessions
    }
}

// MARK: - 仪表盘全局指标 DTO
public struct DashboardMetricsDTO: Sendable {
    public let totalTokens: TokenBreakdown
    public let totalCost: MoneyNanoUSD
    public let totalEvents: Int
    public let totalSessions: Int
    public let activeDaysCount: Int
    public let cacheHitRatio: Double
    public let dailyBuckets: [DayUsageSummaryDTO]
    public let modelDistribution: [ModelUsageSummaryDTO]
    public let todayTokens: TokenBreakdown
    public let todayCost: MoneyNanoUSD
    public let pricingCoverage: PricingCoverage

    public init(
        totalTokens: TokenBreakdown = .zero,
        totalCost: MoneyNanoUSD = .zero,
        totalEvents: Int = 0,
        totalSessions: Int = 0,
        activeDaysCount: Int = 0,
        cacheHitRatio: Double = 0.0,
        dailyBuckets: [DayUsageSummaryDTO] = [],
        modelDistribution: [ModelUsageSummaryDTO] = [],
        todayTokens: TokenBreakdown = .zero,
        todayCost: MoneyNanoUSD = .zero,
        pricingCoverage: PricingCoverage = .fullyPriced
    ) {
        self.totalTokens = totalTokens
        self.totalCost = totalCost
        self.totalEvents = totalEvents
        self.totalSessions = totalSessions
        self.activeDaysCount = activeDaysCount
        self.cacheHitRatio = cacheHitRatio
        self.dailyBuckets = dailyBuckets
        self.modelDistribution = modelDistribution
        self.todayTokens = todayTokens
        self.todayCost = todayCost
        self.pricingCoverage = pricingCoverage
    }
}

// MARK: - 活动热力图格子 DTO
public struct ActivityHeatmapCellDTO: Identifiable, Hashable, Sendable {
    public var id: String { dayKey.yyyyMMdd }

    public let date: Date
    public let dayKey: LocalDayKey
    public let tokenCount: Int64
    public let eventCount: Int
    public let estimatedCost: MoneyNanoUSD
    public let intensityLevel: Int // 0, 1, 2, 3, 4

    public init(
        date: Date,
        dayKey: LocalDayKey,
        tokenCount: Int64,
        eventCount: Int,
        estimatedCost: MoneyNanoUSD = .zero,
        intensityLevel: Int
    ) {
        self.date = date
        self.dayKey = dayKey
        self.tokenCount = tokenCount
        self.eventCount = eventCount
        self.estimatedCost = estimatedCost
        self.intensityLevel = min(max(0, intensityLevel), 4)
    }
}

// MARK: - 画像统计 DTO
public struct ActivityStatsDTO: Sendable {
    public let currentStreak: Int
    public let longestStreak: Int
    public let peakDayKey: LocalDayKey?
    public let peakTokens: Int64
    public let mostUsedModel: String?

    public init(
        currentStreak: Int = 0,
        longestStreak: Int = 0,
        peakDayKey: LocalDayKey? = nil,
        peakTokens: Int64 = 0,
        mostUsedModel: String? = nil
    ) {
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.peakDayKey = peakDayKey
        self.peakTokens = peakTokens
        self.mostUsedModel = mostUsedModel
    }
}

// MARK: - 本地用量诊断 DTO
public struct UsageDiagnosticsDTO: Codable, Sendable {
    public let sourcesDiscovered: Int
    public let sourcesIndexed: Int
    public let sourcesTombstoned: Int
    public let unknownModelEvents: Int
    public let unpricedEvents: Int
    public let fallbackTimestampEvents: Int
    public let totalEvents: Int
    public let activePricingCatalogVersion: String?
    public let parserVersion: Int
    public let lastSuccessfulScanAt: Date?
    public let malformedLineCount: Int
    public let unresolvedTimestampCount: Int
    public let unknownEventTypeCount: Int
    public let rebuiltSourceCount: Int
    public let integrityCheckPassed: Bool
    public let foreignKeyViolationCount: Int
    public let invariantViolationCount: Int

    public init(
        sourcesDiscovered: Int = 0,
        sourcesIndexed: Int = 0,
        sourcesTombstoned: Int = 0,
        unknownModelEvents: Int = 0,
        unpricedEvents: Int = 0,
        fallbackTimestampEvents: Int = 0,
        totalEvents: Int = 0,
        activePricingCatalogVersion: String? = nil,
        parserVersion: Int = ParserCheckpoint.currentParserVersion,
        lastSuccessfulScanAt: Date? = nil,
        malformedLineCount: Int = 0,
        unresolvedTimestampCount: Int = 0,
        unknownEventTypeCount: Int = 0,
        rebuiltSourceCount: Int = 0,
        integrityCheckPassed: Bool = true,
        foreignKeyViolationCount: Int = 0,
        invariantViolationCount: Int = 0
    ) {
        self.sourcesDiscovered = sourcesDiscovered
        self.sourcesIndexed = sourcesIndexed
        self.sourcesTombstoned = sourcesTombstoned
        self.unknownModelEvents = unknownModelEvents
        self.unpricedEvents = unpricedEvents
        self.fallbackTimestampEvents = fallbackTimestampEvents
        self.totalEvents = totalEvents
        self.activePricingCatalogVersion = activePricingCatalogVersion
        self.parserVersion = parserVersion
        self.lastSuccessfulScanAt = lastSuccessfulScanAt
        self.malformedLineCount = malformedLineCount
        self.unresolvedTimestampCount = unresolvedTimestampCount
        self.unknownEventTypeCount = unknownEventTypeCount
        self.rebuiltSourceCount = rebuiltSourceCount
        self.integrityCheckPassed = integrityCheckPassed
        self.foreignKeyViolationCount = foreignKeyViolationCount
        self.invariantViolationCount = invariantViolationCount
    }
}

/// Privacy-safe aggregate diagnostics export. It intentionally contains no
/// prompts, responses, tool output, event payloads, or source file paths.
public struct UsageDiagnosticsExport: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let containsConversationContent: Bool
    public let diagnostics: UsageDiagnosticsDTO

    public init(
        schemaVersion: Int = 1,
        generatedAt: Date = Date(),
        diagnostics: UsageDiagnosticsDTO
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.containsConversationContent = false
        self.diagnostics = diagnostics
    }

    public func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(self)
    }
}
