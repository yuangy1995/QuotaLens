import Foundation
import XCTest
@testable import QuotaLens

final class CodexUsageParsingTests: XCTestCase {
    func testRateLimitSnapshotCurrentWindowCheck() {
        let now: Int64 = 1_787_600_000
        let current = RateLimitSnapshotRecord(
            accountKey: "acc_test",
            observedAt: now - 60,
            limitId: "codex",
            slot: "primary",
            usedPercentMilli: 74_000,
            windowDurationMins: 10_080,
            resetsAt: now + 60,
            planType: "plus",
            rawJson: "{}"
        )
        let expired = RateLimitSnapshotRecord(
            accountKey: "acc_test",
            observedAt: now - 60,
            limitId: "codex",
            slot: "primary",
            usedPercentMilli: 74_000,
            windowDurationMins: 10_080,
            resetsAt: now - 1,
            planType: "plus",
            rawJson: "{}"
        )

        XCTAssertTrue(current.isCurrentQuotaWindow(at: now))
        XCTAssertFalse(expired.isCurrentQuotaWindow(at: now))
    }

    func testDecodesModernTokenCountInfoPayload() throws {
        let line = """
        {"timestamp":"2026-07-18T00:00:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":30,"reasoning_output_tokens":10,"total_tokens":130},"last_token_usage":{"input_tokens":40,"cached_input_tokens":5,"output_tokens":12,"reasoning_output_tokens":4,"total_tokens":52},"model_name":"gpt-5.4"}}}
        """

        let event = try XCTUnwrap(RolloutLineDecoder.decodeLine(line))
        XCTAssertEqual(event.eventType, "token_count")
        XCTAssertEqual(event.timestampMs, 1_784_332_804_000)
        XCTAssertEqual(event.model, "gpt-5.4")
        XCTAssertEqual(event.lastTokenUsage?.inputTokens, 40)
        XCTAssertEqual(event.lastTokenUsage?.cachedInputTokens, 5)
        XCTAssertEqual(event.lastTokenUsage?.outputTokens, 12)
        XCTAssertEqual(event.lastTokenUsage?.reasoningOutputTokens, 4)
        XCTAssertEqual(event.totalTokenUsage?.totalTokens, 130)
    }

    func testDecodesThreadSettingsServiceTier() throws {
        let line = """
        {"timestamp":"2026-07-18T00:00:01.000Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"priority"}}}
        """

        let event = try XCTUnwrap(RolloutLineDecoder.decodeLine(line))
        XCTAssertEqual(event.eventType, "thread_settings_applied")
        XCTAssertEqual(event.serviceTier, "priority")
    }

    func testRolloutTimestampFilenameExtractsSessionUUID() {
        let sessionId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let fileName = "rollout-2026-07-18T00-00-00-\(sessionId).jsonl"

        XCTAssertEqual(
            CodexRolloutScanner.extractSessionId(from: fileName, relativePath: "sessions/\(fileName)"),
            sessionId
        )
    }

    func testSessionIndexReadsThreadNameAndEpochStrings() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotalens-session-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("session_index.jsonl")
        let sessionId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let line = """
        {"id":"\(sessionId)","thread_name":"Fix importer","updated_at":"1785283200000","cwd":"/tmp/QuotaLens"}
        """
        try Data((line + "\n").utf8).write(to: fileURL)

        let metadata = CodexSessionMetadataStore.loadFromSessionIndex(fileURL: fileURL)
        XCTAssertEqual(metadata[sessionId]?.title, "Fix importer")
        XCTAssertEqual(metadata[sessionId]?.projectName, "QuotaLens")
        XCTAssertNotNil(metadata[sessionId]?.updatedAt)
    }

    func testSessionIndexReadsFractionalISO8601Dates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotalens-session-index-fractional-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("session_index.jsonl")
        let sessionId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let line = """
        {"id":"\(sessionId)","thread_name":"Fractional date","updated_at":"2026-08-24T13:17:17.315886Z"}
        """
        try Data((line + "\n").utf8).write(to: fileURL)

        let metadata = CodexSessionMetadataStore.loadFromSessionIndex(fileURL: fileURL)
        XCTAssertEqual(
            Int64(try XCTUnwrap(metadata[sessionId]?.updatedAt).timeIntervalSince1970 * 1000),
            1_787_577_437_315
        )
    }

    func testStateThreadsTableReadsTitleCwdAndMillisecondDates() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotalens-state-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let db = try SQLiteDatabase(path: dbURL.path)
        try db.execute(sql: """
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            cwd TEXT NOT NULL,
            created_at_ms INTEGER,
            updated_at_ms INTEGER
        );
        INSERT INTO threads (id, title, cwd, created_at_ms, updated_at_ms)
        VALUES ('aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', 'State title', '/tmp/QuotaLens', 1777035437315, 1777035440000);
        """)

        let metadata = CodexSessionMetadataStore.loadFromStateSqlite(dbURL: dbURL)
        let item = try XCTUnwrap(metadata["aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"])
        XCTAssertEqual(item.title, "State title")
        XCTAssertEqual(item.cwd, "/tmp/QuotaLens")
        XCTAssertEqual(item.projectName, "QuotaLens")
        XCTAssertEqual(Int64(try XCTUnwrap(item.createdAt).timeIntervalSince1970 * 1000), 1_777_035_437_315)
    }

    func testRolloutHeaderUsesSessionMetaIdOverFilenameHint() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotalens-rollout-header-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions/2026/08/24", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let parentId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let childHint = "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
        let fileURL = sessions.appendingPathComponent("rollout-2026-08-24T00-00-00-\(parentId)_\(childHint).jsonl")
        let line = """
        {"timestamp":"2026-08-24T13:17:11.477Z","type":"session_meta","payload":{"id":"\(parentId)","cwd":"/tmp/QuotaLens"}}
        """
        try Data((line + "\n").utf8).write(to: fileURL)

        let source = try XCTUnwrap(CodexRolloutScanner.scan(paths: CodexHistoryPaths(rootURL: root)).first)
        XCTAssertEqual(source.sessionId, childHint)

        let header = try XCTUnwrap(CodexSessionMetadataStore.loadFromRolloutHeaders(sources: [source]).values.first)
        XCTAssertEqual(header.sessionId, parentId)
        XCTAssertEqual(header.metadata?.cwd, "/tmp/QuotaLens")
    }

    func testStreamingReaderCommitsCompleteEOFJsonWithoutNewline() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotalens-jsonl-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let line = #"{"type":"event_msg","payload":{"type":"token_count"}}"#
        try Data(line.utf8).write(to: fileURL)

        var records: [JSONLLineRecord] = []
        let result = try StreamingJSONLReader.readLines(fileURL: fileURL) { record in
            records.append(record)
        }

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.lineString, line)
        XCTAssertEqual(result.finalOffset, Int64(line.utf8.count))
    }

    func testStreamingReaderKeepsIncompleteEOFJsonForRetry() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotalens-jsonl-incomplete-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let completeLine = #"{"type":"session_meta"}"#
        let incompleteLine = #"{"type":"event_msg","payload":"#
        try Data((completeLine + "\n" + incompleteLine).utf8).write(to: fileURL)

        var records: [JSONLLineRecord] = []
        let result = try StreamingJSONLReader.readLines(fileURL: fileURL) { record in
            records.append(record)
        }

        XCTAssertEqual(records.map(\.lineString), [completeLine])
        XCTAssertEqual(result.finalOffset, Int64(completeLine.utf8.count + 1))
    }

    func testImportModernRolloutCreatesPricedEventAndSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotalens-codex-home-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotalens-import-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let sessionId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let rollout = sessions.appendingPathComponent("rollout-2026-07-18T00-00-00-\(sessionId).jsonl")
        let lines = [
            #"{"timestamp":"2026-07-18T00:00:00.000Z","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"}}"#,
            #"{"timestamp":"2026-07-18T00:00:01.000Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"priority"}}}"#,
            #"{"timestamp":"2026-07-18T00:00:02.000Z","type":"turn_context","payload":{"model":"gpt-5.4"}}"#,
            #"{"timestamp":"2026-07-18T00:00:03.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":30,"reasoning_output_tokens":10,"total_tokens":130},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":30,"reasoning_output_tokens":10,"total_tokens":130}}}}"#
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: rollout)

        let index = root.appendingPathComponent("session_index.jsonl")
        let indexLine = #"{"id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","thread_name":"Import smoke","cwd":"/tmp/QuotaLens"}"#
        try Data((indexLine + "\n").utf8).write(to: index)

        let db = try SQLiteDatabase(path: dbURL.path)
        try SchemaMigrations.migrate(database: db)

        let actor = CodexUsageImportActor(database: db)
        let summary = try await actor.importCodexHistory(paths: CodexHistoryPaths(rootURL: root))

        XCTAssertEqual(summary.eventsInserted, 1)
        XCTAssertEqual(try db.intScalar(sql: "SELECT COUNT(*) FROM codex_usage_events;"), 0)
        XCTAssertEqual(try db.int64Scalar(sql: "SELECT total_tokens FROM codex_session_summaries;"), 130)
        XCTAssertEqual(try db.int64Scalar(sql: "SELECT total_tokens FROM codex_daily_usage_summaries;"), 130)
        XCTAssertEqual(try db.intScalar(sql: "SELECT event_count FROM codex_session_summaries;"), 1)
        XCTAssertEqual(try db.stringScalar(sql: "SELECT title FROM codex_sessions WHERE session_id = ?;", bindings: [sessionId]), "Import smoke")
        let storedSourcePath = try XCTUnwrap(db.stringScalar(sql: "SELECT source_path FROM codex_sessions WHERE session_id = ?;", bindings: [sessionId]))
        XCTAssertEqual(
            (storedSourcePath as NSString).resolvingSymlinksInPath,
            (rollout.path as NSString).resolvingSymlinksInPath
        )
    }

    func testRealCodexHomeImportProbe() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["QUOTALENS_REAL_CODEX_IMPORT_PROBE"] == "1",
            "Set QUOTALENS_REAL_CODEX_IMPORT_PROBE=1 to read the local ~/.codex directory into a temporary test database."
        )

        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root.path), "~/.codex does not exist")

        let importRoot: URL
        var sampledRoot: URL?
        if let rawLimit = ProcessInfo.processInfo.environment["QUOTALENS_REAL_CODEX_IMPORT_SAMPLE_LIMIT"],
           let limit = Int(rawLimit),
           limit > 0 {
            let sample = FileManager.default.temporaryDirectory
                .appendingPathComponent("quotalens-real-codex-sample-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: sample, withIntermediateDirectories: true)
            sampledRoot = sample

            let realSources = CodexRolloutScanner.scan(paths: CodexHistoryPaths(rootURL: root))
            for source in realSources.prefix(limit) {
                let destination = sample.appendingPathComponent(source.relativePath)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source.fileURL)
            }

            let realIndex = root.appendingPathComponent("session_index.jsonl")
            if FileManager.default.fileExists(atPath: realIndex.path) {
                try FileManager.default.copyItem(at: realIndex, to: sample.appendingPathComponent("session_index.jsonl"))
            }
            importRoot = sample
        } else {
            importRoot = root
        }
        defer {
            if let sampledRoot {
                try? FileManager.default.removeItem(at: sampledRoot)
            }
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotalens-real-import-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let db = try SQLiteDatabase(path: dbURL.path)
        try SchemaMigrations.migrate(database: db)

        let actor = CodexUsageImportActor(database: db)
        let summary = try await actor.importCodexHistory(paths: CodexHistoryPaths(rootURL: importRoot), forceRebuild: true)

        XCTAssertGreaterThan(summary.sourcesScanned, 0)
        XCTAssertGreaterThan(summary.eventsInserted, 0)
        XCTAssertGreaterThan(try db.intScalar(sql: "SELECT COUNT(*) FROM codex_sessions;"), 0)
        XCTAssertEqual(try db.intScalar(sql: "SELECT COUNT(*) FROM codex_usage_events;"), 0)
        XCTAssertGreaterThan(try db.int64Scalar(sql: "SELECT COALESCE(SUM(total_tokens), 0) FROM codex_daily_usage_summaries;") ?? 0, 0)
        XCTAssertGreaterThan(try db.int64Scalar(sql: "SELECT COALESCE(SUM(estimated_cost_usd_nano), 0) FROM codex_daily_usage_summaries;") ?? 0, 0)
    }
}
