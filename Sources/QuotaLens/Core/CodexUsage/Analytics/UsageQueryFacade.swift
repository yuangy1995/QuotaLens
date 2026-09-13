// QuotaLens 用量分析统一查询门面 (UsageQueryFacade)
// 隔离 UI 与数据库访问，保证全部查询在非主线程执行

import Foundation

public actor UsageQueryFacade {
    private let repository: UsageAnalyticsRepository

    public init(database: SQLiteDatabase) {
        self.repository = UsageAnalyticsRepository(database: database)
    }

    public func getProjectNames(providerFilter: UsageProviderFilter = .all) throws -> [String] {
        try repository.fetchProjectNames(providerFilter: providerFilter)
    }

    func getOverviewAnalysis(days: Int, provider: UsageProvider, now: Date = Date()) async throws -> OverviewAnalysis {
        let calendar = UsageDayBucketer.calendar()
        let period = OverviewPeriod(days: days, now: now, calendar: calendar)
        let filter = UsageProviderFilter(rawValue: provider.rawValue)!
        let current = try repository.fetchDashboardMetrics(rangeStart: period.start, endExclusive: period.end,
            calendar: calendar, providerFilter: filter)
        let previous = try repository.fetchDashboardMetrics(rangeStart: period.previousStart, endExclusive: period.previousEnd,
            calendar: calendar, providerFilter: filter)
        var slices: [DaySessionSliceDTO] = []
        var complete = true
        for day in current.dailyBuckets {
            try Task.checkCancellation()
            do {
                let detail = try repository.fetchDayDetail(dayKey: day.dayKey, calendar: calendar,
                    eventLimit: 1, providerFilter: filter, endExclusive: period.end)
                slices.append(contentsOf: detail.sessions)
            } catch { complete = false }
            await Task.yield()
        }
        // Day slices can contain events ingested after this analysis started. Do not label
        // a different set of records as an exact contribution breakdown.
        let merged = OverviewAnalysis.merge(slices)
        let matched = merged.reduce(Int64(0)) { $0 + $1.tokens } == current.totalTokens.canonicalTotalTokens
            && merged.reduce(MoneyNanoUSD.zero) { $0 + $1.cost } == current.totalCost
        var priorSlices: [DaySessionSliceDTO] = []
        var priorComplete = true
        for day in previous.dailyBuckets where day.eventCount > 0 || day.tokens.canonicalTotalTokens > 0 {
            try Task.checkCancellation()
            do {
                let detail = try repository.fetchDayDetail(dayKey: day.dayKey, calendar: calendar,
                    eventLimit: 1, providerFilter: filter, endExclusive: period.previousEnd)
                priorSlices.append(contentsOf: detail.sessions)
            } catch { priorComplete = false }
            await Task.yield()
        }
        let prior = OverviewAnalysis.merge(priorSlices)
        priorComplete = priorComplete && prior.reduce(Int64(0)) { $0 + $1.tokens } == previous.totalTokens.canonicalTotalTokens
            && prior.reduce(MoneyNanoUSD.zero) { $0 + $1.cost } == previous.totalCost
        return OverviewAnalysis(period: period, current: current, previous: previous,
                                sessions: complete && matched ? merged : [], contributionsAvailable: complete && matched,
                                previousSessions: priorComplete ? prior : nil)
    }

    public func getSessions(
        sort: SessionSort = .lastActivityDesc,
        search: String? = nil,
        project: String? = nil,
        limit: Int = 50,
        cursor: String? = nil,
        providerFilter: UsageProviderFilter = .all
    ) throws -> [CodexSessionDTO] {
        try repository.fetchSessions(sort: sort, search: search, project: project, limit: limit, cursor: cursor, providerFilter: providerFilter)
    }

    public func getSessionPage(
        sort: SessionSort = .lastActivityDesc,
        search: String? = nil,
        project: String? = nil,
        limit: Int = 50,
        cursor: String? = nil,
        providerFilter: UsageProviderFilter = .all
    ) throws -> CodexSessionPageDTO {
        try repository.fetchSessionPage(sort: sort, search: search, project: project, limit: limit, cursor: cursor, providerFilter: providerFilter)
    }

    public func getSessionDetail(
        sessionId: String,
        eventLimit: Int = 500,
        eventCursor: String? = nil
    ) throws -> CodexSessionDetailDTO? {
        try repository.fetchSessionDetail(
            sessionId: sessionId,
            eventLimit: eventLimit,
            eventCursor: eventCursor
        )
    }

    public func getSessionConversation(sessionId: String) throws -> CodexSessionConversationDTO? {
        try repository.fetchSessionConversation(sessionId: sessionId)
    }

    public func deleteSession(sessionId: String) throws {
        try repository.deleteSession(sessionId: sessionId)
    }

    public func previewMissingSourceCleanup(
        historyRootURL: URL? = nil
    ) throws -> MissingSourceCleanupPreviewDTO {
        try repository.previewMissingSourceCleanup(historyRootURL: historyRootURL)
    }

    public func cleanupMissingSourceIndexes(
        previewId: String,
        historyRootURL: URL? = nil
    ) throws -> MissingSourceCleanupResultDTO {
        try repository.cleanupMissingSourceIndexes(
            previewId: previewId,
            historyRootURL: historyRootURL
        )
    }

    public func recoverIncompleteSessionDeletions(
        historyRootURL: URL? = nil
    ) throws -> SessionDeletionRecoverySummary {
        try repository.recoverIncompleteSessionDeletions(historyRootURL: historyRootURL)
    }

    public func getHistoryDays(
        daysCount: Int = 30,
        calendar: Calendar = UsageDayBucketer.calendar(),
        now: Date = Date(),
        providerFilter: UsageProviderFilter = .all
    ) throws -> [DayUsageSummaryDTO] {
        try repository.fetchHistoryDays(daysCount: daysCount, calendar: calendar, now: now, providerFilter: providerFilter)
    }

    public func getDayDetail(
        dayKey: LocalDayKey,
        calendar: Calendar = UsageDayBucketer.calendar(),
        eventLimit: Int = 500,
        eventCursor: String? = nil,
        providerFilter: UsageProviderFilter = .all
    ) throws -> DayDetailDTO {
        try repository.fetchDayDetail(
            dayKey: dayKey,
            calendar: calendar,
            eventLimit: eventLimit,
            eventCursor: eventCursor,
            providerFilter: providerFilter
        )
    }

    public func getDashboardMetrics(days: Int = 30, calendar: Calendar = UsageDayBucketer.calendar(), providerFilter: UsageProviderFilter = .all) throws -> DashboardMetricsDTO {
        try repository.fetchDashboardMetrics(days: days, calendar: calendar, providerFilter: providerFilter)
    }

    public func getTodayMetrics(calendar: Calendar = UsageDayBucketer.calendar(), providerFilter: UsageProviderFilter = .all) throws -> DashboardMetricsDTO {
        try repository.fetchTodayMetrics(calendar: calendar, providerFilter: providerFilter)
    }

    public func getActivityHeatmap(year: Int = UsageDayBucketer.calendar().component(.year, from: Date()), calendar: Calendar = UsageDayBucketer.calendar(), providerFilter: UsageProviderFilter = .all) throws -> [ActivityHeatmapCellDTO] {
        try repository.fetchActivityHeatmap(year: year, calendar: calendar, providerFilter: providerFilter)
    }

    public func getRecentRateLimitSnapshots(accountKey: String? = nil, provider: UsageProvider? = nil, limit: Int = 50) throws -> [RateLimitSnapshotRecord] {
        try repository.fetchRecentRateLimitSnapshots(accountKey: accountKey, provider: provider, limit: limit)
    }

    public func getDiagnostics() throws -> UsageDiagnosticsDTO {
        try repository.fetchDiagnostics()
    }
}
