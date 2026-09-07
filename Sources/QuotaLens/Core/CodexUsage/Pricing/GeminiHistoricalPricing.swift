import Foundation

extension HistoricalPricingCatalog {
    private static func gemini(_ model: String, from: String, input: Decimal, cached: Decimal,
                               output: Decimal, aliases: [String] = [], threshold: Int64? = nil,
                               cacheHistoryUnverified: Bool = false) -> PricingModelEntry {
        var rules: [PricingRuleEntry] = []
        if cacheHistoryUnverified {
            // 2.5 系列历史缓存折扣曾变化；未核实精确切点前，不回填当前 90% 折扣。
            rules.append(rule(model, from: from, to: verifiedOn, input: input, cached: 0,
                              output: output, threshold: threshold))
        }
        rules.append(rule(model, from: cacheHistoryUnverified ? verifiedOn : from,
                          input: input, cached: cached, output: output, threshold: threshold))
        return PricingModelEntry(modelKey: model, aliases: [model] + aliases, rules: rules,
            sourceURLs: ["https://ai.google.dev/gemini-api/docs/pricing",
                         "https://ai.google.dev/gemini-api/docs/changelog"])
    }

    static let geminiModels: [PricingModelEntry] = [
        PricingModelEntry(modelKey: "gemini-2.0-flash", aliases: ["gemini-2.0-flash", "gemini-2.0-flash-001"], rules: [
            rule("gemini-2.0-flash", from: "2025-02-05", to: "2025-04-16", input: 0.1, cached: 0, output: 0.4),
            rule("gemini-2.0-flash", from: "2025-04-16", input: 0.1, cached: 0.025, output: 0.4)
        ], sourceURLs: ["https://ai.google.dev/gemini-api/docs/pricing?hl=zh-cn",
                        "https://ai.google.dev/gemini-api/docs/changelog"]),
        gemini("gemini-2.0-flash-lite", from: "2025-02-25", input: 0.075, cached: 0, output: 0.3,
               aliases: ["gemini-2.0-flash-lite-001"]),
        gemini("gemini-2.5-pro", from: "2025-06-17", input: 1.25, cached: 0.125, output: 10,
               threshold: 200_000, cacheHistoryUnverified: true),
        gemini("gemini-2.5-flash", from: "2025-06-17", input: 0.3, cached: 0.03, output: 2.5,
               cacheHistoryUnverified: true),
        gemini("gemini-2.5-flash-lite", from: "2025-07-22", input: 0.1, cached: 0.01, output: 0.4,
               cacheHistoryUnverified: true),
        gemini("gemini-3-flash-preview", from: "2025-12-17", input: 0.5, cached: 0.05, output: 3),
        gemini("gemini-3.1-flash-lite", from: "2026-05-07", input: 0.25, cached: 0.025, output: 1.5),
        gemini("gemini-3.5-flash-lite", from: "2026-07-21", input: 0.3, cached: 0.03, output: 2.5),
        gemini("gemini-2.5-computer-use-preview-10-2025", from: "2025-10-07", input: 1.25, cached: 0,
               output: 10, threshold: 200_000),
        gemini("gemini-robotics-er-2-preview", from: "2026-07-30", input: 2, cached: 0.2, output: 10),
        gemini("gemini-robotics-er-1.6-preview", from: verifiedOn, input: 1, cached: 0, output: 5)
    ]
}
