// QuotaLens 用量分析查询仓储 (UsageAnalyticsRepository)
// 高性能 SQLite 只读参数化查询、Keyset 分页、日桶聚合、模型分布与画像统计

import Foundation
import SQLite3

public final class UsageAnalyticsRepository: Sendable {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    // MARK: - 1. 会话列表查询 (支持 Keyset 分页与搜索)
    public func fetchSessions(
        sort: SessionSort = .lastActivityDesc,
        search: String? = nil,
        limit: Int = 50,
        cursor: String? = nil
    ) throws -> [CodexSessionDTO] {
        var conditions: [String] = []
        var bindings: [Any?] = []

        // 只查询主会话（或顶层会话），深度为 0
        conditions.append("(depth = 0 OR parent_session_id IS NULL)")

        if let search = search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
            let pattern = "%\(search)%"
            conditions.append("(title LIKE ? OR project_name LIKE ? OR session_id LIKE ? OR cwd LIKE ?)")
            bindings.append(contentsOf: [pattern, pattern, pattern, pattern])
        }

        var orderClause = "ORDER BY "
        switch sort {
        case .lastActivityDesc:
            orderClause += "COALESCE(last_event_at, updated_at) DESC, session_id DESC"
        case .totalTokensDesc:
            orderClause += "total_tokens DESC, session_id DESC"
        case .estimatedCostDesc:
            orderClause += "estimated_cost_usd_nano DESC, session_id DESC"
        case .createdDesc:
            orderClause += "created_at DESC, session_id DESC"
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = """
        SELECT
            session_id, root_session_id, parent_session_id, depth, title, project_name, cwd,
            created_at, updated_at, last_event_at, event_count, total_tokens, input_tokens,
            cached_input_tokens, output_tokens, reasoning_output_tokens, estimated_cost_usd_nano,
            pricing_status, bucket, has_subagents
        FROM codex_sessions
        \(whereClause)
        \(orderClause)
        LIMIT ?;
        """
        bindings.append(limit)

        return try database.executeQuery(sql: sql, bindings: bindings) { stmt in
            Self.mapSessionRow(stmt)
        }
    }

    // MARK: - 2. 会话完整详情查询
    public func fetchSessionDetail(sessionId: String) throws -> CodexSessionDetailDTO? {
        // 主会话
        let mainSessionSql = """
        SELECT
            session_id, root_session_id, parent_session_id, depth, title, project_name, cwd,
            created_at, updated_at, last_event_at, event_count, total_tokens, input_tokens,
            cached_input_tokens, output_tokens, reasoning_output_tokens, estimated_cost_usd_nano,
            pricing_status, bucket, has_subagents
        FROM codex_sessions
        WHERE session_id = ?;
        """
        guard let mainSession = try database.executeQuery(sql: mainSessionSql, bindings: [sessionId], rowMapper: Self.mapSessionRow).first else {
            return nil
        }

        let sourceInfoSql = """
        SELECT source_path, relative_path
        FROM codex_sessions
        WHERE session_id = ?;
        """
        let sourceInfo = try database.executeQuery(sql: sourceInfoSql, bindings: [sessionId]) { stmt -> (String, String) in
            let sourcePath = sqlite3_column_type(stmt, 0) != SQLITE_NULL && sqlite3_column_text(stmt, 0) != nil
                ? String(cString: sqlite3_column_text(stmt, 0)!) : ""
            let relativePath = sqlite3_column_type(stmt, 1) != SQLITE_NULL && sqlite3_column_text(stmt, 1) != nil
                ? String(cString: sqlite3_column_text(stmt, 1)!) : ""
            return (sourcePath, relativePath)
        }.first

        // 子会话列表
        let subagentsSql = """
        SELECT
            session_id, root_session_id, parent_session_id, depth, title, project_name, cwd,
            created_at, updated_at, last_event_at, event_count, total_tokens, input_tokens,
            cached_input_tokens, output_tokens, reasoning_output_tokens, estimated_cost_usd_nano,
            pricing_status, bucket, has_subagents
        FROM codex_sessions
        WHERE parent_session_id = ?
        ORDER BY created_at ASC;
        """
        let subagents = try database.executeQuery(sql: subagentsSql, bindings: [sessionId], rowMapper: Self.mapSessionRow)

        // 模型汇总统计
        let modelSummariesSql = """
        SELECT
            model_canonical,
            SUM(uncached_input_tokens),
            SUM(cached_input_tokens),
            SUM(output_tokens),
            SUM(reasoning_output_tokens),
            SUM(total_tokens),
            SUM(estimated_cost_usd_nano),
            SUM(event_count),
            SUM(unpriced_event_count)
        FROM codex_session_summaries
        WHERE session_id = ?
        GROUP BY model_canonical
        ORDER BY SUM(total_tokens) DESC;
        """
        let modelSummaries = try database.executeQuery(sql: modelSummariesSql, bindings: [sessionId]) { stmt -> ModelUsageSummaryDTO in
            let model = String(cString: sqlite3_column_text(stmt, 0))
            let uncachedTokens = sqlite3_column_int64(stmt, 1)
            let cachedTokens = sqlite3_column_int64(stmt, 2)
            let tokens = TokenBreakdown(
                inputTokens: uncachedTokens + cachedTokens,
                cachedInputTokens: cachedTokens,
                outputTokens: sqlite3_column_int64(stmt, 3),
                reasoningOutputTokens: sqlite3_column_int64(stmt, 4),
                sourceTotalTokens: sqlite3_column_int64(stmt, 5)
            )
            let cost = MoneyNanoUSD(sqlite3_column_int64(stmt, 6))
            let eventCount = Int(sqlite3_column_int(stmt, 7))
            let unpriced = Int(sqlite3_column_int(stmt, 8))
            return ModelUsageSummaryDTO(
                modelCanonical: model,
                tokens: tokens,
                estimatedCost: cost,
                eventCount: eventCount,
                unpricedCount: unpriced
            )
        }

        var totalSubagentTokens = TokenBreakdown.zero
        var totalSubagentCost = MoneyNanoUSD.zero
        for sub in subagents {
            totalSubagentTokens = totalSubagentTokens + sub.tokens
            totalSubagentCost = totalSubagentCost + sub.estimatedCost
        }

        let preferredSourcePath = {
            guard let sourceInfo else { return "" }
            return sourceInfo.0.isEmpty ? sourceInfo.1 : sourceInfo.0
        }()

        return CodexSessionDetailDTO(
            session: mainSession,
            subagents: subagents,
            modelSummaries: modelSummaries,
            recentEvents: [],
            sourcePath: Self.absoluteSourcePath(preferredSourcePath),
            relativePath: sourceInfo?.1 ?? "",
            totalSubagentTokens: totalSubagentTokens,
            totalSubagentCost: totalSubagentCost
        )
    }

    // MARK: - 3. 每日用量汇总 (History 列表)
    public func fetchHistoryDays(daysCount: Int = 30, calendar: Calendar = .current) throws -> [DayUsageSummaryDTO] {
        let now = Date()
        guard let startDate = calendar.date(byAdding: .day, value: -daysCount, to: calendar.startOfDay(for: now)) else {
            return []
        }
        let startTs = Int64(startDate.timeIntervalSince1970 * 1000)

        let sql = """
        SELECT
            day_key,
            day_start_ms,
            model_canonical,
            session_id,
            event_count,
            total_tokens,
            cached_input_tokens,
            uncached_input_tokens,
            output_tokens,
            reasoning_output_tokens,
            estimated_cost_usd_nano,
            unpriced_event_count
        FROM codex_daily_usage_summaries
        WHERE day_start_ms >= ?
        ORDER BY day_start_ms ASC;
        """

        struct EventSlice {
            let dayKey: LocalDayKey
            let tokens: TokenBreakdown
            let cost: MoneyNanoUSD
            let model: String
            let sessionId: String
            let eventCount: Int
            let unpricedCount: Int
        }

        let slices: [EventSlice] = try database.executeQuery(sql: sql, bindings: [startTs]) { stmt in
            let dayStartMs = sqlite3_column_int64(stmt, 1)
            let model = String(cString: sqlite3_column_text(stmt, 2))
            let sess = String(cString: sqlite3_column_text(stmt, 3))
            let eventCount = Int(sqlite3_column_int(stmt, 4))
            let totalTokens = sqlite3_column_int64(stmt, 5)
            let cachedTokens = sqlite3_column_int64(stmt, 6)
            let uncachedTokens = sqlite3_column_int64(stmt, 7)

            return EventSlice(
                dayKey: LocalDayKey(
                    date: Date(timeIntervalSince1970: Double(dayStartMs) / 1000.0),
                    calendar: calendar
                ),
                tokens: TokenBreakdown(
                    inputTokens: uncachedTokens + cachedTokens,
                    cachedInputTokens: cachedTokens,
                    outputTokens: sqlite3_column_int64(stmt, 8),
                    reasoningOutputTokens: sqlite3_column_int64(stmt, 9),
                    sourceTotalTokens: totalTokens
                ),
                cost: MoneyNanoUSD(sqlite3_column_int64(stmt, 10)),
                model: model,
                sessionId: sess,
                eventCount: eventCount,
                unpricedCount: Int(sqlite3_column_int(stmt, 11))
            )
        }

        // 按日历日分组聚合
        var daysMap: [LocalDayKey: (tokens: TokenBreakdown, cost: MoneyNanoUSD, eventCount: Int, sessions: Set<String>, models: [String: (tokens: TokenBreakdown, cost: MoneyNanoUSD, count: Int)], unpriced: Int)] = [:]

        for slice in slices {
            var entry = daysMap[slice.dayKey] ?? (
                tokens: .zero,
                cost: .zero,
                eventCount: 0,
                sessions: [],
                models: [:],
                unpriced: 0
            )

            entry.tokens = entry.tokens + slice.tokens
            entry.cost = entry.cost + slice.cost
            entry.eventCount += slice.eventCount
            entry.sessions.insert(slice.sessionId)
            entry.unpriced += slice.unpricedCount

            var mEntry = entry.models[slice.model] ?? (tokens: .zero, cost: .zero, count: 0)
            mEntry.tokens = mEntry.tokens + slice.tokens
            mEntry.cost = mEntry.cost + slice.cost
            mEntry.count += slice.eventCount
            entry.models[slice.model] = mEntry

            daysMap[slice.dayKey] = entry
        }

        var result: [DayUsageSummaryDTO] = []
        for (dayKey, val) in daysMap {
            let modelSummaries = val.models.map { modelKey, mVal in
                ModelUsageSummaryDTO(
                    modelCanonical: modelKey,
                    tokens: mVal.tokens,
                    estimatedCost: mVal.cost,
                    eventCount: mVal.count
                )
            }.sorted { $0.tokens.canonicalTotalTokens > $1.tokens.canonicalTotalTokens }

            result.append(
                DayUsageSummaryDTO(
                    dayKey: dayKey,
                    date: dayKey.date(calendar: calendar),
                    tokens: val.tokens,
                    estimatedCost: val.cost,
                    eventCount: val.eventCount,
                    sessionCount: val.sessions.count,
                    modelSummaries: modelSummaries,
                    unpricedEventCount: val.unpriced
                )
            )
        }

        return result.sorted { $0.dayKey > $1.dayKey }
    }

    // MARK: - 4. 仪表盘全局指标 (Dashboard)
    public func fetchDashboardMetrics(days: Int = 30, calendar: Calendar = .current) throws -> DashboardMetricsDTO {
        let dailyBuckets = try fetchHistoryDays(daysCount: days, calendar: calendar)

        var totalTokens = TokenBreakdown.zero
        var totalCost = MoneyNanoUSD.zero
        var totalEvents = 0
        var modelsAgg: [String: (tokens: TokenBreakdown, cost: MoneyNanoUSD, count: Int)] = [:]
        var unpricedTotal = 0

        for day in dailyBuckets {
            totalTokens = totalTokens + day.tokens
            totalCost = totalCost + day.estimatedCost
            totalEvents += day.eventCount
            unpricedTotal += day.unpricedEventCount

            for m in day.modelSummaries {
                var mEntry = modelsAgg[m.modelCanonical] ?? (tokens: .zero, cost: .zero, count: 0)
                mEntry.tokens = mEntry.tokens + m.tokens
                mEntry.cost = mEntry.cost + m.estimatedCost
                mEntry.count += m.eventCount
                modelsAgg[m.modelCanonical] = mEntry
            }
        }

        let modelDistribution = modelsAgg.map { modelKey, val in
            ModelUsageSummaryDTO(
                modelCanonical: modelKey,
                tokens: val.tokens,
                estimatedCost: val.cost,
                eventCount: val.count
            )
        }.sorted { $0.tokens.canonicalTotalTokens > $1.tokens.canonicalTotalTokens }

        let todayKey = LocalDayKey(date: Date(), calendar: calendar)
        let todayBucket = dailyBuckets.first(where: { $0.dayKey == todayKey })

        let totalSessionsCount = try database.intScalar(
            sql: "SELECT COUNT(*) FROM codex_sessions WHERE depth = 0 OR parent_session_id IS NULL;"
        )

        let pricingCoverage: PricingCoverage = unpricedTotal == 0
            ? .fullyPriced
            : (unpricedTotal == totalEvents ? .unpriced(totalEvents: totalEvents) : .partiallyPriced(coveredEvents: totalEvents - unpricedTotal, totalEvents: totalEvents))

        return DashboardMetricsDTO(
            totalTokens: totalTokens,
            totalCost: totalCost,
            totalEvents: totalEvents,
            totalSessions: totalSessionsCount,
            activeDaysCount: dailyBuckets.filter { $0.tokens.canonicalTotalTokens > 0 }.count,
            cacheHitRatio: totalTokens.cacheHitRatio,
            dailyBuckets: dailyBuckets,
            modelDistribution: modelDistribution,
            todayTokens: todayBucket?.tokens ?? .zero,
            todayCost: todayBucket?.estimatedCost ?? .zero,
            pricingCoverage: pricingCoverage
        )
    }

    // MARK: - 5. 额度预测快照
    public func fetchRecentRateLimitSnapshots(accountKey: String? = nil, limit: Int = 50) throws -> [RateLimitSnapshotRecord] {
        var bindings: [Any?] = []
        let whereClause: String
        if let accountKey {
            whereClause = "WHERE account_key = ?"
            bindings.append(accountKey)
        } else {
            whereClause = ""
        }
        bindings.append(limit)

        let sql = """
        SELECT id, account_key, observed_at, limit_id, slot, used_percent_milli, window_duration_mins, resets_at, plan_type, raw_json
        FROM rate_limit_snapshots
        \(whereClause)
        ORDER BY observed_at DESC
        LIMIT ?;
        """

        return try database.executeQuery(sql: sql, bindings: bindings) { stmt in
            RateLimitSnapshotRecord(
                id: sqlite3_column_int64(stmt, 0),
                accountKey: String(cString: sqlite3_column_text(stmt, 1)),
                observedAt: sqlite3_column_int64(stmt, 2),
                limitId: String(cString: sqlite3_column_text(stmt, 3)),
                slot: String(cString: sqlite3_column_text(stmt, 4)),
                usedPercentMilli: Int(sqlite3_column_int(stmt, 5)),
                windowDurationMins: sqlite3_column_type(stmt, 6) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 6)) : nil,
                resetsAt: sqlite3_column_type(stmt, 7) != SQLITE_NULL ? sqlite3_column_int64(stmt, 7) : nil,
                planType: sqlite3_column_type(stmt, 8) != SQLITE_NULL && sqlite3_column_text(stmt, 8) != nil ? String(cString: sqlite3_column_text(stmt, 8)!) : nil,
                rawJson: String(cString: sqlite3_column_text(stmt, 9))
            )
        }
    }

    // MARK: - 6. 活动热力图与画像 (Activity Heatmap)
    public func fetchActivityHeatmap(year: Int = Calendar.current.component(.year, from: Date()), calendar: Calendar = .current) throws -> [ActivityHeatmapCellDTO] {
        var startComps = DateComponents()
        startComps.year = year
        startComps.month = 1
        startComps.day = 1
        guard let startDate = calendar.date(from: startComps) else { return [] }

        var endComps = DateComponents()
        endComps.year = year
        endComps.month = 12
        endComps.day = 31
        guard let endDate = calendar.date(from: endComps) else { return [] }

        let startTs = Int64(startDate.timeIntervalSince1970 * 1000)
        let endTs = Int64(endDate.addingTimeInterval(86400).timeIntervalSince1970 * 1000)

        let sql = """
        SELECT
            day_key,
            day_start_ms,
            SUM(total_tokens),
            SUM(event_count),
            SUM(estimated_cost_usd_nano)
        FROM codex_daily_usage_summaries
        WHERE day_start_ms >= ? AND day_start_ms < ?
        GROUP BY day_key, day_start_ms;
        """

        var tokenByDay: [LocalDayKey: (tokens: Int64, count: Int, cost: MoneyNanoUSD)] = [:]
        _ = try database.executeQuery(sql: sql, bindings: [startTs, endTs]) { stmt in
            let dayStartMs = sqlite3_column_int64(stmt, 1)
            let tok = sqlite3_column_int64(stmt, 2)
            let count = Int(sqlite3_column_int(stmt, 3))
            let cost = MoneyNanoUSD(sqlite3_column_int64(stmt, 4))
            let date = Date(timeIntervalSince1970: Double(dayStartMs) / 1000.0)
            let dayKey = LocalDayKey(date: date, calendar: calendar)

            let cur = tokenByDay[dayKey] ?? (0, 0, .zero)
            tokenByDay[dayKey] = (cur.tokens + tok, cur.count + count, cur.cost + cost)
        }

        var cells: [ActivityHeatmapCellDTO] = []
        var curDate = startDate
        while curDate <= endDate {
            let dayKey = LocalDayKey(date: curDate, calendar: calendar)
            let data = tokenByDay[dayKey] ?? (tokens: 0, count: 0, cost: .zero)
            let tokens = data.tokens

            let level: Int
            if tokens == 0 {
                level = 0
            } else if tokens < 100_000 {
                level = 1
            } else if tokens < 1_000_000 {
                level = 2
            } else if tokens < 5_000_000 {
                level = 3
            } else {
                level = 4
            }

            cells.append(
                ActivityHeatmapCellDTO(
                    date: curDate,
                    dayKey: dayKey,
                    tokenCount: tokens,
                    eventCount: data.count,
                    estimatedCost: data.cost,
                    intensityLevel: level
                )
            )

            guard let next = calendar.date(byAdding: .day, value: 1, to: curDate) else { break }
            curDate = next
        }

        return cells
    }

    // MARK: - Row Mappers
    private static func mapSessionRow(_ stmt: OpaquePointer) -> CodexSessionDTO {
        let sid = String(cString: sqlite3_column_text(stmt, 0))
        let rootId = String(cString: sqlite3_column_text(stmt, 1))
        let parentId = sqlite3_column_type(stmt, 2) != SQLITE_NULL && sqlite3_column_text(stmt, 2) != nil
            ? String(cString: sqlite3_column_text(stmt, 2)!) : nil
        let depth = Int(sqlite3_column_int(stmt, 3))
        let title = sqlite3_column_type(stmt, 4) != SQLITE_NULL && sqlite3_column_text(stmt, 4) != nil
            ? String(cString: sqlite3_column_text(stmt, 4)!) : nil
        let proj = sqlite3_column_type(stmt, 5) != SQLITE_NULL && sqlite3_column_text(stmt, 5) != nil
            ? String(cString: sqlite3_column_text(stmt, 5)!) : nil
        let cwd = sqlite3_column_type(stmt, 6) != SQLITE_NULL && sqlite3_column_text(stmt, 6) != nil
            ? String(cString: sqlite3_column_text(stmt, 6)!) : nil
        let createdMs = sqlite3_column_int64(stmt, 7)
        let updatedMs = sqlite3_column_int64(stmt, 8)
        let lastEventMs = sqlite3_column_type(stmt, 9) != SQLITE_NULL ? sqlite3_column_int64(stmt, 9) : nil

        let eventCount = Int(sqlite3_column_int(stmt, 10))
        let totalTokens = sqlite3_column_int64(stmt, 11)
        let inputTokens = sqlite3_column_int64(stmt, 12)
        let cachedTokens = sqlite3_column_int64(stmt, 13)
        let outputTokens = sqlite3_column_int64(stmt, 14)
        let reasoningTokens = sqlite3_column_int64(stmt, 15)
        let costNano = sqlite3_column_int64(stmt, 16)
        let pricingStr = String(cString: sqlite3_column_text(stmt, 17))
        let bucketStr = String(cString: sqlite3_column_text(stmt, 18))
        let hasSubagents = sqlite3_column_int(stmt, 19) != 0

        return CodexSessionDTO(
            sessionId: sid,
            rootSessionId: rootId,
            parentSessionId: parentId,
            depth: depth,
            title: title,
            projectName: proj,
            cwd: cwd,
            createdAt: Date(timeIntervalSince1970: Double(createdMs) / 1000.0),
            updatedAt: Date(timeIntervalSince1970: Double(updatedMs) / 1000.0),
            lastEventAt: lastEventMs.map { Date(timeIntervalSince1970: Double($0) / 1000.0) },
            eventCount: eventCount,
            tokens: TokenBreakdown(
                inputTokens: inputTokens,
                cachedInputTokens: cachedTokens,
                outputTokens: outputTokens,
                reasoningOutputTokens: reasoningTokens,
                sourceTotalTokens: totalTokens
            ),
            estimatedCost: MoneyNanoUSD(costNano),
            pricingStatus: PricingStatus(rawValue: pricingStr) ?? .unpricedUnknownModel,
            bucket: SessionBucket(rawValue: bucketStr) ?? .active,
            hasSubagents: hasSubagents,
            subagentCount: 0
        )
    }

    private static func absoluteSourcePath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        if path.hasPrefix("/") { return path }
        return CodexHistoryRootResolver.resolvePaths().rootURL
            .appendingPathComponent(path)
            .path
    }

    private static func mapEventRow(_ stmt: OpaquePointer) -> CodexUsageEventDTO {
        let eid = String(cString: sqlite3_column_text(stmt, 0))
        let sid = String(cString: sqlite3_column_text(stmt, 1))
        let rootId = String(cString: sqlite3_column_text(stmt, 2))
        let turnIdx = Int(sqlite3_column_int(stmt, 3))
        let callIdx = Int(sqlite3_column_int(stmt, 4))
        let ts = sqlite3_column_int64(stmt, 5)
        let modelRaw = String(cString: sqlite3_column_text(stmt, 6))
        let modelCanonical = String(cString: sqlite3_column_text(stmt, 7))
        let tier = sqlite3_column_type(stmt, 8) != SQLITE_NULL && sqlite3_column_text(stmt, 8) != nil
            ? String(cString: sqlite3_column_text(stmt, 8)!) : nil
        let inTok = sqlite3_column_int64(stmt, 9)
        let cachedTok = sqlite3_column_int64(stmt, 10)
        let outTok = sqlite3_column_int64(stmt, 11)
        let reasonTok = sqlite3_column_int64(stmt, 12)
        let totTok = sqlite3_column_int64(stmt, 13)
        let costNano = sqlite3_column_int64(stmt, 14)
        let ruleId = sqlite3_column_type(stmt, 15) != SQLITE_NULL && sqlite3_column_text(stmt, 15) != nil
            ? String(cString: sqlite3_column_text(stmt, 15)!) : nil
        let pStatus = String(cString: sqlite3_column_text(stmt, 16))
        let deriv = String(cString: sqlite3_column_text(stmt, 17))
        let attrib = String(cString: sqlite3_column_text(stmt, 18))
        let isReplay = sqlite3_column_int(stmt, 19) != 0
        let src = String(cString: sqlite3_column_text(stmt, 20))
        let offset = sqlite3_column_int64(stmt, 21)

        return CodexUsageEventDTO(
            eventId: eid,
            sessionId: sid,
            rootSessionId: rootId,
            turnIndex: turnIdx,
            callIndex: callIdx,
            timestamp: Date(timeIntervalSince1970: Double(ts) / 1000.0),
            modelRaw: modelRaw,
            modelCanonical: modelCanonical,
            serviceTier: tier,
            tokens: TokenBreakdown(
                inputTokens: inTok,
                cachedInputTokens: cachedTok,
                outputTokens: outTok,
                reasoningOutputTokens: reasonTok,
                sourceTotalTokens: totTok
            ),
            estimatedCost: MoneyNanoUSD(costNano),
            pricingRuleId: ruleId,
            pricingStatus: PricingStatus(rawValue: pStatus) ?? .unpricedUnknownModel,
            usageDerivation: UsageDerivation(rawValue: deriv) ?? .explicitLastUsage,
            attributionQuality: AttributionQuality(rawValue: attrib) ?? .sessionFallback,
            isChildReplay: isReplay,
            sourcePath: src,
            lineOffset: offset
        )
    }
}
