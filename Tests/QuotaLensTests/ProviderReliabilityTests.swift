import Foundation
import SQLite3
import XCTest
@testable import QuotaLens

final class ProviderReliabilityTests: XCTestCase {
    func testClaude401RejectsTokenAndRetriesOnceWithRefreshedCredentials() async throws {
        let fixture = makeClaudeFixture(accountKey: "account-a")
        ClaudeURLProtocolStub.register([
            .init(statusCode: 401, body: "{}"),
            .init(statusCode: 200, body: Self.validClaudeUsage)
        ], for: fixture.usageURL)
        ClaudeURLProtocolStub.register([
            .init(statusCode: 200, body: Self.refreshedCredentials(accessToken: "access-new"))
        ], for: fixture.refreshURL)

        let client = makeClaudeClient(
            fixture: fixture,
            credentials: ClaudeCredentialBox([Self.credentials(
                accessToken: "access-old",
                refreshToken: "refresh-a",
                accountKey: "account-a"
            )])
        )
        let snapshot = try await client.fetch()

        XCTAssertEqual(snapshot.accountKey, "account-a")
        XCTAssertEqual(
            ClaudeURLProtocolStub.authorizationHeaders(for: fixture.usageURL),
            ["Bearer access-old", "Bearer access-new"]
        )
        XCTAssertEqual(ClaudeURLProtocolStub.requestCount(for: fixture.refreshURL), 1)
    }

    func testClaudeNonScope403RejectsTokenAndRetriesOnce() async throws {
        let fixture = makeClaudeFixture(accountKey: "account-a")
        ClaudeURLProtocolStub.register([
            .init(statusCode: 403, body: #"{"error":"token revoked"}"#),
            .init(statusCode: 200, body: Self.validClaudeUsage)
        ], for: fixture.usageURL)
        ClaudeURLProtocolStub.register([
            .init(statusCode: 200, body: Self.refreshedCredentials(accessToken: "access-after-403"))
        ], for: fixture.refreshURL)

        let client = makeClaudeClient(
            fixture: fixture,
            credentials: ClaudeCredentialBox([Self.credentials(
                accessToken: "access-revoked",
                refreshToken: "refresh-a",
                accountKey: "account-a"
            )])
        )
        _ = try await client.fetch()

        XCTAssertEqual(
            ClaudeURLProtocolStub.authorizationHeaders(for: fixture.usageURL),
            ["Bearer access-revoked", "Bearer access-after-403"]
        )
        XCTAssertEqual(ClaudeURLProtocolStub.requestCount(for: fixture.refreshURL), 1)
    }

    func testClaudeScope403DoesNotRefreshCredentials() async throws {
        let fixture = makeClaudeFixture(accountKey: "account-a")
        ClaudeURLProtocolStub.register([
            .init(statusCode: 403, body: #"{"error":"missing required scope"}"#)
        ], for: fixture.usageURL)

        let client = makeClaudeClient(
            fixture: fixture,
            credentials: ClaudeCredentialBox([Self.credentials(
                accessToken: "access-limited",
                refreshToken: "refresh-a",
                accountKey: "account-a"
            )])
        )

        do {
            _ = try await client.fetch()
            XCTFail("Expected insufficient scope")
        } catch let error as ClaudeUsageClient.FetchError {
            XCTAssertEqual(error, .insufficientScope)
        }
        XCTAssertEqual(ClaudeURLProtocolStub.requestCount(for: fixture.usageURL), 1)
        XCTAssertEqual(ClaudeURLProtocolStub.requestCount(for: fixture.refreshURL), 0)
    }

    func testClaudeSuccessfulAccountDoesNotRestoreAnotherAccountsRejectedToken() async throws {
        let fixture = makeClaudeFixture(accountKey: "multi-account")
        ClaudeURLProtocolStub.register([
            .init(statusCode: 401, body: "{}"),
            .init(statusCode: 401, body: "{}"),
            .init(statusCode: 200, body: Self.validClaudeUsage),
            .init(statusCode: 200, body: Self.validClaudeUsage)
        ], for: fixture.usageURL)
        ClaudeURLProtocolStub.register([
            .init(statusCode: 200, body: Self.refreshedCredentials(accessToken: "access-a-1")),
            .init(statusCode: 200, body: Self.refreshedCredentials(accessToken: "access-a-2"))
        ], for: fixture.refreshURL)

        let credentialBox = ClaudeCredentialBox([Self.credentials(
            accessToken: "access-a",
            refreshToken: "refresh-a",
            accountKey: "account-a"
        )])
        let client = makeClaudeClient(fixture: fixture, credentials: credentialBox)

        do {
            _ = try await client.fetch()
            XCTFail("Expected account A to remain unauthorized")
        } catch let error as ClaudeUsageClient.FetchError {
            XCTAssertEqual(error, .unauthorized)
        }

        credentialBox.replace(with: [Self.credentials(
            accessToken: "access-b",
            refreshToken: nil,
            accountKey: "account-b"
        )])
        _ = try await client.fetch()

        credentialBox.replace(with: [Self.credentials(
            accessToken: "access-a",
            refreshToken: "refresh-a",
            accountKey: "account-a"
        )])
        _ = try await client.fetch()

        XCTAssertEqual(
            ClaudeURLProtocolStub.authorizationHeaders(for: fixture.usageURL),
            ["Bearer access-a", "Bearer access-a-1", "Bearer access-b", "Bearer access-a-2"]
        )
    }

    func testClaudeRefreshPersistenceFailureKeepsSnapshotAndReportsWarning() async throws {
        enum ExpectedError: Error { case persistence }

        let fixture = makeClaudeFixture(accountKey: "account-a")
        ClaudeURLProtocolStub.register([
            .init(statusCode: 401, body: "{}"),
            .init(statusCode: 200, body: Self.validClaudeUsage)
        ], for: fixture.usageURL)
        ClaudeURLProtocolStub.register([
            .init(statusCode: 200, body: Self.refreshedCredentials(accessToken: "access-memory"))
        ], for: fixture.refreshURL)

        let client = makeClaudeClient(
            fixture: fixture,
            credentials: ClaudeCredentialBox([Self.credentials(
                accessToken: "access-old",
                refreshToken: "refresh-a",
                accountKey: "account-a"
            )]),
            credentialSaver: { _, _, _, _, _ in throw ExpectedError.persistence }
        )
        let snapshot = try await client.fetch()

        XCTAssertTrue(snapshot.hasQuota)
        let hasWarning = await client.hasCredentialPersistenceWarning()
        XCTAssertTrue(hasWarning)
        XCTAssertNotNil(ProviderQuotaRefreshResult(
            snapshot: snapshot,
            historySaved: true,
            credentialPersistenceWarning: hasWarning
        ).storageWarningText)
    }

    func testLegacyChatGPTHistoryRemainsUnassignedWhenMultipleAccountsExist() throws {
        let database = try makeMigratedDatabase(in: makeTemporaryDirectory(named: "LegacyAccountAmbiguous"))
        let repositories = Repositories(database: database)
        let legacyKey = AccountIdentity.stableAccountKey(from: "chatgpt_user")
        try insertAccount(legacyKey, emailHash: "legacy-hash", database: database)
        try insertAccount("account-current", emailHash: "current-hash", database: database)
        try insertAccount("account-other", emailHash: "other-hash", database: database)
        try insertDailySnapshot(
            accountKey: legacyKey,
            observedAt: 100,
            totalTokens: 10,
            state: .live,
            rawJSON: "{}",
            database: database
        )

        let migrated = try repositories.migrateLegacyChatGPTAccount(
            to: "account-current",
            emailHash: "current-hash"
        )

        XCTAssertFalse(migrated)
        XCTAssertEqual(try database.intScalar(
            sql: "SELECT COUNT(*) FROM account_daily_snapshots WHERE account_key = ?;",
            bindings: [legacyKey]
        ), 1)
        XCTAssertEqual(try database.intScalar(
            sql: "SELECT COUNT(*) FROM account_daily_snapshots WHERE account_key = 'account-current';"
        ), 0)
    }

    func testLegacyChatGPTHistoryMigratesWhenItIsTheOnlyKnownAccount() throws {
        let database = try makeMigratedDatabase(in: makeTemporaryDirectory(named: "LegacyAccountSingle"))
        let repositories = Repositories(database: database)
        let legacyKey = AccountIdentity.stableAccountKey(from: "chatgpt_user")
        try insertAccount(legacyKey, emailHash: "legacy-hash", database: database)
        try insertDailySnapshot(
            accountKey: legacyKey,
            observedAt: 100,
            totalTokens: 10,
            state: .live,
            rawJSON: "{}",
            database: database
        )

        let migrated = try repositories.migrateLegacyChatGPTAccount(
            to: "account-current",
            emailHash: "current-hash"
        )

        XCTAssertTrue(migrated)
        XCTAssertEqual(try database.intScalar(
            sql: "SELECT COUNT(*) FROM accounts WHERE account_key = ?;",
            bindings: [legacyKey]
        ), 0)
        XCTAssertEqual(try database.intScalar(
            sql: "SELECT COUNT(*) FROM account_daily_snapshots WHERE account_key = 'account-current';"
        ), 1)
    }

    func testAccountMigrationMergesDailySnapshotConflictsWithoutDiscardingBetterRows() throws {
        let database = try makeMigratedDatabase(in: makeTemporaryDirectory(named: "DailySnapshotMerge"))
        let repositories = Repositories(database: database)
        try insertAccount("account-old", emailHash: "old", database: database)
        try insertAccount("account-new", emailHash: "new", database: database)

        try insertDailySnapshot(
            accountKey: "account-new",
            observedAt: 100,
            totalTokens: 10,
            state: .live,
            rawJSON: "{}",
            database: database
        )
        try insertDailySnapshot(
            accountKey: "account-old",
            observedAt: 100,
            totalTokens: 20,
            state: .finalized,
            rawJSON: #"{"complete":true}"#,
            database: database
        )
        try insertDailySnapshot(
            accountKey: "account-new",
            observedAt: 200,
            totalTokens: 30,
            state: .finalized,
            rawJSON: #"{"trusted":true}"#,
            database: database
        )
        try insertDailySnapshot(
            accountKey: "account-old",
            observedAt: 200,
            totalTokens: 99,
            state: .live,
            rawJSON: #"{"longer_but_live":"must not replace finalized"}"#,
            database: database
        )
        try insertDailySnapshot(
            accountKey: "account-old",
            observedAt: 300,
            totalTokens: 40,
            state: .stable,
            rawJSON: #"{"only":"old"}"#,
            database: database
        )

        try repositories.migrateAccountKey(from: "account-old", to: "account-new")

        let rows = try database.executeQuery(
            sql: "SELECT observed_at, total_tokens, data_state, raw_json FROM account_daily_snapshots WHERE account_key = 'account-new' ORDER BY observed_at;"
        ) { statement in
            (
                sqlite3_column_int64(statement, 0),
                sqlite3_column_int64(statement, 1),
                String(cString: sqlite3_column_text(statement, 2)),
                String(cString: sqlite3_column_text(statement, 3))
            )
        }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].0, 100)
        XCTAssertEqual(rows[0].1, 20)
        XCTAssertEqual(rows[0].2, DailyDataState.finalized.rawValue)
        XCTAssertEqual(rows[1].0, 200)
        XCTAssertEqual(rows[1].1, 30)
        XCTAssertEqual(rows[1].2, DailyDataState.finalized.rawValue)
        XCTAssertEqual(rows[2].0, 300)
        XCTAssertEqual(rows[2].1, 40)
        XCTAssertEqual(try database.intScalar(
            sql: "SELECT COUNT(*) FROM account_daily_snapshots WHERE account_key = 'account-old';"
        ), 0)
    }

    func testAntigravityStopDuringCallbackPreventsOldPollFromContinuing() async throws {
        let database = try makeMigratedDatabase(in: makeTemporaryDirectory(named: "AntigravityGeneration"))
        let blocker = FirstCallbackBlocker()
        let resultRecorder = CallbackCountRecorder()
        let poller = AntigravityQuotaPoller(
            database: database,
            onResult: { _ in await resultRecorder.record() },
            onSyncState: { _ in await blocker.handle() }
        )

        let pollTask = Task {
            await poller.pollOnce(force: true, preferredProfile: nil)
        }
        await blocker.waitUntilBlocked()
        await poller.stop()
        await blocker.release()
        await pollTask.value

        let resultCount = await resultRecorder.count
        let syncState = await poller.currentSyncState()
        XCTAssertEqual(resultCount, 0)
        XCTAssertNil(syncState.lastSuccessAt)
        XCTAssertNil(syncState.nextAttemptAt)
    }

    private struct ClaudeFixture {
        let usageURL: URL
        let refreshURL: URL
        let session: URLSession
    }

    private func makeClaudeFixture(accountKey: String) -> ClaudeFixture {
        let identifier = "\(accountKey)-\(UUID().uuidString)"
        let usageURL = URL(string: "https://quotalens.test/\(identifier)/usage")!
        let refreshURL = URL(string: "https://quotalens.test/\(identifier)/refresh")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeURLProtocolStub.self]
        return ClaudeFixture(
            usageURL: usageURL,
            refreshURL: refreshURL,
            session: URLSession(configuration: configuration)
        )
    }

    private func makeClaudeClient(
        fixture: ClaudeFixture,
        credentials: ClaudeCredentialBox,
        credentialSaver: @escaping ClaudeUsageClient.CredentialSaver = { _, _, _, _, _ in }
    ) -> ClaudeUsageClient {
        ClaudeUsageClient(
            session: fixture.session,
            endpoint: fixture.usageURL,
            cacheURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("claude-cache-\(UUID().uuidString).json"),
            tokenRefresher: ClaudeTokenRefresher(
                session: fixture.session,
                endpoint: fixture.refreshURL,
                clientID: "test-client"
            ),
            credentialsProvider: { credentials.read() },
            credentialSaver: credentialSaver
        )
    }

    private static func credentials(
        accessToken: String,
        refreshToken: String?,
        accountKey: String
    ) -> ClaudeStoredCredentials {
        ClaudeStoredCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAtMs: Date().addingTimeInterval(3_600).timeIntervalSince1970 * 1_000,
            scopes: ["user:profile"],
            accountKey: accountKey,
            identityConfidence: .stableProviderID
        )
    }

    private static let validClaudeUsage = #"{"rate_limit_tier":"pro","five_hour":{"utilization":12.5,"resets_at":"2026-09-02T00:00:00Z"}}"#

    private static func refreshedCredentials(accessToken: String) -> String {
        #"{"access_token":"\#(accessToken)","refresh_token":"refresh-new","expires_in":3600}"#
    }

    private func insertAccount(
        _ accountKey: String,
        emailHash: String,
        database: SQLiteDatabase
    ) throws {
        try database.executeUpdate(
            sql: "INSERT INTO accounts (account_key, email_hash, plan_type, first_seen_at, last_seen_at) VALUES (?, ?, 'pro', 1, 2);",
            bindings: [accountKey, emailHash]
        )
    }

    private func insertDailySnapshot(
        accountKey: String,
        observedAt: Int64,
        totalTokens: Int64,
        state: DailyDataState,
        rawJSON: String,
        database: SQLiteDatabase
    ) throws {
        try database.executeUpdate(
            sql: """
            INSERT INTO account_daily_snapshots (
                account_key, server_start_date, observed_at, total_tokens, data_state, raw_json
            ) VALUES (?, '2026-09-01', ?, ?, ?, ?);
            """,
            bindings: [accountKey, observedAt, totalTokens, state.rawValue, rawJSON]
        )
    }
}

private final class ClaudeCredentialBox: @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [ClaudeStoredCredentials]

    init(_ credentials: [ClaudeStoredCredentials]) {
        self.credentials = credentials
    }

    func read() -> [ClaudeStoredCredentials] {
        lock.withLock { credentials }
    }

    func replace(with credentials: [ClaudeStoredCredentials]) {
        lock.withLock { self.credentials = credentials }
    }
}

private final class ClaudeURLProtocolStub: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        let statusCode: Int
        let body: Data

        init(statusCode: Int, body: String) {
            self.statusCode = statusCode
            self.body = Data(body.utf8)
        }
    }

    private struct RequestRecord: Sendable {
        let authorization: String?
    }

    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [String: [Response]] = [:]
        private var requests: [String: [RequestRecord]] = [:]

        func register(_ values: [Response], for url: URL) {
            lock.withLock {
                responses[url.absoluteString] = values
                requests[url.absoluteString] = []
            }
        }

        func consume(for request: URLRequest) -> Response? {
            guard let url = request.url else { return nil }
            return lock.withLock {
                let key = url.absoluteString
                requests[key, default: []].append(RequestRecord(
                    authorization: request.value(forHTTPHeaderField: "Authorization")
                ))
                guard var values = responses[key], !values.isEmpty else { return nil }
                let first = values.removeFirst()
                responses[key] = values
                return first
            }
        }

        func requestRecords(for url: URL) -> [RequestRecord] {
            lock.withLock { requests[url.absoluteString] ?? [] }
        }
    }

    private static let store = Store()

    static func register(_ responses: [Response], for url: URL) {
        store.register(responses, for: url)
    }

    static func authorizationHeaders(for url: URL) -> [String] {
        store.requestRecords(for: url).compactMap(\.authorization)
    }

    static func requestCount(for url: URL) -> Int {
        store.requestRecords(for: url).count
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let stub = Self.store.consume(for: request),
              let response = HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor FirstCallbackBlocker {
    private var hasBlocked = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func handle() async {
        guard !hasBlocked else { return }
        hasBlocked = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilBlocked() async {
        if hasBlocked { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor CallbackCountRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
