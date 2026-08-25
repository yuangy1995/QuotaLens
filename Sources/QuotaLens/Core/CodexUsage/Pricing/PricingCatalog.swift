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
        self.longContextThresholdTokens = longContextThresholdTokens
        self.longContextInputMultiplierPpm = longContextInputMultiplierPpm
        self.longContextOutputMultiplierPpm = longContextOutputMultiplierPpm
    }
}

// MARK: - 内置官方 OpenAI 价格目录 (2026-08-25 官方列表价)
public enum BundledPricingCatalog {
    // v3 supersedes the partially-correct v2 catalog. Catalog versions are
    // immutable so a developer build that already installed v2 also upgrades.
    public static let currentVersion = "2026-08-v3"
    public static let publishedAtMs: Int64 = 1787616000000 // 2026-08-25

    public static let defaultCatalog = PricingCatalogModel(
        catalogVersion: currentVersion,
        schemaVersion: 2,
        publishedAt: publishedAtMs,
        catalogSha256: "",
        sourceURLs: [
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
                aliases: ["gpt-5.6", "gpt-5.6-sol", "codex-sol", "gpt-5-sol"],
                rules: [
                    PricingRuleEntry(
                        ruleId: "gpt-5.6-sol-std-v3",
                        serviceTier: nil,
                        effectiveFromMs: 0,
                        inputNanoUsdPerToken: 4_000,
                        cachedNanoUsdPerToken: 400,
                        cacheWriteNanoUsdPerToken: 5_000,
                        outputNanoUsdPerToken: 20_000,
                        longContextThresholdTokens: 272_000,
                        longContextInputMultiplierPpm: 2_000_000,
                        longContextOutputMultiplierPpm: 1_500_000
                    )
                ]
            ),
            PricingModelEntry(
                modelKey: "gpt-5.6-terra",
                aliases: ["gpt-5.6-terra", "codex-terra", "gpt-5-terra"],
                rules: [
                    PricingRuleEntry(
                        ruleId: "gpt-5.6-terra-std-v3",
                        serviceTier: nil,
                        effectiveFromMs: 0,
                        inputNanoUsdPerToken: 2_000,
                        cachedNanoUsdPerToken: 200,
                        cacheWriteNanoUsdPerToken: 2_500,
                        outputNanoUsdPerToken: 12_000,
                        longContextThresholdTokens: 272_000,
                        longContextInputMultiplierPpm: 2_000_000,
                        longContextOutputMultiplierPpm: 1_500_000
                    )
                ]
            ),
            PricingModelEntry(
                modelKey: "gpt-5.6-luna",
                aliases: ["gpt-5.6-luna", "codex-luna", "gpt-5-luna"],
                rules: [
                    PricingRuleEntry(
                        ruleId: "gpt-5.6-luna-std-v3",
                        serviceTier: nil,
                        effectiveFromMs: 0,
                        inputNanoUsdPerToken: 200,
                        cachedNanoUsdPerToken: 20,
                        cacheWriteNanoUsdPerToken: 250,
                        outputNanoUsdPerToken: 1_200,
                        longContextThresholdTokens: 272_000,
                        longContextInputMultiplierPpm: 2_000_000,
                        longContextOutputMultiplierPpm: 1_500_000
                    )
                ]
            ),

            // 2. GPT-5.5 系列
            PricingModelEntry(
                modelKey: "gpt-5.5",
                aliases: ["gpt-5.5", "gpt-5.5-codex", "gpt-5.5-preview"],
                rules: [
                    PricingRuleEntry(
                        ruleId: "gpt-5.5-std-v3",
                        serviceTier: nil,
                        effectiveFromMs: 0,
                        inputNanoUsdPerToken: 5_000,
                        cachedNanoUsdPerToken: 500,
                        outputNanoUsdPerToken: 30_000,
                        longContextThresholdTokens: 272_000,
                        longContextInputMultiplierPpm: 2_000_000,
                        longContextOutputMultiplierPpm: 1_500_000
                    )
                ]
            ),

            // 3. GPT-5.4 系列
            PricingModelEntry(
                modelKey: "gpt-5.4",
                aliases: ["gpt-5.4", "gpt-5.4-codex"],
                rules: [
                    PricingRuleEntry(
                        ruleId: "gpt-5.4-std-v3",
                        serviceTier: nil,
                        effectiveFromMs: 0,
                        inputNanoUsdPerToken: 2_500,
                        cachedNanoUsdPerToken: 250,
                        outputNanoUsdPerToken: 15_000,
                        longContextThresholdTokens: 272_000,
                        longContextInputMultiplierPpm: 2_000_000,
                        longContextOutputMultiplierPpm: 1_500_000
                    )
                ]
            ),
            PricingModelEntry(
                modelKey: "gpt-5.4-mini",
                aliases: ["gpt-5.4-mini"],
                rules: [
                    PricingRuleEntry(ruleId: "gpt-5.4-mini-std-v3", serviceTier: nil, effectiveFromMs: 0, inputNanoUsdPerToken: 750, cachedNanoUsdPerToken: 75, outputNanoUsdPerToken: 4_500)
                ]
            ),
            PricingModelEntry(
                modelKey: "gpt-5.4-nano",
                aliases: ["gpt-5.4-nano"],
                rules: [
                    PricingRuleEntry(ruleId: "gpt-5.4-nano-std-v3", serviceTier: nil, effectiveFromMs: 0, inputNanoUsdPerToken: 200, cachedNanoUsdPerToken: 20, outputNanoUsdPerToken: 1_250)
                ]
            ),

            // 4. GPT-5.3 系列
            PricingModelEntry(
                modelKey: "gpt-5.3-codex",
                aliases: ["gpt-5.3-codex", "gpt-5.3"],
                rules: [
                    PricingRuleEntry(ruleId: "gpt-5.3-codex-std-v3", serviceTier: nil, effectiveFromMs: 0, inputNanoUsdPerToken: 1_750, cachedNanoUsdPerToken: 175, outputNanoUsdPerToken: 14_000)
                ]
            ),

            // 5. GPT-5.2 / GPT-5.1 历史模型
            PricingModelEntry(
                modelKey: "gpt-5.2",
                aliases: ["gpt-5.2", "gpt-5.2-codex"],
                rules: [
                    PricingRuleEntry(ruleId: "gpt-5.2-std-v3", serviceTier: nil, effectiveFromMs: 0, inputNanoUsdPerToken: 1_750, cachedNanoUsdPerToken: 175, outputNanoUsdPerToken: 14_000)
                ]
            ),
            PricingModelEntry(
                modelKey: "gpt-5.1-codex",
                aliases: ["gpt-5.1-codex", "gpt-5.1", "gpt-5.1-codex-max"],
                rules: [
                    PricingRuleEntry(ruleId: "gpt-5.1-codex-std-v3", serviceTier: nil, effectiveFromMs: 0, inputNanoUsdPerToken: 1_250, cachedNanoUsdPerToken: 125, outputNanoUsdPerToken: 10_000)
                ]
            ),
            PricingModelEntry(
                modelKey: "gpt-5.1-codex-mini",
                aliases: ["gpt-5.1-codex-mini"],
                rules: [
                    PricingRuleEntry(ruleId: "gpt-5.1-mini-std-v3", serviceTier: nil, effectiveFromMs: 0, inputNanoUsdPerToken: 250, cachedNanoUsdPerToken: 25, outputNanoUsdPerToken: 2_000)
                ]
            ),

            // 6. 标准 GPT-5 / GPT-5-Codex。Only explicit model IDs are
            // aliases; generic "default" data must remain unknown and unpriced.
            PricingModelEntry(
                modelKey: "gpt-5",
                aliases: ["gpt-5", "gpt-5-codex"],
                rules: [
                    PricingRuleEntry(ruleId: "gpt-5-std-v3", serviceTier: nil, effectiveFromMs: 0, inputNanoUsdPerToken: 1_250, cachedNanoUsdPerToken: 125, outputNanoUsdPerToken: 10_000)
                ]
            )
        ]
    )
}
