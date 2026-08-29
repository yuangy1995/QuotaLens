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
}

enum ClaudeBundledPricingCatalog {
    static let version = "2026-08-claude-v1"
    static let publishedAtMs: Int64 = 1_787_875_200_000

    static let entries: [ClaudePricingEntry] = [
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
            aliases: [model],
            inputRate: rate(input),
            cachedRate: rate(cached),
            cacheWrite5mRate: rate(input * Decimal(string: "1.25")!),
            cacheWrite1hRate: rate(input * 2),
            outputRate: rate(output),
            sourceURL: "https://platform.claude.com/docs/en/about-claude/pricing"
        )
    }

    static func resolveModel(_ raw: String) -> String? {
        let normalized = raw.lowercased()
        if let exact = entries.first(where: {
            $0.aliases.contains(normalized) || $0.modelKey == normalized
        }) {
            return exact.modelKey
        }
        return entries
            .sorted { $0.modelKey.count > $1.modelKey.count }
            .first(where: { normalized.hasPrefix($0.modelKey) })?
            .modelKey
    }
}

struct ClaudePricingEvaluation: Sendable {
    let modelCanonical: String
    let cost: MoneyNanoUSD
    let status: PricingStatus
    let ruleID: String?
}

enum ClaudePricingCatalogService {
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
                    ) VALUES (?, ?, 0, NULL, ?, ?, ?, ?, ?, 1, ?);
                    """,
                    bindings: [
                        "\(entry.modelKey)-standard-v1",
                        entry.modelKey,
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
        output: Int64
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
        let pairs: [(Int64, Int64)] = [
            (max(0, uncachedInput), entry.inputRate),
            (max(0, cachedInput), entry.cachedRate),
            (max(0, cacheWrite5m), entry.cacheWrite5mRate),
            (max(0, cacheWrite1h), entry.cacheWrite1hRate),
            (max(0, output), entry.outputRate)
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
            ruleID: "\(canonical)-standard-v1"
        )
    }
}
