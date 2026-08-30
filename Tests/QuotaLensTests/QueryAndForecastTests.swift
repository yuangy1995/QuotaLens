import SQLite3
import XCTest
@testable import QuotaLens

final class QueryAndForecastTests: XCTestCase {
    func testProviderRefreshIntervalsClampToSafePollingRanges() {
        XCTAssertEqual(AppState.clampedRefreshInterval(1), 15)
        XCTAssertEqual(AppState.clampedRefreshInterval(7_200), 3_600)
        XCTAssertEqual(AppState.clampedClaudeRefreshInterval(1), 15)
        XCTAssertEqual(AppState.clampedClaudeRefreshInterval(7_200), 3_600)
        XCTAssertEqual(AppState.clampedAntigravityRefreshInterval(1), 15)
        XCTAssertEqual(AppState.clampedAntigravityRefreshInterval(7_200), 3_600)
        XCTAssertEqual(AppState.defaultClaudeRefreshIntervalSeconds, 600)
        XCTAssertEqual(AppState.defaultAntigravityRefreshIntervalSeconds, 300)
        XCTAssertEqual(ClaudeUsagePoller.minimumGap, 15)
        XCTAssertEqual(AntigravityQuotaPoller.minimumGap, 15)
    }

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

    func testQuotaForecastUsesShortFiveHourWindowThresholds() {
        let now = Date(timeIntervalSince1970: 20_000_000)
        let reset = Int64(now.addingTimeInterval(4 * 3_600).timeIntervalSince1970)
        let key = QuotaForecastEngine.QuotaCycleKey(
            accountID: "a",
            limitID: "codex",
            slot: "primary",
            resetAt: reset,
            windowDurationMins: 300
        )
        let points = [
            QuotaForecastEngine.RateSnapshotPoint(
                timestamp: now.addingTimeInterval(-300),
                usedPercent: 10,
                cycleKey: key
            ),
            QuotaForecastEngine.RateSnapshotPoint(
                timestamp: now,
                usedPercent: 11,
                cycleKey: key
            )
        ]

        let forecast = QuotaForecastEngine.forecast(
            currentUsedPercent: 11,
            resetsAt: reset,
            currentCycleKey: key,
            snapshots: points,
            now: now
        )

        XCTAssertNotEqual(forecast.risk, .insufficientData)
        XCTAssertEqual(forecast.confidence, .low)
        XCTAssertEqual(forecast.samplePointsCount, 2)
        XCTAssertEqual(forecast.burnRatePercentPerHour, 12, accuracy: 0.05)
    }

    func testQuotaForecastRetainsHighFrequencyFiveHourSamples() {
        let now = Date(timeIntervalSince1970: 20_000_000)
        let reset = Int64(now.addingTimeInterval(4 * 3_600).timeIntervalSince1970)
        let key = QuotaForecastEngine.QuotaCycleKey(
            accountID: "a",
            limitID: "codex",
            slot: "primary",
            resetAt: reset,
            windowDurationMins: 300
        )
        var points: [QuotaForecastEngine.RateSnapshotPoint] = []
        for index in 0...24 {
            points.append(.init(
                timestamp: now.addingTimeInterval(-Double(index * 15)),
                usedPercent: 10 + Double(24 - index) * 0.5,
                cycleKey: key
            ))
        }

        let forecast = QuotaForecastEngine.forecast(
            currentUsedPercent: 22,
            resetsAt: reset,
            currentCycleKey: key,
            snapshots: points,
            now: now
        )

        XCTAssertNotEqual(forecast.risk, .insufficientData)
        XCTAssertGreaterThanOrEqual(forecast.samplePointsCount, 2)
    }

    func testQuotaForecastRetainsHighFrequencyWeeklySamples() {
        let now = Date(timeIntervalSince1970: 20_000_000)
        let reset = Int64(now.addingTimeInterval(12 * 3_600).timeIntervalSince1970)
        let key = QuotaForecastEngine.QuotaCycleKey(
            accountID: "a",
            limitID: "codex",
            slot: "primary",
            resetAt: reset,
            windowDurationMins: 10_080
        )
        var points: [QuotaForecastEngine.RateSnapshotPoint] = []
        for index in 0...64 {
            points.append(.init(
                timestamp: now.addingTimeInterval(-Double(index * 15)),
                usedPercent: 20 + Double(64 - index) * 0.1,
                cycleKey: key
            ))
        }

        let forecast = QuotaForecastEngine.forecast(
            currentUsedPercent: 26.4,
            resetsAt: reset,
            currentCycleKey: key,
            snapshots: points,
            now: now
        )

        XCTAssertNotEqual(forecast.risk, .insufficientData)
        XCTAssertGreaterThanOrEqual(forecast.samplePointsCount, 2)
    }

    func testQuotaForecastKeepsWeeklyThresholdAndSeparatesWindowDurations() {
        let now = Date(timeIntervalSince1970: 20_000_000)
        let reset = Int64(now.addingTimeInterval(12 * 3_600).timeIntervalSince1970)
        let fiveHourKey = QuotaForecastEngine.QuotaCycleKey(
            accountID: "a",
            limitID: "codex",
            slot: "primary",
            resetAt: reset,
            windowDurationMins: 300
        )
        let weeklyKey = QuotaForecastEngine.QuotaCycleKey(
            accountID: "a",
            limitID: "codex",
            slot: "primary",
            resetAt: reset,
            windowDurationMins: 10_080
        )
        let points = [
            QuotaForecastEngine.RateSnapshotPoint(
                timestamp: now.addingTimeInterval(-300),
                usedPercent: 10,
                cycleKey: fiveHourKey
            ),
            QuotaForecastEngine.RateSnapshotPoint(
                timestamp: now,
                usedPercent: 11,
                cycleKey: fiveHourKey
            ),
            QuotaForecastEngine.RateSnapshotPoint(
                timestamp: now.addingTimeInterval(-300),
                usedPercent: 10,
                cycleKey: weeklyKey
            ),
            QuotaForecastEngine.RateSnapshotPoint(
                timestamp: now,
                usedPercent: 90,
                cycleKey: weeklyKey
            )
        ]

        let shortForecast = QuotaForecastEngine.forecast(
            currentUsedPercent: 11,
            resetsAt: reset,
            currentCycleKey: fiveHourKey,
            snapshots: points,
            now: now
        )
        XCTAssertEqual(shortForecast.burnRatePercentPerHour, 12, accuracy: 0.05)

        let weeklyForecast = QuotaForecastEngine.forecast(
            currentUsedPercent: 90,
            resetsAt: reset,
            currentCycleKey: weeklyKey,
            snapshots: points,
            now: now
        )
        XCTAssertEqual(weeklyForecast.confidence, .insufficientData)
    }

    func testQuotaForecastRejectsStaleFiveHourSamples() {
        let now = Date(timeIntervalSince1970: 20_000_000)
        let reset = Int64(now.addingTimeInterval(4 * 3_600).timeIntervalSince1970)
        let key = QuotaForecastEngine.QuotaCycleKey(
            accountID: "a",
            limitID: "codex",
            slot: "primary",
            resetAt: reset,
            windowDurationMins: 300
        )
        let forecast = QuotaForecastEngine.forecast(
            currentUsedPercent: 30,
            resetsAt: reset,
            currentCycleKey: key,
            snapshots: [
                .init(timestamp: now.addingTimeInterval(-1_260), usedPercent: 20, cycleKey: key),
                .init(timestamp: now.addingTimeInterval(-960), usedPercent: 25, cycleKey: key)
            ],
            now: now
        )

        XCTAssertEqual(forecast.confidence, .insufficientData)
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

    func testAntigravityQuotaPersistenceStoresPoolsAndPrunesHistoryAfterSevenDays() throws {
        let directory = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: directory)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let reset = now.addingTimeInterval(2 * 3_600)

        try insertRateLimitHistory(
            database,
            provider: .antigravity,
            accountKey: "antigravity-test",
            observedAt: Int64(now.timeIntervalSince1970) - RateLimitSnapshotRetention.retentionSeconds - 1,
            limitID: "old-group",
            slot: "old-window",
            usedPercent: 10,
            durationMinutes: 300,
            resetAt: Int64(reset.timeIntervalSince1970)
        )

        let snapshot = AntigravityQuotaSnapshot(
            sourceProfile: "ide",
            accountKey: "antigravity-test",
            accountDisplayName: "Fixture",
            planName: "Pro",
            capturedAt: now,
            groups: [
                .init(
                    id: "gemini-group",
                    title: "Gemini",
                    buckets: [
                        .init(id: "five-hour", title: "Five Hour", window: .fiveHour, remainingPercent: 72.5, resetAt: reset),
                        .init(id: "weekly", title: "Weekly", window: .weekly, remainingPercent: 41, resetAt: reset.addingTimeInterval(86_400))
                    ]
                )
            ],
            models: [
                .init(id: "gemini-1", displayName: "Gemini", remainingPercent: 5, resetAt: reset)
            ]
        )

        try AntigravityQuotaRepository.persist(snapshot, database: database)

        let rows = try database.executeQuery(
            sql: """
            SELECT limit_id, slot, used_percent_milli, window_duration_mins, plan_type
            FROM rate_limit_snapshots
            WHERE provider = 'antigravity'
            ORDER BY slot;
            """
        ) { statement in
            (
                String(cString: sqlite3_column_text(statement, 0)),
                String(cString: sqlite3_column_text(statement, 1)),
                Int(sqlite3_column_int(statement, 2)),
                Int(sqlite3_column_int(statement, 3)),
                String(cString: sqlite3_column_text(statement, 4))
            )
        }

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.0)), Set(["gemini-group"]))
        XCTAssertEqual(Set(rows.map(\.1)), Set(["five-hour", "weekly"]))
        XCTAssertEqual(Set(rows.map(\.3)), Set([300, 10_080]))
        XCTAssertTrue(rows.allSatisfy { $0.4 == "Pro" })
        XCTAssertEqual(rows.first(where: { $0.1 == "five-hour" })?.2, 27_500)
        XCTAssertFalse(rows.contains(where: { $0.0 == "gemini-1" }))
        XCTAssertEqual(
            try database.intScalar(sql: "SELECT COUNT(*) FROM antigravity_quota_cache WHERE account_key = 'antigravity-test';"),
            1
        )
    }

    func testProviderQuotaHistoryIsProviderScopedAndBuildsCurrentCycleForecast() async throws {
        let directory = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: directory)
        let now = Date(timeIntervalSince1970: 2_010_000_000)
        let resetAt = Int64(now.addingTimeInterval(2 * 3_600).timeIntervalSince1970)

        for sample in [(seconds: -600, used: 20.0), (seconds: -300, used: 35.0)] {
            try insertRateLimitHistory(
                database,
                provider: .antigravity,
                accountKey: "shared-account",
                observedAt: Int64(now.timeIntervalSince1970) + Int64(sample.seconds),
                limitID: "shared-limit",
                slot: "primary",
                usedPercent: sample.used,
                durationMinutes: 300,
                resetAt: resetAt
            )
            try insertRateLimitHistory(
                database,
                provider: .codex,
                accountKey: "shared-account",
                observedAt: Int64(now.timeIntervalSince1970) + Int64(sample.seconds),
                limitID: "shared-limit",
                slot: "primary",
                usedPercent: 95 - sample.used,
                durationMinutes: 300,
                resetAt: resetAt
            )
        }

        let antigravityHistory = try ProviderQuotaHistoryRepository.fetch(
            database: database,
            provider: .antigravity,
            accountKey: "shared-account",
            since: now.addingTimeInterval(-3_600)
        )
        let codexHistory = try ProviderQuotaHistoryRepository.fetch(
            database: database,
            provider: .codex,
            accountKey: "shared-account",
            since: now.addingTimeInterval(-3_600)
        )
        XCTAssertEqual(antigravityHistory.map(\.usedPercent), [20, 35])
        XCTAssertEqual(codexHistory.map(\.usedPercent), [75, 60])

        let service = ProviderQuotaInsightsService(database: database)
        let result = await service.build(
            inputs: [makeQuotaInput(
                provider: .antigravity,
                accountKey: "shared-account",
                limitID: "shared-limit",
                slot: "primary",
                usedPercent: 50,
                durationMinutes: 300,
                resetAt: Date(timeIntervalSince1970: Double(resetAt)),
                capturedAt: now
            )],
            refreshIntervals: [.antigravity: 300],
            now: now
        )
        let insight = try XCTUnwrap(result[.antigravity]?.first)
        XCTAssertEqual(insight.trendPoints.map(\.usedPercent), [20, 35, 50])
        XCTAssertEqual(insight.forecast.burnRatePercentPerHour, 180, accuracy: 0.5)
        XCTAssertEqual(insight.risk, .critical)
        XCTAssertTrue(insight.hasUsableForecast)
    }

    func testProviderQuotaInsightsHandleInsufficientDelayedAndStaleData() async throws {
        let directory = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: directory)
        let service = ProviderQuotaInsightsService(database: database)
        let now = Date(timeIntervalSince1970: 2_020_000_000)
        let reset = now.addingTimeInterval(3_600)

        let fresh = await service.build(
            inputs: [makeQuotaInput(
                provider: .antigravity,
                usedPercent: 20,
                durationMinutes: 300,
                resetAt: reset,
                capturedAt: now
            )],
            refreshIntervals: [.antigravity: 300],
            now: now
        )
        let freshInsight = try XCTUnwrap(fresh[.antigravity]?.first)
        XCTAssertEqual(freshInsight.freshness, .fresh)
        XCTAssertEqual(freshInsight.forecast.confidence, .insufficientData)
        XCTAssertFalse(freshInsight.hasUsableForecast)

        let delayed = await service.build(
            inputs: [makeQuotaInput(
                provider: .antigravity,
                usedPercent: 20,
                durationMinutes: 300,
                resetAt: reset,
                capturedAt: now.addingTimeInterval(-601)
            )],
            refreshIntervals: [.antigravity: 300],
            now: now
        )
        XCTAssertEqual(delayed[.antigravity]?.first?.freshness, .delayed)

        let stale = await service.build(
            inputs: [makeQuotaInput(
                provider: .antigravity,
                usedPercent: 20,
                durationMinutes: 300,
                resetAt: reset,
                capturedAt: now.addingTimeInterval(-1_201)
            )],
            refreshIntervals: [.antigravity: 300],
            now: now
        )
        let staleInsight = try XCTUnwrap(stale[.antigravity]?.first)
        XCTAssertEqual(staleInsight.freshness, .stale)
        XCTAssertEqual(staleInsight.risk, .insufficientData)
        XCTAssertFalse(staleInsight.hasUsableForecast)

        let weekly = ProviderQuotaInsight(
            input: makeQuotaInput(
                provider: .antigravity,
                usedPercent: 30,
                durationMinutes: 10_080,
                resetAt: reset,
                capturedAt: now
            ),
            forecast: QuotaForecastDTO(
                risk: .onTrack,
                confidence: .medium,
                burnRatePercentPerHour: 2,
                projectedRemainingAtReset: 60
            ),
            freshness: .fresh,
            sustainableRatePercentPerHour: 1,
            trendPoints: []
        )
        XCTAssertEqual(weekly.rateMultiplier, 24)
        XCTAssertEqual(weekly.burnRateForDisplay, 48)
        XCTAssertEqual(weekly.sustainableRateForDisplay, 24)
    }

    func testQuotaRecommendationsFollowOperationalPriorityAndDowngradeLowConfidence() {
        let now = Date(timeIntervalSince1970: 2_030_000_000)
        let critical = makeQuotaInsight(
            group: "Gemini",
            remainingPercent: 10,
            risk: .critical,
            confidence: .high,
            now: now
        )
        let roomy = makeQuotaInsight(
            group: "Claude/GPT",
            remainingPercent: 60,
            risk: .onTrack,
            confidence: .medium,
            now: now
        )
        let recommendations = QuotaRecommendationEngine.make(
            insights: [.antigravity: [critical, roomy]],
            enabledProviders: [.codex, .antigravity],
            errors: [.codex: "Offline"],
            antigravityActivity: nil
        )

        XCTAssertEqual(recommendations.map(\.id), [
            "sync-error-codex",
            "critical-\(critical.id)",
            "imbalance-300"
        ])

        let uncertain = makeQuotaInsight(
            group: "Gemini",
            remainingPercent: 10,
            risk: .critical,
            confidence: .low,
            now: now
        )
        let cautious = QuotaRecommendationEngine.make(
            insights: [.antigravity: [uncertain]],
            enabledProviders: [.antigravity],
            errors: [:],
            antigravityActivity: nil
        )
        XCTAssertEqual(cautious.first?.severity, .warning)
    }

    func testAntigravityActivityMetricsCoverCurrentPreviousAndCalendarPeriods() async throws {
        let directory = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: directory)
        let calendar = UsageDayBucketer.calendar()
        let today = calendar.startOfDay(for: Date())
        let samples: [(offset: Int, steps: Int64, project: String)] = [
            (0, 10, "Current"), (-1, 20, "Current"), (-6, 30, "Current"),
            (-7, 15, "Previous"), (-12, 25, "Previous"),
            (-20, 40, "Current"), (-35, 50, "Historical")
        ]
        for (index, sample) in samples.enumerated() {
            let date = try XCTUnwrap(calendar.date(byAdding: .day, value: sample.offset, to: today))
                .addingTimeInterval(12 * 3_600)
            try insertAntigravityActivity(
                database,
                id: "activity-\(index)",
                date: date,
                steps: sample.steps,
                project: sample.project
            )
        }

        let snapshot = try await AntigravityActivityStore(database: database)
            .cachedSnapshot(preferredProfile: .ide)

        XCTAssertEqual(snapshot.sevenDayMetrics.taskCount, 3)
        XCTAssertEqual(snapshot.sevenDayMetrics.activeDays, 3)
        XCTAssertEqual(snapshot.sevenDayMetrics.stepCount, 60)
        XCTAssertEqual(snapshot.previousSevenDayMetrics.taskCount, 2)
        XCTAssertEqual(snapshot.previousSevenDayMetrics.stepCount, 40)
        XCTAssertEqual(snapshot.thirtyDayMetrics.taskCount, 6)
        XCTAssertEqual(snapshot.previousThirtyDayMetrics.taskCount, 1)
        XCTAssertEqual(try XCTUnwrap(snapshot.taskChangePercent(days: 7)), 50, accuracy: 0.001)
        XCTAssertEqual(snapshot.daily.count, 30)
        XCTAssertEqual(snapshot.dailyPoints(days: 7).reduce(0) { $0 + $1.taskCount }, 3)
        XCTAssertEqual(snapshot.projectCounts["Historical"], nil)
    }

    func testAntigravityActivityKeepsLastHistoricalActivityForEmptyRecentPeriod() async throws {
        let directory = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: directory)
        let calendar = UsageDayBucketer.calendar()
        let historical = try XCTUnwrap(calendar.date(byAdding: .day, value: -45, to: Date()))
        try insertAntigravityActivity(
            database,
            id: "historical-only",
            date: historical,
            steps: 12,
            project: "Archive"
        )

        let snapshot = try await AntigravityActivityStore(database: database)
            .cachedSnapshot(preferredProfile: .ide)
        XCTAssertEqual(snapshot.sevenDayMetrics.taskCount, 0)
        XCTAssertEqual(snapshot.thirtyDayMetrics.taskCount, 0)
        XCTAssertNotNil(snapshot.latestActivityAt)
        XCTAssertEqual(snapshot.daily.count, 30)
        XCTAssertTrue(snapshot.daily.allSatisfy { $0.taskCount == 0 })
    }

    func testAntigravityActivityAggregatesProfilesAndDeduplicatesTrajectories() async throws {
        let directory = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: directory)
        let newer = Date().addingTimeInterval(-60)
        let older = newer.addingTimeInterval(-60)

        try insertAntigravityActivity(
            database,
            id: "shared",
            date: older,
            steps: 10,
            project: "IDE",
            source: .ide
        )
        try insertAntigravityActivity(
            database,
            id: "shared",
            date: newer,
            steps: 30,
            project: "Legacy",
            source: .legacy
        )
        try insertAntigravityActivity(
            database,
            id: "ide-only",
            date: newer,
            steps: 20,
            project: "IDE",
            source: .ide
        )
        try insertAntigravityActivity(
            database,
            id: "legacy-only",
            date: newer,
            steps: 40,
            project: "Legacy",
            source: .legacy
        )

        let store = AntigravityActivityStore(database: database)
        let combined = try await store.cachedSnapshot()
        let byProfile = try await store.cachedSnapshotsByProfile()

        XCTAssertEqual(combined.sevenDayMetrics.taskCount, 3)
        XCTAssertEqual(combined.sevenDayMetrics.stepCount, 90)
        XCTAssertEqual(combined.projectCounts["IDE"], 1)
        XCTAssertEqual(combined.projectCounts["Legacy"], 2)
        XCTAssertEqual(byProfile[.ide]?.sevenDayMetrics.taskCount, 2)
        XCTAssertEqual(byProfile[.ide]?.sevenDayMetrics.stepCount, 30)
        XCTAssertEqual(byProfile[.legacy]?.sevenDayMetrics.taskCount, 2)
        XCTAssertEqual(byProfile[.legacy]?.sevenDayMetrics.stepCount, 70)
    }

    func testAntigravityLocalStateReaderReturnsEveryAvailableProfile() throws {
        let directory = try makeTemporaryDirectory()
        let ideURL = directory.appendingPathComponent("ide/state.vscdb")
        let legacyURL = directory.appendingPathComponent("legacy/state.vscdb")
        let ideDatabase = try SQLiteDatabase(path: ideURL.path)
        let legacyDatabase = try SQLiteDatabase(path: legacyURL.path)
        for database in [ideDatabase, legacyDatabase] {
            try database.execute(sql: "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        }
        try ideDatabase.executeUpdate(
            sql: "INSERT INTO ItemTable (key, value) VALUES (?, ?);",
            bindings: ["activity", "ide-value"]
        )
        try legacyDatabase.executeUpdate(
            sql: "INSERT INTO ItemTable (key, value) VALUES (?, ?);",
            bindings: ["activity", "legacy-value"]
        )

        let reader = AntigravityLocalStateReader(sources: [
            AntigravityStateSource(profile: .ide, databaseURL: ideURL),
            AntigravityStateSource(profile: .legacy, databaseURL: legacyURL)
        ])
        let values = try reader.readRawValues(key: "activity", preferredProfile: .legacy)

        XCTAssertEqual(values.map(\.source.profile), [.legacy, .ide])
        XCTAssertEqual(values.map(\.value), ["legacy-value", "ide-value"])
    }

    func testAntigravityActivityScanMergesLegacyAndConversationFormats() async throws {
        let directory = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: directory)
        let stateURL = directory.appendingPathComponent("legacy/state.vscdb")
        let stateDatabase = try SQLiteDatabase(path: stateURL.path)
        try stateDatabase.execute(sql: "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT NOT NULL);")

        let now = Date()
        let oldDate = now.addingTimeInterval(-20 * 86_400)
        let sharedOldDate = now.addingTimeInterval(-2 * 86_400)
        let legacyValue = makeLegacyAntigravityActivityValue([
            (id: "old-only", date: oldDate, steps: 5),
            (id: "shared", date: sharedOldDate, steps: 10)
        ])
        try stateDatabase.executeUpdate(
            sql: "INSERT INTO ItemTable (key, value) VALUES (?, ?);",
            bindings: ["antigravityUnifiedStateSync.trajectorySummaries", legacyValue]
        )

        let conversationsURL = directory.appendingPathComponent("conversations", isDirectory: true)
        let sharedNewDate = now.addingTimeInterval(-86_400)
        let newOnlyDate = now.addingTimeInterval(-3_600)
        try createAntigravityConversationDatabase(
            at: conversationsURL.appendingPathComponent("shared.db"),
            trajectoryID: "shared",
            createdAt: sharedOldDate,
            lastActivityAt: sharedNewDate,
            steps: 3,
            projectName: "CurrentProject"
        )
        try createAntigravityConversationDatabase(
            at: conversationsURL.appendingPathComponent("new-only.db"),
            trajectoryID: "new-only",
            createdAt: newOnlyDate.addingTimeInterval(-60),
            lastActivityAt: newOnlyDate,
            steps: 4,
            projectName: "CurrentProject"
        )

        let store = AntigravityActivityStore(
            database: database,
            reader: AntigravityLocalStateReader(sources: [
                AntigravityStateSource(profile: .legacy, databaseURL: stateURL)
            ]),
            conversationReader: AntigravityConversationReader(directoryURL: conversationsURL)
        )
        let result = try await store.scan(preferredProfile: .legacy)

        XCTAssertEqual(result.recordsRead, 3)
        XCTAssertEqual(result.sourceProfiles, [.legacy])
        XCTAssertEqual(result.snapshot.sevenDayMetrics.taskCount, 2)
        XCTAssertEqual(result.snapshot.sevenDayMetrics.stepCount, 7)
        XCTAssertEqual(result.snapshot.thirtyDayMetrics.taskCount, 3)
        XCTAssertEqual(result.snapshot.thirtyDayMetrics.stepCount, 12)
        XCTAssertEqual(result.snapshot.projectCounts["CurrentProject"], 2)
        XCTAssertEqual(
            try XCTUnwrap(result.snapshot.latestActivityAt).timeIntervalSince1970,
            newOnlyDate.timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testAntigravityModelAggregationUsesTightestAvailabilityAndEarliestReset() throws {
        let later = Date(timeIntervalSince1970: 2_040_010_000)
        let earlier = later.addingTimeInterval(-1_000)
        let snapshot = AntigravityQuotaSnapshot(
            sourceProfile: "ide",
            accountKey: "models",
            accountDisplayName: nil,
            planName: nil,
            capturedAt: earlier,
            groups: [],
            models: [
                .init(id: "one", displayName: " Gemini Pro ", remainingPercent: 70, resetAt: later),
                .init(id: "two", displayName: "gemini pro", remainingPercent: 25, resetAt: earlier),
                .init(id: "three", displayName: nil, remainingPercent: 80, resetAt: later),
                .init(id: "four", displayName: "", remainingPercent: 60, resetAt: earlier)
            ]
        )

        XCTAssertEqual(snapshot.aggregatedModels.count, 2)
        let gemini = try XCTUnwrap(snapshot.aggregatedModels.first(where: { $0.id.contains("gemini pro") }))
        XCTAssertEqual(gemini.remainingPercent, 25)
        XCTAssertEqual(gemini.resetAt, earlier)
        XCTAssertEqual(gemini.modelCount, 2)
        let other = try XCTUnwrap(snapshot.aggregatedModels.first(where: { $0.id != gemini.id }))
        XCTAssertEqual(other.remainingPercent, 60)
        XCTAssertEqual(other.modelCount, 2)
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

    private func insertRateLimitHistory(
        _ database: SQLiteDatabase,
        provider: UsageProvider,
        accountKey: String,
        observedAt: Int64,
        limitID: String,
        slot: String,
        usedPercent: Double,
        durationMinutes: Int,
        resetAt: Int64
    ) throws {
        try database.executeUpdate(
            sql: """
            INSERT INTO rate_limit_snapshots (
                account_key, observed_at, limit_id, slot, used_percent_milli,
                window_duration_mins, resets_at, plan_type, raw_json, provider
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 'test', '{}', ?);
            """,
            bindings: [
                accountKey,
                observedAt,
                limitID,
                slot,
                Int((usedPercent * 1_000).rounded()),
                durationMinutes,
                resetAt,
                provider.rawValue
            ]
        )
    }

    private func makeQuotaInput(
        provider: UsageProvider,
        accountKey: String = "antigravity-account",
        limitID: String = "gemini-group",
        slot: String = "primary",
        usedPercent: Double,
        durationMinutes: Int,
        resetAt: Date,
        capturedAt: Date
    ) -> ProviderQuotaPoolInput {
        ProviderQuotaPoolInput(
            provider: provider,
            accountKey: accountKey,
            limitID: limitID,
            slot: slot,
            groupTitle: limitID,
            windowTitle: durationMinutes == 300 ? "5 Hours" : "7 Days",
            usedPercent: usedPercent,
            windowDurationMins: durationMinutes,
            resetAt: resetAt,
            capturedAt: capturedAt
        )
    }

    private func makeQuotaInsight(
        group: String,
        remainingPercent: Double,
        risk: QuotaForecastRisk,
        confidence: ForecastConfidence,
        now: Date
    ) -> ProviderQuotaInsight {
        let input = makeQuotaInput(
            provider: .antigravity,
            limitID: group.lowercased(),
            slot: "primary",
            usedPercent: 100 - remainingPercent,
            durationMinutes: 300,
            resetAt: now.addingTimeInterval(3_600),
            capturedAt: now
        )
        return ProviderQuotaInsight(
            input: ProviderQuotaPoolInput(
                provider: input.provider,
                accountKey: input.accountKey,
                limitID: input.limitID,
                slot: input.slot,
                groupTitle: group,
                windowTitle: input.windowTitle,
                usedPercent: input.usedPercent,
                windowDurationMins: input.windowDurationMins,
                resetAt: input.resetAt,
                capturedAt: input.capturedAt
            ),
            forecast: QuotaForecastDTO(
                risk: risk,
                confidence: confidence,
                burnRatePercentPerHour: risk == .critical ? 40 : 1,
                paceRatio: risk == .critical ? 2 : 1,
                estimatedExhaustionDate: risk == .critical ? now.addingTimeInterval(1_800) : nil,
                naturalResetDate: now.addingTimeInterval(3_600),
                projectedRemainingAtReset: risk == .critical ? 0 : remainingPercent,
                samplePointsCount: 4,
                fitQuality: 0.95,
                lastSampleAgeSeconds: 0
            ),
            freshness: .fresh,
            sustainableRatePercentPerHour: remainingPercent,
            trendPoints: []
        )
    }

    private func insertAntigravityActivity(
        _ database: SQLiteDatabase,
        id: String,
        date: Date,
        steps: Int64,
        project: String,
        source: AntigravityStateProfile = .ide
    ) throws {
        try database.executeUpdate(
            sql: """
            INSERT INTO antigravity_activity_records (
                source_profile, trajectory_id, created_at, last_modified_at,
                last_user_input_at, step_count, project_name
            ) VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                source.rawValue,
                id,
                Int64(date.timeIntervalSince1970),
                Int64(date.timeIntervalSince1970),
                Int64(date.timeIntervalSince1970),
                steps,
                project
            ]
        )
    }

    private func createAntigravityConversationDatabase(
        at url: URL,
        trajectoryID: String,
        createdAt: Date,
        lastActivityAt: Date,
        steps: Int,
        projectName: String
    ) throws {
        let database = try SQLiteDatabase(path: url.path)
        try database.execute(sql: """
            CREATE TABLE trajectory_meta (
                trajectory_id TEXT PRIMARY KEY,
                cascade_id TEXT,
                trajectory_type INTEGER,
                source INTEGER
            );
            CREATE TABLE steps (
                idx INTEGER PRIMARY KEY,
                metadata BLOB
            );
            CREATE TABLE trajectory_metadata_blob (
                id TEXT PRIMARY KEY,
                data BLOB
            );
            """)
        try database.executeUpdate(
            sql: "INSERT INTO trajectory_meta (trajectory_id, cascade_id, trajectory_type, source) VALUES (?, ?, 4, 1);",
            bindings: [trajectoryID, trajectoryID]
        )

        let fileURL = URL(fileURLWithPath: "/tmp/\(projectName)").absoluteString
        let workspace = protoBytesField(1, Data(fileURL.utf8))
        let trajectoryMetadata = protoBytesField(1, workspace)
            + protoBytesField(2, protoTimestamp(createdAt))
        try database.executeUpdate(
            sql: "INSERT INTO trajectory_metadata_blob (id, data) VALUES ('main', ?);",
            bindings: [trajectoryMetadata]
        )

        for index in 0..<steps {
            let timestamp = index == steps - 1
                ? lastActivityAt
                : createdAt.addingTimeInterval(Double(index))
            let metadata = protoBytesField(1, protoTimestamp(timestamp))
                + protoBytesField(32, protoTimestamp(timestamp))
            try database.executeUpdate(
                sql: "INSERT INTO steps (idx, metadata) VALUES (?, ?);",
                bindings: [index, metadata]
            )
        }
    }

    private func makeLegacyAntigravityActivityValue(
        _ records: [(id: String, date: Date, steps: Int64)]
    ) -> String {
        let outer = records.reduce(into: Data()) { result, record in
            let summary = protoVarintField(2, UInt64(record.steps))
                + protoBytesField(3, protoTimestamp(record.date))
                + protoBytesField(7, protoTimestamp(record.date))
                + protoBytesField(10, protoTimestamp(record.date))
            let row = protoBytesField(1, Data(summary.base64EncodedString().utf8))
            let entry = protoBytesField(1, Data(record.id.utf8))
                + protoBytesField(2, row)
            result.append(protoBytesField(1, entry))
        }
        return outer.base64EncodedString()
    }

    private func protoTimestamp(_ date: Date) -> Data {
        protoVarintField(1, UInt64(max(0, Int64(date.timeIntervalSince1970))))
    }

    private func protoVarintField(_ number: Int, _ value: UInt64) -> Data {
        protoVarint(UInt64(number << 3)) + protoVarint(value)
    }

    private func protoBytesField(_ number: Int, _ value: Data) -> Data {
        protoVarint(UInt64(number << 3 | 2)) + protoVarint(UInt64(value.count)) + value
    }

    private func protoVarint(_ value: UInt64) -> Data {
        var value = value
        var data = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            data.append(byte)
        } while value != 0
        return data
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
