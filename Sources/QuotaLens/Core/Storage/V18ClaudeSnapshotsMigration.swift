import Foundation

struct V18ClaudeSnapshotsMigration: DatabaseMigration {
    let version = 18
    let name = "Claude cumulative snapshots and source fingerprints"

    func apply(database: SQLiteDatabase) throws {
        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS claude_source_hashes (
            source_path TEXT PRIMARY KEY, content_hash TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS claude_usage_snapshots (
            source_path TEXT NOT NULL, session_id TEXT NOT NULL, root_session_id TEXT NOT NULL,
            message_id TEXT NOT NULL, day_key TEXT NOT NULL, timestamp_ms INTEGER NOT NULL,
            model_raw TEXT NOT NULL, uncached_input INTEGER NOT NULL, cached_input INTEGER NOT NULL,
            cache_write_5m INTEGER NOT NULL, cache_write_1h INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
            line_offset INTEGER NOT NULL, line_bytes INTEGER NOT NULL, total_tokens INTEGER NOT NULL,
            PRIMARY KEY(source_path, session_id, message_id, day_key)
        );
        CREATE TRIGGER IF NOT EXISTS claude_snapshots_session_deleted
        AFTER DELETE ON codex_sessions BEGIN
            DELETE FROM claude_usage_snapshots WHERE session_id = OLD.session_id;
        END;
        CREATE INDEX IF NOT EXISTS idx_claude_snapshots_session
            ON claude_usage_snapshots(session_id, message_id, day_key);
        """)
    }
}
