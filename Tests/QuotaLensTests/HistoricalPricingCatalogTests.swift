import XCTest
@testable import QuotaLens

final class HistoricalPricingCatalogTests: XCTestCase {
    func testGPT61SolReleaseTiersAndLongContext() {
        let release = HistoricalPricingCatalog.day("2026-09-29")
        for (tier, shortCost, longCost) in [(nil as String?, Int64(5_770_000), Int64(990_000_000)),
                                          ("batch", 2_885_000, 495_000_000),
                                          ("flex", 2_885_000, 495_000_000),
                                          ("fast", 11_540_000, 1_980_000_000)] {
            let short = TokenBreakdown(inputTokens: 1_000, cachedInputTokens: 200,
                                       cacheWriteInputTokens: 300, outputTokens: 400)
            let before = PricingEvaluator.evaluate(modelCanonical: "gpt-6.1-sol", serviceTier: tier,
                timestampMs: release - 1, tokens: short)
            XCTAssertEqual(before.pricingStatus, .unpricedHistoricalRuleMissing)
            let current = PricingEvaluator.evaluate(modelCanonical: "gpt-6.1-sol", serviceTier: tier,
                timestampMs: release, tokens: short)
            XCTAssertEqual(current.pricingStatus, .priced)
            XCTAssertEqual(current.estimatedCost.rawValue, shortCost)
            let long = PricingEvaluator.evaluate(modelCanonical: "gpt-6.1-sol", serviceTier: tier,
                timestampMs: release,
                tokens: TokenBreakdown(inputTokens: 300_000, cachedInputTokens: 100_000,
                                       cacheWriteInputTokens: 20_000, outputTokens: 10_000))
            XCTAssertEqual(long.pricingStatus, .priced)
            XCTAssertEqual(long.estimatedCost.rawValue, longCost)
        }
        let old = PricingEvaluator.evaluate(modelCanonical: "gpt-6-sol", serviceTier: nil,
            timestampMs: release, tokens: TokenBreakdown(inputTokens: 1_000, cachedInputTokens: 1_000))
        XCTAssertEqual(old.estimatedCost.rawValue, 200_000)
    }

    func testAstraUltrafastStartsOnSeptember29() {
        let release = HistoricalPricingCatalog.day("2026-09-29")
        let tokens = TokenBreakdown(inputTokens: 300_000, cachedInputTokens: 100_000,
                                   cacheWriteInputTokens: 20_000, outputTokens: 10_000)
        let before = PricingEvaluator.evaluate(modelCanonical: "gpt-6-astra", serviceTier: "ultrafast",
            timestampMs: release - 1, tokens: tokens)
        XCTAssertEqual(before.pricingStatus, .unpricedHistoricalRuleMissing)
        let current = PricingEvaluator.evaluate(modelCanonical: "gpt-6-astra", serviceTier: "ultrafast",
            timestampMs: release, tokens: tokens)
        XCTAssertEqual(current.pricingStatus, .priced)
        XCTAssertEqual(current.estimatedCost.rawValue, 30_300_000_000)
    }

    func testSonnet55ReleaseCacheDurationsAndAlias() {
        let release = HistoricalPricingCatalog.day("2026-09-28")
        for model in ["claude-sonnet-5-5", "claude-sonnet-5.5"] {
            let before = ClaudePricingCatalogService.evaluate(modelRaw: model,
                uncachedInput: 1_000, cachedInput: 200, cacheWrite5m: 300, cacheWrite1h: 400,
                output: 500, timestampMs: release - 1)
            XCTAssertEqual(before.status, .unpricedHistoricalRuleMissing)
            let current = ClaudePricingCatalogService.evaluate(modelRaw: model,
                uncachedInput: 1_000, cachedInput: 200, cacheWrite5m: 300, cacheWrite1h: 400,
                output: 500, timestampMs: release)
            XCTAssertEqual(current.status, .priced)
            XCTAssertEqual(current.cost.rawValue, 9_390_000)
            XCTAssertEqual(AntigravityPricingCatalog.resolveModel(rawModel: model, displayName: nil), "claude-sonnet-5-5")
        }
        XCTAssertNil(ClaudeBundledPricingCatalog.resolveModel("claude-sonnet-5-5-private"))
    }

    func testLatestGeminiReferencesRetainUnitsAndPromotionalDates() throws {
        let models = ["gemini-nano-banana-2.1", "gemini-3.8-live", "gemini-3.8-live-extended-thinking",
                      "gemini-3.8-flash-tts", "gemini-3.8-flash-lite-tts"]
        for model in models {
            let entry = try XCTUnwrap(ModelPriceReferenceCatalog.entries.first { $0.modelID == model })
            XCTAssertFalse(entry.rates.isEmpty)
            XCTAssertTrue(entry.rates.allSatisfy { $0.unit == "millionTokens" })
            let automatic = AntigravityPricingCatalog.evaluate(modelCanonical: model,
                timestampMs: HistoricalPricingCatalog.day("2026-10-07"),
                tokens: TokenBreakdown(inputTokens: 1_000, outputTokens: 1_000))
            XCTAssertEqual(automatic.pricingStatus, .unpricedUnknownModel)
        }
        let image = try XCTUnwrap(ModelPriceReferenceCatalog.entries.first { $0.modelID == models[0] })
        XCTAssertEqual(image.rates.first { $0.metric == "output_image" }?.usd, "30.00")
        for (model, rates) in [(models[3], ["9.00", "18.00"]), (models[4], ["6.00", "12.00"])] {
            let entry = try XCTUnwrap(ModelPriceReferenceCatalog.entries.first { $0.modelID == model })
            let output = entry.rates.filter { $0.metric == "output_audio" }
            XCTAssertEqual(output.map(\.usd), rates)
            XCTAssertEqual(output.map(\.condition), ["2026-09-22 – 2026-12-31", "≥ 2027-01-01"])
        }
    }

    func testCatalogModelIDsAliasesAndRuleIDsAreUnique() {
        for entries in [BundledPricingCatalog.defaultCatalog.models, AntigravityPricingCatalog.geminiModels] {
            XCTAssertEqual(Set(entries.map(\.modelKey)).count, entries.count)
            let aliases = entries.flatMap(\.aliases)
            XCTAssertEqual(Set(aliases).count, aliases.count)
            let rules = entries.flatMap(\.rules)
            XCTAssertEqual(Set(rules.map(\.ruleId)).count, rules.count)
            for rule in rules {
                XCTAssertGreaterThan(rule.rateDivisor, 0)
                if let end = rule.effectiveToMs { XCTAssertGreaterThan(end, rule.effectiveFromMs) }
            }
            for entry in entries {
                let tiers = Dictionary(grouping: entry.rules, by: { $0.serviceTier ?? "standard" })
                for rules in tiers.values {
                    let sorted = rules.sorted { $0.effectiveFromMs < $1.effectiveFromMs }
                    for index in sorted.indices.dropFirst() {
                        XCTAssertLessThanOrEqual(sorted[index - 1].effectiveToMs ?? .max, sorted[index].effectiveFromMs, entry.modelKey)
                    }
                }
            }
        }
        let aliases = ClaudeBundledPricingCatalog.entries.flatMap(\.aliases)
        XCTAssertEqual(Set(aliases).count, aliases.count)
    }

    func testNewOpenAIStandardRatesAndDateSnapshots() {
        let fixtures: [(String, Int64)] = [
            ("o3-mini", 5_500_000), ("gpt-4.5-preview", 225_000_000),
            ("gpt-4.1-2025-04-14", 10_000_000), ("gpt-4.1-mini", 2_000_000),
            ("gpt-4.1-nano", 500_000), ("o1-pro", 750_000_000),
            ("o3", 10_000_000), ("o4-mini", 5_500_000), ("codex-mini-latest", 7_500_000),
            ("o3-pro", 100_000_000), ("o3-deep-research", 50_000_000), ("o4-mini-deep-research", 10_000_000),
            ("gpt-5-mini", 2_250_000), ("gpt-5-nano", 450_000), ("gpt-5-pro", 135_000_000),
            ("gpt-5.1", 11_250_000), ("gpt-5.2-pro", 189_000_000),
            ("gpt-5.4-pro", 210_000_000), ("gpt-5.5-pro", 210_000_000),
            ("gpt-5.3-chat-latest", 15_750_000)
        ]
        for (model, expected) in fixtures {
            let price = PricingEvaluator.evaluate(modelCanonical: model, serviceTier: nil,
                timestampMs: HistoricalPricingCatalog.day("2026-09-07"),
                tokens: TokenBreakdown(inputTokens: 1_000, outputTokens: 1_000))
            XCTAssertEqual(price.pricingStatus, .priced, model)
            XCTAssertEqual(price.estimatedCost.rawValue, expected, model)
        }
    }

    func testNewModelsAreNotBackdatedAndUnavailableCacheIsNotFree() {
        let early = PricingEvaluator.evaluate(modelCanonical: "gpt-4.1", serviceTier: nil,
            timestampMs: HistoricalPricingCatalog.day("2025-04-13"), tokens: TokenBreakdown(inputTokens: 10))
        XCTAssertEqual(early.pricingStatus, .unpricedHistoricalRuleMissing)
        let unknownHistoricalO3 = PricingEvaluator.evaluate(modelCanonical: "o3", serviceTier: nil,
            timestampMs: HistoricalPricingCatalog.day("2025-05-01"), tokens: TokenBreakdown(inputTokens: 10))
        XCTAssertEqual(unknownHistoricalO3.pricingStatus, .unpricedHistoricalRuleMissing)
        let unsupportedCache = PricingEvaluator.evaluate(modelCanonical: "gpt-5-pro", serviceTier: nil,
            timestampMs: HistoricalPricingCatalog.day("2026-09-07"), tokens: TokenBreakdown(inputTokens: 100, cachedInputTokens: 100))
        XCTAssertEqual(unsupportedCache.pricingStatus, .unpricedHistoricalRuleMissing)
        let noFastRule = PricingEvaluator.evaluate(modelCanonical: "gpt-4.1", serviceTier: "fast",
            timestampMs: HistoricalPricingCatalog.day("2025-04-14"), tokens: TokenBreakdown(inputTokens: 100))
        XCTAssertEqual(noFastRule.pricingStatus, .unpricedHistoricalRuleMissing)
    }

    func testExactModelIdentityDoesNotGuessVersions() {
        for name in ["gpt-5.6-sol-private", "my-sol-model", "gpt-5.5-codex", "claude-fable-5-99"] {
            XCTAssertEqual(ModelAliasResolver.resolve(rawModel: name), name)
        }
        XCTAssertNil(ClaudeBundledPricingCatalog.resolveModel("claude-fable-5-99"))
        XCTAssertNil(ClaudeBundledPricingCatalog.resolveModel("claude-opus-4-6-20990101"))
        XCTAssertEqual(ClaudeBundledPricingCatalog.resolveModel("claude-opus-4.5"), "claude-opus-4-5-20251101")
        XCTAssertEqual(ClaudeBundledPricingCatalog.resolveModel("claude-3-7-sonnet-20250219"), "claude-3-7-sonnet-20250219")
    }

    func testClaudeReleaseDateIsNotSnapshotSuffix() {
        let before = claude("claude-opus-4-5-20251101", date: "2025-11-23", input: 100)
        let released = claude("claude-opus-4-5-20251101", date: "2025-11-24", input: 100)
        XCTAssertEqual(before.status, .unpricedHistoricalRuleMissing)
        XCTAssertEqual(released.status, .priced)
        XCTAssertEqual(released.cost.rawValue, 500_000)
        XCTAssertEqual(claude("claude-3-7-sonnet-20250219", date: "2025-02-23", input: 1).status, .unpricedHistoricalRuleMissing)
        XCTAssertEqual(claude("claude-3-7-sonnet-20250219", date: "2025-02-24", input: 1).status, .priced)
    }

    func testClaudeLongContextPremiumEndsOnOfficialDate() {
        XCTAssertEqual(claude("claude-opus-4-6", date: "2026-03-12", input: 300_000, output: 1_000).cost.rawValue, 3_037_500_000)
        XCTAssertEqual(claude("claude-opus-4-6", date: "2026-03-13", input: 300_000, output: 1_000).cost.rawValue, 1_525_000_000)
        XCTAssertEqual(claude("claude-sonnet-4-5", date: "2026-04-29", input: 300_000).cost.rawValue, 1_800_000_000)
        XCTAssertEqual(claude("claude-sonnet-4-5", date: "2026-04-30", input: 300_000).status, .unpricedUnsupportedContextLength)
        let boundary = claude("claude-sonnet-4-5", date: "2026-04-30", input: 200_000)
        XCTAssertEqual(boundary.status, .priced)
        XCTAssertEqual(boundary.cost.rawValue, 600_000_000)
    }

    func testGeminiModelRatesAndLatestReleaseBoundary() {
        let fixtures: [(String, Int64)] = [
            ("gemini-2.0-flash", 500_000), ("gemini-2.0-flash-lite", 375_000),
            ("gemini-2.5-pro", 11_250_000), ("gemini-2.5-flash", 2_800_000),
            ("gemini-2.5-flash-lite", 500_000), ("gemini-3-flash-preview", 3_500_000),
            ("gemini-3.1-flash-lite", 1_750_000), ("gemini-3.5-flash-lite", 2_800_000),
            ("gemini-3.8-flash", 4_500_000)
        ]
        for (model, expected) in fixtures {
            let price = AntigravityPricingCatalog.evaluate(modelCanonical: model,
                timestampMs: HistoricalPricingCatalog.day("2026-09-07"),
                tokens: TokenBreakdown(inputTokens: 1_000, outputTokens: 1_000))
            XCTAssertEqual(price.pricingStatus, .priced, model)
            XCTAssertEqual(price.estimatedCost.rawValue, expected, model)
        }
        let early = AntigravityPricingCatalog.evaluate(modelCanonical: "gemini-3.8-flash",
            timestampMs: HistoricalPricingCatalog.day("2026-09-01"), tokens: TokenBreakdown(inputTokens: 1))
        XCTAssertEqual(early.pricingStatus, .unpricedHistoricalRuleMissing)
    }

    func testUnverifiedGeminiHistoricalCacheDoesNotUseCurrentDiscount() {
        let tokens = TokenBreakdown(inputTokens: 1000, cachedInputTokens: 800)
        let before = AntigravityPricingCatalog.evaluate(modelCanonical: "gemini-2.5-pro",
            timestampMs: HistoricalPricingCatalog.day("2025-07-01"), tokens: tokens)
        XCTAssertEqual(before.pricingStatus, .unpricedHistoricalRuleMissing)
        let current = AntigravityPricingCatalog.evaluate(modelCanonical: "gemini-2.5-pro",
            timestampMs: HistoricalPricingCatalog.day("2026-09-07"), tokens: tokens)
        XCTAssertEqual(current.estimatedCost.rawValue, 350_000)
    }

    func testReferenceUnitsAndModelsNeverEnterConversationPricing() {
        let refs = ModelPriceReferenceCatalog.entries
        XCTAssertEqual(Set(refs.map(\.id)).count, refs.count)
        let units = Set(refs.flatMap(\.rates).map(\.unit))
        XCTAssertTrue(units.isSuperset(of: ["millionTokens", "millionCharacters", "second", "minute", "song"]))
        for ref in refs {
            XCTAssertTrue(ref.sourceURL.hasPrefix("https://"))
            for rate in ref.rates {
                XCTAssertNotNil(Decimal(string: rate.usd, locale: Locale(identifier: "en_US_POSIX")))
            }
            guard ref.category != "text" else { continue }
            let price = PricingEvaluator.evaluate(modelCanonical: ref.modelID, serviceTier: nil,
                timestampMs: HistoricalPricingCatalog.day("2026-09-07"), tokens: TokenBreakdown(inputTokens: 100, outputTokens: 100))
            XCTAssertFalse(price.pricingStatus.isPriced, ref.modelID)
            let google = AntigravityPricingCatalog.evaluate(modelCanonical: ref.modelID,
                timestampMs: HistoricalPricingCatalog.day("2026-09-07"), tokens: TokenBreakdown(inputTokens: 100, outputTokens: 100))
            XCTAssertFalse(google.pricingStatus.isPriced, ref.modelID)
        }
        print("PRICE_CATALOG openai=\(BundledPricingCatalog.defaultCatalog.models.count) claude=\(ClaudeBundledPricingCatalog.entries.count) gemini=\(AntigravityPricingCatalog.geminiModels.count) reference=\(refs.filter { !$0.rates.isEmpty }.count) unverified=\(refs.filter { $0.rates.isEmpty }.count)")
    }

    func testCatalogUpgradeRepricesExistingGPT41WithoutRereadingLog() async throws {
        let directory = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: directory)
        let paths = CodexHistoryPaths(rootURL: directory)
        try overwriteFile(paths.sessionsURL.appendingPathComponent("rollout-test.jsonl"),
            with: rolloutText(sessionId: "test", model: "gpt-4.1", input: 10, output: 5))
        let importer = CodexUsageImportActor(database: database)
        _ = try await importer.importCodexHistory(paths: paths)
        try database.execute(sql: "UPDATE codex_usage_events SET pricing_catalog_version = 'old', estimated_cost_usd_nano = 0;")
        let result = try await importer.importCodexHistory(paths: paths)
        XCTAssertEqual(result.bytesRead, 0)
        XCTAssertEqual(try database.int64Scalar(sql: "SELECT estimated_cost_usd_nano FROM codex_usage_events;"), 60_000)
    }

    private func claude(_ model: String, date: String, input: Int64, output: Int64 = 0) -> ClaudePricingEvaluation {
        ClaudePricingCatalogService.evaluate(modelRaw: model, uncachedInput: input, cachedInput: 0,
            cacheWrite5m: 0, cacheWrite1h: 0, output: output, timestampMs: HistoricalPricingCatalog.day(date))
    }

    func testClaudeHistoricalPriceGapIsNotReportedAsUnknownModel() async throws {
        let root = try makeTemporaryDirectory()
        let database = try makeMigratedDatabase(in: root)
        let logs = root.appendingPathComponent("projects")
        try overwriteFile(logs.appendingPathComponent("session.jsonl"), with: """
        {"type":"assistant","sessionId":"session","timestamp":"2025-11-01T12:00:00Z","message":{"id":"msg1","model":"claude-opus-4-5-20251101","usage":{"input_tokens":10,"output_tokens":5}}}

        """)
        let importer = ClaudeUsageImportActor(database: database, roots: [logs])
        _ = try await importer.scan()
        XCTAssertEqual(try database.stringScalar(sql: "SELECT pricing_status FROM codex_usage_events;"), PricingStatus.unpricedHistoricalRuleMissing.rawValue)
        for table in ["codex_session_summaries", "codex_daily_usage_summaries"] {
            XCTAssertEqual(try database.intScalar(sql: "SELECT unpriced_unknown_model_event_count FROM \(table);"), 0)
            XCTAssertEqual(try database.intScalar(sql: "SELECT unpriced_historical_rule_missing_event_count FROM \(table);"), 1)
        }
    }

    func testPriceCatalogLabelsCoverAllSupportedLanguages() {
        for key in ["Model Price Catalog", "Search models or aliases", "Used for estimates", "Unverified",
                    "Reference only", "Approximate estimate", "million characters", "minute", "second", "song"] {
            for language in AppLanguage.allCases where language != .english && language != .simplifiedChinese {
                XCTAssertNotNil(extendedTranslations[key]?[language], "\(key): \(language)")
            }
        }
    }
}
