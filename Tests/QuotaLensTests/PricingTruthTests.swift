import CryptoKit
import SQLite3
import XCTest
@testable import QuotaLens

final class PricingTruthTests: XCTestCase {
    func testOfficialGoldenRatesForEveryBundledModel() throws {
        let directory = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: directory)
        try PricingCatalogService.shared.ensureCatalogInstalled(database: database)
        let snapshot = try PricingCatalogService.shared.loadSnapshot(database: database)

        XCTAssertEqual(snapshot.catalogVersion, BundledPricingCatalog.currentVersion)
        let rates: [(String, Int64, Int64, Int64)] = [
            ("gpt-5.6-sol", 4_000, 400, 20_000),
            ("gpt-5.6-terra", 2_000, 200, 12_000),
            ("gpt-5.6-luna", 200, 20, 1_200),
            ("gpt-5.5", 5_000, 500, 30_000),
            ("gpt-5.4", 2_500, 250, 15_000),
            ("gpt-5.4-mini", 750, 75, 4_500),
            ("gpt-5.4-nano", 200, 20, 1_250),
            ("gpt-5.3-codex", 1_750, 175, 14_000),
            ("gpt-5.2-codex", 1_750, 175, 14_000),
            ("gpt-5.1-codex", 1_250, 125, 10_000),
            ("gpt-5.1-codex-mini", 250, 25, 2_000)
        ]

        let goldenTokenCount: Int64 = 100_000
        let currentTimestamp = BundledPricingCatalog.publishedAtMs
        for (model, inputRate, cachedRate, outputRate) in rates {
            let input = snapshot.evaluate(
                modelCanonical: model,
                serviceTier: nil,
                timestampMs: currentTimestamp,
                tokens: TokenBreakdown(inputTokens: goldenTokenCount)
            )
            let cached = snapshot.evaluate(
                modelCanonical: model,
                serviceTier: nil,
                timestampMs: currentTimestamp,
                tokens: TokenBreakdown(inputTokens: goldenTokenCount, cachedInputTokens: goldenTokenCount)
            )
            let output = snapshot.evaluate(
                modelCanonical: model,
                serviceTier: nil,
                timestampMs: currentTimestamp,
                tokens: TokenBreakdown(outputTokens: goldenTokenCount)
            )
            XCTAssertEqual(input.pricingStatus, .priced, model)
            XCTAssertEqual(cached.pricingStatus, .priced, model)
            XCTAssertEqual(output.pricingStatus, .priced, model)
            XCTAssertEqual(input.estimatedCost.rawValue, inputRate * goldenTokenCount, model)
            XCTAssertEqual(cached.estimatedCost.rawValue, cachedRate * goldenTokenCount, model)
            XCTAssertEqual(output.estimatedCost.rawValue, outputRate * goldenTokenCount, model)
        }
    }

    func testLongContextAndCacheWriteRulesAreAuditable() throws {
        let model = try XCTUnwrap(BundledPricingCatalog.defaultCatalog.models.first { $0.modelKey == "gpt-5.6-sol" })
        let rule = try XCTUnwrap(model.rules.first { $0.serviceTier == nil && $0.effectiveToMs == nil })
        XCTAssertEqual(rule.cacheWriteNanoUsdPerToken, 5_000)
        XCTAssertEqual(rule.longContextThresholdTokens, 272_000)
        XCTAssertEqual(rule.longContextInputMultiplierPpm, 2_000_000)
        XCTAssertEqual(rule.longContextOutputMultiplierPpm, 1_500_000)

        let result = PricingEvaluator.evaluate(
            modelCanonical: "gpt-5.6-sol",
            serviceTier: nil,
            timestampMs: BundledPricingCatalog.publishedAtMs,
            tokens: TokenBreakdown(inputTokens: 300_000, outputTokens: 100_000)
        )
        XCTAssertEqual(result.pricingStatus, .priced)
        XCTAssertEqual(result.estimatedCost.rawValue, 5_400_000_000)

        let cacheWrite = PricingEvaluator.evaluate(
            modelCanonical: "gpt-5.6-sol",
            serviceTier: nil,
            timestampMs: BundledPricingCatalog.publishedAtMs,
            tokens: TokenBreakdown(
                inputTokens: 1_000,
                cachedInputTokens: 200,
                cacheWriteInputTokens: 300,
                outputTokens: 400
            )
        )
        XCTAssertEqual(cacheWrite.pricingStatus, .priced)
        XCTAssertEqual(cacheWrite.estimatedCost.rawValue, 11_580_000)

        let boundary = PricingEvaluator.evaluate(
            modelCanonical: "gpt-5.6-terra",
            serviceTier: nil,
            timestampMs: BundledPricingCatalog.publishedAtMs,
            tokens: TokenBreakdown(inputTokens: 272_000, outputTokens: 1)
        )
        let justLong = PricingEvaluator.evaluate(
            modelCanonical: "gpt-5.6-terra",
            serviceTier: nil,
            timestampMs: BundledPricingCatalog.publishedAtMs,
            tokens: TokenBreakdown(inputTokens: 272_001, outputTokens: 1)
        )
        XCTAssertEqual(boundary.estimatedCost.rawValue, 544_012_000)
        XCTAssertEqual(justLong.estimatedCost.rawValue, 1_088_022_000)
    }

    func testUnknownModelAndUnsupportedTierAreNeverSilentlyPriced() {
        let tokens = TokenBreakdown(inputTokens: 100, outputTokens: 50)
        let unknown = PricingEvaluator.evaluate(
            modelCanonical: "unknown",
            serviceTier: nil,
            timestampMs: BundledPricingCatalog.publishedAtMs,
            tokens: tokens
        )
        let unsupported = PricingEvaluator.evaluate(
            modelCanonical: "gpt-5.6-sol",
            serviceTier: "ultrafast",
            timestampMs: BundledPricingCatalog.publishedAtMs,
            tokens: tokens
        )
        XCTAssertEqual(unknown.pricingStatus, .unpricedUnknownModel)
        XCTAssertEqual(unknown.estimatedCost, .zero)
        XCTAssertEqual(unsupported.pricingStatus, .unpricedUnsupportedServiceMode)
        XCTAssertEqual(unsupported.estimatedCost, .zero)
    }

    func testServiceTierPricingAndGenericGPT56AliasPolicy() {
        let tokens = TokenBreakdown(inputTokens: 100_000)
        let standard = PricingEvaluator.evaluate(
            modelCanonical: "gpt-5.6-sol",
            serviceTier: nil,
            timestampMs: BundledPricingCatalog.publishedAtMs,
            tokens: tokens
        )
        let flex = PricingEvaluator.evaluate(
            modelCanonical: "gpt-5.6-sol",
            serviceTier: "flex",
            timestampMs: BundledPricingCatalog.publishedAtMs,
            tokens: tokens
        )
        let fast = PricingEvaluator.evaluate(
            modelCanonical: "gpt-5.6-sol",
            serviceTier: "fast",
            timestampMs: BundledPricingCatalog.publishedAtMs,
            tokens: tokens
        )
        let priority = PricingEvaluator.evaluate(
            modelCanonical: "gpt-5.6-sol",
            serviceTier: "priority",
            timestampMs: BundledPricingCatalog.publishedAtMs,
            tokens: tokens
        )
        let generic = PricingEvaluator.evaluate(
            modelCanonical: "gpt-5.6",
            serviceTier: nil,
            timestampMs: BundledPricingCatalog.publishedAtMs,
            tokens: tokens
        )
        XCTAssertEqual(standard.estimatedCost.rawValue, 400_000_000)
        XCTAssertEqual(flex.estimatedCost.rawValue, 200_000_000)
        XCTAssertEqual(fast.estimatedCost.rawValue, 800_000_000)
        XCTAssertEqual(priority.estimatedCost.rawValue, fast.estimatedCost.rawValue)
        XCTAssertEqual(generic.pricingStatus, .unpricedUnknownModel)
        XCTAssertEqual(ModelAliasResolver.resolve(rawModel: "gpt-5.6"), "gpt-5.6")
    }

    func testPublishedFlexAndFastRowsCoverOlderSupportedModelsExactly() {
        let tokens = TokenBreakdown(inputTokens: 100_000)
        let cases: [(model: String, tier: String, expected: Int64)] = [
            ("gpt-5.5", "flex", 250_000_000),
            ("gpt-5.5", "fast", 1_250_000_000),
            ("gpt-5.4", "flex", 125_000_000),
            ("gpt-5.4", "fast", 500_000_000),
            ("gpt-5.4-mini", "flex", 37_500_000),
            ("gpt-5.4-mini", "fast", 150_000_000),
            ("gpt-5.4-nano", "flex", 10_000_000),
            ("gpt-5.3-codex", "fast", 350_000_000),
            ("gpt-5.2", "flex", 87_500_000),
            ("gpt-5.2", "fast", 350_000_000),
            ("gpt-5", "flex", 62_500_000),
            ("gpt-5", "fast", 250_000_000)
        ]
        for item in cases {
            let result = PricingEvaluator.evaluate(
                modelCanonical: item.model,
                serviceTier: item.tier,
                timestampMs: BundledPricingCatalog.publishedAtMs,
                tokens: tokens
            )
            XCTAssertEqual(result.pricingStatus, .priced, "\(item.model) \(item.tier)")
            XCTAssertEqual(result.estimatedCost.rawValue, item.expected, "\(item.model) \(item.tier)")
        }

        let fractionalCachedRate = PricingEvaluator.evaluate(
            modelCanonical: "gpt-5.4-mini",
            serviceTier: "flex",
            timestampMs: BundledPricingCatalog.publishedAtMs,
            tokens: TokenBreakdown(inputTokens: 100_000, cachedInputTokens: 100_000)
        )
        XCTAssertEqual(fractionalCachedRate.estimatedCost.rawValue, 3_750_000)

        let unsupportedFastLongContext = PricingEvaluator.evaluate(
            modelCanonical: "gpt-5.5",
            serviceTier: "fast",
            timestampMs: BundledPricingCatalog.publishedAtMs,
            tokens: TokenBreakdown(inputTokens: 272_001)
        )
        XCTAssertEqual(unsupportedFastLongContext.pricingStatus, .unpricedUnsupportedContextLength)
        XCTAssertEqual(unsupportedFastLongContext.estimatedCost, .zero)

        let supportedFlexLongContext = PricingEvaluator.evaluate(
            modelCanonical: "gpt-5.5",
            serviceTier: "flex",
            timestampMs: BundledPricingCatalog.publishedAtMs,
            tokens: TokenBreakdown(inputTokens: 272_001)
        )
        XCTAssertEqual(supportedFlexLongContext.pricingStatus, .priced)
        XCTAssertEqual(supportedFlexLongContext.estimatedCost.rawValue, 1_360_005_000)

        let unsupportedTier = PricingEvaluator.evaluate(
            modelCanonical: "gpt-5.4-nano",
            serviceTier: "fast",
            timestampMs: BundledPricingCatalog.publishedAtMs,
            tokens: tokens
        )
        XCTAssertEqual(unsupportedTier.pricingStatus, .unpricedUnsupportedServiceMode)
    }

    func testInstalledCatalogPreservesFractionalNanoUsdRates() throws {
        let directory = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: directory)
        try PricingCatalogService.shared.ensureCatalogInstalled(database: database)
        let snapshot = try PricingCatalogService.shared.loadSnapshot(database: database)

        let result = snapshot.evaluate(
            modelCanonical: "gpt-5.4-mini",
            serviceTier: "flex",
            timestampMs: BundledPricingCatalog.publishedAtMs,
            tokens: TokenBreakdown(inputTokens: 100_000, cachedInputTokens: 100_000)
        )
        XCTAssertEqual(result.pricingStatus, .priced)
        XCTAssertEqual(result.estimatedCost.rawValue, 3_750_000)
    }

    func testHistoricalGPT56CutoversUseEventTime() {
        let tokenCount: Int64 = 100_000
        let beforeTerraCutover: Int64 = 1_785_369_599_999
        let terraCutover: Int64 = 1_785_369_600_000
        let beforeSolCutover: Int64 = 1_787_270_399_999
        let solCutover: Int64 = 1_787_270_400_000

        XCTAssertEqual(PricingEvaluator.evaluate(
            modelCanonical: "gpt-5.6-terra",
            serviceTier: nil,
            timestampMs: beforeTerraCutover,
            tokens: TokenBreakdown(inputTokens: tokenCount)
        ).estimatedCost.rawValue, 250_000_000)
        XCTAssertEqual(PricingEvaluator.evaluate(
            modelCanonical: "gpt-5.6-terra",
            serviceTier: nil,
            timestampMs: terraCutover,
            tokens: TokenBreakdown(inputTokens: tokenCount)
        ).estimatedCost.rawValue, 200_000_000)
        XCTAssertEqual(PricingEvaluator.evaluate(
            modelCanonical: "gpt-5.6-terra",
            serviceTier: "flex",
            timestampMs: beforeTerraCutover,
            tokens: TokenBreakdown(inputTokens: tokenCount)
        ).estimatedCost.rawValue, 125_000_000)
        XCTAssertEqual(PricingEvaluator.evaluate(
            modelCanonical: "gpt-5.6-terra",
            serviceTier: "priority",
            timestampMs: beforeTerraCutover,
            tokens: TokenBreakdown(inputTokens: tokenCount)
        ).estimatedCost.rawValue, 500_000_000)
        XCTAssertEqual(PricingEvaluator.evaluate(
            modelCanonical: "gpt-5.6-sol",
            serviceTier: nil,
            timestampMs: beforeSolCutover,
            tokens: TokenBreakdown(inputTokens: tokenCount)
        ).estimatedCost.rawValue, 500_000_000)
        XCTAssertEqual(PricingEvaluator.evaluate(
            modelCanonical: "gpt-5.6-sol",
            serviceTier: nil,
            timestampMs: solCutover,
            tokens: TokenBreakdown(inputTokens: tokenCount)
        ).estimatedCost.rawValue, 400_000_000)
        XCTAssertEqual(PricingEvaluator.evaluate(
            modelCanonical: "gpt-5.6-sol",
            serviceTier: "flex",
            timestampMs: beforeSolCutover,
            tokens: TokenBreakdown(inputTokens: tokenCount)
        ).estimatedCost.rawValue, 250_000_000)
        XCTAssertEqual(PricingEvaluator.evaluate(
            modelCanonical: "gpt-5.6-sol",
            serviceTier: "fast",
            timestampMs: beforeSolCutover,
            tokens: TokenBreakdown(inputTokens: tokenCount)
        ).estimatedCost.rawValue, 1_000_000_000)
    }

    func testInstalledCatalogStoresVerifiableRawJSONAndSourceURLs() throws {
        let directory = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: directory)
        try PricingCatalogService.shared.ensureCatalogInstalled(database: database)

        let row = try XCTUnwrap(database.executeQuery(
            sql: "SELECT raw_json, catalog_sha256 FROM codex_pricing_catalogs WHERE catalog_version = ?;",
            bindings: [BundledPricingCatalog.currentVersion]
        ) { statement in
            (String(cString: sqlite3_column_text(statement, 0)), String(cString: sqlite3_column_text(statement, 1)))
        }.first)
        let digest = SHA256.hash(data: Data(row.0.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(row.1, digest)
        let decoded = try JSONDecoder().decode(PricingCatalogModel.self, from: Data(row.0.utf8))
        XCTAssertTrue(decoded.sourceURLs.contains("https://developers.openai.com/api/docs/models/gpt-5.6-sol"))
        XCTAssertNotEqual(row.0, "{}")
    }

    func testCatalogRowsAreVersionScopedAndActiveSnapshotIsIsolated() throws {
        let directory = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: directory)
        try PricingCatalogService.shared.ensureCatalogInstalled(database: database)

        try database.executeUpdate(
            sql: "INSERT INTO codex_pricing_catalogs VALUES ('legacy-test', 1, 1, 'legacy', 0, '{}');",
            bindings: []
        )
        try database.executeUpdate(
            sql: "INSERT INTO codex_model_aliases VALUES ('gpt-5.6-sol', 'wrong-model', 'exact', 'legacy-test');",
            bindings: []
        )
        try database.executeUpdate(
            sql: """
            INSERT INTO codex_pricing_rules (
                rule_id, model_key, service_tier, effective_from_ms, effective_to_ms,
                input_usd_nano_per_token, cached_usd_nano_per_token,
                cache_write_usd_nano_per_token, output_usd_nano_per_token,
                long_context_threshold_tokens, long_context_input_multiplier_ppm,
                long_context_output_multiplier_ppm, catalog_version
            ) VALUES ('gpt-5.6-sol-std-v3', 'wrong-model', NULL, 0, NULL, 1, 1, NULL, 1, NULL, NULL, NULL, 'legacy-test');
            """,
            bindings: []
        )

        let snapshot = try PricingCatalogService.shared.loadSnapshot(database: database)
        let result = snapshot.evaluate(
            modelCanonical: "gpt-5.6-sol",
            serviceTier: nil,
            timestampMs: BundledPricingCatalog.publishedAtMs,
            tokens: TokenBreakdown(inputTokens: 100_000)
        )
        XCTAssertEqual(snapshot.catalogVersion, BundledPricingCatalog.currentVersion)
        XCTAssertEqual(result.estimatedCost.rawValue, 400_000_000)
        XCTAssertEqual(try database.intScalar(
            sql: "SELECT COUNT(*) FROM codex_model_aliases WHERE alias_pattern = 'gpt-5.6-sol';"
        ), 2)
    }

    func testSameVersionDigestMismatchIsAtomicallyRepaired() throws {
        let directory = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: directory)
        try database.executeUpdate(
            sql: "INSERT INTO codex_pricing_catalogs VALUES (?, 2, 1, 'bad', 1, '{}');",
            bindings: [BundledPricingCatalog.currentVersion]
        )
        try PricingCatalogService.shared.ensureCatalogInstalled(database: database)
        let raw = try XCTUnwrap(database.stringScalar(
            sql: "SELECT raw_json FROM codex_pricing_catalogs WHERE catalog_version = ?;",
            bindings: [BundledPricingCatalog.currentVersion]
        ))
        XCTAssertTrue(raw.contains("gpt-5.6-sol"))
        XCTAssertGreaterThan(try database.intScalar(
            sql: "SELECT COUNT(*) FROM codex_pricing_rules WHERE catalog_version = ?;",
            bindings: [BundledPricingCatalog.currentVersion]
        ), 0)
    }

    func testExplicitRepriceUsesHistoricalEffectiveDatesAndRebuildsSummaries() throws {
        let directory = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: directory)
        try PricingCatalogService.shared.ensureCatalogInstalled(database: database)
        let beforeTerraCutover: Int64 = 1_785_369_599_999
        let terraCutover: Int64 = 1_785_369_600_000

        try database.executeUpdate(
            sql: """
            INSERT INTO codex_sessions (
                session_id, root_session_id, parent_session_id, depth, source_path,
                relative_path, bucket, title, project_name, cwd, created_at, updated_at,
                last_event_at, event_count, total_tokens, input_tokens, cached_input_tokens,
                cache_write_input_tokens, output_tokens, reasoning_output_tokens,
                estimated_cost_usd_nano, pricing_status, metadata_fingerprint,
                has_subagents, agent_type
            ) VALUES (
                'reprice-session', 'reprice-session', NULL, 0, '/tmp/reprice.jsonl',
                'sessions/reprice.jsonl', 'active', 'Reprice', 'Fixture', '/tmp',
                ?, ?, ?, 0, 0, 0, 0, 0, 0, 0, 1, 'unpricedUnknownModel', NULL, 0, NULL
            );
            """,
            bindings: [beforeTerraCutover, terraCutover, terraCutover]
        )
        for (eventId, timestamp) in [("before", beforeTerraCutover), ("after", terraCutover)] {
            try database.executeUpdate(
                sql: """
                INSERT INTO codex_usage_events (
                    event_id, session_id, root_session_id, turn_index, call_index,
                    timestamp_ms, model_raw, model_canonical, service_tier, reasoning_effort,
                    input_tokens, cached_input_tokens, cache_write_input_tokens,
                    output_tokens, reasoning_output_tokens, total_tokens, uncached_input_tokens,
                    estimated_cost_usd_nano, pricing_rule_id, pricing_status,
                    usage_derivation, attribution_quality, is_child_replay, source_path,
                    line_offset, line_bytes, payload_sha256, created_at, timestamp_quality,
                    pricing_catalog_version
                ) VALUES (?, 'reprice-session', 'reprice-session', 0, 0, ?,
                    'gpt-5.6-terra', 'gpt-5.6-terra', NULL, NULL,
                    100000, 0, 0, 0, 0, 100000, 100000,
                    1, NULL, 'priced', 'explicit_last_usage', 'direct_turn_context',
                    0, '/tmp/reprice.jsonl', ?, 1, NULL, ?, 'event_timestamp', 'legacy-test');
                """,
                bindings: [eventId, timestamp, timestamp, timestamp]
            )
        }

        let beforeGeneration = try database.int64Scalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'pricing_reprice_generation';"
        ) ?? 0
        try PricingCatalogService.shared.repriceAllUsageEvents(database: database)

        let eventCosts = try database.executeQuery(
            sql: "SELECT event_id, estimated_cost_usd_nano, pricing_rule_id, pricing_catalog_version FROM codex_usage_events ORDER BY event_id ASC;"
        ) { stmt in
            (
                String(cString: sqlite3_column_text(stmt, 0)),
                sqlite3_column_int64(stmt, 1),
                String(cString: sqlite3_column_text(stmt, 2)),
                String(cString: sqlite3_column_text(stmt, 3))
            )
        }
        XCTAssertEqual(eventCosts.map { $0.1 }, [200_000_000, 250_000_000])
        XCTAssertEqual(Set(eventCosts.map { $0.3 }), [BundledPricingCatalog.currentVersion])
        XCTAssertTrue(eventCosts.allSatisfy { $0.2.contains("gpt-5.6-terra") })
        XCTAssertEqual(try database.int64Scalar(
            sql: "SELECT estimated_cost_usd_nano FROM codex_sessions WHERE session_id = 'reprice-session';"
        ), 450_000_000)
        XCTAssertEqual(try database.intScalar(
            sql: "SELECT COUNT(*) FROM codex_session_summaries WHERE session_id = 'reprice-session';"
        ), 1)
        XCTAssertEqual(try database.int64Scalar(
            sql: "SELECT SUM(estimated_cost_usd_nano) FROM codex_daily_usage_summaries WHERE session_id = 'reprice-session';"
        ), 450_000_000)
        XCTAssertEqual(try database.int64Scalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'pricing_reprice_generation';"
        ), beforeGeneration + 1)

        let expectedDayStarts = Set([beforeTerraCutover, terraCutover].map { timestamp -> Int64 in
            let date = Date(timeIntervalSince1970: Double(timestamp) / 1_000)
            return Int64((Calendar.current.startOfDay(for: date).timeIntervalSince1970 * 1_000).rounded())
        })
        let rebuiltDayStarts = Set(try database.executeQuery(
            sql: "SELECT day_start_ms FROM codex_daily_usage_summaries WHERE session_id = 'reprice-session';"
        ) { stmt in sqlite3_column_int64(stmt, 0) })
        XCTAssertEqual(rebuiltDayStarts, expectedDayStarts)

        let stableEventCosts = eventCosts.map { $0.1 }
        try PricingCatalogService.shared.repriceAllUsageEvents(database: database)
        let repeatedEventCosts = try database.executeQuery(
            sql: "SELECT estimated_cost_usd_nano FROM codex_usage_events ORDER BY event_id ASC;"
        ) { stmt in sqlite3_column_int64(stmt, 0) }
        XCTAssertEqual(repeatedEventCosts, stableEventCosts)

        try database.executeUpdate(sql: """
        WITH RECURSIVE sequence(value) AS (
            VALUES(1)
            UNION ALL
            SELECT value + 1 FROM sequence WHERE value < 505
        )
        INSERT INTO codex_usage_events (
            event_id, session_id, root_session_id, turn_index, call_index,
            timestamp_ms, model_raw, model_canonical, service_tier, reasoning_effort,
            input_tokens, cached_input_tokens, cache_write_input_tokens,
            output_tokens, reasoning_output_tokens, total_tokens, uncached_input_tokens,
            estimated_cost_usd_nano, pricing_rule_id, pricing_status,
            usage_derivation, attribution_quality, is_child_replay, source_path,
            line_offset, line_bytes, payload_sha256, created_at, timestamp_quality,
            pricing_catalog_version
        )
        SELECT
            printf('batch-%03d', value), 'reprice-session', 'reprice-session', 0, value,
            ?, 'gpt-5.6-terra', 'gpt-5.6-terra', NULL, NULL,
            1, 0, 0, 0, 0, 1, 1,
            0, NULL, 'unpricedUnknownModel', 'explicit_last_usage',
            'direct_turn_context', 0, '/tmp/reprice.jsonl', value,
            1, NULL, ?, 'event_timestamp', 'stale-batch'
        FROM sequence;
        """, bindings: [terraCutover, terraCutover])
        try PricingCatalogService.shared.repriceAllUsageEvents(database: database)
        XCTAssertEqual(try database.intScalar(
            sql: "SELECT COUNT(*) FROM codex_usage_events WHERE pricing_catalog_version != ?;",
            bindings: [BundledPricingCatalog.currentVersion]
        ), 0)
        XCTAssertEqual(try database.intScalar(
            sql: "SELECT COUNT(*) FROM codex_usage_events WHERE event_id LIKE 'batch-%' AND pricing_status = 'priced';"
        ), 505)
        XCTAssertEqual(try database.int64Scalar(
            sql: "SELECT SUM(estimated_cost_usd_nano) FROM codex_usage_events WHERE event_id LIKE 'batch-%';"
        ), 1_010_000)
    }
}
