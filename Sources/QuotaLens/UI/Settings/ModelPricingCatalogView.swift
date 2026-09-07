import SwiftUI

struct ModelPricingCatalogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var provider = ""

    private struct Item: Identifiable, Sendable {
        var id: String { provider + ":" + model }
        let provider: String
        let model: String
        let aliases: [String]
        let rules: [PricingRuleEntry]
        let reference: [ReferencePriceRate]
        let sources: [String]
        let automatic: Bool
    }

    private static let items: [Item] = {
        var result = [("OpenAI", BundledPricingCatalog.defaultCatalog.models),
                      ("Google", AntigravityPricingCatalog.geminiModels)].flatMap { provider, entries in
            entries.map { entry in
                Item(provider: provider, model: entry.modelKey, aliases: entry.aliases, rules: entry.rules,
                     reference: [], sources: entry.sourceURLs ?? [provider == "OpenAI"
                        ? "https://developers.openai.com/api/docs/pricing" : "https://ai.google.dev/gemini-api/docs/pricing"], automatic: true)
            }
        }
        result += ClaudeBundledPricingCatalog.entries.map { entry in
            Item(provider: "Anthropic", model: entry.modelKey, aliases: entry.aliases, rules: [], reference: [
                rate("input", entry.inputRate), rate("cached", entry.cachedRate),
                rate("cache_write_5m", entry.cacheWrite5mRate), rate("cache_write_1h", entry.cacheWrite1hRate),
                rate("output", entry.outputRate)
            ], sources: [entry.sourceURL, "https://platform.claude.com/docs/en/release-notes/overview"], automatic: true)
        }
        result += ModelPriceReferenceCatalog.entries.map { entry in
            Item(provider: entry.provider, model: entry.modelID, aliases: [], rules: [], reference: entry.rates,
                 sources: [entry.sourceURL], automatic: false)
        }
        return result.sorted { ($0.provider, $0.model) < ($1.provider, $1.model) }
    }()

    private var filtered: [Item] {
        Self.items.filter { item in
            (provider.isEmpty || item.provider == provider)
                && (search.isEmpty || ([item.model] + item.aliases).contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.text("模型价格目录", "Model Price Catalog")).font(.title2.bold())
                Spacer()
                Text(ModelPriceReferenceCatalog.verifiedOn).foregroundStyle(.secondary)
                Button(L10n.text("关闭", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(L10n.text(
                "对话按已核实规则估算 API 等价价值，不代表订阅扣费。非对话价格仅供参考；待核实项不会计为免费。",
                "Conversation costs use verified API-equivalent rates, not subscription charges. Non-conversation prices are reference only; unverified prices are not free."
            )).font(.callout).foregroundStyle(.secondary)
            Text(L10n.text(
                "目录覆盖不等于全部历史价格已核实。Claude 与 Gemini 的自动估算采用标准全球文本费率，不包含音频输入、Fast、地区加价、缓存存储或工具调用。",
                "Catalog coverage does not imply complete historical pricing. Claude and Gemini estimates use standard global text rates, excluding audio input, Fast, regional uplifts, cache storage, and tool calls."
            )).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField(L10n.text("搜索模型或别名", "Search models or aliases"), text: $search).textFieldStyle(.roundedBorder)
                Picker(L10n.text("提供商", "Provider"), selection: $provider) {
                    Text(L10n.text("全部", "All")).tag("")
                    Text("OpenAI").tag("OpenAI")
                    Text("Anthropic").tag("Anthropic")
                    Text("Google").tag("Google")
                }.frame(width: 200)
                Text("\(filtered.count) / \(Self.items.count)").monospacedDigit().foregroundStyle(.secondary)
            }
            List(filtered) { item in
                DisclosureGroup {
                    if !item.aliases.isEmpty { Text(item.aliases.joined(separator: ", ")).font(.caption).textSelection(.enabled) }
                    ForEach(item.rules, id: \.ruleId) { rule in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(date(rule.effectiveFromMs)) → \(rule.effectiveToMs.map(date) ?? "…") · \(rule.serviceTier ?? "standard")")
                                .font(.caption.bold())
                            rateRow(Self.rate("input", rule.inputNanoUsdPerToken, divisor: rule.rateDivisor))
                            if rule.cachedNanoUsdPerToken > 0 { rateRow(Self.rate("cached", rule.cachedNanoUsdPerToken, divisor: rule.rateDivisor)) }
                            if let write = rule.cacheWriteNanoUsdPerToken { rateRow(Self.rate("cache_write", write, divisor: rule.rateDivisor)) }
                            rateRow(Self.rate("output", rule.outputNanoUsdPerToken, divisor: rule.rateDivisor))
                            if let threshold = rule.longContextThresholdTokens {
                                Text("\(metric("input")) > \(threshold): \(metric("input")) ×2 · \(metric("output")) ×1.5").font(.caption)
                            }
                            if let maximum = rule.maximumInputTokens {
                                Text("\(metric("input")) ≤ \(maximum)").font(.caption)
                            }
                        }.padding(.vertical, 5)
                    }
                    ForEach(item.reference.indices, id: \.self) { index in rateRow(item.reference[index]) }
                    ForEach(item.sources, id: \.self) { source in
                        if let url = URL(string: source) { Link(source, destination: url).font(.caption).lineLimit(1) }
                    }
                } label: {
                    HStack {
                        Text(item.model).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Text(item.provider).foregroundStyle(.secondary)
                        Text(item.automatic ? L10n.text("用于估算", "Used for estimates")
                             : item.reference.isEmpty ? L10n.text("待核实", "Unverified") : L10n.text("仅供参考", "Reference only"))
                            .font(.caption).foregroundStyle(item.automatic ? Color.green : Color.orange)
                    }
                }.padding(.vertical, 4)
            }
        }.padding(20).frame(minWidth: 820, idealWidth: 920, minHeight: 600, idealHeight: 720)
    }

    private static func rate(_ metric: String, _ nano: Int64, divisor: Int64 = 1) -> ReferencePriceRate {
        ReferencePriceRate(metric: metric, usd: NSDecimalNumber(decimal: Decimal(nano) / Decimal(divisor) / 1_000).stringValue,
                           unit: "millionTokens", condition: "")
    }

    private func rateRow(_ rate: ReferencePriceRate) -> some View {
        HStack {
            Text(metric(rate.metric))
            if !rate.condition.isEmpty { Text(rate.condition).foregroundStyle(.secondary) }
            Spacer()
            Text("$\(rate.usd) / \(unit(rate.unit))").monospacedDigit()
        }.font(.caption)
    }

    private func date(_ ms: Int64) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1_000).formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }

    private func metric(_ value: String) -> String {
        if value == "estimate" { return L10n.text("参考估算", "Approximate estimate") }
        let parts = value.split(separator: "_", maxSplits: 1).map(String.init)
        if value.hasPrefix("cache_write") { return L10n.text("缓存写入", "Cache write") + (value.hasSuffix("5m") ? " 5m" : value.hasSuffix("1h") ? " 1h" : "") }
        let action = parts[0] == "input" ? L10n.text("输入", "Input") : parts[0] == "cached" ? L10n.text("缓存读取", "Cache read") : L10n.text("输出", "Output")
        guard parts.count == 2 else { return action }
        let category: String
        switch parts[1] {
        case "text": category = L10n.text("文本", "Text")
        case "audio": category = L10n.text("音频", "Audio")
        case "image": category = L10n.text("图片", "Image")
        case "video": category = L10n.text("视频", "Video")
        default: category = parts[1]
        }
        return category + " · " + action
    }

    private func unit(_ value: String) -> String {
        switch value {
        case "millionTokens": return "1M Token"
        case "millionCharacters": return L10n.text("百万字符", "million characters")
        case "minute": return L10n.text("分钟", "minute")
        case "second": return L10n.text("秒", "second")
        case "image": return L10n.text("张图片", "image")
        case "song": return L10n.text("首歌曲", "song")
        default: return value
        }
    }
}
