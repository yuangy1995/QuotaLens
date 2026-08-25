// QuotaLens 用量分析查询仓储 (UsageAnalyticsRepository)
// 高性能 SQLite 只读参数化查询、Keyset 分页、日桶聚合、模型分布与画像统计

import Foundation
import SQLite3

public enum SessionDeletionError: LocalizedError, Sendable {
    case sessionNotFound
    case unsafeSourcePath(String)
    case sourceIsNotRegularFile(String)

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            return L10n.text("该会话已不存在。", "The session no longer exists.")
        case .unsafeSourcePath(let path):
            return L10n.format(
                "QuotaLens refused to delete a source outside the Codex session folders: %@",
                zhHans: "QuotaLens 已拒绝删除 Codex 会话目录之外的文件：%@",
                path
            )
        case .sourceIsNotRegularFile(let path):
            return L10n.format(
                "The session source is not a regular file: %@",
                zhHans: "会话源不是普通文件：%@",
                path
            )
        }
    }
}

public final class UsageAnalyticsRepository: Sendable {
    private let database: SQLiteDatabase
    private let trashSourceFile: @Sendable (URL) throws -> Void
    private typealias DayAggregate = (
        tokens: TokenBreakdown,
        cost: MoneyNanoUSD,
        eventCount: Int,
        sessions: Set<String>,
        models: [String: (tokens: TokenBreakdown, cost: MoneyNanoUSD, count: Int)],
        unpriced: Int,
        unpricedTokens: Int64
    )

    /// One already-aggregated session/model/day slice. Normal queries read
    /// these from `codex_daily_usage_summaries` so UI loading cost is bounded
    /// by the number of sessions and models, not by raw ledger event count.
    private struct UsageAggregateSlice {
        let dayKey: LocalDayKey
        let tokens: TokenBreakdown
        let cost: MoneyNanoUSD
        let model: String
        let sessionId: String
        let eventCount: Int
        let unpricedCount: Int
        let unpricedTokens: Int64
    }

    public init(
        database: SQLiteDatabase,
        trashSourceFile: @escaping @Sendable (URL) throws -> Void = { sourceURL in
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: sourceURL, resultingItemURL: &resultingURL)
        }
    ) {
        self.database = database
        self.trashSourceFile = trashSourceFile
    }

    // MARK: - 1. 会话列表查询 (支持 Keyset 分页、项目过滤与搜索)
    public func fetchProjectNames() throws -> [String] {
        let sql = """
        SELECT DISTINCT project_name
        FROM codex_sessions
        WHERE project_name IS NOT NULL AND TRIM(project_name) != ''
        ORDER BY project_name COLLATE NOCASE ASC;
        """
        return try database.executeQuery(sql: sql, bindings: []) { stmt in
            if sqlite3_column_type(stmt, 0) != SQLITE_NULL, let text = sqlite3_column_text(stmt, 0) {
                return String(cString: text)
            }
            return nil
        }.compactMap { $0 }
    }

    public func fetchSessions(
        sort: SessionSort = .lastActivityDesc,
        search: String? = nil,
        project: String? = nil,
        limit: Int = 50,
        cursor: String? = nil
    ) throws -> [CodexSessionDTO] {
        try fetchSessionPage(sort: sort, search: search, project: project, limit: limit, cursor: cursor).sessions
    }

    public func fetchSessionPage(
        sort: SessionSort = .lastActivityDesc,
        search: String? = nil,
        project: String? = nil,
        limit: Int = 50,
        cursor: String? = nil
    ) throws -> CodexSessionPageDTO {
        let requestedLimit = min(max(1, limit), 500)
        var conditions: [String] = []
        var bindings: [Any?] = []

        // 只查询主会话（或顶层会话），深度为 0
        conditions.append("(depth = 0 OR parent_session_id IS NULL)")

        if let project = project?.trimmingCharacters(in: .whitespacesAndNewlines), !project.isEmpty {
            conditions.append("project_name = ?")
            bindings.append(project)
        }

        if let search = search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
            let pattern = "%\(Self.escapeLike(search))%"
            conditions.append("""
            (
                title LIKE ? ESCAPE '\\'
                OR project_name LIKE ? ESCAPE '\\'
                OR session_id LIKE ? ESCAPE '\\'
                OR cwd LIKE ? ESCAPE '\\'
                OR agent_type LIKE ? ESCAPE '\\'
                OR EXISTS (
                    SELECT 1
                    FROM codex_session_summaries m
                    WHERE m.session_id = codex_sessions.session_id
                      AND m.model_canonical LIKE ? ESCAPE '\\'
                )
            )
            """)
            bindings.append(contentsOf: [pattern, pattern, pattern, pattern, pattern, pattern])
        }

        if let cursorParts = Self.decodeCursor(cursor) {
            switch sort {
            case .lastActivityDesc:
                conditions.append("(COALESCE(last_event_at, updated_at) < ? OR (COALESCE(last_event_at, updated_at) = ? AND session_id < ?))")
            case .totalTokensDesc:
                conditions.append("(total_tokens < ? OR (total_tokens = ? AND session_id < ?))")
            case .estimatedCostDesc:
                conditions.append("(estimated_cost_usd_nano < ? OR (estimated_cost_usd_nano = ? AND session_id < ?))")
            case .createdDesc:
                conditions.append("(created_at < ? OR (created_at = ? AND session_id < ?))")
            }
            bindings.append(contentsOf: [cursorParts.primary, cursorParts.primary, cursorParts.sessionId])
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
            pricing_status, bucket, has_subagents, agent_type
        FROM codex_sessions
        \(whereClause)
        \(orderClause)
        LIMIT ?;
        """
        bindings.append(requestedLimit + 1)

        let rows = try database.executeQuery(sql: sql, bindings: bindings) { stmt in
            Self.mapSessionRow(stmt)
        }
        let hasMore = rows.count > requestedLimit
        let pageRows = Array(rows.prefix(requestedLimit))
        let nextCursor = hasMore ? pageRows.last.map { Self.encodeCursor(session: $0, sort: sort) } : nil
        return CodexSessionPageDTO(sessions: pageRows, nextCursor: nextCursor)
    }

    // MARK: - 2. 会话完整详情查询
    public func fetchSessionDetail(sessionId: String) throws -> CodexSessionDetailDTO? {
        // 主会话
        let mainSessionSql = """
        SELECT
            session_id, root_session_id, parent_session_id, depth, title, project_name, cwd,
            created_at, updated_at, last_event_at, event_count, total_tokens, input_tokens,
            cached_input_tokens, output_tokens, reasoning_output_tokens, estimated_cost_usd_nano,
            pricing_status, bucket, has_subagents, agent_type
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
            pricing_status, bucket, has_subagents, agent_type
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

        let recentEventsSql = """
        SELECT
            event_id, session_id, root_session_id, turn_index, call_index, timestamp_ms,
            model_raw, model_canonical, service_tier, reasoning_effort, input_tokens, cached_input_tokens,
            output_tokens, reasoning_output_tokens, total_tokens, estimated_cost_usd_nano,
            pricing_rule_id, pricing_status, usage_derivation, attribution_quality,
            is_child_replay, source_path, line_offset, timestamp_quality, pricing_catalog_version
        FROM codex_usage_events
        WHERE session_id = ? AND is_child_replay = 0
        ORDER BY timestamp_ms DESC, line_offset DESC
        LIMIT 100;
        """
        let recentEvents = try database.executeQuery(sql: recentEventsSql, bindings: [sessionId], rowMapper: Self.mapEventRow)

        let preferredSourcePath = {
            guard let sourceInfo else { return "" }
            return sourceInfo.0.isEmpty ? sourceInfo.1 : sourceInfo.0
        }()

        return CodexSessionDetailDTO(
            session: mainSession,
            subagents: subagents,
            modelSummaries: modelSummaries,
            recentEvents: recentEvents,
            sourcePath: Self.absoluteSourcePath(preferredSourcePath),
            relativePath: sourceInfo?.1 ?? "",
            totalSubagentTokens: totalSubagentTokens,
            totalSubagentCost: totalSubagentCost
        )
    }

    /// Moves the rollout source for a session tree to the macOS Trash, then
    /// removes its derived analytics rows so the deleted session disappears
    /// immediately and is not re-imported on the next scan.
    public func deleteSession(sessionId: String, historyRootURL: URL? = nil) throws {
        struct SourceRecord {
            let sessionId: String
            let sourcePath: String
            let relativePath: String
        }

        let records = try database.executeQuery(
            sql: """
            SELECT session_id, source_path, relative_path
            FROM codex_sessions
            WHERE session_id = ?
               OR root_session_id = (
                    SELECT root_session_id
                    FROM codex_sessions
                    WHERE session_id = ?
               );
            """,
            bindings: [sessionId, sessionId]
        ) { statement -> SourceRecord in
            SourceRecord(
                sessionId: String(cString: sqlite3_column_text(statement, 0)),
                sourcePath: String(cString: sqlite3_column_text(statement, 1)),
                relativePath: String(cString: sqlite3_column_text(statement, 2))
            )
        }

        guard !records.isEmpty else {
            throw SessionDeletionError.sessionNotFound
        }

        let historyPaths = CodexHistoryPaths(
            rootURL: historyRootURL ?? CodexHistoryRootResolver.resolveRootURL()
        )
        var sourceURLsByPath: [String: URL] = [:]
        for record in records {
            let sourceURL = try Self.safeSessionSourceURL(
                sourcePath: record.sourcePath,
                relativePath: record.relativePath,
                historyPaths: historyPaths
            )
            sourceURLsByPath[sourceURL.path] = sourceURL
        }

        let fileManager = FileManager.default
        for sourceURL in sourceURLsByPath.values.sorted(by: { $0.path < $1.path }) {
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
            let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw SessionDeletionError.sourceIsNotRegularFile(sourceURL.path)
            }
            try trashSourceFile(sourceURL)
        }

        let sessionIDs = Set(records.map(\.sessionId))
        let sourceKeys = Set(records.map { "\($0.sourcePath)\u{1F}\($0.relativePath)" })

        try database.transaction {
            for sessionID in sessionIDs {
                try database.executeUpdate(
                    sql: "DELETE FROM codex_usage_events WHERE session_id = ? OR root_session_id = ?;",
                    bindings: [sessionID, sessionID]
                )
                try database.executeUpdate(
                    sql: "DELETE FROM codex_session_summaries WHERE session_id = ?;",
                    bindings: [sessionID]
                )
                try database.executeUpdate(
                    sql: "DELETE FROM codex_daily_usage_summaries WHERE session_id = ?;",
                    bindings: [sessionID]
                )
            }

            for sourceKey in sourceKeys {
                let parts = sourceKey.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
                let sourcePath = String(parts[0])
                let relativePath = parts.count > 1 ? String(parts[1]) : ""
                try database.executeUpdate(
                    sql: "DELETE FROM codex_usage_events WHERE source_path = ? OR source_path = ?;",
                    bindings: [sourcePath, relativePath]
                )
                try database.executeUpdate(
                    sql: "DELETE FROM codex_import_sources WHERE source_path = ? OR relative_path = ?;",
                    bindings: [sourcePath, relativePath]
                )
            }

            for sessionID in sessionIDs {
                try database.executeUpdate(
                    sql: "DELETE FROM codex_sessions WHERE session_id = ?;",
                    bindings: [sessionID]
                )
            }
        }
    }

    // MARK: - 3. 每日用量汇总 (History 列表)
    public func fetchHistoryDays(
        daysCount: Int = 30,
        calendar: Calendar = .current,
        now: Date = Date()
    ) throws -> [DayUsageSummaryDTO] {
        let normalizedDayCount = max(1, daysCount)
        let todayStart = calendar.startOfDay(for: now)
        guard let startDate = calendar.date(byAdding: .day, value: -(normalizedDayCount - 1), to: todayStart),
              let endDate = calendar.date(byAdding: .day, value: 1, to: todayStart) else {
            return []
        }
        let slices = try fetchUsageAggregateSlices(
            rangeStart: startDate,
            endExclusive: endDate,
            calendar: calendar
        )

        // 按日历日分组聚合
        var daysMap: [LocalDayKey: DayAggregate] = [:]

        for slice in slices {
            var entry = daysMap[slice.dayKey] ?? (
                tokens: .zero,
                cost: .zero,
                eventCount: 0,
                sessions: [],
                models: [:],
                unpriced: 0,
                unpricedTokens: 0
            )

            entry.tokens = entry.tokens + slice.tokens
            entry.cost = entry.cost + slice.cost
            entry.eventCount += slice.eventCount
            entry.sessions.insert(slice.sessionId)
            entry.unpriced += slice.unpricedCount
            entry.unpricedTokens += slice.unpricedTokens

            var mEntry = entry.models[slice.model] ?? (tokens: .zero, cost: .zero, count: 0)
            mEntry.tokens = mEntry.tokens + slice.tokens
            mEntry.cost = mEntry.cost + slice.cost
            mEntry.count += slice.eventCount
            entry.models[slice.model] = mEntry

            daysMap[slice.dayKey] = entry
        }

        var result: [DayUsageSummaryDTO] = []
        var cursorDate = startDate
        for _ in 0..<normalizedDayCount {
            let dayKey = LocalDayKey(date: cursorDate, calendar: calendar)
            let val = daysMap[dayKey] ?? (
                tokens: .zero,
                cost: .zero,
                eventCount: 0,
                sessions: Set<String>(),
                models: [:],
                unpriced: 0,
                unpricedTokens: 0
            )
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
                    unpricedEventCount: val.unpriced,
                    unpricedTokenCount: val.unpricedTokens
                )
            )
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursorDate) else { break }
            cursorDate = next
        }

        return result.sorted { $0.dayKey > $1.dayKey }
    }

    public func fetchDayDetail(
        dayKey: LocalDayKey,
        calendar: Calendar = .current,
        eventLimit: Int = 500
    ) throws -> DayDetailDTO {
        let startDate = dayKey.date(calendar: calendar)
        guard let endDate = calendar.date(byAdding: .day, value: 1, to: startDate) else {
            return DayDetailDTO(summary: DayUsageSummaryDTO(dayKey: dayKey, date: startDate))
        }
        let startMs = Int64(startDate.timeIntervalSince1970 * 1_000)
        let endMs = Int64(endDate.timeIntervalSince1970 * 1_000)

        struct SessionAggregateRow {
            let sessionId: String
            let eventCount: Int
            let tokens: TokenBreakdown
            let cost: MoneyNanoUSD
            let unpricedCount: Int
            let unpricedTokenCount: Int64
        }

        let aggregateSlices = try fetchUsageAggregateSlices(
            rangeStart: startDate,
            endExclusive: endDate,
            calendar: calendar
        )
        var sessionAggregates: [String: (
            eventCount: Int,
            tokens: TokenBreakdown,
            cost: MoneyNanoUSD,
            unpricedCount: Int,
            unpricedTokens: Int64
        )] = [:]
        var modelAggregates: [String: (
            eventCount: Int,
            tokens: TokenBreakdown,
            cost: MoneyNanoUSD,
            unpricedCount: Int
        )] = [:]

        for aggregate in aggregateSlices {
            var session = sessionAggregates[aggregate.sessionId]
                ?? (0, .zero, .zero, 0, 0)
            session.eventCount += aggregate.eventCount
            session.tokens = session.tokens + aggregate.tokens
            session.cost = session.cost + aggregate.cost
            session.unpricedCount += aggregate.unpricedCount
            session.unpricedTokens += aggregate.unpricedTokens
            sessionAggregates[aggregate.sessionId] = session

            var model = modelAggregates[aggregate.model]
                ?? (0, .zero, .zero, 0)
            model.eventCount += aggregate.eventCount
            model.tokens = model.tokens + aggregate.tokens
            model.cost = model.cost + aggregate.cost
            model.unpricedCount += aggregate.unpricedCount
            modelAggregates[aggregate.model] = model
        }

        let sessionRows = sessionAggregates.map { sessionId, aggregate in
            SessionAggregateRow(
                sessionId: sessionId,
                eventCount: aggregate.eventCount,
                tokens: aggregate.tokens,
                cost: aggregate.cost,
                unpricedCount: aggregate.unpricedCount,
                unpricedTokenCount: aggregate.unpricedTokens
            )
        }.sorted {
            if $0.tokens.canonicalTotalTokens != $1.tokens.canonicalTotalTokens {
                return $0.tokens.canonicalTotalTokens > $1.tokens.canonicalTotalTokens
            }
            return $0.sessionId > $1.sessionId
        }

        let modelSummaries = modelAggregates.map { model, aggregate in
            ModelUsageSummaryDTO(
                modelCanonical: model,
                tokens: aggregate.tokens,
                estimatedCost: aggregate.cost,
                eventCount: aggregate.eventCount,
                unpricedCount: aggregate.unpricedCount
            )
        }.sorted { $0.tokens.canonicalTotalTokens > $1.tokens.canonicalTotalTokens }

        let recentEvents = try database.executeQuery(
            sql: """
            SELECT
                event_id, session_id, root_session_id, turn_index, call_index, timestamp_ms,
                model_raw, model_canonical, service_tier, reasoning_effort, input_tokens, cached_input_tokens,
                output_tokens, reasoning_output_tokens, total_tokens, estimated_cost_usd_nano,
                pricing_rule_id, pricing_status, usage_derivation, attribution_quality,
                is_child_replay, source_path, line_offset, timestamp_quality, pricing_catalog_version
            FROM codex_usage_events
            WHERE is_child_replay = 0 AND timestamp_ms >= ? AND timestamp_ms < ?
            ORDER BY timestamp_ms DESC, line_offset DESC
            LIMIT ?;
            """,
            bindings: [startMs, endMs, min(max(1, eventLimit), 5_000)],
            rowMapper: Self.mapEventRow
        )
        let eventsBySession = Dictionary(grouping: recentEvents, by: \CodexUsageEventDTO.sessionId)

        var slices: [DaySessionSliceDTO] = []
        var totalTokens = TokenBreakdown.zero
        var totalCost = MoneyNanoUSD.zero
        var totalEvents = 0
        var totalUnpriced = 0
        var totalUnpricedTokens: Int64 = 0

        for row in sessionRows {
            totalTokens = totalTokens + row.tokens
            totalCost = totalCost + row.cost
            totalEvents += row.eventCount
            totalUnpriced += row.unpricedCount
            totalUnpricedTokens += row.unpricedTokenCount

            let sessionSQL = """
            SELECT
                session_id, root_session_id, parent_session_id, depth, title, project_name, cwd,
                created_at, updated_at, last_event_at, event_count, total_tokens, input_tokens,
                cached_input_tokens, output_tokens, reasoning_output_tokens, estimated_cost_usd_nano,
                pricing_status, bucket, has_subagents, agent_type
            FROM codex_sessions WHERE session_id = ?;
            """
            guard let session = try database.executeQuery(
                sql: sessionSQL,
                bindings: [row.sessionId],
                rowMapper: Self.mapSessionRow
            ).first else { continue }
            slices.append(
                DaySessionSliceDTO(
                    session: session,
                    dayTokens: row.tokens,
                    dayCost: row.cost,
                    dayEventCount: row.eventCount,
                    events: eventsBySession[row.sessionId] ?? []
                )
            )
        }

        return DayDetailDTO(
            summary: DayUsageSummaryDTO(
                dayKey: dayKey,
                date: startDate,
                tokens: totalTokens,
                estimatedCost: totalCost,
                eventCount: totalEvents,
                sessionCount: sessionRows.count,
                modelSummaries: modelSummaries,
                unpricedEventCount: totalUnpriced,
                unpricedTokenCount: totalUnpricedTokens
            ),
            sessions: slices
        )
    }

    // MARK: - 4. 仪表盘全局指标 (Dashboard)
    public func fetchDashboardMetrics(days: Int = 30, calendar: Calendar = .current) throws -> DashboardMetricsDTO {
        let now = Date()
        let rangeSeconds = Double(max(1, days)) * 86_400.0
        let startDate = now.addingTimeInterval(-rangeSeconds)
        return try fetchDashboardMetrics(rangeStart: startDate, endExclusive: now, calendar: calendar)
    }

    public func fetchTodayMetrics(calendar: Calendar = .current, now: Date = Date()) throws -> DashboardMetricsDTO {
        try fetchDashboardMetrics(
            rangeStart: calendar.startOfDay(for: now),
            endExclusive: now,
            calendar: calendar
        )
    }

    public func fetchDashboardMetrics(
        rangeStart startDate: Date,
        endExclusive endDate: Date,
        calendar: Calendar = .current
    ) throws -> DashboardMetricsDTO {
        let slices = try fetchUsageAggregateSlices(
            rangeStart: startDate,
            endExclusive: endDate,
            calendar: calendar
        )

        var totalTokens = TokenBreakdown.zero
        var totalCost = MoneyNanoUSD.zero
        var totalEvents = 0
        var modelsAgg: [String: (tokens: TokenBreakdown, cost: MoneyNanoUSD, count: Int, unpriced: Int)] = [:]
        var unpricedTotal = 0
        var sessions = Set<String>()
        var daysMap: [LocalDayKey: DayAggregate] = [:]

        for slice in slices {
            totalTokens = totalTokens + slice.tokens
            totalCost = totalCost + slice.cost
            totalEvents += slice.eventCount
            sessions.insert(slice.sessionId)
            unpricedTotal += slice.unpricedCount

            var modelEntry = modelsAgg[slice.model] ?? (tokens: .zero, cost: .zero, count: 0, unpriced: 0)
            modelEntry.tokens = modelEntry.tokens + slice.tokens
            modelEntry.cost = modelEntry.cost + slice.cost
            modelEntry.count += slice.eventCount
            modelEntry.unpriced += slice.unpricedCount
            modelsAgg[slice.model] = modelEntry

            var dayEntry = daysMap[slice.dayKey] ?? (
                tokens: .zero,
                cost: .zero,
                eventCount: 0,
                sessions: [],
                models: [:],
                unpriced: 0,
                unpricedTokens: 0
            )
            dayEntry.tokens = dayEntry.tokens + slice.tokens
            dayEntry.cost = dayEntry.cost + slice.cost
            dayEntry.eventCount += slice.eventCount
            dayEntry.sessions.insert(slice.sessionId)
            dayEntry.unpriced += slice.unpricedCount
            dayEntry.unpricedTokens += slice.unpricedTokens
            var dayModelEntry = dayEntry.models[slice.model] ?? (tokens: .zero, cost: .zero, count: 0)
            dayModelEntry.tokens = dayModelEntry.tokens + slice.tokens
            dayModelEntry.cost = dayModelEntry.cost + slice.cost
            dayModelEntry.count += slice.eventCount
            dayEntry.models[slice.model] = dayModelEntry
            daysMap[slice.dayKey] = dayEntry
        }

        let modelDistribution = modelsAgg.map { modelKey, val in
            ModelUsageSummaryDTO(
                modelCanonical: modelKey,
                tokens: val.tokens,
                estimatedCost: val.cost,
                eventCount: val.count,
                unpricedCount: val.unpriced
            )
        }.sorted { $0.tokens.canonicalTotalTokens > $1.tokens.canonicalTotalTokens }

        let dailyBuckets = Self.filledDailyBuckets(
            startDate: calendar.startOfDay(for: startDate),
            endDate: calendar.startOfDay(for: endDate),
            calendar: calendar,
            daysMap: daysMap
        )

        let todayKey = LocalDayKey(date: endDate, calendar: calendar)
        let todayBucket = dailyBuckets.first(where: { $0.dayKey == todayKey })

        let pricingCoverage: PricingCoverage = unpricedTotal == 0
            ? .fullyPriced
            : (unpricedTotal == totalEvents ? .unpriced(totalEvents: totalEvents) : .partiallyPriced(coveredEvents: totalEvents - unpricedTotal, totalEvents: totalEvents))

        return DashboardMetricsDTO(
            totalTokens: totalTokens,
            totalCost: totalCost,
            totalEvents: totalEvents,
            totalSessions: sessions.count,
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

        guard let endExclusive = calendar.date(byAdding: .day, value: 1, to: endDate) else { return [] }
        let startTs = Int64(startDate.timeIntervalSince1970 * 1000)
        let endTs = Int64(endExclusive.timeIntervalSince1970 * 1000)

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

    public func fetchDiagnostics() throws -> UsageDiagnosticsDTO {
        let sourcesDiscovered = try database.intScalar(sql: "SELECT COUNT(*) FROM codex_import_sources;")
        let sourcesIndexed = try database.intScalar(sql: "SELECT COUNT(*) FROM codex_import_sources WHERE status = 'indexed';")
        let sourcesTombstoned = try database.intScalar(sql: "SELECT COUNT(*) FROM codex_import_sources WHERE status = 'tombstoned';")
        let totalEvents = try database.intScalar(sql: "SELECT COUNT(*) FROM codex_usage_events WHERE is_child_replay = 0;")
        let unknownModelEvents = try database.intScalar(sql: "SELECT COUNT(*) FROM codex_usage_events WHERE model_canonical = 'unknown' AND is_child_replay = 0;")
        let unpricedEvents = try database.intScalar(sql: "SELECT COUNT(*) FROM codex_usage_events WHERE pricing_status != 'priced' AND is_child_replay = 0;")
        let fallbackTimestampEvents = try database.intScalar(
            sql: "SELECT COUNT(*) FROM codex_usage_events WHERE timestamp_quality != 'event_timestamp' AND is_child_replay = 0;"
        )
        let malformedLineCount = try database.intScalar(sql: "SELECT COALESCE(SUM(malformed_line_count), 0) FROM codex_import_sources;")
        let unresolvedTimestampCount = try database.intScalar(sql: "SELECT COALESCE(SUM(unresolved_timestamp_count), 0) FROM codex_import_sources;")
        let unknownEventTypeCount = try database.intScalar(sql: "SELECT COALESCE(SUM(unknown_event_type_count), 0) FROM codex_import_sources;")
        let rebuiltSourceCount = try database.intScalar(sql: "SELECT COUNT(*) FROM codex_import_sources WHERE rebuild_reason IS NOT NULL;")
        let integrityCheckPassed = try database.stringScalar(sql: "PRAGMA integrity_check(1);") == "ok"
        let foreignKeyViolationCount = try database.executeQuery(sql: "PRAGMA foreign_key_check;") { _ in 1 }.count

        let sessionSummaryViolations = try database.intScalar(sql: """
        SELECT COUNT(*)
        FROM codex_sessions s
        WHERE s.event_count != COALESCE((SELECT SUM(event_count) FROM codex_session_summaries x WHERE x.session_id = s.session_id), 0)
           OR s.total_tokens != COALESCE((SELECT SUM(total_tokens) FROM codex_session_summaries x WHERE x.session_id = s.session_id), 0)
           OR s.estimated_cost_usd_nano != COALESCE((SELECT SUM(estimated_cost_usd_nano) FROM codex_session_summaries x WHERE x.session_id = s.session_id), 0);
        """)
        let dailySummaryViolations = try database.intScalar(sql: """
        SELECT COUNT(*) FROM (
            SELECT s.session_id
            FROM codex_session_summaries s
            LEFT JOIN codex_daily_usage_summaries d
              ON d.session_id = s.session_id AND d.model_canonical = s.model_canonical
            GROUP BY s.session_id, s.model_canonical
            HAVING s.event_count != COALESCE(SUM(d.event_count), 0)
                OR s.total_tokens != COALESCE(SUM(d.total_tokens), 0)
                OR s.estimated_cost_usd_nano != COALESCE(SUM(d.estimated_cost_usd_nano), 0)
        );
        """)
        let invalidValueViolations = try database.intScalar(sql: """
        SELECT COUNT(*) FROM codex_usage_events
        WHERE estimated_cost_usd_nano < 0
           OR input_tokens < 0 OR cached_input_tokens < 0 OR output_tokens < 0 OR reasoning_output_tokens < 0
           OR cached_input_tokens > input_tokens
           OR reasoning_output_tokens > output_tokens;
        """)
        let parentCycleViolations = try database.intScalar(sql: """
        WITH RECURSIVE chain(start_id, current_id, path, is_cycle, hops) AS (
            SELECT session_id, parent_session_id, '|' || session_id || '|', 0, 0
            FROM codex_sessions
            UNION ALL
            SELECT chain.start_id, s.parent_session_id,
                   chain.path || s.session_id || '|',
                   CASE WHEN instr(chain.path, '|' || s.session_id || '|') > 0 THEN 1 ELSE 0 END,
                   chain.hops + 1
            FROM chain
            JOIN codex_sessions s ON s.session_id = chain.current_id
            WHERE chain.is_cycle = 0 AND chain.hops < 64
        )
        SELECT COUNT(DISTINCT start_id) FROM chain WHERE is_cycle = 1;
        """)
        let invariantViolationCount = sessionSummaryViolations
            + dailySummaryViolations
            + invalidValueViolations
            + parentCycleViolations
        let activeCatalog = try database.stringScalar(
            sql: "SELECT catalog_version FROM codex_pricing_catalogs WHERE is_active = 1 ORDER BY published_at DESC LIMIT 1;"
        )
        let parserVersion = try database.intScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'codex_parser_version';"
        )
        let lastScanSeconds = try database.int64Scalar(
            sql: "SELECT MAX(completed_at) FROM codex_import_runs WHERE status = 'success';"
        )
        let lastScan = lastScanSeconds.map { value -> Date in
            if value > 100_000_000_000 {
                return Date(timeIntervalSince1970: Double(value) / 1000.0)
            }
            return Date(timeIntervalSince1970: Double(value))
        }

        return UsageDiagnosticsDTO(
            sourcesDiscovered: sourcesDiscovered,
            sourcesIndexed: sourcesIndexed,
            sourcesTombstoned: sourcesTombstoned,
            unknownModelEvents: unknownModelEvents,
            unpricedEvents: unpricedEvents,
            fallbackTimestampEvents: fallbackTimestampEvents,
            totalEvents: totalEvents,
            activePricingCatalogVersion: activeCatalog,
            parserVersion: parserVersion == 0 ? ParserCheckpoint.currentParserVersion : parserVersion,
            lastSuccessfulScanAt: lastScan,
            malformedLineCount: malformedLineCount,
            unresolvedTimestampCount: unresolvedTimestampCount,
            unknownEventTypeCount: unknownEventTypeCount,
            rebuiltSourceCount: rebuiltSourceCount,
            integrityCheckPassed: integrityCheckPassed,
            foreignKeyViolationCount: foreignKeyViolationCount,
            invariantViolationCount: invariantViolationCount
        )
    }

    private struct CursorParts {
        let primary: Int64
        let sessionId: String
    }

    private static func decodeCursor(_ cursor: String?) -> CursorParts? {
        guard let cursor, !cursor.isEmpty else { return nil }
        let parts = cursor.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let primary = Int64(parts[0]) else { return nil }
        return CursorParts(primary: primary, sessionId: parts[1])
    }

    private static func encodeCursor(session: CodexSessionDTO, sort: SessionSort) -> String {
        let primary: Int64
        switch sort {
        case .lastActivityDesc:
            primary = Int64((session.lastEventAt ?? session.updatedAt).timeIntervalSince1970 * 1_000)
        case .totalTokensDesc:
            primary = session.tokens.canonicalTotalTokens
        case .estimatedCostDesc:
            primary = session.estimatedCost.rawValue
        case .createdDesc:
            primary = Int64(session.createdAt.timeIntervalSince1970 * 1_000)
        }
        return "\(primary)|\(session.sessionId)"
    }

    private static func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// Reads full calendar days from the compact aggregate table and only
    /// touches raw ledger events for the two partial boundary days. A fallback
    /// keeps manually-created and legacy databases working when summaries have
    /// not been built yet.
    private func fetchUsageAggregateSlices(
        rangeStart startDate: Date,
        endExclusive endDate: Date,
        calendar: Calendar
    ) throws -> [UsageAggregateSlice] {
        guard startDate < endDate else { return [] }

        let startDay = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)
        guard let dayAfterStart = calendar.date(byAdding: .day, value: 1, to: startDay) else {
            return try fetchRawUsageSlices(rangeStart: startDate, endExclusive: endDate, calendar: calendar)
        }

        let startsOnDayBoundary = abs(startDate.timeIntervalSince(startDay)) < 0.001
        let summaryStart = startsOnDayBoundary ? startDay : dayAfterStart

        // No complete calendar day exists inside this range.
        guard summaryStart < endDay else {
            return try fetchRawUsageSlices(rangeStart: startDate, endExclusive: endDate, calendar: calendar)
        }

        var slices: [UsageAggregateSlice] = []
        if startDate < summaryStart {
            slices += try fetchRawUsageSlices(
                rangeStart: startDate,
                endExclusive: min(summaryStart, endDate),
                calendar: calendar
            )
        }

        slices += try fetchFullDayUsageSlices(
            rangeStart: summaryStart,
            endExclusive: endDay,
            calendar: calendar
        )

        if endDay < endDate {
            slices += try fetchRawUsageSlices(
                rangeStart: max(endDay, startDate),
                endExclusive: endDate,
                calendar: calendar
            )
        }
        return slices
    }

    private func fetchFullDayUsageSlices(
        rangeStart startDate: Date,
        endExclusive endDate: Date,
        calendar: Calendar
    ) throws -> [UsageAggregateSlice] {
        guard startDate < endDate else { return [] }
        let startMs = Int64(startDate.timeIntervalSince1970 * 1_000)
        let endMs = Int64(endDate.timeIntervalSince1970 * 1_000)

        let summaries = try database.executeQuery(
            sql: """
            SELECT
                session_id, day_start_ms, model_canonical, event_count, total_tokens,
                uncached_input_tokens, cached_input_tokens, output_tokens,
                reasoning_output_tokens, estimated_cost_usd_nano, unpriced_event_count
            FROM codex_daily_usage_summaries
            WHERE day_start_ms >= ? AND day_start_ms < ?
            ORDER BY day_start_ms ASC, session_id ASC, model_canonical ASC;
            """,
            bindings: [startMs, endMs]
        ) { statement -> UsageAggregateSlice in
            let total = sqlite3_column_int64(statement, 4)
            let uncached = sqlite3_column_int64(statement, 5)
            let cached = sqlite3_column_int64(statement, 6)
            let unpriced = Int(sqlite3_column_int(statement, 10))
            let dayStart = Date(
                timeIntervalSince1970: Double(sqlite3_column_int64(statement, 1)) / 1_000.0
            )
            return UsageAggregateSlice(
                dayKey: LocalDayKey(date: dayStart, calendar: calendar),
                tokens: TokenBreakdown(
                    inputTokens: uncached + cached,
                    cachedInputTokens: cached,
                    outputTokens: sqlite3_column_int64(statement, 7),
                    reasoningOutputTokens: sqlite3_column_int64(statement, 8),
                    sourceTotalTokens: total
                ),
                cost: MoneyNanoUSD(sqlite3_column_int64(statement, 9)),
                model: String(cString: sqlite3_column_text(statement, 2)),
                sessionId: String(cString: sqlite3_column_text(statement, 0)),
                eventCount: Int(sqlite3_column_int(statement, 3)),
                unpricedCount: unpriced,
                // Summaries are grouped by model. A model row containing an
                // unpriced event is conservatively treated as fully unpriced.
                unpricedTokens: unpriced > 0 ? total : 0
            )
        }

        if !summaries.isEmpty {
            return summaries
        }

        let hasRawEvents = try database.intScalar(
            sql: """
            SELECT EXISTS(
                SELECT 1 FROM codex_usage_events
                WHERE is_child_replay = 0 AND timestamp_ms >= ? AND timestamp_ms < ?
                LIMIT 1
            );
            """,
            bindings: [startMs, endMs]
        ) > 0
        return hasRawEvents
            ? try fetchRawUsageSlices(rangeStart: startDate, endExclusive: endDate, calendar: calendar)
            : []
    }

    private func fetchRawUsageSlices(
        rangeStart startDate: Date,
        endExclusive endDate: Date,
        calendar: Calendar
    ) throws -> [UsageAggregateSlice] {
        guard startDate < endDate else { return [] }
        let startMs = Int64(startDate.timeIntervalSince1970 * 1_000)
        let endMs = Int64(endDate.timeIntervalSince1970 * 1_000)

        return try database.executeQuery(
            sql: """
            SELECT
                timestamp_ms, model_canonical, session_id, pricing_status,
                input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens,
                total_tokens, estimated_cost_usd_nano
            FROM codex_usage_events
            WHERE is_child_replay = 0 AND timestamp_ms >= ? AND timestamp_ms < ?;
            """,
            bindings: [startMs, endMs]
        ) { statement -> UsageAggregateSlice in
            let timestampMs = sqlite3_column_int64(statement, 0)
            let total = sqlite3_column_int64(statement, 8)
            let pricingStatus = PricingStatus(
                rawValue: String(cString: sqlite3_column_text(statement, 3))
            ) ?? .unpricedUnknownModel
            return UsageAggregateSlice(
                dayKey: LocalDayKey(
                    date: Date(timeIntervalSince1970: Double(timestampMs) / 1_000.0),
                    calendar: calendar
                ),
                tokens: TokenBreakdown(
                    inputTokens: sqlite3_column_int64(statement, 4),
                    cachedInputTokens: sqlite3_column_int64(statement, 5),
                    outputTokens: sqlite3_column_int64(statement, 6),
                    reasoningOutputTokens: sqlite3_column_int64(statement, 7),
                    sourceTotalTokens: total
                ),
                cost: MoneyNanoUSD(sqlite3_column_int64(statement, 9)),
                model: String(cString: sqlite3_column_text(statement, 1)),
                sessionId: String(cString: sqlite3_column_text(statement, 2)),
                eventCount: 1,
                unpricedCount: pricingStatus.isPriced ? 0 : 1,
                unpricedTokens: pricingStatus.isPriced ? 0 : total
            )
        }
    }

    private static func filledDailyBuckets(
        startDate: Date,
        endDate: Date,
        calendar: Calendar,
        daysMap: [LocalDayKey: DayAggregate]
    ) -> [DayUsageSummaryDTO] {
        var result: [DayUsageSummaryDTO] = []
        var cursor = startDate
        while cursor <= endDate {
            let dayKey = LocalDayKey(date: cursor, calendar: calendar)
            let val = daysMap[dayKey] ?? (
                tokens: .zero,
                cost: .zero,
                eventCount: 0,
                sessions: Set<String>(),
                models: [:],
                unpriced: 0,
                unpricedTokens: 0
            )
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
                    unpricedEventCount: val.unpriced,
                    unpricedTokenCount: val.unpricedTokens
                )
            )
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result.sorted { $0.dayKey > $1.dayKey }
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
        let agentType = sqlite3_column_type(stmt, 20) != SQLITE_NULL && sqlite3_column_text(stmt, 20) != nil
            ? String(cString: sqlite3_column_text(stmt, 20)!) : nil

        return CodexSessionDTO(
            sessionId: sid,
            rootSessionId: rootId,
            parentSessionId: parentId,
            depth: depth,
            title: title,
            projectName: proj,
            cwd: cwd,
            agentType: agentType,
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

    private static func safeSessionSourceURL(
        sourcePath: String,
        relativePath: String,
        historyPaths: CodexHistoryPaths
    ) throws -> URL {
        let rootURL = historyPaths.rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let allowedRoots = [historyPaths.sessionsURL, historyPaths.archivedSessionsURL]
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }

        var candidates: [URL] = []
        if !sourcePath.isEmpty {
            candidates.append(
                sourcePath.hasPrefix("/")
                    ? URL(fileURLWithPath: sourcePath)
                    : rootURL.appendingPathComponent(sourcePath)
            )
        }
        if !relativePath.isEmpty {
            candidates.append(rootURL.appendingPathComponent(relativePath))
        }

        let safeCandidates = candidates
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { candidate in
                allowedRoots.contains { allowedRoot in
                    candidate.path.hasPrefix(allowedRoot.path + "/")
                }
            }

        if let existing = safeCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return existing
        }
        if let safeCandidate = safeCandidates.first {
            return safeCandidate
        }

        throw SessionDeletionError.unsafeSourcePath(
            sourcePath.isEmpty ? relativePath : sourcePath
        )
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
        let effort = sqlite3_column_type(stmt, 9) != SQLITE_NULL && sqlite3_column_text(stmt, 9) != nil
            ? String(cString: sqlite3_column_text(stmt, 9)!) : nil
        let inTok = sqlite3_column_int64(stmt, 10)
        let cachedTok = sqlite3_column_int64(stmt, 11)
        let outTok = sqlite3_column_int64(stmt, 12)
        let reasonTok = sqlite3_column_int64(stmt, 13)
        let totTok = sqlite3_column_int64(stmt, 14)
        let costNano = sqlite3_column_int64(stmt, 15)
        let ruleId = sqlite3_column_type(stmt, 16) != SQLITE_NULL && sqlite3_column_text(stmt, 16) != nil
            ? String(cString: sqlite3_column_text(stmt, 16)!) : nil
        let pStatus = String(cString: sqlite3_column_text(stmt, 17))
        let deriv = String(cString: sqlite3_column_text(stmt, 18))
        let attrib = String(cString: sqlite3_column_text(stmt, 19))
        let isReplay = sqlite3_column_int(stmt, 20) != 0
        let src = String(cString: sqlite3_column_text(stmt, 21))
        let offset = sqlite3_column_int64(stmt, 22)
        let timestampQualityRaw = sqlite3_column_type(stmt, 23) != SQLITE_NULL && sqlite3_column_text(stmt, 23) != nil
            ? String(cString: sqlite3_column_text(stmt, 23)!)
            : TimestampQuality.eventTimestamp.rawValue
        let catalogVersion = sqlite3_column_type(stmt, 24) != SQLITE_NULL && sqlite3_column_text(stmt, 24) != nil
            ? String(cString: sqlite3_column_text(stmt, 24)!)
            : nil

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
            reasoningEffort: effort,
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
            pricingCatalogVersion: catalogVersion,
            usageDerivation: UsageDerivation(rawValue: deriv) ?? .explicitLastUsage,
            attributionQuality: AttributionQuality(rawValue: attrib) ?? .sessionFallback,
            timestampQuality: TimestampQuality(rawValue: timestampQualityRaw) ?? .eventTimestamp,
            isChildReplay: isReplay,
            sourcePath: src,
            lineOffset: offset
        )
    }
}
