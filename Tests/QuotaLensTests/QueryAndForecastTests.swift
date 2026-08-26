import SQLite3
import XCTest
@testable import QuotaLens

final class QueryAndForecastTests: XCTestCase {
    func testKeysetPaginationHasNoDuplicatesOrOmissionsForEverySort() throws {
        let directory = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: directory)
        let repository = UsageAnalyticsRepository(database: database)
        for index in 0..<17 {
            try insertSession(
                database,
                id: String(format: "session-%02d", index),
                updatedMs: Int64(10_000 + (index % 4) * 1_000),
                createdMs: Int64(5_000 + (index % 3) * 1_000),
                tokens: Int64((index % 5) * 100),
                cost: Int64((index % 2) * 1_000)
            )
        }

        for sort in SessionSort.allCases {
            var cursor: String?
            var ids: [String] = []
            repeat {
                let page = try repository.fetchSessionPage(sort: sort, limit: 4, cursor: cursor)
                ids.append(contentsOf: page.sessions.map(\.sessionId))
                cursor = page.nextCursor
            } while cursor != nil
            XCTAssertEqual(ids.count, 17, sort.rawValue)
            XCTAssertEqual(Set(ids).count, 17, sort.rawValue)
        }
    }

    func testSearchEscapesWildcardsAndIncludesModelAndAgentType() throws {
        let directory = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: directory)
        let repository = UsageAnalyticsRepository(database: database)
        try insertSession(database, id: "literal", title: "literal%_\\name", agentType: "reviewer")
        try insertSession(database, id: "ordinary", title: "literalABCname")
        try database.executeUpdate(
            sql: """
            INSERT INTO codex_session_summaries (
                session_id, model_canonical, event_count, total_tokens,
                uncached_input_tokens, cached_input_tokens, output_tokens,
                reasoning_output_tokens, estimated_cost_usd_nano, unpriced_event_count
            ) VALUES ('ordinary', 'gpt-5.6-terra', 1, 1, 1, 0, 0, 0, 0, 0);
            """,
            bindings: []
        )

        XCTAssertEqual(try repository.fetchSessions(search: "%_\\").map(\.sessionId), ["literal"])
        XCTAssertEqual(try repository.fetchSessions(search: "reviewer").map(\.sessionId), ["literal"])
        XCTAssertEqual(try repository.fetchSessions(search: "gpt-5.6-terra").map(\.sessionId), ["ordinary"])
    }

    func testHistoryUsesExactlyNaturalDaysAcrossDSTAndFillsZeros() throws {
        let directory = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: directory)
        let repository = UsageAnalyticsRepository(database: database)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 10, hour: 12
        )))
        let today = calendar.startOfDay(for: now)
        let sixDaysAgo = try XCTUnwrap(calendar.date(byAdding: .day, value: -6, to: today))
        let threeDaysAgo = try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: today))
        try insertSession(database, id: "dst-session")
        try insertEvent(database, id: "dst-1", sessionID: "dst-session", date: sixDaysAgo.addingTimeInterval(3_600), tokens: 10)
        try insertEvent(database, id: "dst-2", sessionID: "dst-session", date: threeDaysAgo.addingTimeInterval(3_600), tokens: 20)

        let days = try repository.fetchHistoryDays(daysCount: 7, calendar: calendar, now: now)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.first?.dayKey, LocalDayKey(date: today, calendar: calendar))
        XCTAssertEqual(days.last?.dayKey, LocalDayKey(date: sixDaysAgo, calendar: calendar))
        XCTAssertEqual(days.filter { $0.tokens.canonicalTotalTokens == 0 }.count, 5)
        for pair in zip(days.dropLast(), days.dropFirst()) {
            let newer = pair.0.date
            let older = pair.1.date
            XCTAssertEqual(calendar.dateComponents([.day], from: older, to: newer).day, 1)
        }
    }

    func testUsageDayBucketerUsesExplicitTimeZoneAcrossDSTMidnightAndZoneSwitch() throws {
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let laCalendar = UsageDayBucketer.calendar(timeZone: losAngeles)
        let beforeSpringForward = Int64(try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-08T09:59:59Z")).timeIntervalSince1970 * 1_000)
        let afterSpringForward = Int64(try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-08T10:00:00Z")).timeIntervalSince1970 * 1_000)
        let nextMidnight = Int64(try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-09T07:00:00Z")).timeIntervalSince1970 * 1_000)

        let beforeBucket = UsageDayBucketer.bucket(
            timestampMs: beforeSpringForward,
            calendar: laCalendar,
            timeZone: losAngeles
        )
        let afterBucket = UsageDayBucketer.bucket(
            timestampMs: afterSpringForward,
            calendar: laCalendar,
            timeZone: losAngeles
        )
        let midnightBucket = UsageDayBucketer.bucket(
            timestampMs: nextMidnight,
            calendar: laCalendar,
            timeZone: losAngeles
        )

        XCTAssertEqual(beforeBucket.dayKey.yyyyMMdd, "2026-03-08")
        XCTAssertEqual(afterBucket.dayKey.yyyyMMdd, "2026-03-08")
        XCTAssertEqual(beforeBucket.dayStartMs, afterBucket.dayStartMs)
        XCTAssertEqual(midnightBucket.dayKey.yyyyMMdd, "2026-03-09")
        XCTAssertGreaterThan(midnightBucket.dayStartMs, afterBucket.dayStartMs)

        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let timestamp = Int64(try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-20T02:00:00Z")).timeIntervalSince1970 * 1_000)
        let utcBucket = UsageDayBucketer.bucket(
            timestampMs: timestamp,
            calendar: UsageDayBucketer.calendar(timeZone: utc),
            timeZone: utc
        )
        let laBucket = UsageDayBucketer.bucket(
            timestampMs: timestamp,
            calendar: laCalendar,
            timeZone: losAngeles
        )
        XCTAssertEqual(utcBucket.dayKey.yyyyMMdd, "2026-08-20")
        XCTAssertEqual(laBucket.dayKey.yyyyMMdd, "2026-08-19")
    }

    func testDashboardRollingRangeScopesEveryMetricAndDayDetailDrillsToEvents() throws {
        let directory = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: directory)
        let repository = UsageAnalyticsRepository(database: database)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 25
        )))
        let start = end.addingTimeInterval(-7 * 86_400)
        try insertSession(database, id: "inside", title: "Inside")
        try insertSession(database, id: "outside", title: "Outside")
        try insertEvent(database, id: "in-1", sessionID: "inside", date: start.addingTimeInterval(10), tokens: 10)
        try insertEvent(database, id: "in-2", sessionID: "inside", date: end.addingTimeInterval(-10), tokens: 20)
        try insertEvent(database, id: "out-1", sessionID: "outside", date: start.addingTimeInterval(-1), tokens: 100)
        try insertEvent(database, id: "out-2", sessionID: "outside", date: end, tokens: 100)

        let metrics = try repository.fetchDashboardMetrics(
            rangeStart: start,
            endExclusive: end,
            calendar: calendar
        )
        XCTAssertEqual(metrics.totalTokens.canonicalTotalTokens, 30)
        XCTAssertEqual(metrics.totalEvents, 2)
        XCTAssertEqual(metrics.totalSessions, 1)

        let key = LocalDayKey(date: end.addingTimeInterval(-10), calendar: calendar)
        let detail = try repository.fetchDayDetail(dayKey: key, calendar: calendar)
        XCTAssertEqual(detail.summary.tokens.canonicalTotalTokens, 20)
        XCTAssertEqual(detail.sessions.map(\.session.sessionId), ["inside"])
        XCTAssertEqual(detail.sessions.first?.events.map(\.eventId), ["in-2"])
    }

    func testSessionAndHistoryEventKeysetPaginationHasNoDuplicatesOrOmissions() throws {
        let directory = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: directory)
        let repository = UsageAnalyticsRepository(database: database)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 20,
            hour: 12
        )))
        try insertSession(database, id: "paged", title: "Paged")
        for offset in 0..<13 {
            try insertEvent(
                database,
                id: String(format: "event-%02d", offset),
                sessionID: "paged",
                date: day,
                tokens: 1,
                lineOffset: Int64(offset)
            )
        }

        var sessionCursor: String?
        var sessionIDs: [String] = []
        repeat {
            let page = try XCTUnwrap(repository.fetchSessionDetail(
                sessionId: "paged",
                eventLimit: 5,
                eventCursor: sessionCursor
            ))
            XCTAssertEqual(page.totalEventCount, 13)
            XCTAssertEqual(page.loadedEventCount, page.recentEvents.count)
            sessionIDs.append(contentsOf: page.recentEvents.map(\.eventId))
            sessionCursor = page.nextEventCursor
            XCTAssertEqual(page.hasMoreEvents, sessionCursor != nil)
        } while sessionCursor != nil
        XCTAssertEqual(sessionIDs.count, 13)
        XCTAssertEqual(Set(sessionIDs).count, 13)
        XCTAssertEqual(sessionIDs.first, "event-12")
        XCTAssertEqual(sessionIDs.last, "event-00")

        let dayKey = LocalDayKey(date: day, calendar: calendar)
        var dayCursor: String?
        var dayIDs: [String] = []
        repeat {
            let detail = try repository.fetchDayDetail(
                dayKey: dayKey,
                calendar: calendar,
                eventLimit: 4,
                eventCursor: dayCursor
            )
            XCTAssertEqual(detail.totalEventCount, 13)
            XCTAssertEqual(detail.loadedEventCount, detail.sessions.reduce(0) { $0 + $1.events.count })
            dayIDs.append(contentsOf: detail.sessions.flatMap(\.events).map(\.eventId))
            dayCursor = detail.nextEventCursor
            XCTAssertEqual(detail.hasMoreEvents, dayCursor != nil)
        } while dayCursor != nil
        XCTAssertEqual(dayIDs.count, 13)
        XCTAssertEqual(Set(dayIDs), Set(sessionIDs))
    }

    func testFullDayQueriesPreferCompactDailySummariesOverRawLedgerEvents() throws {
        let directory = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: directory)
        let repository = UsageAnalyticsRepository(database: database)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let dayStart = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 20
        )))
        let dayEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: dayStart))

        try insertSession(database, id: "summary-backed")
        // Deliberately differs from the compact summary. If either query scans
        // the raw ledger for a full day, it will return 999 instead of 123.
        try insertEvent(
            database,
            id: "raw-event",
            sessionID: "summary-backed",
            date: dayStart.addingTimeInterval(3_600),
            tokens: 999
        )
        try insertDailySummary(
            database,
            sessionID: "summary-backed",
            dayStart: dayStart,
            calendar: calendar,
            eventCount: 7,
            tokens: 123
        )

        let dashboard = try repository.fetchDashboardMetrics(
            rangeStart: dayStart,
            endExclusive: dayEnd,
            calendar: calendar
        )
        XCTAssertEqual(dashboard.totalTokens.canonicalTotalTokens, 123)
        XCTAssertEqual(dashboard.totalEvents, 7)

        let history = try repository.fetchHistoryDays(
            daysCount: 1,
            calendar: calendar,
            now: dayStart.addingTimeInterval(12 * 3_600)
        )
        XCTAssertEqual(history.first?.tokens.canonicalTotalTokens, 123)
        XCTAssertEqual(history.first?.eventCount, 7)
    }

    func testFullDayTokenPricingCoverageUsesExactUnpricedTokenWeight() throws {
        let directory = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: directory)
        let repository = UsageAnalyticsRepository(database: database)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let dayStart = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 20
        )))
        let dayEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: dayStart))

        try insertSession(database, id: "coverage")
        try database.executeUpdate(
            sql: """
            INSERT INTO codex_daily_usage_summaries (
                session_id, day_key, day_start_ms, model_canonical, event_count,
                total_tokens, uncached_input_tokens, cached_input_tokens,
                cache_write_input_tokens, output_tokens, reasoning_output_tokens,
                estimated_cost_usd_nano, unpriced_event_count, unpriced_token_count
            ) VALUES ('coverage', '2026-08-20', ?, 'gpt-5.6-sol', 10,
                100000, 100000, 0, 0, 0, 0, 1000, 1, 5000);
            """,
            bindings: [Int64(dayStart.timeIntervalSince1970 * 1_000)]
        )

        let metrics = try repository.fetchDashboardMetrics(
            rangeStart: dayStart,
            endExclusive: dayEnd,
            calendar: calendar
        )
        XCTAssertEqual(metrics.eventPricingCoverage, 0.9, accuracy: 0.000_001)
        XCTAssertEqual(metrics.tokenPricingCoverage, 0.95, accuracy: 0.000_001)
        XCTAssertEqual(metrics.costForecastCoverage, 0.95, accuracy: 0.000_001)

        let history = try repository.fetchHistoryDays(
            daysCount: 1,
            calendar: calendar,
            now: dayStart.addingTimeInterval(12 * 3_600)
        )
        XCTAssertEqual(history.first?.unpricedEventCount, 1)
        XCTAssertEqual(history.first?.unpricedTokenCount, 5_000)
    }

    func testTodayMetricsUseNaturalDayInsteadOfPast24Hours() throws {
        let directory = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: directory)
        let repository = UsageAnalyticsRepository(database: database)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 10)))
        let todayStart = calendar.startOfDay(for: now)
        try insertSession(database, id: "today")
        try insertEvent(database, id: "yesterday", sessionID: "today", date: todayStart.addingTimeInterval(-3_600), tokens: 100)
        try insertEvent(database, id: "today-event", sessionID: "today", date: todayStart.addingTimeInterval(3_600), tokens: 10)
        let metrics = try repository.fetchTodayMetrics(calendar: calendar, now: now)
        XCTAssertEqual(metrics.totalTokens.canonicalTotalTokens, 10)
        XCTAssertEqual(metrics.totalEvents, 1)
    }

    func testQuotaForecastRejectsOtherAccountsSlotsAndResetCycles() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let reset = Int64(now.addingTimeInterval(12 * 3_600).timeIntervalSince1970)
        let key = QuotaForecastEngine.QuotaCycleKey(accountID: "a", limitID: "codex", slot: "primary", resetAt: reset)
        let other = QuotaForecastEngine.QuotaCycleKey(accountID: "b", limitID: "codex", slot: "secondary", resetAt: reset + 1)
        var points: [QuotaForecastEngine.RateSnapshotPoint] = []
        for hour in 0...4 {
            points.append(.init(
                timestamp: now.addingTimeInterval(Double(hour - 4) * 3_600),
                usedPercent: Double(20 + hour),
                cycleKey: key
            ))
            points.append(.init(
                timestamp: now.addingTimeInterval(Double(hour - 4) * 3_600),
                usedPercent: Double(hour * 20),
                cycleKey: other
            ))
        }
        let forecast = QuotaForecastEngine.forecast(
            currentUsedPercent: 24,
            resetsAt: reset,
            currentCycleKey: key,
            snapshots: points,
            now: now
        )
        XCTAssertEqual(forecast.samplePointsCount, 5)
        XCTAssertEqual(forecast.burnRatePercentPerHour, 1, accuracy: 0.05)
        XCTAssertGreaterThanOrEqual(forecast.fitQuality ?? 0, 0.99)
    }

    func testQuotaForecastRequiresFreshSpanningSamples() {
        let now = Date(timeIntervalSince1970: 20_000_000)
        let reset = Int64(now.addingTimeInterval(10_000).timeIntervalSince1970)
        let key = QuotaForecastEngine.QuotaCycleKey(accountID: "a", limitID: "codex", slot: "primary", resetAt: reset)
        let stale = [
            QuotaForecastEngine.RateSnapshotPoint(timestamp: now.addingTimeInterval(-10_000), usedPercent: 10, cycleKey: key),
            QuotaForecastEngine.RateSnapshotPoint(timestamp: now.addingTimeInterval(-8_000), usedPercent: 12, cycleKey: key)
        ]
        let forecast = QuotaForecastEngine.forecast(
            currentUsedPercent: 12,
            resetsAt: reset,
            currentCycleKey: key,
            snapshots: stale,
            now: now
        )
        XCTAssertEqual(forecast.confidence, .insufficientData)
    }

    func testQuotaForecastHandlesEmptyAndSinglePointCycles() {
        let now = Date(timeIntervalSince1970: 20_000_000)
        let reset = Int64(now.addingTimeInterval(10_000).timeIntervalSince1970)
        let key = QuotaForecastEngine.QuotaCycleKey(
            accountID: "a",
            limitID: "codex",
            slot: "primary",
            resetAt: reset
        )
        for points in [
            [QuotaForecastEngine.RateSnapshotPoint](),
            [.init(timestamp: now, usedPercent: 10, cycleKey: key)]
        ] {
            let forecast = QuotaForecastEngine.forecast(
                currentUsedPercent: 10,
                resetsAt: reset,
                currentCycleKey: key,
                snapshots: points,
                now: now
            )
            XCTAssertEqual(forecast.confidence, .insufficientData)
        }
    }

    func testLocalProjectionThresholdsOutliersBootstrapOrderAndCoverage() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(
            LocalUsageProjection.project(history: makeHistory(days: 6, now: now, calendar: calendar), calendar: calendar, now: now).confidence,
            .insufficientData
        )
        XCTAssertEqual(
            LocalUsageProjection.project(history: makeHistory(days: 7, now: now, calendar: calendar), calendar: calendar, now: now).confidence,
            .low
        )
        XCTAssertEqual(
            LocalUsageProjection.project(history: makeHistory(days: 14, now: now, calendar: calendar), calendar: calendar, now: now).confidence,
            .medium
        )

        var history = makeHistory(days: 28, now: now, calendar: calendar)
        history[10] = DayUsageSummaryDTO(
            dayKey: history[10].dayKey,
            date: history[10].date,
            tokens: TokenBreakdown(inputTokens: 100_000_000),
            estimatedCost: MoneyNanoUSD(10_000_000_000),
            eventCount: 1,
            sessionCount: 1,
            unpricedEventCount: 1,
            unpricedTokenCount: 100_000_000
        )
        let forecast = LocalUsageProjection.project(history: history, calendar: calendar, now: now)
        XCTAssertEqual(forecast.confidence, .low)
        XCTAssertFalse(forecast.isCostForecastAvailable)
        XCTAssertEqual(forecast.projectedTotalCost, .zero)
        XCTAssertLessThan(forecast.tokenPricingCoverage, 0.80)
        XCTAssertEqual(forecast.dailyProjections.count, 7)
        XCTAssertGreaterThan(forecast.unpricedTokenCount, 0)
        XCTAssertLessThan(forecast.pricingCoverage.coverageRatio, 1)
        for point in forecast.dailyProjections {
            XCTAssertLessThanOrEqual(point.p10Tokens, point.p50Tokens)
            XCTAssertLessThanOrEqual(point.p50Tokens, point.p90Tokens)
            XCTAssertLessThan(point.p90Tokens, 1_000_000)
        }
    }

    func testLocalProjectionTokenCoverageThresholdsControlCostForecast() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        var mediumCoverage = makeHistory(days: 28, now: now, calendar: calendar)
        mediumCoverage[0] = DayUsageSummaryDTO(
            dayKey: mediumCoverage[0].dayKey,
            date: mediumCoverage[0].date,
            tokens: TokenBreakdown(inputTokens: 5_000),
            estimatedCost: .zero,
            eventCount: 1,
            sessionCount: 1,
            unpricedEventCount: 1,
            unpricedTokenCount: 5_000
        )
        let medium = LocalUsageProjection.project(history: mediumCoverage, calendar: calendar, now: now)
        XCTAssertGreaterThanOrEqual(medium.tokenPricingCoverage, 0.80)
        XCTAssertLessThan(medium.tokenPricingCoverage, 0.95)
        XCTAssertTrue(medium.isCostForecastAvailable)
        XCTAssertEqual(medium.confidence, .low)
        XCTAssertGreaterThan(medium.projectedTotalCost.rawValue, 0)

        var lowCoverage = makeHistory(days: 28, now: now, calendar: calendar)
        lowCoverage[0] = DayUsageSummaryDTO(
            dayKey: lowCoverage[0].dayKey,
            date: lowCoverage[0].date,
            tokens: TokenBreakdown(inputTokens: 100_000),
            estimatedCost: .zero,
            eventCount: 1,
            sessionCount: 1,
            unpricedEventCount: 1,
            unpricedTokenCount: 100_000
        )
        let low = LocalUsageProjection.project(history: lowCoverage, calendar: calendar, now: now)
        XCTAssertLessThan(low.tokenPricingCoverage, 0.80)
        XCTAssertFalse(low.isCostForecastAvailable)
        XCTAssertEqual(low.projectedTotalCost, .zero)
    }

    func testDiagnosticsDetectsApplicationInvariantCorruption() throws {
        let directory = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: directory)
        let repository = UsageAnalyticsRepository(database: database)
        try insertSession(database, id: "broken", tokens: 999)
        let diagnostics = try repository.fetchDiagnostics()
        XCTAssertTrue(diagnostics.integrityCheckPassed)
        XCTAssertEqual(diagnostics.foreignKeyViolationCount, 0)
        XCTAssertGreaterThan(diagnostics.invariantViolationCount, 0)
    }

    func testDiagnosticsExportIsAggregateOnlyAndStableJSON() throws {
        let diagnostics = UsageDiagnosticsDTO(
            sourcesDiscovered: 4,
            sourcesIndexed: 3,
            sourcesTombstoned: 1,
            unknownModelEvents: 2,
            unpricedEvents: 2,
            totalEvents: 10,
            activePricingCatalogVersion: BundledPricingCatalog.currentVersion,
            parserVersion: ParserCheckpoint.currentParserVersion
        )
        let report = UsageDiagnosticsExport(
            generatedAt: Date(timeIntervalSince1970: 1_787_227_200),
            diagnostics: diagnostics
        )
        let data = try report.jsonData()
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"containsConversationContent\" : false"))
        XCTAssertTrue(json.contains(BundledPricingCatalog.currentVersion))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("prompt"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("sourcePath"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("response"))
    }

    private func makeHistory(days: Int, now: Date, calendar: Calendar) -> [DayUsageSummaryDTO] {
        let today = calendar.startOfDay(for: now)
        return (1...days).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let tokens = Int64(1_000 + (offset % 5) * 100)
            return DayUsageSummaryDTO(
                dayKey: LocalDayKey(date: date, calendar: calendar),
                date: date,
                tokens: TokenBreakdown(inputTokens: tokens),
                estimatedCost: MoneyNanoUSD(tokens * 1_000),
                eventCount: 1,
                sessionCount: 1
            )
        }
    }

    private func insertSession(
        _ database: SQLiteDatabase,
        id: String,
        title: String? = nil,
        agentType: String? = nil,
        updatedMs: Int64 = 10_000,
        createdMs: Int64 = 5_000,
        tokens: Int64 = 0,
        cost: Int64 = 0
    ) throws {
        try database.executeUpdate(
            sql: """
            INSERT INTO codex_sessions (
                session_id, root_session_id, parent_session_id, depth, source_path,
                relative_path, bucket, title, project_name, cwd, created_at, updated_at,
                last_event_at, event_count, total_tokens, input_tokens, cached_input_tokens,
                output_tokens, reasoning_output_tokens, estimated_cost_usd_nano,
                pricing_status, metadata_fingerprint, has_subagents, agent_type
            ) VALUES (?, ?, NULL, 0, ?, ?, 'active', ?, 'Fixture', '/tmp', ?, ?, ?, 0, ?, ?, 0, 0, 0, ?, 'priced', NULL, 0, ?);
            """,
            bindings: [id, id, "/tmp/\(id).jsonl", "sessions/\(id).jsonl", title, createdMs, updatedMs, updatedMs, tokens, tokens, cost, agentType]
        )
    }

    private func insertEvent(
        _ database: SQLiteDatabase,
        id: String,
        sessionID: String,
        date: Date,
        tokens: Int64,
        priced: Bool = true,
        lineOffset: Int64 = 0
    ) throws {
        let status = priced ? PricingStatus.priced : .unpricedUnknownModel
        try database.executeUpdate(
            sql: """
            INSERT INTO codex_usage_events (
                event_id, session_id, root_session_id, turn_index, call_index,
                timestamp_ms, model_raw, model_canonical, service_tier,
                input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens,
                total_tokens, uncached_input_tokens, estimated_cost_usd_nano,
                pricing_rule_id, pricing_status, usage_derivation, attribution_quality,
                is_child_replay, source_path, line_offset, line_bytes, payload_sha256,
                created_at, timestamp_quality, pricing_catalog_version
            ) VALUES (?, ?, ?, 0, 0, ?, 'gpt-5.4', 'gpt-5.4', NULL, ?, 0, 0, 0, ?, ?, ?, NULL, ?, 'explicit_last_usage', 'direct_turn_context', 0, ?, ?, 1, NULL, ?, 'event_timestamp', ?);
            """,
            bindings: [
                id, sessionID, sessionID, Int64(date.timeIntervalSince1970 * 1_000),
                tokens, tokens, tokens, priced ? tokens * 2_500 : 0,
                status.rawValue, "/tmp/\(sessionID).jsonl", lineOffset,
                Int64(date.timeIntervalSince1970 * 1_000), BundledPricingCatalog.currentVersion
            ]
        )
    }

    private func insertDailySummary(
        _ database: SQLiteDatabase,
        sessionID: String,
        dayStart: Date,
        calendar: Calendar,
        eventCount: Int,
        tokens: Int64
    ) throws {
        try database.executeUpdate(
            sql: """
            INSERT INTO codex_daily_usage_summaries (
                session_id, day_key, day_start_ms, model_canonical, event_count,
                total_tokens, uncached_input_tokens, cached_input_tokens, output_tokens,
                reasoning_output_tokens, estimated_cost_usd_nano, unpriced_event_count
            ) VALUES (?, ?, ?, 'gpt-5.4', ?, ?, ?, 0, 0, 0, ?, 0);
            """,
            bindings: [
                sessionID,
                LocalDayKey(date: dayStart, calendar: calendar).yyyyMMdd,
                Int64(dayStart.timeIntervalSince1970 * 1_000),
                eventCount,
                tokens,
                tokens,
                tokens * 2_500
            ]
        )
    }
}
