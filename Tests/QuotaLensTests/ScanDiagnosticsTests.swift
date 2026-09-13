import AppKit
import SwiftUI
import XCTest
@testable import QuotaLens

final class ScanDiagnosticsTests: XCTestCase {
    @MainActor
    func testLegacyLanguageTablesStillResolveAfterInitializerSplit() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: L10n.languageModeDefaultsKey)
        defer {
            if let previous { defaults.set(previous, forKey: L10n.languageModeDefaultsKey) }
            else { defaults.removeObject(forKey: L10n.languageModeDefaultsKey) }
        }
        let expected: [AppLanguageMode: String] = [
            .traditionalChinese: "%d 秒", .japanese: "%d秒", .korean: "%d초",
            .spanish: "%d s", .german: "%d s", .french: "%d s",
            .portuguese: "%d s", .portugueseBrazil: "%d s"
        ]
        for (mode, text) in expected {
            defaults.set(mode.rawValue, forKey: L10n.languageModeDefaultsKey)
            XCTAssertEqual(L10n.localized("%d seconds short"), text, mode.rawValue)
            XCTAssertNotEqual(L10n.localized("View issues"), "View issues", mode.rawValue)
        }
    }

    func testDiagnosticsTranslationsCoverAllSecondaryLanguages() {
        XCTAssertFalse(diagnosticsTranslations.isEmpty)
        for (key, translations) in diagnosticsTranslations {
            XCTAssertEqual(translations.count, 8, key)
            XCTAssertTrue(translations.values.allSatisfy { !$0.isEmpty }, key)
        }
    }

    func testUnknownAndUncheckedAreNotReportedAsZero() {
        XCTAssertNil(LocalScanDiagnostics.unchecked.count(.read))
        let failed = LocalScanDiagnostics(checkedAt: Date(), issues: [
            .init(source: nil, kind: .incomplete, reason: "fixture")
        ])
        XCTAssertNil(failed.count(.read))
        XCTAssertNil(failed.count(.format))
        XCTAssertNil(LocalScanDiagnostics(checkedAt: Date(), issues: [], sourcesFound: false).count(.read))
        XCTAssertEqual(LocalScanDiagnostics(checkedAt: Date(), issues: []).count(.read), 0)
    }

    func testPermissionsAreNotCountedAsMissingFiles() {
        XCTAssertEqual(IndexedSourcePresence.inspect(["/a"]) { _ in throw CocoaError(.fileReadNoPermission) }, .unknown)
        XCTAssertEqual(IndexedSourcePresence.inspect(["/a"]) { _ in throw CocoaError(.fileReadNoSuchFile) }, .missing)
        XCTAssertEqual(IndexedSourcePresence.inspect(["/a", "/b"]) { path in
            if path == "/a" { throw CocoaError(.fileReadNoPermission) }
            return [:]
        }, .present)
        XCTAssertEqual(IndexedSourcePresence.inspect([]), .unknown)
    }

    @MainActor
    func testScanIssuesDriveCountsAndClearAfterSuccessfulRetry() async throws {
        let root = try makeTemporaryDirectory()
        let db = try makeMigratedDatabase(in: root)
        let sourceURL = root.appendingPathComponent("state.vscdb")
        let source = try SQLiteDatabase(path: sourceURL.path)
        try source.execute(sql: "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);")
        try source.executeUpdate(sql: "INSERT INTO ItemTable VALUES (?, ?);",
            bindings: ["antigravityUnifiedStateSync.trajectorySummaries", "invalid!base64"])
        let conversations = root.appendingPathComponent("conversations")
        let broken = conversations.appendingPathComponent("broken.db")
        try overwriteFile(broken, with: "not a sqlite database")
        let reader = AntigravityLocalStateReader(sources: [.init(profile: .ide, databaseURL: sourceURL)])
        let store = AntigravityActivityStore(database: db, reader: reader,
            conversationReader: AntigravityConversationReader(directoryURL: conversations))
        let coordinator = AntigravityActivityScanCoordinator(store: store)
        await coordinator.scanNow()
        XCTAssertTrue(coordinator.isPartial)
        XCTAssertEqual(coordinator.diagnostics.count(.read), 1)
        XCTAssertEqual(coordinator.diagnostics.count(.format), 1)
        XCTAssertEqual(Set(coordinator.diagnostics.issues.compactMap { $0.source?.resolvingSymlinksInPath() }),
                       Set([sourceURL, broken].map { $0.resolvingSymlinksInPath() }))
        let index = try UsageAnalyticsRepository(database: db).fetchDiagnostics()
        XCTAssertEqual(index.malformedLineCount, 0, "Indexed record rows are not Antigravity scan sources")
        XCTAssertEqual(index.missingSourceCount, 0)
        XCTAssertNil(coordinator.lastScanTime)
        if let output = ProcessInfo.processInfo.environment["QUOTALENS_DIAGNOSTICS_SCREENSHOT_DIR"] {
            for scheme in [ColorScheme.light, .dark] {
                let content = AntigravityScanProblems(coordinator: coordinator, retry: {})
                    .padding(20).frame(width: 720)
                    .background(scheme == .dark ? Color(white: 0.1) : .white)
                    .environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: content)
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.setFrameSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("diagnostics-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
        try source.execute(sql: "DELETE FROM ItemTable;")
        try FileManager.default.removeItem(at: broken)
        await coordinator.scanNow()
        XCTAssertFalse(coordinator.isPartial)
        XCTAssertTrue(coordinator.diagnostics.issues.isEmpty)
        XCTAssertEqual(coordinator.diagnostics.count(.read), 0)
        XCTAssertEqual(coordinator.diagnostics.count(.format), 0)
        XCTAssertNotNil(coordinator.lastScanTime)
    }

    @MainActor
    func testNoSourcesHaveUnknownCoverage() async throws {
        let root = try makeTemporaryDirectory()
        let db = try makeMigratedDatabase(in: root)
        let store = AntigravityActivityStore(database: db, reader: AntigravityLocalStateReader(sources: []),
            conversationReader: AntigravityConversationReader(directoryURL: root.appendingPathComponent("missing")))
        let coordinator = AntigravityActivityScanCoordinator(store: store)
        await coordinator.scanNow()
        XCTAssertFalse(coordinator.diagnostics.sourcesFound)
        XCTAssertNil(coordinator.diagnostics.count(.read))
    }

    @MainActor
    func testMissingConversationDirectoryRetainsCachedActivity() async throws {
        let root = try makeTemporaryDirectory()
        let db = try makeMigratedDatabase(in: root)
        try db.executeUpdate(sql: "INSERT INTO antigravity_activity_records (source_profile, trajectory_id, step_count) VALUES (?, ?, ?);",
                             bindings: [AntigravityStateProfile.legacy.rawValue, "cached-fixture", 7])
        let store = AntigravityActivityStore(database: db, reader: AntigravityLocalStateReader(sources: []),
            conversationReader: AntigravityConversationReader(directoryURL: root.appendingPathComponent("missing")))
        let result = try await store.scan()
        XCTAssertEqual(result.recordsRead, 1)
        XCTAssertFalse(result.isComplete)
        XCTAssertFalse(result.sourcesFound)
        XCTAssertFalse(result.issues.isEmpty)
    }
}
