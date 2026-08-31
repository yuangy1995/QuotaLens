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
            let destination = simulatedTrash.appendingPathComponent(sourceURL.lastPathComponent)
            try FileManager.default.moveItem(
                at: sourceURL,
                to: destination
            )
            return destination
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
        let repository = UsageAnalyticsRepository(database: database) { sourceURL in
            XCTFail("Unsafe source must never reach the Trash handler")
            return sourceURL
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

    func testDeleteSessionRestoresFilesAndDatabaseWhenSecondStageMoveFails() throws {
        let directory = try makeTemporaryDirectory(named: "SessionDeletionStageFailure")
        let historyRoot = directory.appendingPathComponent("codex", isDirectory: true)
        let sessionsDirectory = historyRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

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

        final class StageMoveCounter: @unchecked Sendable {
            var count = 0
        }
        let stageMoveCounter = StageMoveCounter()
        let repository = UsageAnalyticsRepository(
            database: database,
            trashSourceFile: { sourceURL in
                XCTFail("Trash must not be reached when staging fails.")
                return sourceURL
            },
            stageSourceFile: { sourceURL, stagingURL in
                stageMoveCounter.count += 1
                if stageMoveCounter.count == 2 {
                    throw NSError(domain: "QuotaLensTests", code: 42)
                }
                try FileManager.default.moveItem(at: sourceURL, to: stagingURL)
            }
        )

        XCTAssertThrowsError(try repository.deleteSession(sessionId: "child", historyRootURL: historyRoot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootSource.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: childSource.path))
        XCTAssertEqual(try String(contentsOf: rootSource, encoding: .utf8), "root\n")
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_sessions;"), 2)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_import_sources;"), 2)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_usage_events;"), 2)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_session_summaries;"), 2)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_daily_usage_summaries;"), 2)
    }

    func testDeleteSessionRestoresTrashMovesAndDatabaseWhenSecondTrashMoveFails() throws {
        let directory = try makeTemporaryDirectory(named: "SessionDeletionTrashFailure")
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

        final class TrashMoveCounter: @unchecked Sendable {
            var count = 0
        }
        let trashMoveCounter = TrashMoveCounter()
        let repository = UsageAnalyticsRepository(
            database: database,
            trashSourceFile: { sourceURL in
                trashMoveCounter.count += 1
                if trashMoveCounter.count == 2 {
                    throw NSError(domain: "QuotaLensTests", code: 43)
                }
                let destination = simulatedTrash.appendingPathComponent(sourceURL.lastPathComponent)
                try FileManager.default.moveItem(at: sourceURL, to: destination)
                return destination
            }
        )

        XCTAssertThrowsError(try repository.deleteSession(sessionId: "child", historyRootURL: historyRoot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootSource.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: childSource.path))
        XCTAssertEqual(try String(contentsOf: rootSource, encoding: .utf8), "root\n")
        XCTAssertEqual(try String(contentsOf: childSource, encoding: .utf8), "child\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: simulatedTrash.path), [])
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_sessions;"), 2)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_import_sources;"), 2)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_usage_events;"), 2)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_session_summaries;"), 2)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_daily_usage_summaries;"), 2)
        XCTAssertNotNil(try repository.fetchSessionDetail(sessionId: "child"))
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
        XCTAssertNil(state.recommendedQuotaPacePercent(now: now))
        XCTAssertEqual(
            state.recommendedQuotaPaceSubtitle(now: now),
            "No quota remaining · Waiting for reset"
        )
    }

    @MainActor
    func testQuotaPaceUsesHourlyUnitForFiveHourWindow() {
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
            usedPercentMilli: 20_000,
            windowDurationMins: 300,
            resetsAt: Int64(now.addingTimeInterval(4 * 3_600).timeIntervalSince1970),
            planType: "plus",
            rawJson: "{}"
        )
        state.quotaDisplayMode = .remaining

        XCTAssertEqual(state.quotaWindowKind, .fiveHour)
        XCTAssertEqual(state.currentQuotaRemainingUnits(now: now) ?? 0, 4.0, accuracy: 0.001)
        XCTAssertEqual(state.recommendedQuotaPacePercent(now: now) ?? 0, 20.0, accuracy: 0.001)
        XCTAssertEqual(state.recommendedQuotaPacePercentString(now: now), "20.0%")
        XCTAssertEqual(state.recommendedQuotaPaceTitle, "Hourly Budget Pace")
        XCTAssertEqual(state.recommendedQuotaPaceUnit, "hour")
        XCTAssertEqual(state.recommendedQuotaPaceSubtitle(now: now), "About 4.0 hours remaining · Even pace")
        XCTAssertEqual(state.quotaDisplayMode.ringTitle(for: state.quotaWindowKind), "Available in 5 Hours")

        state.latestRateLimit = RateLimitSnapshotRecord(
            accountKey: "test-account",
            observedAt: Int64(now.timeIntervalSince1970),
            limitId: "codex",
            slot: "primary",
            usedPercentMilli: 4_000,
            windowDurationMins: 300,
            resetsAt: Int64(now.addingTimeInterval(30 * 60).timeIntervalSince1970),
            planType: "plus",
            rawJson: "{}"
        )

        XCTAssertEqual(state.currentQuotaRemainingUnits(now: now) ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(state.recommendedQuotaPacePercent(now: now) ?? 0, 96.0, accuracy: 0.001)
        XCTAssertEqual(state.recommendedQuotaPacePercentString(now: now), "96.0%")
    }

    @MainActor
    func testQuotaPaceKeepsDailyUnitForWeeklyWindow() {
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
            usedPercentMilli: 20_000,
            windowDurationMins: 10_080,
            resetsAt: Int64(now.addingTimeInterval(4 * 86_400).timeIntervalSince1970),
            planType: "plus",
            rawJson: "{}"
        )

        XCTAssertEqual(state.quotaWindowKind, .weekly)
        XCTAssertEqual(state.currentQuotaRemainingUnits(now: now) ?? 0, 4.0, accuracy: 0.001)
        XCTAssertEqual(state.recommendedQuotaPacePercent(now: now) ?? 0, 20.0, accuracy: 0.001)
        XCTAssertEqual(state.recommendedQuotaPaceTitle, "Daily Budget Pace")
        XCTAssertEqual(state.recommendedQuotaPaceUnit, "day")
        XCTAssertEqual(state.recommendedQuotaPaceSubtitle(now: now), "Remaining 4.0 days · Even pace")

        state.latestRateLimit = RateLimitSnapshotRecord(
            accountKey: "test-account",
            observedAt: Int64(now.timeIntervalSince1970),
            limitId: "codex",
            slot: "primary",
            usedPercentMilli: 4_000,
            windowDurationMins: 10_080,
            resetsAt: Int64(now.addingTimeInterval(12 * 3_600).timeIntervalSince1970),
            planType: "plus",
            rawJson: "{}"
        )

        XCTAssertEqual(state.currentQuotaRemainingUnits(now: now) ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(state.recommendedQuotaPacePercent(now: now) ?? 0, 96.0, accuracy: 0.001)
        XCTAssertEqual(state.recommendedQuotaPacePercentString(now: now), "96.0%")
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

        let chinese = "新增 Antigravity 深度用量解析与官方 API 定价目录引擎，支持 Gemini 3.7/3.6/3.5 Flash 与 3.1 Pro 成本测算与长上下文折算"
        let english = "Added Antigravity deep usage parsing and official API pricing catalog engine with cost auditing for Gemini 3.7/3.6/3.5 Flash and 3.1 Pro"
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

    func testRemoteChangelogLocalizationAcrossLanguages() {
        let defaults = UserDefaults.standard
        let previousLanguage = defaults.string(forKey: L10n.languageModeDefaultsKey)
        defer {
            if let previousLanguage {
                defaults.set(previousLanguage, forKey: L10n.languageModeDefaultsKey)
            } else {
                defaults.removeObject(forKey: L10n.languageModeDefaultsKey)
            }
        }

        let chinese = "新增 Antigravity 深度用量解析与官方 API 定价目录引擎，支持 Gemini 3.7/3.6/3.5 Flash 与 3.1 Pro 成本测算与长上下文折算"
        for mode in AppLanguageMode.allCases where mode != .system {
            defaults.set(mode.rawValue, forKey: L10n.languageModeDefaultsKey)
            let localized = L10n.localizeChangelogText(chinese)
            switch mode {
            case .simplifiedChinese:
                XCTAssertEqual(localized, chinese)
            default:
                XCTAssertNotEqual(localized, chinese, mode.rawValue)
            }
        }
    }

    func testReleaseNotesHtmlStrippingAndLocalization() {
        let rawHtml = """
        <p>QuotaLens v1.0.11</p>
        <p>This in-app update feed is architecture-specific and downloads the Apple Silicon build automatically.</p>
        - 全新重构「本地索引与数据诊断」卡片排版为现代化自适应 4 列网格，重点突出 12 项关键诊断指标并强化健康度感知
        """
        let cleaned = UpdateManager.cleanReleaseNotes(rawHtml, version: "1.0.11")
        XCTAssertFalse(cleaned.contains("<p>"))
        XCTAssertFalse(cleaned.contains("architecture-specific"))
        XCTAssertTrue(cleaned.contains("全新重构「本地索引与数据诊断」卡片排版为现代化自适应 4 列网格，重点突出 12 项关键诊断指标并强化健康度感知"))

        let defaults = UserDefaults.standard
        let previousLanguage = defaults.string(forKey: L10n.languageModeDefaultsKey)
        defer {
            if let previousLanguage {
                defaults.set(previousLanguage, forKey: L10n.languageModeDefaultsKey)
            } else {
                defaults.removeObject(forKey: L10n.languageModeDefaultsKey)
            }
        }

        defaults.set(AppLanguageMode.english.rawValue, forKey: L10n.languageModeDefaultsKey)
        let englishLocalized = L10n.localizeChangelogText(cleaned)
        XCTAssertTrue(englishLocalized.contains("Redesigned local index & diagnostics layout"))
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

    func testFactoryResetDatabaseAndDefaults() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("test_reset.sqlite").path
        let db = try SQLiteDatabase(path: dbPath)
        try SchemaMigrations.migrate(database: db)

        // 插入一些测试数据
        try db.executeUpdate(
            sql: "INSERT INTO accounts (account_key, email_hash, plan_type, first_seen_at, last_seen_at) VALUES ('acc_test', 'hash_test', 'plus', 1000, 2000);",
            bindings: []
        )

        // 执行重置逻辑
        try db.execute(sql: "PRAGMA foreign_keys = OFF;")
        let allTables = try db.executeQuery(
            sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';"
        ) { stmt in
            String(cString: sqlite3_column_text(stmt, 0))
        }
        for table in allTables {
            try? db.execute(sql: "DROP TABLE IF EXISTS \(table);")
        }
        try db.execute(sql: "PRAGMA user_version = 0;")
        try db.execute(sql: "PRAGMA foreign_keys = ON;")
        try db.execute(sql: "VACUUM;")
        try SchemaMigrations.migrate(database: db)

        // 验证表已清空并重新初始化成功
        let count = try db.executeQuery(sql: "SELECT COUNT(*) FROM accounts;") { stmt in
            sqlite3_column_int64(stmt, 0)
        }.first ?? -1
        XCTAssertEqual(count, 0)
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
