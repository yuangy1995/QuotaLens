// QuotaLens 价格目录同步服务与 API 等价价值估算器
// 将官方价格规则同步至 SQLite，并提供精确 nano-USD 计算

import Foundation
import CryptoKit
import SQLite3

public final class PricingCatalogService: Sendable {
    public static let shared = PricingCatalogService()

    public init() {}

    /// 确保当前版本的价格目录已完整安装至本地数据库
    public func ensureCatalogInstalled(database: SQLiteDatabase) throws {
        let catalog = BundledPricingCatalog.defaultCatalog
        let rawJSON = try Self.rawJSONString(for: catalog)
        let catalogSHA = Self.sha256Hex(rawJSON)
        let installedSHA = try database.stringScalar(
            sql: "SELECT catalog_sha256 FROM codex_pricing_catalogs WHERE catalog_version = ?;",
            bindings: [catalog.catalogVersion]
        )

        if installedSHA == catalogSHA {
            try database.transaction {
                try database.executeUpdate(
                    sql: "UPDATE codex_pricing_catalogs SET is_active = CASE WHEN catalog_version = ? THEN 1 ELSE 0 END;",
                    bindings: [catalog.catalogVersion]
                )
                try database.executeUpdate(
                    sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('pricing_catalog_generation', ?, unixepoch());",
                    bindings: [catalog.catalogVersion]
                )
            }
            return
        }

        try database.transaction {
            // A same-version row with a different digest is incomplete or from
            // an unpublished developer build. Repair that version atomically;
            // released older versions remain immutable and untouched.
            try database.executeUpdate(
                sql: "DELETE FROM codex_model_aliases WHERE catalog_version = ?;",
                bindings: [catalog.catalogVersion]
            )
            try database.executeUpdate(
                sql: "DELETE FROM codex_pricing_rules WHERE catalog_version = ?;",
                bindings: [catalog.catalogVersion]
            )
            // 1. 插入价格目录
            try database.executeUpdate(
                sql: """
                INSERT OR REPLACE INTO codex_pricing_catalogs (
                    catalog_version, schema_version, published_at, catalog_sha256, is_active, raw_json
                ) VALUES (?, ?, ?, ?, 1, ?);
                """,
                bindings: [
                    catalog.catalogVersion,
                    catalog.schemaVersion,
                    catalog.publishedAt,
                    catalogSHA,
                    rawJSON
                ]
            )

            // 将其他目录置为非活跃
            try database.executeUpdate(
                sql: "UPDATE codex_pricing_catalogs SET is_active = CASE WHEN catalog_version = ? THEN 1 ELSE 0 END;",
                bindings: [catalog.catalogVersion]
            )

            // 2. 插入别名与规则
            for modelEntry in catalog.models {
                for alias in modelEntry.aliases {
                    try database.executeUpdate(
                        sql: """
                        INSERT OR REPLACE INTO codex_model_aliases (
                            alias_pattern, target_model_key, match_type, catalog_version
                        ) VALUES (?, ?, 'exact', ?);
                        """,
                        bindings: [alias.lowercased(), modelEntry.modelKey, catalog.catalogVersion]
                    )
                }

                for rule in modelEntry.rules {
                    try database.executeUpdate(
                        sql: """
                        INSERT OR REPLACE INTO codex_pricing_rules (
                            rule_id, model_key, service_tier, effective_from_ms, effective_to_ms,
                            input_usd_nano_per_token, cached_usd_nano_per_token, cache_write_usd_nano_per_token,
                            output_usd_nano_per_token, long_context_threshold_tokens,
                            long_context_input_multiplier_ppm, long_context_output_multiplier_ppm,
                            catalog_version
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                        """,
                        bindings: [
                            rule.ruleId,
                            modelEntry.modelKey,
                            rule.serviceTier,
                            rule.effectiveFromMs,
                            rule.effectiveToMs,
                            rule.inputNanoUsdPerToken,
                            rule.cachedNanoUsdPerToken,
                            rule.cacheWriteNanoUsdPerToken,
                            rule.outputNanoUsdPerToken,
                            rule.longContextThresholdTokens,
                            rule.longContextInputMultiplierPpm,
                            rule.longContextOutputMultiplierPpm,
                            catalog.catalogVersion
                        ]
                    )
                }
            }

            // 递增定价版本代号
            try database.executeUpdate(
                sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('pricing_catalog_generation', ?, unixepoch());",
                bindings: [catalog.catalogVersion]
            )
        }
    }

    public func loadSnapshot(database: SQLiteDatabase) throws -> PricingCatalogSnapshot {
        let activeCatalog = try activeCatalogVersion(database: database)

        let aliases = try database.executeQuery(
            sql: """
            SELECT alias_pattern, target_model_key
            FROM codex_model_aliases
            WHERE catalog_version = ?
            ORDER BY alias_pattern ASC;
            """,
            bindings: [activeCatalog]
        ) { stmt -> (String, String) in
            (
                String(cString: sqlite3_column_text(stmt, 0)).lowercased(),
                String(cString: sqlite3_column_text(stmt, 1)).lowercased()
            )
        }

        var aliasMap: [String: String] = [:]
        for (alias, target) in aliases where aliasMap[alias] == nil {
            aliasMap[alias] = target
        }

        let ruleRows = try database.executeQuery(
            sql: """
            SELECT
                model_key, rule_id, service_tier, effective_from_ms, effective_to_ms,
                input_usd_nano_per_token, cached_usd_nano_per_token,
                cache_write_usd_nano_per_token, output_usd_nano_per_token,
                long_context_threshold_tokens, long_context_input_multiplier_ppm,
                long_context_output_multiplier_ppm
            FROM codex_pricing_rules
            WHERE catalog_version = ?
            ORDER BY model_key ASC, effective_from_ms DESC;
            """,
            bindings: [activeCatalog]
        ) { stmt -> (String, PricingRuleEntry) in
            let modelKey = String(cString: sqlite3_column_text(stmt, 0)).lowercased()
            let tier = sqlite3_column_type(stmt, 2) != SQLITE_NULL && sqlite3_column_text(stmt, 2) != nil
                ? String(cString: sqlite3_column_text(stmt, 2)!).lowercased()
                : nil
            let effectiveTo = sqlite3_column_type(stmt, 4) != SQLITE_NULL
                ? sqlite3_column_int64(stmt, 4)
                : nil
            let cacheWrite = sqlite3_column_type(stmt, 7) != SQLITE_NULL
                ? sqlite3_column_int64(stmt, 7)
                : nil
            let longThreshold = sqlite3_column_type(stmt, 9) != SQLITE_NULL
                ? sqlite3_column_int64(stmt, 9)
                : nil
            let longInputMultiplier = sqlite3_column_type(stmt, 10) != SQLITE_NULL
                ? sqlite3_column_int64(stmt, 10)
                : nil
            let longOutputMultiplier = sqlite3_column_type(stmt, 11) != SQLITE_NULL
                ? sqlite3_column_int64(stmt, 11)
                : nil
            return (
                modelKey,
                PricingRuleEntry(
                    ruleId: String(cString: sqlite3_column_text(stmt, 1)),
                    serviceTier: tier,
                    effectiveFromMs: sqlite3_column_int64(stmt, 3),
                    effectiveToMs: effectiveTo,
                    inputNanoUsdPerToken: sqlite3_column_int64(stmt, 5),
                    cachedNanoUsdPerToken: sqlite3_column_int64(stmt, 6),
                    cacheWriteNanoUsdPerToken: cacheWrite,
                    outputNanoUsdPerToken: sqlite3_column_int64(stmt, 8),
                    longContextThresholdTokens: longThreshold,
                    longContextInputMultiplierPpm: longInputMultiplier,
                    longContextOutputMultiplierPpm: longOutputMultiplier
                )
            )
        }

        var rulesByModel: [String: [PricingRuleEntry]] = [:]
        for (modelKey, rule) in ruleRows {
            rulesByModel[modelKey, default: []].append(rule)
        }

        return PricingCatalogSnapshot(catalogVersion: activeCatalog, aliases: aliasMap, rulesByModel: rulesByModel)
    }

    /// 使用已安装到 SQLite 的版本化价格目录评估单条事件。
    public func evaluate(
        database: SQLiteDatabase,
        modelCanonical: String,
        serviceTier: String?,
        timestampMs: Int64,
        tokens: TokenBreakdown
    ) throws -> PricingEvaluationResult {
        try loadSnapshot(database: database).evaluate(
            modelCanonical: modelCanonical,
            serviceTier: serviceTier,
            timestampMs: timestampMs,
            tokens: tokens
        )
    }

    private func activeCatalogVersion(database: SQLiteDatabase) throws -> String {
        if let active = try database.stringScalar(
            sql: "SELECT catalog_version FROM codex_pricing_catalogs WHERE is_active = 1 ORDER BY published_at DESC LIMIT 1;"
        ) {
            return active
        }
        return BundledPricingCatalog.currentVersion
    }

    private static func rawJSONString(for catalog: PricingCatalogModel) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(catalog)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 价格估算引擎
public struct PricingCatalogSnapshot: Sendable {
    public let catalogVersion: String
    public let aliases: [String: String]
    public let rulesByModel: [String: [PricingRuleEntry]]

    public init(catalogVersion: String, aliases: [String: String], rulesByModel: [String: [PricingRuleEntry]]) {
        self.catalogVersion = catalogVersion
        self.aliases = aliases
        self.rulesByModel = rulesByModel
    }

    public func evaluate(
        modelCanonical: String,
        serviceTier: String?,
        timestampMs: Int64,
        tokens: TokenBreakdown
    ) -> PricingEvaluationResult {
        let normalizedModel = modelCanonical.lowercased()
        let modelKey = aliases[normalizedModel] ?? normalizedModel

        guard let rules = rulesByModel[modelKey] else {
            return PricingEvaluationResult(
                estimatedCost: .zero,
                pricingStatus: .unpricedUnknownModel,
                pricingRuleId: nil,
                catalogVersion: catalogVersion
            )
        }

        let tier = Self.normalizedServiceTier(serviceTier)
        let candidates = rules.filter { rule in
            if timestampMs < rule.effectiveFromMs { return false }
            if let to = rule.effectiveToMs, timestampMs >= to { return false }
            let ruleTier = Self.normalizedServiceTier(rule.serviceTier)
            return ruleTier == tier
        }

        let matchedRule = candidates.sorted { lhs, rhs in
            let lhsPriority = rulePriority(lhs, requestedTier: tier)
            let rhsPriority = rulePriority(rhs, requestedTier: tier)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return lhs.effectiveFromMs > rhs.effectiveFromMs
        }.first

        guard let matchedRule else {
            return PricingEvaluationResult(
                estimatedCost: .zero,
                pricingStatus: tier == nil
                    ? .unpricedHistoricalRuleMissing
                    : .unpricedUnsupportedServiceMode,
                pricingRuleId: nil,
                catalogVersion: catalogVersion
            )
        }

        return PricingEvaluator.evaluate(rule: matchedRule, tokens: tokens, catalogVersion: catalogVersion)
    }

    private func rulePriority(_ rule: PricingRuleEntry, requestedTier: String?) -> Int {
        if let requestedTier,
           let ruleTier = rule.serviceTier?.lowercased(),
           ruleTier == requestedTier {
            return 0
        }
        if rule.serviceTier == nil { return 1 }
        return 2
    }

    private static func normalizedServiceTier(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty || ["auto", "default", "standard"].contains(normalized) {
            return nil
        }
        // API responses report priority even when callers request fast.
        return normalized == "fast" ? "priority" : normalized
    }
}

public struct PricingEvaluationResult: Sendable {
    public let estimatedCost: MoneyNanoUSD
    public let pricingStatus: PricingStatus
    public let pricingRuleId: String?
    public let catalogVersion: String?

    public init(
        estimatedCost: MoneyNanoUSD,
        pricingStatus: PricingStatus,
        pricingRuleId: String?,
        catalogVersion: String? = nil
    ) {
        self.estimatedCost = estimatedCost
        self.pricingStatus = pricingStatus
        self.pricingRuleId = pricingRuleId
        self.catalogVersion = catalogVersion
    }
}

public enum PricingEvaluator {
    /// 评估单条事件的 API 等价价值
    public static func evaluate(
        modelCanonical: String,
        serviceTier: String?,
        timestampMs: Int64,
        tokens: TokenBreakdown
    ) -> PricingEvaluationResult {
        let catalog = BundledPricingCatalog.defaultCatalog
        let normalizedModel = modelCanonical.lowercased()

        // 1. 匹配模型条目
        guard catalog.models.contains(where: { entry in
            entry.modelKey == normalizedModel || entry.aliases.contains(normalizedModel)
        }) else {
            return PricingEvaluationResult(
                estimatedCost: .zero,
                pricingStatus: .unpricedUnknownModel,
                pricingRuleId: nil,
                catalogVersion: catalog.catalogVersion
            )
        }

        let aliases = Dictionary(uniqueKeysWithValues: catalog.models.flatMap { entry in
            entry.aliases.map { ($0.lowercased(), entry.modelKey.lowercased()) }
        })
        let rules = Dictionary(grouping: catalog.models.flatMap { entry in
            entry.rules.map { (entry.modelKey.lowercased(), $0) }
        }, by: { $0.0 }).mapValues { $0.map(\.1) }
        return PricingCatalogSnapshot(
            catalogVersion: catalog.catalogVersion,
            aliases: aliases,
            rulesByModel: rules
        ).evaluate(
            modelCanonical: modelCanonical,
            serviceTier: serviceTier,
            timestampMs: timestampMs,
            tokens: tokens
        )
    }

    public static func evaluate(
        rule: PricingRuleEntry,
        tokens: TokenBreakdown,
        catalogVersion: String? = nil
    ) -> PricingEvaluationResult {
        let uncachedInput = tokens.uncachedInputTokens
        let cachedInput = tokens.cachedInputTokens
        let output = tokens.outputTokens
        let longContext = rule.longContextThresholdTokens.map { tokens.inputTokens > $0 } ?? false
        let inputRate = longContext
            ? scaledRate(rule.inputNanoUsdPerToken, ppm: rule.longContextInputMultiplierPpm)
            : rule.inputNanoUsdPerToken
        let cachedRate = longContext
            ? scaledRate(rule.cachedNanoUsdPerToken, ppm: rule.longContextInputMultiplierPpm)
            : rule.cachedNanoUsdPerToken
        let outputRate = longContext
            ? scaledRate(rule.outputNanoUsdPerToken, ppm: rule.longContextOutputMultiplierPpm)
            : rule.outputNanoUsdPerToken

        let (inCost, inOverflow) = uncachedInput.multipliedReportingOverflow(by: inputRate)
        let (cacheCost, cacheOverflow) = cachedInput.multipliedReportingOverflow(by: cachedRate)
        let (outCost, outOverflow) = output.multipliedReportingOverflow(by: outputRate)

        if inOverflow || cacheOverflow || outOverflow {
            return PricingEvaluationResult(
                estimatedCost: .zero,
                pricingStatus: .unpricedCalculationOverflow,
                pricingRuleId: rule.ruleId,
                catalogVersion: catalogVersion
            )
        }

        let (partial, addOverflow) = inCost.addingReportingOverflow(cacheCost)
        let (total, totalOverflow) = partial.addingReportingOverflow(outCost)
        if addOverflow || totalOverflow {
            return PricingEvaluationResult(
                estimatedCost: .zero,
                pricingStatus: .unpricedCalculationOverflow,
                pricingRuleId: rule.ruleId,
                catalogVersion: catalogVersion
            )
        }

        return PricingEvaluationResult(
            estimatedCost: MoneyNanoUSD(total),
            pricingStatus: .priced,
            pricingRuleId: rule.ruleId,
            catalogVersion: catalogVersion
        )
    }

    private static func scaledRate(_ rate: Int64, ppm: Int64?) -> Int64 {
        guard let ppm else { return rate }
        let scaled = (Decimal(rate) * Decimal(ppm)) / Decimal(1_000_000)
        return NSDecimalNumber(decimal: scaled).int64Value
    }
}
