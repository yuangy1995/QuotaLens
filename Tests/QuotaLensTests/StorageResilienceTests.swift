import SQLite3
import XCTest
@testable import QuotaLens

final class StorageResilienceTests: XCTestCase {
    func testInMemoryRecoveryDatabaseSupportsFullSchema() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try SchemaMigrations.migrate(database: database)
        XCTAssertEqual(
            try database.intScalar(sql: "PRAGMA user_version;"),
            SchemaMigrations.targetSchemaVersion
        )
        XCTAssertEqual(try database.stringScalar(sql: "PRAGMA integrity_check(1);"), "ok")
    }

    func testDisconnectedFallbackThrowsInsteadOfTerminatingProcess() {
        let database = SQLiteDatabase.disconnectedFallback()
        XCTAssertThrowsError(try database.intScalar(sql: "SELECT 1;")) { error in
            XCTAssertTrue(error.localizedDescription.contains("数据库未连接"))
        }
    }

    func testFailedBeginDoesNotRunNestedTransactionInAutocommitMode() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try database.execute(sql: "CREATE TABLE transaction_probe (id INTEGER PRIMARY KEY);")

        XCTAssertThrowsError(try database.transaction {
            try database.executeUpdate(
                sql: "INSERT INTO transaction_probe (id) VALUES (1);",
                bindings: []
            )
            try database.transaction {
                try database.executeUpdate(
                    sql: "INSERT INTO transaction_probe (id) VALUES (2);",
                    bindings: []
                )
            }
        })

        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM transaction_probe;"), 0)
        try database.transaction {
            try database.executeUpdate(
                sql: "INSERT INTO transaction_probe (id) VALUES (3);",
                bindings: []
            )
        }
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM transaction_probe;"), 1)
    }

    func testParserMigrationKeepsOldCodexIndexVisibleAndMarksRebuildPending() throws {
        let directory = try makeTemporaryDirectory(named: "QuotaLensMigration")
        let database = try makeMigratedDatabase(in: directory)

        try database.executeUpdate(
            sql: "INSERT INTO accounts VALUES ('account-fixture', NULL, 'pro', 1, 2);",
            bindings: []
        )
        try database.executeUpdate(
            sql: """
            INSERT INTO rate_limit_snapshots (
                account_key, observed_at, limit_id, slot, used_percent_milli, raw_json
            ) VALUES ('account-fixture', 1, 'codex', 'primary', 500, '{}');
            """,
            bindings: []
        )
        try database.executeUpdate(
            sql: """
            INSERT INTO codex_import_sources (
                source_path, relative_path, bucket, device_id, inode, file_size,
                mtime_ms, last_imported_size, last_imported_line, status
            ) VALUES ('/tmp/fixture.jsonl', 'sessions/fixture.jsonl', 'active', 1, 2, 3, 4, 3, 1, 'indexed');
            """,
            bindings: []
        )
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
                'legacy-session', 'legacy-session', NULL, 0, '/tmp/fixture.jsonl',
                'sessions/fixture.jsonl', 'active', 'Legacy', 'Fixture', '/tmp',
                1, 1, 1, 1, 100, 100, 0, 0, 0, 0, 123, 'priced', NULL, 0, NULL
            );
            """,
            bindings: []
        )

        // V6 -> V7/V9 会触发 Parser 重建，但旧索引必须继续可见，不能先清空正式表。
        try database.execute(sql: "PRAGMA user_version = 6;")
        try SchemaMigrations.migrate(database: database)

        XCTAssertEqual(try database.intScalar(sql: "PRAGMA user_version;"), SchemaMigrations.targetSchemaVersion)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM accounts;"), 1)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM rate_limit_snapshots;"), 1)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_import_sources;"), 1)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_sessions;"), 1)
        XCTAssertEqual(
            try database.stringScalar(sql: "SELECT status FROM codex_import_sources WHERE source_path = '/tmp/fixture.jsonl';"),
            "stale"
        )
        XCTAssertEqual(
            try database.stringScalar(sql: "SELECT value FROM app_metadata WHERE key = 'codex_parser_rebuild_status';"),
            "pending"
        )
        XCTAssertEqual(
            try database.stringScalar(sql: "SELECT value FROM app_metadata WHERE key = 'codex_parser_version';"),
            String(ParserCheckpoint.currentParserVersion)
        )
        try PricingCatalogService.shared.ensureCatalogInstalled(database: database)
        XCTAssertEqual(try database.int64Scalar(sql: "SELECT total_tokens FROM codex_sessions WHERE session_id = 'legacy-session';"), 100)
        XCTAssertEqual(try database.int64Scalar(sql: "SELECT estimated_cost_usd_nano FROM codex_sessions WHERE session_id = 'legacy-session';"), 123)
        XCTAssertEqual(try database.stringScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'pricing_migration_state';"
        ), PricingMigrationState.pendingSources.rawValue)
    }

    func testV10DeveloperDatabaseUpgradesToExactCoverageSchema() throws {
        let directory = try makeTemporaryDirectory(named: "QuotaLensV10CoverageUpgrade")
        let database = try makeMigratedDatabase(in: directory)
        try database.execute(sql: "ALTER TABLE codex_session_summaries DROP COLUMN unpriced_token_count;")
        try database.execute(sql: "ALTER TABLE codex_daily_usage_summaries DROP COLUMN unpriced_token_count;")
        try database.executeUpdate(
            sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('pricing_reprice_catalog_version', 'developer-v10', unixepoch());",
            bindings: []
        )
        try database.execute(sql: "PRAGMA user_version = 10;")

        try SchemaMigrations.migrate(database: database)

        XCTAssertEqual(try database.intScalar(sql: "PRAGMA user_version;"), SchemaMigrations.targetSchemaVersion)
        for table in ["codex_session_summaries", "codex_daily_usage_summaries"] {
            let columns = try database.executeQuery(sql: "PRAGMA table_info(\(table));") { statement in
                String(cString: sqlite3_column_text(statement, 1))
            }
            XCTAssertTrue(columns.contains("unpriced_token_count"), table)
            XCTAssertTrue(columns.contains("unpriced_unknown_model_event_count"), table)
            XCTAssertTrue(columns.contains("unpriced_overflow_token_count"), table)
        }
        XCTAssertEqual(
            try database.intScalar(sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'codex_scan_diagnostics';"),
            1
        )
        XCTAssertNil(try database.stringScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'pricing_reprice_catalog_version';"
        ))
    }
}
