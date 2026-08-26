import SQLite3
import XCTest
@testable import QuotaLens

final class ImporterRecoveryTests: XCTestCase {
    func testFirstImportNoChangeAppendRewriteMoveAndDelete() async throws {
        let root = try makeTemporaryDirectory(named: "QuotaLensImporter")
        let paths = CodexHistoryPaths(rootURL: root)
        try FileManager.default.createDirectory(at: paths.sessionsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.archivedSessionsURL, withIntermediateDirectories: true)
        let database = try makeMigratedDatabase(in: root)
        let importer = CodexUsageImportActor(database: database)
        let originalFlag = UsageFeatureFlags.shared.isScanArchivedSessionsEnabled
        UsageFeatureFlags.shared.isScanArchivedSessionsEnabled = true
        addTeardownBlock { UsageFeatureFlags.shared.isScanArchivedSessionsEnabled = originalFlag }

        let sessionID = "11111111-1111-1111-1111-111111111111"
        let fileName = "rollout-2026-08-20T12-00-00-\(sessionID).jsonl"
        let activeFile = paths.sessionsURL.appendingPathComponent(fileName)
        let initialDate = Date(timeIntervalSince1970: 1_787_227_200)
        try overwriteFile(
            activeFile,
            with: rolloutText(sessionId: sessionID, input: 10, output: 5),
            modificationDate: initialDate
        )

        let first = try await importer.importCodexHistory(paths: paths)
        XCTAssertEqual(first.sourcesScanned, 1)
        XCTAssertEqual(first.eventsInserted, 1)
        XCTAssertEqual(try sessionTotal(database, sessionID: sessionID), 15)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_usage_events;"), 1)
        _ = try XCTUnwrap(database.stringScalar(sql: "SELECT event_id FROM codex_usage_events LIMIT 1;"))

        let unchanged = try await importer.importCodexHistory(paths: paths)
        XCTAssertEqual(unchanged.eventsInserted, 0)
        XCTAssertEqual(unchanged.bytesRead, 0)
        XCTAssertEqual(try sessionTotal(database, sessionID: sessionID), 15)

        // 10 -> 20 keeps the fixture byte length identical and forces a same-size rewrite.
        let rewritten = rolloutText(sessionId: sessionID, input: 20, output: 5)
        try overwriteFile(activeFile, with: rewritten, modificationDate: initialDate.addingTimeInterval(2))
        _ = try await importer.importCodexHistory(paths: paths)
        XCTAssertEqual(try sessionTotal(database, sessionID: sessionID), 25)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_usage_events;"), 1)
        XCTAssertEqual(
            try database.stringScalar(sql: "SELECT rebuild_reason FROM codex_import_sources LIMIT 1;"),
            "same_size_rewrite"
        )

        let appended = usageLine(timestamp: "2026-08-20T12:05:00Z", input: 5, output: 2, totalInput: 25, totalOutput: 7)
        try appendFile(activeFile, with: appended, modificationDate: initialDate.addingTimeInterval(4))
        let appendResult = try await importer.importCodexHistory(paths: paths)
        XCTAssertEqual(appendResult.eventsInserted, 1)
        XCTAssertEqual(try sessionTotal(database, sessionID: sessionID), 32)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_usage_events;"), 2)

        let truncatedReplacement = rolloutText(sessionId: sessionID, input: 3, output: 1)
        try overwriteFile(activeFile, with: truncatedReplacement, modificationDate: initialDate.addingTimeInterval(5))
        _ = try await importer.importCodexHistory(paths: paths)
        XCTAssertEqual(try sessionTotal(database, sessionID: sessionID), 4)
        XCTAssertEqual(
            try database.stringScalar(sql: "SELECT rebuild_reason FROM codex_import_sources LIMIT 1;"),
            "file_truncated"
        )

        let largerReplacement = rolloutText(sessionId: sessionID, input: 200, output: 50)
            + "{\"padding\":\"\(String(repeating: "x", count: 2_000))\"}\n"
        try overwriteFile(activeFile, with: largerReplacement, modificationDate: initialDate.addingTimeInterval(6))
        _ = try await importer.importCodexHistory(paths: paths)
        XCTAssertEqual(try sessionTotal(database, sessionID: sessionID), 250)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_usage_events;"), 1)

        let eventBeforeMove = try XCTUnwrap(database.stringScalar(sql: "SELECT event_id FROM codex_usage_events LIMIT 1;"))
        let archivedFile = paths.archivedSessionsURL.appendingPathComponent(fileName)
        try FileManager.default.moveItem(at: activeFile, to: archivedFile)
        let moveResult = try await importer.importCodexHistory(paths: paths)
        XCTAssertEqual(moveResult.eventsInserted, 0)
        XCTAssertEqual(try sessionTotal(database, sessionID: sessionID), 250)
        XCTAssertEqual(try database.stringScalar(
            sql: "SELECT bucket FROM codex_sessions WHERE session_id = ?;",
            bindings: [sessionID]
        ), SessionBucket.archived.rawValue)
        XCTAssertEqual(try database.stringScalar(sql: "SELECT event_id FROM codex_usage_events LIMIT 1;"), eventBeforeMove)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_import_sources;"), 1)

        try FileManager.default.removeItem(at: archivedFile)
        _ = try await importer.importCodexHistory(paths: paths)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_sessions;"), 0)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_usage_events;"), 0)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_import_sources WHERE status = 'tombstoned';"), 1)
    }

    func testIncrementalAndForcedFullRebuildProduceIdenticalTotals() async throws {
        let root = try makeTemporaryDirectory(named: "QuotaLensImporterParity")
        let paths = CodexHistoryPaths(rootURL: root)
        try FileManager.default.createDirectory(at: paths.sessionsURL, withIntermediateDirectories: true)
        let database = try makeMigratedDatabase(in: root)
        let importer = CodexUsageImportActor(database: database)
        let sessionID = "22222222-2222-2222-2222-222222222222"
        let file = paths.sessionsURL.appendingPathComponent("rollout-2026-08-20T12-00-00-\(sessionID).jsonl")
        try overwriteFile(file, with: rolloutText(
            sessionId: sessionID,
            model: "gpt-5.6-sol",
            input: 10,
            cached: 2,
            cacheWrite: 3,
            output: 5
        ))
        _ = try await importer.importCodexHistory(paths: paths)
        try appendFile(file, with: usageLine(
            timestamp: "2026-08-20T13:00:00Z",
            input: 7,
            cached: 3,
            cacheWrite: 2,
            output: 4,
            totalInput: 17,
            totalCached: 5,
            totalCacheWrite: 5,
            totalOutput: 9
        ))
        _ = try await importer.importCodexHistory(paths: paths)
        let incremental = try sessionFacts(database, sessionID: sessionID)
        XCTAssertEqual(incremental.tokens, 26)
        XCTAssertEqual(incremental.cacheWriteTokens, 5)
        XCTAssertEqual(incremental.cost, 338_750)

        _ = try await importer.importCodexHistory(paths: paths, forceRebuild: true)
        let rebuilt = try sessionFacts(database, sessionID: sessionID)
        XCTAssertEqual(incremental.tokens, rebuilt.tokens)
        XCTAssertEqual(incremental.cacheWriteTokens, rebuilt.cacheWriteTokens)
        XCTAssertEqual(incremental.events, rebuilt.events)
        XCTAssertEqual(incremental.cost, rebuilt.cost)
    }

    func testSkippedNonRolloutJSONLIsPersistedAsScanDiagnosticWithoutTombstone() async throws {
        let root = try makeTemporaryDirectory(named: "QuotaLensScanDiagnostics")
        let paths = CodexHistoryPaths(rootURL: root)
        try FileManager.default.createDirectory(at: paths.sessionsURL, withIntermediateDirectories: true)
        let skipped = paths.sessionsURL.appendingPathComponent("notes.jsonl")
        try overwriteFile(skipped, with: "{\"type\":\"metadata\",\"message\":\"not a rollout\"}\n")
        let database = try makeMigratedDatabase(in: root)
        let importer = CodexUsageImportActor(database: database)

        let summary = try await importer.importCodexHistory(paths: paths)

        XCTAssertEqual(summary.sourcesScanned, 0)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_import_sources;"), 0)
        XCTAssertEqual(try database.intScalar(
            sql: "SELECT COUNT(*) FROM codex_scan_diagnostics WHERE diagnostic_code = 'non_rollout_jsonl_probe_miss';"
        ), 1)
        let diagnostics = try UsageAnalyticsRepository(database: database).fetchDiagnostics()
        XCTAssertEqual(diagnostics.skippedNonRolloutJSONLCount, 1)
        XCTAssertEqual(diagnostics.parserRebuildStatus, "completed")
        XCTAssertEqual(diagnostics.parserRebuildProcessedSources, 0)
        XCTAssertEqual(diagnostics.parserRebuildTotalSources, 0)
    }

    func testPartialEOFIsResumedWithoutReplayingCommittedEvent() async throws {
        let root = try makeTemporaryDirectory(named: "QuotaLensImporterPartial")
        let paths = CodexHistoryPaths(rootURL: root)
        try FileManager.default.createDirectory(at: paths.sessionsURL, withIntermediateDirectories: true)
        let database = try makeMigratedDatabase(in: root)
        let importer = CodexUsageImportActor(database: database)
        let sessionID = "33333333-3333-3333-3333-333333333333"
        let file = paths.sessionsURL.appendingPathComponent("rollout-2026-08-20T12-00-00-\(sessionID).jsonl")
        let first = rolloutText(sessionId: sessionID, input: 10, output: 5)
        let second = usageLine(timestamp: "2026-08-20T14:00:00Z", input: 3, output: 2, totalInput: 13, totalOutput: 7)
        let split = second.index(second.startIndex, offsetBy: second.count / 2)
        try overwriteFile(file, with: first + second[..<split])
        _ = try await importer.importCodexHistory(paths: paths)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_usage_events;"), 1)

        try appendFile(file, with: String(second[split...]))
        _ = try await importer.importCodexHistory(paths: paths)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_usage_events;"), 2)
        XCTAssertEqual(try sessionTotal(database, sessionID: sessionID), 20)
    }

    func testDisabledArchivedScanDoesNotTombstoneMissingArchivedSources() async throws {
        let root = try makeTemporaryDirectory(named: "QuotaLensArchivedTombstone")
        let paths = CodexHistoryPaths(rootURL: root)
        try FileManager.default.createDirectory(at: paths.sessionsURL, withIntermediateDirectories: true)
        let archivedPath = paths.archivedSessionsURL
            .appendingPathComponent("rollout-2026-08-20T12-00-00-archived.jsonl")
            .path
        let database = try makeMigratedDatabase(in: root)
        try database.executeUpdate(
            sql: """
            INSERT INTO codex_import_sources (
                source_path, relative_path, bucket, device_id, inode, file_size,
                mtime_ms, scan_generation, status, parser_version
            ) VALUES (?, 'archived_sessions/rollout-2026-08-20T12-00-00-archived.jsonl', 'archived', 1, 2, 1, 1, 0, 'indexed', ?);
            """,
            bindings: [archivedPath, ParserCheckpoint.currentParserVersion]
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
                'archived-session', 'archived-session', NULL, 0, ?,
                'archived_sessions/rollout-2026-08-20T12-00-00-archived.jsonl',
                'archived', 'Archived', 'Fixture', '/tmp', 1, 1, 1,
                1, 1, 1, 0, 0, 0, 0, 0, 'priced', NULL, 0, NULL
            );
            """,
            bindings: [archivedPath]
        )

        let originalFlag = UsageFeatureFlags.shared.isScanArchivedSessionsEnabled
        UsageFeatureFlags.shared.isScanArchivedSessionsEnabled = false
        addTeardownBlock { UsageFeatureFlags.shared.isScanArchivedSessionsEnabled = originalFlag }

        _ = try await CodexUsageImportActor(database: database).importCodexHistory(paths: paths)
        XCTAssertEqual(
            try database.stringScalar(sql: "SELECT status FROM codex_import_sources WHERE source_path = ?;", bindings: [archivedPath]),
            "indexed"
        )
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_sessions WHERE session_id = 'archived-session';"), 1)
    }

    func testFailedActiveScanDoesNotTombstoneMissingActiveSources() async throws {
        let root = try makeTemporaryDirectory(named: "QuotaLensActiveScanFailure")
        let paths = CodexHistoryPaths(rootURL: root)
        try FileManager.default.createDirectory(at: paths.sessionsURL, withIntermediateDirectories: true)
        let sourcePath = paths.sessionsURL.appendingPathComponent("rollout-2026-08-20T12-00-00-active.jsonl").path
        let database = try makeMigratedDatabase(in: root)
        try database.executeUpdate(
            sql: """
            INSERT INTO codex_import_sources (
                source_path, relative_path, bucket, device_id, inode, file_size,
                mtime_ms, scan_generation, status, parser_version
            ) VALUES (?, 'sessions/rollout-2026-08-20T12-00-00-active.jsonl', 'active', 1, 2, 1, 1, 0, 'indexed', ?);
            """,
            bindings: [sourcePath, ParserCheckpoint.currentParserVersion]
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
                'active-session', 'active-session', NULL, 0, ?,
                'sessions/rollout-2026-08-20T12-00-00-active.jsonl',
                'active', 'Active', 'Fixture', '/tmp', 1, 1, 1,
                1, 1, 1, 0, 0, 0, 0, 0, 'priced', NULL, 0, NULL
            );
            """,
            bindings: [sourcePath]
        )

        let importer = CodexUsageImportActor(database: database) { _, _ in
            ScanOutcome(active: .failed("enumerator failed"), archived: .disabled, sources: [])
        }
        _ = try await importer.importCodexHistory(paths: paths)

        XCTAssertEqual(
            try database.stringScalar(sql: "SELECT status FROM codex_import_sources WHERE source_path = ?;", bindings: [sourcePath]),
            "indexed"
        )
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_sessions WHERE session_id = 'active-session';"), 1)
        XCTAssertEqual(try database.stringScalar(sql: "SELECT status FROM codex_import_runs ORDER BY started_at DESC LIMIT 1;"), "partial")
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_import_runs WHERE status = 'success';"), 0)
        let runError = try XCTUnwrap(database.stringScalar(
            sql: "SELECT error_message FROM codex_import_runs ORDER BY started_at DESC LIMIT 1;"
        ))
        XCTAssertTrue(
            runError.contains("Some local records cannot be read right now")
                || runError.contains("部分本地记录暂时无法读取")
        )
        XCTAssertEqual(
            try database.stringScalar(sql: "SELECT value FROM app_metadata WHERE key = 'codex_parser_rebuild_status';"),
            "failed"
        )

        let sessionID = "77777777-7777-7777-7777-777777777777"
        let file = paths.sessionsURL.appendingPathComponent("rollout-2026-08-20T12-00-00-\(sessionID).jsonl")
        try overwriteFile(file, with: rolloutText(sessionId: sessionID, input: 4, output: 1))
        _ = try await CodexUsageImportActor(database: database).importCodexHistory(paths: paths)
        XCTAssertEqual(
            try database.stringScalar(sql: "SELECT value FROM app_metadata WHERE key = 'codex_parser_rebuild_status';"),
            "completed"
        )
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_sessions WHERE session_id = ?;", bindings: [sessionID]), 1)
    }

    func testSuccessfulRootTombstonesOnlyItsBucketWhenOtherRootFails() async throws {
        let root = try makeTemporaryDirectory(named: "QuotaLensIndependentBucketFailure")
        let paths = CodexHistoryPaths(rootURL: root)
        let database = try makeMigratedDatabase(in: root)
        let activePath = paths.sessionsURL.appendingPathComponent("missing-active.jsonl").path
        let archivedPath = paths.archivedSessionsURL.appendingPathComponent("missing-archived.jsonl").path

        for (sessionID, sourcePath, relativePath, bucket, inode) in [
            ("active-session", activePath, "sessions/missing-active.jsonl", "active", 1),
            ("archived-session", archivedPath, "archived_sessions/missing-archived.jsonl", "archived", 2)
        ] {
            try database.executeUpdate(
                sql: """
                INSERT INTO codex_import_sources (
                    source_path, relative_path, bucket, device_id, inode, file_size,
                    mtime_ms, scan_generation, status, parser_version
                ) VALUES (?, ?, ?, 1, ?, 1, 1, 0, 'indexed', ?);
                """,
                bindings: [sourcePath, relativePath, bucket, inode, ParserCheckpoint.currentParserVersion]
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
                    ?, ?, NULL, 0, ?, ?, ?, 'Fixture', 'Fixture', '/tmp', 1, 1, 1,
                    1, 1, 1, 0, 0, 0, 0, 0, 'priced', NULL, 0, NULL
                );
                """,
                bindings: [sessionID, sessionID, sourcePath, relativePath, bucket]
            )
        }

        let originalFlag = UsageFeatureFlags.shared.isScanArchivedSessionsEnabled
        UsageFeatureFlags.shared.isScanArchivedSessionsEnabled = true
        addTeardownBlock { UsageFeatureFlags.shared.isScanArchivedSessionsEnabled = originalFlag }

        let importer = CodexUsageImportActor(database: database) { _, _ in
            ScanOutcome(active: .success, archived: .failed("archived enumerator failed"), sources: [])
        }
        _ = try await importer.importCodexHistory(paths: paths)

        XCTAssertEqual(
            try database.stringScalar(sql: "SELECT status FROM codex_import_sources WHERE source_path = ?;", bindings: [activePath]),
            "tombstoned"
        )
        XCTAssertEqual(
            try database.stringScalar(sql: "SELECT status FROM codex_import_sources WHERE source_path = ?;", bindings: [archivedPath]),
            "indexed"
        )
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_sessions WHERE session_id = 'active-session';"), 0)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_sessions WHERE session_id = 'archived-session';"), 1)
        XCTAssertEqual(try database.stringScalar(sql: "SELECT status FROM codex_import_runs LIMIT 1;"), "partial")
    }

    func testForcedRebuildPublishesFromShadowOnlyAfterCompleteSuccess() async throws {
        let root = try makeTemporaryDirectory(named: "QuotaLensParserShadowRecovery")
        let paths = CodexHistoryPaths(rootURL: root)
        try FileManager.default.createDirectory(at: paths.sessionsURL, withIntermediateDirectories: true)
        let database = try makeMigratedDatabase(in: root)
        let importer = CodexUsageImportActor(database: database)
        let sessionID = "88888888-8888-8888-8888-888888888888"
        let file = paths.sessionsURL.appendingPathComponent(
            "rollout-2026-08-20T12-00-00-\(sessionID).jsonl"
        )

        try overwriteFile(file, with: rolloutText(sessionId: sessionID, input: 10, output: 5))
        _ = try await importer.importCodexHistory(paths: paths)
        _ = try await importer.importCodexHistory(paths: paths, forceRebuild: true)

        let originalTokens = try database.int64Scalar(
            sql: "SELECT total_tokens FROM codex_sessions WHERE session_id = ?;",
            bindings: [sessionID]
        )
        try overwriteFile(file, with: rolloutText(sessionId: sessionID, input: 40, output: 7))
        try database.execute(sql: """
        CREATE TEMP TRIGGER fail_parser_shadow_insert
        BEFORE INSERT ON codex_usage_events_parser_shadow
        BEGIN
            SELECT RAISE(ABORT, 'simulated parser shadow failure');
        END;
        """)

        do {
            _ = try await importer.importCodexHistory(paths: paths, forceRebuild: true)
            XCTFail("影子重建注入失败后不应成功")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("simulated parser shadow failure"))
        }

        XCTAssertEqual(try database.int64Scalar(
            sql: "SELECT total_tokens FROM codex_sessions WHERE session_id = ?;",
            bindings: [sessionID]
        ), originalTokens)
        XCTAssertEqual(try database.stringScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'usage_aggregation_timezone_id';"
        ), TimeZone.current.identifier)
        XCTAssertEqual(try database.stringScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'codex_parser_rebuild_status';"
        ), "failed")
        XCTAssertEqual(try database.intScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'codex_parser_rebuild_processed_sources';"
        ), 0)
        XCTAssertEqual(try database.intScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'codex_parser_rebuild_total_sources';"
        ), 1)

        try database.execute(sql: "DROP TRIGGER temp.fail_parser_shadow_insert;")
        _ = try await importer.importCodexHistory(paths: paths, forceRebuild: true)

        XCTAssertEqual(try database.int64Scalar(
            sql: "SELECT total_tokens FROM codex_sessions WHERE session_id = ?;",
            bindings: [sessionID]
        ), 47)
        XCTAssertEqual(try database.stringScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'usage_aggregation_timezone_id';"
        ), TimeZone.current.identifier)
        XCTAssertEqual(try database.stringScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'codex_parser_rebuild_status';"
        ), "completed")
        XCTAssertEqual(try database.intScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'codex_parser_rebuild_processed_sources';"
        ), 1)
        XCTAssertEqual(try database.intScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'codex_parser_rebuild_total_sources';"
        ), 1)
    }

    func testMissingParserUpgradeSourceRetainsHistoryAndRetriesWhenRestored() async throws {
        let root = try makeTemporaryDirectory(named: "QuotaLensMissingUpgradeSource")
        let paths = CodexHistoryPaths(rootURL: root)
        try FileManager.default.createDirectory(at: paths.sessionsURL, withIntermediateDirectories: true)
        let database = try makeMigratedDatabase(in: root)
        let importer = CodexUsageImportActor(database: database)
        let sessionID = "99999999-9999-9999-9999-999999999999"
        let file = paths.sessionsURL.appendingPathComponent("rollout-2026-08-20T12-00-00-\(sessionID).jsonl")
        try overwriteFile(file, with: rolloutText(sessionId: sessionID, input: 10, output: 5))
        _ = try await importer.importCodexHistory(paths: paths)
        try database.execute(sql: "UPDATE codex_import_sources SET parser_version = 0, status = 'stale';")
        try FileManager.default.removeItem(at: file)

        for _ in 0..<2 {
            let summary = try await importer.importCodexHistory(paths: paths)
            XCTAssertNotNil(summary.warningMessage)
            XCTAssertEqual(try sessionTotal(database, sessionID: sessionID), 15)
            XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_usage_events;"), 1)
            XCTAssertEqual(try database.stringScalar(
                sql: "SELECT value FROM app_metadata WHERE key = 'codex_parser_rebuild_status';"
            ), "pending")
            XCTAssertEqual(try database.intScalar(
                sql: "SELECT value FROM app_metadata WHERE key = 'codex_parser_rebuild_total_sources';"
            ), 1)
        }

        try overwriteFile(file, with: rolloutText(sessionId: sessionID, input: 40, output: 7))
        let retried = try await importer.importCodexHistory(paths: paths)
        XCTAssertNil(retried.warningMessage)
        XCTAssertEqual(try sessionTotal(database, sessionID: sessionID), 47)
        XCTAssertEqual(try database.stringScalar(sql: "SELECT status FROM codex_import_sources LIMIT 1;"), "indexed")
        XCTAssertEqual(try database.stringScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'codex_parser_rebuild_status';"
        ), "completed")
    }

    func testTimeZoneChangeUsesStoredLedgerAndPublishesAtomically() async throws {
        let root = try makeTemporaryDirectory(named: "QuotaLensTimeZoneRecovery")
        let paths = CodexHistoryPaths(rootURL: root)
        try FileManager.default.createDirectory(at: paths.sessionsURL, withIntermediateDirectories: true)
        let database = try makeMigratedDatabase(in: root)
        let sessionID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let file = paths.sessionsURL.appendingPathComponent("rollout-2026-08-20T12-00-00-\(sessionID).jsonl")
        try overwriteFile(file, with: rolloutText(sessionId: sessionID, input: 10, output: 5))
        _ = try await CodexUsageImportActor(database: database).importCodexHistory(paths: paths)
        let service = PricingCatalogService.shared
        let oldZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let newZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))
        try service.ensureCatalogInstalled(database: database, timeZone: oldZone)
        let previousDay = try database.stringScalar(sql: "SELECT day_key FROM codex_daily_usage_summaries;")
        let previousCost = try database.int64Scalar(sql: "SELECT estimated_cost_usd_nano FROM codex_sessions;")
        try FileManager.default.removeItem(at: file)
        try database.execute(sql: """
        CREATE TRIGGER fail_timezone_publish BEFORE DELETE ON codex_daily_usage_summaries
        BEGIN
            SELECT RAISE(ABORT, 'timezone publish interruption');
        END;
        """)

        XCTAssertThrowsError(try service.ensureCatalogInstalled(database: database, timeZone: newZone))
        XCTAssertEqual(try database.stringScalar(sql: "SELECT day_key FROM codex_daily_usage_summaries;"), previousDay)
        XCTAssertEqual(try database.stringScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'usage_aggregation_timezone_id';"
        ), oldZone.identifier)
        XCTAssertEqual(try database.int64Scalar(sql: "SELECT estimated_cost_usd_nano FROM codex_sessions;"), previousCost)

        try database.execute(sql: "DROP TRIGGER fail_timezone_publish;")
        try service.ensureCatalogInstalled(database: database, timeZone: newZone)
        XCTAssertEqual(try database.stringScalar(sql: "SELECT day_key FROM codex_daily_usage_summaries;"), "2026-08-21")
        XCTAssertEqual(try database.stringScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'usage_aggregation_timezone_id';"
        ), newZone.identifier)
        XCTAssertEqual(try sessionTotal(database, sessionID: sessionID), 15)
        XCTAssertEqual(try database.int64Scalar(sql: "SELECT estimated_cost_usd_nano FROM codex_sessions;"), previousCost)
        let generation = try database.intScalar(sql: "SELECT value FROM app_metadata WHERE key = 'pricing_reprice_generation';")
        try service.ensureCatalogInstalled(database: database, timeZone: newZone)
        XCTAssertEqual(try database.intScalar(sql: "SELECT value FROM app_metadata WHERE key = 'pricing_reprice_generation';"), generation)
    }

    func testChildReplayIsExcludedAndFreshTurnIsCountedAfterResume() async throws {
        let root = try makeTemporaryDirectory(named: "QuotaLensImporterReplay")
        let paths = CodexHistoryPaths(rootURL: root)
        try FileManager.default.createDirectory(at: paths.sessionsURL, withIntermediateDirectories: true)
        let database = try makeMigratedDatabase(in: root)
        let importer = CodexUsageImportActor(database: database)
        let parentID = "44444444-4444-4444-4444-444444444444"
        let childID = "55555555-5555-5555-5555-555555555555"
        let parentFile = paths.sessionsURL.appendingPathComponent("rollout-2026-08-20T12-00-00-\(parentID).jsonl")
        let childFile = paths.sessionsURL.appendingPathComponent("rollout-2026-08-20T12-10-00-\(childID).jsonl")
        try overwriteFile(parentFile, with: rolloutText(sessionId: parentID, input: 10, output: 5))

        let childHeader = rolloutText(
            sessionId: childID,
            input: 4,
            output: 1,
            parentSessionId: parentID,
            agentRole: "reviewer"
        )
        try overwriteFile(childFile, with: childHeader)
        _ = try await importer.importCodexHistory(paths: paths)
        XCTAssertEqual(try sessionTotal(database, sessionID: childID), 0)

        let freshMarker = "{\"timestamp\":\"2026-08-20T12:20:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\"}}\n"
        try appendFile(childFile, with: freshMarker + usageLine(
            timestamp: "2026-08-20T12:21:00Z",
            input: 6,
            output: 2,
            totalInput: 10,
            totalOutput: 3
        ))
        _ = try await importer.importCodexHistory(paths: paths)
        XCTAssertEqual(try sessionTotal(database, sessionID: childID), 8)
        XCTAssertEqual(try database.stringScalar(
            sql: "SELECT agent_type FROM codex_sessions WHERE session_id = ?;",
            bindings: [childID]
        ), "reviewer")
    }

    func testImportedLedgerMaintainsCrossPageTokenCostAndEventInvariants() async throws {
        let root = try makeTemporaryDirectory(named: "QuotaLensImporterInvariant")
        let paths = CodexHistoryPaths(rootURL: root)
        try FileManager.default.createDirectory(at: paths.sessionsURL, withIntermediateDirectories: true)
        let database = try makeMigratedDatabase(in: root)
        let importer = CodexUsageImportActor(database: database)
        let sessionID = "66666666-6666-6666-6666-666666666666"
        let file = paths.sessionsURL.appendingPathComponent(
            "rollout-2026-08-20T12-00-00-\(sessionID).jsonl"
        )
        try overwriteFile(file, with: rolloutText(
            sessionId: sessionID,
            model: "gpt-5.4",
            input: 10,
            cached: 2,
            output: 5
        ))
        _ = try await importer.importCodexHistory(paths: paths)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let rangeStart = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 20
        )))
        let rangeEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: rangeStart))
        let repository = UsageAnalyticsRepository(database: database)
        let session = try XCTUnwrap(repository.fetchSessionDetail(sessionId: sessionID))
        let history = try repository.fetchHistoryDays(
            daysCount: 2,
            calendar: calendar,
            now: rangeEnd
        )
        let dashboard = try repository.fetchDashboardMetrics(
            rangeStart: rangeStart,
            endExclusive: rangeEnd,
            calendar: calendar
        )
        let historyTokens = history.reduce(Int64(0)) { $0 + $1.tokens.canonicalTotalTokens }
        let historyCost = history.reduce(Int64(0)) { $0 + $1.estimatedCost.rawValue }
        let historyEvents = history.reduce(0) { $0 + $1.eventCount }

        XCTAssertEqual(session.session.tokens.canonicalTotalTokens, historyTokens)
        XCTAssertEqual(historyTokens, dashboard.totalTokens.canonicalTotalTokens)
        XCTAssertEqual(session.session.estimatedCost.rawValue, historyCost)
        XCTAssertEqual(historyCost, dashboard.totalCost.rawValue)
        XCTAssertEqual(session.session.eventCount, historyEvents)
        XCTAssertEqual(historyEvents, dashboard.totalEvents)
    }

    private func usageLine(
        timestamp: String,
        input: Int64,
        cached: Int64 = 0,
        cacheWrite: Int64 = 0,
        output: Int64,
        totalInput: Int64,
        totalCached: Int64 = 0,
        totalCacheWrite: Int64 = 0,
        totalOutput: Int64
    ) -> String {
        "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":\(input),\"cached_input_tokens\":\(cached),\"cache_creation_input_tokens\":\(cacheWrite),\"output_tokens\":\(output)},\"total_token_usage\":{\"input_tokens\":\(totalInput),\"cached_input_tokens\":\(totalCached),\"cache_creation_input_tokens\":\(totalCacheWrite),\"output_tokens\":\(totalOutput)}}}}\n"
    }

    private func sessionTotal(_ database: SQLiteDatabase, sessionID: String) throws -> Int64 {
        try database.int64Scalar(
            sql: "SELECT total_tokens FROM codex_sessions WHERE session_id = ?;",
            bindings: [sessionID]
        ) ?? 0
    }

    private func sessionFacts(
        _ database: SQLiteDatabase,
        sessionID: String
    ) throws -> (tokens: Int64, cacheWriteTokens: Int64, events: Int, cost: Int64) {
        try XCTUnwrap(database.executeQuery(
            sql: "SELECT total_tokens, cache_write_input_tokens, event_count, estimated_cost_usd_nano FROM codex_sessions WHERE session_id = ?;",
            bindings: [sessionID]
        ) { statement in
            (
                tokens: sqlite3_column_int64(statement, 0),
                cacheWriteTokens: sqlite3_column_int64(statement, 1),
                events: Int(sqlite3_column_int(statement, 2)),
                cost: sqlite3_column_int64(statement, 3)
            )
        }.first)
    }
}
