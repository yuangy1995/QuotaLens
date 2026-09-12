import Foundation
import SQLite3

struct CodexCapacityStore: Sendable {
    let database: SQLiteDatabase

    func record(_ observation: CodexCapacityObservation) throws {
        let data = try JSONEncoder().encode(observation)
        let json = String(decoding: data, as: UTF8.self)
        try database.execute(sql: """
            INSERT OR IGNORE INTO codex_capacity_observations (account_key, observed_at, payload)
            VALUES (?, ?, ?);
            """, bindings: [observation.accountKey, observation.observedAt, json])
    }

    func observations(accountKey: String) throws -> [CodexCapacityObservation] {
        let payloads = try database.executeQuery(sql: """
            SELECT payload FROM codex_capacity_observations WHERE account_key = ? ORDER BY observed_at;
            """, bindings: [accountKey]) { statement in
                String(cString: sqlite3_column_text(statement, 0))
            }
        return try payloads.map { try JSONDecoder().decode(CodexCapacityObservation.self, from: Data($0.utf8)) }
    }
}

struct V21CodexCapacityMigration: DatabaseMigration {
    let version = 21
    let name = "V21CodexCapacity"
    func apply(database: SQLiteDatabase) throws {
        try database.execute(sql: """
            CREATE TABLE IF NOT EXISTS codex_capacity_observations (
                account_key TEXT NOT NULL,
                observed_at INTEGER NOT NULL,
                payload TEXT NOT NULL,
                PRIMARY KEY (account_key, observed_at)
            );
            """)
    }
}
