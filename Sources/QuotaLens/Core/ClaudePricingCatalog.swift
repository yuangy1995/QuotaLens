import Foundation
import CryptoKit

struct ClaudePricingEntry: Codable, Sendable {
    let modelKey: String
    let aliases: [String]
    let inputRate: Int64
    let cachedRate: Int64
    let cacheWrite5mRate: Int64
    let cacheWrite1hRate: Int64
    let outputRate: Int64
    let sourceURL: String
    let effectiveFromMs: Int64
}

enum ClaudeBundledPricingCatalog {
    static let version = "2026-09-claude-v3"
    static let publishedAtMs: Int64 = 1_788_739_200_000 // 2026-09-07

    static let entries: [ClaudePricingEntry] = [
        entry("claude-3-7-sonnet-20250219", input: 3, cached: 0.3, output: 15),
        entry("claude-sonnet-4-20250514", input: 3, cached: 0.3, output: 15),
        entry("claude-opus-4-20250514", input: 15, cached: 1.5, output: 75),
        entry("claude-opus-4-1-20250805", input: 15, cached: 1.5, output: 75),
        entry("claude-fable-5-1", input: 10, cached: 0.25, output: 50),
        entry("claude-mythos-5-1", input: 10, cached: 0.25, output: 50),
        entry("claude-mythos-5", input: 10, cached: 1, output: 50),
        entry("claude-opus-5", input: 5, cached: 0.5, output: 25),
        entry("claude-fable-5", input: 10, cached: 1, output: 50),
        entry("claude-sonnet-5", input: 2, cached: 0.2, output: 10),
        entry("claude-opus-4-8", input: 5, cached: 0.5, output: 25),
        entry("claude-opus-4-7", input: 5, cached: 0.5, output: 25),
        entry("claude-opus-4-6", input: 5, cached: 0.5, output: 25),
        entry("claude-opus-4-5-20251101", input: 5, cached: 0.5, output: 25),
        entry("claude-sonnet-4-6", input: 3, cached: 0.3, output: 15),
        entry("claude-sonnet-4-5-20250929", input: 3, cached: 0.3, output: 15),
        entry("claude-haiku-4-5-20251001", input: 1, cached: 0.1, output: 5)
    ]

    // 已退役型号仍保留用于历史估算，不将模型快照后缀当成公开上线日期。
    private static let releases: [String: String] = [
        "claude-3-7-sonnet-20250219": "2025-02-24",
        "claude-sonnet-4-20250514": "2025-05-22", "claude-opus-4-20250514": "2025-05-22",
        "claude-opus-4-1-20250805": "2025-08-05",
        "claude-sonnet-4-5-20250929": "2025-09-29", "claude-haiku-4-5-20251001": "2025-10-15",
        "claude-opus-4-5-20251101": "2025-11-24", "claude-opus-4-6": "2026-02-05",
        "claude-sonnet-4-6": "2026-02-17", "claude-opus-4-7": "2026-04-16",
        "claude-opus-4-8": "2026-05-28", "claude-fable-5": "2026-06-09",
        "claude-mythos-5": "2026-06-09", "claude-sonnet-5": "2026-06-30",
        "claude-opus-5": "2026-07-24", "claude-fable-5-1": "2026-09-01", "claude-mythos-5-1": "2026-09-01"
    ]

    private static func entry(
        _ model: String,
        input: Decimal,
        cached: Decimal,
        output: Decimal
    ) -> ClaudePricingEntry {
        func rate(_ dollarsPerMillion: Decimal) -> Int64 {
            NSDecimalNumber(decimal: dollarsPerMillion * 1_000).int64Value
        }
        return ClaudePricingEntry(
            modelKey: model,
            aliases: Array(Set([model, model.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)])).sorted(),
            inputRate: rate(input),
            cachedRate: rate(cached),
            cacheWrite5mRate: rate(input * Decimal(string: "1.25")!),
            cacheWrite1hRate: rate(input * 2),
            outputRate: rate(output),
            sourceURL: "https://platform.claude.com/docs/en/about-claude/pricing",
            effectiveFromMs: HistoricalPricingCatalog.day(releases[model]!)
        )
    }

    static func resolveModel(_ raw: String) -> String? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: ".", with: "-")
        if let exact = entries.first(where: {
            $0.aliases.contains(normalized) || $0.modelKey == normalized
        }) {
            return exact.modelKey
        }
        return nil
    }
}

struct ClaudePricingEvaluation: Sendable {
    let modelCanonical: String
    let cost: MoneyNanoUSD
    let status: PricingStatus
    let ruleID: String?
}

enum ClaudePricingCatalogService {
    private static let longContextStandardFrom = HistoricalPricingCatalog.day("2026-03-13")
    private static let legacyLongContextFrom = HistoricalPricingCatalog.day("2025-08-12")
    private static let legacyLongContextTo = HistoricalPricingCatalog.day("2026-04-30")
    static func ensureInstalled(database: SQLiteDatabase) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ClaudeBundledPricingCatalog.entries)
        let raw = String(data: data, encoding: .utf8) ?? "[]"
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        try database.transaction {
            try database.executeUpdate(
                sql: """
                INSERT OR REPLACE INTO claude_pricing_catalogs (
                    catalog_version, published_at, catalog_sha256, is_active, raw_json
                ) VALUES (?, ?, ?, 1, ?);
                """,
                bindings: [ClaudeBundledPricingCatalog.version,
                           ClaudeBundledPricingCatalog.publishedAtMs,
                           digest,
                           raw]
            )
            try database.executeUpdate(
                sql: "UPDATE claude_pricing_catalogs SET is_active = CASE WHEN catalog_version = ? THEN 1 ELSE 0 END;",
                bindings: [ClaudeBundledPricingCatalog.version]
            )
            try database.executeUpdate(
                sql: "DELETE FROM claude_model_aliases WHERE catalog_version = ?;",
                bindings: [ClaudeBundledPricingCatalog.version]
            )
            try database.executeUpdate(
                sql: "DELETE FROM claude_pricing_rules WHERE catalog_version = ?;",
                bindings: [ClaudeBundledPricingCatalog.version]
            )
            for entry in ClaudeBundledPricingCatalog.entries {
                for alias in entry.aliases {
                    try database.executeUpdate(
                        sql: """
                        INSERT OR REPLACE INTO claude_model_aliases (
                            alias_pattern, target_model_key, catalog_version
                        ) VALUES (?, ?, ?);
                        """,
                        bindings: [alias.lowercased(), entry.modelKey, ClaudeBundledPricingCatalog.version]
                    )
                }
                try database.executeUpdate(
                    sql: """
                    INSERT OR REPLACE INTO claude_pricing_rules (
                        rule_id, model_key, effective_from_ms, effective_to_ms,
                        input_usd_nano_per_token, cached_usd_nano_per_token,
                        cache_write_5m_usd_nano_per_token,
                        cache_write_1h_usd_nano_per_token,
                        output_usd_nano_per_token, rate_divisor, catalog_version
                    ) VALUES (?, ?, ?, NULL, ?, ?, ?, ?, ?, 1, ?);
                    """,
                    bindings: [
                        "\(entry.modelKey)-standard-v3",
                        entry.modelKey,
                        entry.effectiveFromMs,
                        entry.inputRate,
                        entry.cachedRate,
                        entry.cacheWrite5mRate,
                        entry.cacheWrite1hRate,
                        entry.outputRate,
                        ClaudeBundledPricingCatalog.version
                    ]
                )
            }
        }
    }

    static func evaluate(
        modelRaw: String,
        uncachedInput: Int64,
        cachedInput: Int64,
        cacheWrite5m: Int64,
        cacheWrite1h: Int64,
        output: Int64,
        timestampMs: Int64 = ClaudeBundledPricingCatalog.publishedAtMs
    ) -> ClaudePricingEvaluation {
        guard let canonical = ClaudeBundledPricingCatalog.resolveModel(modelRaw),
              let entry = ClaudeBundledPricingCatalog.entries.first(where: { $0.modelKey == canonical }) else {
            return ClaudePricingEvaluation(
                modelCanonical: modelRaw.lowercased(),
                cost: .zero,
                status: .unpricedUnknownModel,
                ruleID: nil
            )
        }
        guard timestampMs >= entry.effectiveFromMs else {
            return ClaudePricingEvaluation(modelCanonical: canonical, cost: .zero,
                                           status: .unpricedHistoricalRuleMissing, ruleID: nil)
        }
        let inputParts = [uncachedInput, cachedInput, cacheWrite5m, cacheWrite1h].map { max(0, $0) }
        var totalInput: Int64 = 0
        for part in inputParts {
            let sum = totalInput.addingReportingOverflow(part)
            guard !sum.overflow else {
                return ClaudePricingEvaluation(modelCanonical: canonical, cost: .zero,
                                               status: .unpricedCalculationOverflow, ruleID: nil)
            }
            totalInput = sum.partialValue
        }
        let legacySonnet = ["claude-sonnet-4-20250514", "claude-sonnet-4-5-20250929"].contains(canonical)
        let generation46 = ["claude-opus-4-6", "claude-sonnet-4-6"].contains(canonical)
        let premiumLongContext = totalInput > 200_000 && (legacySonnet
            || (generation46 && timestampMs < longContextStandardFrom))
        if totalInput > 200_000, legacySonnet,
           (timestampMs < legacyLongContextFrom || timestampMs >= legacyLongContextTo) {
            return ClaudePricingEvaluation(modelCanonical: canonical, cost: .zero,
                                           status: .unpricedUnsupportedContextLength, ruleID: nil)
        }
        if totalInput > 200_000, ["claude-3-7-sonnet-20250219", "claude-opus-4-20250514",
                                "claude-opus-4-1-20250805", "claude-opus-4-5-20251101", "claude-haiku-4-5-20251001"].contains(canonical) {
            return ClaudePricingEvaluation(modelCanonical: canonical, cost: .zero,
                                           status: .unpricedUnsupportedContextLength, ruleID: nil)
        }
        let inputMultiplier: Int64 = premiumLongContext ? 2 : 1
        let pairs: [(Int64, Int64)] = [
            (max(0, uncachedInput), entry.inputRate * inputMultiplier),
            (max(0, cachedInput), entry.cachedRate * inputMultiplier),
            (max(0, cacheWrite5m), entry.cacheWrite5mRate * inputMultiplier),
            (max(0, cacheWrite1h), entry.cacheWrite1hRate * inputMultiplier),
            (max(0, output), premiumLongContext ? entry.outputRate * 3 / 2 : entry.outputRate)
        ]
        var total: Int64 = 0
        for (tokens, rate) in pairs {
            let (cost, multipliedOverflow) = tokens.multipliedReportingOverflow(by: rate)
            let (next, addedOverflow) = total.addingReportingOverflow(cost)
            if multipliedOverflow || addedOverflow {
                return ClaudePricingEvaluation(
                    modelCanonical: canonical,
                    cost: .zero,
                    status: .unpricedCalculationOverflow,
                    ruleID: nil
                )
            }
            total = next
        }
        return ClaudePricingEvaluation(
            modelCanonical: canonical,
            cost: MoneyNanoUSD(total),
            status: .priced,
            ruleID: "\(canonical)-standard-v3"
        )
    }
}
