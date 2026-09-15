import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import QuotaLens

final class CodexMultiAccountTests: XCTestCase {
    @MainActor
    func testCurrentAccountKeepsOriginalOverviewWithoutChangingQuerySelection() throws {
        let root = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: root)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let records = ["active", "other"].map {
            ManagedCodexAccount(accountKey: $0, directoryID: UUID(), name: $0,
                                source: .imported, status: .available)
        }
        defaults.set(try JSONEncoder().encode(records), forKey: "QuotaLens.managedCodexAccounts")
        let store = CodexAccountsStore(database: database, defaults: defaults, root: root)
        let state = AppState()
        let originalSelection = state.selectedAccountKey
        state.account = AccountRecord(accountKey: "active", emailHash: nil, planType: "pro", firstSeenAt: 1, lastSeenAt: 1)

        XCTAssertTrue(store.showsCurrentCodexOverview(state: state))
        store.select("active")
        XCTAssertTrue(store.showsCurrentCodexOverview(state: state))
        XCTAssertEqual(store.selectedKey, "active")
        store.select("other")
        XCTAssertFalse(store.showsCurrentCodexOverview(state: state))
        XCTAssertEqual(state.account?.accountKey, "active")
        XCTAssertEqual(state.selectedAccountKey, originalSelection)
        store.select("active")
        XCTAssertTrue(store.showsCurrentCodexOverview(state: state))

        state.account = nil
        XCTAssertFalse(store.showsCurrentCodexOverview(state: state))
        store.select("")
        XCTAssertTrue(store.showsCurrentCodexOverview(state: state))
        for provider in [UsageProvider.claude, .antigravity] {
            let otherStore = CodexAccountsStore(database: database, defaults: defaults, root: root, provider: provider)
            XCTAssertFalse(otherStore.showsCurrentCodexOverview(state: state))
        }
    }

    @MainActor
    func testRestoredOverviewRendersWithAccountPickerInBothThemes() throws {
        let root = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: root)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let record = ManagedCodexAccount(accountKey: "active", directoryID: UUID(), name: "Work · fixture@example.test",
                                        source: .imported, status: .available)
        defaults.set(try JSONEncoder().encode([record]), forKey: "QuotaLens.managedCodexAccounts")
        defaults.set("active", forKey: "QuotaLens.managedCodexAccounts.selection")
        let store = CodexAccountsStore(database: database, defaults: defaults, root: root)
        let state = AppState()
        let now = Int64(Date().timeIntervalSince1970)
        state.account = AccountRecord(accountKey: "active", emailHash: nil, planType: "pro", firstSeenAt: now, lastSeenAt: now)
        state.currentQuotaSnapshots = [
            .init(accountKey: "active", observedAt: now, limitId: "codex", slot: "primary",
                  usedPercentMilli: 25000, windowDurationMins: 300, resetsAt: now + 10800, planType: "pro", rawJson: "{}"),
            .init(accountKey: "active", observedAt: now, limitId: "codex", slot: "secondary",
                  usedPercentMilli: 33000, windowDurationMins: 10080, resetsAt: now + 259200, planType: "pro", rawJson: "{}")
        ]
        state.hasCurrentServerQuota = true
        state.lastSuccessfulRefreshAt = Date()
        for width in [CGFloat(900), 1100] {
            for scheme in [ColorScheme.light, .dark] {
                let content = CodexAccountsOverviewView(state: state, accounts: store, automaticallyRefresh: false)
                    .frame(width: width, height: 800)
                    .background(AppTheme.canvasGradient(for: scheme))
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
                        .write(to: url.appendingPathComponent("codex-home-\(Int(width))-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
        }
    }

    func testIndependentEnvironmentDoesNotInheritActiveCredentials() {
        let base = ["CODEX_HOME": "/active", "OPENAI_API_KEY": "fixture", "CODEX_ACCESS_TOKEN": "fixture",
                    "CODEX_AUTH_JSON": "fixture", "CODEX_REMOTE_TOKEN": "fixture", "PATH": "/usr/bin"]
        let env = CodexAccountConnection.environment(homeURL: URL(fileURLWithPath: "/isolated"), base: base)
        XCTAssertEqual(env["CODEX_HOME"], "/isolated")
        XCTAssertEqual(base["CODEX_HOME"], "/active")
        XCTAssertNil(env["OPENAI_API_KEY"])
        XCTAssertNil(env["CODEX_ACCESS_TOKEN"])
        XCTAssertNil(env["CODEX_AUTH_JSON"])
        XCTAssertNil(env["CODEX_REMOTE_TOKEN"])
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertTrue(CodexAccountConnection.arguments.contains("cli_auth_credentials_store=\"file\""))
    }

    func testLoginURLOnlyAcceptsOfficialHTTPSOrigins() {
        XCTAssertNotNil(CodexAccountConnection.validatedLoginURL("https://auth.openai.com/authorize?state=test"))
        for value in ["http://auth.openai.com/authorize", "https://auth.openai.com.evil.test/", "file:///tmp/auth",
                      "https://auth.openai.com@evil.test/", "https://user:password@auth.openai.com/"] {
            XCTAssertNil(CodexAccountConnection.validatedLoginURL(value))
        }
    }

    func testRefreshRejectsWrongAccountBeforeSaving() async throws {
        let root = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: root)
        let snapshot = try snapshot(accountID: "account-b")
        let reader = CodexAccountQuotaReader(database: database, fetch: { _ in snapshot })
        do {
            _ = try await reader.refresh(homeURL: root, expectedAccountKey: AccountIdentity.stableAccountKey(from: "account-a"))
            XCTFail("Must reject another account's quota")
        } catch {}
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM rate_limit_snapshots;"), 0)
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM accounts;"), 0)
    }

    func testRefreshRejectsLocalIdentityConflictingWithServer() async throws {
        let root = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: root)
        try overwriteFile(root.appendingPathComponent("auth.json"), with: #"{"tokens":{"account_id":"account-a"}}"#)
        let snapshot = try snapshot(accountID: "account-b")
        let reader = CodexAccountQuotaReader(database: database, fetch: { _ in snapshot })
        do {
            _ = try await reader.refresh(homeURL: root, expectedAccountKey: nil)
            XCTFail("Local credentials must not relabel another account's response")
        } catch {}
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM accounts;"), 0)
    }

    func testAuthorizedQuotaPersistsWindowsAndKeepsProviderIsolation() async throws {
        let root = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: root)
        let key = AccountIdentity.stableAccountKey(from: "account-a")
        let snapshot = try snapshot(accountID: "account-a")
        let reader = CodexAccountQuotaReader(database: database, fetch: { _ in snapshot })
        let result = try await reader.refresh(homeURL: root, expectedAccountKey: key)
        XCTAssertEqual(result.0, key)
        XCTAssertEqual(result.1, "fixture@example.test")
        XCTAssertEqual(result.2.count, 2)
        XCTAssertEqual(result.2.map(\.usedPercentMilli), [25_000, 55_000])
        try database.execute(sql: """
        INSERT INTO rate_limit_snapshots(account_key, observed_at, limit_id, slot, used_percent_milli, raw_json, provider)
        VALUES ('\(key)', 2000000000, 'codex', 'primary', 99000, '{}', 'claude');
        """)
        let cached = try await reader.cached(accountKey: key)
        XCTAssertEqual(cached.count, 2)
        XCTAssertFalse(cached.contains { $0.usedPercentMilli == 99000 })
    }

    @MainActor
    func testHistoricalAccountIsNotSelectableAndDoesNotClearActiveAccount() async throws {
        let root = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: root)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let state = AppState()
        let previousKey = state.selectedAccountKey
        defer { state.selectedAccountKey = previousKey }
        state.selectedAccountKey = "active"
        let active = AccountRecord(accountKey: "active", emailHash: nil, planType: "plus", firstSeenAt: 1, lastSeenAt: 1)
        state.account = active
        let store = CodexAccountsStore(database: database, defaults: defaults, root: root)
        store.select("historical")
        await store.loadSelection(refresh: false)
        XCTAssertEqual(store.selectedKey, "")
        XCTAssertTrue(store.keys(state: state).isEmpty)
        XCTAssertEqual(state.account?.accountKey, "active")
        XCTAssertEqual(state.selectedAccountKey, "active")
        XCTAssertTrue(store.snapshots.isEmpty)
        await store.cancelAuthorization()
        XCTAssertFalse(store.isAuthorizing)
        XCTAssertEqual(state.account?.accountKey, "active")
    }

    @MainActor
    func testSavedAuthorizationNamesSurviveRestartWithoutTokensInPreferences() throws {
        let root = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: root)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let record = ManagedCodexAccount(accountKey: "account-a", directoryID: UUID(), name: "Work")
        let data = try JSONEncoder().encode([record])
        defaults.set(data, forKey: "QuotaLens.managedCodexAccounts")
        let store = CodexAccountsStore(database: database, defaults: defaults, root: root)
        let state = AppState()
        XCTAssertEqual(store.name(for: "account-a", state: state), "Work")
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("token"))
        state.storedAccountKeysByProvider[.codex] = ["acc_missing"]
        XCTAssertFalse(store.name(for: "acc_missing", state: state).contains("acc_missing"))
    }

    func testNewAccountStringsCoverSupportedLanguages() {
        let releaseNote = "Restored the full quota dashboard for the current Codex account, keeping account switching, management, and nicknames."
        XCTAssertEqual(L10n.changelogZhToEnMap["恢复当前 Codex 账号的完整额度首页，保留账号切换、账号管理和备注。"], releaseNote)
        for language in AppLanguage.allCases where language != .english && language != .simplifiedChinese {
            XCTAssertFalse(queryAccountTranslations[releaseNote]?[language]?.isEmpty ?? true, "\(language): \(releaseNote)")
        }
        let keys = ["Viewing account", "Current Codex account", "Authorize account", "Independently authorized",
                    "Historical snapshot · Authorize to refresh", "No quota data", "Unidentified account %d", "Rename",
                    "Authorization did not complete. Try again.", "Remaining: %.0f%%"]
        for language in AppLanguage.allCases where language != .english && language != .simplifiedChinese {
            for key in keys { XCTAssertNotNil(extendedTranslations[key]?[language], "\(language): \(key)") }
        }
    }

    private func snapshot(accountID: String) throws -> CodexServerSnapshot {
        let accountJSON = """
        {"account":{"type":"chatgpt","accountId":"\(accountID)","email":"fixture@example.test","planType":"plus"},"requiresOpenaiAuth":true}
        """
        let limitsJSON = #"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":2000000000},"secondary":{"usedPercent":55,"windowDurationMins":10080,"resetsAt":2000000000}}}"#
        return CodexServerSnapshot(capturedAt: Date(timeIntervalSince1970: 1800000000), version: "fixture", binaryPath: "/fixture",
            account: try JSONDecoder().decode(AccountReadResult.self, from: Data(accountJSON.utf8)), accountRawJson: accountJSON,
            rateLimits: try JSONDecoder().decode(RateLimitsReadResult.self, from: Data(limitsJSON.utf8)), rateLimitsRawJson: limitsJSON,
            accountUsage: nil)
    }
}
