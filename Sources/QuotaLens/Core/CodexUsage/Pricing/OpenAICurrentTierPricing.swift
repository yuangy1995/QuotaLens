import Foundation

extension HistoricalPricingCatalog {
    // 现行特殊档位的原始页面只证明核对日价格；未核实的更早时期不回填。
    private static let currentTierRules: [PricingRuleEntry] = [
            rule("gpt-5.5-pro", from: verifiedOn, input: 15.00, cached: 0, output: 90.00, tier: "batch", maximum: 272_000),
            rule("gpt-5.4-pro", from: verifiedOn, input: 15.00, cached: 0, output: 90.00, tier: "batch", threshold: 272_000),
            rule("gpt-5.2-pro", from: verifiedOn, input: 10.50, cached: 0, output: 84.00, tier: "batch"),
            rule("gpt-5.1", from: verifiedOn, input: 0.625, cached: 0.0625, output: 5.00, tier: "batch"),
            rule("gpt-5-mini", from: verifiedOn, input: 0.125, cached: 0.0125, output: 1.00, tier: "batch"),
            rule("gpt-5-nano", from: verifiedOn, input: 0.025, cached: 0.0025, output: 0.20, tier: "batch"),
            rule("gpt-5-pro", from: verifiedOn, input: 7.50, cached: 0, output: 60.00, tier: "batch"),
            rule("gpt-4.1", from: verifiedOn, input: 1.00, cached: 0, output: 4.00, tier: "batch"),
            rule("gpt-4.1-mini", from: verifiedOn, input: 0.20, cached: 0, output: 0.80, tier: "batch"),
            rule("gpt-4.1-nano", from: verifiedOn, input: 0.05, cached: 0, output: 0.20, tier: "batch"),
            rule("o1-pro", from: verifiedOn, input: 75.00, cached: 0, output: 300.00, tier: "batch"),
            rule("o3-pro", from: verifiedOn, input: 10.00, cached: 0, output: 40.00, tier: "batch"),
            rule("o3", from: verifiedOn, input: 1.00, cached: 0, output: 4.00, tier: "batch"),
            rule("o4-mini", from: verifiedOn, input: 0.55, cached: 0, output: 2.20, tier: "batch"),
            rule("o3-mini", from: verifiedOn, input: 0.55, cached: 0, output: 2.20, tier: "batch"),
            rule("gpt-5.5-pro", from: verifiedOn, input: 15.00, cached: 0, output: 90.00, tier: "flex", maximum: 272_000),
            rule("gpt-5.4-pro", from: verifiedOn, input: 15.00, cached: 0, output: 90.00, tier: "flex", threshold: 272_000),
            rule("gpt-5.1", from: verifiedOn, input: 0.625, cached: 0.0625, output: 5.00, tier: "flex"),
            rule("gpt-5-mini", from: verifiedOn, input: 0.125, cached: 0.0125, output: 1.00, tier: "flex"),
            rule("gpt-5-nano", from: verifiedOn, input: 0.025, cached: 0.0025, output: 0.20, tier: "flex"),
            rule("o3", from: verifiedOn, input: 1.00, cached: 0.25, output: 4.00, tier: "flex"),
            rule("o4-mini", from: verifiedOn, input: 0.55, cached: 0.1375, output: 2.20, tier: "flex"),
            rule("gpt-5.1", from: verifiedOn, input: 2.50, cached: 0.25, output: 20.00, tier: "fast"),
            rule("gpt-5-mini", from: verifiedOn, input: 0.45, cached: 0.045, output: 3.60, tier: "fast"),
            rule("gpt-4.1", from: verifiedOn, input: 3.50, cached: 0.875, output: 14.00, tier: "fast"),
            rule("gpt-4.1-mini", from: verifiedOn, input: 0.70, cached: 0.175, output: 2.80, tier: "fast"),
            rule("gpt-4.1-nano", from: verifiedOn, input: 0.20, cached: 0.05, output: 0.80, tier: "fast"),
            rule("o3", from: verifiedOn, input: 3.50, cached: 0.875, output: 14.00, tier: "fast"),
            rule("o4-mini", from: verifiedOn, input: 2.00, cached: 0.50, output: 8.00, tier: "fast"),
    ]

    static func addingCurrentTiers(to model: PricingModelEntry) -> PricingModelEntry {
        let rules = currentTierRules.filter { $0.ruleId.hasPrefix(model.modelKey + "-") }
            .filter { rule in
                // 以完整模型 ID 匹配，避免 gpt-4.1 吸收 mini/nano 的规则。
                rule.ruleId == "\(model.modelKey)-\(rule.serviceTier!)-\(verifiedOn)-v7"
            }
        return PricingModelEntry(modelKey: model.modelKey, aliases: model.aliases,
                                 rules: model.rules + rules,
                                 sourceURLs: Array(Set((model.sourceURLs ?? []) + ["https://developers.openai.com/api/docs/pricing"])).sorted())
    }
}
