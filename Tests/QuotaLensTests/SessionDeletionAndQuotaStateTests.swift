import SQLite3
import XCTest
@testable import QuotaLens

final class SessionDeletionAndQuotaStateTests: XCTestCase {
    func testDeleteSessionMovesEntireTreeAndCleansDerivedRows() throws {
        let directory = try makeTemporaryDirectory(named: "SessionDeletion")
        let historyRoot = directory.appendingPathComponent("codex", isDirectory: true)
        let sessionsDirectory = historyRoot.appendingPathComponent("sessions", isDirectory: true)
        let simulatedTrash = directory.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: simulatedTrash, withIntermediateDirectories: true)

        let rootSource = sessionsDirectory.appendingPathComponent("root.jsonl")
        let childSource = sessionsDirectory.appendingPathComponent("child.jsonl")
        try overwriteFile(rootSource, with: "root\n")
        try overwriteFile(childSource, with: "child\n")

        let database = try makeMigratedDatabase(in: directory)
        try insertSession(
            database,
            id: "root",
            rootID: "root",
            parentID: nil,
            depth: 0,
            sourceURL: rootSource,
            relativePath: "sessions/root.jsonl"
        )
        try insertSession(
            database,
            id: "child",
            rootID: "root",
            parentID: "root",
            depth: 1,
            sourceURL: childSource,
            relativePath: "sessions/child.jsonl"
        )
        try insertSource(database, sourceURL: rootSource, relativePath: "sessions/root.jsonl", inode: 1)
        try insertSource(database, sourceURL: childSource, relativePath: "sessions/child.jsonl", inode: 2)
        try insertDerivedRows(database, sessionID: "root", rootID: "root", sourceURL: rootSource)
        try insertDerivedRows(database, sessionID: "child", rootID: "root", sourceURL: childSource)

        let repository = UsageAnalyticsRepository(database: database) { sourceURL in
            try FileManager.default.moveItem(
                at: sourceURL,
                to: simulatedTrash.appendingPathComponent(sourceURL.lastPathComponent)
            )
        }

        try repository.deleteSession(sessionId: "root", historyRootURL: historyRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: rootSource.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: childSource.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: simulatedTrash.appendingPathComponent("root.jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: simulatedTrash.appendingPathComponent("child.jsonl").path))
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_sessions;"), 0)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_import_sources;"), 0)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_usage_events;"), 0)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_session_summaries;"), 0)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_daily_usage_summaries;"), 0)
    }

    func testDeleteSessionRejectsSourcesOutsideCodexHistoryFolders() throws {
        let directory = try makeTemporaryDirectory(named: "UnsafeSessionDeletion")
        let historyRoot = directory.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: historyRoot.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        let outsideSource = directory.appendingPathComponent("outside.jsonl")
        try overwriteFile(outsideSource, with: "outside\n")

        let database = try makeMigratedDatabase(in: directory)
        try insertSession(
            database,
            id: "unsafe",
            rootID: "unsafe",
            parentID: nil,
            depth: 0,
            sourceURL: outsideSource,
            relativePath: "../outside.jsonl"
        )
        let repository = UsageAnalyticsRepository(database: database) { _ in
            XCTFail("Unsafe source must never reach the Trash handler")
        }

        XCTAssertThrowsError(
            try repository.deleteSession(sessionId: "unsafe", historyRootURL: historyRoot)
        ) { error in
            guard case SessionDeletionError.unsafeSourcePath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideSource.path))
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_sessions;"), 1)
    }

    @MainActor
    func testExhaustedQuotaHasNoDailyPaceRecommendation() {
        let defaults = UserDefaults.standard
        let previousLanguage = defaults.string(forKey: L10n.languageModeDefaultsKey)
        defaults.set(AppLanguageMode.english.rawValue, forKey: L10n.languageModeDefaultsKey)
        defer {
            if let previousLanguage {
                defaults.set(previousLanguage, forKey: L10n.languageModeDefaultsKey)
            } else {
                defaults.removeObject(forKey: L10n.languageModeDefaultsKey)
            }
        }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = AppState()
        state.latestRateLimit = RateLimitSnapshotRecord(
            accountKey: "test-account",
            observedAt: Int64(now.timeIntervalSince1970),
            limitId: "codex",
            slot: "primary",
            usedPercentMilli: 100_000,
            windowDurationMins: 10_080,
            resetsAt: Int64(now.addingTimeInterval(3_600).timeIntervalSince1970),
            planType: "plus",
            rawJson: "{}"
        )
        state.hasCurrentServerQuota = true
        state.connectionStatus = .connected(version: "test", binaryPath: "/tmp/codex")

        XCTAssertTrue(state.isQuotaExhausted)
        XCTAssertNil(state.recommendedDailyQuotaPercent(now: now))
        XCTAssertEqual(
            state.recommendedDailyQuotaSubtitle(now: now),
            "No quota remaining · Waiting for reset"
        )
    }

    @MainActor
    func testCurrentChangelogEntryIsLocalizedForEverySupportedLanguage() {
        let defaults = UserDefaults.standard
        let previousLanguage = defaults.string(forKey: L10n.languageModeDefaultsKey)
        defer {
            if let previousLanguage {
                defaults.set(previousLanguage, forKey: L10n.languageModeDefaultsKey)
            } else {
                defaults.removeObject(forKey: L10n.languageModeDefaultsKey)
            }
        }

        let chinese = "新增 Codex 本地历史用量与 Rollout 审计日志实时追踪解析引擎，支持秒级流式索引"
        let english = "Real-time parsing and streaming index for Codex local history & rollout audit logs"
        for mode in AppLanguageMode.allCases where mode != .system {
            defaults.set(mode.rawValue, forKey: L10n.languageModeDefaultsKey)
            let localized = L10n.text(chinese, english)
            switch mode {
            case .english:
                XCTAssertEqual(localized, english)
            case .simplifiedChinese:
                XCTAssertEqual(localized, chinese)
            default:
                XCTAssertNotEqual(localized, english, mode.rawValue)
                XCTAssertNotEqual(localized, chinese, mode.rawValue)
            }
        }
    }

    func testRemoteChangelogIsRestrictedToItsSourceLanguage() {
        for language in AppLanguage.allCases {
            XCTAssertEqual(
                ChangelogContentPolicy.allowsRemoteContent(for: language),
                language == .simplifiedChinese,
                language.rawValue
            )
        }
    }

    func testHeatmapHoverUsesOneGridCoordinateSpaceAndRejectsGaps() {
        XCTAssertEqual(
            UsageDashboardHoverLayout.heatmapCellIndex(
                at: CGPoint(x: 13, y: 25),
                squareSize: 10,
                spacing: 2,
                rowCount: 7,
                cellCount: 30
            ),
            9
        )
        XCTAssertNil(
            UsageDashboardHoverLayout.heatmapCellIndex(
                at: CGPoint(x: 11, y: 5),
                squareSize: 10,
                spacing: 2,
                rowCount: 7,
                cellCount: 30
            )
        )
    }

    func testHoverCardPositionTracksPointerAndStaysInsideContainer() {
        let container = CGSize(width: 800, height: 300)
        let card = CGSize(width: 188, height: 122)
        let first = UsageDashboardHoverLayout.cardPosition(
            cursor: CGPoint(x: 100, y: 80),
            containerSize: container,
            cardSize: card
        )
        let second = UsageDashboardHoverLayout.cardPosition(
            cursor: CGPoint(x: 260, y: 80),
            containerSize: container,
            cardSize: card
        )

        XCTAssertGreaterThan(second.x, first.x)
        XCTAssertGreaterThanOrEqual(first.x - card.width / 2, 6)
        XCTAssertLessThanOrEqual(second.x + card.width / 2, container.width - 6)
    }

    private func insertSession(
        _ database: SQLiteDatabase,
        id: String,
        rootID: String,
        parentID: String?,
        depth: Int,
        sourceURL: URL,
        relativePath: String
    ) throws {
        try database.executeUpdate(
            sql: """
            INSERT INTO codex_sessions (
                session_id, root_session_id, parent_session_id, depth, source_path,
                relative_path, bucket, title, project_name, cwd, created_at, updated_at,
                last_event_at, event_count, total_tokens, input_tokens, cached_input_tokens,
                output_tokens, reasoning_output_tokens, estimated_cost_usd_nano,
                pricing_status, metadata_fingerprint, has_subagents, agent_type
            ) VALUES (?, ?, ?, ?, ?, ?, 'active', ?, 'Fixture', '/tmp', 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 'priced', NULL, ?, NULL);
            """,
            bindings: [id, rootID, parentID, depth, sourceURL.path, relativePath, id, depth == 0]
        )
    }

    private func insertSource(
        _ database: SQLiteDatabase,
        sourceURL: URL,
        relativePath: String,
        inode: Int
    ) throws {
        try database.executeUpdate(
            sql: """
            INSERT INTO codex_import_sources (
                source_path, relative_path, bucket, device_id, inode, file_size, mtime_ms
            ) VALUES (?, ?, 'active', 1, ?, 1, 1);
            """,
            bindings: [sourceURL.path, relativePath, inode]
        )
    }

    private func insertDerivedRows(
        _ database: SQLiteDatabase,
        sessionID: String,
        rootID: String,
        sourceURL: URL
    ) throws {
        try database.executeUpdate(
            sql: "INSERT INTO codex_session_summaries (session_id, model_canonical) VALUES (?, 'gpt-test');",
            bindings: [sessionID]
        )
        try database.executeUpdate(
            sql: "INSERT INTO codex_daily_usage_summaries (session_id, day_key, day_start_ms, model_canonical) VALUES (?, '2026-08-25', 1, 'gpt-test');",
            bindings: [sessionID]
        )
        try database.executeUpdate(
            sql: """
            INSERT INTO codex_usage_events (
                event_id, session_id, root_session_id, timestamp_ms, model_raw,
                model_canonical, input_tokens, cached_input_tokens, output_tokens,
                reasoning_output_tokens, total_tokens, uncached_input_tokens,
                estimated_cost_usd_nano, pricing_status, usage_derivation,
                attribution_quality, source_path, created_at
            ) VALUES (?, ?, ?, 1, 'gpt-test', 'gpt-test', 1, 0, 0, 0, 1, 1, 0,
                      'priced', 'explicit_last_usage', 'direct_turn_context', ?, 1);
            """,
            bindings: ["event-\(sessionID)", sessionID, rootID, sourceURL.path]
        )
    }
}
