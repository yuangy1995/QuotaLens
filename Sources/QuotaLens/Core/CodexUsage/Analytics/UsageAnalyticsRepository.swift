// QuotaLens 用量分析查询仓储 (UsageAnalyticsRepository)
// 高性能 SQLite 只读参数化查询、Keyset 分页、日桶聚合、模型分布与画像统计

import Foundation
import CryptoKit
import SQLite3

public enum SessionDeletionError: LocalizedError, Sendable {
    case sessionNotFound
    case unsafeSourcePath(String)
    case sourceIsNotRegularFile(String)
    case sourceUnavailable(String)
    case trashDestinationUnavailable(String)
    case rollbackFailed(String)
    case recoveryBlocked(String)
    case unsafeDeletionJournal(String)

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            return L10n.text("该会话已不存在。", "The session no longer exists.")
        case .unsafeSourcePath:
            return L10n.text(
                "无法删除：这条记录的位置不在 QuotaLens 可安全管理的范围内。",
                "Cannot delete this item because it is outside the location QuotaLens can safely manage."
            )
        case .sourceIsNotRegularFile:
            return L10n.text(
                "无法删除：这条记录对应的位置不是可安全移动的文件。",
                "Cannot delete this item because its source is not a file QuotaLens can safely move."
            )
        case .sourceUnavailable:
            return L10n.text(
                "无法删除：这条记录暂时无法读取。请检查权限后重试。",
                "Cannot delete this item because the record cannot be read right now. Check permissions and try again."
            )
        case .trashDestinationUnavailable:
            return L10n.text(
                "删除未完成：系统没有确认文件可恢复的位置，QuotaLens 已停止继续删除。",
                "Deletion did not finish because the system did not confirm a recoverable location. QuotaLens stopped before continuing."
            )
        case .rollbackFailed:
            return L10n.text(
                "删除未完成，部分文件需要先恢复或确认。处理前，本地用量更新会暂停。",
                "Deletion did not finish. Some files need to be restored or confirmed before local usage updates can continue."
            )
        case .recoveryBlocked:
            return L10n.text(
                "上一次删除尚未完全处理；为避免数据不一致，本地用量更新已暂停。",
                "A previous deletion is not fully resolved. Local usage updates are paused to avoid inconsistent data."
            )
        case .unsafeDeletionJournal:
            return L10n.text(
                "删除恢复信息未通过安全检查；QuotaLens 已停止自动恢复。",
                "Deletion recovery information did not pass safety checks. QuotaLens stopped automatic recovery."
            )
        }
    }
}

public enum MissingSourceCleanupError: LocalizedError, Sendable {
    case stalePreview

    public var errorDescription: String? {
        switch self {
        case .stalePreview:
            return L10n.text(
                "记录检查结果已过期；请重新预览后再确认清理。",
                "The record check is out of date. Preview again before cleaning."
            )
        }
    }
}

public final class UsageAnalyticsRepository: Sendable {
    private let database: SQLiteDatabase
    private let trashSourceFile: @Sendable (URL) throws -> URL
    private let stageSourceFile: @Sendable (URL, URL) throws -> Void
    private let deletionStagingRootProvider: @Sendable () throws -> URL
    private let trustedDeletionStagingBaseRoots: [URL]
    private let trustedDeletionStagingOperationRoots: [URL]
    private typealias DayAggregate = (
        tokens: TokenBreakdown,
        cost: MoneyNanoUSD,
        eventCount: Int,
        sessions: Set<String>,
        models: [String: (tokens: TokenBreakdown, cost: MoneyNanoUSD, count: Int, reasons: UnpricedReasonCounts, provenance: SummaryProvenance)],
        unpriced: Int,
        unpricedTokens: Int64,
        reasons: UnpricedReasonCounts,
        legacyTokens: Int64,
        legacyCost: MoneyNanoUSD,
        legacyEvents: Int
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
        let unpricedReasonCounts: UnpricedReasonCounts
        let summaryProvenance: SummaryProvenance
    }

    public init(
        database: SQLiteDatabase,
        trashSourceFile: @escaping @Sendable (URL) throws -> URL = { sourceURL in
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: sourceURL, resultingItemURL: &resultingURL)
            guard let resultingURL else {
                throw SessionDeletionError.trashDestinationUnavailable(sourceURL.path)
            }
            return resultingURL as URL
        },
        stageSourceFile: @escaping @Sendable (URL, URL) throws -> Void = { sourceURL, stagingURL in
            try FileManager.default.moveItem(at: sourceURL, to: stagingURL)
        },
        deletionStagingRootProvider: (@Sendable () throws -> URL)? = nil,
        trustedDeletionStagingBaseRoots: [URL]? = nil,
        trustedDeletionStagingOperationRoots: [URL] = []
    ) {
        self.database = database
        self.trashSourceFile = trashSourceFile
        self.stageSourceFile = stageSourceFile
        self.deletionStagingRootProvider = deletionStagingRootProvider ?? UsageAnalyticsRepository.makeDeletionStagingDirectory
        self.trustedDeletionStagingBaseRoots = (trustedDeletionStagingBaseRoots ?? [UsageAnalyticsRepository.defaultDeletionStagingBaseDirectory()])
            .map(UsageAnalyticsRepository.canonicalFileURL)
        self.trustedDeletionStagingOperationRoots = trustedDeletionStagingOperationRoots
            .map(UsageAnalyticsRepository.canonicalFileURL)
    }

    // MARK: - 1. 会话列表查询 (支持 Keyset 分页、项目过滤与搜索)
    public func fetchProjectNames(providerFilter: UsageProviderFilter = .all) throws -> [String] {
        let provider = Self.providerPredicate(providerFilter)
        let sql = """
        SELECT DISTINCT project_name
        FROM codex_sessions
        WHERE project_name IS NOT NULL AND TRIM(project_name) != ''\(provider.sql)
        ORDER BY project_name COLLATE NOCASE ASC;
        """
        return try database.executeQuery(sql: sql, bindings: provider.bindings) { stmt in
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
        cursor: String? = nil,
        providerFilter: UsageProviderFilter = .all
    ) throws -> [CodexSessionDTO] {
        try fetchSessionPage(sort: sort, search: search, project: project, limit: limit, cursor: cursor, providerFilter: providerFilter).sessions
    }

    public func fetchSessionPage(
        sort: SessionSort = .lastActivityDesc,
        search: String? = nil,
        project: String? = nil,
        limit: Int = 50,
        cursor: String? = nil,
        providerFilter: UsageProviderFilter = .all
    ) throws -> CodexSessionPageDTO {
        let requestedLimit = min(max(1, limit), 500)
        if let query = search?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            return try fetchConversationSearchPage(
                query: query,
                sort: sort,
                project: project,
                limit: requestedLimit,
                cursor: cursor,
                providerFilter: providerFilter
            )
        }

        var conditions: [String] = []
        var bindings: [Any?] = []

        // 只查询主会话（或顶层会话），深度为 0
        conditions.append("(depth = 0 OR parent_session_id IS NULL)")
        if let provider = providerFilter.provider {
            conditions.append("provider = ?")
            bindings.append(provider.rawValue)
        }

        if let project = project?.trimmingCharacters(in: .whitespacesAndNewlines), !project.isEmpty {
            conditions.append("project_name = ?")
            bindings.append(project)
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
            cached_input_tokens, cache_write_input_tokens, output_tokens,
            reasoning_output_tokens, estimated_cost_usd_nano,
            pricing_status, bucket, has_subagents, agent_type,
            unpriced_unknown_model_event_count, unpriced_unknown_model_token_count,
            unpriced_unsupported_tier_event_count, unpriced_unsupported_tier_token_count,
            unpriced_historical_rule_missing_event_count, unpriced_historical_rule_missing_token_count,
            unpriced_unsupported_context_event_count, unpriced_unsupported_context_token_count,
            unpriced_invalid_record_event_count, unpriced_invalid_record_token_count,
            unpriced_overflow_event_count, unpriced_overflow_token_count,
            summary_provenance, provider
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

    private struct ConversationSearchCandidate {
        let session: CodexSessionDTO
        let sourcePath: String
        let modelNames: String
    }

    private func fetchConversationSearchPage(
        query: String,
        sort: SessionSort,
        project: String?,
        limit: Int,
        cursor: String?,
        providerFilter: UsageProviderFilter
    ) throws -> CodexSessionPageDTO {
        let candidates = try fetchConversationSearchCandidates(
            sort: sort,
            project: project,
            cursor: cursor,
            providerFilter: providerFilter
        )
        var matches: [CodexSessionDTO] = []
        matches.reserveCapacity(limit + 1)

        for candidate in candidates {
            try Task.checkCancellation()

            let metadataFields = [
                candidate.session.title,
                candidate.session.projectName,
                candidate.session.sessionId,
                candidate.session.cwd,
                candidate.session.agentType,
                candidate.modelNames
            ]
            let metadataMatches = metadataFields.compactMap { $0 }.contains {
                Self.localizedContains($0, query: query)
            }

            var contentMatches = false
            if !metadataMatches,
               candidate.session.provider == .codex,
               !candidate.sourcePath.isEmpty {
                do {
                    contentMatches = try CodexConversationReader.containsConversationText(
                        fileURL: URL(fileURLWithPath: candidate.sourcePath),
                        query: query
                    )
                } catch let cancellation as CancellationError {
                    throw cancellation
                } catch {
                    contentMatches = false
                }
            }

            if metadataMatches || contentMatches {
                matches.append(candidate.session)
                if matches.count > limit {
                    break
                }
            }
        }

        let hasMore = matches.count > limit
        let pageRows = Array(matches.prefix(limit))
        return CodexSessionPageDTO(
            sessions: pageRows,
            nextCursor: hasMore ? pageRows.last.map { Self.encodeCursor(session: $0, sort: sort) } : nil
        )
    }

    private func fetchConversationSearchCandidates(
        sort: SessionSort,
        project: String?,
        cursor: String?,
        providerFilter: UsageProviderFilter
    ) throws -> [ConversationSearchCandidate] {
        var conditions = ["(depth = 0 OR parent_session_id IS NULL)"]
        var bindings: [Any?] = []
        if let provider = providerFilter.provider {
            conditions.append("provider = ?")
            bindings.append(provider.rawValue)
        }

        if let project = project?.trimmingCharacters(in: .whitespacesAndNewlines), !project.isEmpty {
            conditions.append("project_name = ?")
            bindings.append(project)
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

        let orderClause: String
        switch sort {
        case .lastActivityDesc:
            orderClause = "COALESCE(last_event_at, updated_at) DESC, session_id DESC"
        case .totalTokensDesc:
            orderClause = "total_tokens DESC, session_id DESC"
        case .estimatedCostDesc:
            orderClause = "estimated_cost_usd_nano DESC, session_id DESC"
        case .createdDesc:
            orderClause = "created_at DESC, session_id DESC"
        }

        let sql = """
        SELECT
            session_id, root_session_id, parent_session_id, depth, title, project_name, cwd,
            created_at, updated_at, last_event_at, event_count, total_tokens, input_tokens,
            cached_input_tokens, cache_write_input_tokens, output_tokens,
            reasoning_output_tokens, estimated_cost_usd_nano,
            pricing_status, bucket, has_subagents, agent_type,
            unpriced_unknown_model_event_count, unpriced_unknown_model_token_count,
            unpriced_unsupported_tier_event_count, unpriced_unsupported_tier_token_count,
            unpriced_historical_rule_missing_event_count, unpriced_historical_rule_missing_token_count,
            unpriced_unsupported_context_event_count, unpriced_unsupported_context_token_count,
            unpriced_invalid_record_event_count, unpriced_invalid_record_token_count,
            unpriced_overflow_event_count, unpriced_overflow_token_count,
            summary_provenance, provider, source_path, relative_path,
            COALESCE((
                SELECT GROUP_CONCAT(model_canonical, ' ')
                FROM codex_session_summaries summary
                WHERE summary.session_id = codex_sessions.session_id
            ), '')
        FROM codex_sessions
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY \(orderClause);
        """

        return try database.executeQuery(sql: sql, bindings: bindings) { statement in
            let session = Self.mapSessionRow(statement)
            let storedSource = Self.stringColumn(statement, index: 36) ?? ""
            let relativePath = Self.stringColumn(statement, index: 37) ?? ""
            let preferredSource = storedSource.isEmpty ? relativePath : storedSource
            return ConversationSearchCandidate(
                session: session,
                sourcePath: Self.absoluteSourcePath(preferredSource),
                modelNames: Self.stringColumn(statement, index: 38) ?? ""
            )
        }
    }

    // MARK: - 2. 会话完整详情查询
    public func fetchSessionDetail(
        sessionId: String,
        eventLimit: Int = 500,
        eventCursor: String? = nil
    ) throws -> CodexSessionDetailDTO? {
        // 主会话
        let mainSessionSql = """
        SELECT
            session_id, root_session_id, parent_session_id, depth, title, project_name, cwd,
            created_at, updated_at, last_event_at, event_count, total_tokens, input_tokens,
            cached_input_tokens, cache_write_input_tokens, output_tokens,
            reasoning_output_tokens, estimated_cost_usd_nano,
            pricing_status, bucket, has_subagents, agent_type,
            unpriced_unknown_model_event_count, unpriced_unknown_model_token_count,
            unpriced_unsupported_tier_event_count, unpriced_unsupported_tier_token_count,
            unpriced_historical_rule_missing_event_count, unpriced_historical_rule_missing_token_count,
            unpriced_unsupported_context_event_count, unpriced_unsupported_context_token_count,
            unpriced_invalid_record_event_count, unpriced_invalid_record_token_count,
            unpriced_overflow_event_count, unpriced_overflow_token_count,
            summary_provenance, provider
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
            cached_input_tokens, cache_write_input_tokens, output_tokens,
            reasoning_output_tokens, estimated_cost_usd_nano,
            pricing_status, bucket, has_subagents, agent_type,
            unpriced_unknown_model_event_count, unpriced_unknown_model_token_count,
            unpriced_unsupported_tier_event_count, unpriced_unsupported_tier_token_count,
            unpriced_historical_rule_missing_event_count, unpriced_historical_rule_missing_token_count,
            unpriced_unsupported_context_event_count, unpriced_unsupported_context_token_count,
            unpriced_invalid_record_event_count, unpriced_invalid_record_token_count,
            unpriced_overflow_event_count, unpriced_overflow_token_count,
            summary_provenance, provider
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
            SUM(cache_write_input_tokens),
            SUM(output_tokens),
            SUM(reasoning_output_tokens),
            SUM(total_tokens),
            SUM(estimated_cost_usd_nano),
            SUM(event_count),
            SUM(unpriced_event_count),
            SUM(unpriced_unknown_model_event_count),
            SUM(unpriced_unknown_model_token_count),
            SUM(unpriced_unsupported_tier_event_count),
            SUM(unpriced_unsupported_tier_token_count),
            SUM(unpriced_historical_rule_missing_event_count),
            SUM(unpriced_historical_rule_missing_token_count),
            SUM(unpriced_unsupported_context_event_count),
            SUM(unpriced_unsupported_context_token_count),
            SUM(unpriced_invalid_record_event_count),
            SUM(unpriced_invalid_record_token_count),
            SUM(unpriced_overflow_event_count),
            SUM(unpriced_overflow_token_count),
            CASE
                WHEN SUM(CASE WHEN summary_provenance = 'legacyAggregate' THEN event_count ELSE 0 END) = SUM(event_count)
                    THEN 'legacyAggregate'
                WHEN SUM(CASE WHEN summary_provenance = 'reconstructed' THEN event_count ELSE 0 END) > 0
                    THEN 'reconstructed'
                ELSE 'eventLedger'
            END
        FROM codex_session_summaries
        WHERE session_id = ?
        GROUP BY model_canonical
        ORDER BY SUM(total_tokens) DESC;
        """
        let modelSummaries = try database.executeQuery(sql: modelSummariesSql, bindings: [sessionId]) { stmt -> ModelUsageSummaryDTO in
            let model = String(cString: sqlite3_column_text(stmt, 0))
            let uncachedTokens = sqlite3_column_int64(stmt, 1)
            let cachedTokens = sqlite3_column_int64(stmt, 2)
            let cacheWriteTokens = sqlite3_column_int64(stmt, 3)
            let tokens = TokenBreakdown(
                inputTokens: uncachedTokens + cachedTokens + cacheWriteTokens,
                cachedInputTokens: cachedTokens,
                cacheWriteInputTokens: cacheWriteTokens,
                outputTokens: sqlite3_column_int64(stmt, 4),
                reasoningOutputTokens: sqlite3_column_int64(stmt, 5),
                sourceTotalTokens: sqlite3_column_int64(stmt, 6)
            )
            let cost = MoneyNanoUSD(sqlite3_column_int64(stmt, 7))
            let eventCount = Int(sqlite3_column_int(stmt, 8))
            let unpriced = Int(sqlite3_column_int(stmt, 9))
            return ModelUsageSummaryDTO(
                modelCanonical: model,
                tokens: tokens,
                estimatedCost: cost,
                eventCount: eventCount,
                unpricedCount: unpriced,
                unpricedReasonCounts: Self.unpricedReasonCounts(from: stmt, start: 10),
                summaryProvenance: SummaryProvenance(
                    storedValue: sqlite3_column_type(stmt, 22) != SQLITE_NULL
                        && sqlite3_column_text(stmt, 22) != nil
                        ? String(cString: sqlite3_column_text(stmt, 22)!)
                        : nil
                )
            )
        }

        var totalSubagentTokens = TokenBreakdown.zero
        var totalSubagentCost = MoneyNanoUSD.zero
        for sub in subagents {
            totalSubagentTokens = totalSubagentTokens + sub.tokens
            totalSubagentCost = totalSubagentCost + sub.estimatedCost
        }

        let eventPage = try fetchSessionEventPage(
            sessionId: sessionId,
            limit: eventLimit,
            cursor: eventCursor
        )

        let preferredSourcePath = {
            guard let sourceInfo else { return "" }
            return sourceInfo.0.isEmpty ? sourceInfo.1 : sourceInfo.0
        }()

        return CodexSessionDetailDTO(
            session: mainSession,
            subagents: subagents,
            modelSummaries: modelSummaries,
            recentEvents: eventPage.events,
            totalEventCount: eventPage.totalEventCount,
            loadedEventCount: eventPage.loadedEventCount,
            hasMoreEvents: eventPage.hasMore,
            nextEventCursor: eventPage.nextCursor,
            sourcePath: Self.absoluteSourcePath(preferredSourcePath),
            relativePath: sourceInfo?.1 ?? "",
            totalSubagentTokens: totalSubagentTokens,
            totalSubagentCost: totalSubagentCost
        )
    }

    public func fetchSessionConversation(sessionId: String) throws -> CodexSessionConversationDTO? {
        let rows = try database.executeQuery(
            sql: "SELECT source_path, relative_path, provider FROM codex_sessions WHERE session_id = ? LIMIT 1;",
            bindings: [sessionId]
        ) { statement in
            (
                Self.stringColumn(statement, index: 0) ?? "",
                Self.stringColumn(statement, index: 1) ?? "",
                Self.stringColumn(statement, index: 2) ?? UsageProvider.codex.rawValue
            )
        }
        guard let source = rows.first else { return nil }
        guard source.2 == UsageProvider.codex.rawValue else {
            return CodexSessionConversationDTO(sessionId: sessionId, messages: [])
        }

        let preferredSource = source.0.isEmpty ? source.1 : source.0
        let sourcePath = Self.absoluteSourcePath(preferredSource)
        guard !sourcePath.isEmpty else {
            return CodexSessionConversationDTO(sessionId: sessionId, messages: [])
        }

        return try CodexConversationReader.readConversation(
            fileURL: URL(fileURLWithPath: sourcePath),
            sessionId: sessionId
        )
    }

    public func fetchSessionEventPage(
        sessionId: String,
        limit: Int = 500,
        cursor: String? = nil
    ) throws -> CodexUsageEventPageDTO {
        try fetchEventPage(
            whereClause: "session_id = ? AND is_child_replay = 0",
            bindings: [sessionId],
            limit: limit,
            cursor: cursor
        )
    }

    /// 删除会话树前先持久化 journal；提交前的唯一回滚依据始终保留在 staging_path。
    public func deleteSession(sessionId: String, historyRootURL: URL? = nil) throws {
        struct SourceRecord {
            let sessionId: String
            let sourcePath: String
            let relativePath: String
            let bucket: SessionBucket
        }

        struct DeletionSource {
            let record: SourceRecord
            let originalURL: URL
            let stagingURL: URL
            let trashCandidateURL: URL
        }

        let provider = try database.stringScalar(
            sql: "SELECT provider FROM codex_sessions WHERE session_id = ? LIMIT 1;",
            bindings: [sessionId]
        )
        guard provider == nil || provider == UsageProvider.codex.rawValue else {
            throw SessionDeletionError.unsafeSourcePath("Claude")
        }
        try assertNoIncompleteSessionDeletionJournal(historyRootURL: historyRootURL)

        let records = try database.executeQuery(
            sql: """
            SELECT session_id, source_path, relative_path, bucket
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
                relativePath: String(cString: sqlite3_column_text(statement, 2)),
                bucket: SessionBucket(
                    rawValue: sqlite3_column_type(statement, 3) != SQLITE_NULL
                        && sqlite3_column_text(statement, 3) != nil
                        ? String(cString: sqlite3_column_text(statement, 3)!)
                        : SessionBucket.active.rawValue
                ) ?? .active
            )
        }

        guard !records.isEmpty else {
            throw SessionDeletionError.sessionNotFound
        }

        let historyPaths = CodexHistoryPaths(
            rootURL: historyRootURL ?? CodexHistoryRootResolver.resolveRootURL()
        )
        var sourceRecordsByPath: [String: (SourceRecord, URL)] = [:]
        for record in records {
            let sourceURL = try Self.safeSessionSourceURL(
                sourcePath: record.sourcePath,
                relativePath: record.relativePath,
                historyPaths: historyPaths
            )
            sourceRecordsByPath[sourceURL.path] = (record, sourceURL)
        }

        let fileManager = FileManager.default
        let sortedSources = sourceRecordsByPath.values.sorted(by: { $0.1.path < $1.1.path })
        var initiallyMissingSourcePaths = Set<String>()
        for (_, sourceURL) in sortedSources {
            switch Self.filePresence(at: sourceURL) {
            case .missing:
                initiallyMissingSourcePaths.insert(sourceURL.path)
                continue
            case .inaccessible:
                throw SessionDeletionError.sourceUnavailable(sourceURL.path)
            case .exists:
                break
            }
            let values: URLResourceValues
            do {
                values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey])
            } catch {
                throw SessionDeletionError.sourceUnavailable(sourceURL.path)
            }
            guard values.isRegularFile == true else {
                throw SessionDeletionError.sourceIsNotRegularFile(sourceURL.path)
            }
        }

        let sessionIDs = Set(records.map(\.sessionId))
        let sourceKeys = Set(records.map { "\($0.sourcePath)\u{1F}\($0.relativePath)" })
        let rootSessionId = try database.stringScalar(
            sql: "SELECT root_session_id FROM codex_sessions WHERE session_id = ?;",
            bindings: [sessionId]
        ) ?? sessionId
        let deletionId = UUID().uuidString
        let stagingRoot = try deletionStagingRootProvider()
        guard Self.isSafeDeletionStagingRoot(
            stagingRoot,
            historyRoot: historyPaths.rootURL,
            trustedBaseRoots: trustedDeletionStagingBaseRoots,
            trustedOperationRoots: trustedDeletionStagingOperationRoots
        ) else {
            throw SessionDeletionError.unsafeDeletionJournal("unsafe staging root")
        }
        let deletionSources: [DeletionSource] = sortedSources.enumerated().map { index, item in
            let (record, url) = item
            let stagingURL = stagingRoot
                .appendingPathComponent(String(index), isDirectory: true)
                .appendingPathComponent(url.lastPathComponent)
            let trashCandidateURL = stagingRoot
                .appendingPathComponent("trash-\(index)", isDirectory: true)
                .appendingPathComponent(url.lastPathComponent)
            return DeletionSource(
                record: record,
                originalURL: url,
                stagingURL: stagingURL,
                trashCandidateURL: trashCandidateURL
            )
        }
        try createDeletionJournal(
            deletionId: deletionId,
            requestedSessionId: sessionId,
            rootSessionId: rootSessionId,
            historyRoot: historyPaths.rootURL,
            stagingRoot: stagingRoot,
            sources: deletionSources.map { item in
                return (
                    sessionId: item.record.sessionId,
                    sourcePath: item.record.sourcePath,
                    relativePath: item.record.relativePath,
                    bucket: item.record.bucket,
                    originalURL: item.originalURL,
                    stagingURL: item.stagingURL,
                    initialState: initiallyMissingSourcePaths.contains(item.originalURL.path)
                        ? "missingBeforeDelete"
                        : "prepared"
                )
            }
        )

        func rollbackAndThrow(_ error: Error) throws {
            guard let rollbackFailures = try? rollbackDeletionFiles(
                deletionId: deletionId,
                allowRecordedRecoveryCleanup: true
            ) else {
                try? markDeletionRollbackRequired(deletionId: deletionId, failures: [error.localizedDescription])
                throw SessionDeletionError.rollbackFailed("recovery information could not be read")
            }
            if !rollbackFailures.isEmpty {
                try? markDeletionRollbackRequired(deletionId: deletionId, failures: rollbackFailures)
                throw SessionDeletionError.rollbackFailed(rollbackFailures.joined(separator: "; "))
            }
            try? fileManager.removeItem(at: stagingRoot)
            try? updateDeletionJournalStatus(deletionId: deletionId, status: "finalized", error: error.localizedDescription)
            throw error
        }

        do {
            for item in deletionSources {
                switch Self.filePresence(at: item.originalURL) {
                case .missing:
                    if !initiallyMissingSourcePaths.contains(item.originalURL.path) {
                        try updateDeletionFileState(
                            deletionId: deletionId,
                            originalPath: item.originalURL.path,
                            state: "missingBeforeDelete",
                            stagingPath: item.stagingURL.path,
                            recoveryPath: nil
                        )
                    }
                    continue
                case .inaccessible:
                    throw SessionDeletionError.sourceUnavailable(item.originalURL.path)
                case .exists:
                    break
                }
                try fileManager.createDirectory(
                    at: item.stagingURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try stageSourceFile(item.originalURL, item.stagingURL)
                try updateDeletionFileState(
                    deletionId: deletionId,
                    originalPath: item.originalURL.path,
                    state: "staged",
                    stagingPath: item.stagingURL.path,
                    recoveryPath: nil
                )
            }
            try updateDeletionJournalStatus(deletionId: deletionId, status: "staged")
            for item in deletionSources where fileManager.fileExists(atPath: item.stagingURL.path) {
                try fileManager.createDirectory(
                    at: item.trashCandidateURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: item.trashCandidateURL.path) {
                    try fileManager.removeItem(at: item.trashCandidateURL)
                }
                // Trash 操作可能在返回恢复 URL 前崩溃；因此只移动 staging 的副本。
                try fileManager.copyItem(at: item.stagingURL, to: item.trashCandidateURL)
                try updateDeletionFileState(
                    deletionId: deletionId,
                    originalPath: item.originalURL.path,
                    state: "trashPrepared",
                    stagingPath: item.stagingURL.path,
                    recoveryPath: nil
                )
                let trashURL = try trashSourceFile(item.trashCandidateURL)
                try updateDeletionFileState(
                    deletionId: deletionId,
                    originalPath: item.originalURL.path,
                    state: "trashed",
                    stagingPath: item.stagingURL.path,
                    recoveryPath: trashURL.path
                )
            }
            try updateDeletionJournalStatus(deletionId: deletionId, status: "trashed")
        } catch {
            try rollbackAndThrow(error)
        }

        do {
            try database.transaction {
                try deleteSessionDerivedRows(sessionIDs: sessionIDs, sourceKeys: sourceKeys)
                try updateDeletionJournalStatusInTransaction(
                    deletionId: deletionId,
                    status: "databaseCommitted"
                )
            }
        } catch {
            try rollbackAndThrow(error)
        }

        var finalized = false
        do {
            if fileManager.fileExists(atPath: stagingRoot.path) {
                try fileManager.removeItem(at: stagingRoot)
            }
            try updateDeletionJournalStatus(deletionId: deletionId, status: "finalized")
            finalized = true
            try PricingCatalogService.shared.refreshPricingMigrationState(database: database)
        } catch {
            if !finalized {
                try? updateDeletionJournalStatus(
                    deletionId: deletionId,
                    status: "databaseCommitted",
                    error: error.localizedDescription
                )
            }
            throw error
        }
    }

    public func previewMissingSourceCleanup(
        historyRootURL: URL? = nil
    ) throws -> MissingSourceCleanupPreviewDTO {
        try assertNoIncompleteSessionDeletionJournal(historyRootURL: historyRootURL)
        let items = try missingSourceCleanupItems(historyRootURL: historyRootURL)
        let totalSessions = items.reduce(0) { $0 + $1.sessionCount }
        let totalTokens = items.reduce(Int64(0)) { $0 + $1.totalTokens }
        let totalCost = items.reduce(MoneyNanoUSD.zero) { $0 + $1.estimatedCost }
        return MissingSourceCleanupPreviewDTO(
            previewId: Self.missingSourcePreviewId(items: items),
            items: items,
            totalSessions: totalSessions,
            totalTokens: totalTokens,
            estimatedCost: totalCost
        )
    }

    public func cleanupMissingSourceIndexes(
        previewId: String,
        historyRootURL: URL? = nil
    ) throws -> MissingSourceCleanupResultDTO {
        let preview = try previewMissingSourceCleanup(historyRootURL: historyRootURL)
        guard preview.previewId == previewId else {
            throw MissingSourceCleanupError.stalePreview
        }

        try database.transaction {
            try assertNoIncompleteSessionDeletionJournal(historyRootURL: historyRootURL)
            for item in preview.items {
                try deleteDerivedRowsForSource(
                    sourcePath: item.sourcePath,
                    relativePath: item.relativePath
                )
                try database.executeUpdate(
                    sql: """
                    UPDATE codex_import_sources
                    SET status = 'tombstoned',
                        error_message = 'missing source index explicitly cleaned',
                        scan_generation = COALESCE((SELECT CAST(value AS INTEGER) FROM app_metadata WHERE key = 'codex_usage_scan_generation'), scan_generation)
                    WHERE source_path = ? OR relative_path = ?;
                    """,
                    bindings: [item.sourcePath, item.relativePath]
                )
            }
        }
        try PricingCatalogService.shared.refreshPricingMigrationState(database: database)

        return MissingSourceCleanupResultDTO(
            sourcesRemoved: preview.items.count,
            sessionsRemoved: preview.totalSessions,
            tokensRemoved: preview.totalTokens,
            estimatedCostRemoved: preview.estimatedCost
        )
    }

    public func assertNoIncompleteSessionDeletionJournal(
        historyRootURL: URL? = nil
    ) throws {
        let rows = try database.executeQuery(
            sql: """
            SELECT deletion_id, status, history_root_path
            FROM codex_session_deletion_journal
            WHERE status != 'finalized'
            ORDER BY created_at ASC
            LIMIT 3;
            """
        ) { stmt -> (String, String, String) in
            (
                String(cString: sqlite3_column_text(stmt, 0)),
                String(cString: sqlite3_column_text(stmt, 1)),
                String(cString: sqlite3_column_text(stmt, 2))
            )
        }
        guard rows.isEmpty else {
            let details = rows
                .map { "\($0.0):\($0.1)" }
                .joined(separator: ", ")
            throw SessionDeletionError.recoveryBlocked(details)
        }
        _ = historyRootURL
    }

    public func recoverIncompleteSessionDeletions(
        historyRootURL: URL? = nil
    ) throws -> SessionDeletionRecoverySummary {
        let rows = try database.executeQuery(
            sql: """
            SELECT deletion_id, status, staging_root_path, history_root_path
            FROM codex_session_deletion_journal
            WHERE status != 'finalized'
            ORDER BY created_at ASC;
            """
        ) { stmt -> (String, String, String, String) in
            (
                String(cString: sqlite3_column_text(stmt, 0)),
                String(cString: sqlite3_column_text(stmt, 1)),
                String(cString: sqlite3_column_text(stmt, 2)),
                String(cString: sqlite3_column_text(stmt, 3))
            )
        }
        guard !rows.isEmpty else {
            return SessionDeletionRecoverySummary()
        }

        var finalized = 0
        var rolledBack = 0
        var rollbackRequired = 0
        for row in rows {
            if row.1 == "rollbackRequired" {
                rollbackRequired += 1
                continue
            }

            let safetyFailures = try validateDeletionJournalSafety(
                deletionId: row.0,
                status: row.1,
                historyRootPath: row.3,
                stagingRootPath: row.2,
                historyRootURL: historyRootURL
            )
            if !safetyFailures.isEmpty {
                try markDeletionRollbackRequired(deletionId: row.0, failures: safetyFailures)
                rollbackRequired += 1
                continue
            }

            if row.1 == "databaseCommitted" {
                if FileManager.default.fileExists(atPath: row.2) {
                    try FileManager.default.removeItem(atPath: row.2)
                }
                try updateDeletionJournalStatus(
                    deletionId: row.0,
                    status: "finalized"
                )
                finalized += 1
                continue
            }

            let failures = try rollbackDeletionFiles(deletionId: row.0)
            if failures.isEmpty {
                if FileManager.default.fileExists(atPath: row.2) {
                    try FileManager.default.removeItem(atPath: row.2)
                }
                try updateDeletionJournalStatus(
                    deletionId: row.0,
                    status: "finalized",
                    error: "rolled back incomplete deletion"
                )
                rolledBack += 1
            } else {
                try markDeletionRollbackRequired(
                    deletionId: row.0,
                    failures: failures
                )
                rollbackRequired += 1
            }
        }
        try PricingCatalogService.shared.refreshPricingMigrationState(database: database)
        let message = rollbackRequired > 0
            ? L10n.format(
                "%d deletion(s) need attention before local usage updates can continue.",
                zhHans: "%d 个删除操作需要处理后才能继续本地用量更新。",
                rollbackRequired
            )
            : L10n.format(
                "Resolved %d interrupted deletion(s).",
                zhHans: "已处理 %d 个中断的删除操作。",
                rolledBack + finalized
            )
        return SessionDeletionRecoverySummary(
            finalizedCount: finalized,
            rolledBackCount: rolledBack,
            rollbackRequiredCount: rollbackRequired,
            message: message
        )
    }

    // MARK: - 3. 每日用量汇总 (History 列表)
    public func fetchHistoryDays(
        daysCount: Int = 30,
        calendar: Calendar = UsageDayBucketer.calendar(),
        now: Date = Date(),
        providerFilter: UsageProviderFilter = .all
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
            calendar: calendar,
            providerFilter: providerFilter
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
                unpricedTokens: 0,
                reasons: .zero,
                legacyTokens: 0,
                legacyCost: .zero,
                legacyEvents: 0
            )

            entry.tokens = entry.tokens + slice.tokens
            let isLegacy = slice.summaryProvenance == .legacyAggregate
            entry.cost = isLegacy ? entry.cost : entry.cost + slice.cost
            entry.eventCount += slice.eventCount
            entry.sessions.insert(slice.sessionId)
            entry.unpriced += isLegacy ? 0 : slice.unpricedCount
            entry.unpricedTokens += isLegacy ? 0 : slice.unpricedTokens
            entry.reasons = isLegacy ? entry.reasons : entry.reasons + slice.unpricedReasonCounts
            entry.legacyTokens += isLegacy ? slice.tokens.canonicalTotalTokens : 0
            entry.legacyCost = isLegacy ? entry.legacyCost + slice.cost : entry.legacyCost
            entry.legacyEvents += isLegacy ? slice.eventCount : 0

            var mEntry = entry.models[slice.model] ?? (tokens: .zero, cost: .zero, count: 0, reasons: .zero, provenance: .eventLedger)
            mEntry.tokens = mEntry.tokens + slice.tokens
            mEntry.cost = isLegacy ? mEntry.cost : mEntry.cost + slice.cost
            mEntry.count += slice.eventCount
            mEntry.reasons = isLegacy ? mEntry.reasons : mEntry.reasons + slice.unpricedReasonCounts
            mEntry.provenance = Self.combinedSummaryProvenance(mEntry.provenance, slice.summaryProvenance)
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
                unpricedTokens: 0,
                reasons: .zero,
                legacyTokens: 0,
                legacyCost: .zero,
                legacyEvents: 0
            )
            let modelSummaries = val.models.map { modelKey, mVal in
                ModelUsageSummaryDTO(
                    modelCanonical: modelKey,
                    tokens: mVal.tokens,
                    estimatedCost: mVal.cost,
                    eventCount: mVal.count,
                    unpricedCount: mVal.reasons.totalEvents,
                    unpricedReasonCounts: mVal.reasons,
                    summaryProvenance: mVal.provenance
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
                    unpricedTokenCount: val.unpricedTokens,
                    unpricedReasonCounts: val.reasons,
                    legacyAggregateTokens: val.legacyTokens,
                    legacyAggregateCost: val.legacyCost
                )
            )
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursorDate) else { break }
            cursorDate = next
        }

        return result.sorted { $0.dayKey > $1.dayKey }
    }

    public func fetchDayDetail(
        dayKey: LocalDayKey,
        calendar: Calendar = UsageDayBucketer.calendar(),
        eventLimit: Int = 500,
        eventCursor: String? = nil,
        providerFilter: UsageProviderFilter = .all
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
            let unpricedReasonCounts: UnpricedReasonCounts
            let legacyTokens: Int64
            let legacyCost: MoneyNanoUSD
        }

        let aggregateSlices = try fetchUsageAggregateSlices(
            rangeStart: startDate,
            endExclusive: endDate,
            calendar: calendar,
            providerFilter: providerFilter
        )
        var sessionAggregates: [String: (
            eventCount: Int,
            tokens: TokenBreakdown,
            cost: MoneyNanoUSD,
            unpricedCount: Int,
            unpricedTokens: Int64,
            reasons: UnpricedReasonCounts,
            legacyTokens: Int64,
            legacyCost: MoneyNanoUSD
        )] = [:]
        var modelAggregates: [String: (
            eventCount: Int,
            tokens: TokenBreakdown,
            cost: MoneyNanoUSD,
            unpricedCount: Int,
            reasons: UnpricedReasonCounts
        )] = [:]

        for aggregate in aggregateSlices {
            let isLegacy = aggregate.summaryProvenance == .legacyAggregate
            var session = sessionAggregates[aggregate.sessionId]
                ?? (0, .zero, .zero, 0, 0, .zero, 0, .zero)
            session.eventCount += aggregate.eventCount
            session.tokens = session.tokens + aggregate.tokens
            session.cost = isLegacy ? session.cost : session.cost + aggregate.cost
            session.unpricedCount += isLegacy ? 0 : aggregate.unpricedCount
            session.unpricedTokens += isLegacy ? 0 : aggregate.unpricedTokens
            session.reasons = isLegacy ? session.reasons : session.reasons + aggregate.unpricedReasonCounts
            session.legacyTokens += isLegacy ? aggregate.tokens.canonicalTotalTokens : 0
            session.legacyCost = isLegacy ? session.legacyCost + aggregate.cost : session.legacyCost
            sessionAggregates[aggregate.sessionId] = session

            var model = modelAggregates[aggregate.model]
                ?? (0, .zero, .zero, 0, .zero)
            model.eventCount += aggregate.eventCount
            model.tokens = model.tokens + aggregate.tokens
            model.cost = isLegacy ? model.cost : model.cost + aggregate.cost
            model.unpricedCount += isLegacy ? 0 : aggregate.unpricedCount
            model.reasons = isLegacy ? model.reasons : model.reasons + aggregate.unpricedReasonCounts
            modelAggregates[aggregate.model] = model
        }

        let sessionRows = sessionAggregates.map { sessionId, aggregate in
            SessionAggregateRow(
                sessionId: sessionId,
                eventCount: aggregate.eventCount,
                tokens: aggregate.tokens,
                cost: aggregate.cost,
                unpricedCount: aggregate.unpricedCount,
                unpricedTokenCount: aggregate.unpricedTokens,
                unpricedReasonCounts: aggregate.reasons,
                legacyTokens: aggregate.legacyTokens,
                legacyCost: aggregate.legacyCost
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
                unpricedCount: aggregate.unpricedCount,
                unpricedReasonCounts: aggregate.reasons
            )
        }.sorted { $0.tokens.canonicalTotalTokens > $1.tokens.canonicalTotalTokens }

        let eventProvider = Self.providerPredicate(providerFilter)
        let eventPage = try fetchEventPage(
            whereClause: "is_child_replay = 0 AND timestamp_ms >= ? AND timestamp_ms < ?\(eventProvider.sql)",
            bindings: [startMs, endMs] + eventProvider.bindings,
            limit: eventLimit,
            cursor: eventCursor
        )
        let eventsBySession = Dictionary(grouping: eventPage.events, by: \CodexUsageEventDTO.sessionId)

        var slices: [DaySessionSliceDTO] = []
        var totalTokens = TokenBreakdown.zero
        var totalCost = MoneyNanoUSD.zero
        var totalEvents = 0
        var totalUnpriced = 0
        var totalUnpricedTokens: Int64 = 0
        var totalUnpricedReasons = UnpricedReasonCounts.zero
        var legacyAggregateTokens: Int64 = 0
        var legacyAggregateCost = MoneyNanoUSD.zero

        let sessionsById = try fetchSessionsById(ids: sessionRows.map(\.sessionId))

        for row in sessionRows {
            totalTokens = totalTokens + row.tokens
            totalCost = totalCost + row.cost
            totalEvents += row.eventCount
            totalUnpriced += row.unpricedCount
            totalUnpricedTokens += row.unpricedTokenCount
            totalUnpricedReasons = totalUnpricedReasons + row.unpricedReasonCounts
            legacyAggregateTokens += row.legacyTokens
            legacyAggregateCost = legacyAggregateCost + row.legacyCost

            guard let session = sessionsById[row.sessionId] else { continue }
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
                unpricedTokenCount: totalUnpricedTokens,
                unpricedReasonCounts: totalUnpricedReasons,
                legacyAggregateTokens: legacyAggregateTokens,
                legacyAggregateCost: legacyAggregateCost
            ),
            sessions: slices,
            totalEventCount: eventPage.totalEventCount,
            loadedEventCount: eventPage.loadedEventCount,
            hasMoreEvents: eventPage.hasMore,
            nextEventCursor: eventPage.nextCursor
        )
    }

    // MARK: - 4. 仪表盘全局指标 (Dashboard)
    public func fetchDashboardMetrics(days: Int = 30, calendar: Calendar = UsageDayBucketer.calendar(), providerFilter: UsageProviderFilter = .all) throws -> DashboardMetricsDTO {
        let now = Date()
        let rangeSeconds = Double(max(1, days)) * 86_400.0
        let startDate = now.addingTimeInterval(-rangeSeconds)
        return try fetchDashboardMetrics(rangeStart: startDate, endExclusive: now, calendar: calendar, providerFilter: providerFilter)
    }

    public func fetchTodayMetrics(calendar: Calendar = UsageDayBucketer.calendar(), now: Date = Date(), providerFilter: UsageProviderFilter = .all) throws -> DashboardMetricsDTO {
        try fetchDashboardMetrics(
            rangeStart: calendar.startOfDay(for: now),
            endExclusive: now,
            calendar: calendar,
            providerFilter: providerFilter
        )
    }

    public func fetchDashboardMetrics(
        rangeStart startDate: Date,
        endExclusive endDate: Date,
        calendar: Calendar = UsageDayBucketer.calendar(),
        providerFilter: UsageProviderFilter = .all
    ) throws -> DashboardMetricsDTO {
        let slices = try fetchUsageAggregateSlices(
            rangeStart: startDate,
            endExclusive: endDate,
            calendar: calendar,
            providerFilter: providerFilter
        )

        var totalTokens = TokenBreakdown.zero
        var totalCost = MoneyNanoUSD.zero
        var totalEvents = 0
        var modelsAgg: [String: (tokens: TokenBreakdown, cost: MoneyNanoUSD, count: Int, unpriced: Int, reasons: UnpricedReasonCounts, provenance: SummaryProvenance)] = [:]
        var unpricedTotal = 0
        var unpricedTokenTotal: Int64 = 0
        var unpricedReasons = UnpricedReasonCounts.zero
        var sessions = Set<String>()
        var daysMap: [LocalDayKey: DayAggregate] = [:]
        var legacyAggregateTokens: Int64 = 0
        var legacyAggregateCost = MoneyNanoUSD.zero
        var legacyAggregateEvents = 0

        for slice in slices {
            let isLegacy = slice.summaryProvenance == .legacyAggregate
            totalTokens = totalTokens + slice.tokens
            totalCost = isLegacy ? totalCost : totalCost + slice.cost
            totalEvents += slice.eventCount
            sessions.insert(slice.sessionId)
            unpricedTotal += isLegacy ? 0 : slice.unpricedCount
            unpricedTokenTotal += isLegacy ? 0 : slice.unpricedTokens
            unpricedReasons = isLegacy ? unpricedReasons : unpricedReasons + slice.unpricedReasonCounts
            legacyAggregateTokens += isLegacy ? slice.tokens.canonicalTotalTokens : 0
            legacyAggregateCost = isLegacy ? legacyAggregateCost + slice.cost : legacyAggregateCost
            legacyAggregateEvents += isLegacy ? slice.eventCount : 0

            var modelEntry = modelsAgg[slice.model] ?? (tokens: .zero, cost: .zero, count: 0, unpriced: 0, reasons: .zero, provenance: .eventLedger)
            modelEntry.tokens = modelEntry.tokens + slice.tokens
            modelEntry.cost = isLegacy ? modelEntry.cost : modelEntry.cost + slice.cost
            modelEntry.count += slice.eventCount
            modelEntry.unpriced += isLegacy ? 0 : slice.unpricedCount
            modelEntry.reasons = isLegacy ? modelEntry.reasons : modelEntry.reasons + slice.unpricedReasonCounts
            modelEntry.provenance = Self.combinedSummaryProvenance(modelEntry.provenance, slice.summaryProvenance)
            modelsAgg[slice.model] = modelEntry

            var dayEntry = daysMap[slice.dayKey] ?? (
                tokens: .zero,
                cost: .zero,
                eventCount: 0,
                sessions: [],
                models: [:],
                unpriced: 0,
                unpricedTokens: 0,
                reasons: .zero,
                legacyTokens: 0,
                legacyCost: .zero,
                legacyEvents: 0
            )
            dayEntry.tokens = dayEntry.tokens + slice.tokens
            dayEntry.cost = isLegacy ? dayEntry.cost : dayEntry.cost + slice.cost
            dayEntry.eventCount += slice.eventCount
            dayEntry.sessions.insert(slice.sessionId)
            dayEntry.unpriced += isLegacy ? 0 : slice.unpricedCount
            dayEntry.unpricedTokens += isLegacy ? 0 : slice.unpricedTokens
            dayEntry.reasons = isLegacy ? dayEntry.reasons : dayEntry.reasons + slice.unpricedReasonCounts
            dayEntry.legacyTokens += isLegacy ? slice.tokens.canonicalTotalTokens : 0
            dayEntry.legacyCost = isLegacy ? dayEntry.legacyCost + slice.cost : dayEntry.legacyCost
            dayEntry.legacyEvents += isLegacy ? slice.eventCount : 0
            var dayModelEntry = dayEntry.models[slice.model] ?? (tokens: .zero, cost: .zero, count: 0, reasons: .zero, provenance: .eventLedger)
            dayModelEntry.tokens = dayModelEntry.tokens + slice.tokens
            dayModelEntry.cost = isLegacy ? dayModelEntry.cost : dayModelEntry.cost + slice.cost
            dayModelEntry.count += slice.eventCount
            dayModelEntry.reasons = isLegacy ? dayModelEntry.reasons : dayModelEntry.reasons + slice.unpricedReasonCounts
            dayModelEntry.provenance = Self.combinedSummaryProvenance(dayModelEntry.provenance, slice.summaryProvenance)
            dayEntry.models[slice.model] = dayModelEntry
            daysMap[slice.dayKey] = dayEntry
        }

        let modelDistribution = modelsAgg.map { modelKey, val in
            ModelUsageSummaryDTO(
                modelCanonical: modelKey,
                tokens: val.tokens,
                estimatedCost: val.cost,
                eventCount: val.count,
                unpricedCount: val.unpriced,
                unpricedReasonCounts: val.reasons,
                summaryProvenance: val.provenance
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

        let totalTokenCount = totalTokens.canonicalTotalTokens
        let currentCatalogStats = try fetchCurrentCatalogCoverageStats(
            rangeStart: startDate,
            endExclusive: endDate
        )
        let coveredEvents = max(0, totalEvents - unpricedTotal - legacyAggregateEvents)
        let pricingCoverage: PricingCoverage
        if totalEvents == 0 || coveredEvents == totalEvents {
            pricingCoverage = .fullyPriced
        } else if coveredEvents == 0 {
            pricingCoverage = .unpriced(totalEvents: totalEvents)
        } else {
            pricingCoverage = .partiallyPriced(
                coveredEvents: coveredEvents,
                totalEvents: totalEvents
            )
        }
        let eventPricingCoverage = totalEvents > 0
            ? max(0, min(1, Double(coveredEvents) / Double(totalEvents)))
            : 1.0
        let coveredTokenCount = max(0, totalTokenCount - unpricedTokenTotal - legacyAggregateTokens)
        let tokenPricingCoverage = totalTokenCount > 0
            ? max(0, min(1, Double(coveredTokenCount) / Double(totalTokenCount)))
            : 1.0
        let currentCatalogCoverage = totalTokenCount > 0
            ? max(0, min(1, Double(min(totalTokenCount, currentCatalogStats.currentCatalogPricedTokens)) / Double(totalTokenCount)))
            : 1.0

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
            pricingCoverage: pricingCoverage,
            eventPricingCoverage: eventPricingCoverage,
            tokenPricingCoverage: tokenPricingCoverage,
            costForecastCoverage: tokenPricingCoverage,
            unpricedReasonCounts: unpricedReasons,
            legacyAggregateTokens: legacyAggregateTokens,
            legacyAggregateCost: legacyAggregateCost,
            legacyAggregateEventCount: legacyAggregateEvents,
            currentCatalogCoverage: currentCatalogCoverage
        )
    }

    private func fetchCurrentCatalogCoverageStats(
        rangeStart startDate: Date,
        endExclusive endDate: Date
    ) throws -> (currentCatalogPricedEventCount: Int, currentCatalogPricedTokens: Int64) {
        let startMs = Int64(startDate.timeIntervalSince1970 * 1_000)
        let endMs = Int64(endDate.timeIntervalSince1970 * 1_000)
        let activeCatalog = try database.stringScalar(
            sql: "SELECT catalog_version FROM codex_pricing_catalogs WHERE is_active = 1 ORDER BY published_at DESC LIMIT 1;"
        ) ?? BundledPricingCatalog.currentVersion
        return try database.executeQuery(
            sql: """
            SELECT
                COALESCE(SUM(CASE WHEN pricing_status = 'priced' AND pricing_catalog_version = ? THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN pricing_status = 'priced' AND pricing_catalog_version = ? THEN total_tokens ELSE 0 END), 0)
            FROM codex_usage_events
            WHERE is_child_replay = 0 AND timestamp_ms >= ? AND timestamp_ms < ?;
            """,
            bindings: [activeCatalog, activeCatalog, startMs, endMs]
        ) { stmt -> (Int, Int64) in
            (
                Int(sqlite3_column_int(stmt, 0)),
                sqlite3_column_int64(stmt, 1)
            )
        }.first ?? (0, 0)
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
    public func fetchActivityHeatmap(year: Int = UsageDayBucketer.calendar().component(.year, from: Date()), calendar: Calendar = UsageDayBucketer.calendar(), providerFilter: UsageProviderFilter = .all) throws -> [ActivityHeatmapCellDTO] {
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

        let provider = Self.providerPredicate(providerFilter)
        let sql = """
        SELECT
            day_key,
            day_start_ms,
            SUM(total_tokens),
            SUM(event_count),
            SUM(CASE WHEN summary_provenance = 'legacyAggregate' THEN 0 ELSE estimated_cost_usd_nano END),
            SUM(CASE WHEN summary_provenance = 'legacyAggregate' THEN estimated_cost_usd_nano ELSE 0 END)
        FROM codex_daily_usage_summaries
        WHERE day_start_ms >= ? AND day_start_ms < ?\(provider.sql)
        GROUP BY day_key, day_start_ms;
        """

        var tokenByDay: [LocalDayKey: (tokens: Int64, count: Int, cost: MoneyNanoUSD, legacyCost: MoneyNanoUSD)] = [:]
        _ = try database.executeQuery(sql: sql, bindings: [startTs, endTs] + provider.bindings) { stmt in
            let dayStartMs = sqlite3_column_int64(stmt, 1)
            let tok = sqlite3_column_int64(stmt, 2)
            let count = Int(sqlite3_column_int(stmt, 3))
            let cost = MoneyNanoUSD(sqlite3_column_int64(stmt, 4))
            let legacyCost = MoneyNanoUSD(sqlite3_column_int64(stmt, 5))
            let date = Date(timeIntervalSince1970: Double(dayStartMs) / 1000.0)
            let dayKey = LocalDayKey(date: date, calendar: calendar)

            let cur = tokenByDay[dayKey] ?? (0, 0, .zero, .zero)
            tokenByDay[dayKey] = (
                cur.tokens + tok,
                cur.count + count,
                cur.cost + cost,
                cur.legacyCost + legacyCost
            )
        }

        var cells: [ActivityHeatmapCellDTO] = []
        var curDate = startDate
        while curDate <= endDate {
            let dayKey = LocalDayKey(date: curDate, calendar: calendar)
            let data = tokenByDay[dayKey] ?? (tokens: 0, count: 0, cost: .zero, legacyCost: .zero)
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
                    legacyAggregateCost: data.legacyCost,
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
        let genericGPT56Events = try database.intScalar(sql: "SELECT COUNT(*) FROM codex_usage_events WHERE model_canonical = 'gpt-5.6' AND is_child_replay = 0;")
        let unpricedEvents = try database.intScalar(sql: "SELECT COUNT(*) FROM codex_usage_events WHERE pricing_status != 'priced' AND is_child_replay = 0;")
        let unpricedTokens = try database.int64Scalar(
            sql: "SELECT COALESCE(SUM(total_tokens), 0) FROM codex_usage_events WHERE pricing_status != 'priced' AND is_child_replay = 0;"
        ) ?? 0
        let eventReasonCounts = try fetchEventUnpricedReasonCounts()
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
                OR s.unpriced_event_count != COALESCE(SUM(d.unpriced_event_count), 0)
                OR s.unpriced_token_count != COALESCE(SUM(d.unpriced_token_count), 0)
        );
        """)
        let invalidValueViolations = try database.intScalar(sql: """
        SELECT COUNT(*) FROM codex_usage_events
        WHERE estimated_cost_usd_nano < 0
           OR input_tokens < 0 OR cached_input_tokens < 0 OR output_tokens < 0 OR reasoning_output_tokens < 0
           OR cache_write_input_tokens < 0
           OR cached_input_tokens + cache_write_input_tokens > input_tokens
           OR reasoning_output_tokens > output_tokens;
        """)
        let summaryCoverageViolations = try database.intScalar(sql: """
        SELECT COUNT(*) FROM codex_session_summaries
        WHERE unpriced_event_count < 0
           OR unpriced_event_count > event_count
           OR unpriced_token_count < 0
           OR unpriced_token_count > total_tokens;
        """) + database.intScalar(sql: """
        SELECT COUNT(*) FROM codex_daily_usage_summaries
        WHERE unpriced_event_count < 0
           OR unpriced_event_count > event_count
           OR unpriced_token_count < 0
           OR unpriced_token_count > total_tokens;
        """)
        let reasonCoverageViolations = try database.intScalar(sql: """
        SELECT COUNT(*) FROM codex_session_summaries
        WHERE unpriced_event_count != (
                unpriced_unknown_model_event_count
                + unpriced_unsupported_tier_event_count
                + unpriced_historical_rule_missing_event_count
                + unpriced_unsupported_context_event_count
                + unpriced_invalid_record_event_count
                + unpriced_overflow_event_count
            )
           OR unpriced_token_count != (
                unpriced_unknown_model_token_count
                + unpriced_unsupported_tier_token_count
                + unpriced_historical_rule_missing_token_count
                + unpriced_unsupported_context_token_count
                + unpriced_invalid_record_token_count
                + unpriced_overflow_token_count
            );
        """) + database.intScalar(sql: """
        SELECT COUNT(*) FROM codex_daily_usage_summaries
        WHERE unpriced_event_count != (
                unpriced_unknown_model_event_count
                + unpriced_unsupported_tier_event_count
                + unpriced_historical_rule_missing_event_count
                + unpriced_unsupported_context_event_count
                + unpriced_invalid_record_event_count
                + unpriced_overflow_event_count
            )
           OR unpriced_token_count != (
                unpriced_unknown_model_token_count
                + unpriced_unsupported_tier_token_count
                + unpriced_historical_rule_missing_token_count
                + unpriced_unsupported_context_token_count
                + unpriced_invalid_record_token_count
                + unpriced_overflow_token_count
            );
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
            + summaryCoverageViolations
            + reasonCoverageViolations
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
        let repriceGeneration = try database.int64Scalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'pricing_reprice_generation';"
        ) ?? 0
        let repriceStatus = try database.stringScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'pricing_reprice_status';"
        ) ?? "completed"
        let repriceLastRowID = try database.int64Scalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'pricing_reprice_last_rowid';"
        ) ?? 0
        let repriceProcessed = try database.intScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'pricing_reprice_processed_events';"
        )
        let repriceTotal = try database.intScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'pricing_reprice_total_events';"
        )
        let aggregationTimeZoneID = try database.stringScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'usage_aggregation_timezone_id';"
        )
        let aggregationGeneration = try database.int64Scalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'usage_aggregation_timezone_generation';"
        ) ?? 0
        let parserRebuildStatus = try database.stringScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'codex_parser_rebuild_status';"
        ) ?? "completed"
        let parserRebuildGeneration = try database.int64Scalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'codex_parser_rebuild_generation';"
        ) ?? 0
        let parserRebuildProcessedSources = try database.intScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'codex_parser_rebuild_processed_sources';"
        )
        let parserRebuildTotalSources = try database.intScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'codex_parser_rebuild_total_sources';"
        )
        let skippedNonRolloutJSONLCount = try database.intScalar(
            sql: "SELECT COUNT(*) FROM codex_scan_diagnostics WHERE diagnostic_code = 'non_rollout_jsonl_probe_miss';"
        )
        let pendingSourceCount = try database.intScalar(
            sql: """
            SELECT COUNT(*)
            FROM codex_import_sources
            WHERE status != 'tombstoned'
              AND (status = 'stale' OR parser_version != ?);
            """,
            bindings: [ParserCheckpoint.currentParserVersion]
        )
        let sourcePresenceRows = try database.executeQuery(
            sql: """
            SELECT source_path, relative_path
            FROM codex_import_sources
            WHERE status != 'tombstoned';
            """
        ) { stmt -> (String, String) in
            let sourcePath = sqlite3_column_type(stmt, 0) != SQLITE_NULL && sqlite3_column_text(stmt, 0) != nil
                ? String(cString: sqlite3_column_text(stmt, 0)!)
                : ""
            let relativePath = sqlite3_column_type(stmt, 1) != SQLITE_NULL && sqlite3_column_text(stmt, 1) != nil
                ? String(cString: sqlite3_column_text(stmt, 1)!)
                : ""
            return (sourcePath, relativePath)
        }
        let missingSourceCount = sourcePresenceRows.filter { sourcePath, relativePath in
            let primary = Self.absoluteSourcePath(sourcePath)
            let fallback = Self.absoluteSourcePath(relativePath)
            return !FileManager.default.fileExists(atPath: primary)
                && (fallback.isEmpty || !FileManager.default.fileExists(atPath: fallback))
        }.count
        let legacyAggregateSessionCount = try database.intScalar(
            sql: "SELECT COUNT(*) FROM codex_sessions WHERE summary_provenance = 'legacyAggregate' AND event_count > 0;"
        )
        let legacyAggregateRow = try database.executeQuery(
            sql: """
            SELECT
                COALESCE(SUM(event_count), 0),
                COALESCE(SUM(total_tokens), 0),
                COALESCE(SUM(estimated_cost_usd_nano), 0)
            FROM codex_session_summaries
            WHERE summary_provenance = 'legacyAggregate';
            """
        ) { stmt -> (Int, Int64, Int64) in
            (
                Int(sqlite3_column_int(stmt, 0)),
                sqlite3_column_int64(stmt, 1),
                sqlite3_column_int64(stmt, 2)
            )
        }.first ?? (0, 0, 0)
        let timestampConflictCount = try database.intScalar(
            sql: "SELECT COALESCE(SUM(timestamp_conflict_count), 0) FROM codex_import_sources;"
        )
        let pendingDeletionJournalCount = try database.intScalar(
            sql: """
            SELECT COUNT(*)
            FROM codex_session_deletion_journal
            WHERE status NOT IN ('finalized', 'rollbackRequired');
            """
        )
        let rollbackRequiredDeletionJournalCount = try database.intScalar(
            sql: "SELECT COUNT(*) FROM codex_session_deletion_journal WHERE status = 'rollbackRequired';"
        )
        let pricingMigrationState = PricingMigrationState(
            storedValue: try database.stringScalar(
                sql: "SELECT value FROM app_metadata WHERE key = 'pricing_migration_state';"
            )
        )

        return UsageDiagnosticsDTO(
            sourcesDiscovered: sourcesDiscovered,
            sourcesIndexed: sourcesIndexed,
            sourcesTombstoned: sourcesTombstoned,
            unknownModelEvents: unknownModelEvents,
            genericGPT56Events: genericGPT56Events,
            unpricedEvents: unpricedEvents,
            unpricedTokens: unpricedTokens,
            unpricedReasonCounts: eventReasonCounts,
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
            invariantViolationCount: invariantViolationCount,
            pricingRepriceGeneration: repriceGeneration,
            pricingRepriceStatus: repriceStatus,
            pricingMigrationState: pricingMigrationState,
            pricingRepriceLastRowID: repriceLastRowID,
            pricingRepriceProcessedEvents: repriceProcessed,
            pricingRepriceTotalEvents: repriceTotal,
            usageAggregationTimeZoneID: aggregationTimeZoneID,
            usageAggregationGeneration: aggregationGeneration,
            parserRebuildStatus: parserRebuildStatus,
            parserRebuildGeneration: parserRebuildGeneration,
            parserRebuildProcessedSources: parserRebuildProcessedSources,
            parserRebuildTotalSources: parserRebuildTotalSources,
            skippedNonRolloutJSONLCount: skippedNonRolloutJSONLCount,
            pendingSourceCount: pendingSourceCount,
            missingSourceCount: missingSourceCount,
            legacyAggregateSessionCount: legacyAggregateSessionCount,
            legacyAggregateEventCount: legacyAggregateRow.0,
            legacyAggregateTokens: legacyAggregateRow.1,
            legacyAggregateCost: MoneyNanoUSD(legacyAggregateRow.2),
            timestampConflictCount: timestampConflictCount,
            pendingDeletionJournalCount: pendingDeletionJournalCount,
            rollbackRequiredDeletionJournalCount: rollbackRequiredDeletionJournalCount
        )
    }

    private func fetchEventUnpricedReasonCounts() throws -> UnpricedReasonCounts {
        let rows = try database.executeQuery(
            sql: """
            SELECT pricing_status, COUNT(*), COALESCE(SUM(total_tokens), 0)
            FROM codex_usage_events
            WHERE pricing_status != 'priced' AND is_child_replay = 0
            GROUP BY pricing_status;
            """
        ) { stmt -> (PricingStatus, Int, Int64) in
            (
                PricingStatus(rawValue: String(cString: sqlite3_column_text(stmt, 0))) ?? .unpricedUnknownModel,
                Int(sqlite3_column_int(stmt, 1)),
                sqlite3_column_int64(stmt, 2)
            )
        }
        var counts = UnpricedReasonCounts.zero
        for row in rows {
            switch row.0 {
            case .priced:
                continue
            case .unpricedUnknownModel:
                counts.unknownModelEvents += row.1
                counts.unknownModelTokens += row.2
            case .unpricedHistoricalRuleMissing:
                counts.historicalRuleMissingEvents += row.1
                counts.historicalRuleMissingTokens += row.2
            case .unpricedUnsupportedServiceMode:
                counts.unsupportedTierEvents += row.1
                counts.unsupportedTierTokens += row.2
            case .unpricedUnsupportedContextLength:
                counts.unsupportedContextEvents += row.1
                counts.unsupportedContextTokens += row.2
            case .unpricedInvalidTokenRecord:
                counts.invalidRecordEvents += row.1
                counts.invalidRecordTokens += row.2
            case .unpricedCalculationOverflow:
                counts.overflowEvents += row.1
                counts.overflowTokens += row.2
            }
        }
        return counts
    }

    private func fetchEventPage(
        whereClause: String,
        bindings baseBindings: [Any?],
        limit: Int,
        cursor: String?
    ) throws -> CodexUsageEventPageDTO {
        let requestedLimit = min(max(1, limit), 1_000)
        var conditions = [whereClause]
        var bindings = baseBindings
        if let cursorParts = Self.decodeEventCursor(cursor) {
            conditions.append("""
            (
                timestamp_ms < ?
                OR (timestamp_ms = ? AND line_offset < ?)
                OR (timestamp_ms = ? AND line_offset = ? AND event_id < ?)
            )
            """)
            bindings.append(contentsOf: [
                cursorParts.timestampMs,
                cursorParts.timestampMs,
                cursorParts.lineOffset,
                cursorParts.timestampMs,
                cursorParts.lineOffset,
                cursorParts.eventId
            ])
        }

        let combinedWhere = conditions.joined(separator: " AND ")
        let total = try database.intScalar(
            sql: "SELECT COUNT(*) FROM codex_usage_events WHERE \(whereClause);",
            bindings: baseBindings
        )
        let rows = try database.executeQuery(
            sql: """
            SELECT
                event_id, session_id, root_session_id, turn_index, call_index, timestamp_ms,
                model_raw, model_canonical, service_tier, reasoning_effort,
                input_tokens, cached_input_tokens, cache_write_input_tokens,
                output_tokens, reasoning_output_tokens, total_tokens, estimated_cost_usd_nano,
                pricing_rule_id, pricing_status, usage_derivation, attribution_quality,
                is_child_replay, source_path, line_offset, timestamp_quality,
                timestamp_source, timestamp_conflict_count, pricing_catalog_version, provider
            FROM codex_usage_events
            WHERE \(combinedWhere)
            ORDER BY timestamp_ms DESC, line_offset DESC, event_id DESC
            LIMIT ?;
            """,
            bindings: bindings + [requestedLimit + 1],
            rowMapper: Self.mapEventRow
        )
        let hasMore = rows.count > requestedLimit
        let pageRows = Array(rows.prefix(requestedLimit))
        return CodexUsageEventPageDTO(
            events: pageRows,
            totalEventCount: total,
            loadedEventCount: pageRows.count,
            hasMore: hasMore,
            nextCursor: hasMore ? pageRows.last.map(Self.encodeEventCursor) : nil
        )
    }

    private func fetchSessionsById(ids: [String]) throws -> [String: CodexSessionDTO] {
        let uniqueIds = Array(Set(ids)).sorted()
        guard !uniqueIds.isEmpty else { return [:] }
        var result: [String: CodexSessionDTO] = [:]
        let batchSize = 500
        for start in stride(from: 0, to: uniqueIds.count, by: batchSize) {
            let end = min(start + batchSize, uniqueIds.count)
            let batch = Array(uniqueIds[start..<end])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let sessions = try database.executeQuery(
                sql: """
                SELECT
                    session_id, root_session_id, parent_session_id, depth, title, project_name, cwd,
                    created_at, updated_at, last_event_at, event_count, total_tokens, input_tokens,
                    cached_input_tokens, cache_write_input_tokens, output_tokens,
                    reasoning_output_tokens, estimated_cost_usd_nano,
                    pricing_status, bucket, has_subagents, agent_type,
                    unpriced_unknown_model_event_count, unpriced_unknown_model_token_count,
                    unpriced_unsupported_tier_event_count, unpriced_unsupported_tier_token_count,
                    unpriced_historical_rule_missing_event_count, unpriced_historical_rule_missing_token_count,
                    unpriced_unsupported_context_event_count, unpriced_unsupported_context_token_count,
                    unpriced_invalid_record_event_count, unpriced_invalid_record_token_count,
                    unpriced_overflow_event_count, unpriced_overflow_token_count,
                    summary_provenance, provider
                FROM codex_sessions
                WHERE session_id IN (\(placeholders));
                """,
                bindings: batch,
                rowMapper: Self.mapSessionRow
            )
            for session in sessions {
                result[session.sessionId] = session
            }
        }
        return result
    }

    private struct CursorParts {
        let primary: Int64
        let sessionId: String
    }

    private struct EventCursorParts {
        let timestampMs: Int64
        let lineOffset: Int64
        let eventId: String
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
            primary = Int64(((session.lastEventAt ?? session.updatedAt).timeIntervalSince1970 * 1_000).rounded())
        case .totalTokensDesc:
            primary = session.tokens.canonicalTotalTokens
        case .estimatedCostDesc:
            primary = session.estimatedCost.rawValue
        case .createdDesc:
            primary = Int64((session.createdAt.timeIntervalSince1970 * 1_000).rounded())
        }
        return "\(primary)|\(session.sessionId)"
    }

    private static func decodeEventCursor(_ cursor: String?) -> EventCursorParts? {
        guard let cursor, !cursor.isEmpty else { return nil }
        let parts = cursor.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count == 3,
              let timestamp = Int64(parts[0]),
              let lineOffset = Int64(parts[1]) else {
            return nil
        }
        return EventCursorParts(timestampMs: timestamp, lineOffset: lineOffset, eventId: parts[2])
    }

    private static func encodeEventCursor(event: CodexUsageEventDTO) -> String {
        let timestampMs = Int64((event.timestamp.timeIntervalSince1970 * 1_000).rounded())
        return "\(timestampMs)|\(event.lineOffset)|\(event.eventId)"
    }

    private static func unpricedReasonCounts(from stmt: OpaquePointer, start: Int32) -> UnpricedReasonCounts {
        UnpricedReasonCounts(
            unknownModelEvents: Int(sqlite3_column_int(stmt, start)),
            unknownModelTokens: sqlite3_column_int64(stmt, start + 1),
            unsupportedTierEvents: Int(sqlite3_column_int(stmt, start + 2)),
            unsupportedTierTokens: sqlite3_column_int64(stmt, start + 3),
            historicalRuleMissingEvents: Int(sqlite3_column_int(stmt, start + 4)),
            historicalRuleMissingTokens: sqlite3_column_int64(stmt, start + 5),
            unsupportedContextEvents: Int(sqlite3_column_int(stmt, start + 6)),
            unsupportedContextTokens: sqlite3_column_int64(stmt, start + 7),
            invalidRecordEvents: Int(sqlite3_column_int(stmt, start + 8)),
            invalidRecordTokens: sqlite3_column_int64(stmt, start + 9),
            overflowEvents: Int(sqlite3_column_int(stmt, start + 10)),
            overflowTokens: sqlite3_column_int64(stmt, start + 11)
        )
    }

    /// Reads full calendar days from the compact aggregate table and only
    /// touches raw ledger events for the two partial boundary days. A fallback
    /// keeps manually-created and legacy databases working when summaries have
    /// not been built yet.
    private func fetchUsageAggregateSlices(
        rangeStart startDate: Date,
        endExclusive endDate: Date,
        calendar: Calendar,
        providerFilter: UsageProviderFilter
    ) throws -> [UsageAggregateSlice] {
        guard startDate < endDate else { return [] }

        let startDay = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)
        guard let dayAfterStart = calendar.date(byAdding: .day, value: 1, to: startDay) else {
            return try fetchRawUsageSlices(rangeStart: startDate, endExclusive: endDate, calendar: calendar, providerFilter: providerFilter)
        }

        let startsOnDayBoundary = abs(startDate.timeIntervalSince(startDay)) < 0.001
        let summaryStart = startsOnDayBoundary ? startDay : dayAfterStart

        // No complete calendar day exists inside this range.
        guard summaryStart < endDay else {
            return try fetchRawUsageSlices(rangeStart: startDate, endExclusive: endDate, calendar: calendar, providerFilter: providerFilter)
        }

        var slices: [UsageAggregateSlice] = []
        if startDate < summaryStart {
            slices += try fetchRawUsageSlices(
                rangeStart: startDate,
                endExclusive: min(summaryStart, endDate),
                calendar: calendar,
                providerFilter: providerFilter
            )
        }

        slices += try fetchFullDayUsageSlices(
            rangeStart: summaryStart,
            endExclusive: endDay,
            calendar: calendar,
            providerFilter: providerFilter
        )

        if endDay < endDate {
            slices += try fetchRawUsageSlices(
                rangeStart: max(endDay, startDate),
                endExclusive: endDate,
                calendar: calendar,
                providerFilter: providerFilter
            )
        }
        return slices
    }

    private func fetchFullDayUsageSlices(
        rangeStart startDate: Date,
        endExclusive endDate: Date,
        calendar: Calendar,
        providerFilter: UsageProviderFilter
    ) throws -> [UsageAggregateSlice] {
        guard startDate < endDate else { return [] }
        let startMs = Int64(startDate.timeIntervalSince1970 * 1_000)
        let endMs = Int64(endDate.timeIntervalSince1970 * 1_000)

        let provider = Self.providerPredicate(providerFilter)
        let summaries = try database.executeQuery(
            sql: """
            SELECT
                session_id, day_start_ms, model_canonical, event_count, total_tokens,
                uncached_input_tokens, cached_input_tokens, cache_write_input_tokens, output_tokens,
                reasoning_output_tokens, estimated_cost_usd_nano, unpriced_event_count,
                unpriced_token_count,
                unpriced_unknown_model_event_count, unpriced_unknown_model_token_count,
                unpriced_unsupported_tier_event_count, unpriced_unsupported_tier_token_count,
                unpriced_historical_rule_missing_event_count, unpriced_historical_rule_missing_token_count,
                unpriced_unsupported_context_event_count, unpriced_unsupported_context_token_count,
                unpriced_invalid_record_event_count, unpriced_invalid_record_token_count,
                unpriced_overflow_event_count, unpriced_overflow_token_count,
                summary_provenance
            FROM codex_daily_usage_summaries
            WHERE day_start_ms >= ? AND day_start_ms < ?\(provider.sql)
            ORDER BY day_start_ms ASC, session_id ASC, model_canonical ASC;
            """,
            bindings: [startMs, endMs] + provider.bindings
        ) { statement -> UsageAggregateSlice in
            let total = sqlite3_column_int64(statement, 4)
            let uncached = sqlite3_column_int64(statement, 5)
            let cached = sqlite3_column_int64(statement, 6)
            let cacheWrite = sqlite3_column_int64(statement, 7)
            let unpriced = Int(sqlite3_column_int(statement, 11))
            let dayStart = Date(
                timeIntervalSince1970: Double(sqlite3_column_int64(statement, 1)) / 1_000.0
            )
            return UsageAggregateSlice(
                dayKey: LocalDayKey(date: dayStart, calendar: calendar),
                tokens: TokenBreakdown(
                    inputTokens: uncached + cached + cacheWrite,
                    cachedInputTokens: cached,
                    cacheWriteInputTokens: cacheWrite,
                    outputTokens: sqlite3_column_int64(statement, 8),
                    reasoningOutputTokens: sqlite3_column_int64(statement, 9),
                    sourceTotalTokens: total
                ),
                cost: MoneyNanoUSD(sqlite3_column_int64(statement, 10)),
                model: String(cString: sqlite3_column_text(statement, 2)),
                sessionId: String(cString: sqlite3_column_text(statement, 0)),
                eventCount: Int(sqlite3_column_int(statement, 3)),
                unpricedCount: unpriced,
                unpricedTokens: sqlite3_column_int64(statement, 12),
                unpricedReasonCounts: Self.unpricedReasonCounts(from: statement, start: 13),
                summaryProvenance: SummaryProvenance(
                    storedValue: sqlite3_column_type(statement, 25) != SQLITE_NULL
                        && sqlite3_column_text(statement, 25) != nil
                        ? String(cString: sqlite3_column_text(statement, 25)!)
                        : nil
                )
            )
        }

        if !summaries.isEmpty {
            return summaries
        }

        let hasRawEvents = try database.intScalar(
            sql: """
            SELECT EXISTS(
                SELECT 1 FROM codex_usage_events
                WHERE is_child_replay = 0 AND timestamp_ms >= ? AND timestamp_ms < ?\(provider.sql)
                LIMIT 1
            );
            """,
            bindings: [startMs, endMs] + provider.bindings
        ) > 0
        return hasRawEvents
            ? try fetchRawUsageSlices(rangeStart: startDate, endExclusive: endDate, calendar: calendar, providerFilter: providerFilter)
            : []
    }

    private func fetchRawUsageSlices(
        rangeStart startDate: Date,
        endExclusive endDate: Date,
        calendar: Calendar,
        providerFilter: UsageProviderFilter
    ) throws -> [UsageAggregateSlice] {
        guard startDate < endDate else { return [] }
        let startMs = Int64(startDate.timeIntervalSince1970 * 1_000)
        let endMs = Int64(endDate.timeIntervalSince1970 * 1_000)

        let provider = Self.providerPredicate(providerFilter)
        return try database.executeQuery(
            sql: """
            SELECT
                timestamp_ms, model_canonical, session_id, pricing_status,
                input_tokens, cached_input_tokens, cache_write_input_tokens,
                output_tokens, reasoning_output_tokens, total_tokens, estimated_cost_usd_nano
            FROM codex_usage_events
            WHERE is_child_replay = 0 AND timestamp_ms >= ? AND timestamp_ms < ?\(provider.sql);
            """,
            bindings: [startMs, endMs] + provider.bindings
        ) { statement -> UsageAggregateSlice in
            let timestampMs = sqlite3_column_int64(statement, 0)
            let total = sqlite3_column_int64(statement, 9)
            let pricingStatus = PricingStatus(
                rawValue: String(cString: sqlite3_column_text(statement, 3))
            ) ?? .unpricedUnknownModel
            var reasons = UnpricedReasonCounts.zero
            reasons.add(status: pricingStatus, tokenCount: total)
            return UsageAggregateSlice(
                dayKey: LocalDayKey(
                    date: Date(timeIntervalSince1970: Double(timestampMs) / 1_000.0),
                    calendar: calendar
                ),
                tokens: TokenBreakdown(
                    inputTokens: sqlite3_column_int64(statement, 4),
                    cachedInputTokens: sqlite3_column_int64(statement, 5),
                    cacheWriteInputTokens: sqlite3_column_int64(statement, 6),
                    outputTokens: sqlite3_column_int64(statement, 7),
                    reasoningOutputTokens: sqlite3_column_int64(statement, 8),
                    sourceTotalTokens: total
                ),
                cost: MoneyNanoUSD(sqlite3_column_int64(statement, 10)),
                model: String(cString: sqlite3_column_text(statement, 1)),
                sessionId: String(cString: sqlite3_column_text(statement, 2)),
                eventCount: 1,
                unpricedCount: pricingStatus.isPriced ? 0 : 1,
                unpricedTokens: pricingStatus.isPriced ? 0 : total,
                unpricedReasonCounts: reasons,
                summaryProvenance: .eventLedger
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
                unpricedTokens: 0,
                reasons: .zero,
                legacyTokens: 0,
                legacyCost: .zero,
                legacyEvents: 0
            )
            let modelSummaries = val.models.map { modelKey, mVal in
                ModelUsageSummaryDTO(
                    modelCanonical: modelKey,
                    tokens: mVal.tokens,
                    estimatedCost: mVal.cost,
                    eventCount: mVal.count,
                    unpricedCount: mVal.reasons.totalEvents,
                    unpricedReasonCounts: mVal.reasons,
                    summaryProvenance: mVal.provenance
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
                    unpricedTokenCount: val.unpricedTokens,
                    unpricedReasonCounts: val.reasons,
                    legacyAggregateTokens: val.legacyTokens,
                    legacyAggregateCost: val.legacyCost
                )
            )
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result.sorted { $0.dayKey > $1.dayKey }
    }

    private static func combinedSummaryProvenance(
        _ current: SummaryProvenance,
        _ incoming: SummaryProvenance
    ) -> SummaryProvenance {
        if current == incoming { return current }
        if current == .legacyAggregate && incoming == .legacyAggregate { return .legacyAggregate }
        if current == .eventLedger && incoming == .eventLedger { return .eventLedger }
        return .reconstructed
    }

    private static func providerPredicate(
        _ filter: UsageProviderFilter
    ) -> (sql: String, bindings: [Any?]) {
        guard let provider = filter.provider else { return ("", []) }
        return (" AND provider = ?", [provider.rawValue])
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
        let cacheWriteTokens = sqlite3_column_int64(stmt, 14)
        let outputTokens = sqlite3_column_int64(stmt, 15)
        let reasoningTokens = sqlite3_column_int64(stmt, 16)
        let costNano = sqlite3_column_int64(stmt, 17)
        let pricingStr = String(cString: sqlite3_column_text(stmt, 18))
        let bucketStr = String(cString: sqlite3_column_text(stmt, 19))
        let hasSubagents = sqlite3_column_int(stmt, 20) != 0
        let agentType = sqlite3_column_type(stmt, 21) != SQLITE_NULL && sqlite3_column_text(stmt, 21) != nil
            ? String(cString: sqlite3_column_text(stmt, 21)!) : nil
        let reasonCounts = sqlite3_column_count(stmt) >= 34
            ? Self.unpricedReasonCounts(from: stmt, start: 22)
            : .zero
        let provenanceRaw = sqlite3_column_count(stmt) >= 35
            && sqlite3_column_type(stmt, 34) != SQLITE_NULL
            && sqlite3_column_text(stmt, 34) != nil
            ? String(cString: sqlite3_column_text(stmt, 34)!)
            : nil
        let providerRaw = sqlite3_column_count(stmt) >= 36
            && sqlite3_column_type(stmt, 35) != SQLITE_NULL
            && sqlite3_column_text(stmt, 35) != nil
            ? String(cString: sqlite3_column_text(stmt, 35)!)
            : UsageProvider.codex.rawValue

        return CodexSessionDTO(
            sessionId: sid,
            provider: UsageProvider(rawValue: providerRaw) ?? .codex,
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
                cacheWriteInputTokens: cacheWriteTokens,
                outputTokens: outputTokens,
                reasoningOutputTokens: reasoningTokens,
                sourceTotalTokens: totalTokens
            ),
            estimatedCost: MoneyNanoUSD(costNano),
            pricingStatus: AggregatePricingStatus(storedValue: pricingStr),
            summaryProvenance: SummaryProvenance(storedValue: provenanceRaw),
            unpricedReasonCounts: reasonCounts,
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

    private static func stringColumn(_ statement: OpaquePointer, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    private static func localizedContains(_ value: String, query: String) -> Bool {
        value.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: nil,
            locale: L10n.locale
        ) != nil
    }

    private func deleteSessionDerivedRows(
        sessionIDs: Set<String>,
        sourceKeys: Set<String>
    ) throws {
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

    private func deleteDerivedRowsForSource(
        sourcePath: String,
        relativePath: String
    ) throws {
        let sessionIDs = try database.executeQuery(
            sql: """
            SELECT session_id
            FROM codex_sessions
            WHERE source_path = ? OR relative_path = ?;
            """,
            bindings: [sourcePath, relativePath]
        ) { statement in
            String(cString: sqlite3_column_text(statement, 0))
        }

        try database.executeUpdate(
            sql: "DELETE FROM codex_usage_events WHERE source_path = ? OR source_path = ?;",
            bindings: [sourcePath, relativePath]
        )
        for sessionID in sessionIDs {
            try database.executeUpdate(
                sql: "DELETE FROM codex_session_summaries WHERE session_id = ?;",
                bindings: [sessionID]
            )
            try database.executeUpdate(
                sql: "DELETE FROM codex_daily_usage_summaries WHERE session_id = ?;",
                bindings: [sessionID]
            )
            try database.executeUpdate(
                sql: "DELETE FROM codex_sessions WHERE session_id = ?;",
                bindings: [sessionID]
            )
        }
    }

    private func createDeletionJournal(
        deletionId: String,
        requestedSessionId: String,
        rootSessionId: String,
        historyRoot: URL,
        stagingRoot: URL,
        sources: [(
            sessionId: String,
            sourcePath: String,
            relativePath: String,
            bucket: SessionBucket,
            originalURL: URL,
            stagingURL: URL,
            initialState: String
        )]
    ) throws {
        let now = Self.unixSeconds()
        try database.transaction {
            try database.executeUpdate(
                sql: """
                INSERT INTO codex_session_deletion_journal (
                    deletion_id, requested_session_id, root_session_id,
                    history_root_path, staging_root_path, status, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, 'prepared', ?, ?);
                """,
                bindings: [
                    deletionId,
                    requestedSessionId,
                    rootSessionId,
                    historyRoot.path,
                    stagingRoot.path,
                    now,
                    now
                ]
            )
            for source in sources {
                try database.executeUpdate(
                    sql: """
                    INSERT INTO codex_session_deletion_files (
                        deletion_id, session_id, source_path, relative_path, bucket,
                        original_path, staging_path, recovery_path, state, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, ?);
                    """,
                    bindings: [
                        deletionId,
                        source.sessionId,
                        source.sourcePath,
                        source.relativePath,
                        source.bucket.rawValue,
                        source.originalURL.path,
                        source.stagingURL.path,
                        source.initialState,
                        now
                    ]
                )
            }
        }
    }

    private func updateDeletionJournalStatus(
        deletionId: String,
        status: String,
        error: String? = nil
    ) throws {
        try updateDeletionJournalStatusInTransaction(
            deletionId: deletionId,
            status: status,
            error: error
        )
    }

    private func updateDeletionJournalStatusInTransaction(
        deletionId: String,
        status: String,
        error: String? = nil
    ) throws {
        try database.executeUpdate(
            sql: """
            UPDATE codex_session_deletion_journal
            SET status = ?, updated_at = ?, error_message = ?
            WHERE deletion_id = ?;
            """,
            bindings: [status, Self.unixSeconds(), error, deletionId]
        )
    }

    private func updateDeletionFileState(
        deletionId: String,
        originalPath: String,
        state: String,
        stagingPath: String,
        recoveryPath: String?
    ) throws {
        try database.executeUpdate(
            sql: """
            UPDATE codex_session_deletion_files
            SET state = ?, staging_path = ?, recovery_path = ?, updated_at = ?
            WHERE deletion_id = ? AND original_path = ?;
            """,
            bindings: [
                state,
                stagingPath,
                recoveryPath,
                Self.unixSeconds(),
                deletionId,
                originalPath
            ]
        )
    }

    private func markDeletionRollbackRequired(
        deletionId: String,
        failures: [String]
    ) throws {
        try updateDeletionJournalStatus(
            deletionId: deletionId,
            status: "rollbackRequired",
            error: failures.joined(separator: "; ")
        )
    }

    private func rollbackDeletionFiles(
        deletionId: String,
        allowRecordedRecoveryCleanup: Bool = false
    ) throws -> [String] {
        let historyRoot = try database.stringScalar(
            sql: "SELECT history_root_path FROM codex_session_deletion_journal WHERE deletion_id = ?;",
            bindings: [deletionId]
        ).map { Self.canonicalFileURL(URL(fileURLWithPath: $0)) }
        let rows = try database.executeQuery(
            sql: """
            SELECT original_path, staging_path, recovery_path, state
            FROM codex_session_deletion_files
            WHERE deletion_id = ?
            ORDER BY original_path DESC;
            """,
            bindings: [deletionId]
        ) { stmt -> (String, String, String?, String) in
            let recoveryPath = sqlite3_column_type(stmt, 2) != SQLITE_NULL
                && sqlite3_column_text(stmt, 2) != nil
                ? String(cString: sqlite3_column_text(stmt, 2)!)
                : nil
            return (
                String(cString: sqlite3_column_text(stmt, 0)),
                String(cString: sqlite3_column_text(stmt, 1)),
                recoveryPath,
                String(cString: sqlite3_column_text(stmt, 3))
            )
        }

        let fileManager = FileManager.default
        var failures: [String] = []
        for row in rows {
            if row.3 == "missingBeforeDelete" {
                continue
            }

            let stagingExists = fileManager.fileExists(atPath: row.1)
            let recoveryExists = row.2.map { fileManager.fileExists(atPath: $0) } ?? false
            if fileManager.fileExists(atPath: row.0) {
                if stagingExists || recoveryExists {
                    failures.append("restore destination already exists \(row.0)")
                }
                continue
            }

            let sourcePath: String?
            if stagingExists {
                sourcePath = row.1
            } else if recoveryExists, let recoveryPath = row.2, let historyRoot {
                let recovery = Self.canonicalFileURL(URL(fileURLWithPath: recoveryPath))
                let original = Self.canonicalFileURL(URL(fileURLWithPath: row.0))
                if Self.isSafeDeletionRecoverySource(
                    recovery,
                    original: original,
                    historyRoot: historyRoot
                ) {
                    sourcePath = recoveryPath
                } else {
                    failures.append("unsafe recovery source \(recovery.path)")
                    continue
                }
            } else {
                sourcePath = nil
            }
            guard let sourcePath else {
                failures.append("missing recovery source \(row.1)")
                continue
            }
            do {
                let originalURL = URL(fileURLWithPath: row.0)
                try fileManager.createDirectory(
                    at: originalURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(
                    at: URL(fileURLWithPath: sourcePath),
                    to: originalURL
                )
                if let recoveryPath = row.2,
                   recoveryPath != sourcePath,
                   fileManager.fileExists(atPath: recoveryPath) {
                    let mayRemoveRecordedRecovery = allowRecordedRecoveryCleanup
                        || (historyRoot.map {
                            Self.isSafeDeletionRecoverySource(
                                Self.canonicalFileURL(URL(fileURLWithPath: recoveryPath)),
                                original: Self.canonicalFileURL(originalURL),
                                historyRoot: $0
                            )
                        } ?? false)
                    if mayRemoveRecordedRecovery {
                        try? fileManager.removeItem(atPath: recoveryPath)
                    }
                }
                try updateDeletionFileState(
                    deletionId: deletionId,
                    originalPath: row.0,
                    state: "rolledBack",
                    stagingPath: row.1,
                    recoveryPath: row.2
                )
            } catch {
                failures.append("\(row.0): \(error.localizedDescription)")
            }
        }
        return failures
    }

    private func validateDeletionJournalSafety(
        deletionId: String,
        status: String,
        historyRootPath: String,
        stagingRootPath: String,
        historyRootURL: URL?
    ) throws -> [String] {
        let expectedHistoryRoot = Self.canonicalFileURL(historyRootURL ?? URL(fileURLWithPath: historyRootPath))
        let storedHistoryRoot = Self.canonicalFileURL(URL(fileURLWithPath: historyRootPath))
        var failures: [String] = []
        if storedHistoryRoot.path != expectedHistoryRoot.path {
            failures.append("history root mismatch \(storedHistoryRoot.path)")
        }

        let stagingRoot = Self.canonicalFileURL(URL(fileURLWithPath: stagingRootPath))
        if !Self.isSafeDeletionStagingRoot(
            stagingRoot,
            historyRoot: storedHistoryRoot,
            trustedBaseRoots: trustedDeletionStagingBaseRoots,
            trustedOperationRoots: trustedDeletionStagingOperationRoots
        ) {
            failures.append("unsafe staging root \(stagingRoot.path)")
        }

        let paths = CodexHistoryPaths(rootURL: storedHistoryRoot)
        let allowedRoots = [paths.sessionsURL, paths.archivedSessionsURL]
            .map(Self.canonicalFileURL)
        let fileRows = try database.executeQuery(
            sql: """
            SELECT original_path, staging_path, recovery_path
            FROM codex_session_deletion_files
            WHERE deletion_id = ?;
            """,
            bindings: [deletionId]
        ) { stmt -> (String, String, String?) in
            let recoveryPath = sqlite3_column_type(stmt, 2) != SQLITE_NULL
                && sqlite3_column_text(stmt, 2) != nil
                ? String(cString: sqlite3_column_text(stmt, 2)!)
                : nil
            return (
                String(cString: sqlite3_column_text(stmt, 0)),
                String(cString: sqlite3_column_text(stmt, 1)),
                recoveryPath
            )
        }
        let needsFileRecovery = status != "databaseCommitted"
        for row in fileRows {
            let original = Self.canonicalFileURL(URL(fileURLWithPath: row.0))
            if !allowedRoots.contains(where: { Self.path(original.path, isInside: $0.path) }) {
                failures.append("unsafe original path \(original.path)")
            }
            let staging = Self.canonicalFileURL(URL(fileURLWithPath: row.1))
            if !Self.path(staging.path, isInside: stagingRoot.path) {
                failures.append("unsafe staging path \(staging.path)")
            }
            if needsFileRecovery, let recoveryPath = row.2 {
                let recovery = Self.canonicalFileURL(URL(fileURLWithPath: recoveryPath))
                let stagingExists = FileManager.default.fileExists(atPath: staging.path)
                if !stagingExists && !Self.isSafeDeletionRecoverySource(
                    recovery,
                    original: original,
                    historyRoot: storedHistoryRoot
                ) {
                    failures.append("unexpected recovery file \(recovery.path)")
                }
            }
        }
        return failures
    }

    private static func unixSeconds() -> Int64 {
        Int64(Date().timeIntervalSince1970)
    }

    private static func makeDeletionStagingDirectory() throws -> URL {
        let base = defaultDeletionStagingBaseDirectory()
        let staging = base
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    private static func defaultDeletionStagingBaseDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return base
            .appendingPathComponent("QuotaLens", isDirectory: true)
            .appendingPathComponent("DeletionStaging", isDirectory: true)
    }

    private static func isSafeDeletionStagingRoot(
        _ stagingRoot: URL,
        historyRoot: URL,
        trustedBaseRoots: [URL],
        trustedOperationRoots: [URL]
    ) -> Bool {
        let stagingPath = canonicalFileURL(stagingRoot).path
        let historyPath = canonicalFileURL(historyRoot).path
        guard stagingPath != "/", stagingPath.count > 8 else { return false }
        guard stagingPath != historyPath,
              !path(historyPath, isInside: stagingPath),
              !path(stagingPath, isInside: historyPath) else {
            return false
        }
        if trustedOperationRoots.contains(where: { canonicalFileURL($0).path == stagingPath }) {
            return true
        }
        return trustedBaseRoots.contains { root in
            let rootPath = canonicalFileURL(root).path
            guard stagingPath != rootPath,
                  path(stagingPath, isInside: rootPath) else {
                return false
            }
            let relative = stagingPath
                .dropFirst(rootPath.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return !relative.isEmpty && !relative.contains("/")
        }
    }

    private static func path(_ child: String, isInside parent: String) -> Bool {
        let normalizedChild = canonicalFileURL(URL(fileURLWithPath: child)).path
        let normalizedParent = canonicalFileURL(URL(fileURLWithPath: parent)).path
        let parentPrefix = normalizedParent == "/" ? "/" : normalizedParent + "/"
        return normalizedChild == normalizedParent
            || normalizedChild.hasPrefix(parentPrefix)
    }

    private static func isSafeDeletionRecoverySource(
        _ recovery: URL,
        original: URL,
        historyRoot: URL
    ) -> Bool {
        let recoveryURL = canonicalFileURL(recovery)
        let recoveryPath = recoveryURL.path
        let originalURL = canonicalFileURL(original)
        guard recoveryURL.lastPathComponent == originalURL.lastPathComponent,
              !path(recoveryPath, isInside: canonicalFileURL(historyRoot).path) else {
            return false
        }
        return deletionRecoveryTrashRoots().contains { root in
            path(recoveryPath, isInside: root.path)
        }
    }

    private static func deletionRecoveryTrashRoots() -> [URL] {
        let homeTrash = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
        return [canonicalFileURL(homeTrash)]
    }

    private static func canonicalFileURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private enum SourcePresence {
        case exists
        case missing
        case inaccessible
    }

    private func missingSourceCleanupItems(
        historyRootURL: URL? = nil
    ) throws -> [MissingSourceCleanupItemDTO] {
        let historyPaths = CodexHistoryPaths(
            rootURL: historyRootURL ?? CodexHistoryRootResolver.resolveRootURL()
        )
        let rows = try database.executeQuery(
            sql: """
            SELECT source_path, relative_path, bucket, status
            FROM codex_import_sources
            WHERE status != 'tombstoned'
            ORDER BY source_path ASC;
            """
        ) { stmt -> (String, String, SessionBucket, String) in
            let sourcePath = sqlite3_column_type(stmt, 0) != SQLITE_NULL && sqlite3_column_text(stmt, 0) != nil
                ? String(cString: sqlite3_column_text(stmt, 0)!)
                : ""
            let relativePath = sqlite3_column_type(stmt, 1) != SQLITE_NULL && sqlite3_column_text(stmt, 1) != nil
                ? String(cString: sqlite3_column_text(stmt, 1)!)
                : ""
            let bucketRaw = sqlite3_column_type(stmt, 2) != SQLITE_NULL && sqlite3_column_text(stmt, 2) != nil
                ? String(cString: sqlite3_column_text(stmt, 2)!)
                : SessionBucket.active.rawValue
            let status = sqlite3_column_type(stmt, 3) != SQLITE_NULL && sqlite3_column_text(stmt, 3) != nil
                ? String(cString: sqlite3_column_text(stmt, 3)!)
                : ""
            return (
                sourcePath,
                relativePath,
                SessionBucket(rawValue: bucketRaw) ?? .active,
                status
            )
        }

        var items: [MissingSourceCleanupItemDTO] = []
        for row in rows {
            guard Self.sourcePresence(
                sourcePath: row.0,
                relativePath: row.1,
                historyPaths: historyPaths
            ) == .missing else {
                continue
            }
            let affected = try database.executeQuery(
                sql: """
                SELECT
                    COUNT(*),
                    COALESCE(SUM(total_tokens), 0),
                    COALESCE(SUM(estimated_cost_usd_nano), 0)
                FROM codex_sessions
                WHERE source_path = ? OR relative_path = ?;
                """,
                bindings: [row.0, row.1]
            ) { stmt -> (Int, Int64, Int64) in
                (
                    Int(sqlite3_column_int(stmt, 0)),
                    sqlite3_column_int64(stmt, 1),
                    sqlite3_column_int64(stmt, 2)
                )
            }.first ?? (0, 0, 0)
            items.append(
                MissingSourceCleanupItemDTO(
                    sourcePath: row.0,
                    relativePath: row.1,
                    bucket: row.2,
                    sessionCount: affected.0,
                    totalTokens: affected.1,
                    estimatedCost: MoneyNanoUSD(affected.2),
                    status: row.3
                )
            )
        }
        return items
    }

    private static func sourcePresence(
        sourcePath: String,
        relativePath: String,
        historyPaths: CodexHistoryPaths
    ) -> SourcePresence {
        let rootURL = historyPaths.rootURL.standardizedFileURL
        let candidates: [URL] = [
            sourcePath.isEmpty ? nil : (sourcePath.hasPrefix("/")
                ? URL(fileURLWithPath: sourcePath)
                : rootURL.appendingPathComponent(sourcePath)),
            relativePath.isEmpty ? nil : rootURL.appendingPathComponent(relativePath)
        ].compactMap { $0 }
        guard !candidates.isEmpty else { return .missing }

        var sawInaccessible = false
        for candidate in candidates {
            switch filePresence(at: candidate) {
            case .exists:
                return .exists
            case .inaccessible:
                sawInaccessible = true
            case .missing:
                continue
            }
        }
        return sawInaccessible ? .inaccessible : .missing
    }

    private static func filePresence(at url: URL) -> SourcePresence {
        let path = url.standardizedFileURL.path
        if FileManager.default.fileExists(atPath: path) {
            return .exists
        }
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path)
            return .exists
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               (nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError) {
                return .missing
            }
            if nsError.domain == NSPOSIXErrorDomain, nsError.code == ENOENT {
                return .missing
            }
            return .inaccessible
        }
    }

    private static func missingSourcePreviewId(items: [MissingSourceCleanupItemDTO]) -> String {
        var payload = ""
        for item in items.sorted(by: { $0.sourcePath < $1.sourcePath }) {
            payload += [
                item.sourcePath,
                item.relativePath,
                item.bucket.rawValue,
                item.status,
                String(item.sessionCount),
                String(item.totalTokens),
                String(item.estimatedCost.rawValue)
            ].joined(separator: "\u{1F}") + "\n"
        }
        return SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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
        let cacheWriteTok = sqlite3_column_int64(stmt, 12)
        let outTok = sqlite3_column_int64(stmt, 13)
        let reasonTok = sqlite3_column_int64(stmt, 14)
        let totTok = sqlite3_column_int64(stmt, 15)
        let costNano = sqlite3_column_int64(stmt, 16)
        let ruleId = sqlite3_column_type(stmt, 17) != SQLITE_NULL && sqlite3_column_text(stmt, 17) != nil
            ? String(cString: sqlite3_column_text(stmt, 17)!) : nil
        let pStatus = String(cString: sqlite3_column_text(stmt, 18))
        let deriv = String(cString: sqlite3_column_text(stmt, 19))
        let attrib = String(cString: sqlite3_column_text(stmt, 20))
        let isReplay = sqlite3_column_int(stmt, 21) != 0
        let src = String(cString: sqlite3_column_text(stmt, 22))
        let offset = sqlite3_column_int64(stmt, 23)
        let timestampQualityRaw = sqlite3_column_type(stmt, 24) != SQLITE_NULL && sqlite3_column_text(stmt, 24) != nil
            ? String(cString: sqlite3_column_text(stmt, 24)!)
            : TimestampQuality.eventTimestamp.rawValue
        let timestampSourceRaw = sqlite3_column_type(stmt, 25) != SQLITE_NULL && sqlite3_column_text(stmt, 25) != nil
            ? String(cString: sqlite3_column_text(stmt, 25)!)
            : TimestampSource.topLevelTimestamp.rawValue
        let timestampConflictCount = Int(sqlite3_column_int(stmt, 26))
        let catalogVersion = sqlite3_column_type(stmt, 27) != SQLITE_NULL && sqlite3_column_text(stmt, 27) != nil
            ? String(cString: sqlite3_column_text(stmt, 27)!)
            : nil
        let providerRaw = sqlite3_column_count(stmt) >= 29
            && sqlite3_column_type(stmt, 28) != SQLITE_NULL
            && sqlite3_column_text(stmt, 28) != nil
            ? String(cString: sqlite3_column_text(stmt, 28)!)
            : UsageProvider.codex.rawValue

        return CodexUsageEventDTO(
            eventId: eid,
            provider: UsageProvider(rawValue: providerRaw) ?? .codex,
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
                cacheWriteInputTokens: cacheWriteTok,
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
            timestampSource: TimestampSource(rawValue: timestampSourceRaw) ?? .topLevelTimestamp,
            timestampConflictCount: timestampConflictCount,
            isChildReplay: isReplay,
            sourcePath: src,
            lineOffset: offset
        )
    }
}
