// QuotaLens 价格目录模型与官方费率规则

import Foundation

public struct PricingCatalogModel: Codable, Sendable {
    public let catalogVersion: String
    public let schemaVersion: Int
    public let publishedAt: Int64
    public let catalogSha256: String
    public let models: [PricingModelEntry]

    public init(
        catalogVersion: String,
        schemaVersion: Int = 1,
        publishedAt: Int64,
        catalogSha256: String = "",
        models: [PricingModelEntry]
    ) {
        self.catalogVersion = catalogVersion
        self.schemaVersion = schemaVersion
        self.publishedAt = publishedAt
        self.catalogSha256 = catalogSha256
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
    public let outputNanoUsdPerToken: Int64

    public init(
        ruleId: String,
        serviceTier: String? = nil,
        effectiveFromMs: Int64 = 0,
        effectiveToMs: Int64? = nil,
        inputNanoUsdPerToken: Int64,
        cachedNanoUsdPerToken: Int64,
        outputNanoUsdPerToken: Int64
    ) {
        self.ruleId = ruleId
        self.serviceTier = serviceTier
        self.effectiveFromMs = effectiveFromMs
        self.effectiveToMs = effectiveToMs
        self.inputNanoUsdPerToken = inputNanoUsdPerToken
        self.cachedNanoUsdPerToken = cachedNanoUsdPerToken
        self.outputNanoUsdPerToken = outputNanoUsdPerToken
    }
}

// MARK: - 内置官方 OpenAI 价格目录 (2026 最新官方列表价)
public enum BundledPricingCatalog {
    public static let currentVersion = "2026-08-v1"
    public static let publishedAtMs: Int64 = 1787529600000 // 2026-08-24

    public static let defaultCatalog = PricingCatalogModel(
        catalogVersion: currentVersion,
        schemaVersion: 1,
        publishedAt: publishedAtMs,
        catalogSha256: "bundled_official_openai_2026_08",
        models: [
            // 1. GPT-5.6 系列 (旗舰推理模型)
            PricingModelEntry(
                modelKey: "gpt-5.6-sol",
                aliases: ["gpt-5.6-sol", "codex-sol", "gpt-5-sol"],
                rules: [
                    PricingRuleEntry(ruleId: "gpt-5.6-sol-std", serviceTier: nil, effectiveFromMs: 0, inputNanoUsdPerToken: 3_000, cachedNanoUsdPerToken: 750, outputNanoUsdPerToken: 12_000),
                    PricingRuleEntry(ruleId: "gpt-5.6-sol-fast", serviceTier: "fast", effectiveFromMs: 0, inputNanoUsdPerToken: 6_000, cachedNanoUsdPerToken: 1_500, outputNanoUsdPerToken: 24_000),
                    PricingRuleEntry(ruleId: "gpt-5.6-sol-flex", serviceTier: "flex", effectiveFromMs: 0, inputNanoUsdPerToken: 1_500, cachedNanoUsdPerToken: 375, outputNanoUsdPerToken: 6_000)
                ]
            ),
            PricingModelEntry(
                modelKey: "gpt-5.6-terra",
                aliases: ["gpt-5.6-terra", "codex-terra", "gpt-5-terra"],
                rules: [
                    PricingRuleEntry(ruleId: "gpt-5.6-terra-std", serviceTier: nil, effectiveFromMs: 0, inputNanoUsdPerToken: 2_500, cachedNanoUsdPerToken: 625, outputNanoUsdPerToken: 10_000),
                    PricingRuleEntry(ruleId: "gpt-5.6-terra-fast", serviceTier: "fast", effectiveFromMs: 0, inputNanoUsdPerToken: 5_000, cachedNanoUsdPerToken: 1_250, outputNanoUsdPerToken: 20_000),
                    PricingRuleEntry(ruleId: "gpt-5.6-terra-flex", serviceTier: "flex", effectiveFromMs: 0, inputNanoUsdPerToken: 1_250, cachedNanoUsdPerToken: 312, outputNanoUsdPerToken: 5_000)
                ]
            ),
            PricingModelEntry(
                modelKey: "gpt-5.6-luna",
                aliases: ["gpt-5.6-luna", "codex-luna", "gpt-5-luna"],
                rules: [
                    PricingRuleEntry(ruleId: "gpt-5.6-luna-std", serviceTier: nil, effectiveFromMs: 0, inputNanoUsdPerToken: 2_000, cachedNanoUsdPerToken: 500, outputNanoUsdPerToken: 8_000),
                    PricingRuleEntry(ruleId: "gpt-5.6-luna-fast", serviceTier: "fast", effectiveFromMs: 0, inputNanoUsdPerToken: 4_000, cachedNanoUsdPerToken: 1_000, outputNanoUsdPerToken: 16_000)
                ]
            ),

            // 2. GPT-5.5 系列
            PricingModelEntry(
                modelKey: "gpt-5.5",
                aliases: ["gpt-5.5", "gpt-5.5-codex", "gpt-5.5-preview"],
                rules: [
                    PricingRuleEntry(ruleId: "gpt-5.5-std", serviceTier: nil, effectiveFromMs: 0, inputNanoUsdPerToken: 2_000, cachedNanoUsdPerToken: 500, outputNanoUsdPerToken: 8_000)
                ]
            ),

            // 3. GPT-5.4 系列
            PricingModelEntry(
                modelKey: "gpt-5.4",
                aliases: ["gpt-5.4", "gpt-5.4-codex"],
                rules: [
                    PricingRuleEntry(ruleId: "gpt-5.4-std", serviceTier: nil, effectiveFromMs: 0, inputNanoUsdPerToken: 1_500, cachedNanoUsdPerToken: 375, outputNanoUsdPerToken: 6_000)
                ]
            ),
            PricingModelEntry(
                modelKey: "gpt-5.4-mini",
                aliases: ["gpt-5.4-mini", "gpt-5.4-nano"],
                rules: [
                    PricingRuleEntry(ruleId: "gpt-5.4-mini-std", serviceTier: nil, effectiveFromMs: 0, inputNanoUsdPerToken: 250, cachedNanoUsdPerToken: 62, outputNanoUsdPerToken: 1_000)
                ]
            ),

            // 4. GPT-5.3 系列
            PricingModelEntry(
                modelKey: "gpt-5.3-codex",
                aliases: ["gpt-5.3-codex", "gpt-5.3"],
                rules: [
                    PricingRuleEntry(ruleId: "gpt-5.3-codex-std", serviceTier: nil, effectiveFromMs: 0, inputNanoUsdPerToken: 1_250, cachedNanoUsdPerToken: 312, outputNanoUsdPerToken: 5_000)
                ]
            ),
            PricingModelEntry(
                modelKey: "gpt-5.3-codex-spark",
                aliases: ["gpt-5.3-codex-spark", "codex-spark"],
                rules: [
                    PricingRuleEntry(ruleId: "gpt-5.3-spark-std", serviceTier: nil, effectiveFromMs: 0, inputNanoUsdPerToken: 500, cachedNanoUsdPerToken: 125, outputNanoUsdPerToken: 2_000)
                ]
            ),

            // 5. Codex 自动化评审模型
            PricingModelEntry(
                modelKey: "codex-auto-review",
                aliases: ["codex-auto-review", "auto-review"],
                rules: [
                    PricingRuleEntry(ruleId: "codex-auto-review-std", serviceTier: nil, effectiveFromMs: 0, inputNanoUsdPerToken: 1_000, cachedNanoUsdPerToken: 250, outputNanoUsdPerToken: 4_000)
                ]
            ),

            // 6. GPT-5.2 / GPT-5.1 历史模型
            PricingModelEntry(
                modelKey: "gpt-5.2",
                aliases: ["gpt-5.2", "gpt-5.2-codex"],
                rules: [
                    PricingRuleEntry(ruleId: "gpt-5.2-std", serviceTier: nil, effectiveFromMs: 0, inputNanoUsdPerToken: 1_750, cachedNanoUsdPerToken: 437, outputNanoUsdPerToken: 7_000)
                ]
            ),
            PricingModelEntry(
                modelKey: "gpt-5.1-codex",
                aliases: ["gpt-5.1-codex", "gpt-5.1", "gpt-5.1-codex-max"],
                rules: [
                    PricingRuleEntry(ruleId: "gpt-5.1-codex-std", serviceTier: nil, effectiveFromMs: 0, inputNanoUsdPerToken: 2_500, cachedNanoUsdPerToken: 625, outputNanoUsdPerToken: 10_000)
                ]
            ),
            PricingModelEntry(
                modelKey: "gpt-5.1-codex-mini",
                aliases: ["gpt-5.1-codex-mini"],
                rules: [
                    PricingRuleEntry(ruleId: "gpt-5.1-mini-std", serviceTier: nil, effectiveFromMs: 0, inputNanoUsdPerToken: 300, cachedNanoUsdPerToken: 75, outputNanoUsdPerToken: 1_200)
                ]
            ),

            // 7. 标准基准 GPT-5 (通用兜底)
            PricingModelEntry(
                modelKey: "gpt-5",
                aliases: ["gpt-5", "codex", "default"],
                rules: [
                    PricingRuleEntry(ruleId: "gpt-5-std", serviceTier: nil, effectiveFromMs: 0, inputNanoUsdPerToken: 2_000, cachedNanoUsdPerToken: 500, outputNanoUsdPerToken: 8_000)
                ]
            )
        ]
    )
}
