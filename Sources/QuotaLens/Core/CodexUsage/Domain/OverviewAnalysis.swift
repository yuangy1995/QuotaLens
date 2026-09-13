import Foundation

struct OverviewPeriod: Sendable {
    let start: Date
    let end: Date
    let previousStart: Date
    let previousEnd: Date

    init(days: Int, now: Date = Date(), calendar: Calendar = UsageDayBucketer.calendar()) {
        let count = max(1, min(30, days))
        start = calendar.date(byAdding: .day, value: -(count - 1), to: calendar.startOfDay(for: now))!
        end = now
        previousStart = calendar.date(byAdding: .day, value: -count, to: start)!
        previousEnd = calendar.date(byAdding: .day, value: -count, to: now)!
    }
}

struct OverviewSessionUsage: Identifiable, Sendable {
    var id: String { session.sessionId }
    let session: CodexSessionDTO
    var tokens: Int64
    var cost: MoneyNanoUSD
}

struct OverviewProjectUsage: Identifiable, Sendable {
    let id: String
    let title: String
    let path: String?
    let sessions: [OverviewSessionUsage]
    var tokens: Int64 { sessions.reduce(0) { $0 + $1.tokens } }
}

struct OverviewAnalysis: Sendable {
    let period: OverviewPeriod
    let current: DashboardMetricsDTO
    let previous: DashboardMetricsDTO
    let sessions: [OverviewSessionUsage]
    let contributionsAvailable: Bool
    var previousSessions: [OverviewSessionUsage]? = nil
    var recordedDays: [DayUsageSummaryDTO] {
        current.dailyBuckets.filter { $0.eventCount > 0 || $0.tokens.canonicalTotalTokens > 0 }
    }

    var projects: [OverviewProjectUsage] {
        Self.projectRows(sessions)
    }
    var previousProjects: [OverviewProjectUsage]? { previousSessions.map(Self.projectRows) }
    private static func projectRows(_ sessions: [OverviewSessionUsage]) -> [OverviewProjectUsage] {
        Dictionary(grouping: sessions) { entry in
            entry.session.cwd?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyForOverview ?? ""
        }.map { path, entries in
            OverviewProjectUsage(id: path, title: path.isEmpty ? L10n.text("未归属", "Unassigned") : URL(fileURLWithPath: path).lastPathComponent,
                                 path: path.isEmpty ? nil : path, sessions: entries)
        }.sorted { $0.tokens == $1.tokens ? $0.id < $1.id : $0.tokens > $1.tokens }
    }

    static func merge(_ slices: [DaySessionSliceDTO]) -> [OverviewSessionUsage] {
        var rows: [String: OverviewSessionUsage] = [:]
        for slice in slices {
            if var row = rows[slice.id] {
                row.tokens += slice.dayTokens.canonicalTotalTokens
                row.cost = row.cost + slice.dayCost
                rows[slice.id] = row
            } else {
                rows[slice.id] = .init(session: slice.session, tokens: slice.dayTokens.canonicalTotalTokens, cost: slice.dayCost)
            }
        }
        return rows.values.sorted { $0.tokens == $1.tokens ? $0.id < $1.id : $0.tokens > $1.tokens }
    }
}

private extension String {
    var nilIfEmptyForOverview: String? { isEmpty ? nil : self }
}
