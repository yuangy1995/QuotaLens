import Foundation
import XCTest
import SwiftUI
@testable import QuotaLens

final class QueryAccountsTests: XCTestCase {
    private func token(_ id: String, expired: Bool = false) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "https://api.openai.com/auth": ["chatgpt_account_id": id],
            "https://api.openai.com/profile": ["email": "\(id)@example.test"],
            "exp": expired ? 1 : 4_000_000_000
        ])
        return "header." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".fixture"
    }

    private func payload(_ id: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tokens": [
            "access_token": token(id), "refresh_token": "shared-refresh-fixture",
            "id_token": "expired-identity-fixture"
        ]])
    }

    private func client() -> QueryCredentialClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QueryAccountURLProtocol.self]
        return QueryCredentialClient(session: URLSession(configuration: config))
    }

    @MainActor
    private func store(database: SQLiteDatabase, defaults: UserDefaults, root: URL,
                       vault: TestQueryVault) -> CodexAccountsStore {
        CodexAccountsStore(database: database, defaults: defaults, root: root, client: client(),
            loadCredential: { try vault.load($0) },
            saveCredential: { vault.save($0, id: $1) },
            deleteCredential: { vault.remove($0) },
            renewCredential: { _, _ in throw QueryAccountError.authorization })
    }

    override func setUp() {
        super.setUp()
        QueryAccountURLProtocol.setStatus(200)
    }

    @MainActor
    func testHistoryNeverPopulatesQueryAccountDirectory() throws {
        let root = try makeTemporaryDirectory()
        let db = try makeMigratedDatabase(in: root)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let records = [
            ManagedCodexAccount(accountKey: "usable", directoryID: UUID(), name: "Usable", source: .imported, status: .available),
            ManagedCodexAccount(accountKey: "expired", directoryID: UUID(), name: "Expired", source: .imported, status: .needsAuthorization),
            ManagedCodexAccount(accountKey: "legacy", directoryID: UUID(), name: "Legacy")
        ]
        defaults.set(try JSONEncoder().encode(records), forKey: "QuotaLens.managedCodexAccounts")
        let accounts = store(database: db, defaults: defaults, root: root, vault: TestQueryVault())
        let state = AppState()
        state.storedAccountKeysByProvider[.codex] = ["historical"]
        XCTAssertEqual(accounts.keys(state: state), ["usable"])
        accounts.select("historical")
        XCTAssertEqual(accounts.selectedKey, "")
        accounts.select("expired")
        XCTAssertEqual(accounts.selectedKey, "")
    }

    @MainActor
    func testImportVerifiesBeforeSavingAndNeverUsesRefreshToken() async throws {
        let root = try makeTemporaryDirectory()
        let db = try makeMigratedDatabase(in: root)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = TestQueryVault()
        let accounts = store(database: db, defaults: defaults, root: root, vault: vault)
        await accounts.importCredential(try payload("a"))
        XCTAssertNil(accounts.error)
        XCTAssertEqual(accounts.accounts.count, 1)
        XCTAssertEqual(accounts.accounts.first?.status, .available)
        XCTAssertEqual(accounts.selectedKey, AccountIdentity.stableAccountKey(from: "a"))
        XCTAssertEqual(accounts.snapshots.first?.usedPercentMilli, 25000)
        XCTAssertEqual(vault.count, 1)
        XCTAssertTrue(QueryAccountURLProtocol.requests.allSatisfy {
            $0.url?.path == "/backend-api/wham/usage" && $0.httpMethod == "GET" && $0.httpBody == nil
        })
        let data = try XCTUnwrap(defaults.data(forKey: "QuotaLens.managedCodexAccounts"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("shared-refresh"))
        let reopened = store(database: db, defaults: defaults, root: root, vault: vault)
        XCTAssertEqual(reopened.selectedKey, accounts.selectedKey)
        XCTAssertEqual(reopened.accounts.first?.verifiedAt, accounts.accounts.first?.verifiedAt)
    }

    @MainActor
    func testFailedImportDoesNotCreateSelectableAccount() async throws {
        let root = try makeTemporaryDirectory()
        let db = try makeMigratedDatabase(in: root)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = TestQueryVault()
        let accounts = store(database: db, defaults: defaults, root: root, vault: vault)
        QueryAccountURLProtocol.setStatus(401)
        await accounts.importCredential(try payload("a"))
        XCTAssertTrue(accounts.accounts.isEmpty)
        XCTAssertEqual(vault.count, 0)
        XCTAssertEqual(try db.intScalar(sql: "SELECT COUNT(*) FROM rate_limit_snapshots;"), 0)
    }

    @MainActor
    func testNetworkFailureRetainsDataButRevokedCredentialIsNotSelectable() async throws {
        let root = try makeTemporaryDirectory()
        let db = try makeMigratedDatabase(in: root)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = store(database: db, defaults: defaults, root: root, vault: TestQueryVault())
        await accounts.importCredential(try payload("a"))
        let key = accounts.selectedKey
        QueryAccountURLProtocol.setStatus(503)
        await accounts.loadSelection(refresh: true)
        XCTAssertEqual(accounts.selectedKey, key)
        XCTAssertEqual(accounts.accounts.first?.status, .available)
        XCTAssertFalse(accounts.snapshots.isEmpty)
        QueryAccountURLProtocol.setStatus(401)
        await accounts.loadSelection(refresh: true)
        XCTAssertEqual(accounts.selectedKey, "")
        XCTAssertEqual(accounts.accounts.first?.status, .needsAuthorization)
        XCTAssertTrue(accounts.keys(state: AppState()).isEmpty)
        XCTAssertGreaterThan(try db.intScalar(sql: "SELECT COUNT(*) FROM rate_limit_snapshots;"), 0)
    }

    @MainActor
    func testRemovalPreservesHistoryAndSuppressesAutomaticRediscovery() async throws {
        let root = try makeTemporaryDirectory()
        let db = try makeMigratedDatabase(in: root)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = TestQueryVault()
        let accounts = store(database: db, defaults: defaults, root: root, vault: vault)
        let data = try payload("a")
        await accounts.importCredential(data, source: .local)
        let count = try db.intScalar(sql: "SELECT COUNT(*) FROM rate_limit_snapshots;")
        accounts.removeCredential(accounts.selectedKey)
        XCTAssertEqual(vault.count, 0)
        XCTAssertTrue(accounts.accounts.isEmpty)
        XCTAssertEqual(try db.intScalar(sql: "SELECT COUNT(*) FROM rate_limit_snapshots;"), count)
        XCTAssertEqual(try db.intScalar(sql: "SELECT COUNT(*) FROM accounts;"), 1)
        let reopened = store(database: db, defaults: defaults, root: root, vault: vault)
        await reopened.importCredential(data, source: .local)
        XCTAssertTrue(reopened.accounts.isEmpty)
        await reopened.importCredential(data, source: .local, allowIgnored: true)
        XCTAssertEqual(reopened.accounts.count, 1)
    }

    @MainActor
    func testChangedCredentialCannotWriteAnotherAccountsQuota() async throws {
        let root = try makeTemporaryDirectory()
        let db = try makeMigratedDatabase(in: root)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = TestQueryVault()
        let accounts = store(database: db, defaults: defaults, root: root, vault: vault)
        await accounts.importCredential(try payload("a"))
        let id = try XCTUnwrap(accounts.accounts.first?.directoryID)
        vault.save(try QueryCredential.parse(payload("b"), provider: .codex), id: id)
        await accounts.loadSelection(refresh: true)
        XCTAssertEqual(accounts.accounts.first?.status, .needsAuthorization)
        XCTAssertEqual(accounts.selectedKey, "")
        XCTAssertEqual(try db.intScalar(sql: "SELECT COUNT(*) FROM accounts;"), 1)
    }

    func testAccessTokenExpiryDoesNotDependOnIdentityToken() throws {
        let valid = try QueryCredential.parse(payload("a"), provider: .codex)
        XCTAssertNoThrow(try valid.checkExpiry())
        let expired = QueryCredential(accessToken: try token("a", expired: true), refreshToken: "fixture", expiresAt: nil, isGCPToS: false)
        XCTAssertThrowsError(try expired.checkExpiry()) { XCTAssertEqual($0 as? QueryAccountError, .expired) }
        XCTAssertThrowsError(try QueryCredential.parse(Data(#"{"email":"a@example.test"}"#.utf8), provider: .codex))
    }

    func testKnownExpiredImportedCredentialIsNotSelectableWithoutARequest() {
        let account = ManagedCodexAccount(accountKey: "a", directoryID: UUID(), name: "A",
            source: .imported, status: .available, verifiedAt: Date(), accessExpiresAt: Date(timeIntervalSince1970: 1))
        XCTAssertFalse(account.canQuery)
        var independent = account
        independent.source = .independent
        XCTAssertTrue(independent.canQuery, "An independent grant may refresh its own access token")
    }

    @MainActor
    func testOAuthCallbacksRequireMatchingStateAndSingleCode() {
        XCTAssertEqual(QueryOAuthFlow.callbackCode(target: "/oauth/callback?state=expected&code=code", expectedState: "expected"), "code")
        XCTAssertNil(QueryOAuthFlow.callbackCode(target: "/oauth/callback?state=other&code=code", expectedState: "expected"))
        XCTAssertNil(QueryOAuthFlow.callbackCode(target: "/wrong?state=expected&code=code", expectedState: "expected"))
        XCTAssertNil(QueryOAuthFlow.callbackCode(target: "/oauth/callback?state=expected&code=a&code=b", expectedState: "expected"))
        XCTAssertNil(QueryOAuthFlow.callbackCode(target: "/oauth/callback?state=expected&state=expected&code=a", expectedState: "expected"))
        XCTAssertNil(QueryOAuthFlow.callbackCode(target: "/oauth/callback?state=expected&error=access_denied", expectedState: "expected"))
    }

    func testBrowserAuthorizationUsesPKCEAndDoesNotRequestClaudeWriteScopes() throws {
        for provider in [UsageProvider.claude, .antigravity] {
            let url = try QueryOAuthClient(provider: provider).authorizationURL(
                redirect: provider == .claude ? QueryOAuthClient.claudeRedirect : "http://127.0.0.1:43210/oauth/callback",
                state: "fixture-state", verifier: String(repeating: "v", count: 64))
            let fields = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(fields.first { $0.name == "state" }?.value, "fixture-state")
            XCTAssertEqual(fields.first { $0.name == "code_challenge_method" }?.value, "S256")
            XCTAssertEqual(fields.first { $0.name == "code_challenge" }?.value?.count, 43)
            XCTAssertFalse(url.absoluteString.contains("refresh_token"))
            if provider == .claude {
                XCTAssertEqual(fields.first { $0.name == "scope" }?.value, "user:profile")
            } else {
                XCTAssertEqual(url.host, "accounts.google.com")
            }
        }
    }

    @MainActor
    func testCredentialManagerRendersInBothThemes() throws {
        let root = try makeTemporaryDirectory()
        let db = try makeMigratedDatabase(in: root)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let records = [
            ManagedCodexAccount(accountKey: "a", directoryID: UUID(), name: "Work · work@example.test", source: .independent, status: .available, verifiedAt: Date(), accessExpiresAt: Date().addingTimeInterval(3600), hasRefreshToken: true),
            ManagedCodexAccount(accountKey: "b", directoryID: UUID(), name: "Personal · personal@example.test", source: .imported, status: .accessExpired, accessExpiresAt: Date().addingTimeInterval(-60), hasRefreshToken: true)
        ]
        defaults.set(try JSONEncoder().encode(records), forKey: "QuotaLens.managedCodexAccounts")
        let accounts = store(database: db, defaults: defaults, root: root, vault: TestQueryVault())
        for scheme in [ColorScheme.light, .dark] {
            let view = QueryAccountsManagerView(state: AppState(), accounts: accounts)
                .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            host.setFrameSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertEqual(host.bounds.width, 680)
            XCTAssertEqual(host.bounds.height, 580)
            if let output = ProcessInfo.processInfo.environment["QUOTALENS_QUERY_SCREENSHOT_DIR"] {
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent(scheme == .dark ? "query-accounts-dark.png" : "query-accounts-light.png"))
            }
        }
    }

    func testQueryAccountTranslationsCoverSupportedLanguages() {
        let expected = Set(AppLanguage.allCases).subtracting([.english, .simplifiedChinese])
        for (key, values) in queryAccountTranslations {
            XCTAssertEqual(Set(values.keys), expected, key)
            XCTAssertTrue(values.values.allSatisfy { !$0.isEmpty }, key)
        }
    }

    @MainActor
    func testChangingSelectionDuringAQueryCannotShowThePreviousAccount() async throws {
        let root = try makeTemporaryDirectory()
        let db = try makeMigratedDatabase(in: root)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = store(database: db, defaults: defaults, root: root, vault: TestQueryVault())
        await accounts.importCredential(try payload("a"))
        await accounts.importCredential(try payload("b"))
        let a = AccountIdentity.stableAccountKey(from: "a")
        let b = AccountIdentity.stableAccountKey(from: "b")
        QueryAccountURLProtocol.setStatus(200)
        QueryAccountURLProtocol.setDelay(0.08)
        accounts.select(a)
        let first = Task { await accounts.loadSelection(refresh: true) }
        for _ in 0..<100 {
            if accounts.isRefreshing { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        accounts.select(b)
        await first.value
        for _ in 0..<100 {
            if QueryAccountURLProtocol.requests.last?.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "b",
               !accounts.isRefreshing { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(accounts.selectedKey, b)
        XCTAssertFalse(accounts.snapshots.isEmpty)
        XCTAssertTrue(accounts.snapshots.allSatisfy { $0.accountKey == b })
        XCTAssertEqual(QueryAccountURLProtocol.requests.last?.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "b")
    }

    @MainActor
    func testClaudeAndAntigravityUseOwnCredentialsAndProviderLedgers() async throws {
        let root = try makeTemporaryDirectory()
        let db = try makeMigratedDatabase(in: root)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for provider in [UsageProvider.claude, .antigravity] {
            let vault = TestQueryVault()
            let accounts = CodexAccountsStore(database: db, defaults: defaults, root: root, provider: provider,
                client: client(), loadCredential: { try vault.load($0) },
                saveCredential: { vault.save($0, id: $1) }, deleteCredential: { vault.remove($0) })
            await accounts.importCredential(Data(#"{"access_token":"fixture-access","refresh_token":"shared-fixture"}"#.utf8))
            XCTAssertNil(accounts.error, provider.rawValue)
            XCTAssertEqual(accounts.accounts.count, 1)
            XCTAssertFalse(accounts.snapshots.isEmpty)
            XCTAssertGreaterThan(try db.intScalar(sql: "SELECT COUNT(*) FROM rate_limit_snapshots WHERE provider = ?;", bindings: [provider.rawValue]), 0)
            XCTAssertFalse(QueryAccountURLProtocol.requests.contains { $0.url?.path.hasSuffix("/token") == true })
        }
        XCTAssertEqual(try db.intScalar(sql: "SELECT COUNT(*) FROM rate_limit_snapshots WHERE provider = 'codex';"), 0)
    }
}

private final class TestQueryVault: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: QueryCredential] = [:]
    var count: Int { lock.withLock { values.count } }
    func save(_ value: QueryCredential, id: UUID) { lock.withLock { values[id] = value } }
    func load(_ id: UUID) throws -> QueryCredential {
        try lock.withLock { guard let value = values[id] else { throw QueryAccountError.authorization }; return value }
    }
    func remove(_ id: UUID) { _ = lock.withLock { values.removeValue(forKey: id) } }
}

private final class QueryAccountURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    nonisolated(unsafe) private static var delay: TimeInterval = 0
    static var requests: [URLRequest] { lock.withLock { captured } }
    static func setStatus(_ value: Int) { lock.withLock { status = value; captured = []; delay = 0 } }
    static func setDelay(_ value: TimeInterval) { lock.withLock { delay = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, delay) = Self.lock.withLock { Self.captured.append(request); return (Self.status, Self.delay) }
        let json: String
        switch request.url!.path {
        case "/api/oauth/profile": json = #"{"account":{"uuid":"claude-fixture","email":"claude@example.test"}}"#
        case "/api/oauth/usage": json = #"{"five_hour":{"utilization":25,"resets_at":"2096-01-01T00:00:00Z"}}"#
        case "/oauth2/v2/userinfo": json = #"{"id":"google-fixture","email":"google@example.test"}"#
        case "/v1internal:loadCodeAssist": json = #"{"cloudaicompanionProject":"fixture-project"}"#
        case "/v1internal:retrieveUserQuotaSummary": json = #"{"groups":[]}"#
        case "/v1internal:fetchAvailableModels": json = #"{"models":{"fixture":{"displayName":"Fixture","quotaInfo":{"remainingFraction":0.7,"resetTime":"2096-01-01T00:00:00Z"}}}}"#
        default: json = #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":25,"limit_window_seconds":18000,"reset_at":4000000000}}}"#
        }
        let body = Data(json.utf8)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
