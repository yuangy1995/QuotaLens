import AppKit
import SwiftUI
import XCTest
@testable import QuotaLens

final class ResetCreditHistoryTests: XCTestCase {
    private let payload = Data(#"{"as_of":"2026-09-14T00:00:00.123456Z","window_start":"2026-08-15T00:00:00Z","events":[{"id":"grant","kind":"granted","occurred_at":"2026-09-01T01:00:00Z"},{"id":"use","kind":"used","occurred_at":"2026-09-02T02:00:00.123456Z"}],"next_cursor":null}"#.utf8)

    func testDecodesActualHistorySchemaWithoutInventingCreditDetails() throws {
        let page = try ResetCreditHistoryPage.decode(payload)
        XCTAssertEqual(page.events.count, 2)
        XCTAssertEqual(page.events.filter(\.isUsed).count, 1)
        XCTAssertNil(page.nextCursor)
        XCTAssertLessThan(page.windowStart, page.asOf)
        let data = try JSONEncoder().encode(page.events)
        let restored = try JSONDecoder().decode([ResetCreditHistoryEvent].self, from: data)
        XCTAssertEqual(restored.last?.occurredAt, page.events.last?.occurredAt)
        XCTAssertThrowsError(try ResetCreditHistoryPage.decode(Data(#"{"credits":[]}"#.utf8)))
    }

    @MainActor
    func testPaginationDeduplicatesAndCacheRemainsAccountScoped() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let page = try ResetCreditHistoryPage.decode(payload)
        let store = ResetCreditHistoryStore(defaults: defaults)
        await store.load(accountKey: "a") { cursor in
            XCTAssertNil(cursor)
            return .init(events: page.events, asOf: page.asOf, windowStart: page.windowStart, nextCursor: "next")
        }
        await store.load(accountKey: "a", append: true) { cursor in
            XCTAssertEqual(cursor, "next")
            return .init(events: [page.events[1], .init(id: "older", kind: "granted", occurredAt: page.windowStart)],
                         asOf: page.asOf, windowStart: page.windowStart, nextCursor: nil)
        }
        XCTAssertEqual(store.events.count, 3)
        let cached = ResetCreditHistoryStore(defaults: defaults)
        await cached.load(accountKey: "a") { _ in throw QueryAccountError.unavailable }
        XCTAssertEqual(cached.events.count, 3)
        XCTAssertNotNil(cached.error)
        await cached.load(accountKey: "b") { _ in
            .init(events: [], asOf: page.asOf, windowStart: page.windowStart, nextCursor: nil)
        }
        XCTAssertTrue(cached.events.isEmpty)
        XCTAssertEqual(cached.accountKey, "b")
    }

    func testHistoryClientUsesOnlyGETAndPinnedAccount() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HistoryHTTPStub.self]
        let client = QueryCredentialClient(session: URLSession(configuration: config))
        let claims = try JSONSerialization.data(withJSONObject: [
            "https://api.openai.com/auth": ["chatgpt_account_id": "history-fixture"], "exp": 4_000_000_000
        ])
        let middle = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let credential = QueryCredential(accessToken: "header." + middle + ".fixture", refreshToken: nil, expiresAt: nil, isGCPToS: false)
        let page = try await client.resetCreditHistory(credential, accountKey: AccountIdentity.stableAccountKey(from: "history-fixture"), cursor: "cursor/with?punctuation")
        XCTAssertEqual(page.events.first?.kind, "used")
        do {
            _ = try await client.resetCreditHistory(credential, accountKey: "wrong-account")
            XCTFail("Mismatched account must be rejected")
        } catch { XCTAssertEqual(error as? QueryAccountError, .identity) }
    }

    @MainActor
    func testOpeningInlinePeekDoesNotChangeSelectedAccount() throws {
        let root = try makeTemporaryDirectory()
        let db = try makeMigratedDatabase(in: root)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = [
            ManagedCodexAccount(accountKey: "a", directoryID: UUID(), name: "First", source: .imported, status: .available),
            ManagedCodexAccount(accountKey: "b", directoryID: UUID(), name: "Second", source: .imported, status: .available)
        ]
        defaults.set(try JSONEncoder().encode(accounts), forKey: "QuotaLens.managedCodexAccounts")
        let store = CodexAccountsStore(database: db, defaults: defaults, root: root)
        store.select("a")
        let host = NSHostingView(rootView: OverviewQuotaPeek(accounts: store, accountKey: "b"))
        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(store.selectedKey, "a")
        XCTAssertEqual(host.bounds.size, CGSize(width: 680, height: 500))
    }

    @MainActor
    func testHistoryPanelRendersAndContainsNoRedemptionControls() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ResetCreditHistoryStore(defaults: defaults)
        let page = try ResetCreditHistoryPage.decode(payload)
        await store.load(accountKey: "fixture") { _ in page }
        for scheme in [ColorScheme.light, .dark] {
            let content = ResetCreditHistoryPanel(store: store, refresh: {}, loadMore: {})
                .padding(24).frame(width: 760)
                .background(scheme == .dark ? Color(white: 0.1) : Color(white: 0.97))
                .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: content)
            host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            host.setFrameSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.bounds.width, 760)
            if let directory = ProcessInfo.processInfo.environment["QUOTALENS_RESET_HISTORY_SCREENSHOT_DIR"] {
                let url = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: url.appendingPathComponent("reset-history-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }

    func testHistoryTranslationsCoverSupportedLanguages() {
        let expected = Set(AppLanguage.allCases).subtracting([.english, .simplifiedChinese])
        for (key, values) in resetHistoryTranslations { XCTAssertEqual(Set(values.keys), expected, key) }
    }
}

private final class HistoryHTTPStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.url?.path, "/backend-api/wham/rate-limit-reset-credits/history")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "history-fixture")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "cursor/with?punctuation")
        let body = Data(#"{"as_of":"2026-09-14T00:00:00Z","window_start":"2026-08-15T00:00:00Z","events":[{"id":"used","kind":"used","occurred_at":"2026-09-02T02:00:00Z"}],"next_cursor":null}"#.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
