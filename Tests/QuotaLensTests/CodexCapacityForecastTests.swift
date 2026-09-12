import XCTest
import SwiftUI
import SQLite3
@testable import QuotaLens

final class CodexCapacityForecastTests: XCTestCase {
    private let week: Int64 = 604800
    private func point(_ time: Int64, _ tokens: Int64?, _ used: Double, reset: Int64,
                       account: String = "a", plan: String? = "plus", detail: String? = nil,
                       minutes: Int = 10080, shortUsed: Double? = nil, shortReset: Int64 = 18000) -> CodexCapacityObservation {
        var windows = [CodexCapacityObservation.Window(minutes: minutes, usedPercent: used, resetsAt: reset)]
        if let shortUsed { windows.append(.init(minutes: 300, usedPercent: shortUsed, resetsAt: shortReset)) }
        return .init(accountKey: account, observedAt: time, lifetimeTokens: tokens,
                     planType: plan, subscriptionPlan: detail, windows: windows)
    }
    private func analyze(_ rows: [CodexCapacityObservation], now: Int64? = nil) -> [CodexCapacityWindow] {
        CodexCapacityForecast.analyze(rows, accountKey: "a", now: now ?? rows.map(\.observedAt).max()!)
    }

    func testUserExampleNaturalThenEarlyResetHalvesCapacity() throws {
        let rows = [point(0, 0, 0, reset: week), point(week - 1, 50, 50, reset: week),
                    point(week, 50, 0, reset: 2 * week), point(week + 100, 60, 20, reset: 2 * week),
                    point(week + 200, 60, 0, reset: 2 * week + 200)]
        let window = try XCTUnwrap(analyze(rows).first)
        XCTAssertEqual(window.cycles.count, 3)
        XCTAssertEqual(window.cycles[0].capacity, 100)
        XCTAssertEqual(window.cycles[1].capacity, 50)
        XCTAssertEqual(window.cycles[0].endReason, .natural)
        XCTAssertEqual(window.cycles[1].endReason, .restored)
        XCTAssertEqual(window.prediction?.tokens, 50)
        XCTAssertEqual(window.prediction?.followsTrend, false)
    }

    func testWeeklyResetDoesNotResetFiveHourLedger() throws {
        // 10:00 视为 0，12:00 周重置，15:00 短窗口重置。
        let rows = [point(0, 0, 40, reset: 7200, shortUsed: 0),
                    point(7199, 50, 65, reset: 7200, shortUsed: 50),
                    point(7200, 50, 0, reset: week + 7200, shortUsed: 50),
                    point(10800, 70, 10, reset: week + 7200, shortUsed: 70),
                    point(18000, 70, 10, reset: week + 7200, shortUsed: 0, shortReset: 36000)]
        let windows = analyze(rows)
        let short = try XCTUnwrap(windows.first { $0.minutes == 300 })
        let weekly = try XCTUnwrap(windows.first { $0.minutes == 10080 })
        XCTAssertEqual(short.cycles.count, 2)
        XCTAssertEqual(short.cycles[0].capacity, 100)
        XCTAssertEqual(short.cycles[0].measuredTokens, 70)
        XCTAssertEqual(short.cycles[0].remainingTokens, 30)
        XCTAssertEqual(weekly.cycles.count, 2)
        XCTAssertEqual(weekly.current?.measuredTokens, 20)
        XCTAssertEqual(weekly.current?.capacity, 200)
        XCTAssertEqual(weekly.current?.remainingTokens, 180)
    }

    func testUnattributedResetIntervalIsSkippedOnlyForResettingWindow() throws {
        let rows = [point(0, 0, 0, reset: 7200, shortUsed: 0),
                    point(7080, 50, 25, reset: 7200, shortUsed: 50),
                    point(7380, 80, 5, reset: week + 7200, shortUsed: 80),
                    point(9000, 90, 10, reset: week + 7200, shortUsed: 90),
                    point(9500, 100, 15, reset: week + 7200, shortUsed: 100)]
        let windows = analyze(rows)
        XCTAssertEqual(windows.first { $0.minutes == 300 }?.current?.capacity, 100)
        let weekly = try XCTUnwrap(windows.first { $0.minutes == 10080 })
        XCTAssertEqual(weekly.cycles[0].measuredTokens, 50)
        XCTAssertEqual(weekly.current?.measuredTokens, 20)
        XCTAssertEqual(weekly.current?.capacity, 200)
        XCTAssertEqual(weekly.current?.hasGap, true)
    }

    func testSameDeadlineRecoveryCreatesDistinctCycle() {
        let rows = [point(0, 0, 0, reset: week), point(100, 80, 80, reset: week),
                    point(200, 80, 0, reset: week), point(300, 115, 70, reset: week)]
        let cycles = analyze(rows)[0].cycles
        XCTAssertEqual(cycles.count, 2)
        XCTAssertNotEqual(cycles[0].id, cycles[1].id)
        XCTAssertEqual(cycles[0].capacity, 100)
        XCTAssertEqual(cycles[1].capacity, 50)
    }

    func testArchivedCycleSnapshotsStayIndependentAcrossRepeatedResets() {
        let rows = [point(0, 0, 0, reset: week), point(100, 50, 50, reset: week),
                    point(200, 50, 0, reset: week), point(300, 150, 50, reset: week),
                    point(400, 150, 0, reset: week), point(500, 175, 50, reset: week)]
        let cycles = analyze(rows)[0].cycles
        XCTAssertEqual(cycles.map(\.capacity), [100, 200, 50])
        XCTAssertEqual(cycles.map(\.measuredTokens), [50, 100, 25])
        XCTAssertEqual(cycles.map(\.endAt), [200, 400, nil])
        XCTAssertEqual(Set(cycles.map(\.id)).count, 3)
        let extended = analyze(rows + [point(600, 185, 70, reset: week)])[0].cycles
        XCTAssertEqual(extended[0].measuredTokens, cycles[0].measuredTokens)
        XCTAssertEqual(extended[1].measuredTokens, cycles[1].measuredTokens)
        XCTAssertEqual(extended[2].measuredTokens, 35)
    }

    func testPartialFirstCycleUsesMatchingPercentageDelta() {
        let rows = [point(0, 1000, 40, reset: week), point(100, 1020, 60, reset: week)]
        XCTAssertEqual(analyze(rows)[0].current?.capacity, 100)
        XCTAssertEqual(analyze(rows)[0].current?.remainingTokens, 40)
    }

    func testMissingCounterBridgesButCorrectionStartsNewPair() {
        let rows = [point(0, 100, 0, reset: week), point(10, nil, 10, reset: week),
                    point(20, 130, 20, reset: week), point(30, 140, 30, reset: week),
                    point(40, 120, 29, reset: week), point(50, 130, 39, reset: week)]
        let cycle = analyze(rows)[0].current
        XCTAssertEqual(cycle?.measuredTokens, 50)
        XCTAssertEqual(cycle?.consumedPercent, 40)
        XCTAssertEqual(cycle?.capacity, 125)
        XCTAssertEqual(cycle?.hasGap, true)
    }

    func testIndependentUpdatesAccumulateUntilBothCountersChange() {
        let rows = [point(0, 0, 0, reset: week), point(10, 10, 0, reset: week),
                    point(20, 10, 10, reset: week), point(30, 10, 20, reset: week),
                    point(40, 20, 20, reset: week)]
        XCTAssertEqual(analyze(rows)[0].current?.capacity, 100)
    }

    func testSparseConsumptionDoesNotExposeHugeEstimate() {
        let rows = [point(0, 0, 0, reset: week), point(1, 1000, 1, reset: week)]
        XCTAssertNil(analyze(rows)[0].current?.capacity)
    }

    func testOtherAccountsAndUnknownWindowsAreExcluded() {
        let rows = [point(0, 0, 0, reset: week), point(10, 100000, 50, reset: week, account: "b"),
                    point(20, 20, 20, reset: week), point(30, 1000, 50, reset: week, minutes: 60)]
        let windows = analyze(rows)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].current?.capacity, 100)
        XCTAssertFalse(windows[0].isAvailable)
    }

    func testPlanChangeWithSameDeadlineSeparatesStagesAndForecast() {
        let rows = [point(0, 0, 0, reset: week, plan: "pro", detail: "pro5x"),
                    point(100, 50, 50, reset: week, plan: "pro", detail: "pro5x"),
                    point(200, 50, 50, reset: week, plan: "pro", detail: "pro20x"),
                    point(300, 150, 60, reset: week, plan: "pro", detail: "pro20x")]
        let window = analyze(rows)[0]
        XCTAssertEqual(window.cycles.count, 2)
        XCTAssertEqual(window.cycles[0].endReason, .planChanged)
        XCTAssertEqual(window.current?.capacity, 1000)
        XCTAssertNil(window.prediction)
    }

    func testTemporaryMissingPlanDoesNotCauseUpgradeOrDowngrade() {
        let rows = [point(0, 0, 0, reset: week, detail: "pro5x"),
                    point(100, 10, 10, reset: week, plan: nil),
                    point(200, 20, 20, reset: week, detail: "pro5x")]
        XCTAssertEqual(analyze(rows)[0].cycles.count, 1)
        XCTAssertEqual(analyze(rows)[0].current?.capacity, 100)
    }

    func testExpiredWindowDoesNotPredictCurrentRemaining() {
        let rows = [point(0, 0, 0, reset: 18000, minutes: 300), point(100, 50, 50, reset: 18000, minutes: 300)]
        let window = analyze(rows, now: 19000)[0]
        XCTAssertNil(window.current)
        XCTAssertFalse(window.isAvailable)
        XCTAssertEqual(window.cycles[0].endReason, .awaitingRefresh)
    }

    func testForecastTrendAndFallback() throws {
        let falling = try XCTUnwrap(CodexCapacityForecast.predict(capacities: [100, 80, 64]))
        XCTAssertEqual(falling.tokens, 57.6, accuracy: 0.0001)
        XCTAssertEqual(falling.changePercent, -10, accuracy: 0.0001)
        let rising = try XCTUnwrap(CodexCapacityForecast.predict(capacities: [100, 120, 144]))
        XCTAssertEqual(rising.tokens, 158.4, accuracy: 0.0001)
        XCTAssertEqual(CodexCapacityForecast.predict(capacities: [100, 50])?.tokens, 50)
        XCTAssertEqual(CodexCapacityForecast.predict(capacities: [100, 50, 100])?.tokens, 100)
        XCTAssertNil(CodexCapacityForecast.predict(capacities: []))
        XCTAssertNil(CodexCapacityForecast.predict(capacities: [0]))
    }

    func testHoursOfDelayedCloudUsageSurviveIntermittentFailures() throws {
        let rows = [point(0, 1000, 79, reset: week), point(1000, nil, 81, reset: week),
                    point(1020, 1000, 81, reset: week), point(5000, nil, 85, reset: week),
                    point(5020, 1000, 85, reset: week), point(8000, nil, 87, reset: week),
                    point(8020, 1000, 87, reset: week), point(10000, nil, 89, reset: week),
                    point(10020, 1000, 89, reset: week), point(14400, 1120, 91, reset: week)]
        let before = try XCTUnwrap(analyze(Array(rows.dropLast()))[0].current)
        XCTAssertNil(before.capacity)
        XCTAssertTrue(before.awaitingCloudUsage)
        let after = try XCTUnwrap(analyze(rows)[0].current)
        XCTAssertEqual(after.measuredTokens, 120)
        XCTAssertEqual(after.consumedPercent, 12)
        XCTAssertEqual(after.capacity, 1000)
        XCTAssertFalse(after.awaitingCloudUsage)
    }

    func testStableEstimateDoesNotFallWhileWaitingForNextCloudBatch() throws {
        var rows = [point(0, 0, 0, reset: week), point(3600, 200, 20, reset: week)]
        rows += [point(4000, nil, 25, reset: week), point(5000, 200, 30, reset: week),
                 point(6000, 200, 40, reset: week)]
        let waiting = try XCTUnwrap(analyze(rows)[0].current)
        XCTAssertEqual(waiting.capacity, 1000)
        XCTAssertEqual(waiting.consumedPercent, 20)
        XCTAssertTrue(waiting.awaitingCloudUsage)
        rows.append(point(10000, 400, 40, reset: week))
        let settled = try XCTUnwrap(analyze(rows)[0].current)
        XCTAssertEqual(settled.capacity, 1000)
        XCTAssertEqual(settled.measuredTokens, 400)
        XCTAssertEqual(settled.consumedPercent, 40)
        XCTAssertFalse(settled.awaitingCloudUsage)
    }

    func testLateBatchAfterResetIsNotChargedToNewCycle() throws {
        let rows = [point(0, 0, 0, reset: week), point(100, 100, 10, reset: week),
                    point(200, 100, 40, reset: week), point(300, 100, 0, reset: week + 300),
                    point(400, 100, 10, reset: week + 300), point(500, nil, 20, reset: week + 300),
                    point(600, 600, 20, reset: week + 300), point(700, 700, 30, reset: week + 300)]
        let waiting = try XCTUnwrap(analyze(Array(rows.prefix(6)))[0].current)
        XCTAssertNil(waiting.capacity)
        XCTAssertTrue(waiting.awaitingCloudUsage)
        let window = analyze(rows)[0]
        XCTAssertEqual(window.cycles[0].capacity, 1000)
        XCTAssertEqual(window.current?.measuredTokens, 100)
        XCTAssertEqual(window.current?.capacity, 1000)
    }

    func testDelayedBatchCanStillBeUsedByWindowThatDidNotReset() {
        let rows = [point(0, 0, 0, reset: 7200, shortUsed: 0),
                    point(1000, nil, 10, reset: 7200, shortUsed: 10),
                    point(7200, 0, 0, reset: 7200 + week, shortUsed: 20),
                    point(8000, 300, 10, reset: 7200 + week, shortUsed: 30)]
        let windows = analyze(rows)
        XCTAssertNil(windows.first { $0.minutes == 10080 }?.current?.capacity)
        XCTAssertEqual(windows.first { $0.minutes == 300 }?.current?.capacity, 1000)
    }

    func testIdleDeadlineDriftDoesNotManufactureResets() {
        let rows = [point(0, 1000, 50, reset: week), point(100, 1100, 60, reset: week),
                    point(200, 1100, 0, reset: week + 200), point(1000, 1100, 0, reset: week + 1000),
                    point(5000, 1100, 0, reset: week + 5000), point(6000, 1200, 10, reset: week + 6000)]
        let window = analyze(rows)[0]
        XCTAssertEqual(window.cycles.count, 2)
        XCTAssertEqual(window.cycles[0].endReason, .restored)
        XCTAssertEqual(window.current?.capacity, 1000)
    }

    func testIdleWindowDoesNotBridgeAnExpiredUnobservedCycle() {
        let rows = [point(0, 0, 0, reset: 18000, minutes: 300),
                    point(40000, 400, 10, reset: 54000, minutes: 300),
                    point(41000, 500, 20, reset: 54000, minutes: 300)]
        XCTAssertEqual(analyze(rows)[0].cycles.count, 2)
        XCTAssertEqual(analyze(rows)[0].current?.measuredTokens, 100)
    }

    func testOptInReadOnlyStoredObservationReplay() throws {
        guard let path = ProcessInfo.processInfo.environment["QUOTALENS_CAPACITY_REPLAY_DATABASE"] else {
            throw XCTSkip("Opt-in read-only capacity history replay")
        }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let handle = try XCTUnwrap(database)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "SELECT payload FROM codex_capacity_observations ORDER BY account_key, observed_at", -1, &statement, nil), SQLITE_OK)
        let query = try XCTUnwrap(statement)
        defer { sqlite3_finalize(query) }
        var rows: [CodexCapacityObservation] = []
        var result = sqlite3_step(query)
        while result == SQLITE_ROW {
            let json = String(cString: sqlite3_column_text(query, 0))
            rows.append(try JSONDecoder().decode(CodexCapacityObservation.self, from: Data(json.utf8)))
            result = sqlite3_step(query)
        }
        XCTAssertEqual(result, SQLITE_DONE)
        XCTAssertFalse(rows.isEmpty)
        let now = try XCTUnwrap(rows.map(\.observedAt).max())
        var estimates = 0
        for (index, account) in Set(rows.map(\.accountKey)).sorted().enumerated() {
            for window in CodexCapacityForecast.analyze(rows, accountKey: account, now: now) {
                let valid = window.cycles.compactMap(\.capacity)
                XCTAssertTrue(valid.allSatisfy { $0.isFinite && $0 > 0 })
                estimates += valid.count
                // 仅输出匿名计数，不输出账号标识、原始用量或登录信息。
                print("CAPACITY_REPLAY account=\(index + 1) minutes=\(window.minutes) cycles=\(window.cycles.count) estimates=\(valid.count) forecast=\(window.prediction != nil)")
            }
        }
        XCTAssertGreaterThan(estimates, 0, "Recorded delayed cloud usage should now produce estimates")
    }

    func testPersistenceIsAccountScopedIdempotentAndSurvivesReopen() throws {
        let dir = try makeTemporaryDirectory()
        let db = try makeMigratedDatabase(in: dir)
        let store = CodexCapacityStore(database: db)
        let a = point(100, 0, 0, reset: week)
        try store.record(a)
        try store.record(a)
        try store.record(point(100, 900, 90, reset: week, account: "b"))
        let reopened = try SQLiteDatabase(path: dir.appendingPathComponent("test.sqlite").path)
        let loaded = try CodexCapacityStore(database: reopened).observations(accountKey: "a")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.lifetimeTokens, 0)
        XCTAssertEqual(try store.observations(accountKey: "b").count, 1)
    }

    func testExamplesUseRealAlgorithmWithIndependentLedgers() throws {
        for minutes in [300, 10080] {
            let now: Int64 = 20000000
            let rows = CodexCapacityExamples.observations(now: now, minutes: minutes)
            let window = try XCTUnwrap(CodexCapacityForecast.analyze(rows, accountKey: "example", now: now).first)
            XCTAssertEqual(window.cycles.count, 6)
            XCTAssertNotNil(window.current?.capacity)
            XCTAssertEqual(window.cycles[1].endReason, .restored)
            XCTAssertNotNil(window.prediction)
        }
    }

    func testAllNewTranslationsCoverEveryAdditionalLanguage() {
        let expected = Set(AppLanguage.allCases).subtracting([.english, .simplifiedChinese])
        for (key, translations) in capacityForecastTranslations {
            XCTAssertEqual(Set(translations.keys), expected, key)
            XCTAssertTrue(translations.values.allSatisfy { !$0.isEmpty }, key)
        }
    }

    func testSubscriptionLookupNeverUsesAnotherWorkspaceDefault() {
        let entries: [String: Any] = [
            "default": ["account": ["id": "other"], "entitlement": ["subscription_plan": "pro20x"]],
            "mine": ["account": ["id": "mine"], "entitlement": ["subscription_plan": "pro5x"]]
        ]
        let match = ChatGPTSubscriptionClient.matchingAccount(in: entries, expectedAccountKey: AccountIdentity.stableAccountKey(from: "mine"))
        XCTAssertEqual((match?["entitlement"] as? [String: String])?["subscription_plan"], "pro5x")
        XCTAssertNil(ChatGPTSubscriptionClient.matchingAccount(in: entries, expectedAccountKey: "unknown"))
    }

    @MainActor
    func testCapacityCardsRenderInBothThemes() throws {
        let now = Int64(Date().timeIntervalSince1970)
        let windows = [300, 10080].flatMap { minutes in
            CodexCapacityForecast.analyze(CodexCapacityExamples.observations(now: now, minutes: minutes), accountKey: "example", now: now)
        }
        for scheme in [ColorScheme.light, .dark] {
            let content = VStack(spacing: 24) {
                HStack {
                    ViewingAccountPicker(selection: .constant(""), accountNames: [("", L10n.text("Codex 当前账号", "Current Codex account"))])
                    Spacer()
                }
                ForEach(windows) { CapacityWindowCard(window: $0) }
            }.padding(28).frame(width: 1000).background(AppTheme.canvasGradient(for: scheme))
                .environment(\.colorScheme, scheme)
            let image = try renderNativeView(content, scheme: scheme)
            XCTAssertGreaterThan(image.size.height, 600)
            XCTAssertEqual(image.size.width, 1000)
            // 按需输出检查图片；普通回归测试不产生额外文件。
            if let output = ProcessInfo.processInfo.environment["QUOTALENS_CAPACITY_SCREENSHOT_DIR"] {
                let directory = URL(fileURLWithPath: output, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try XCTUnwrap(image.tiffRepresentation)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent(scheme == .dark ? "quota-forecast-dark.png" : "quota-forecast-light.png"))
            }
        }
    }

    @MainActor
    func testEmptyForecastIsCompactAtMinimumWindowWidth() throws {
        let now = Int64(Date().timeIntervalSince1970)
        let window = try XCTUnwrap(analyze([point(now, 1000, 79, reset: now + week)]).first)
        let oldLanguage = UserDefaults.standard.object(forKey: L10n.languageModeDefaultsKey)
        defer { UserDefaults.standard.set(oldLanguage, forKey: L10n.languageModeDefaultsKey) }
        UserDefaults.standard.set(AppLanguageMode.simplifiedChinese.rawValue, forKey: L10n.languageModeDefaultsKey)
        for scheme in [ColorScheme.light, .dark] {
            let content = VStack(spacing: 20) {
                HStack {
                    ViewingAccountPicker(selection: .constant(""), accountNames: [("", L10n.text("Codex 当前账号", "Current Codex account"))])
                    Spacer()
                }
                CapacityWindowCard(window: window)
            }.padding(24).frame(width: 710).background(AppTheme.canvasGradient(for: scheme))
                .environment(\.colorScheme, scheme)
            let image = try renderNativeView(content, scheme: scheme)
            XCTAssertLessThan(image.size.height, 550, "Empty state should not fill the page with explanatory content")
            XCTAssertEqual(image.size.width, 710)
            if let output = ProcessInfo.processInfo.environment["QUOTALENS_CAPACITY_SCREENSHOT_DIR"] {
                let directory = URL(fileURLWithPath: output, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent(scheme == .dark ? "quota-empty-dark.png" : "quota-empty-light.png"))
            }
        }
    }

    @MainActor
    private func renderNativeView<Content: View>(_ content: Content, scheme: ColorScheme) throws -> NSImage {
        let hosting = NSHostingView(rootView: content.environment(\.displayScale, 2))
        hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.setFrameSize(hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let image = NSImage(size: hosting.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }
}
