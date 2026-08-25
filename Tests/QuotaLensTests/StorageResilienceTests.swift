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

    func testParserMigrationClearsOnlyDerivedCodexUsageData() throws {
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

        // Exercise the V6 -> V7 path against the current schema. V7 must force
        // only the derived Codex index to rebuild and preserve core quota data.
        try database.execute(sql: "PRAGMA user_version = 6;")
        try SchemaMigrations.migrate(database: database)

        XCTAssertEqual(try database.intScalar(sql: "PRAGMA user_version;"), SchemaMigrations.targetSchemaVersion)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM accounts;"), 1)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM rate_limit_snapshots;"), 1)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_import_sources;"), 0)
        XCTAssertEqual(
            try database.stringScalar(sql: "SELECT value FROM app_metadata WHERE key = 'codex_parser_version';"),
            String(ParserCheckpoint.currentParserVersion)
        )
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

        XCTAssertEqual(try database.intScalar(sql: "PRAGMA user_version;"), 11)
        for table in ["codex_session_summaries", "codex_daily_usage_summaries"] {
            let columns = try database.executeQuery(sql: "PRAGMA table_info(\(table));") { statement in
                String(cString: sqlite3_column_text(statement, 1))
            }
            XCTAssertTrue(columns.contains("unpriced_token_count"), table)
        }
        XCTAssertNil(try database.stringScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'pricing_reprice_catalog_version';"
        ))
    }
}
