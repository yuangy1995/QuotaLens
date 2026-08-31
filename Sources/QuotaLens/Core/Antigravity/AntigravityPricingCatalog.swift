import Foundation

enum AntigravityPricingCatalog {
    static let version = "2026-08-antigravity-v1"

    // 标准 API Token 列表价，不包含订阅费、搜索调用或缓存存储费用。
    // https://ai.google.dev/gemini-api/docs/pricing
    // https://ai.google.dev/gemini-api/docs/changelog
    // https://blog.google/innovation-and-ai/models-and-research/gemini-models/gemini-3-6-flash-3-5-flash-lite-3-5-flash-cyber/
    // https://cloud.google.com/gemini-enterprise-agent-platform/generative-ai/pricing
    private static let promotionFromMs: Int64 = 1_786_579_200_000 // 2026-08-13 UTC
    private static let promotionToMs: Int64 = 1_798_761_600_000 // 2027-01-01 UTC

    private static let geminiModels: [PricingModelEntry] = [
        PricingModelEntry(
            modelKey: "gemini-3.7-flash",
            rules: flashRules(model: "gemini-3.7-flash", releasedAtMs: promotionFromMs)
        ),
        PricingModelEntry(
            modelKey: "gemini-3.6-flash",
            rules: flashRules(model: "gemini-3.6-flash", releasedAtMs: 1_784_592_000_000)
        ),
        PricingModelEntry(modelKey: "gemini-3.5-flash", rules: [
            PricingRuleEntry(
                ruleId: "gemini-3.5-flash-standard-v1",
                effectiveFromMs: 1_779_148_800_000, // 2026-05-19 UTC
                inputNanoUsdPerToken: 1_500,
                cachedNanoUsdPerToken: 150,
                outputNanoUsdPerToken: 9_000
            )
        ]),
        PricingModelEntry(
            modelKey: "gemini-3.1-pro",
            aliases: ["gemini-3.1-pro-preview", "gemini-3.1-pro-preview-customtools"],
            rules: [PricingRuleEntry(
                ruleId: "gemini-3.1-pro-standard-v1",
                effectiveFromMs: 1_771_459_200_000, // 2026-02-19 UTC
                inputNanoUsdPerToken: 2_000,
                cachedNanoUsdPerToken: 200,
                outputNanoUsdPerToken: 12_000,
                longContextThresholdTokens: 200_000,
                longContextInputMultiplierPpm: 2_000_000,
                longContextOutputMultiplierPpm: 1_500_000
            )]
        )
    ]

    private static let snapshot = PricingCatalogSnapshot(
        catalogVersion: version,
        aliases: Dictionary(uniqueKeysWithValues: geminiModels.flatMap { entry in
            entry.aliases.map { ($0, entry.modelKey) }
        }),
        rulesByModel: Dictionary(uniqueKeysWithValues: geminiModels.map { ($0.modelKey, $0.rules) })
    )

    private static func flashRules(model: String, releasedAtMs: Int64) -> [PricingRuleEntry] {
        var rules: [PricingRuleEntry] = []
        if releasedAtMs < promotionFromMs {
            rules.append(PricingRuleEntry(
                ruleId: "\(model)-launch-v1",
                effectiveFromMs: releasedAtMs,
                effectiveToMs: promotionFromMs,
                inputNanoUsdPerToken: 1_500,
                cachedNanoUsdPerToken: 150,
                outputNanoUsdPerToken: 7_500
            ))
        }
        rules.append(PricingRuleEntry(
            ruleId: "\(model)-introductory-v1",
            effectiveFromMs: promotionFromMs,
            effectiveToMs: promotionToMs,
            inputNanoUsdPerToken: 750,
            cachedNanoUsdPerToken: 75,
            outputNanoUsdPerToken: 3_750
        ))
        rules.append(PricingRuleEntry(
            ruleId: "\(model)-standard-v1",
            effectiveFromMs: promotionToMs,
            inputNanoUsdPerToken: 1_500,
            cachedNanoUsdPerToken: 150,
            outputNanoUsdPerToken: 7_500
        ))
        return rules
    }

    static func resolveModel(rawModel: String, displayName: String?) -> String {
        for name in [rawModel, displayName].compactMap({ $0 }) {
            let normalized = normalizedModel(name)
            if snapshot.rulesByModel[normalized] != nil {
                return normalized
            }
            if let canonical = snapshot.aliases[normalized] {
                return canonical
            }
            if let entry = ClaudeBundledPricingCatalog.entries.first(where: {
                normalizedModel($0.modelKey) == normalized
            }) {
                return entry.modelKey
            }
        }
        // 内部实验模型只有在记录同时提供可识别的显示名称时才计价。
        return ModelAliasResolver.resolve(rawModel: rawModel)
    }

    private static func normalizedModel(_ name: String) -> String {
        var normalized = ModelAliasResolver.resolve(rawModel: name)
            .replacingOccurrences(of: "^models/", with: "", options: .regularExpression)
            .replacingOccurrences(
                of: #"(?:-?\((?:minimal|low|medium|high|thinking)\)|-(?:minimal|low|medium|high|thinking))$"#,
                with: "",
                options: .regularExpression
            )
        if normalized.hasPrefix("claude-") {
            normalized = normalized
                .replacingOccurrences(of: ".", with: "-")
                .replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        }
        return normalized
    }

    static func evaluate(
        modelCanonical: String,
        timestampMs: Int64,
        tokens: TokenBreakdown
    ) -> PricingEvaluationResult {
        if ClaudeBundledPricingCatalog.entries.contains(where: { $0.modelKey == modelCanonical }) {
            let price = ClaudePricingCatalogService.evaluate(
                modelRaw: modelCanonical,
                uncachedInput: tokens.uncachedInputTokens,
                cachedInput: tokens.cachedInputTokens,
                cacheWrite5m: tokens.cacheWriteInputTokens,
                cacheWrite1h: 0,
                output: tokens.outputTokens
            )
            return PricingEvaluationResult(
                estimatedCost: price.cost,
                pricingStatus: price.status,
                pricingRuleId: price.ruleID,
                catalogVersion: ClaudeBundledPricingCatalog.version
            )
        }
        return snapshot.evaluate(
            modelCanonical: modelCanonical,
            serviceTier: nil,
            timestampMs: timestampMs,
            tokens: tokens
        )
    }
}
