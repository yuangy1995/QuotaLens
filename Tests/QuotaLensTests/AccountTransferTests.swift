import Foundation
import XCTest
@testable import QuotaLens

final class AccountTransferTests: XCTestCase {
    private func client() -> QueryCredentialClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransferHTTPStub.self]
        return QueryCredentialClient(session: URLSession(configuration: configuration))
    }
    private func key(_ id: String = "fixture") throws -> String {
        try AntigravityAccountIdentity(userInfo: ["id": id, "email": id + "@example.test"]).accountKey
    }
    private func credential(expired: Bool = false) -> QueryCredential {
        .init(accessToken: "fixture-access", refreshToken: "fixture-refresh",
              expiresAt: Date().addingTimeInterval(expired ? -60 : 3600), isGCPToS: false)
    }
    @MainActor
    private func makeStore(defaults: UserDefaults, root: URL, db: SQLiteDatabase, vault: TransferVault,
                           local: (@Sendable () throws -> [QueryCredential])? = nil,
                           renew: (@Sendable (UsageProvider, QueryCredential) async throws -> QueryCredential)? = nil) -> CodexAccountsStore {
        CodexAccountsStore(database: db, defaults: defaults, root: root, provider: .antigravity, client: client(),
            loadCredential: { try vault.load($0) }, saveCredential: { vault.save($0, id: $1) }, deleteCredential: { vault.remove($0) },
            renewCredential: renew ?? { _, old in
                vault.recordRenewal()
                return .init(accessToken: "fixture-access", refreshToken: "rotated-fixture",
                             expiresAt: Date().addingTimeInterval(3600), isGCPToS: old.isGCPToS)
            }, localCredentialProvider: local)
    }

    func testCockpitRefreshOnlyArrayAndFullTokenFormat() throws {
        let simple = Data(#"[{"email":"fixture@example.test","refresh_token":"fixture-refresh","account_password":"discard-me","two_factor_secret":"discard-me"}]"#.utf8)
        let item = try QueryCredentialTransfer.parse(simple, provider: .antigravity)[0].get()
        XCTAssertTrue(item.credential.accessToken.isEmpty)
        XCTAssertEqual(item.credential.refreshToken, "fixture-refresh")
        let full = Data(#"[{"token":{"access_token":"fixture-access","refresh_token":"fixture-refresh","expiry_timestamp":4000000000,"expires_in":3600,"is_gcp_tos":true,"oauth_client_key":"antigravity_enterprise"}}]"#.utf8)
        let value = try QueryCredentialTransfer.parse(full, provider: .antigravity)[0].get().credential
        XCTAssertEqual(value.effectiveExpiry?.timeIntervalSince1970, 4_000_000_000)
        XCTAssertTrue(value.isGCPToS)
        let claude = Data(#"[{"auth_mode":"oauth","claude_credentials_raw":{"claudeAiOauth":{"accessToken":"fixture","refreshToken":"refresh","expiresAt":4000000000000}}}]"#.utf8)
        XCTAssertEqual(try QueryCredentialTransfer.parse(claude, provider: .claude)[0].get().credential.refreshToken, "refresh")
    }

    func testBatchKeepsFailuresAndRejectsWrongProviders() throws {
        let data = Data(#"{"accounts":[{"access_token":"fixture"},{"email":"no-credentials"}]}"#.utf8)
        let rows = try QueryCredentialTransfer.parse(data, provider: .antigravity)
        XCTAssertEqual(rows.count, 2)
        XCTAssertNoThrow(try rows[0].get())
        XCTAssertThrowsError(try rows[1].get())
        let wrong = Data(#"{"provider":"claude","accounts":[{"access_token":"fixture"}]}"#.utf8)
        XCTAssertThrowsError(try QueryCredentialTransfer.parse(wrong, provider: .antigravity)[0].get()) {
            XCTAssertEqual($0 as? QueryAccountError, .wrongProvider)
        }
    }

    func testOAuthRenewalPreservesRefreshTokenWhenServerDoesNotRotateIt() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransferHTTPStub.self]
        let session = URLSession(configuration: configuration)
        for provider in [UsageProvider.codex, .claude, .antigravity] {
            let value = try await QueryOAuthClient(provider: provider, session: session).refresh(credential(expired: true))
            XCTAssertEqual(value.accessToken, "renewed-access")
            XCTAssertEqual(value.refreshToken, "fixture-refresh")
            XCTAssertGreaterThan(try XCTUnwrap(value.expiresAt).timeIntervalSinceNow, 3500)
        }
    }

    func testExportDocumentUsesPrivateFilePermissionsAndTranslationsAreComplete() throws {
        let document = QueryAccountExportDocument(data: Data("{}".utf8))
        let file = try makeTemporaryDirectory().appendingPathComponent("export.json")
        try document.makeFileWrapper().write(to: file, options: .atomic, originalContentsURL: nil)
        XCTAssertEqual(try Data(contentsOf: file), Data("{}".utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        let expected = Set(AppLanguage.allCases).subtracting([.english, .simplifiedChinese])
        for (key, translations) in accountTransferTranslations { XCTAssertEqual(Set(translations.keys), expected, key) }
    }

    @MainActor
    func testRefreshOnlyImportRenewsByDefaultThenExportsAndRoundTrips() async throws {
        let root = try makeTemporaryDirectory()
        let db = try makeMigratedDatabase(in: root)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = TransferVault()
        let store = makeStore(defaults: defaults, root: root, db: db, vault: vault)
        let input = Data(#"[{"refresh_token":"fixture-refresh","account_password":"must-not-export"}]"#.utf8)
        await store.importCredential(input)
        XCTAssertNil(store.error)
        XCTAssertEqual(vault.renewals, 1)
        XCTAssertEqual(store.accounts.first?.hasRefreshToken, true)
        let exported = try store.exportCredentials([try key()])
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains("must-not-export"))
        let parsed = try QueryCredentialTransfer.parse(exported, provider: .antigravity)[0].get()
        XCTAssertEqual(parsed.credential.refreshToken, "rotated-fixture")
        XCTAssertEqual(parsed.expectedAccountKey, try key())
        await store.importCredential(exported)
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertNil(store.error)
    }

    @MainActor
    func testIndependentGrantRenewsInBackgroundAndPersistsNewExpiry() async throws {
        let root = try makeTemporaryDirectory()
        let db = try makeMigratedDatabase(in: root)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let record = ManagedCodexAccount(accountKey: try key(), directoryID: id, name: "Fixture",
            source: .independent, status: .available, verifiedAt: Date(),
            accessExpiresAt: Date().addingTimeInterval(-60), hasRefreshToken: true)
        defaults.set(try JSONEncoder().encode([record]), forKey: "QuotaLens.queryAccounts.antigravity")
        let vault = TransferVault()
        vault.save(credential(expired: true), id: id)
        let store = makeStore(defaults: defaults, root: root, db: db, vault: vault)
        await store.renewDueAccounts()
        XCTAssertNil(store.error)
        XCTAssertEqual(vault.renewals, 1)
        XCTAssertEqual(store.accounts.first?.status, .available)
        XCTAssertGreaterThan(try XCTUnwrap(store.accounts.first?.accessExpiresAt).timeIntervalSinceNow, 3000)
        XCTAssertEqual(try vault.load(id).refreshToken, "rotated-fixture")
        await store.renewDueAccounts()
        XCTAssertEqual(vault.renewals, 1)
    }

    @MainActor
    func testMissingCredentialIsNotReportedAsExpiryAndCanBeRestoredLocally() async throws {
        let root = try makeTemporaryDirectory()
        let db = try makeMigratedDatabase(in: root)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let record = ManagedCodexAccount(accountKey: try key(), directoryID: UUID(), name: "Fixture", source: .independent, status: .available)
        defaults.set(try JSONEncoder().encode([record]), forKey: "QuotaLens.queryAccounts.antigravity")
        let vault = TransferVault()
        let local = credential()
        let store = makeStore(defaults: defaults, root: root, db: db, vault: vault, local: { [local] })
        await store.prepare()
        XCTAssertEqual(store.accounts.first?.status, .missingCredentials)
        XCTAssertEqual(vault.renewals, 0)
        await store.discoverLocal(force: true)
        XCTAssertNil(store.error)
        XCTAssertNotNil(store.operationMessage)
        XCTAssertEqual(store.accounts.first?.status, .available)
        XCTAssertEqual(store.accounts.first?.source, .local)
    }

    @MainActor
    func testManualLocalImportAlwaysReportsNoFileAndUnchangedAccount() async throws {
        let root = try makeTemporaryDirectory()
        let db = try makeMigratedDatabase(in: root)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = TransferVault()
        let empty = makeStore(defaults: defaults, root: root, db: db, vault: vault, local: { [] })
        await empty.discoverLocal(force: true)
        XCTAssertEqual(empty.error, QueryAccountError.credentialMissing.userMessage)
        let value = credential()
        let record = ManagedCodexAccount(accountKey: try key(), directoryID: UUID(), name: "Fixture", source: .independent, status: .available)
        defaults.set(try JSONEncoder().encode([record]), forKey: "QuotaLens.queryAccounts.antigravity")
        vault.save(value, id: record.directoryID)
        let store = makeStore(defaults: defaults, root: root, db: db, vault: vault, local: { [value] })
        await store.discoverLocal(force: true)
        XCTAssertNil(store.error)
        XCTAssertNotNil(store.operationMessage)
        XCTAssertEqual(store.accounts.first?.source, .independent)
    }

    @MainActor
    func testInvalidGrantDoesNotPretendRenewalSucceeded() async throws {
        let root = try makeTemporaryDirectory()
        let db = try makeMigratedDatabase(in: root)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let record = ManagedCodexAccount(accountKey: try key(), directoryID: id, name: "Fixture",
            source: .independent, status: .available, accessExpiresAt: Date().addingTimeInterval(-1))
        defaults.set(try JSONEncoder().encode([record]), forKey: "QuotaLens.queryAccounts.antigravity")
        let vault = TransferVault()
        vault.save(credential(expired: true), id: id)
        let store = makeStore(defaults: defaults, root: root, db: db, vault: vault, renew: { _, _ in throw QueryAccountError.authorization })
        await store.renewDueAccounts()
        XCTAssertEqual(store.accounts.first?.status, .needsAuthorization)
        XCTAssertEqual(try vault.load(id).refreshToken, "fixture-refresh")
    }

    @MainActor
    func testOldDisabledPreferenceCannotDisableDefaultRenewal() async throws {
        let root = try makeTemporaryDirectory()
        let db = try makeMigratedDatabase(in: root)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let record = ManagedCodexAccount(accountKey: try key(), directoryID: id, name: "Fixture",
            source: .imported, status: .available, accessExpiresAt: Date().addingTimeInterval(-1), hasRefreshToken: true)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object["refreshAllowed"] = false
        defaults.set(try JSONSerialization.data(withJSONObject: [object]), forKey: "QuotaLens.queryAccounts.antigravity")
        defaults.set(false, forKey: "QuotaLens.queryAccounts.antigravity.allowImportedRenewal")
        let vault = TransferVault()
        vault.save(credential(expired: true), id: id)
        let store = makeStore(defaults: defaults, root: root, db: db, vault: vault)
        XCTAssertTrue(try XCTUnwrap(store.accounts.first).canQuery)
        await store.renewDueAccounts()
        XCTAssertNil(store.error)
        XCTAssertEqual(vault.renewals, 1)
        XCTAssertEqual(store.accounts.first?.status, .available)
    }
}

private final class TransferVault: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: QueryCredential] = [:]
    private var counter = 0
    var renewals: Int { lock.withLock { counter } }
    func recordRenewal() { lock.withLock { counter += 1 } }
    func save(_ credential: QueryCredential, id: UUID) { lock.withLock { values[id] = credential } }
    func load(_ id: UUID) throws -> QueryCredential {
        try lock.withLock { guard let value = values[id] else { throw QueryAccountError.credentialMissing }; return value }
    }
    func remove(_ id: UUID) { _ = lock.withLock { values.removeValue(forKey: id) } }
}

private final class TransferHTTPStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let json: String
        switch request.url!.path {
        case "/token", "/oauth/token", "/v1/oauth/token":
            json = #"{"access_token":"renewed-access","expires_in":3600}"#
        case "/oauth2/v2/userinfo": json = #"{"id":"fixture","email":"fixture@example.test"}"#
        case "/v1internal:loadCodeAssist": json = #"{"cloudaicompanionProject":"fixture-project"}"#
        case "/v1internal:retrieveUserQuotaSummary": json = #"{"groups":[]}"#
        default: json = #"{"models":{"fixture":{"displayName":"Fixture","quotaInfo":{"remainingFraction":0.7,"resetTime":"2096-01-01T00:00:00Z"}}}}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
