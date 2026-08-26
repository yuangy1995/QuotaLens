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
    public let pricingStatus: AggregatePricingStatus
    public let summaryProvenance: SummaryProvenance
    public let unpricedReasonCounts: UnpricedReasonCounts
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
        pricingStatus: AggregatePricingStatus = .fullyUnpriced,
        summaryProvenance: SummaryProvenance = .eventLedger,
        unpricedReasonCounts: UnpricedReasonCounts = .zero,
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
        self.summaryProvenance = summaryProvenance
        self.unpricedReasonCounts = unpricedReasonCounts
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
    public let totalEventCount: Int
    public let loadedEventCount: Int
    public let hasMoreEvents: Bool
    public let nextEventCursor: String?
    public let sourcePath: String
    public let relativePath: String
    public let totalSubagentTokens: TokenBreakdown
    public let totalSubagentCost: MoneyNanoUSD

    public init(
        session: CodexSessionDTO,
        subagents: [CodexSessionDTO] = [],
        modelSummaries: [ModelUsageSummaryDTO] = [],
        recentEvents: [CodexUsageEventDTO] = [],
        totalEventCount: Int? = nil,
        loadedEventCount: Int? = nil,
        hasMoreEvents: Bool = false,
        nextEventCursor: String? = nil,
        sourcePath: String = "",
        relativePath: String = "",
        totalSubagentTokens: TokenBreakdown = .zero,
        totalSubagentCost: MoneyNanoUSD = .zero
    ) {
        self.session = session
        self.subagents = subagents
        self.modelSummaries = modelSummaries
        self.recentEvents = recentEvents
        self.totalEventCount = totalEventCount ?? recentEvents.count
        self.loadedEventCount = loadedEventCount ?? recentEvents.count
        self.hasMoreEvents = hasMoreEvents
        self.nextEventCursor = nextEventCursor
        self.sourcePath = sourcePath
        self.relativePath = relativePath
        self.totalSubagentTokens = totalSubagentTokens
        self.totalSubagentCost = totalSubagentCost
    }
}

public struct CodexUsageEventPageDTO: Sendable {
    public let events: [CodexUsageEventDTO]
    public let totalEventCount: Int
    public let loadedEventCount: Int
    public let hasMore: Bool
    public let nextCursor: String?

    public init(
        events: [CodexUsageEventDTO],
        totalEventCount: Int,
        loadedEventCount: Int? = nil,
        hasMore: Bool,
        nextCursor: String?
    ) {
        self.events = events
        self.totalEventCount = totalEventCount
        self.loadedEventCount = loadedEventCount ?? events.count
        self.hasMore = hasMore
        self.nextCursor = nextCursor
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
    public let timestampSource: TimestampSource
    public let timestampConflictCount: Int
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
        timestampSource: TimestampSource = .topLevelTimestamp,
        timestampConflictCount: Int = 0,
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
        self.timestampSource = timestampSource
        self.timestampConflictCount = timestampConflictCount
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
    public let unpricedReasonCounts: UnpricedReasonCounts
    public let summaryProvenance: SummaryProvenance

    public init(
        modelCanonical: String,
        tokens: TokenBreakdown,
        estimatedCost: MoneyNanoUSD,
        eventCount: Int,
        unpricedCount: Int = 0,
        unpricedReasonCounts: UnpricedReasonCounts = .zero,
        summaryProvenance: SummaryProvenance = .eventLedger
    ) {
        self.modelCanonical = modelCanonical
        self.tokens = tokens
        self.estimatedCost = estimatedCost
        self.eventCount = eventCount
        self.unpricedCount = unpricedCount
        self.unpricedReasonCounts = unpricedReasonCounts
        self.summaryProvenance = summaryProvenance
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
    public let unpricedReasonCounts: UnpricedReasonCounts
    public let legacyAggregateTokens: Int64
    public let legacyAggregateCost: MoneyNanoUSD

    public init(
        dayKey: LocalDayKey,
        date: Date,
        tokens: TokenBreakdown = .zero,
        estimatedCost: MoneyNanoUSD = .zero,
        eventCount: Int = 0,
        sessionCount: Int = 0,
        modelSummaries: [ModelUsageSummaryDTO] = [],
        unpricedEventCount: Int = 0,
        unpricedTokenCount: Int64 = 0,
        unpricedReasonCounts: UnpricedReasonCounts = .zero,
        legacyAggregateTokens: Int64 = 0,
        legacyAggregateCost: MoneyNanoUSD = .zero
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
        self.unpricedReasonCounts = unpricedReasonCounts
        self.legacyAggregateTokens = legacyAggregateTokens
        self.legacyAggregateCost = legacyAggregateCost
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
    public let totalEventCount: Int
    public let loadedEventCount: Int
    public let hasMoreEvents: Bool
    public let nextEventCursor: String?

    public init(
        summary: DayUsageSummaryDTO,
        sessions: [DaySessionSliceDTO] = [],
        totalEventCount: Int? = nil,
        loadedEventCount: Int? = nil,
        hasMoreEvents: Bool = false,
        nextEventCursor: String? = nil
    ) {
        self.summary = summary
        self.sessions = sessions
        self.totalEventCount = totalEventCount ?? sessions.reduce(0) { $0 + $1.events.count }
        self.loadedEventCount = loadedEventCount ?? sessions.reduce(0) { $0 + $1.events.count }
        self.hasMoreEvents = hasMoreEvents
        self.nextEventCursor = nextEventCursor
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
    public let eventPricingCoverage: Double
    public let tokenPricingCoverage: Double
    public let costForecastCoverage: Double
    public let unpricedReasonCounts: UnpricedReasonCounts
    public let legacyAggregateTokens: Int64
    public let legacyAggregateCost: MoneyNanoUSD
    public let legacyAggregateEventCount: Int
    public let currentCatalogCoverage: Double

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
        pricingCoverage: PricingCoverage = .fullyPriced,
        eventPricingCoverage: Double = 1.0,
        tokenPricingCoverage: Double = 1.0,
        costForecastCoverage: Double = 1.0,
        unpricedReasonCounts: UnpricedReasonCounts = .zero,
        legacyAggregateTokens: Int64 = 0,
        legacyAggregateCost: MoneyNanoUSD = .zero,
        legacyAggregateEventCount: Int = 0,
        currentCatalogCoverage: Double = 1.0
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
        self.eventPricingCoverage = eventPricingCoverage
        self.tokenPricingCoverage = tokenPricingCoverage
        self.costForecastCoverage = costForecastCoverage
        self.unpricedReasonCounts = unpricedReasonCounts
        self.legacyAggregateTokens = legacyAggregateTokens
        self.legacyAggregateCost = legacyAggregateCost
        self.legacyAggregateEventCount = legacyAggregateEventCount
        self.currentCatalogCoverage = currentCatalogCoverage
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
    public let legacyAggregateCost: MoneyNanoUSD
    public let intensityLevel: Int // 0, 1, 2, 3, 4

    public init(
        date: Date,
        dayKey: LocalDayKey,
        tokenCount: Int64,
        eventCount: Int,
        estimatedCost: MoneyNanoUSD = .zero,
        legacyAggregateCost: MoneyNanoUSD = .zero,
        intensityLevel: Int
    ) {
        self.date = date
        self.dayKey = dayKey
        self.tokenCount = tokenCount
        self.eventCount = eventCount
        self.estimatedCost = estimatedCost
        self.legacyAggregateCost = legacyAggregateCost
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
    public let genericGPT56Events: Int
    public let unpricedEvents: Int
    public let unpricedTokens: Int64
    public let unpricedReasonCounts: UnpricedReasonCounts
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
    public let pricingRepriceGeneration: Int64
    public let pricingRepriceStatus: String
    public let pricingMigrationState: PricingMigrationState
    public let pricingRepriceLastRowID: Int64
    public let pricingRepriceProcessedEvents: Int
    public let pricingRepriceTotalEvents: Int
    public let usageAggregationTimeZoneID: String?
    public let usageAggregationGeneration: Int64
    public let parserRebuildStatus: String
    public let parserRebuildGeneration: Int64
    public let parserRebuildProcessedSources: Int
    public let parserRebuildTotalSources: Int
    public let skippedNonRolloutJSONLCount: Int
    public let pendingSourceCount: Int
    public let missingSourceCount: Int
    public let legacyAggregateSessionCount: Int
    public let legacyAggregateEventCount: Int
    public let legacyAggregateTokens: Int64
    public let legacyAggregateCost: MoneyNanoUSD
    public let timestampConflictCount: Int
    public let pendingDeletionJournalCount: Int
    public let rollbackRequiredDeletionJournalCount: Int

    public init(
        sourcesDiscovered: Int = 0,
        sourcesIndexed: Int = 0,
        sourcesTombstoned: Int = 0,
        unknownModelEvents: Int = 0,
        genericGPT56Events: Int = 0,
        unpricedEvents: Int = 0,
        unpricedTokens: Int64 = 0,
        unpricedReasonCounts: UnpricedReasonCounts = .zero,
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
        invariantViolationCount: Int = 0,
        pricingRepriceGeneration: Int64 = 0,
        pricingRepriceStatus: String = "completed",
        pricingMigrationState: PricingMigrationState = .fullyCurrent,
        pricingRepriceLastRowID: Int64 = 0,
        pricingRepriceProcessedEvents: Int = 0,
        pricingRepriceTotalEvents: Int = 0,
        usageAggregationTimeZoneID: String? = nil,
        usageAggregationGeneration: Int64 = 0,
        parserRebuildStatus: String = "completed",
        parserRebuildGeneration: Int64 = 0,
        parserRebuildProcessedSources: Int = 0,
        parserRebuildTotalSources: Int = 0,
        skippedNonRolloutJSONLCount: Int = 0,
        pendingSourceCount: Int = 0,
        missingSourceCount: Int = 0,
        legacyAggregateSessionCount: Int = 0,
        legacyAggregateEventCount: Int = 0,
        legacyAggregateTokens: Int64 = 0,
        legacyAggregateCost: MoneyNanoUSD = .zero,
        timestampConflictCount: Int = 0,
        pendingDeletionJournalCount: Int = 0,
        rollbackRequiredDeletionJournalCount: Int = 0
    ) {
        self.sourcesDiscovered = sourcesDiscovered
        self.sourcesIndexed = sourcesIndexed
        self.sourcesTombstoned = sourcesTombstoned
        self.unknownModelEvents = unknownModelEvents
        self.genericGPT56Events = genericGPT56Events
        self.unpricedEvents = unpricedEvents
        self.unpricedTokens = unpricedTokens
        self.unpricedReasonCounts = unpricedReasonCounts
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
        self.pricingRepriceGeneration = pricingRepriceGeneration
        self.pricingRepriceStatus = pricingRepriceStatus
        self.pricingMigrationState = pricingMigrationState
        self.pricingRepriceLastRowID = pricingRepriceLastRowID
        self.pricingRepriceProcessedEvents = pricingRepriceProcessedEvents
        self.pricingRepriceTotalEvents = pricingRepriceTotalEvents
        self.usageAggregationTimeZoneID = usageAggregationTimeZoneID
        self.usageAggregationGeneration = usageAggregationGeneration
        self.parserRebuildStatus = parserRebuildStatus
        self.parserRebuildGeneration = parserRebuildGeneration
        self.parserRebuildProcessedSources = parserRebuildProcessedSources
        self.parserRebuildTotalSources = parserRebuildTotalSources
        self.skippedNonRolloutJSONLCount = skippedNonRolloutJSONLCount
        self.pendingSourceCount = pendingSourceCount
        self.missingSourceCount = missingSourceCount
        self.legacyAggregateSessionCount = legacyAggregateSessionCount
        self.legacyAggregateEventCount = legacyAggregateEventCount
        self.legacyAggregateTokens = legacyAggregateTokens
        self.legacyAggregateCost = legacyAggregateCost
        self.timestampConflictCount = timestampConflictCount
        self.pendingDeletionJournalCount = pendingDeletionJournalCount
        self.rollbackRequiredDeletionJournalCount = rollbackRequiredDeletionJournalCount
    }
}

// MARK: - 缺失来源清理预览
public struct MissingSourceCleanupItemDTO: Identifiable, Hashable, Codable, Sendable {
    public var id: String { sourcePath }

    public let sourcePath: String
    public let relativePath: String
    public let bucket: SessionBucket
    public let sessionCount: Int
    public let totalTokens: Int64
    public let estimatedCost: MoneyNanoUSD
    public let status: String

    public init(
        sourcePath: String,
        relativePath: String,
        bucket: SessionBucket,
        sessionCount: Int,
        totalTokens: Int64,
        estimatedCost: MoneyNanoUSD,
        status: String
    ) {
        self.sourcePath = sourcePath
        self.relativePath = relativePath
        self.bucket = bucket
        self.sessionCount = sessionCount
        self.totalTokens = totalTokens
        self.estimatedCost = estimatedCost
        self.status = status
    }
}

public struct MissingSourceCleanupPreviewDTO: Hashable, Codable, Sendable {
    public let previewId: String
    public let generatedAt: Date
    public let items: [MissingSourceCleanupItemDTO]
    public let totalSessions: Int
    public let totalTokens: Int64
    public let estimatedCost: MoneyNanoUSD

    public init(
        previewId: String,
        generatedAt: Date = Date(),
        items: [MissingSourceCleanupItemDTO],
        totalSessions: Int,
        totalTokens: Int64,
        estimatedCost: MoneyNanoUSD
    ) {
        self.previewId = previewId
        self.generatedAt = generatedAt
        self.items = items
        self.totalSessions = totalSessions
        self.totalTokens = totalTokens
        self.estimatedCost = estimatedCost
    }
}

public struct MissingSourceCleanupResultDTO: Hashable, Codable, Sendable {
    public let sourcesRemoved: Int
    public let sessionsRemoved: Int
    public let tokensRemoved: Int64
    public let estimatedCostRemoved: MoneyNanoUSD

    public init(
        sourcesRemoved: Int,
        sessionsRemoved: Int,
        tokensRemoved: Int64,
        estimatedCostRemoved: MoneyNanoUSD
    ) {
        self.sourcesRemoved = sourcesRemoved
        self.sessionsRemoved = sessionsRemoved
        self.tokensRemoved = tokensRemoved
        self.estimatedCostRemoved = estimatedCostRemoved
    }
}

public struct SessionDeletionRecoverySummary: Hashable, Codable, Sendable {
    public let finalizedCount: Int
    public let rolledBackCount: Int
    public let rollbackRequiredCount: Int
    public let message: String?

    public init(
        finalizedCount: Int = 0,
        rolledBackCount: Int = 0,
        rollbackRequiredCount: Int = 0,
        message: String? = nil
    ) {
        self.finalizedCount = finalizedCount
        self.rolledBackCount = rolledBackCount
        self.rollbackRequiredCount = rollbackRequiredCount
        self.message = message
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
