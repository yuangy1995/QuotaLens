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
            ("gpt-5.2", 1_750, 175, 14_000),
            ("gpt-5.2-codex", 1_750, 175, 14_000),
            ("gpt-5.1-codex", 1_250, 125, 10_000),
            ("gpt-5.1-codex-max", 1_250, 125, 10_000),
            ("gpt-5.1-codex-mini", 250, 25, 2_000),
            ("gpt-5", 1_250, 125, 10_000),
            ("gpt-5-codex", 1_250, 125, 10_000)
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

    func testOlderModelCacheWriteMatchesScaledInputRateAcrossTiers() {
        let shortTokens: Int64 = 100_000
        let cases: [(model: String, tier: String?, tokens: TokenBreakdown, expected: Int64, status: PricingStatus)] = [
            ("gpt-5.5", nil, TokenBreakdown(cacheWriteInputTokens: shortTokens), 500_000_000, .priced),
            ("gpt-5.5", "flex", TokenBreakdown(cacheWriteInputTokens: shortTokens), 250_000_000, .priced),
            ("gpt-5.5", "fast", TokenBreakdown(cacheWriteInputTokens: shortTokens), 1_250_000_000, .priced),
            ("gpt-5.4", nil, TokenBreakdown(cacheWriteInputTokens: shortTokens), 250_000_000, .priced),
            ("gpt-5.4-mini", "flex", TokenBreakdown(cacheWriteInputTokens: shortTokens), 37_500_000, .priced),
            ("gpt-5.3-codex", "fast", TokenBreakdown(cacheWriteInputTokens: shortTokens), 350_000_000, .priced),
            ("gpt-5.2-codex", "flex", TokenBreakdown(cacheWriteInputTokens: shortTokens), 87_500_000, .priced),
            ("gpt-5-codex", "fast", TokenBreakdown(cacheWriteInputTokens: shortTokens), 250_000_000, .priced),
            ("gpt-5.5", "flex", TokenBreakdown(cacheWriteInputTokens: 272_001), 1_360_005_000, .priced),
            ("gpt-5.5", "fast", TokenBreakdown(cacheWriteInputTokens: 272_001), 0, .unpricedUnsupportedContextLength)
        ]

        for item in cases {
            let result = PricingEvaluator.evaluate(
                modelCanonical: item.model,
                serviceTier: item.tier,
                timestampMs: BundledPricingCatalog.publishedAtMs,
                tokens: item.tokens
            )
            XCTAssertEqual(result.pricingStatus, item.status, "\(item.model) \(String(describing: item.tier))")
            XCTAssertEqual(result.estimatedCost.rawValue, item.expected, "\(item.model) \(String(describing: item.tier))")
        }
    }

    func testOlderModelEffectiveDatesUseOfficialUTCDayBoundaries() {
        let token = TokenBreakdown(inputTokens: 1_000)
        let cases: [(model: String, releaseMs: Int64)] = [
            ("gpt-5", 1_754_524_800_000),
            ("gpt-5-codex", 1_757_894_400_000),
            ("gpt-5.1-codex", 1_762_992_000_000),
            ("gpt-5.1-codex-max", 1_763_424_000_000),
            ("gpt-5.1-codex-mini", 1_762_992_000_000),
            ("gpt-5.2", 1_765_411_200_000),
            ("gpt-5.2-codex", 1_768_348_800_000),
            ("gpt-5.3-codex", 1_771_891_200_000),
            ("gpt-5.4", 1_772_668_800_000),
            ("gpt-5.4-mini", 1_773_705_600_000),
            ("gpt-5.4-nano", 1_773_705_600_000),
            ("gpt-5.5", 1_776_988_800_000)
        ]

        for item in cases {
            let before = PricingEvaluator.evaluate(
                modelCanonical: item.model,
                serviceTier: nil,
                timestampMs: item.releaseMs - 1,
                tokens: token
            )
            let atRelease = PricingEvaluator.evaluate(
                modelCanonical: item.model,
                serviceTier: nil,
                timestampMs: item.releaseMs,
                tokens: token
            )
            XCTAssertEqual(before.pricingStatus, .unpricedHistoricalRuleMissing, item.model)
            XCTAssertEqual(atRelease.pricingStatus, .priced, item.model)
        }

        XCTAssertEqual(PricingEvaluator.evaluate(
            modelCanonical: "gpt-5-codex",
            serviceTier: nil,
            timestampMs: 1_754_524_800_000,
            tokens: token
        ).pricingStatus, .unpricedHistoricalRuleMissing)
        XCTAssertEqual(PricingEvaluator.evaluate(
            modelCanonical: "gpt-5.2-codex",
            serviceTier: nil,
            timestampMs: 1_765_411_200_000,
            tokens: token
        ).pricingStatus, .unpricedHistoricalRuleMissing)
    }

    func testV5GoldenMatrixCoversBundledModelsTiersContextsAndTokenBuckets() {
        struct TierCase {
            let name: String?
            let multiplier: Decimal
            let supportsLongContext: Bool
        }
        struct ModelCase {
            let model: String
            let input: Decimal
            let cached: Decimal
            let cacheWrite: Decimal
            let output: Decimal
            let tiers: [TierCase]
        }
        func roundNano(_ value: Decimal) -> Int64 {
            Int64(NSDecimalNumber(decimal: value).doubleValue.rounded())
        }
        func expectedCost(model: ModelCase, tier: TierCase, input: Int64, cached: Int64, cacheWrite: Int64, output: Int64) -> Int64 {
            let longContext = input > 272_000
            let inputMultiplier: Decimal = longContext ? 2 : 1
            let outputMultiplier: Decimal = longContext ? 1.5 : 1
            let uncached = max(0, input - cached - cacheWrite)
            let total = Decimal(uncached) * model.input * tier.multiplier * inputMultiplier
                + Decimal(cached) * model.cached * tier.multiplier * inputMultiplier
                + Decimal(cacheWrite) * model.cacheWrite * tier.multiplier * inputMultiplier
                + Decimal(output) * model.output * tier.multiplier * outputMultiplier
            return roundNano(total)
        }

        let standardLong = TierCase(name: nil, multiplier: 1, supportsLongContext: true)
        let flexLong = TierCase(name: "flex", multiplier: 0.5, supportsLongContext: true)
        let fastLong = TierCase(name: "fast", multiplier: 2, supportsLongContext: true)
        let standardShort = TierCase(name: nil, multiplier: 1, supportsLongContext: false)
        let flexShort = TierCase(name: "flex", multiplier: 0.5, supportsLongContext: false)
        let fastShort = TierCase(name: "fast", multiplier: 2, supportsLongContext: false)
        let fastShort25 = TierCase(name: "fast", multiplier: 2.5, supportsLongContext: false)

        let models: [ModelCase] = [
            ModelCase(model: "gpt-5.6-sol", input: 4_000, cached: 400, cacheWrite: 5_000, output: 20_000, tiers: [standardLong, flexLong, fastLong]),
            ModelCase(model: "gpt-5.6-terra", input: 2_000, cached: 200, cacheWrite: 2_500, output: 12_000, tiers: [standardLong, flexLong, fastLong]),
            ModelCase(model: "gpt-5.6-luna", input: 200, cached: 20, cacheWrite: 250, output: 1_200, tiers: [standardLong, flexLong, fastLong]),
            ModelCase(model: "gpt-5.5", input: 5_000, cached: 500, cacheWrite: 5_000, output: 30_000, tiers: [standardLong, flexLong, fastShort25]),
            ModelCase(model: "gpt-5.4", input: 2_500, cached: 250, cacheWrite: 2_500, output: 15_000, tiers: [standardLong, flexLong, fastShort]),
            ModelCase(model: "gpt-5.4-mini", input: 750, cached: 75, cacheWrite: 750, output: 4_500, tiers: [standardShort, flexShort, fastShort]),
            ModelCase(model: "gpt-5.4-nano", input: 200, cached: 20, cacheWrite: 200, output: 1_250, tiers: [standardShort, flexShort]),
            ModelCase(model: "gpt-5.3-codex", input: 1_750, cached: 175, cacheWrite: 1_750, output: 14_000, tiers: [standardShort, fastShort]),
            ModelCase(model: "gpt-5.2", input: 1_750, cached: 175, cacheWrite: 1_750, output: 14_000, tiers: [standardShort, flexShort, fastShort]),
            ModelCase(model: "gpt-5.2-codex", input: 1_750, cached: 175, cacheWrite: 1_750, output: 14_000, tiers: [standardShort, flexShort, fastShort]),
            ModelCase(model: "gpt-5.1-codex", input: 1_250, cached: 125, cacheWrite: 1_250, output: 10_000, tiers: [standardShort]),
            ModelCase(model: "gpt-5.1-codex-max", input: 1_250, cached: 125, cacheWrite: 1_250, output: 10_000, tiers: [standardShort]),
            ModelCase(model: "gpt-5.1-codex-mini", input: 250, cached: 25, cacheWrite: 250, output: 2_000, tiers: [standardShort]),
            ModelCase(model: "gpt-5", input: 1_250, cached: 125, cacheWrite: 1_250, output: 10_000, tiers: [standardShort, flexShort, fastShort]),
            ModelCase(model: "gpt-5-codex", input: 1_250, cached: 125, cacheWrite: 1_250, output: 10_000, tiers: [standardShort, flexShort, fastShort])
        ]

        enum Bucket: CaseIterable {
            case input
            case cached
            case cacheWrite
            case output
        }

        for model in models {
            for tier in model.tiers {
                for contextInput in [272_000, 272_001] as [Int64] {
                    for bucket in Bucket.allCases {
                        let outputTokens: Int64 = bucket == .output ? 1_000 : 0
                        let cachedTokens: Int64 = bucket == .cached ? contextInput : 0
                        let cacheWriteTokens: Int64 = bucket == .cacheWrite ? contextInput : 0
                        let tokens = TokenBreakdown(
                            inputTokens: contextInput,
                            cachedInputTokens: cachedTokens,
                            cacheWriteInputTokens: cacheWriteTokens,
                            outputTokens: outputTokens
                        )
                        let result = PricingEvaluator.evaluate(
                            modelCanonical: model.model,
                            serviceTier: tier.name,
                            timestampMs: BundledPricingCatalog.publishedAtMs,
                            tokens: tokens
                        )
                        let label = "\(model.model) \(String(describing: tier.name)) \(contextInput) \(bucket)"
                        if contextInput > 272_000 && !tier.supportsLongContext {
                            XCTAssertEqual(result.pricingStatus, .unpricedUnsupportedContextLength, label)
                            XCTAssertEqual(result.estimatedCost, .zero, label)
                        } else {
                            XCTAssertEqual(result.pricingStatus, .priced, label)
                            XCTAssertEqual(
                                result.estimatedCost.rawValue,
                                expectedCost(
                                    model: model,
                                    tier: tier,
                                    input: tokens.inputTokens,
                                    cached: tokens.cachedInputTokens,
                                    cacheWrite: tokens.cacheWriteInputTokens,
                                    output: tokens.outputTokens
                                ),
                                label
                            )
                        }
                    }
                }
            }
        }
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
        let beforeSolCutover: Int64 = 1_787_340_849_999
        let solCutover: Int64 = 1_787_340_850_000
        let afterSolCutover: Int64 = 1_787_340_850_001

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

        let solCases: [(tier: String?, shortBefore: Int64, shortCurrent: Int64, longBefore: Int64, longCurrent: Int64)] = [
            (nil, 500_000_000, 400_000_000, 3_000_000_000, 2_400_000_000),
            ("flex", 250_000_000, 200_000_000, 1_500_000_000, 1_200_000_000),
            ("fast", 1_000_000_000, 800_000_000, 6_000_000_000, 4_800_000_000)
        ]
        for item in solCases {
            XCTAssertEqual(PricingEvaluator.evaluate(
                modelCanonical: "gpt-5.6-sol",
                serviceTier: item.tier,
                timestampMs: beforeSolCutover,
                tokens: TokenBreakdown(inputTokens: tokenCount)
            ).estimatedCost.rawValue, item.shortBefore, "\(String(describing: item.tier)) short before")
            XCTAssertEqual(PricingEvaluator.evaluate(
                modelCanonical: "gpt-5.6-sol",
                serviceTier: item.tier,
                timestampMs: solCutover,
                tokens: TokenBreakdown(inputTokens: tokenCount)
            ).estimatedCost.rawValue, item.shortCurrent, "\(String(describing: item.tier)) short at")
            XCTAssertEqual(PricingEvaluator.evaluate(
                modelCanonical: "gpt-5.6-sol",
                serviceTier: item.tier,
                timestampMs: afterSolCutover,
                tokens: TokenBreakdown(inputTokens: tokenCount)
            ).estimatedCost.rawValue, item.shortCurrent, "\(String(describing: item.tier)) short after")
            XCTAssertEqual(PricingEvaluator.evaluate(
                modelCanonical: "gpt-5.6-sol",
                serviceTier: item.tier,
                timestampMs: beforeSolCutover,
                tokens: TokenBreakdown(inputTokens: 300_000)
            ).estimatedCost.rawValue, item.longBefore, "\(String(describing: item.tier)) long before")
            XCTAssertEqual(PricingEvaluator.evaluate(
                modelCanonical: "gpt-5.6-sol",
                serviceTier: item.tier,
                timestampMs: solCutover,
                tokens: TokenBreakdown(inputTokens: 300_000)
            ).estimatedCost.rawValue, item.longCurrent, "\(String(describing: item.tier)) long at")
            XCTAssertEqual(PricingEvaluator.evaluate(
                modelCanonical: "gpt-5.6-sol",
                serviceTier: item.tier,
                timestampMs: afterSolCutover,
                tokens: TokenBreakdown(inputTokens: 300_000)
            ).estimatedCost.rawValue, item.longCurrent, "\(String(describing: item.tier)) long after")
        }
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
        XCTAssertTrue(decoded.sourceURLs.contains("https://developers.openai.com/api/docs/guides/prompt-caching"))
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

    func testSegmentedRepriceResumesAfterFailureAndPublishesAtomically() throws {
        let directory = try makeTemporaryDirectory(named: "SegmentedReprice")
        let database = try makeMigratedDatabase(in: directory)
        try PricingCatalogService.shared.ensureCatalogInstalled(database: database)
        let timestamp = BundledPricingCatalog.publishedAtMs

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
                'segmented', 'segmented', NULL, 0, '/tmp/segmented.jsonl',
                'sessions/segmented.jsonl', 'active', 'Segmented', 'Fixture', '/tmp',
                ?, ?, ?, 1200, 1200, 1200, 0, 0, 0, 0, 777, 'fullyUnpriced', NULL, 0, NULL
            );
            """,
            bindings: [timestamp, timestamp, timestamp]
        )
        try database.executeUpdate(
            sql: """
            WITH RECURSIVE sequence(value) AS (
                VALUES(1)
                UNION ALL
                SELECT value + 1 FROM sequence WHERE value < 1200
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
                printf('seg-%04d', value), 'segmented', 'segmented', 0, value,
                ?, 'gpt-5.6-terra', 'gpt-5.6-terra', NULL, NULL,
                1, 0, 0, 0, 0, 1, 1,
                0, NULL, 'unpricedUnknownModel', 'explicit_last_usage',
                'direct_turn_context', 0, '/tmp/segmented.jsonl', value,
                1, NULL, ?, 'event_timestamp', 'legacy-segmented'
            FROM sequence;
            """,
            bindings: [timestamp, timestamp]
        )

        XCTAssertThrowsError(try PricingCatalogService.shared.repriceAllUsageEvents(
            database: database,
            batchSize: 500,
            simulatedFailureAfterBatches: 1
        ))
        XCTAssertEqual(
            try database.stringScalar(sql: "SELECT value FROM app_metadata WHERE key = 'pricing_reprice_status';"),
            "failed"
        )
        XCTAssertEqual(try database.intScalar(
            sql: "SELECT COUNT(*) FROM codex_usage_events WHERE pricing_catalog_version = 'legacy-segmented';"
        ), 1200)
        XCTAssertEqual(try database.int64Scalar(
            sql: "SELECT estimated_cost_usd_nano FROM codex_sessions WHERE session_id = 'segmented';"
        ), 777)
        XCTAssertEqual(try database.intScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'pricing_reprice_processed_events';"
        ), 500)

        try PricingCatalogService.shared.repriceAllUsageEvents(database: database, batchSize: 500)

        XCTAssertEqual(
            try database.stringScalar(sql: "SELECT value FROM app_metadata WHERE key = 'pricing_reprice_status';"),
            "completed"
        )
        XCTAssertEqual(try database.intScalar(
            sql: "SELECT COUNT(*) FROM codex_usage_events WHERE pricing_catalog_version = ?;",
            bindings: [BundledPricingCatalog.currentVersion]
        ), 1200)
        XCTAssertEqual(try database.int64Scalar(
            sql: "SELECT estimated_cost_usd_nano FROM codex_sessions WHERE session_id = 'segmented';"
        ), 2_400_000)
        XCTAssertEqual(try database.int64Scalar(
            sql: "SELECT SUM(estimated_cost_usd_nano) FROM codex_session_summaries WHERE session_id = 'segmented';"
        ), 2_400_000)
        XCTAssertEqual(try database.int64Scalar(
            sql: "SELECT SUM(estimated_cost_usd_nano) FROM codex_daily_usage_summaries WHERE session_id = 'segmented';"
        ), 2_400_000)
    }

    func testRepricePreservesUnpricedReasonCountsAcrossSummariesAndDiagnostics() throws {
        let directory = try makeTemporaryDirectory(named: "UnpricedReasons")
        let database = try makeMigratedDatabase(in: directory)
        let repository = UsageAnalyticsRepository(database: database)
        try PricingCatalogService.shared.ensureCatalogInstalled(database: database)
        let timestamp = BundledPricingCatalog.publishedAtMs

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
                'reasons', 'reasons', NULL, 0, '/tmp/reasons.jsonl',
                'sessions/reasons.jsonl', 'active', 'Reasons', 'Fixture', '/tmp',
                ?, ?, ?, 3, 130, 130, 0, 0, 0, 0, 0, 'fullyUnpriced', NULL, 0, NULL
            );
            """,
            bindings: [timestamp, timestamp, timestamp]
        )
        let events: [(id: String, model: String, tier: String?, input: Int64)] = [
            ("priced", "gpt-5.6-terra", nil, 100),
            ("unknown", "unknown", nil, 10),
            ("tier", "gpt-5.6-terra", "unsupported", 20)
        ]
        for (offset, event) in events.enumerated() {
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
                ) VALUES (?, 'reasons', 'reasons', 0, ?, ?, ?, ?, ?, NULL,
                    ?, 0, 0, 0, 0, ?, ?, 0, NULL, 'unpricedUnknownModel',
                    'explicit_last_usage', 'direct_turn_context', 0,
                    '/tmp/reasons.jsonl', ?, 1, NULL, ?, 'event_timestamp', 'legacy-reasons');
                """,
                bindings: [
                    event.id,
                    offset,
                    timestamp + Int64(offset),
                    event.model,
                    event.model,
                    event.tier,
                    event.input,
                    event.input,
                    event.input,
                    offset,
                    timestamp
                ]
            )
        }

        try PricingCatalogService.shared.repriceAllUsageEvents(database: database, batchSize: 2)

        let session = try XCTUnwrap(try repository.fetchSessionPage(limit: 1).sessions.first)
        XCTAssertEqual(session.pricingStatus, .partiallyPriced)
        XCTAssertEqual(session.unpricedReasonCounts.unknownModelEvents, 1)
        XCTAssertEqual(session.unpricedReasonCounts.unknownModelTokens, 10)
        XCTAssertEqual(session.unpricedReasonCounts.unsupportedTierEvents, 1)
        XCTAssertEqual(session.unpricedReasonCounts.unsupportedTierTokens, 20)
        XCTAssertEqual(session.estimatedCost.rawValue, 200_000)

        let diagnostics = try repository.fetchDiagnostics()
        XCTAssertEqual(diagnostics.unpricedEvents, 2)
        XCTAssertEqual(diagnostics.unpricedTokens, 30)
        XCTAssertEqual(diagnostics.unpricedReasonCounts.unknownModelEvents, 1)
        XCTAssertEqual(diagnostics.unpricedReasonCounts.unsupportedTierEvents, 1)
        XCTAssertEqual(diagnostics.invariantViolationCount, 0)
    }
}
