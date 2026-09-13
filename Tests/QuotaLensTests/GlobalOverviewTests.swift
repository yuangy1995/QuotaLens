import Foundation
import XCTest
@testable import QuotaLens

final class GlobalOverviewTests: XCTestCase {
    private func analysis(_ provider: UsageProvider, path: String?, current: Int64, previous: Int64) -> OverviewAnalysis {
        let date = Date()
        let session = CodexSessionDTO(sessionId: provider.rawValue, provider: provider, rootSessionId: provider.rawValue,
            title: "Fixture", projectName: "same-name", cwd: path, createdAt: date, updatedAt: date)
        return OverviewAnalysis(period: .init(days: 7),
            current: .init(totalTokens: .init(inputTokens: current),
                           modelDistribution: [.init(modelCanonical: "same-model", tokens: .init(inputTokens: current), estimatedCost: .zero, eventCount: 1)]),
            previous: .init(totalTokens: .init(inputTokens: previous),
                            modelDistribution: [.init(modelCanonical: "same-model", tokens: .init(inputTokens: previous), estimatedCost: .zero, eventCount: 1)]),
            sessions: [.init(session: session, tokens: current, cost: .zero)], contributionsAvailable: true,
            previousSessions: [.init(session: session, tokens: previous, cost: .zero)])
    }

    func testProjectsMergeOnlyMatchingPathsAndKeepMissingOwnershipSeparate() {
        let analyses: [UsageProvider: OverviewAnalysis] = [
            .codex: analysis(.codex, path: "/work/project", current: 120, previous: 50),
            .claude: analysis(.claude, path: "/work/project", current: 80, previous: 20)
        ]
        let projects = GlobalUsageDistribution.rows(analyses, dimension: .projects)
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.tokens, 200)
        XCTAssertEqual(projects.first?.previousTokens, 70)
        XCTAssertEqual(projects.first?.providers, [.codex, .claude])
        let missing = GlobalUsageDistribution.rows([
            .codex: analysis(.codex, path: nil, current: 10, previous: 2),
            .claude: analysis(.claude, path: nil, current: 20, previous: 3)
        ], dimension: .projects)
        XCTAssertEqual(missing.count, 2)
    }

    func testModelsRetainToolContextInsteadOfCombiningIdenticalNames() {
        let rows = GlobalUsageDistribution.rows([
            .codex: analysis(.codex, path: "/a", current: 12, previous: 10),
            .claude: analysis(.claude, path: "/a", current: 8, previous: 5)
        ], dimension: .models)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
        XCTAssertEqual(rows.first?.tokens, 12)
    }

    func testModelThatDisappearedRemainsVisibleWithZeroCurrentUsage() {
        let original = analysis(.codex, path: nil, current: 0, previous: 40)
        let value = OverviewAnalysis(period: original.period, current: .init(), previous: original.previous,
                                     sessions: [], contributionsAvailable: true)
        let rows = GlobalUsageDistribution.rows([.codex: value], dimension: .models)
        XCTAssertEqual(rows.first?.tokens, 0)
        XCTAssertEqual(rows.first?.previousTokens, 40)
    }

    @MainActor
    func testThreeGlobalRoutesRemainAvailableWithOneTool() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tools = EnabledToolsStore(defaults: defaults)
        let navigation = AppNavigationStore(enabledTools: tools, activeTool: nil, defaults: defaults)
        for page in OverviewPage.allCases {
            navigation.selectOverviewPage(page)
            navigation.normalize(enabledTools: [.codex], activeTool: .codex)
            XCTAssertEqual(navigation.overviewPage, page)
            XCTAssertEqual(navigation.selectedContext, .overview)
        }
        XCTAssertEqual(OverviewPage.allCases.count, 3)
    }

    @MainActor
    func testIndependentCodexPlaintextIsTemporaryAndRotatedCredentialIsEncrypted() async throws {
        let root = try makeTemporaryDirectory()
        let db = try makeMigratedDatabase(in: root)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let key = AccountIdentity.stableAccountKey(from: "fixture-a")
        let record = ManagedCodexAccount(accountKey: key, directoryID: id, name: "Fixture", source: .independent, status: .available)
        defaults.set(try JSONEncoder().encode([record]), forKey: "QuotaLens.managedCodexAccounts")
        let vault = LocalCredentialStore(root: root.appendingPathComponent("EncryptedCredentials"))
        let original = Data(#"{"tokens":{"account_id":"fixture-a","access_token":"original-fixture"}}"#.utf8)
        try vault.save(original, id: "codex-" + id.uuidString)
        let reader = CodexAccountQuotaReader(database: db, fetch: { home in
            XCTAssertTrue(home.lastPathComponent.hasPrefix("query-"))
            let url = home.appendingPathComponent("auth.json")
            XCTAssertEqual(try Data(contentsOf: url), original)
            try Data(#"{"tokens":{"account_id":"fixture-a","access_token":"rotated-fixture"}}"#.utf8).write(to: url)
            let identity = #"{"account":{"type":"chatgpt","accountId":"fixture-a","email":"fixture@example.test"},"requiresOpenaiAuth":true}"#
            let quota = #"{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":4000000000}}}"#
            return CodexServerSnapshot(capturedAt: Date(), version: "test", binaryPath: "/fixture",
                account: try JSONDecoder().decode(AccountReadResult.self, from: Data(identity.utf8)),
                accountRawJson: identity, rateLimits: try JSONDecoder().decode(RateLimitsReadResult.self, from: Data(quota.utf8)),
                rateLimitsRawJson: quota, accountUsage: nil)
        }, fetchSubscription: { _, _ in nil })
        let store = CodexAccountsStore(database: db, defaults: defaults, root: root, reader: reader)
        store.select(key)
        await store.loadSelection(refresh: true)
        XCTAssertNil(store.error)
        let saved = try vault.load(Data.self, id: "codex-" + id.uuidString)
        XCTAssertTrue(String(decoding: saved, as: UTF8.self).contains("rotated-fixture"))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("query-") })
    }
}
