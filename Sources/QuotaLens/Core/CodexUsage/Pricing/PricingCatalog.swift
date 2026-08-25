// QuotaLens 价格目录模型与官方费率规则

import Foundation

public struct PricingCatalogModel: Codable, Sendable {
    public let catalogVersion: String
    public let schemaVersion: Int
    public let publishedAt: Int64
    public let catalogSha256: String
    public let sourceURLs: [String]
    public let models: [PricingModelEntry]

    public init(
        catalogVersion: String,
        schemaVersion: Int = 1,
        publishedAt: Int64,
        catalogSha256: String = "",
        sourceURLs: [String] = [],
        models: [PricingModelEntry]
    ) {
        self.catalogVersion = catalogVersion
        self.schemaVersion = schemaVersion
        self.publishedAt = publishedAt
        self.catalogSha256 = catalogSha256
        self.sourceURLs = sourceURLs
        self.models = models
    }
}

public struct PricingModelEntry: Codable, Sendable {
    public let modelKey: String
    public let aliases: [String]
    public let rules: [PricingRuleEntry]

    public init(modelKey: String, aliases: [String] = [], rules: [PricingRuleEntry]) {
        self.modelKey = modelKey
        self.aliases = aliases
        self.rules = rules
    }
}

public struct PricingRuleEntry: Codable, Sendable {
    public let ruleId: String
    public let serviceTier: String? // nil = standard/default, "fast", "flex", "priority"
    public let effectiveFromMs: Int64
    public let effectiveToMs: Int64?
    public let inputNanoUsdPerToken: Int64
    public let cachedNanoUsdPerToken: Int64
    public let cacheWriteNanoUsdPerToken: Int64?
    public let outputNanoUsdPerToken: Int64
    /// Common denominator for all per-token rate numerators in this rule.
    /// Most rows use 1; fractional nano-USD rates such as $0.0375 / 1M
    /// cached tokens use 2 so the catalog does not round away half a nano.
    public let rateDivisor: Int64
    /// Largest input-token count supported by this exact tier/rate row.
    /// A nil value means the row either has explicit long-context pricing or
    /// does not publish a short-context-only ceiling.
    public let maximumInputTokens: Int64?
    public let longContextThresholdTokens: Int64?
    public let longContextInputMultiplierPpm: Int64?
    public let longContextOutputMultiplierPpm: Int64?

    public init(
        ruleId: String,
        serviceTier: String? = nil,
        effectiveFromMs: Int64 = 0,
        effectiveToMs: Int64? = nil,
        inputNanoUsdPerToken: Int64,
        cachedNanoUsdPerToken: Int64,
        cacheWriteNanoUsdPerToken: Int64? = nil,
        outputNanoUsdPerToken: Int64,
        rateDivisor: Int64 = 1,
        maximumInputTokens: Int64? = nil,
        longContextThresholdTokens: Int64? = nil,
        longContextInputMultiplierPpm: Int64? = nil,
        longContextOutputMultiplierPpm: Int64? = nil
    ) {
        self.ruleId = ruleId
        self.serviceTier = serviceTier
        self.effectiveFromMs = effectiveFromMs
        self.effectiveToMs = effectiveToMs
        self.inputNanoUsdPerToken = inputNanoUsdPerToken
        self.cachedNanoUsdPerToken = cachedNanoUsdPerToken
        self.cacheWriteNanoUsdPerToken = cacheWriteNanoUsdPerToken
        self.outputNanoUsdPerToken = outputNanoUsdPerToken
        self.rateDivisor = rateDivisor
        self.maximumInputTokens = maximumInputTokens
        self.longContextThresholdTokens = longContextThresholdTokens
        self.longContextInputMultiplierPpm = longContextInputMultiplierPpm
        self.longContextOutputMultiplierPpm = longContextOutputMultiplierPpm
    }
}

// MARK: - 内置官方 OpenAI 价格目录 (2026-08-25 官方列表价)
public enum BundledPricingCatalog {
    // v4 adds cache-write token accounting, effective-dated GPT-5.6 pricing,
    // and official Standard/Flex/Fast service-tier rows. Catalog versions are
    // immutable so a developer build that already installed v3 also upgrades.
    public static let currentVersion = "2026-08-v4"
    public static let publishedAtMs: Int64 = 1787616000000 // 2026-08-25
    private static let gpt56ReleaseMs: Int64 = 1783555200000 // 2026-07-09
    private static let gpt56TerraLunaCutoverMs: Int64 = 1785369600000 // 2026-07-30
    private static let gpt56SolPromotionalCutoverMs: Int64 = 1787270400000 // 2026-08-21

    private struct GPT56Rate: Sendable {
        let input: Int64
        let cached: Int64
        let cacheWrite: Int64
        let output: Int64
    }

    private static func gpt56Rule(
        modelKey: String,
        suffix: String,
        serviceTier: String?,
        effectiveFromMs: Int64,
        effectiveToMs: Int64?,
        rate: GPT56Rate
    ) -> PricingRuleEntry {
        let tierId = serviceTier ?? "std"
        return PricingRuleEntry(
            ruleId: "\(modelKey)-\(tierId)-\(suffix)",
            serviceTier: serviceTier,
            effectiveFromMs: effectiveFromMs,
            effectiveToMs: effectiveToMs,
            inputNanoUsdPerToken: rate.input,
            cachedNanoUsdPerToken: rate.cached,
            cacheWriteNanoUsdPerToken: rate.cacheWrite,
            outputNanoUsdPerToken: rate.output,
            longContextThresholdTokens: 272_000,
            longContextInputMultiplierPpm: 2_000_000,
            longContextOutputMultiplierPpm: 1_500_000
        )
    }

    private static func scaledGPT56Rate(_ rate: GPT56Rate, multiplierPpm: Int64) -> GPT56Rate {
        func scale(_ value: Int64) -> Int64 {
            NSDecimalNumber(decimal: Decimal(value) * Decimal(multiplierPpm) / Decimal(1_000_000)).int64Value
        }
        return GPT56Rate(
            input: scale(rate.input),
            cached: scale(rate.cached),
            cacheWrite: scale(rate.cacheWrite),
            output: scale(rate.output)
        )
    }

    private static func gpt56Rules(
        modelKey: String,
        launch: GPT56Rate,
        current: GPT56Rate,
        currentFromMs: Int64
    ) -> [PricingRuleEntry] {
        let periods: [(suffix: String, from: Int64, to: Int64?, rate: GPT56Rate)] = [
            ("launch-v4", gpt56ReleaseMs, currentFromMs, launch),
            ("current-v4", currentFromMs, nil, current)
        ]
        return periods.flatMap { period in
            [
                gpt56Rule(
                    modelKey: modelKey,
                    suffix: period.suffix,
                    serviceTier: nil,
                    effectiveFromMs: period.from,
                    effectiveToMs: period.to,
                    rate: period.rate
                ),
                gpt56Rule(
                    modelKey: modelKey,
                    suffix: period.suffix,
                    serviceTier: "flex",
                    effectiveFromMs: period.from,
                    effectiveToMs: period.to,
                    rate: scaledGPT56Rate(period.rate, multiplierPpm: 500_000)
                ),
                gpt56Rule(
                    modelKey: modelKey,
                    suffix: period.suffix,
                    serviceTier: "fast",
                    effectiveFromMs: period.from,
                    effectiveToMs: period.to,
                    rate: scaledGPT56Rate(period.rate, multiplierPpm: 2_000_000)
                )
            ]
        }
    }

    private static func greatestCommonDivisor(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        var a = lhs
        var b = rhs
        while b != 0 {
            (a, b) = (b, a % b)
        }
        return a
    }

    private static func publishedTierRule(
        modelKey: String,
        serviceTier: String?,
        input: Int64,
        cached: Int64,
        output: Int64,
        multiplierPpm: Int64,
        supportsLongContext: Bool
    ) -> PricingRuleEntry {
        let divisorBase: Int64 = 1_000_000
        let commonDivisor = greatestCommonDivisor(multiplierPpm, divisorBase)
        let numeratorMultiplier = multiplierPpm / commonDivisor
        let rateDivisor = divisorBase / commonDivisor
        let tierId = serviceTier ?? "std"
        return PricingRuleEntry(
            ruleId: "\(modelKey)-\(tierId)-v4",
            serviceTier: serviceTier,
            effectiveFromMs: 0,
            inputNanoUsdPerToken: input * numeratorMultiplier,
            cachedNanoUsdPerToken: cached * numeratorMultiplier,
            outputNanoUsdPerToken: output * numeratorMultiplier,
            rateDivisor: rateDivisor,
            maximumInputTokens: supportsLongContext ? nil : 272_000,
            longContextThresholdTokens: supportsLongContext ? 272_000 : nil,
            longContextInputMultiplierPpm: supportsLongContext ? 2_000_000 : nil,
            longContextOutputMultiplierPpm: supportsLongContext ? 1_500_000 : nil
        )
    }

    private static func publishedTierRules(
        modelKey: String,
        input: Int64,
        cached: Int64,
        output: Int64,
        supportsLongContext: Bool,
        supportsFlex: Bool,
        fastMultiplierPpm: Int64?
    ) -> [PricingRuleEntry] {
        var rules = [publishedTierRule(
            modelKey: modelKey,
            serviceTier: nil,
            input: input,
            cached: cached,
            output: output,
            multiplierPpm: 1_000_000,
            supportsLongContext: supportsLongContext
        )]
        if supportsFlex {
            rules.append(publishedTierRule(
                modelKey: modelKey,
                serviceTier: "flex",
                input: input,
                cached: cached,
                output: output,
                multiplierPpm: 500_000,
                supportsLongContext: supportsLongContext
            ))
        }
        if let fastMultiplierPpm {
            rules.append(publishedTierRule(
                modelKey: modelKey,
                serviceTier: "fast",
                input: input,
                cached: cached,
                output: output,
                multiplierPpm: fastMultiplierPpm,
                supportsLongContext: false
            ))
        }
        return rules
    }

    public static let defaultCatalog = PricingCatalogModel(
        catalogVersion: currentVersion,
        schemaVersion: 4,
        publishedAt: publishedAtMs,
        catalogSha256: "",
        sourceURLs: [
            "https://developers.openai.com/api/docs/pricing",
            "https://developers.openai.com/api/docs/changelog",
            "https://developers.openai.com/api/docs/guides/deployment-checklist",
            "https://developers.openai.com/api/docs/guides/flex-processing",
            "https://developers.openai.com/api/docs/guides/fast-mode",
            "https://developers.openai.com/api/docs/models/gpt-5.6-sol",
            "https://developers.openai.com/api/docs/models/gpt-5.6-terra",
            "https://developers.openai.com/api/docs/models/gpt-5.6-luna",
            "https://developers.openai.com/api/docs/models/gpt-5.5",
            "https://developers.openai.com/api/docs/models/gpt-5.4",
            "https://developers.openai.com/api/docs/models/gpt-5.4-mini",
            "https://developers.openai.com/api/docs/models/gpt-5.4-nano",
            "https://developers.openai.com/api/docs/models/gpt-5.3-codex",
            "https://developers.openai.com/api/docs/models/gpt-5.2-codex",
            "https://developers.openai.com/api/docs/models/gpt-5.1-codex",
            "https://developers.openai.com/api/docs/models/gpt-5.1-codex-mini"
        ],
        models: [
            // 1. GPT-5.6 系列 (旗舰推理模型)
            PricingModelEntry(
                modelKey: "gpt-5.6-sol",
                // The API changelog states that the request alias `gpt-5.6`
                // routes to Sol. Local Codex rollout records can also use a
                // generic family label, so QuotaLens keeps that generic label
                // unpriced unless the rollout itself names a concrete SKU.
                aliases: ["gpt-5.6-sol", "codex-sol", "gpt-5-sol"],
                rules: Self.gpt56Rules(
                    modelKey: "gpt-5.6-sol",
                    launch: GPT56Rate(input: 5_000, cached: 500, cacheWrite: 6_250, output: 30_000),
                    current: GPT56Rate(input: 4_000, cached: 400, cacheWrite: 5_000, output: 20_000),
                    currentFromMs: gpt56SolPromotionalCutoverMs
                )
            ),
            PricingModelEntry(
                modelKey: "gpt-5.6-terra",
                aliases: ["gpt-5.6-terra", "codex-terra", "gpt-5-terra"],
                rules: Self.gpt56Rules(
                    modelKey: "gpt-5.6-terra",
                    launch: GPT56Rate(input: 2_500, cached: 250, cacheWrite: 3_125, output: 15_000),
                    current: GPT56Rate(input: 2_000, cached: 200, cacheWrite: 2_500, output: 12_000),
                    currentFromMs: gpt56TerraLunaCutoverMs
                )
            ),
            PricingModelEntry(
                modelKey: "gpt-5.6-luna",
                aliases: ["gpt-5.6-luna", "codex-luna", "gpt-5-luna"],
                rules: Self.gpt56Rules(
                    modelKey: "gpt-5.6-luna",
                    launch: GPT56Rate(input: 1_000, cached: 100, cacheWrite: 1_250, output: 6_000),
                    current: GPT56Rate(input: 200, cached: 20, cacheWrite: 250, output: 1_200),
                    currentFromMs: gpt56TerraLunaCutoverMs
                )
            ),

            // 2. GPT-5.5 系列
            PricingModelEntry(
                modelKey: "gpt-5.5",
                aliases: ["gpt-5.5", "gpt-5.5-codex", "gpt-5.5-preview"],
                rules: Self.publishedTierRules(
                    modelKey: "gpt-5.5",
                    input: 5_000,
                    cached: 500,
                    output: 30_000,
                    supportsLongContext: true,
                    supportsFlex: true,
                    fastMultiplierPpm: 2_500_000
                )
            ),

            // 3. GPT-5.4 系列
            PricingModelEntry(
                modelKey: "gpt-5.4",
                aliases: ["gpt-5.4", "gpt-5.4-codex"],
                rules: Self.publishedTierRules(
                    modelKey: "gpt-5.4",
                    input: 2_500,
                    cached: 250,
                    output: 15_000,
                    supportsLongContext: true,
                    supportsFlex: true,
                    fastMultiplierPpm: 2_000_000
                )
            ),
            PricingModelEntry(
                modelKey: "gpt-5.4-mini",
                aliases: ["gpt-5.4-mini"],
                rules: Self.publishedTierRules(
                    modelKey: "gpt-5.4-mini",
                    input: 750,
                    cached: 75,
                    output: 4_500,
                    supportsLongContext: false,
                    supportsFlex: true,
                    fastMultiplierPpm: 2_000_000
                )
            ),
            PricingModelEntry(
                modelKey: "gpt-5.4-nano",
                aliases: ["gpt-5.4-nano"],
                rules: Self.publishedTierRules(
                    modelKey: "gpt-5.4-nano",
                    input: 200,
                    cached: 20,
                    output: 1_250,
                    supportsLongContext: false,
                    supportsFlex: true,
                    fastMultiplierPpm: nil
                )
            ),

            // 4. GPT-5.3 系列
            PricingModelEntry(
                modelKey: "gpt-5.3-codex",
                aliases: ["gpt-5.3-codex", "gpt-5.3"],
                rules: Self.publishedTierRules(
                    modelKey: "gpt-5.3-codex",
                    input: 1_750,
                    cached: 175,
                    output: 14_000,
                    supportsLongContext: false,
                    supportsFlex: false,
                    fastMultiplierPpm: 2_000_000
                )
            ),

            // 5. GPT-5.2 / GPT-5.1 历史模型
            PricingModelEntry(
                modelKey: "gpt-5.2",
                aliases: ["gpt-5.2", "gpt-5.2-codex"],
                rules: Self.publishedTierRules(
                    modelKey: "gpt-5.2",
                    input: 1_750,
                    cached: 175,
                    output: 14_000,
                    supportsLongContext: false,
                    supportsFlex: true,
                    fastMultiplierPpm: 2_000_000
                )
            ),
            PricingModelEntry(
                modelKey: "gpt-5.1-codex",
                aliases: ["gpt-5.1-codex", "gpt-5.1", "gpt-5.1-codex-max"],
                rules: Self.publishedTierRules(
                    modelKey: "gpt-5.1-codex",
                    input: 1_250,
                    cached: 125,
                    output: 10_000,
                    supportsLongContext: false,
                    supportsFlex: false,
                    fastMultiplierPpm: nil
                )
            ),
            PricingModelEntry(
                modelKey: "gpt-5.1-codex-mini",
                aliases: ["gpt-5.1-codex-mini"],
                rules: Self.publishedTierRules(
                    modelKey: "gpt-5.1-codex-mini",
                    input: 250,
                    cached: 25,
                    output: 2_000,
                    supportsLongContext: false,
                    supportsFlex: false,
                    fastMultiplierPpm: nil
                )
            ),

            // 6. 标准 GPT-5 / GPT-5-Codex。Only explicit model IDs are
            // aliases; generic "default" data must remain unknown and unpriced.
            PricingModelEntry(
                modelKey: "gpt-5",
                aliases: ["gpt-5", "gpt-5-codex"],
                rules: Self.publishedTierRules(
                    modelKey: "gpt-5",
                    input: 1_250,
                    cached: 125,
                    output: 10_000,
                    supportsLongContext: false,
                    supportsFlex: true,
                    fastMultiplierPpm: 2_000_000
                )
            )
        ]
    )
}
