import Foundation
import XCTest
@testable import QuotaLens

final class PerformanceBenchmarkTests: XCTestCase {
    func testOptionalMillionEventRepriceBenchmark() throws {
        guard ProcessInfo.processInfo.environment["QUOTALENS_RUN_PERF_BENCHMARK"] == "1" else {
            throw XCTSkip("Set QUOTALENS_RUN_PERF_BENCHMARK=1 to run the million-event reprice benchmark.")
        }

        let directory = try makeTemporaryDirectory(named: "QuotaLensRepriceBenchmark")
        let database = try makeMigratedDatabase(in: directory)
        try PricingCatalogService.shared.ensureCatalogInstalled(database: database)
        let timestamp = BundledPricingCatalog.publishedAtMs

        try database.executeUpdate(
            sql: """
            INSERT INTO codex_sessions (
                session_id, root_session_id, parent_session_id, depth, source_path,
                relative_path, bucket, title, project_name, cwd, created_at, updated_at,
                last_event_at, event_count, total_tokens, input_tokens, cached_input_tokens,
                cache_write_input_tokens, output_tokens, reasoning_output_tokens,
                estimated_cost_usd_nano, pricing_status, metadata_fingerprint,
                has_subagents, agent_type
            ) VALUES (
                'benchmark-session', 'benchmark-session', NULL, 0, '/tmp/benchmark.jsonl',
                'sessions/benchmark.jsonl', 'active', 'Benchmark', 'Fixture', '/tmp',
                ?, ?, ?, 1000000, 1000000, 1000000, 0, 0, 0, 0, 0,
                'fullyUnpriced', NULL, 0, NULL
            );
            """,
            bindings: [timestamp, timestamp, timestamp]
        )

        try database.executeUpdate(
            sql: """
            WITH RECURSIVE sequence(value) AS (
                VALUES(1)
                UNION ALL
                SELECT value + 1 FROM sequence WHERE value < 1000000
            )
            INSERT INTO codex_usage_events (
                event_id, session_id, root_session_id, turn_index, call_index,
                timestamp_ms, model_raw, model_canonical, service_tier, reasoning_effort,
                input_tokens, cached_input_tokens, cache_write_input_tokens,
                output_tokens, reasoning_output_tokens, total_tokens, uncached_input_tokens,
                estimated_cost_usd_nano, pricing_rule_id, pricing_status,
                usage_derivation, attribution_quality, is_child_replay, source_path,
                line_offset, line_bytes, payload_sha256, created_at, timestamp_quality,
                pricing_catalog_version
            )
            SELECT
                printf('bench-%07d', value), 'benchmark-session', 'benchmark-session',
                0, value, ?, 'gpt-5.6-terra', 'gpt-5.6-terra', NULL, NULL,
                1, 0, 0, 0, 0, 1, 1,
                0, NULL, 'unpricedUnknownModel', 'explicit_last_usage',
                'direct_turn_context', 0, '/tmp/benchmark.jsonl', value,
                1, NULL, ?, 'event_timestamp', 'legacy-benchmark'
            FROM sequence;
            """,
            bindings: [timestamp, timestamp]
        )

        let startedAt = CFAbsoluteTimeGetCurrent()
        try PricingCatalogService.shared.repriceAllUsageEvents(database: database, batchSize: 1_000) { progress, message in
            if progress == 0.7 || progress == 0.9 || progress == 1 {
                let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
                let walPath = directory.appendingPathComponent("test.sqlite-wal").path
                let walBytes = (try? FileManager.default.attributesOfItem(atPath: walPath)[.size] as? NSNumber)?.int64Value ?? 0
                print(String(format: "重计价阶段 %.0f%%: %@，累计 %.3f 秒，WAL %.1f MiB", progress * 100, message, elapsed, Double(walBytes) / 1_048_576))
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt

        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_usage_events;"), 1_000_000)
        XCTAssertEqual(try database.intScalar(
            sql: "SELECT COUNT(*) FROM codex_usage_events WHERE pricing_catalog_version = ?;",
            bindings: [BundledPricingCatalog.currentVersion]
        ), 1_000_000)
        XCTAssertEqual(try database.int64Scalar(
            sql: "SELECT estimated_cost_usd_nano FROM codex_sessions WHERE session_id = 'benchmark-session';"
        ), 2_000_000_000)
        print(String(format: "QuotaLens million-event reprice benchmark: %.3f seconds", elapsed))
    }
}
