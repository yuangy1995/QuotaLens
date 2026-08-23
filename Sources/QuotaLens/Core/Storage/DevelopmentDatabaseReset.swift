// Development-stage reset for databases polluted by pre-MVP synthetic data.

import Foundation
import SQLite3

public struct DevelopmentDatabaseReset: Sendable {
    public static func resetIfLegacySyntheticDataExists(databasePath: String) {
        guard FileManager.default.fileExists(atPath: databasePath),
              containsLegacySyntheticData(databasePath: databasePath) else {
            return
        }

        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: databasePath + suffix)
        }
    }

    private static func containsLegacySyntheticData(databasePath: String) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            return false
        }
        defer { sqlite3_close(db) }

        return scalarCount(db, "SELECT COUNT(*) FROM usage_events WHERE source = 'app_server' AND allocation_quality = 'exact' AND event_id LIKE 'ev_%';") > 0
            || scalarCount(db, "SELECT COUNT(*) FROM rate_limit_snapshots WHERE raw_json = '{}';") > 0
            || scalarCount(db, "SELECT COUNT(*) FROM account_daily_snapshots WHERE raw_json = '{}';") > 0
            || scalarCount(db, "SELECT COUNT(*) FROM accounts WHERE account_key LIKE 'acc_%@%';") > 0
            || scalarCount(db, "SELECT COUNT(*) FROM quota_cycles WHERE cycle_id = 'cycle_2026_08_w3';") > 0
    }

    private static func scalarCount(_ db: OpaquePointer, _ sql: String) -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return 0
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }
        return sqlite3_column_int64(statement, 0)
    }
}
