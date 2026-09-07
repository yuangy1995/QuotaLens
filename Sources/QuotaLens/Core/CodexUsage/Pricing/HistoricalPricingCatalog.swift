// 官方文本 Token 费率补充。日期为 API 公开可用日或已核实的价格起点，不是快照训练日期。
import Foundation

enum HistoricalPricingCatalog {
    static let verifiedOn = "2026-09-07"
    static func day(_ date: String) -> Int64 {
        Int64((try! Date(date + "T00:00:00Z", strategy: .iso8601)).timeIntervalSince1970 * 1_000)
    }

    static func rule(_ model: String, from: String, to: String? = nil,
                     input: Decimal, cached: Decimal, output: Decimal,
                     tier: String? = nil, threshold: Int64? = nil,
                     maximum: Int64? = nil, cacheWrite: Decimal? = nil) -> PricingRuleEntry {
        // 微 nano 分子避免 $0.0375 / MTok 等费率提前舍入。
        func rate(_ value: Decimal) -> Int64 { NSDecimalNumber(decimal: value * 1_000_000).int64Value }
        return PricingRuleEntry(
            ruleId: "\(model)-\(tier ?? "standard")-\(from)-v7", serviceTier: tier,
            effectiveFromMs: day(from), effectiveToMs: to.map(day),
            inputNanoUsdPerToken: rate(input), cachedNanoUsdPerToken: rate(cached),
            cacheWriteNanoUsdPerToken: cacheWrite.map(rate), outputNanoUsdPerToken: rate(output),
            rateDivisor: 1_000, maximumInputTokens: maximum,
            longContextThresholdTokens: threshold,
            longContextInputMultiplierPpm: threshold == nil ? nil : 2_000_000,
            longContextOutputMultiplierPpm: threshold == nil ? nil : 1_500_000
        )
    }

    private static func openAI(_ id: String, from: String, input: Decimal, cached: Decimal,
                               output: Decimal, aliases: [String] = [], threshold: Int64? = nil,
                               maximum: Int64? = nil) -> PricingModelEntry {
        PricingModelEntry(modelKey: id, aliases: [id] + aliases, rules: [
            rule(id, from: from, input: input, cached: cached, output: output,
                 threshold: threshold, maximum: maximum, cacheWrite: cached > 0 ? input : nil)
        ], sourceURLs: [["gpt-5-search-api", "gpt-5.5-cyber"].contains(id)
                        ? "https://developers.openai.com/api/docs/pricing"
                        : "https://developers.openai.com/api/docs/models/\(id)",
                        "https://developers.openai.com/api/docs/changelog"])
    }

    static let openAIModels: [PricingModelEntry] = [
        openAI("o3-mini", from: "2025-01-31", input: 1.1, cached: 0.55, output: 4.4,
               aliases: ["o3-mini-2025-01-31"]),
        openAI("gpt-4.5-preview", from: "2025-02-27", input: 75, cached: 37.5, output: 150,
               aliases: ["gpt-4.5-preview-2025-02-27"]),
        openAI("computer-use-preview", from: "2025-03-11", input: 3, cached: 0, output: 12,
               aliases: ["computer-use-preview-2025-03-11"]),
        openAI("gpt-4o-search-preview", from: "2025-03-11", input: 2.5, cached: 0, output: 10,
               aliases: ["gpt-4o-search-preview-2025-03-11"]),
        openAI("gpt-4o-mini-search-preview", from: "2025-03-11", input: 0.15, cached: 0, output: 0.6,
               aliases: ["gpt-4o-mini-search-preview-2025-03-11"]),
        openAI("o1-pro", from: "2025-03-19", input: 150, cached: 0, output: 600,
               aliases: ["o1-pro-2025-03-19"]),
        openAI("gpt-4.1", from: "2025-04-14", input: 2, cached: 0.5, output: 8,
               aliases: ["gpt-4.1-2025-04-14"]),
        openAI("gpt-4.1-mini", from: "2025-04-14", input: 0.4, cached: 0.1, output: 1.6,
               aliases: ["gpt-4.1-mini-2025-04-14"]),
        openAI("gpt-4.1-nano", from: "2025-04-14", input: 0.1, cached: 0.025, output: 0.4,
               aliases: ["gpt-4.1-nano-2025-04-14"]),
        // 官方变更日志确认 6 月 10 日降价；未核实此前列表价，不向前回填现价。
        openAI("o3", from: "2025-06-10", input: 2, cached: 0.5, output: 8,
               aliases: ["o3-2025-04-16"]),
        openAI("o4-mini", from: "2025-04-16", input: 1.1, cached: 0.275, output: 4.4,
               aliases: ["o4-mini-2025-04-16"]),
        openAI("codex-mini-latest", from: "2025-05-15", input: 1.5, cached: 0.375, output: 6),
        openAI("o3-pro", from: "2025-06-10", input: 20, cached: 0, output: 80,
               aliases: ["o3-pro-2025-06-10"]),
        openAI("o3-deep-research", from: "2025-06-26", input: 10, cached: 2.5, output: 40,
               aliases: ["o3-deep-research-2025-06-26"]),
        openAI("o4-mini-deep-research", from: "2025-06-26", input: 2, cached: 0.5, output: 8,
               aliases: ["o4-mini-deep-research-2025-06-26"]),
        openAI("gpt-5-mini", from: "2025-08-07", input: 0.25, cached: 0.025, output: 2,
               aliases: ["gpt-5-mini-2025-08-07"]),
        openAI("gpt-5-nano", from: "2025-08-07", input: 0.05, cached: 0.005, output: 0.4,
               aliases: ["gpt-5-nano-2025-08-07"]),
        openAI("gpt-5-chat-latest", from: "2025-08-07", input: 1.25, cached: 0.125, output: 10),
        openAI("gpt-5.1-chat-latest", from: "2025-11-13", input: 1.25, cached: 0.125, output: 10),
        openAI("gpt-5.2-chat-latest", from: "2025-12-11", input: 1.75, cached: 0.175, output: 14),
        openAI("gpt-5.3-chat-latest", from: "2026-03-03", input: 1.75, cached: 0.175, output: 14),
        openAI("chat-latest", from: verifiedOn, input: 5, cached: 0.5, output: 30),
        openAI("gpt-5-pro", from: "2025-10-06", input: 15, cached: 0, output: 120,
               aliases: ["gpt-5-pro-2025-10-06"]),
        openAI("gpt-5-search-api", from: verifiedOn, input: 1.25, cached: 0.125, output: 10),
        openAI("gpt-5.1", from: "2025-11-13", input: 1.25, cached: 0.125, output: 10,
               aliases: ["gpt-5.1-2025-11-13"]),
        openAI("gpt-5.2-pro", from: "2025-12-11", input: 21, cached: 0, output: 168,
               aliases: ["gpt-5.2-pro-2025-12-11"]),
        openAI("gpt-5.4-pro", from: "2026-03-05", input: 30, cached: 0, output: 180,
               aliases: ["gpt-5.4-pro-2026-03-05"], threshold: 272_000),
        openAI("gpt-5.5-pro", from: "2026-04-24", input: 30, cached: 0, output: 180, threshold: 272_000),
        openAI("gpt-5.5-cyber", from: verifiedOn, input: 12.5, cached: 1.25, output: 75, maximum: 272_000),
        PricingModelEntry(modelKey: "gpt-5.6-cyber", aliases: ["gpt-5.6-cyber"], rules: [
            rule("gpt-5.6-cyber", from: verifiedOn, input: 12.5, cached: 1.25, output: 75,
                 maximum: 272_000, cacheWrite: 15.625)
        ], sourceURLs: ["https://developers.openai.com/api/docs/pricing"])
    ].map(addingCurrentTiers)
}
