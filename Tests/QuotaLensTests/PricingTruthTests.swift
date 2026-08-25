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
        for (model, inputRate, cachedRate, outputRate) in rates {
            let input = snapshot.evaluate(
                modelCanonical: model,
                serviceTier: nil,
                timestampMs: 1,
                tokens: TokenBreakdown(inputTokens: goldenTokenCount)
            )
            let cached = snapshot.evaluate(
                modelCanonical: model,
                serviceTier: nil,
                timestampMs: 1,
                tokens: TokenBreakdown(inputTokens: goldenTokenCount, cachedInputTokens: goldenTokenCount)
            )
            let output = snapshot.evaluate(
                modelCanonical: model,
                serviceTier: nil,
                timestampMs: 1,
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
        let rule = try XCTUnwrap(model.rules.first)
        XCTAssertEqual(rule.cacheWriteNanoUsdPerToken, 5_000)
        XCTAssertEqual(rule.longContextThresholdTokens, 272_000)
        XCTAssertEqual(rule.longContextInputMultiplierPpm, 2_000_000)
        XCTAssertEqual(rule.longContextOutputMultiplierPpm, 1_500_000)

        let result = PricingEvaluator.evaluate(
            modelCanonical: "gpt-5.6-sol",
            serviceTier: nil,
            timestampMs: 1,
            tokens: TokenBreakdown(inputTokens: 300_000, outputTokens: 100_000)
        )
        XCTAssertEqual(result.pricingStatus, .priced)
        XCTAssertEqual(result.estimatedCost.rawValue, 5_400_000_000)
    }

    func testUnknownModelAndUnsupportedTierAreNeverSilentlyPriced() {
        let tokens = TokenBreakdown(inputTokens: 100, outputTokens: 50)
        let unknown = PricingEvaluator.evaluate(
            modelCanonical: "unknown",
            serviceTier: nil,
            timestampMs: 1,
            tokens: tokens
        )
        let unsupported = PricingEvaluator.evaluate(
            modelCanonical: "gpt-5.6-sol",
            serviceTier: "priority",
            timestampMs: 1,
            tokens: tokens
        )
        XCTAssertEqual(unknown.pricingStatus, .unpricedUnknownModel)
        XCTAssertEqual(unknown.estimatedCost, .zero)
        XCTAssertEqual(unsupported.pricingStatus, .unpricedUnsupportedServiceMode)
        XCTAssertEqual(unsupported.estimatedCost, .zero)
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
            timestampMs: 1,
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
}
