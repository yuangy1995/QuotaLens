// QuotaLens 价格目录同步服务与 API 等价价值估算器
// 将官方价格规则同步至 SQLite，并提供精确 nano-USD 计算

import Foundation
import CryptoKit
import SQLite3

public final class PricingCatalogService: Sendable {
    public static let shared = PricingCatalogService()

    public init() {}

    /// 确保当前版本的价格目录已完整安装至本地数据库
    public func ensureCatalogInstalled(database: SQLiteDatabase) throws {
        let catalog = BundledPricingCatalog.defaultCatalog
        let rawJSON = try Self.rawJSONString(for: catalog)
        let catalogSHA = Self.sha256Hex(rawJSON)
        let installedSHA = try database.stringScalar(
            sql: "SELECT catalog_sha256 FROM codex_pricing_catalogs WHERE catalog_version = ?;",
            bindings: [catalog.catalogVersion]
        )
        let repriceNeeded = try catalogNeedsReprice(database: database, catalogVersion: catalog.catalogVersion)

        if installedSHA == catalogSHA {
            try database.transaction {
                try database.executeUpdate(
                    sql: "UPDATE codex_pricing_catalogs SET is_active = CASE WHEN catalog_version = ? THEN 1 ELSE 0 END;",
                    bindings: [catalog.catalogVersion]
                )
                try database.executeUpdate(
                    sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('pricing_catalog_generation', ?, unixepoch());",
                    bindings: [catalog.catalogVersion]
                )
            }
            if repriceNeeded {
                try repriceAllUsageEvents(database: database)
            }
            return
        }

        try database.transaction {
            // 同版本 digest 不同只可能来自未发布开发构建或不完整安装；仅修复当前版本。
            try database.executeUpdate(
                sql: "DELETE FROM codex_model_aliases WHERE catalog_version = ?;",
                bindings: [catalog.catalogVersion]
            )
            try database.executeUpdate(
                sql: "DELETE FROM codex_pricing_rules WHERE catalog_version = ?;",
                bindings: [catalog.catalogVersion]
            )
            // 1. 插入价格目录
            try database.executeUpdate(
                sql: """
                INSERT OR REPLACE INTO codex_pricing_catalogs (
                    catalog_version, schema_version, published_at, catalog_sha256, is_active, raw_json
                ) VALUES (?, ?, ?, ?, 1, ?);
                """,
                bindings: [
                    catalog.catalogVersion,
                    catalog.schemaVersion,
                    catalog.publishedAt,
                    catalogSHA,
                    rawJSON
                ]
            )

            // 将其他目录置为非活跃
            try database.executeUpdate(
                sql: "UPDATE codex_pricing_catalogs SET is_active = CASE WHEN catalog_version = ? THEN 1 ELSE 0 END;",
                bindings: [catalog.catalogVersion]
            )

            // 2. 插入别名与规则
            for modelEntry in catalog.models {
                for alias in modelEntry.aliases {
                    try database.executeUpdate(
                        sql: """
                        INSERT OR REPLACE INTO codex_model_aliases (
                            alias_pattern, target_model_key, match_type, catalog_version
                        ) VALUES (?, ?, 'exact', ?);
                        """,
                        bindings: [alias.lowercased(), modelEntry.modelKey, catalog.catalogVersion]
                    )
                }

                for rule in modelEntry.rules {
                    try database.executeUpdate(
                        sql: """
                        INSERT OR REPLACE INTO codex_pricing_rules (
                            rule_id, model_key, service_tier, effective_from_ms, effective_to_ms,
                            input_usd_nano_per_token, cached_usd_nano_per_token, cache_write_usd_nano_per_token,
                            output_usd_nano_per_token, rate_divisor, maximum_input_tokens,
                            long_context_threshold_tokens,
                            long_context_input_multiplier_ppm, long_context_output_multiplier_ppm,
                            catalog_version
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                        """,
                        bindings: [
                            rule.ruleId,
                            modelEntry.modelKey,
                            rule.serviceTier,
                            rule.effectiveFromMs,
                            rule.effectiveToMs,
                            rule.inputNanoUsdPerToken,
                            rule.cachedNanoUsdPerToken,
                            rule.cacheWriteNanoUsdPerToken,
                            rule.outputNanoUsdPerToken,
                            rule.rateDivisor,
                            rule.maximumInputTokens,
                            rule.longContextThresholdTokens,
                            rule.longContextInputMultiplierPpm,
                            rule.longContextOutputMultiplierPpm,
                            catalog.catalogVersion
                        ]
                    )
                }
            }

            // 递增定价版本代号
            try database.executeUpdate(
                sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('pricing_catalog_generation', ?, unixepoch());",
                bindings: [catalog.catalogVersion]
            )
        }
        try repriceAllUsageEvents(database: database)
    }

    /// 可恢复的全量重计价入口；每个 batch 独立提交，最后短事务切换正式结果。
    public func repriceAllUsageEvents(
        database: SQLiteDatabase,
        batchSize: Int = 500,
        simulatedFailureAfterBatches: Int? = nil
    ) throws {
        let snapshot = try loadSnapshot(database: database)
        let normalizedBatchSize = max(1, batchSize)
        try ensureRepriceShadowTables(database: database)
        try prepareRepriceRunIfNeeded(database: database, catalogVersion: snapshot.catalogVersion)

        do {
            var completedBatches = 0
            while true {
                let lastRowID = try database.int64Scalar(
                    sql: "SELECT value FROM app_metadata WHERE key = 'pricing_reprice_last_rowid';"
                ) ?? 0
                let rows = try loadRepriceEventRows(database: database, lastRowID: lastRowID, limit: normalizedBatchSize)
                guard !rows.isEmpty else { break }

                try database.transaction {
                    for row in rows {
                        let price = snapshot.evaluate(
                            modelCanonical: row.modelCanonical,
                            serviceTier: row.serviceTier,
                            timestampMs: row.timestampMs,
                            tokens: row.tokens
                        )
                        try database.executeUpdate(
                            sql: """
                            INSERT OR REPLACE INTO codex_usage_event_reprice_shadow (
                                source_rowid, event_id, estimated_cost_usd_nano,
                                pricing_rule_id, pricing_status, pricing_catalog_version
                            ) VALUES (?, ?, ?, ?, ?, ?);
                            """,
                            bindings: [
                                row.rowID,
                                row.eventID,
                                price.estimatedCost.rawValue,
                                price.pricingRuleId,
                                price.pricingStatus.rawValue,
                                price.catalogVersion
                            ]
                        )
                    }
                    let finalRowID = rows.last?.rowID ?? lastRowID
                    let processed = try database.intScalar(
                        sql: "SELECT COUNT(*) FROM codex_usage_event_reprice_shadow;"
                    )
                    try updateRepriceMetadata(
                        database: database,
                        status: "running",
                        catalogVersion: snapshot.catalogVersion,
                        lastRowID: finalRowID,
                        processedEvents: processed,
                        totalEvents: nil,
                        error: nil
                    )
                }

                completedBatches += 1
                if let simulatedFailureAfterBatches, completedBatches >= simulatedFailureAfterBatches {
                    throw NSError(
                        domain: "QuotaLens.PricingReprice",
                        code: 1001,
                        userInfo: [NSLocalizedDescriptionKey: "simulated reprice interruption"]
                    )
                }
            }

            try rebuildShadowSummaries(database: database)
            try publishRepriceResults(database: database, catalogVersion: snapshot.catalogVersion)
        } catch {
            try? updateRepriceMetadata(
                database: database,
                status: "failed",
                catalogVersion: snapshot.catalogVersion,
                lastRowID: nil,
                processedEvents: nil,
                totalEvents: nil,
                error: error.localizedDescription
            )
            throw error
        }
    }

    public func loadSnapshot(database: SQLiteDatabase) throws -> PricingCatalogSnapshot {
        let activeCatalog = try activeCatalogVersion(database: database)

        let aliases = try database.executeQuery(
            sql: """
            SELECT alias_pattern, target_model_key
            FROM codex_model_aliases
            WHERE catalog_version = ?
            ORDER BY alias_pattern ASC;
            """,
            bindings: [activeCatalog]
        ) { stmt -> (String, String) in
            (
                String(cString: sqlite3_column_text(stmt, 0)).lowercased(),
                String(cString: sqlite3_column_text(stmt, 1)).lowercased()
            )
        }

        var aliasMap: [String: String] = [:]
        for (alias, target) in aliases where aliasMap[alias] == nil {
            aliasMap[alias] = target
        }

        let ruleRows = try database.executeQuery(
            sql: """
            SELECT
                model_key, rule_id, service_tier, effective_from_ms, effective_to_ms,
                input_usd_nano_per_token, cached_usd_nano_per_token,
                cache_write_usd_nano_per_token, output_usd_nano_per_token,
                rate_divisor, maximum_input_tokens, long_context_threshold_tokens,
                long_context_input_multiplier_ppm,
                long_context_output_multiplier_ppm
            FROM codex_pricing_rules
            WHERE catalog_version = ?
            ORDER BY model_key ASC, effective_from_ms DESC;
            """,
            bindings: [activeCatalog]
        ) { stmt -> (String, PricingRuleEntry) in
            let modelKey = String(cString: sqlite3_column_text(stmt, 0)).lowercased()
            let tier = sqlite3_column_type(stmt, 2) != SQLITE_NULL && sqlite3_column_text(stmt, 2) != nil
                ? String(cString: sqlite3_column_text(stmt, 2)!).lowercased()
                : nil
            let effectiveTo = sqlite3_column_type(stmt, 4) != SQLITE_NULL
                ? sqlite3_column_int64(stmt, 4)
                : nil
            let cacheWrite = sqlite3_column_type(stmt, 7) != SQLITE_NULL
                ? sqlite3_column_int64(stmt, 7)
                : nil
            let maximumInputTokens = sqlite3_column_type(stmt, 10) != SQLITE_NULL
                ? sqlite3_column_int64(stmt, 10)
                : nil
            let longThreshold = sqlite3_column_type(stmt, 11) != SQLITE_NULL
                ? sqlite3_column_int64(stmt, 11)
                : nil
            let longInputMultiplier = sqlite3_column_type(stmt, 12) != SQLITE_NULL
                ? sqlite3_column_int64(stmt, 12)
                : nil
            let longOutputMultiplier = sqlite3_column_type(stmt, 13) != SQLITE_NULL
                ? sqlite3_column_int64(stmt, 13)
                : nil
            return (
                modelKey,
                PricingRuleEntry(
                    ruleId: String(cString: sqlite3_column_text(stmt, 1)),
                    serviceTier: tier,
                    effectiveFromMs: sqlite3_column_int64(stmt, 3),
                    effectiveToMs: effectiveTo,
                    inputNanoUsdPerToken: sqlite3_column_int64(stmt, 5),
                    cachedNanoUsdPerToken: sqlite3_column_int64(stmt, 6),
                    cacheWriteNanoUsdPerToken: cacheWrite,
                    outputNanoUsdPerToken: sqlite3_column_int64(stmt, 8),
                    rateDivisor: sqlite3_column_int64(stmt, 9),
                    maximumInputTokens: maximumInputTokens,
                    longContextThresholdTokens: longThreshold,
                    longContextInputMultiplierPpm: longInputMultiplier,
                    longContextOutputMultiplierPpm: longOutputMultiplier
                )
            )
        }

        var rulesByModel: [String: [PricingRuleEntry]] = [:]
        for (modelKey, rule) in ruleRows {
            rulesByModel[modelKey, default: []].append(rule)
        }

        return PricingCatalogSnapshot(catalogVersion: activeCatalog, aliases: aliasMap, rulesByModel: rulesByModel)
    }

    /// 使用已安装到 SQLite 的版本化价格目录评估单条事件。
    public func evaluate(
        database: SQLiteDatabase,
        modelCanonical: String,
        serviceTier: String?,
        timestampMs: Int64,
        tokens: TokenBreakdown
    ) throws -> PricingEvaluationResult {
        try loadSnapshot(database: database).evaluate(
            modelCanonical: modelCanonical,
            serviceTier: serviceTier,
            timestampMs: timestampMs,
            tokens: tokens
        )
    }

    private func activeCatalogVersion(database: SQLiteDatabase) throws -> String {
        if let active = try database.stringScalar(
            sql: "SELECT catalog_version FROM codex_pricing_catalogs WHERE is_active = 1 ORDER BY published_at DESC LIMIT 1;"
        ) {
            return active
        }
        return BundledPricingCatalog.currentVersion
    }

    private func catalogNeedsReprice(database: SQLiteDatabase, catalogVersion: String) throws -> Bool {
        let repricedCatalog = try database.stringScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'pricing_reprice_catalog_version';"
        )
        guard repricedCatalog == catalogVersion else { return true }
        let staleEventCount = try database.intScalar(
            sql: """
            SELECT COUNT(*)
            FROM codex_usage_events
            WHERE COALESCE(pricing_catalog_version, '') != ?;
            """,
            bindings: [catalogVersion]
        )
        return staleEventCount > 0
    }

    private struct RepriceEventRow {
        let rowID: Int64
        let eventID: String
        let modelCanonical: String
        let serviceTier: String?
        let timestampMs: Int64
        let tokens: TokenBreakdown
    }

    private struct RepriceSummaryKey: Hashable {
        let sessionId: String
        let modelCanonical: String
    }

    private struct RepriceDailySummaryKey: Hashable {
        let sessionId: String
        let dayKey: String
        let dayStartMs: Int64
        let modelCanonical: String
    }

    private struct RepriceSummaryAggregate {
        var eventCount = 0
        var totalTokens: Int64 = 0
        var uncachedInputTokens: Int64 = 0
        var cachedInputTokens: Int64 = 0
        var cacheWriteInputTokens: Int64 = 0
        var outputTokens: Int64 = 0
        var reasoningOutputTokens: Int64 = 0
        var estimatedCostNano: Int64 = 0
        var unpricedEventCount = 0
        var unpricedTokenCount: Int64 = 0
        var reasons = UnpricedReasonCounts.zero

        mutating func add(tokens: TokenBreakdown, cost: Int64, pricingStatus: PricingStatus) {
            eventCount += 1
            totalTokens += tokens.canonicalTotalTokens
            uncachedInputTokens += tokens.uncachedInputTokens
            cachedInputTokens += tokens.cachedInputTokens
            cacheWriteInputTokens += tokens.cacheWriteInputTokens
            outputTokens += tokens.outputTokens
            reasoningOutputTokens += tokens.reasoningOutputTokens
            estimatedCostNano += cost
            if !pricingStatus.isPriced {
                unpricedEventCount += 1
                unpricedTokenCount += tokens.canonicalTotalTokens
                reasons.add(status: pricingStatus, tokenCount: tokens.canonicalTotalTokens)
            }
        }
    }

    private func ensureRepriceShadowTables(database: SQLiteDatabase) throws {
        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS codex_usage_event_reprice_shadow (
            source_rowid INTEGER PRIMARY KEY,
            event_id TEXT NOT NULL UNIQUE,
            estimated_cost_usd_nano INTEGER NOT NULL,
            pricing_rule_id TEXT,
            pricing_status TEXT NOT NULL,
            pricing_catalog_version TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS codex_session_summaries_reprice_shadow (
            session_id TEXT NOT NULL,
            model_canonical TEXT NOT NULL,
            event_count INTEGER NOT NULL DEFAULT 0,
            total_tokens INTEGER NOT NULL DEFAULT 0,
            uncached_input_tokens INTEGER NOT NULL DEFAULT 0,
            cached_input_tokens INTEGER NOT NULL DEFAULT 0,
            cache_write_input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_output_tokens INTEGER NOT NULL DEFAULT 0,
            estimated_cost_usd_nano INTEGER NOT NULL DEFAULT 0,
            unpriced_event_count INTEGER NOT NULL DEFAULT 0,
            unpriced_token_count INTEGER NOT NULL DEFAULT 0,
            unpriced_unknown_model_event_count INTEGER NOT NULL DEFAULT 0,
            unpriced_unknown_model_token_count INTEGER NOT NULL DEFAULT 0,
            unpriced_unsupported_tier_event_count INTEGER NOT NULL DEFAULT 0,
            unpriced_unsupported_tier_token_count INTEGER NOT NULL DEFAULT 0,
            unpriced_historical_rule_missing_event_count INTEGER NOT NULL DEFAULT 0,
            unpriced_historical_rule_missing_token_count INTEGER NOT NULL DEFAULT 0,
            unpriced_unsupported_context_event_count INTEGER NOT NULL DEFAULT 0,
            unpriced_unsupported_context_token_count INTEGER NOT NULL DEFAULT 0,
            unpriced_invalid_record_event_count INTEGER NOT NULL DEFAULT 0,
            unpriced_invalid_record_token_count INTEGER NOT NULL DEFAULT 0,
            unpriced_overflow_event_count INTEGER NOT NULL DEFAULT 0,
            unpriced_overflow_token_count INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(session_id, model_canonical)
        );

        CREATE TABLE IF NOT EXISTS codex_daily_usage_summaries_reprice_shadow (
            session_id TEXT NOT NULL,
            day_key TEXT NOT NULL,
            day_start_ms INTEGER NOT NULL,
            model_canonical TEXT NOT NULL,
            event_count INTEGER NOT NULL DEFAULT 0,
            total_tokens INTEGER NOT NULL DEFAULT 0,
            uncached_input_tokens INTEGER NOT NULL DEFAULT 0,
            cached_input_tokens INTEGER NOT NULL DEFAULT 0,
            cache_write_input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_output_tokens INTEGER NOT NULL DEFAULT 0,
            estimated_cost_usd_nano INTEGER NOT NULL DEFAULT 0,
            unpriced_event_count INTEGER NOT NULL DEFAULT 0,
            unpriced_token_count INTEGER NOT NULL DEFAULT 0,
            unpriced_unknown_model_event_count INTEGER NOT NULL DEFAULT 0,
            unpriced_unknown_model_token_count INTEGER NOT NULL DEFAULT 0,
            unpriced_unsupported_tier_event_count INTEGER NOT NULL DEFAULT 0,
            unpriced_unsupported_tier_token_count INTEGER NOT NULL DEFAULT 0,
            unpriced_historical_rule_missing_event_count INTEGER NOT NULL DEFAULT 0,
            unpriced_historical_rule_missing_token_count INTEGER NOT NULL DEFAULT 0,
            unpriced_unsupported_context_event_count INTEGER NOT NULL DEFAULT 0,
            unpriced_unsupported_context_token_count INTEGER NOT NULL DEFAULT 0,
            unpriced_invalid_record_event_count INTEGER NOT NULL DEFAULT 0,
            unpriced_invalid_record_token_count INTEGER NOT NULL DEFAULT 0,
            unpriced_overflow_event_count INTEGER NOT NULL DEFAULT 0,
            unpriced_overflow_token_count INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(session_id, day_key, model_canonical)
        );
        """)
    }

    private func prepareRepriceRunIfNeeded(database: SQLiteDatabase, catalogVersion: String) throws {
        let stateCatalog = try database.stringScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'pricing_reprice_target_catalog_version';"
        )
        let status = try database.stringScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'pricing_reprice_status';"
        )
        let totalEvents = try database.intScalar(sql: "SELECT COUNT(*) FROM codex_usage_events;")
        let shadowEventCount = try database.intScalar(sql: "SELECT COUNT(*) FROM codex_usage_event_reprice_shadow;")
        let canResume = stateCatalog == catalogVersion && (status == "failed" || status == "running")
            && shadowEventCount > 0
        guard canResume == false else {
            try updateRepriceMetadata(
                database: database,
                status: "running",
                catalogVersion: catalogVersion,
                lastRowID: nil,
                processedEvents: nil,
                totalEvents: totalEvents,
                error: nil
            )
            return
        }

        try database.transaction {
            try database.execute(sql: """
            DELETE FROM codex_usage_event_reprice_shadow;
            DELETE FROM codex_session_summaries_reprice_shadow;
            DELETE FROM codex_daily_usage_summaries_reprice_shadow;
            """)
            let previousGeneration = try database.int64Scalar(
                sql: "SELECT value FROM app_metadata WHERE key = 'pricing_reprice_generation';"
            ) ?? 0
            let nextGeneration = previousGeneration + 1
            try database.executeUpdate(
                sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('pricing_reprice_generation', ?, unixepoch());",
                bindings: [String(nextGeneration)]
            )
            try updateRepriceMetadata(
                database: database,
                status: "running",
                catalogVersion: catalogVersion,
                lastRowID: 0,
                processedEvents: 0,
                totalEvents: totalEvents,
                error: nil
            )
        }
    }

    private func loadRepriceEventRows(
        database: SQLiteDatabase,
        lastRowID: Int64,
        limit: Int
    ) throws -> [RepriceEventRow] {
        try database.executeQuery(
            sql: """
            SELECT
                rowid, event_id, model_canonical, service_tier, timestamp_ms,
                input_tokens, cached_input_tokens, cache_write_input_tokens,
                output_tokens, reasoning_output_tokens, total_tokens
            FROM codex_usage_events
            WHERE rowid > ?
            ORDER BY rowid ASC
            LIMIT ?;
            """,
            bindings: [lastRowID, limit]
        ) { stmt -> RepriceEventRow in
            let tier = sqlite3_column_type(stmt, 3) != SQLITE_NULL && sqlite3_column_text(stmt, 3) != nil
                ? String(cString: sqlite3_column_text(stmt, 3)!)
                : nil
            let total = sqlite3_column_int64(stmt, 10)
            return RepriceEventRow(
                rowID: sqlite3_column_int64(stmt, 0),
                eventID: String(cString: sqlite3_column_text(stmt, 1)),
                modelCanonical: String(cString: sqlite3_column_text(stmt, 2)),
                serviceTier: tier,
                timestampMs: sqlite3_column_int64(stmt, 4),
                tokens: TokenBreakdown(
                    inputTokens: sqlite3_column_int64(stmt, 5),
                    cachedInputTokens: sqlite3_column_int64(stmt, 6),
                    cacheWriteInputTokens: sqlite3_column_int64(stmt, 7),
                    outputTokens: sqlite3_column_int64(stmt, 8),
                    reasoningOutputTokens: sqlite3_column_int64(stmt, 9),
                    sourceTotalTokens: total
                )
            )
        }
    }

    private func rebuildShadowSummaries(database: SQLiteDatabase) throws {
        try database.execute(sql: """
        DELETE FROM codex_session_summaries_reprice_shadow;
        DELETE FROM codex_daily_usage_summaries_reprice_shadow;
        """)

        let timeZone = TimeZone.current
        let calendar = UsageDayBucketer.calendar(timeZone: timeZone)
        var sessionSummaries: [RepriceSummaryKey: RepriceSummaryAggregate] = [:]
        var dailySummaries: [RepriceDailySummaryKey: RepriceSummaryAggregate] = [:]

        let rows = try database.executeQuery(
            sql: """
            SELECT
                e.session_id, e.model_canonical, e.timestamp_ms,
                e.input_tokens, e.cached_input_tokens, e.cache_write_input_tokens,
                e.output_tokens, e.reasoning_output_tokens, e.total_tokens,
                r.estimated_cost_usd_nano, r.pricing_status
            FROM codex_usage_events e
            JOIN codex_usage_event_reprice_shadow r ON r.source_rowid = e.rowid
            WHERE e.is_child_replay = 0
            ORDER BY e.rowid ASC;
            """
        ) { stmt -> (String, String, Int64, TokenBreakdown, Int64, PricingStatus) in
            let total = sqlite3_column_int64(stmt, 8)
            let status = PricingStatus(rawValue: String(cString: sqlite3_column_text(stmt, 10))) ?? .unpricedUnknownModel
            return (
                String(cString: sqlite3_column_text(stmt, 0)),
                String(cString: sqlite3_column_text(stmt, 1)),
                sqlite3_column_int64(stmt, 2),
                TokenBreakdown(
                    inputTokens: sqlite3_column_int64(stmt, 3),
                    cachedInputTokens: sqlite3_column_int64(stmt, 4),
                    cacheWriteInputTokens: sqlite3_column_int64(stmt, 5),
                    outputTokens: sqlite3_column_int64(stmt, 6),
                    reasoningOutputTokens: sqlite3_column_int64(stmt, 7),
                    sourceTotalTokens: total
                ),
                sqlite3_column_int64(stmt, 9),
                status
            )
        }

        for row in rows {
            let sessionKey = RepriceSummaryKey(sessionId: row.0, modelCanonical: row.1)
            var sessionAggregate = sessionSummaries[sessionKey] ?? RepriceSummaryAggregate()
            sessionAggregate.add(tokens: row.3, cost: row.4, pricingStatus: row.5)
            sessionSummaries[sessionKey] = sessionAggregate

            let bucket = UsageDayBucketer.bucket(timestampMs: row.2, calendar: calendar, timeZone: timeZone)
            let dailyKey = RepriceDailySummaryKey(
                sessionId: row.0,
                dayKey: bucket.dayKey.yyyyMMdd,
                dayStartMs: bucket.dayStartMs,
                modelCanonical: row.1
            )
            var dailyAggregate = dailySummaries[dailyKey] ?? RepriceSummaryAggregate()
            dailyAggregate.add(tokens: row.3, cost: row.4, pricingStatus: row.5)
            dailySummaries[dailyKey] = dailyAggregate
        }

        try database.transaction {
            for (key, aggregate) in sessionSummaries {
                try insertSessionSummaryShadow(database: database, key: key, aggregate: aggregate)
            }
            for (key, aggregate) in dailySummaries {
                try insertDailySummaryShadow(database: database, key: key, aggregate: aggregate)
            }
        }
    }

    private func publishRepriceResults(database: SQLiteDatabase, catalogVersion: String) throws {
        let previousTimezone = try database.stringScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'usage_aggregation_timezone_id';"
        )
        let currentTimezone = TimeZone.current.identifier
        let timezoneGeneration = try database.int64Scalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'usage_aggregation_timezone_generation';"
        ) ?? 0
        let nextTimezoneGeneration = previousTimezone == nil || previousTimezone == currentTimezone
            ? timezoneGeneration
            : timezoneGeneration + 1

        try database.transaction {
            try database.execute(sql: """
            UPDATE codex_usage_events
            SET estimated_cost_usd_nano = (
                    SELECT estimated_cost_usd_nano FROM codex_usage_event_reprice_shadow r
                    WHERE r.source_rowid = codex_usage_events.rowid
                ),
                pricing_rule_id = (
                    SELECT pricing_rule_id FROM codex_usage_event_reprice_shadow r
                    WHERE r.source_rowid = codex_usage_events.rowid
                ),
                pricing_status = (
                    SELECT pricing_status FROM codex_usage_event_reprice_shadow r
                    WHERE r.source_rowid = codex_usage_events.rowid
                ),
                pricing_catalog_version = (
                    SELECT pricing_catalog_version FROM codex_usage_event_reprice_shadow r
                    WHERE r.source_rowid = codex_usage_events.rowid
                )
            WHERE rowid IN (SELECT source_rowid FROM codex_usage_event_reprice_shadow);

            DELETE FROM codex_session_summaries;
            DELETE FROM codex_daily_usage_summaries;

            INSERT INTO codex_session_summaries (
                session_id, model_canonical, event_count, total_tokens,
                uncached_input_tokens, cached_input_tokens, cache_write_input_tokens,
                output_tokens, reasoning_output_tokens, estimated_cost_usd_nano,
                unpriced_event_count, unpriced_token_count,
                unpriced_unknown_model_event_count, unpriced_unknown_model_token_count,
                unpriced_unsupported_tier_event_count, unpriced_unsupported_tier_token_count,
                unpriced_historical_rule_missing_event_count, unpriced_historical_rule_missing_token_count,
                unpriced_unsupported_context_event_count, unpriced_unsupported_context_token_count,
                unpriced_invalid_record_event_count, unpriced_invalid_record_token_count,
                unpriced_overflow_event_count, unpriced_overflow_token_count
            )
            SELECT
                session_id, model_canonical, event_count, total_tokens,
                uncached_input_tokens, cached_input_tokens, cache_write_input_tokens,
                output_tokens, reasoning_output_tokens, estimated_cost_usd_nano,
                unpriced_event_count, unpriced_token_count,
                unpriced_unknown_model_event_count, unpriced_unknown_model_token_count,
                unpriced_unsupported_tier_event_count, unpriced_unsupported_tier_token_count,
                unpriced_historical_rule_missing_event_count, unpriced_historical_rule_missing_token_count,
                unpriced_unsupported_context_event_count, unpriced_unsupported_context_token_count,
                unpriced_invalid_record_event_count, unpriced_invalid_record_token_count,
                unpriced_overflow_event_count, unpriced_overflow_token_count
            FROM codex_session_summaries_reprice_shadow;

            INSERT INTO codex_daily_usage_summaries (
                session_id, day_key, day_start_ms, model_canonical, event_count, total_tokens,
                uncached_input_tokens, cached_input_tokens, cache_write_input_tokens,
                output_tokens, reasoning_output_tokens, estimated_cost_usd_nano,
                unpriced_event_count, unpriced_token_count,
                unpriced_unknown_model_event_count, unpriced_unknown_model_token_count,
                unpriced_unsupported_tier_event_count, unpriced_unsupported_tier_token_count,
                unpriced_historical_rule_missing_event_count, unpriced_historical_rule_missing_token_count,
                unpriced_unsupported_context_event_count, unpriced_unsupported_context_token_count,
                unpriced_invalid_record_event_count, unpriced_invalid_record_token_count,
                unpriced_overflow_event_count, unpriced_overflow_token_count
            )
            SELECT
                session_id, day_key, day_start_ms, model_canonical, event_count, total_tokens,
                uncached_input_tokens, cached_input_tokens, cache_write_input_tokens,
                output_tokens, reasoning_output_tokens, estimated_cost_usd_nano,
                unpriced_event_count, unpriced_token_count,
                unpriced_unknown_model_event_count, unpriced_unknown_model_token_count,
                unpriced_unsupported_tier_event_count, unpriced_unsupported_tier_token_count,
                unpriced_historical_rule_missing_event_count, unpriced_historical_rule_missing_token_count,
                unpriced_unsupported_context_event_count, unpriced_unsupported_context_token_count,
                unpriced_invalid_record_event_count, unpriced_invalid_record_token_count,
                unpriced_overflow_event_count, unpriced_overflow_token_count
            FROM codex_daily_usage_summaries_reprice_shadow;
            """)

            try updateSessionsFromSummaries(database: database)
            try updateRepriceMetadata(
                database: database,
                status: "completed",
                catalogVersion: catalogVersion,
                lastRowID: nil,
                processedEvents: nil,
                totalEvents: nil,
                error: nil
            )
            try database.executeUpdate(
                sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('pricing_reprice_catalog_version', ?, unixepoch());",
                bindings: [catalogVersion]
            )
            try database.executeUpdate(
                sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('usage_aggregation_timezone_id', ?, unixepoch());",
                bindings: [currentTimezone]
            )
            try database.executeUpdate(
                sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('usage_aggregation_timezone_generation', ?, unixepoch());",
                bindings: [String(nextTimezoneGeneration)]
            )
            try database.execute(sql: """
            DELETE FROM codex_usage_event_reprice_shadow;
            DELETE FROM codex_session_summaries_reprice_shadow;
            DELETE FROM codex_daily_usage_summaries_reprice_shadow;
            """)
        }
    }

    private func updateSessionsFromSummaries(database: SQLiteDatabase) throws {
        try database.execute(sql: """
        UPDATE codex_sessions
        SET
            event_count = COALESCE((SELECT SUM(event_count) FROM codex_session_summaries s WHERE s.session_id = codex_sessions.session_id), 0),
            total_tokens = COALESCE((SELECT SUM(total_tokens) FROM codex_session_summaries s WHERE s.session_id = codex_sessions.session_id), 0),
            input_tokens = COALESCE((SELECT SUM(uncached_input_tokens + cached_input_tokens + cache_write_input_tokens) FROM codex_session_summaries s WHERE s.session_id = codex_sessions.session_id), 0),
            cached_input_tokens = COALESCE((SELECT SUM(cached_input_tokens) FROM codex_session_summaries s WHERE s.session_id = codex_sessions.session_id), 0),
            cache_write_input_tokens = COALESCE((SELECT SUM(cache_write_input_tokens) FROM codex_session_summaries s WHERE s.session_id = codex_sessions.session_id), 0),
            output_tokens = COALESCE((SELECT SUM(output_tokens) FROM codex_session_summaries s WHERE s.session_id = codex_sessions.session_id), 0),
            reasoning_output_tokens = COALESCE((SELECT SUM(reasoning_output_tokens) FROM codex_session_summaries s WHERE s.session_id = codex_sessions.session_id), 0),
            estimated_cost_usd_nano = COALESCE((SELECT SUM(estimated_cost_usd_nano) FROM codex_session_summaries s WHERE s.session_id = codex_sessions.session_id), 0),
            unpriced_unknown_model_event_count = COALESCE((SELECT SUM(unpriced_unknown_model_event_count) FROM codex_session_summaries s WHERE s.session_id = codex_sessions.session_id), 0),
            unpriced_unknown_model_token_count = COALESCE((SELECT SUM(unpriced_unknown_model_token_count) FROM codex_session_summaries s WHERE s.session_id = codex_sessions.session_id), 0),
            unpriced_unsupported_tier_event_count = COALESCE((SELECT SUM(unpriced_unsupported_tier_event_count) FROM codex_session_summaries s WHERE s.session_id = codex_sessions.session_id), 0),
            unpriced_unsupported_tier_token_count = COALESCE((SELECT SUM(unpriced_unsupported_tier_token_count) FROM codex_session_summaries s WHERE s.session_id = codex_sessions.session_id), 0),
            unpriced_historical_rule_missing_event_count = COALESCE((SELECT SUM(unpriced_historical_rule_missing_event_count) FROM codex_session_summaries s WHERE s.session_id = codex_sessions.session_id), 0),
            unpriced_historical_rule_missing_token_count = COALESCE((SELECT SUM(unpriced_historical_rule_missing_token_count) FROM codex_session_summaries s WHERE s.session_id = codex_sessions.session_id), 0),
            unpriced_unsupported_context_event_count = COALESCE((SELECT SUM(unpriced_unsupported_context_event_count) FROM codex_session_summaries s WHERE s.session_id = codex_sessions.session_id), 0),
            unpriced_unsupported_context_token_count = COALESCE((SELECT SUM(unpriced_unsupported_context_token_count) FROM codex_session_summaries s WHERE s.session_id = codex_sessions.session_id), 0),
            unpriced_invalid_record_event_count = COALESCE((SELECT SUM(unpriced_invalid_record_event_count) FROM codex_session_summaries s WHERE s.session_id = codex_sessions.session_id), 0),
            unpriced_invalid_record_token_count = COALESCE((SELECT SUM(unpriced_invalid_record_token_count) FROM codex_session_summaries s WHERE s.session_id = codex_sessions.session_id), 0),
            unpriced_overflow_event_count = COALESCE((SELECT SUM(unpriced_overflow_event_count) FROM codex_session_summaries s WHERE s.session_id = codex_sessions.session_id), 0),
            unpriced_overflow_token_count = COALESCE((SELECT SUM(unpriced_overflow_token_count) FROM codex_session_summaries s WHERE s.session_id = codex_sessions.session_id), 0),
            pricing_status = CASE
                WHEN COALESCE((SELECT SUM(event_count) FROM codex_session_summaries s WHERE s.session_id = codex_sessions.session_id), 0) = 0
                    THEN 'fullyUnpriced'
                WHEN COALESCE((SELECT SUM(unpriced_event_count) FROM codex_session_summaries s WHERE s.session_id = codex_sessions.session_id), 0) = 0
                    THEN 'fullyPriced'
                WHEN COALESCE((SELECT SUM(unpriced_event_count) FROM codex_session_summaries s WHERE s.session_id = codex_sessions.session_id), 0)
                    >= COALESCE((SELECT SUM(event_count) FROM codex_session_summaries s WHERE s.session_id = codex_sessions.session_id), 0)
                    THEN 'fullyUnpriced'
                ELSE 'partiallyPriced'
            END;
        """)
    }

    private func insertSessionSummaryShadow(
        database: SQLiteDatabase,
        key: RepriceSummaryKey,
        aggregate: RepriceSummaryAggregate
    ) throws {
        try database.executeUpdate(
            sql: Self.sessionSummaryInsertSQL(table: "codex_session_summaries_reprice_shadow"),
            bindings: [key.sessionId, key.modelCanonical] + Self.summaryBindings(aggregate)
        )
    }

    private func insertDailySummaryShadow(
        database: SQLiteDatabase,
        key: RepriceDailySummaryKey,
        aggregate: RepriceSummaryAggregate
    ) throws {
        try database.executeUpdate(
            sql: Self.dailySummaryInsertSQL(table: "codex_daily_usage_summaries_reprice_shadow"),
            bindings: [key.sessionId, key.dayKey, key.dayStartMs, key.modelCanonical] + Self.summaryBindings(aggregate)
        )
    }

    private static func summaryBindings(_ aggregate: RepriceSummaryAggregate) -> [Any?] {
        [
            aggregate.eventCount,
            aggregate.totalTokens,
            aggregate.uncachedInputTokens,
            aggregate.cachedInputTokens,
            aggregate.cacheWriteInputTokens,
            aggregate.outputTokens,
            aggregate.reasoningOutputTokens,
            aggregate.estimatedCostNano,
            aggregate.unpricedEventCount,
            aggregate.unpricedTokenCount,
            aggregate.reasons.unknownModelEvents,
            aggregate.reasons.unknownModelTokens,
            aggregate.reasons.unsupportedTierEvents,
            aggregate.reasons.unsupportedTierTokens,
            aggregate.reasons.historicalRuleMissingEvents,
            aggregate.reasons.historicalRuleMissingTokens,
            aggregate.reasons.unsupportedContextEvents,
            aggregate.reasons.unsupportedContextTokens,
            aggregate.reasons.invalidRecordEvents,
            aggregate.reasons.invalidRecordTokens,
            aggregate.reasons.overflowEvents,
            aggregate.reasons.overflowTokens
        ]
    }

    private static func sessionSummaryInsertSQL(table: String) -> String {
        """
        INSERT INTO \(table) (
            session_id, model_canonical, event_count, total_tokens,
            uncached_input_tokens, cached_input_tokens, cache_write_input_tokens,
            output_tokens, reasoning_output_tokens, estimated_cost_usd_nano,
            unpriced_event_count, unpriced_token_count,
            unpriced_unknown_model_event_count, unpriced_unknown_model_token_count,
            unpriced_unsupported_tier_event_count, unpriced_unsupported_tier_token_count,
            unpriced_historical_rule_missing_event_count, unpriced_historical_rule_missing_token_count,
            unpriced_unsupported_context_event_count, unpriced_unsupported_context_token_count,
            unpriced_invalid_record_event_count, unpriced_invalid_record_token_count,
            unpriced_overflow_event_count, unpriced_overflow_token_count
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
    }

    private static func dailySummaryInsertSQL(table: String) -> String {
        """
        INSERT INTO \(table) (
            session_id, day_key, day_start_ms, model_canonical, event_count, total_tokens,
            uncached_input_tokens, cached_input_tokens, cache_write_input_tokens,
            output_tokens, reasoning_output_tokens, estimated_cost_usd_nano,
            unpriced_event_count, unpriced_token_count,
            unpriced_unknown_model_event_count, unpriced_unknown_model_token_count,
            unpriced_unsupported_tier_event_count, unpriced_unsupported_tier_token_count,
            unpriced_historical_rule_missing_event_count, unpriced_historical_rule_missing_token_count,
            unpriced_unsupported_context_event_count, unpriced_unsupported_context_token_count,
            unpriced_invalid_record_event_count, unpriced_invalid_record_token_count,
            unpriced_overflow_event_count, unpriced_overflow_token_count
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
    }

    private func updateRepriceMetadata(
        database: SQLiteDatabase,
        status: String,
        catalogVersion: String,
        lastRowID: Int64?,
        processedEvents: Int?,
        totalEvents: Int?,
        error: String?
    ) throws {
        try database.executeUpdate(
            sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('pricing_reprice_status', ?, unixepoch());",
            bindings: [status]
        )
        try database.executeUpdate(
            sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('pricing_reprice_target_catalog_version', ?, unixepoch());",
            bindings: [catalogVersion]
        )
        if let lastRowID {
            try database.executeUpdate(
                sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('pricing_reprice_last_rowid', ?, unixepoch());",
                bindings: [String(lastRowID)]
            )
        }
        if let processedEvents {
            try database.executeUpdate(
                sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('pricing_reprice_processed_events', ?, unixepoch());",
                bindings: [String(processedEvents)]
            )
        }
        if let totalEvents {
            try database.executeUpdate(
                sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('pricing_reprice_total_events', ?, unixepoch());",
                bindings: [String(totalEvents)]
            )
        }
        if let error {
            try database.executeUpdate(
                sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('pricing_reprice_error', ?, unixepoch());",
                bindings: [error]
            )
        } else {
            try database.executeUpdate(sql: "DELETE FROM app_metadata WHERE key = 'pricing_reprice_error';", bindings: [])
        }
    }

    private static func rawJSONString(for catalog: PricingCatalogModel) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(catalog)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 价格估算引擎
public struct PricingCatalogSnapshot: Sendable {
    public let catalogVersion: String
    public let aliases: [String: String]
    public let rulesByModel: [String: [PricingRuleEntry]]

    public init(catalogVersion: String, aliases: [String: String], rulesByModel: [String: [PricingRuleEntry]]) {
        self.catalogVersion = catalogVersion
        self.aliases = aliases
        self.rulesByModel = rulesByModel
    }

    public func evaluate(
        modelCanonical: String,
        serviceTier: String?,
        timestampMs: Int64,
        tokens: TokenBreakdown
    ) -> PricingEvaluationResult {
        let normalizedModel = modelCanonical.lowercased()
        let modelKey = aliases[normalizedModel] ?? normalizedModel

        guard let rules = rulesByModel[modelKey] else {
            return PricingEvaluationResult(
                estimatedCost: .zero,
                pricingStatus: .unpricedUnknownModel,
                pricingRuleId: nil,
                catalogVersion: catalogVersion
            )
        }

        let tier = Self.normalizedServiceTier(serviceTier)
        let candidates = rules.filter { rule in
            if timestampMs < rule.effectiveFromMs { return false }
            if let to = rule.effectiveToMs, timestampMs >= to { return false }
            let ruleTier = Self.normalizedServiceTier(rule.serviceTier)
            return ruleTier == tier
        }

        let matchedRule = candidates.sorted { lhs, rhs in
            let lhsPriority = rulePriority(lhs, requestedTier: tier)
            let rhsPriority = rulePriority(rhs, requestedTier: tier)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return lhs.effectiveFromMs > rhs.effectiveFromMs
        }.first

        guard let matchedRule else {
            return PricingEvaluationResult(
                estimatedCost: .zero,
                pricingStatus: tier == nil
                    ? .unpricedHistoricalRuleMissing
                    : .unpricedUnsupportedServiceMode,
                pricingRuleId: nil,
                catalogVersion: catalogVersion
            )
        }

        return PricingEvaluator.evaluate(rule: matchedRule, tokens: tokens, catalogVersion: catalogVersion)
    }

    private func rulePriority(_ rule: PricingRuleEntry, requestedTier: String?) -> Int {
        if let requestedTier,
           let ruleTier = rule.serviceTier?.lowercased(),
           ruleTier == requestedTier {
            return 0
        }
        if rule.serviceTier == nil { return 1 }
        return 2
    }

    private static func normalizedServiceTier(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty || ["auto", "default", "standard"].contains(normalized) {
            return nil
        }
        // Priority processing was renamed Fast mode on 2026-07-30. Rollouts and
        // API usage can still contain either spelling, so both select the same
        // official Fast pricing row. Unknown tiers intentionally remain unpriced.
        if normalized == "priority" || normalized == "fast" {
            return "fast"
        }
        return normalized
    }
}

public struct PricingEvaluationResult: Sendable {
    public let estimatedCost: MoneyNanoUSD
    public let pricingStatus: PricingStatus
    public let pricingRuleId: String?
    public let catalogVersion: String?

    public init(
        estimatedCost: MoneyNanoUSD,
        pricingStatus: PricingStatus,
        pricingRuleId: String?,
        catalogVersion: String? = nil
    ) {
        self.estimatedCost = estimatedCost
        self.pricingStatus = pricingStatus
        self.pricingRuleId = pricingRuleId
        self.catalogVersion = catalogVersion
    }
}

public enum PricingEvaluator {
    /// 评估单条事件的 API 等价价值
    public static func evaluate(
        modelCanonical: String,
        serviceTier: String?,
        timestampMs: Int64,
        tokens: TokenBreakdown
    ) -> PricingEvaluationResult {
        let catalog = BundledPricingCatalog.defaultCatalog
        let normalizedModel = modelCanonical.lowercased()

        // 1. 匹配模型条目
        guard catalog.models.contains(where: { entry in
            entry.modelKey == normalizedModel || entry.aliases.contains(normalizedModel)
        }) else {
            return PricingEvaluationResult(
                estimatedCost: .zero,
                pricingStatus: .unpricedUnknownModel,
                pricingRuleId: nil,
                catalogVersion: catalog.catalogVersion
            )
        }

        let aliases = Dictionary(uniqueKeysWithValues: catalog.models.flatMap { entry in
            entry.aliases.map { ($0.lowercased(), entry.modelKey.lowercased()) }
        })
        let rules = Dictionary(grouping: catalog.models.flatMap { entry in
            entry.rules.map { (entry.modelKey.lowercased(), $0) }
        }, by: { $0.0 }).mapValues { $0.map(\.1) }
        return PricingCatalogSnapshot(
            catalogVersion: catalog.catalogVersion,
            aliases: aliases,
            rulesByModel: rules
        ).evaluate(
            modelCanonical: modelCanonical,
            serviceTier: serviceTier,
            timestampMs: timestampMs,
            tokens: tokens
        )
    }

    public static func evaluate(
        rule: PricingRuleEntry,
        tokens: TokenBreakdown,
        catalogVersion: String? = nil
    ) -> PricingEvaluationResult {
        guard rule.rateDivisor > 0 else {
            return PricingEvaluationResult(
                estimatedCost: .zero,
                pricingStatus: .unpricedCalculationOverflow,
                pricingRuleId: rule.ruleId,
                catalogVersion: catalogVersion
            )
        }
        if let maximumInputTokens = rule.maximumInputTokens,
           tokens.inputTokens > maximumInputTokens {
            return PricingEvaluationResult(
                estimatedCost: .zero,
                pricingStatus: .unpricedUnsupportedContextLength,
                pricingRuleId: rule.ruleId,
                catalogVersion: catalogVersion
            )
        }

        let uncachedInput = tokens.uncachedInputTokens
        let cachedInput = tokens.cachedInputTokens
        let cacheWriteInput = tokens.cacheWriteInputTokens
        let output = tokens.outputTokens
        let longContext = rule.longContextThresholdTokens.map { tokens.inputTokens > $0 } ?? false
        let inputRate = longContext
            ? scaledRate(rule.inputNanoUsdPerToken, ppm: rule.longContextInputMultiplierPpm)
            : rule.inputNanoUsdPerToken
        let cachedRate = longContext
            ? scaledRate(rule.cachedNanoUsdPerToken, ppm: rule.longContextInputMultiplierPpm)
            : rule.cachedNanoUsdPerToken
        let cacheWriteRate = rule.cacheWriteNanoUsdPerToken.map { rate in
            longContext ? scaledRate(rate, ppm: rule.longContextInputMultiplierPpm) : rate
        }
        let outputRate = longContext
            ? scaledRate(rule.outputNanoUsdPerToken, ppm: rule.longContextOutputMultiplierPpm)
            : rule.outputNanoUsdPerToken

        guard cacheWriteInput == 0 || cacheWriteRate != nil else {
            return PricingEvaluationResult(
                estimatedCost: .zero,
                pricingStatus: .unpricedHistoricalRuleMissing,
                pricingRuleId: rule.ruleId,
                catalogVersion: catalogVersion
            )
        }

        let (inCost, inOverflow) = uncachedInput.multipliedReportingOverflow(by: inputRate)
        let (cacheCost, cacheOverflow) = cachedInput.multipliedReportingOverflow(by: cachedRate)
        let (cacheWriteCost, cacheWriteOverflow) = cacheWriteInput.multipliedReportingOverflow(by: cacheWriteRate ?? 0)
        let (outCost, outOverflow) = output.multipliedReportingOverflow(by: outputRate)

        if inOverflow || cacheOverflow || cacheWriteOverflow || outOverflow {
            return PricingEvaluationResult(
                estimatedCost: .zero,
                pricingStatus: .unpricedCalculationOverflow,
                pricingRuleId: rule.ruleId,
                catalogVersion: catalogVersion
            )
        }

        let (partial, addOverflow) = inCost.addingReportingOverflow(cacheCost)
        let (withCacheWrite, cacheWriteAddOverflow) = partial.addingReportingOverflow(cacheWriteCost)
        let (total, totalOverflow) = withCacheWrite.addingReportingOverflow(outCost)
        if addOverflow || cacheWriteAddOverflow || totalOverflow {
            return PricingEvaluationResult(
                estimatedCost: .zero,
                pricingStatus: .unpricedCalculationOverflow,
                pricingRuleId: rule.ruleId,
                catalogVersion: catalogVersion
            )
        }

        let quotient = total / rule.rateDivisor
        let remainder = total % rule.rateDivisor
        let shouldRoundUp = remainder >= (rule.rateDivisor + 1) / 2
        let (roundedTotal, roundingOverflow) = quotient.addingReportingOverflow(shouldRoundUp ? 1 : 0)
        if roundingOverflow {
            return PricingEvaluationResult(
                estimatedCost: .zero,
                pricingStatus: .unpricedCalculationOverflow,
                pricingRuleId: rule.ruleId,
                catalogVersion: catalogVersion
            )
        }

        return PricingEvaluationResult(
            estimatedCost: MoneyNanoUSD(roundedTotal),
            pricingStatus: .priced,
            pricingRuleId: rule.ruleId,
            catalogVersion: catalogVersion
        )
    }

    private static func scaledRate(_ rate: Int64, ppm: Int64?) -> Int64 {
        guard let ppm else { return rate }
        let scaled = (Decimal(rate) * Decimal(ppm)) / Decimal(1_000_000)
        return NSDecimalNumber(decimal: scaled).int64Value
    }
}
