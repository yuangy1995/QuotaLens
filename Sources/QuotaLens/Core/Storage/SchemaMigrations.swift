// QuotaLens 数据库顺序迁移框架与 Schema 定义
// 严格遵循实施计划要求：版本化、可幂等重复执行、事务保护、版本冲突防护

import Foundation
import SQLite3

public protocol DatabaseMigration {
    var version: Int { get }
    var name: String { get }
    func apply(database: SQLiteDatabase) throws
}

private func addColumnIfMissing(
    database: SQLiteDatabase,
    table: String,
    column: String,
    definition: String
) throws {
    let columns = try database.executeQuery(sql: "PRAGMA table_info(\(table));") { statement in
        String(cString: sqlite3_column_text(statement, 1))
    }
    guard !columns.contains(column) else { return }
    try database.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
}

private let unpricedReasonColumnDefinitions: [(String, String)] = [
    ("unpriced_unknown_model_event_count", "INTEGER NOT NULL DEFAULT 0"),
    ("unpriced_unknown_model_token_count", "INTEGER NOT NULL DEFAULT 0"),
    ("unpriced_unsupported_tier_event_count", "INTEGER NOT NULL DEFAULT 0"),
    ("unpriced_unsupported_tier_token_count", "INTEGER NOT NULL DEFAULT 0"),
    ("unpriced_historical_rule_missing_event_count", "INTEGER NOT NULL DEFAULT 0"),
    ("unpriced_historical_rule_missing_token_count", "INTEGER NOT NULL DEFAULT 0"),
    ("unpriced_unsupported_context_event_count", "INTEGER NOT NULL DEFAULT 0"),
    ("unpriced_unsupported_context_token_count", "INTEGER NOT NULL DEFAULT 0"),
    ("unpriced_invalid_record_event_count", "INTEGER NOT NULL DEFAULT 0"),
    ("unpriced_invalid_record_token_count", "INTEGER NOT NULL DEFAULT 0"),
    ("unpriced_overflow_event_count", "INTEGER NOT NULL DEFAULT 0"),
    ("unpriced_overflow_token_count", "INTEGER NOT NULL DEFAULT 0")
]

private func addUnpricedReasonColumns(database: SQLiteDatabase, table: String) throws {
    for (column, definition) in unpricedReasonColumnDefinitions {
        try addColumnIfMissing(database: database, table: table, column: column, definition: definition)
    }
}

public struct SchemaMigrations {
    public static let targetSchemaVersion = 13

    public static func migrate(database: SQLiteDatabase) throws {
        let currentVersion = try database.intScalar(sql: "PRAGMA user_version;")
        if currentVersion > targetSchemaVersion {
            throw NSError(
                domain: "QuotaLens.Migration",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "数据库版本 (\(currentVersion)) 高于当前应用支持版本 (\(targetSchemaVersion))，已拒绝降级写入。"
                ]
            )
        }

        if currentVersion == targetSchemaVersion {
            try V5AggregateOnlyUsageMigration.compactIfNeeded(database: database)
            return
        }

        let migrations: [DatabaseMigration] = [
            V1InitialSchemaMigration(),
            V2CodexUsageCoreMigration(),
            V3PricingAndSummariesMigration(),
            V4DiagnosticsAndIndexesMigration(),
            V5AggregateOnlyUsageMigration(),
            V6UsageTruthAndRecoveryMigration(),
            V7CatalogIdentityAndParserV4Migration(),
            V8ReasoningEffortMigration(),
            V9CacheWriteAndParserV6Migration(),
            V10PricingRuleBoundsMigration(),
            V11ExactPricingCoverageMigration(),
            V12AggregateReasonsAndRebuildStateMigration(),
            V13Round2ReliabilityMigration()
        ]

        for migration in migrations where migration.version > currentVersion {
            try database.transaction {
                try migration.apply(database: database)
                try database.execute(sql: "PRAGMA user_version = \(migration.version);")
            }
        }

        try V5AggregateOnlyUsageMigration.compactIfNeeded(database: database)
    }
}

// MARK: - V13: 第二轮复审可靠性边界
private struct V13Round2ReliabilityMigration: DatabaseMigration {
    let version = 13
    let name = "V13Round2Reliability"

    func apply(database: SQLiteDatabase) throws {
        for table in ["codex_sessions", "codex_session_summaries", "codex_daily_usage_summaries"] {
            try addColumnIfMissing(
                database: database,
                table: table,
                column: "summary_provenance",
                definition: "TEXT NOT NULL DEFAULT 'eventLedger'"
            )
        }
        try addColumnIfMissing(
            database: database,
            table: "codex_usage_events",
            column: "timestamp_source",
            definition: "TEXT NOT NULL DEFAULT 'top_level_timestamp'"
        )
        try addColumnIfMissing(
            database: database,
            table: "codex_usage_events",
            column: "timestamp_conflict_count",
            definition: "INTEGER NOT NULL DEFAULT 0"
        )
        try addColumnIfMissing(
            database: database,
            table: "codex_import_sources",
            column: "timestamp_conflict_count",
            definition: "INTEGER NOT NULL DEFAULT 0"
        )

        try database.execute(sql: """
        UPDATE codex_usage_events
        SET timestamp_source = CASE timestamp_quality
            WHEN 'file_name_timestamp' THEN 'file_name'
            WHEN 'session_timestamp' THEN 'session_metadata'
            WHEN 'file_modification_time' THEN 'file_modification'
            WHEN 'unresolved' THEN 'unresolved'
            ELSE timestamp_source
        END;

        UPDATE codex_sessions
        SET summary_provenance = 'legacyAggregate'
        WHERE event_count > 0
          AND NOT EXISTS (
            SELECT 1
            FROM codex_usage_events e
            WHERE e.session_id = codex_sessions.session_id
              AND e.is_child_replay = 0
          );

        UPDATE codex_session_summaries
        SET summary_provenance = 'legacyAggregate'
        WHERE session_id IN (
            SELECT session_id FROM codex_sessions WHERE summary_provenance = 'legacyAggregate'
        );

        UPDATE codex_daily_usage_summaries
        SET summary_provenance = 'legacyAggregate'
        WHERE session_id IN (
            SELECT session_id FROM codex_sessions WHERE summary_provenance = 'legacyAggregate'
        );

        CREATE INDEX IF NOT EXISTS idx_codex_sessions_provenance
            ON codex_sessions(summary_provenance);
        CREATE INDEX IF NOT EXISTS idx_codex_session_summaries_provenance
            ON codex_session_summaries(summary_provenance);
        CREATE INDEX IF NOT EXISTS idx_codex_daily_summaries_provenance
            ON codex_daily_usage_summaries(summary_provenance);
        CREATE INDEX IF NOT EXISTS idx_codex_events_timestamp_source
            ON codex_usage_events(timestamp_source, timestamp_conflict_count);

        CREATE TABLE IF NOT EXISTS codex_session_deletion_journal (
            deletion_id TEXT PRIMARY KEY,
            requested_session_id TEXT NOT NULL,
            root_session_id TEXT NOT NULL,
            history_root_path TEXT NOT NULL,
            staging_root_path TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            error_message TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_codex_deletion_journal_status
            ON codex_session_deletion_journal(status, updated_at);

        CREATE TABLE IF NOT EXISTS codex_session_deletion_files (
            deletion_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            source_path TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            bucket TEXT NOT NULL,
            original_path TEXT NOT NULL,
            staging_path TEXT NOT NULL,
            recovery_path TEXT,
            state TEXT NOT NULL,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY(deletion_id, original_path),
            FOREIGN KEY(deletion_id) REFERENCES codex_session_deletion_journal(deletion_id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_codex_deletion_files_state
            ON codex_session_deletion_files(deletion_id, state);

        INSERT OR REPLACE INTO app_metadata (key, value, updated_at)
            VALUES ('codex_parser_version', '7', unixepoch());
        INSERT OR REPLACE INTO app_metadata (key, value, updated_at)
            VALUES ('codex_parser_rebuild_status', 'pending', unixepoch());
        INSERT OR REPLACE INTO app_metadata (key, value, updated_at)
            VALUES ('codex_parser_rebuild_generation', COALESCE((SELECT CAST(value AS INTEGER) + 1 FROM app_metadata WHERE key = 'codex_parser_rebuild_generation'), 1), unixepoch());
        INSERT OR REPLACE INTO app_metadata (key, value, updated_at)
            VALUES ('pricing_migration_state', 'fullyCurrent', unixepoch());
        DELETE FROM app_metadata WHERE key = 'pricing_reprice_catalog_version';

        UPDATE codex_import_sources
            SET status = CASE WHEN status = 'tombstoned' THEN status ELSE 'stale' END,
                error_message = CASE WHEN status = 'tombstoned' THEN error_message ELSE 'parser v7 rebuild pending' END
        WHERE status != 'tombstoned';
        """)
    }
}

// MARK: - V12: 聚合原因、可恢复重计价状态与时区口径
private struct V12AggregateReasonsAndRebuildStateMigration: DatabaseMigration {
    let version = 12
    let name = "V12AggregateReasonsAndRebuildState"

    func apply(database: SQLiteDatabase) throws {
        for table in ["codex_sessions", "codex_session_summaries", "codex_daily_usage_summaries"] {
            try addUnpricedReasonColumns(database: database, table: table)
        }

        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS codex_scan_diagnostics (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source_path TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            bucket TEXT NOT NULL,
            diagnostic_code TEXT NOT NULL,
            message TEXT NOT NULL,
            scan_generation INTEGER NOT NULL,
            created_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_codex_scan_diagnostics_generation
            ON codex_scan_diagnostics(scan_generation, diagnostic_code);

        INSERT OR IGNORE INTO app_metadata (key, value, updated_at)
            VALUES ('pricing_reprice_status', 'completed', unixepoch());
        INSERT OR IGNORE INTO app_metadata (key, value, updated_at)
            VALUES ('pricing_reprice_last_rowid', '0', unixepoch());
        INSERT OR IGNORE INTO app_metadata (key, value, updated_at)
            VALUES ('pricing_reprice_processed_events', '0', unixepoch());
        INSERT OR IGNORE INTO app_metadata (key, value, updated_at)
            VALUES ('pricing_reprice_total_events', '0', unixepoch());
        INSERT OR IGNORE INTO app_metadata (key, value, updated_at)
            VALUES ('usage_aggregation_timezone_id', '\(TimeZone.current.identifier)', unixepoch());
        INSERT OR IGNORE INTO app_metadata (key, value, updated_at)
            VALUES ('usage_aggregation_timezone_generation', '0', unixepoch());
        INSERT OR IGNORE INTO app_metadata (key, value, updated_at)
            VALUES ('codex_parser_rebuild_status', 'completed', unixepoch());
        INSERT OR IGNORE INTO app_metadata (key, value, updated_at)
            VALUES ('codex_parser_rebuild_generation', '0', unixepoch());
        INSERT OR IGNORE INTO app_metadata (key, value, updated_at)
            VALUES ('codex_parser_rebuild_processed_sources', '0', unixepoch());
        INSERT OR IGNORE INTO app_metadata (key, value, updated_at)
            VALUES ('codex_parser_rebuild_total_sources', '0', unixepoch());
        DELETE FROM app_metadata WHERE key = 'pricing_reprice_catalog_version';
        """)
    }
}

// MARK: - V11: exact token-weighted pricing coverage in compact summaries
private struct V11ExactPricingCoverageMigration: DatabaseMigration {
    let version = 11
    let name = "V11ExactPricingCoverage"

    func apply(database: SQLiteDatabase) throws {
        try addColumnIfMissing(
            database: database,
            table: "codex_session_summaries",
            column: "unpriced_token_count",
            definition: "INTEGER NOT NULL DEFAULT 0"
        )
        try addColumnIfMissing(
            database: database,
            table: "codex_daily_usage_summaries",
            column: "unpriced_token_count",
            definition: "INTEGER NOT NULL DEFAULT 0"
        )
        // Force the next catalog check to rebuild both compact summaries from
        // event-level pricing truth, including databases created by a v10
        // developer build.
        try database.executeUpdate(
            sql: "DELETE FROM app_metadata WHERE key = 'pricing_reprice_catalog_version';",
            bindings: []
        )
    }
}

// MARK: - V10: exact fractional rates and short-context-only rule bounds
private struct V10PricingRuleBoundsMigration: DatabaseMigration {
    let version = 10
    let name = "V10PricingRuleBounds"

    func apply(database: SQLiteDatabase) throws {
        try addColumnIfMissing(
            database: database,
            table: "codex_pricing_rules",
            column: "rate_divisor",
            definition: "INTEGER NOT NULL DEFAULT 1"
        )
        try addColumnIfMissing(
            database: database,
            table: "codex_pricing_rules",
            column: "maximum_input_tokens",
            definition: "INTEGER"
        )
    }
}

// MARK: - V9: cache-write token bucket and parser v6 rebuild
private struct V9CacheWriteAndParserV6Migration: DatabaseMigration {
    let version = 9
    let name = "V9CacheWriteAndParserV6"

    func apply(database: SQLiteDatabase) throws {
        try addColumnIfMissing(
            database: database,
            table: "codex_usage_events",
            column: "cache_write_input_tokens",
            definition: "INTEGER NOT NULL DEFAULT 0"
        )
        try addColumnIfMissing(
            database: database,
            table: "codex_sessions",
            column: "cache_write_input_tokens",
            definition: "INTEGER NOT NULL DEFAULT 0"
        )
        try addColumnIfMissing(
            database: database,
            table: "codex_session_summaries",
            column: "cache_write_input_tokens",
            definition: "INTEGER NOT NULL DEFAULT 0"
        )
        try addColumnIfMissing(
            database: database,
            table: "codex_daily_usage_summaries",
            column: "cache_write_input_tokens",
            definition: "INTEGER NOT NULL DEFAULT 0"
        )

        try database.execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_codex_events_session_time_offset_id
            ON codex_usage_events(session_id, is_child_replay, timestamp_ms DESC, line_offset DESC, event_id DESC);
        CREATE INDEX IF NOT EXISTS idx_codex_events_day_time_offset_id
            ON codex_usage_events(is_child_replay, timestamp_ms DESC, line_offset DESC, event_id DESC);

        UPDATE codex_import_sources
            SET status = CASE WHEN status = 'tombstoned' THEN status ELSE 'stale' END,
                error_message = CASE WHEN status = 'tombstoned' THEN error_message ELSE 'parser rebuild pending' END;
        INSERT OR REPLACE INTO app_metadata (key, value, updated_at)
            VALUES ('codex_usage_generation', unixepoch(), unixepoch());
        INSERT OR REPLACE INTO app_metadata (key, value, updated_at)
            VALUES ('codex_parser_version', '6', unixepoch());
        INSERT OR REPLACE INTO app_metadata (key, value, updated_at)
            VALUES ('pricing_reprice_generation', '0', unixepoch());
        INSERT OR REPLACE INTO app_metadata (key, value, updated_at)
            VALUES ('codex_parser_rebuild_status', 'pending', unixepoch());
        INSERT OR REPLACE INTO app_metadata (key, value, updated_at)
            VALUES ('codex_parser_rebuild_generation', COALESCE((SELECT CAST(value AS INTEGER) + 1 FROM app_metadata WHERE key = 'codex_parser_rebuild_generation'), 1), unixepoch());
        DELETE FROM app_metadata WHERE key = 'pricing_reprice_catalog_version';
        """)
    }
}

// MARK: - V8: event reasoning effort support
private struct V8ReasoningEffortMigration: DatabaseMigration {
    let version = 8
    let name = "V8ReasoningEffort"

    func apply(database: SQLiteDatabase) throws {
        try addColumnIfMissing(database: database, table: "codex_usage_events", column: "reasoning_effort", definition: "TEXT")
    }
}

// MARK: - V7: immutable catalog rows, agent search, parser v4 rebuild
private struct V7CatalogIdentityAndParserV4Migration: DatabaseMigration {
    let version = 7
    let name = "V7CatalogIdentityAndParserV4"

    func apply(database: SQLiteDatabase) throws {
        // V3 used alias_pattern and rule_id as global primary keys, so installing
        // a newer catalog could overwrite rows belonging to an older catalog.
        // Rebuild both tables with catalog-scoped identities.
        try database.execute(sql: """
        DROP INDEX IF EXISTS idx_codex_aliases_target;
        ALTER TABLE codex_model_aliases RENAME TO codex_model_aliases_v6;
        CREATE TABLE codex_model_aliases (
            alias_pattern TEXT NOT NULL,
            target_model_key TEXT NOT NULL,
            match_type TEXT NOT NULL DEFAULT 'exact',
            catalog_version TEXT NOT NULL,
            PRIMARY KEY(alias_pattern, catalog_version)
        );
        INSERT OR IGNORE INTO codex_model_aliases (
            alias_pattern, target_model_key, match_type, catalog_version
        )
        SELECT alias_pattern, target_model_key, match_type, catalog_version
        FROM codex_model_aliases_v6;
        DROP TABLE codex_model_aliases_v6;
        CREATE INDEX idx_codex_aliases_target
            ON codex_model_aliases(target_model_key, catalog_version);

        DROP INDEX IF EXISTS idx_codex_pricing_model_tier_time;
        ALTER TABLE codex_pricing_rules RENAME TO codex_pricing_rules_v6;
        CREATE TABLE codex_pricing_rules (
            rule_id TEXT NOT NULL,
            model_key TEXT NOT NULL,
            service_tier TEXT,
            effective_from_ms INTEGER NOT NULL,
            effective_to_ms INTEGER,
            input_usd_nano_per_token INTEGER NOT NULL,
            cached_usd_nano_per_token INTEGER NOT NULL,
            cache_write_usd_nano_per_token INTEGER,
            output_usd_nano_per_token INTEGER NOT NULL,
            long_context_threshold_tokens INTEGER,
            long_context_input_multiplier_ppm INTEGER,
            long_context_output_multiplier_ppm INTEGER,
            catalog_version TEXT NOT NULL,
            PRIMARY KEY(rule_id, catalog_version)
        );
        INSERT OR IGNORE INTO codex_pricing_rules (
            rule_id, model_key, service_tier, effective_from_ms, effective_to_ms,
            input_usd_nano_per_token, cached_usd_nano_per_token,
            cache_write_usd_nano_per_token, output_usd_nano_per_token,
            long_context_threshold_tokens, long_context_input_multiplier_ppm,
            long_context_output_multiplier_ppm, catalog_version
        )
        SELECT
            rule_id, model_key, service_tier, effective_from_ms, effective_to_ms,
            input_usd_nano_per_token, cached_usd_nano_per_token,
            cache_write_usd_nano_per_token, output_usd_nano_per_token,
            long_context_threshold_tokens, long_context_input_multiplier_ppm,
            long_context_output_multiplier_ppm, catalog_version
        FROM codex_pricing_rules_v6;
        DROP TABLE codex_pricing_rules_v6;
        CREATE INDEX idx_codex_pricing_model_tier_time
            ON codex_pricing_rules(catalog_version, model_key, service_tier, effective_from_ms, effective_to_ms);
        """)

        try addColumnIfMissing(database: database, table: "codex_sessions", column: "agent_type", definition: "TEXT")
        try addColumnIfMissing(database: database, table: "codex_import_sources", column: "rebuild_reason", definition: "TEXT")
        try addColumnIfMissing(database: database, table: "codex_import_sources", column: "malformed_line_count", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing(database: database, table: "codex_import_sources", column: "unresolved_timestamp_count", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing(database: database, table: "codex_import_sources", column: "unknown_event_type_count", definition: "INTEGER NOT NULL DEFAULT 0")

        // Parser v4 改变事件 ID 与累计计数语义，保留旧索引并标记后台重建。
        try database.execute(sql: """
        UPDATE codex_import_sources
            SET status = CASE WHEN status = 'tombstoned' THEN status ELSE 'stale' END,
                error_message = CASE WHEN status = 'tombstoned' THEN error_message ELSE 'parser rebuild pending' END;
        INSERT OR REPLACE INTO app_metadata (key, value, updated_at)
            VALUES ('codex_usage_generation', unixepoch(), unixepoch());
        INSERT OR REPLACE INTO app_metadata (key, value, updated_at)
            VALUES ('codex_parser_version', '4', unixepoch());
        INSERT OR REPLACE INTO app_metadata (key, value, updated_at)
            VALUES ('codex_parser_rebuild_status', 'pending', unixepoch());
        INSERT OR REPLACE INTO app_metadata (key, value, updated_at)
            VALUES ('codex_parser_rebuild_generation', COALESCE((SELECT CAST(value AS INTEGER) + 1 FROM app_metadata WHERE key = 'codex_parser_rebuild_generation'), 1), unixepoch());
        """)
    }
}

// MARK: - V1: 现有 QuotaLens 基础账本与额度表
private struct V1InitialSchemaMigration: DatabaseMigration {
    let version = 1
    let name = "V1InitialSchema"

    func apply(database: SQLiteDatabase) throws {
        let sql = """
        -- 账户表
        CREATE TABLE IF NOT EXISTS accounts (
            account_key TEXT PRIMARY KEY,
            email_hash TEXT,
            plan_type TEXT,
            first_seen_at INTEGER NOT NULL,
            last_seen_at INTEGER NOT NULL
        );

        -- 设备表
        CREATE TABLE IF NOT EXISTS devices (
            device_id TEXT PRIMARY KEY,
            platform TEXT NOT NULL DEFAULT 'macOS',
            app_install_id TEXT NOT NULL,
            first_seen_at INTEGER NOT NULL,
            last_seen_at INTEGER NOT NULL,
            sync_enabled INTEGER NOT NULL DEFAULT 0
        );

        -- 账户每日总账快照 (account/usage/read)
        CREATE TABLE IF NOT EXISTS account_daily_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            account_key TEXT NOT NULL,
            server_start_date TEXT NOT NULL,
            observed_at INTEGER NOT NULL,
            total_tokens INTEGER NOT NULL,
            data_state TEXT NOT NULL,
            raw_json TEXT NOT NULL,
            UNIQUE(account_key, server_start_date, observed_at)
        );
        CREATE INDEX IF NOT EXISTS idx_daily_snaps_acc_date ON account_daily_snapshots(account_key, server_start_date);

        -- 额度窗口快照 (account/rateLimits/read)
        CREATE TABLE IF NOT EXISTS rate_limit_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            account_key TEXT NOT NULL,
            observed_at INTEGER NOT NULL,
            limit_id TEXT NOT NULL,
            slot TEXT NOT NULL,
            used_percent_milli INTEGER NOT NULL,
            window_duration_mins INTEGER,
            resets_at INTEGER,
            plan_type TEXT,
            raw_json TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_rate_snaps_time ON rate_limit_snapshots(observed_at);
        CREATE INDEX IF NOT EXISTS idx_rate_snaps_limit ON rate_limit_snapshots(limit_id, slot);
        CREATE INDEX IF NOT EXISTS idx_rate_snaps_account_limit_time ON rate_limit_snapshots(account_key, limit_id, slot, observed_at);

        -- 线程用量快照 (thread/tokenUsage/updated 或 account/usage/read(threadId))
        CREATE TABLE IF NOT EXISTS thread_usage_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            device_id TEXT NOT NULL,
            observed_at INTEGER NOT NULL,
            thread_id TEXT NOT NULL,
            model_raw TEXT,
            model_canonical TEXT,
            reasoning_effort TEXT,
            service_tier TEXT,
            input_tokens INTEGER,
            cached_input_tokens INTEGER,
            output_tokens INTEGER,
            total_tokens INTEGER,
            estimated_credits_micros INTEGER,
            raw_json TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_thread_snaps_thread ON thread_usage_snapshots(thread_id, observed_at);
        CREATE INDEX IF NOT EXISTS idx_thread_snaps_device_thread_time ON thread_usage_snapshots(device_id, thread_id, observed_at);

        -- 用量增量切片事件
        CREATE TABLE IF NOT EXISTS usage_events (
            event_id TEXT PRIMARY KEY,
            device_id TEXT NOT NULL,
            interval_start INTEGER NOT NULL,
            interval_end INTEGER NOT NULL,
            thread_id TEXT,
            model_raw TEXT,
            model_canonical TEXT,
            reasoning_effort TEXT,
            service_tier TEXT,
            input_tokens INTEGER NOT NULL,
            cached_input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            total_tokens INTEGER NOT NULL,
            meter_version_id TEXT,
            cycle_id TEXT,
            allocation_quality TEXT NOT NULL,
            source TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_usage_events_time ON usage_events(interval_start, interval_end);
        CREATE INDEX IF NOT EXISTS idx_usage_events_cycle ON usage_events(cycle_id);

        -- 计量版本表
        CREATE TABLE IF NOT EXISTS meter_versions (
            meter_version_id TEXT PRIMARY KEY,
            effective_from INTEGER NOT NULL,
            effective_to INTEGER,
            reason TEXT NOT NULL,
            source TEXT NOT NULL,
            confidence TEXT NOT NULL
        );

        -- 额度周期表
        CREATE TABLE IF NOT EXISTS quota_cycles (
            cycle_id TEXT PRIMARY KEY,
            account_key TEXT NOT NULL,
            limit_id TEXT NOT NULL,
            slot TEXT NOT NULL,
            start_at INTEGER NOT NULL,
            end_at INTEGER,
            expected_end_at INTEGER,
            window_duration_mins INTEGER,
            boundary_reason TEXT NOT NULL,
            is_complete INTEGER NOT NULL,
            predecessor_cycle_id TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_cycles_account ON quota_cycles(account_key, start_at);
        CREATE INDEX IF NOT EXISTS idx_cycles_account_limit ON quota_cycles(account_key, limit_id, start_at);

        -- 额度周期分段表 (Segments)
        CREATE TABLE IF NOT EXISTS quota_cycle_segments (
            segment_id TEXT PRIMARY KEY,
            cycle_id TEXT NOT NULL,
            start_at INTEGER NOT NULL,
            end_at INTEGER NOT NULL,
            meter_version_id TEXT NOT NULL,
            boundary_quality TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_segments_cycle ON quota_cycle_segments(cycle_id);

        -- 周容量估算表
        CREATE TABLE IF NOT EXISTS quota_estimates (
            estimate_id TEXT PRIMARY KEY,
            cycle_id TEXT NOT NULL,
            meter_version_id TEXT NOT NULL,
            capacity_units_micros INTEGER,
            confidence_low_micros INTEGER,
            confidence_high_micros INTEGER,
            account_tokens INTEGER,
            attributed_tokens INTEGER,
            coverage_ppm INTEGER,
            percent_span_milli INTEGER,
            sample_count INTEGER,
            residual_micros INTEGER,
            confidence_level TEXT NOT NULL,
            algorithm_version TEXT NOT NULL,
            calculated_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_estimates_cycle ON quota_estimates(cycle_id);

        -- 额度事件与异常表
        CREATE TABLE IF NOT EXISTS quota_events (
            event_id TEXT PRIMARY KEY,
            occurred_at INTEGER NOT NULL,
            event_type TEXT NOT NULL,
            severity TEXT NOT NULL,
            limit_id TEXT,
            old_cycle_id TEXT,
            new_cycle_id TEXT,
            evidence_json TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_quota_events_time ON quota_events(occurred_at);

        INSERT OR IGNORE INTO meter_versions (
            meter_version_id, effective_from, effective_to, reason, source, confidence
        ) VALUES (
            'meter-2026-07-v1', 1785283200, NULL, '内置初始计量版本；用于额度估算基线', 'seed', 'low'
        );
        """
        try database.execute(sql: sql)
    }
}

// MARK: - V2: Codex 精确账本、导入源与会话元数据表
private struct V2CodexUsageCoreMigration: DatabaseMigration {
    let version = 2
    let name = "V2CodexUsageCore"

    func apply(database: SQLiteDatabase) throws {
        let sql = """
        -- 应用级元数据表
        CREATE TABLE IF NOT EXISTS app_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at INTEGER NOT NULL
        );

        -- Codex 会话表
        CREATE TABLE IF NOT EXISTS codex_sessions (
            session_id TEXT PRIMARY KEY,
            root_session_id TEXT NOT NULL,
            parent_session_id TEXT,
            depth INTEGER NOT NULL DEFAULT 0,
            source_path TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            bucket TEXT NOT NULL,
            title TEXT,
            project_name TEXT,
            cwd TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            last_event_at INTEGER,
            event_count INTEGER NOT NULL DEFAULT 0,
            total_tokens INTEGER NOT NULL DEFAULT 0,
            input_tokens INTEGER NOT NULL DEFAULT 0,
            cached_input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_output_tokens INTEGER NOT NULL DEFAULT 0,
            estimated_cost_usd_nano INTEGER NOT NULL DEFAULT 0,
            pricing_status TEXT NOT NULL DEFAULT 'unpricedUnknownModel',
            metadata_fingerprint TEXT,
            has_subagents INTEGER NOT NULL DEFAULT 0,
            summary_provenance TEXT NOT NULL DEFAULT 'eventLedger'
        );
        CREATE INDEX IF NOT EXISTS idx_codex_sessions_root ON codex_sessions(root_session_id);
        CREATE INDEX IF NOT EXISTS idx_codex_sessions_parent ON codex_sessions(parent_session_id);
        CREATE INDEX IF NOT EXISTS idx_codex_sessions_updated ON codex_sessions(updated_at DESC);
        CREATE INDEX IF NOT EXISTS idx_codex_sessions_created ON codex_sessions(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_codex_sessions_tokens ON codex_sessions(total_tokens DESC);
        CREATE INDEX IF NOT EXISTS idx_codex_sessions_cost ON codex_sessions(estimated_cost_usd_nano DESC);
        CREATE INDEX IF NOT EXISTS idx_codex_sessions_bucket ON codex_sessions(bucket);

        -- Codex 导入文件源跟踪表
        CREATE TABLE IF NOT EXISTS codex_import_sources (
            source_path TEXT PRIMARY KEY,
            relative_path TEXT NOT NULL,
            bucket TEXT NOT NULL,
            device_id INTEGER NOT NULL,
            inode INTEGER NOT NULL,
            birthtime_ns INTEGER,
            file_size INTEGER NOT NULL,
            mtime_ms INTEGER NOT NULL,
            last_imported_size INTEGER NOT NULL DEFAULT 0,
            last_imported_line INTEGER NOT NULL DEFAULT 0,
            last_imported_sha256 TEXT,
            checkpoint_state_json TEXT,
            status TEXT NOT NULL DEFAULT 'discovered',
            last_imported_at INTEGER,
            error_message TEXT,
            timestamp_conflict_count INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_codex_sources_identity ON codex_import_sources(device_id, inode, birthtime_ns);
        CREATE INDEX IF NOT EXISTS idx_codex_sources_status ON codex_import_sources(status);

        -- Codex 精确增量用量事件表
        CREATE TABLE IF NOT EXISTS codex_usage_events (
            event_id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            root_session_id TEXT NOT NULL,
            turn_index INTEGER NOT NULL DEFAULT 0,
            call_index INTEGER NOT NULL DEFAULT 0,
            timestamp_ms INTEGER NOT NULL,
            model_raw TEXT NOT NULL,
            model_canonical TEXT NOT NULL,
            service_tier TEXT,
            reasoning_effort TEXT,
            input_tokens INTEGER NOT NULL DEFAULT 0,
            cached_input_tokens INTEGER NOT NULL DEFAULT 0,
            cache_write_input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_output_tokens INTEGER NOT NULL DEFAULT 0,
            total_tokens INTEGER NOT NULL DEFAULT 0,
            uncached_input_tokens INTEGER NOT NULL DEFAULT 0,
            estimated_cost_usd_nano INTEGER NOT NULL DEFAULT 0,
            pricing_rule_id TEXT,
            pricing_status TEXT NOT NULL DEFAULT 'unpricedUnknownModel',
            usage_derivation TEXT NOT NULL,
            attribution_quality TEXT NOT NULL,
            is_child_replay INTEGER NOT NULL DEFAULT 0,
            source_path TEXT NOT NULL,
            line_offset INTEGER NOT NULL DEFAULT 0,
            line_bytes INTEGER NOT NULL DEFAULT 0,
            payload_sha256 TEXT,
            created_at INTEGER NOT NULL,
            timestamp_quality TEXT NOT NULL DEFAULT 'event_timestamp',
            timestamp_source TEXT NOT NULL DEFAULT 'top_level_timestamp',
            timestamp_conflict_count INTEGER NOT NULL DEFAULT 0,
            pricing_catalog_version TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_codex_events_session_time ON codex_usage_events(session_id, timestamp_ms);
        CREATE INDEX IF NOT EXISTS idx_codex_events_root_time ON codex_usage_events(root_session_id, timestamp_ms);
        CREATE INDEX IF NOT EXISTS idx_codex_events_time_replay ON codex_usage_events(timestamp_ms, is_child_replay);
        CREATE INDEX IF NOT EXISTS idx_codex_events_model_time ON codex_usage_events(model_canonical, timestamp_ms);
        CREATE INDEX IF NOT EXISTS idx_codex_events_source ON codex_usage_events(source_path);

        -- 初始化应用元数据
        INSERT OR IGNORE INTO app_metadata (key, value, updated_at) VALUES ('codex_usage_generation', '1', unixepoch());
        INSERT OR IGNORE INTO app_metadata (key, value, updated_at) VALUES ('pricing_catalog_generation', '1', unixepoch());
        """
        try database.execute(sql: sql)
    }
}

// MARK: - V3: 价格目录、模型别名与会话模型汇总表
private struct V3PricingAndSummariesMigration: DatabaseMigration {
    let version = 3
    let name = "V3PricingAndSummaries"

    func apply(database: SQLiteDatabase) throws {
        let sql = """
        -- 价格目录版本记录表
        CREATE TABLE IF NOT EXISTS codex_pricing_catalogs (
            catalog_version TEXT PRIMARY KEY,
            schema_version INTEGER NOT NULL DEFAULT 1,
            published_at INTEGER NOT NULL,
            catalog_sha256 TEXT NOT NULL,
            is_active INTEGER NOT NULL DEFAULT 0,
            raw_json TEXT NOT NULL
        );

        -- 模型别名映射表
        CREATE TABLE IF NOT EXISTS codex_model_aliases (
            alias_pattern TEXT PRIMARY KEY,
            target_model_key TEXT NOT NULL,
            match_type TEXT NOT NULL DEFAULT 'exact',
            catalog_version TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_codex_aliases_target ON codex_model_aliases(target_model_key);

        -- 价格规则表
        CREATE TABLE IF NOT EXISTS codex_pricing_rules (
            rule_id TEXT PRIMARY KEY,
            model_key TEXT NOT NULL,
            service_tier TEXT,
            effective_from_ms INTEGER NOT NULL,
            effective_to_ms INTEGER,
            input_usd_nano_per_token INTEGER NOT NULL,
            cached_usd_nano_per_token INTEGER NOT NULL,
            output_usd_nano_per_token INTEGER NOT NULL,
            catalog_version TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_codex_pricing_model_tier_time ON codex_pricing_rules(model_key, service_tier, effective_from_ms, effective_to_ms);

        -- 会话多模型汇总聚合缓存表
        CREATE TABLE IF NOT EXISTS codex_session_summaries (
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
            summary_provenance TEXT NOT NULL DEFAULT 'eventLedger',
            PRIMARY KEY(session_id, model_canonical)
        );
        CREATE INDEX IF NOT EXISTS idx_codex_summaries_session ON codex_session_summaries(session_id);
        CREATE INDEX IF NOT EXISTS idx_codex_summaries_model ON codex_session_summaries(model_canonical);
        """
        try database.execute(sql: sql)
    }
}

// MARK: - V4: 导入批次运行历史与聚合查询优化索引
private struct V4DiagnosticsAndIndexesMigration: DatabaseMigration {
    let version = 4
    let name = "V4DiagnosticsAndIndexes"

    func apply(database: SQLiteDatabase) throws {
        let sql = """
        -- 导入历史批次记录表
        CREATE TABLE IF NOT EXISTS codex_import_runs (
            run_id TEXT PRIMARY KEY,
            started_at INTEGER NOT NULL,
            completed_at INTEGER,
            sources_scanned INTEGER NOT NULL DEFAULT 0,
            sources_updated INTEGER NOT NULL DEFAULT 0,
            events_inserted INTEGER NOT NULL DEFAULT 0,
            bytes_read INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL,
            error_message TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_codex_runs_started ON codex_import_runs(started_at DESC);

        -- 查询聚合复合索引
        CREATE INDEX IF NOT EXISTS idx_codex_events_replay_time_tokens
            ON codex_usage_events(is_child_replay, timestamp_ms, total_tokens, estimated_cost_usd_nano);

        CREATE INDEX IF NOT EXISTS idx_codex_events_session_replay_time
            ON codex_usage_events(session_id, is_child_replay, timestamp_ms);
        """
        try database.execute(sql: sql)
    }
}

// MARK: - V5: 低写入聚合表
private struct V5AggregateOnlyUsageMigration: DatabaseMigration {
    let version = 5
    let name = "V5AggregateOnlyUsage"

    func apply(database: SQLiteDatabase) throws {
        let sql = """
        -- 按会话/本地日期/模型保存最终聚合结果，替代扫描时持续写事件明细。
        CREATE TABLE IF NOT EXISTS codex_daily_usage_summaries (
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
            summary_provenance TEXT NOT NULL DEFAULT 'eventLedger',
            PRIMARY KEY(session_id, day_key, model_canonical)
        );
        CREATE INDEX IF NOT EXISTS idx_codex_daily_day ON codex_daily_usage_summaries(day_start_ms, day_key);
        CREATE INDEX IF NOT EXISTS idx_codex_daily_model ON codex_daily_usage_summaries(model_canonical, day_start_ms);
        CREATE INDEX IF NOT EXISTS idx_codex_daily_session ON codex_daily_usage_summaries(session_id);

        -- v5 以后保留旧索引可见性；需要重建时由扫描器按源原子替换。
        UPDATE codex_import_sources
            SET status = CASE WHEN status = 'tombstoned' THEN status ELSE status END;
        INSERT OR REPLACE INTO app_metadata (key, value, updated_at)
            VALUES ('codex_usage_generation', unixepoch(), unixepoch());
        """
        try database.execute(sql: sql)
    }

    static func compactIfNeeded(database: SQLiteDatabase) throws {
        let completionKey = "codex_usage_v5_compaction_completed"
        let completed = try database.stringScalar(
            sql: "SELECT value FROM app_metadata WHERE key = ?;",
            bindings: [completionKey]
        )
        guard completed != "1" else { return }

        let pageCount = try database.intScalar(sql: "PRAGMA page_count;")
        let freeListCount = try database.intScalar(sql: "PRAGMA freelist_count;")
        let shouldCompact = freeListCount > 4_096
            || (pageCount > 0 && Double(freeListCount) / Double(pageCount) >= 0.20)

        if shouldCompact {
            try database.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE);")
            try database.execute(sql: "VACUUM;")
            try database.execute(sql: "PRAGMA optimize;")
        }

        try database.executeUpdate(
            sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES (?, '1', unixepoch());",
            bindings: [completionKey]
        )
    }
}

// MARK: - V6: 价格审计、事件账本、解析版本与文件恢复指纹
private struct V6UsageTruthAndRecoveryMigration: DatabaseMigration {
    let version = 6
    let name = "V6UsageTruthAndRecovery"

    func apply(database: SQLiteDatabase) throws {
        try addColumnIfMissing(
            database: database,
            table: "codex_pricing_rules",
            column: "cache_write_usd_nano_per_token",
            definition: "INTEGER"
        )
        try addColumnIfMissing(
            database: database,
            table: "codex_pricing_rules",
            column: "long_context_threshold_tokens",
            definition: "INTEGER"
        )
        try addColumnIfMissing(
            database: database,
            table: "codex_pricing_rules",
            column: "long_context_input_multiplier_ppm",
            definition: "INTEGER"
        )
        try addColumnIfMissing(
            database: database,
            table: "codex_pricing_rules",
            column: "long_context_output_multiplier_ppm",
            definition: "INTEGER"
        )

        try addColumnIfMissing(database: database, table: "codex_import_sources", column: "head_sha256", definition: "TEXT")
        try addColumnIfMissing(database: database, table: "codex_import_sources", column: "tail_sha256", definition: "TEXT")
        try addColumnIfMissing(database: database, table: "codex_import_sources", column: "imported_tail_sha256", definition: "TEXT")
        try addColumnIfMissing(database: database, table: "codex_import_sources", column: "parser_version", definition: "INTEGER NOT NULL DEFAULT 3")
        try addColumnIfMissing(database: database, table: "codex_import_sources", column: "scan_generation", definition: "INTEGER NOT NULL DEFAULT 0")

        try addColumnIfMissing(database: database, table: "codex_usage_events", column: "timestamp_quality", definition: "TEXT NOT NULL DEFAULT 'event_timestamp'")
        try addColumnIfMissing(database: database, table: "codex_usage_events", column: "pricing_catalog_version", definition: "TEXT")

        try database.execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_codex_events_session_time_offset
            ON codex_usage_events(session_id, timestamp_ms DESC, line_offset DESC);
        CREATE INDEX IF NOT EXISTS idx_codex_events_range_session
            ON codex_usage_events(is_child_replay, timestamp_ms, session_id);
        CREATE INDEX IF NOT EXISTS idx_codex_sources_generation
            ON codex_import_sources(scan_generation, status);
        """)

        // Parser v3 改变时间戳、模型和 replay 语义，保留旧索引并标记后台重建。
        try database.execute(sql: """
        UPDATE codex_import_sources
            SET status = CASE WHEN status = 'tombstoned' THEN status ELSE 'stale' END,
                error_message = CASE WHEN status = 'tombstoned' THEN error_message ELSE 'parser rebuild pending' END;
        INSERT OR REPLACE INTO app_metadata (key, value, updated_at)
            VALUES ('codex_usage_generation', unixepoch(), unixepoch());
        INSERT OR REPLACE INTO app_metadata (key, value, updated_at)
            VALUES ('codex_parser_version', '3', unixepoch());
        INSERT OR REPLACE INTO app_metadata (key, value, updated_at)
            VALUES ('codex_parser_rebuild_status', 'pending', unixepoch());
        INSERT OR REPLACE INTO app_metadata (key, value, updated_at)
            VALUES ('codex_parser_rebuild_generation', COALESCE((SELECT CAST(value AS INTEGER) + 1 FROM app_metadata WHERE key = 'codex_parser_rebuild_generation'), 1), unixepoch());
        """)
    }
}
