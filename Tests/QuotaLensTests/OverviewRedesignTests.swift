import AppKit
import SwiftUI
import XCTest
@testable import QuotaLens

final class OverviewRedesignTests: XCTestCase {
    func testVersionLabelOmitsLocalBuildAndMetadata() {
        XCTAssertEqual(AppVersion.shortVersion("1.0.33-local.20260913.111500"), "1.0.33")
        XCTAssertEqual(AppVersion.shortVersion("1.2.3+456"), "1.2.3")
        XCTAssertEqual(AppVersion.shortVersion("1.2.3"), "1.2.3")
    }

    func testCalendarPeriodsAndMatchedCutoffAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12)))
        for days in [1, 7, 30] {
            let period = OverviewPeriod(days: days, now: now, calendar: calendar)
            XCTAssertEqual(calendar.component(.hour, from: period.start), 0)
            XCTAssertEqual(calendar.component(.hour, from: period.previousEnd), 12)
            XCTAssertEqual(calendar.dateComponents([.day], from: period.previousStart, to: period.start).day, days)
            XCTAssertEqual(calendar.dateComponents([.day], from: period.start, to: calendar.startOfDay(for: now)).day, days - 1)
        }
    }

    func testDayContributionsDoNotUseSessionLifetimeAndProjectsUsePaths() {
        let date = Date()
        func session(_ id: String, _ path: String?) -> CodexSessionDTO {
            .init(sessionId: id, rootSessionId: id, title: id, projectName: "Same name", cwd: path,
                  createdAt: date, updatedAt: date, tokens: .init(inputTokens: 999_999))
        }
        let first = session("a", "/work/one/repo")
        let second = session("b", "/work/two/repo")
        let unassigned = session("c", nil)
        let rows = OverviewAnalysis.merge([
            .init(session: first, dayTokens: .init(inputTokens: 10), dayCost: .zero, dayEventCount: 1),
            .init(session: first, dayTokens: .init(inputTokens: 20), dayCost: .zero, dayEventCount: 1),
            .init(session: second, dayTokens: .init(inputTokens: 5), dayCost: .zero, dayEventCount: 1),
            .init(session: unassigned, dayTokens: .init(inputTokens: 2), dayCost: .zero, dayEventCount: 1)
        ])
        let analysis = OverviewAnalysis(period: .init(days: 7), current: .init(), previous: .init(), sessions: rows, contributionsAvailable: true)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.first?.tokens, 30)
        XCTAssertEqual(analysis.projects.count, 3)
        XCTAssertEqual(analysis.projects.reduce(0) { $0 + $1.tokens }, 37)
        XCTAssertEqual(analysis.projects.last?.path, nil)
    }

    func testFacadeUsesActualWindowAndPreservesProviderIsolation() async throws {
        let root = try makeTemporaryDirectory()
        let db = try makeMigratedDatabase(in: root)
        let calendar = UsageDayBucketer.calendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 12)))
        let period = OverviewPeriod(days: 7, now: now, calendar: calendar)
        let paths = CodexHistoryPaths(rootURL: root)
        let events: [(String, Date, Int64)] = [
            ("current", now.addingTimeInterval(-60), 100),
            ("prior", period.previousStart.addingTimeInterval(60), 40),
            ("before", period.previousStart.addingTimeInterval(-60), 999)
        ]
        for (id, date, input) in events {
            try overwriteFile(paths.sessionsURL.appendingPathComponent("rollout-\(id).jsonl"),
                with: rolloutText(sessionId: id, timestamp: ISO8601DateFormatter().string(from: date), input: input, output: 10))
        }
        let importer = CodexUsageImportActor(database: db)
        _ = try await importer.importCodexHistory(paths: paths)
        let facade = UsageQueryFacade(database: db)
        let result = try await facade.getOverviewAnalysis(days: 7, provider: .codex, now: now)
        XCTAssertEqual(result.current.totalTokens.canonicalTotalTokens, 110)
        XCTAssertEqual(result.previous.totalTokens.canonicalTotalTokens, 50)
        XCTAssertTrue(result.contributionsAvailable)
        XCTAssertEqual(result.sessions.reduce(0) { $0 + $1.tokens }, 110)
        XCTAssertEqual(result.recordedDays.count, 1)
        let other = try await facade.getOverviewAnalysis(days: 7, provider: .claude, now: now)
        XCTAssertTrue(other.sessions.isEmpty)
        XCTAssertTrue(other.recordedDays.isEmpty)
    }

    func testMissingDaysAreNotDisplayedAsMeasuredZero() {
        let now = Date()
        let empty = DayUsageSummaryDTO(dayKey: LocalDayKey(date: now), date: now)
        let result = OverviewAnalysis(period: .init(days: 7), current: .init(dailyBuckets: [empty]),
                                      previous: .init(), sessions: [], contributionsAvailable: true)
        XCTAssertTrue(result.recordedDays.isEmpty)
    }

    func testOverviewTranslationsHaveAllLanguages() {
        let languages = Set(AppLanguage.allCases).subtracting([.english, .simplifiedChinese])
        for (key, values) in overviewTranslations {
            XCTAssertEqual(Set(values.keys), languages, key)
            XCTAssertTrue(values.values.allSatisfy { !$0.isEmpty }, key)
        }
    }

    @MainActor
    func testOverviewPanelsRenderAtWideAndNarrowWidthsInBothThemes() throws {
        let root = try makeTemporaryDirectory()
        let db = try makeMigratedDatabase(in: root)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let record = ManagedCodexAccount(accountKey: "fixture", directoryID: UUID(), name: "Work · fixture@example.test",
            source: .imported, status: .available, verifiedAt: Date())
        defaults.set(try JSONEncoder().encode([record]), forKey: "QuotaLens.managedCodexAccounts")
        try Repositories(database: db).insertRateLimitSnapshot(.init(accountKey: "fixture", observedAt: Int64(Date().timeIntervalSince1970),
            limitId: "codex", slot: "secondary", usedPercentMilli: 17000, windowDurationMins: 10080,
            resetsAt: Int64(Date().addingTimeInterval(86400).timeIntervalSince1970), planType: "pro", rawJson: "{}"))
        let accounts = CodexAccountsStore(database: db, defaults: defaults, root: root)
        let calendar = UsageDayBucketer.calendar()
        let now = Date()
        let days = (0..<7).map { offset -> DayUsageSummaryDTO in
            let date = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now))!
            return .init(dayKey: LocalDayKey(date: date), date: date, tokens: .init(inputTokens: Int64(offset + 1) * 100_000, cachedInputTokens: 10_000, outputTokens: 20_000), eventCount: 1, sessionCount: 1)
        }
        let tokens = days.reduce(TokenBreakdown.zero) { $0 + $1.tokens }
        let model = ModelUsageSummaryDTO(modelCanonical: "gpt-5.4", tokens: tokens, estimatedCost: .zero, eventCount: 7)
        let session = CodexSessionDTO(sessionId: "fixture", rootSessionId: "fixture", title: "Example session", projectName: "QuotaLens",
                                     cwd: "/workspace/QuotaLens", createdAt: now, updatedAt: now)
        let analysis = OverviewAnalysis(period: .init(days: 7, now: now),
            current: .init(totalTokens: tokens, totalSessions: 1, cacheHitRatio: tokens.cacheHitRatio,
                           dailyBuckets: days.sorted { $0.date < $1.date }, modelDistribution: [model]),
            previous: .init(totalTokens: .init(inputTokens: 1_200_000)),
            sessions: [.init(session: session, tokens: tokens.canonicalTotalTokens, cost: .zero)], contributionsAvailable: true)
        for width in [CGFloat(680), 1100] {
            for scheme in [ColorScheme.light, .dark] {
                let content = VStack(alignment: .leading, spacing: 20) {
                    OverviewResourceGroup(state: AppState(), accounts: accounts, automaticallyRefresh: false) { _ in }
                    GlobalDistributionPanel(analyses: [.codex: analysis]) { _, _ in }
                }
                .padding(20).frame(width: width)
                .background(scheme == .dark ? Color(white: 0.075) : Color(white: 0.965))
                .environment(\.colorScheme, scheme)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                let host = NSHostingView(rootView: content)
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.setFrameSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.bounds.width, width)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let output = ProcessInfo.processInfo.environment["QUOTALENS_OVERVIEW_SCREENSHOT_DIR"] {
                    let url = URL(fileURLWithPath: output)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: url.appendingPathComponent("overview-\(Int(width))-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
