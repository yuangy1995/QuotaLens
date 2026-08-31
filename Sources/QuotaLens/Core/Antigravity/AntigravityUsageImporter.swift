import Foundation
import SQLite3

struct AntigravityUsageImporter {
    private struct Aggregate {
        var eventCount = 0
        var tokens = TokenBreakdown.zero
        var cost = MoneyNanoUSD.zero
        var unpricedReasons = UnpricedReasonCounts.zero

        mutating func add(_ incoming: TokenBreakdown, price: PricingEvaluationResult) {
            eventCount += 1
            tokens = tokens + incoming
            cost = cost + price.estimatedCost
            unpricedReasons.add(status: price.pricingStatus, tokenCount: incoming.canonicalTotalTokens)
        }

        var reasonBindings: [Any?] {
            [
                unpricedReasons.unknownModelEvents, unpricedReasons.unknownModelTokens,
                unpricedReasons.unsupportedTierEvents, unpricedReasons.unsupportedTierTokens,
                unpricedReasons.historicalRuleMissingEvents, unpricedReasons.historicalRuleMissingTokens,
                unpricedReasons.unsupportedContextEvents, unpricedReasons.unsupportedContextTokens,
                unpricedReasons.invalidRecordEvents, unpricedReasons.invalidRecordTokens,
                unpricedReasons.overflowEvents, unpricedReasons.overflowTokens
            ]
        }
    }

    private struct DailyKey: Hashable {
        let sessionID: String
        let dayKey: String
        let dayStartMs: Int64
        let model: String
    }

    static func importScan(
        _ scan: AntigravityConversationScanResult,
        database: SQLiteDatabase
    ) throws {
        let calendar = UsageDayBucketer.calendar()
        let successfulPaths = Set(scan.successfulSources.map(\.path))
        let sessions = scan.conversations
            .filter { successfulPaths.contains($0.sourcePath) && $0.usageParseReport.isComplete }
            .sorted { $0.sessionID < $1.sessionID }
        let discoveredPaths = Set(scan.discoveredSources.map(\.path))

        try database.transaction {
            let existing = try database.executeQuery(
                sql: "SELECT session_id, source_path FROM codex_sessions WHERE provider = 'antigravity';"
            ) { statement in
                (String(cString: sqlite3_column_text(statement, 0)), String(cString: sqlite3_column_text(statement, 1)))
            }
            for (sessionID, sourcePath) in existing {
                guard successfulPaths.contains(sourcePath)
                    || (scan.isComplete && !discoveredPaths.contains(sourcePath)) else { continue }
                for table in ["codex_daily_usage_summaries", "codex_session_summaries", "codex_usage_events", "codex_sessions"] {
                    try database.executeUpdate(
                        sql: "DELETE FROM \(table) WHERE provider = 'antigravity' AND session_id = ?;",
                        bindings: [sessionID]
                    )
                }
            }

            var dailyAggregates: [DailyKey: Aggregate] = [:]

            for conversation in sessions {
                let sessionID = UsageSessionIdentity.key(provider: .antigravity, rawSessionID: conversation.sessionID)
                let events = conversation.usageRecords
                var sessionAggregate = Aggregate()
                var byModel: [String: Aggregate] = [:]
                for event in events {
                    let model = AntigravityPricingCatalog.resolveModel(
                        rawModel: event.modelRaw,
                        displayName: event.modelDisplayName
                    )
                    let price = AntigravityPricingCatalog.evaluate(
                        modelCanonical: model,
                        timestampMs: milliseconds(event.timestamp),
                        tokens: event.tokens
                    )
                    let providerMessageID = event.responseID ?? "generation-\(event.generationIndex)"
                    let eventID = "\(sessionID):\(providerMessageID)"

                    try database.executeUpdate(
                        sql: """
                        INSERT INTO codex_usage_events (
                            event_id, session_id, root_session_id, turn_index, call_index,
                            timestamp_ms, model_raw, model_canonical, service_tier, reasoning_effort,
                            input_tokens, cached_input_tokens, cache_write_input_tokens,
                            cache_write_5m_input_tokens, cache_write_1h_input_tokens,
                            output_tokens, reasoning_output_tokens, total_tokens, uncached_input_tokens,
                            estimated_cost_usd_nano, pricing_rule_id, pricing_status,
                            usage_derivation, attribution_quality, is_child_replay,
                            source_path, line_offset, line_bytes, created_at,
                            timestamp_quality, timestamp_source, timestamp_conflict_count,
                            pricing_catalog_version, provider, provider_message_id
                        ) VALUES (
                            ?, ?, ?, ?, 0, ?, ?, ?, NULL, NULL,
                            ?, ?, 0, 0, 0, ?, ?, ?, ?,
                            ?, ?, ?,
                            'explicit_last_usage', 'direct_turn_context', 0,
                            ?, ?, 0, unixepoch(),
                            ?, ?, 0, ?, 'antigravity', ?
                        )
                        ON CONFLICT(event_id) DO UPDATE SET
                            timestamp_ms = excluded.timestamp_ms,
                            model_raw = excluded.model_raw,
                            model_canonical = excluded.model_canonical,
                            input_tokens = excluded.input_tokens,
                            cached_input_tokens = excluded.cached_input_tokens,
                            output_tokens = excluded.output_tokens,
                            reasoning_output_tokens = excluded.reasoning_output_tokens,
                            total_tokens = excluded.total_tokens,
                            uncached_input_tokens = excluded.uncached_input_tokens,
                            estimated_cost_usd_nano = excluded.estimated_cost_usd_nano,
                            pricing_rule_id = excluded.pricing_rule_id,
                            pricing_status = excluded.pricing_status,
                            pricing_catalog_version = excluded.pricing_catalog_version,
                            source_path = excluded.source_path,
                            line_offset = excluded.line_offset,
                            timestamp_quality = excluded.timestamp_quality,
                            timestamp_source = excluded.timestamp_source,
                            provider = 'antigravity',
                            provider_message_id = excluded.provider_message_id;
                        """,
                        bindings: [
                            eventID,
                            sessionID,
                            sessionID,
                            Int(clamping: event.generationIndex),
                            milliseconds(event.timestamp),
                            event.modelRaw,
                            model,
                            event.tokens.inputTokens,
                            event.tokens.cachedInputTokens,
                            event.tokens.outputTokens,
                            event.tokens.reasoningOutputTokens,
                            event.tokens.canonicalTotalTokens,
                            event.tokens.uncachedInputTokens,
                            price.estimatedCost.rawValue,
                            price.pricingRuleId,
                            price.pricingStatus.rawValue,
                            conversation.sourcePath,
                            event.generationIndex,
                            event.timestampSource.quality.rawValue,
                            event.timestampSource.rawValue,
                            price.catalogVersion,
                            providerMessageID
                        ]
                    )

                    sessionAggregate.add(event.tokens, price: price)
                    byModel[model, default: Aggregate()].add(event.tokens, price: price)

                    let day = LocalDayKey(date: event.timestamp, calendar: calendar)
                    let dayStart = milliseconds(day.date(calendar: calendar))
                    dailyAggregates[DailyKey(
                        sessionID: sessionID,
                        dayKey: day.yyyyMMdd,
                        dayStartMs: dayStart,
                        model: model
                    ), default: Aggregate()].add(event.tokens, price: price)
                }
                let eventDates = events.map(\.timestamp)
                let createdAt = conversation.createdAt
                    ?? eventDates.min()
                    ?? conversation.lastModifiedAt
                    ?? Date()
                let updatedAt = ([conversation.lastModifiedAt] + eventDates).compactMap { $0 }.max() ?? createdAt
                let sessionTokens = sessionAggregate.tokens

                try database.executeUpdate(
                    sql: """
                    INSERT INTO codex_sessions (
                        session_id, root_session_id, parent_session_id, depth,
                        source_path, relative_path, bucket, title, project_name, cwd,
                        created_at, updated_at, last_event_at, event_count,
                        total_tokens, input_tokens, cached_input_tokens, cache_write_input_tokens,
                        output_tokens, reasoning_output_tokens, estimated_cost_usd_nano,
                        pricing_status, metadata_fingerprint, has_subagents,
                        summary_provenance, provider,
                        unpriced_unknown_model_event_count, unpriced_unknown_model_token_count,
                        unpriced_unsupported_tier_event_count, unpriced_unsupported_tier_token_count,
                        unpriced_historical_rule_missing_event_count, unpriced_historical_rule_missing_token_count,
                        unpriced_unsupported_context_event_count, unpriced_unsupported_context_token_count,
                        unpriced_invalid_record_event_count, unpriced_invalid_record_token_count,
                        unpriced_overflow_event_count, unpriced_overflow_token_count
                    ) VALUES (
                        ?, ?, NULL, 0, ?, ?, 'active', NULL, ?, ?, ?, ?, ?, ?,
                        ?, ?, ?, 0, ?, ?, ?, ?, NULL, 0,
                        'eventLedger', 'antigravity',
                        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
                    );
                    """,
                    bindings: [
                        sessionID,
                        sessionID,
                        conversation.sourcePath,
                        conversation.sourcePath,
                        conversation.projectName,
                        conversation.cwd,
                        milliseconds(createdAt),
                        milliseconds(updatedAt),
                        eventDates.max().map(milliseconds),
                        sessionAggregate.eventCount,
                        sessionTokens.canonicalTotalTokens,
                        sessionTokens.inputTokens,
                        sessionTokens.cachedInputTokens,
                        sessionTokens.outputTokens,
                        sessionTokens.reasoningOutputTokens,
                        sessionAggregate.cost.rawValue,
                        AggregatePricingStatus(
                            eventCount: sessionAggregate.eventCount,
                            unpricedEventCount: sessionAggregate.unpricedReasons.totalEvents
                        ).rawValue
                    ] + sessionAggregate.reasonBindings
                )

                for (model, aggregate) in byModel {
                    try insertSessionSummary(
                        database: database,
                        sessionID: sessionID,
                        model: model,
                        aggregate: aggregate
                    )
                }
            }

            for (key, aggregate) in dailyAggregates {
                try insertDailySummary(database: database, key: key, aggregate: aggregate)
            }
        }
    }

    private static func insertSessionSummary(
        database: SQLiteDatabase,
        sessionID: String,
        model: String,
        aggregate: Aggregate
    ) throws {
        try database.executeUpdate(
            sql: """
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
                unpriced_overflow_event_count, unpriced_overflow_token_count,
                summary_provenance, provider
            ) VALUES (
                ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?,
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'eventLedger', 'antigravity'
            );
            """,
            bindings: [
                sessionID,
                model,
                aggregate.eventCount,
                aggregate.tokens.canonicalTotalTokens,
                aggregate.tokens.uncachedInputTokens,
                aggregate.tokens.cachedInputTokens,
                aggregate.tokens.outputTokens,
                aggregate.tokens.reasoningOutputTokens,
                aggregate.cost.rawValue,
                aggregate.unpricedReasons.totalEvents,
                aggregate.unpricedReasons.totalTokens
            ] + aggregate.reasonBindings
        )
    }

    private static func insertDailySummary(
        database: SQLiteDatabase,
        key: DailyKey,
        aggregate: Aggregate
    ) throws {
        try database.executeUpdate(
            sql: """
            INSERT INTO codex_daily_usage_summaries (
                session_id, day_key, day_start_ms, model_canonical,
                event_count, total_tokens, uncached_input_tokens, cached_input_tokens,
                cache_write_input_tokens, output_tokens, reasoning_output_tokens,
                estimated_cost_usd_nano, unpriced_event_count, unpriced_token_count,
                unpriced_unknown_model_event_count, unpriced_unknown_model_token_count,
                unpriced_unsupported_tier_event_count, unpriced_unsupported_tier_token_count,
                unpriced_historical_rule_missing_event_count, unpriced_historical_rule_missing_token_count,
                unpriced_unsupported_context_event_count, unpriced_unsupported_context_token_count,
                unpriced_invalid_record_event_count, unpriced_invalid_record_token_count,
                unpriced_overflow_event_count, unpriced_overflow_token_count,
                summary_provenance, provider
            ) VALUES (
                ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?,
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'eventLedger', 'antigravity'
            );
            """,
            bindings: [
                key.sessionID,
                key.dayKey,
                key.dayStartMs,
                key.model,
                aggregate.eventCount,
                aggregate.tokens.canonicalTotalTokens,
                aggregate.tokens.uncachedInputTokens,
                aggregate.tokens.cachedInputTokens,
                aggregate.tokens.outputTokens,
                aggregate.tokens.reasoningOutputTokens,
                aggregate.cost.rawValue,
                aggregate.unpricedReasons.totalEvents,
                aggregate.unpricedReasons.totalTokens
            ] + aggregate.reasonBindings
        )
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
