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

    public func getSessionDetail(sessionId: String) throws -> CodexSessionDetailDTO? {
        try repository.fetchSessionDetail(sessionId: sessionId)
    }

    public func deleteSession(sessionId: String) throws {
        try repository.deleteSession(sessionId: sessionId)
    }

    public func getHistoryDays(
        daysCount: Int = 30,
        calendar: Calendar = .current,
        now: Date = Date()
    ) throws -> [DayUsageSummaryDTO] {
        try repository.fetchHistoryDays(daysCount: daysCount, calendar: calendar, now: now)
    }

    public func getDayDetail(dayKey: LocalDayKey, calendar: Calendar = .current) throws -> DayDetailDTO {
        try repository.fetchDayDetail(dayKey: dayKey, calendar: calendar)
    }

    public func getDashboardMetrics(days: Int = 30, calendar: Calendar = .current) throws -> DashboardMetricsDTO {
        try repository.fetchDashboardMetrics(days: days, calendar: calendar)
    }

    public func getTodayMetrics(calendar: Calendar = .current) throws -> DashboardMetricsDTO {
        try repository.fetchTodayMetrics(calendar: calendar)
    }

    public func getActivityHeatmap(year: Int = Calendar.current.component(.year, from: Date()), calendar: Calendar = .current) throws -> [ActivityHeatmapCellDTO] {
        try repository.fetchActivityHeatmap(year: year, calendar: calendar)
    }

    public func getRecentRateLimitSnapshots(accountKey: String? = nil, limit: Int = 50) throws -> [RateLimitSnapshotRecord] {
        try repository.fetchRecentRateLimitSnapshots(accountKey: accountKey, limit: limit)
    }

    public func getDiagnostics() throws -> UsageDiagnosticsDTO {
        try repository.fetchDiagnostics()
    }
}
