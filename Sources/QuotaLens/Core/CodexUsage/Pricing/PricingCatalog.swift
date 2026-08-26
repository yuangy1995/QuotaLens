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
    /// 本规则所有 token 单价分子的共同分母。
    /// 大多数规则为 1；例如 $0.0375 / 1M cached token 这类半 nano 费率使用 2，避免目录层提前舍入。
    public let rateDivisor: Int64
    /// 当前层级/费率行支持的最大输入 token 数；nil 表示有显式长上下文价格，或没有公开短上下文上限。
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
    // v5 保持 v4 不可变，补齐旧模型 Cache Write、官方上线日期和 Sol 促销精确切点。
    public static let currentVersion = "2026-08-v5"
    public static let publishedAtMs: Int64 = 1787616000000 // 2026-08-25
    private static let gpt56ReleaseMs: Int64 = 1783555200000 // 2026-07-09
    private static let gpt56TerraLunaCutoverMs: Int64 = 1785369600000 // 2026-07-30
    private static let gpt56FastLongContextFromMs: Int64 = 1785888000000 // 2026-08-05
    private static let gpt56SolPromotionalCutoverMs: Int64 = 1787340850000 // 2026-08-21T19:34:10Z

    // 以官方 API 上线日为列表价起点，不混用 Codex 产品上线日；日期粒度统一取 UTC 零点。
    private static let gpt5APIReleaseMs: Int64 = 1754524800000 // 2025-08-07
    private static let gpt5CodexReleaseMs: Int64 = 1758585600000 // 2025-09-23
    private static let gpt51ReleaseMs: Int64 = 1762992000000 // 2025-11-13
    private static let gpt51CodexMaxReleaseMs: Int64 = 1764806400000 // 2025-12-04
    private static let gpt52ReleaseMs: Int64 = 1765411200000 // 2025-12-11
    private static let gpt52CodexReleaseMs: Int64 = 1768348800000 // 2026-01-14
    private static let gpt53CodexReleaseMs: Int64 = 1771891200000 // 2026-02-24
    private static let gpt54ReleaseMs: Int64 = 1772668800000 // 2026-03-05
    private static let gpt54MiniNanoReleaseMs: Int64 = 1773705600000 // 2026-03-17
    private static let gpt55ReleaseMs: Int64 = 1776988800000 // 2026-04-24

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
        rate: GPT56Rate,
        supportsLongContext: Bool = true
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
            maximumInputTokens: supportsLongContext ? nil : 272_000,
            longContextThresholdTokens: supportsLongContext ? 272_000 : nil,
            longContextInputMultiplierPpm: supportsLongContext ? 2_000_000 : nil,
            longContextOutputMultiplierPpm: supportsLongContext ? 1_500_000 : nil
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
            ("launch-v5", gpt56ReleaseMs, currentFromMs, launch),
            ("current-v5", currentFromMs, nil, current)
        ]
        return periods.flatMap { period -> [PricingRuleEntry] in
            var rules = [
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
                )
            ]
            let fastRate = scaledGPT56Rate(period.rate, multiplierPpm: 2_000_000)
            // Fast 长上下文在 8 月 5 日才开放，不能将当前能力回填到此前的历史请求。
            if period.from < gpt56FastLongContextFromMs {
                rules.append(gpt56Rule(
                    modelKey: modelKey,
                    suffix: "\(period.suffix)-short",
                    serviceTier: "fast",
                    effectiveFromMs: period.from,
                    effectiveToMs: min(period.to ?? gpt56FastLongContextFromMs, gpt56FastLongContextFromMs),
                    rate: fastRate,
                    supportsLongContext: false
                ))
            }
            if period.to == nil || period.to! > gpt56FastLongContextFromMs {
                rules.append(gpt56Rule(
                    modelKey: modelKey,
                    suffix: period.suffix,
                    serviceTier: "fast",
                    effectiveFromMs: max(period.from, gpt56FastLongContextFromMs),
                    effectiveToMs: period.to,
                    rate: fastRate
                ))
            }
            return rules
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
        effectiveFromMs: Int64,
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
            ruleId: "\(modelKey)-\(tierId)-v5",
            serviceTier: serviceTier,
            effectiveFromMs: effectiveFromMs,
            inputNanoUsdPerToken: input * numeratorMultiplier,
            cachedNanoUsdPerToken: cached * numeratorMultiplier,
            cacheWriteNanoUsdPerToken: input * numeratorMultiplier,
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
        effectiveFromMs: Int64,
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
            effectiveFromMs: effectiveFromMs,
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
                effectiveFromMs: effectiveFromMs,
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
                effectiveFromMs: effectiveFromMs,
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
        schemaVersion: 5,
        publishedAt: publishedAtMs,
        catalogSha256: "",
        sourceURLs: [
            "https://developers.openai.com/api/docs/pricing",
            "https://developers.openai.com/api/docs/changelog",
            "https://developers.openai.com/api/docs/guides/deployment-checklist",
            "https://developers.openai.com/api/docs/guides/flex-processing",
            "https://developers.openai.com/api/docs/guides/fast-mode",
            "https://developers.openai.com/api/docs/models/gpt-5.6-sol",
            "https://developers.openai.com/api/docs/guides/prompt-caching",
            "https://developers.openai.com/api/docs/models/gpt-5.6-terra",
            "https://developers.openai.com/api/docs/models/gpt-5.6-luna",
            "https://developers.openai.com/api/docs/models/gpt-5.5",
            "https://developers.openai.com/api/docs/models/gpt-5.4",
            "https://developers.openai.com/api/docs/models/gpt-5.4-mini",
            "https://developers.openai.com/api/docs/models/gpt-5.4-nano",
            "https://developers.openai.com/api/docs/models/gpt-5.3-codex",
            "https://developers.openai.com/api/docs/models/gpt-5.2",
            "https://developers.openai.com/api/docs/models/gpt-5.2-codex",
            "https://developers.openai.com/api/docs/models/gpt-5.1-codex",
            "https://developers.openai.com/api/docs/models/gpt-5.1-codex-max",
            "https://developers.openai.com/api/docs/models/gpt-5.1-codex-mini",
            "https://developers.openai.com/api/docs/models/gpt-5",
            "https://developers.openai.com/api/docs/models/gpt-5-codex"
        ],
        models: [
            // 1. GPT-5.6 系列 (旗舰推理模型)
            PricingModelEntry(
                modelKey: "gpt-5.6-sol",
                // API changelog 说明请求别名 `gpt-5.6` 路由到 Sol；本地 Codex rollout 也可能写入泛化族名，
                // 因此 QuotaLens 仅在日志明确记录具体 SKU 时计价，泛化族名继续保持未计价。
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
                    effectiveFromMs: gpt55ReleaseMs,
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
                    effectiveFromMs: gpt54ReleaseMs,
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
                    effectiveFromMs: gpt54MiniNanoReleaseMs,
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
                    effectiveFromMs: gpt54MiniNanoReleaseMs,
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
                aliases: ["gpt-5.3-codex"],
                rules: Self.publishedTierRules(
                    modelKey: "gpt-5.3-codex",
                    effectiveFromMs: gpt53CodexReleaseMs,
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
                aliases: ["gpt-5.2"],
                rules: Self.publishedTierRules(
                    modelKey: "gpt-5.2",
                    effectiveFromMs: gpt52ReleaseMs,
                    input: 1_750,
                    cached: 175,
                    output: 14_000,
                    supportsLongContext: false,
                    supportsFlex: true,
                    fastMultiplierPpm: 2_000_000
                )
            ),
            PricingModelEntry(
                modelKey: "gpt-5.2-codex",
                aliases: ["gpt-5.2-codex"],
                rules: Self.publishedTierRules(
                    modelKey: "gpt-5.2-codex",
                    effectiveFromMs: gpt52CodexReleaseMs,
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
                aliases: ["gpt-5.1-codex", "gpt-5.1"],
                rules: Self.publishedTierRules(
                    modelKey: "gpt-5.1-codex",
                    effectiveFromMs: gpt51ReleaseMs,
                    input: 1_250,
                    cached: 125,
                    output: 10_000,
                    supportsLongContext: false,
                    supportsFlex: false,
                    fastMultiplierPpm: nil
                )
            ),
            PricingModelEntry(
                modelKey: "gpt-5.1-codex-max",
                aliases: ["gpt-5.1-codex-max"],
                rules: Self.publishedTierRules(
                    modelKey: "gpt-5.1-codex-max",
                    effectiveFromMs: gpt51CodexMaxReleaseMs,
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
                    effectiveFromMs: gpt51ReleaseMs,
                    input: 250,
                    cached: 25,
                    output: 2_000,
                    supportsLongContext: false,
                    supportsFlex: false,
                    fastMultiplierPpm: nil
                )
            ),

            // 6. 标准 GPT-5 / GPT-5-Codex。只接受明确模型 ID，generic default 仍保持未知。
            PricingModelEntry(
                modelKey: "gpt-5",
                aliases: ["gpt-5"],
                rules: Self.publishedTierRules(
                    modelKey: "gpt-5",
                    effectiveFromMs: gpt5APIReleaseMs,
                    input: 1_250,
                    cached: 125,
                    output: 10_000,
                    supportsLongContext: false,
                    supportsFlex: true,
                    fastMultiplierPpm: 2_000_000
                )
            ),
            PricingModelEntry(
                modelKey: "gpt-5-codex",
                aliases: ["gpt-5-codex"],
                rules: Self.publishedTierRules(
                    modelKey: "gpt-5-codex",
                    effectiveFromMs: gpt5CodexReleaseMs,
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
