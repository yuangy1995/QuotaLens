import SQLite3
import XCTest
@testable import QuotaLens

final class UsageRefreshRegressionTests: XCTestCase {
    func testModelsFromMetadataAndNestedSettingsSurviveCheckpoint() throws {
        let contexts = [
            #"{"type":"session_meta","payload":{"id":"test","model":"gpt-6-astra"}}"#,
            #"{"type":"session_meta","model":"gpt-6-astra","payload":{"id":"test"}}"#,
            #"{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-6-astra"}}}"#,
            #"{"type":"turn_context","payload":{"collaboration_mode":{"settings":{"model":"gpt-6-astra"}}}}"#
        ]
        for context in contexts {
            let event = try XCTUnwrap(RolloutLineDecoder.decodeLine(context))
            XCTAssertEqual(event.model, "gpt-6-astra")
            let reducer = CodexUsageReducer(sessionId: "test", rootSessionId: "test", isChildSession: false, sourcePath: "/tmp/test.jsonl")
            var state = CodexUsageReducer.ReducerState()
            _ = reducer.reduce(event: event, lineRecord: record(context), state: &state)
            var resumed = CodexUsageReducer.ReducerState(checkpoint: state.makeCheckpoint())
            let usage = try XCTUnwrap(reducer.reduce(
                event: RolloutWireEvent(eventType: "token_count", timestampMs: BundledPricingCatalog.publishedAtMs,
                                        lastTokenUsage: RawTokenUsagePayload(inputTokens: 10, outputTokens: 5)),
                lineRecord: record("usage", offset: 1000), state: &resumed
            ))
            XCTAssertEqual(usage.modelRaw, "gpt-6-astra")
            XCTAssertEqual(usage.modelCanonical, "gpt-6-astra")
        }
        let explicit = try XCTUnwrap(RolloutLineDecoder.decodeLine(
            #"{"type":"turn_context","payload":{"model":"original-model","collaboration_mode":{"settings":{"model":"other-model"}}}}"#
        ))
        XCTAssertEqual(explicit.model, "original-model")
        XCTAssertEqual(ModelAliasResolver.resolve(rawModel: "unreleased-model"), "unreleased-model")
        XCTAssertEqual(ModelAliasResolver.resolve(rawModel: nil), "unknown")
    }

    func testParserUpgradeRepairsStoredUnknownOnceThenResumesIncrementally() async throws {
        let root = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: root)
        let paths = CodexHistoryPaths(rootURL: root)
        let file = paths.sessionsURL.appendingPathComponent("rollout-test.jsonl")
        let text = rolloutText(sessionId: "test", input: 10, output: 5)
            .replacingOccurrences(of: #""model":"gpt-5.4""#,
                                  with: #""collaboration_mode":{"settings":{"model":"gpt-6-astra"}}"#)
        try overwriteFile(file, with: text)
        let importer = CodexUsageImportActor(database: database)
        _ = try await importer.importCodexHistory(paths: paths)
        try database.execute(sql: """
        UPDATE codex_import_sources SET parser_version = 7;
        UPDATE codex_usage_events SET model_raw = 'unknown', model_canonical = 'unknown';
        """)
        let repaired = try await importer.importCodexHistory(paths: paths)
        XCTAssertGreaterThan(repaired.bytesRead, 0)
        XCTAssertEqual(try database.stringScalar(sql: "SELECT model_raw FROM codex_usage_events;"), "gpt-6-astra")
        let unchanged = try await importer.importCodexHistory(paths: paths)
        XCTAssertEqual(unchanged.bytesRead, 0)
        XCTAssertEqual(unchanged.eventsInserted, 0)
        let appended = "{\"type\":\"token_count\",\"timestamp\":1788652800,\"payload\":{\"last_token_usage\":{\"input_tokens\":2,\"output_tokens\":1}}}\n"
        try appendFile(file, with: appended)
        let incremental = try await importer.importCodexHistory(paths: paths)
        XCTAssertEqual(incremental.bytesRead, Int64(appended.utf8.count))
        XCTAssertEqual(incremental.eventsInserted, 1)
    }

    @MainActor
    func testRescanDiscoversNewSessionAndRefreshesSelectedConversation() async throws {
        let root = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: root)
        let paths = CodexHistoryPaths(rootURL: root)
        let file = paths.sessionsURL.appendingPathComponent("rollout-first.jsonl")
        try overwriteFile(file, with: rolloutText(sessionId: "first", input: 10, output: 5))
        let importer = CodexUsageImportActor(database: database)
        _ = try await importer.importCodexHistory(paths: paths)
        let store = SessionsStore(facade: UsageQueryFacade(database: database), providerFilter: .codex)
        await store.reloadSessions()
        await store.reloadSessions(refreshSelectedDetail: true)
        XCTAssertEqual(store.selectedDetail?.session.tokens.canonicalTotalTokens, 15)
        let selected = store.selectedSessionId
        let appended = """
        {"type":"token_count","timestamp":"2026-09-06T12:00:00Z","payload":{"last_token_usage":{"input_tokens":20,"output_tokens":5}}}
        {"type":"event_msg","timestamp":"2026-09-06T12:00:01Z","payload":{"type":"user_message","message":"new conversation content"}}

        """
        try appendFile(file, with: appended)
        try overwriteFile(paths.sessionsURL.appendingPathComponent("rollout-second.jsonl"),
                          with: rolloutText(sessionId: "second", input: 1, output: 1))
        _ = try await importer.importCodexHistory(paths: paths)
        await store.reloadSessions(refreshSelectedDetail: true)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.selectedSessionId, selected)
        XCTAssertEqual(store.selectedDetail?.session.tokens.canonicalTotalTokens, 40)
        XCTAssertTrue(store.selectedConversation?.messages.contains { $0.text == "new conversation content" } == true)
        await store.reloadSessions(refreshSelectedDetail: true)
        XCTAssertTrue(store.selectedConversation?.messages.contains { $0.text == "new conversation content" } == true)
    }

    func testAstraReleaseBoundaryAndFable51CachePricing() {
        let beforeRelease = PricingEvaluator.evaluate(modelCanonical: "gpt-6-astra", serviceTier: nil,
            timestampMs: 1788393599999, tokens: TokenBreakdown(inputTokens: 1))
        XCTAssertEqual(beforeRelease.pricingStatus, .unpricedHistoricalRuleMissing)
        let released = PricingEvaluator.evaluate(modelCanonical: "gpt-6-astra", serviceTier: nil,
            timestampMs: 1788393600000, tokens: TokenBreakdown(inputTokens: 1))
        XCTAssertEqual(released.estimatedCost.rawValue, 10_000)
        for model in ["claude-fable-5-1", "claude-mythos-5-1"] {
            let price = ClaudePricingCatalogService.evaluate(modelRaw: model, uncachedInput: 100_000,
                cachedInput: 100_000, cacheWrite5m: 100_000, cacheWrite1h: 100_000, output: 100_000)
            XCTAssertEqual(price.modelCanonical, model)
            XCTAssertEqual(price.status, .priced)
            XCTAssertEqual(price.cost.rawValue, 9_275_000_000)
        }
        let previous = ClaudePricingCatalogService.evaluate(modelRaw: "claude-fable-5", uncachedInput: 0,
            cachedInput: 100_000, cacheWrite5m: 0, cacheWrite1h: 0, output: 0)
        XCTAssertEqual(previous.cost.rawValue, 100_000_000)
    }

    func testClaudeRepricesExistingLedgerWithoutReimportingLogs() async throws {
        let root = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: root)
        let logs = root.appendingPathComponent("projects")
        let file = logs.appendingPathComponent("session.jsonl")
        try overwriteFile(file, with: """
        {"type":"assistant","sessionId":"session","timestamp":"2026-09-06T12:00:00Z","message":{"id":"msg1","model":"claude-fable-5-1","usage":{"input_tokens":0,"cache_read_input_tokens":1000,"output_tokens":0}}}

        """)
        let importer = ClaudeUsageImportActor(database: database, roots: [logs])
        _ = try await importer.scan()
        XCTAssertEqual(try database.intScalar(sql: "SELECT COUNT(*) FROM codex_usage_events WHERE provider = 'claude';"), 1)
        try database.execute(sql: """
        UPDATE codex_usage_events SET pricing_catalog_version = 'old', model_canonical = 'claude-fable-5', estimated_cost_usd_nano = 1000000;
        UPDATE app_metadata SET value = 'old' WHERE key = 'claude_usage_pricing_version';
        """)
        let repriced = try await importer.scan()
        XCTAssertEqual(repriced.filesChanged, 0)
        XCTAssertEqual(try database.stringScalar(sql: "SELECT model_canonical FROM codex_usage_events;"), "claude-fable-5-1")
        XCTAssertEqual(try database.int64Scalar(sql: "SELECT estimated_cost_usd_nano FROM codex_usage_events;"), 250_000)
        XCTAssertEqual(try database.int64Scalar(sql: "SELECT estimated_cost_usd_nano FROM codex_session_summaries;"), 250_000)
        let unchanged = try await importer.scan()
        XCTAssertEqual(unchanged.eventsUpdated, 0)
    }

    func testPricingVersionCheckUsesCoveringIndex() throws {
        let root = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: root)
        let plan = try database.executeQuery(sql: """
        EXPLAIN QUERY PLAN SELECT EXISTS(SELECT 1 FROM codex_usage_events
        WHERE provider = 'codex' AND (pricing_catalog_version IS NULL OR pricing_catalog_version != ?));
        """, bindings: [BundledPricingCatalog.currentVersion]) { String(cString: sqlite3_column_text($0, 3)) }
        XCTAssertTrue(plan.contains { $0.contains("COVERING INDEX idx_usage_events_provider_catalog") }, plan.joined(separator: "\n"))
    }

    private func record(_ text: String, offset: Int64 = 0) -> JSONLLineRecord {
        JSONLLineRecord(lineIndex: 1, startOffset: offset, lineBytes: text.utf8.count + 1, lineString: text)
    }
}
