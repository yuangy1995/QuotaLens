// QuotaLens 数据库架构迁移与初始化
// 严格遵循实施计划 14 节设计，建立 10+ 核心业务表与高性能索引

import Foundation

public struct SchemaMigrations {
    public static func migrate(database: SQLiteDatabase) throws {
        let migrationSql = """
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

        PRAGMA user_version = 1;
        """

        try database.execute(sql: migrationSql)
    }
}
