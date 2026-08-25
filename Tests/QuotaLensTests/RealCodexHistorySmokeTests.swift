import XCTest
@testable import QuotaLens

final class RealCodexHistorySmokeTests: XCTestCase {
    func testExplicitRealFormatSampleImportIsIdempotentAndConsistent() async throws {
        guard let fixtureRoot = ProcessInfo.processInfo.environment["QUOTALENS_REAL_FIXTURE_ROOT"],
              !fixtureRoot.isEmpty else {
            throw XCTSkip("Set QUOTALENS_REAL_FIXTURE_ROOT to run the opt-in real-format smoke test.")
        }

        let paths = CodexHistoryPaths(rootURL: URL(fileURLWithPath: fixtureRoot, isDirectory: true))
        let discovered = CodexRolloutScanner.scan(paths: paths, scanArchived: true).sources
        guard !discovered.isEmpty else {
            throw XCTSkip("The explicit fixture root contains no rollout JSONL files.")
        }

        let databaseDirectory = try makeTemporaryDirectory(named: "QuotaLensRealFormat")
        let database = try makeMigratedDatabase(in: databaseDirectory)
        let importer = CodexUsageImportActor(database: database)
        let originalArchivedFlag = UsageFeatureFlags.shared.isScanArchivedSessionsEnabled
        UsageFeatureFlags.shared.isScanArchivedSessionsEnabled = true
        addTeardownBlock {
            UsageFeatureFlags.shared.isScanArchivedSessionsEnabled = originalArchivedFlag
        }

        let first = try await importer.importCodexHistory(paths: paths)
        XCTAssertEqual(first.sourcesScanned, discovered.count)
        XCTAssertGreaterThan(first.eventsInserted, 0)

        let second = try await importer.importCodexHistory(paths: paths)
        XCTAssertEqual(second.eventsInserted, 0)
        XCTAssertEqual(second.bytesRead, 0)

        let diagnostics = try UsageAnalyticsRepository(database: database).fetchDiagnostics()
        XCTAssertTrue(diagnostics.integrityCheckPassed)
        XCTAssertEqual(diagnostics.foreignKeyViolationCount, 0)
        XCTAssertEqual(diagnostics.invariantViolationCount, 0)
        XCTAssertGreaterThan(diagnostics.totalEvents, 0)

        // Aggregate-only output is safe for CI/developer logs: no source paths or
        // conversation payloads are printed.
        print(
            "REAL_FORMAT_SMOKE sources=\(first.sourcesScanned) events=\(diagnostics.totalEvents) "
                + "unpriced=\(diagnostics.unpricedEvents) malformed=\(diagnostics.malformedLineCount)"
        )
    }
}
