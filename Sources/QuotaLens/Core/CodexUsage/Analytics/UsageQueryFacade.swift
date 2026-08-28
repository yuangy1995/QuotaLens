// QuotaLens 用量分析统一查询门面 (UsageQueryFacade)
// 隔离 UI 与数据库访问，保证全部查询在非主线程执行

import Foundation

public actor UsageQueryFacade {
    private let repository: UsageAnalyticsRepository

    public init(database: SQLiteDatabase) {
        self.repository = UsageAnalyticsRepository(database: database)
    }

    public func getProjectNames() throws -> [String] {
        try repository.fetchProjectNames()
    }

    public func getSessions(
        sort: SessionSort = .lastActivityDesc,
        search: String? = nil,
        project: String? = nil,
        limit: Int = 50,
        cursor: String? = nil
    ) throws -> [CodexSessionDTO] {
        try repository.fetchSessions(sort: sort, search: search, project: project, limit: limit, cursor: cursor)
    }

    public func getSessionPage(
        sort: SessionSort = .lastActivityDesc,
        search: String? = nil,
        project: String? = nil,
        limit: Int = 50,
        cursor: String? = nil
    ) throws -> CodexSessionPageDTO {
        try repository.fetchSessionPage(sort: sort, search: search, project: project, limit: limit, cursor: cursor)
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
        now: Date = Date()
    ) throws -> [DayUsageSummaryDTO] {
        try repository.fetchHistoryDays(daysCount: daysCount, calendar: calendar, now: now)
    }

    public func getDayDetail(
        dayKey: LocalDayKey,
        calendar: Calendar = UsageDayBucketer.calendar(),
        eventLimit: Int = 500,
        eventCursor: String? = nil
    ) throws -> DayDetailDTO {
        try repository.fetchDayDetail(
            dayKey: dayKey,
            calendar: calendar,
            eventLimit: eventLimit,
            eventCursor: eventCursor
        )
    }

    public func getDashboardMetrics(days: Int = 30, calendar: Calendar = UsageDayBucketer.calendar()) throws -> DashboardMetricsDTO {
        try repository.fetchDashboardMetrics(days: days, calendar: calendar)
    }

    public func getTodayMetrics(calendar: Calendar = UsageDayBucketer.calendar()) throws -> DashboardMetricsDTO {
        try repository.fetchTodayMetrics(calendar: calendar)
    }

    public func getActivityHeatmap(year: Int = UsageDayBucketer.calendar().component(.year, from: Date()), calendar: Calendar = UsageDayBucketer.calendar()) throws -> [ActivityHeatmapCellDTO] {
        try repository.fetchActivityHeatmap(year: year, calendar: calendar)
    }

    public func getRecentRateLimitSnapshots(accountKey: String? = nil, limit: Int = 50) throws -> [RateLimitSnapshotRecord] {
        try repository.fetchRecentRateLimitSnapshots(accountKey: accountKey, limit: limit)
    }

    public func getDiagnostics() throws -> UsageDiagnosticsDTO {
        try repository.fetchDiagnostics()
    }
}
