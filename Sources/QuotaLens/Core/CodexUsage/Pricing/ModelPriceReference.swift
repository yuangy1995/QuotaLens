// 参考目录与自动计价严格分离：非 Token 单位永不进入对话费用计算。
import Foundation

struct ModelPriceReference: Codable, Identifiable, Sendable {
    var id: String { provider + ":" + modelID }
    let provider: String
    let modelID: String
    let category: String
    let rates: [ReferencePriceRate]
    let sourceURL: String
}

struct ReferencePriceRate: Codable, Sendable {
    let metric: String
    let usd: String
    let unit: String
    let condition: String
}

enum ModelPriceReferenceCatalog {
    static let verifiedOn = "2026-09-07"
    static let entries: [ModelPriceReference] = try! JSONDecoder().decode(
        [ModelPriceReference].self, from: Data(referenceJSON.utf8)
    )
}
