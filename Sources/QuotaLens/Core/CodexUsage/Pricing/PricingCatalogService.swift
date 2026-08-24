// QuotaLens 价格目录同步服务与 API 等价价值估算器
// 将官方价格规则同步至 SQLite，并提供精确 nano-USD 计算

import Foundation
import SQLite3

public final class PricingCatalogService: Sendable {
    public static let shared = PricingCatalogService()

    public init() {}

    /// 确保当前版本的价格目录已完整安装至本地数据库
    public func ensureCatalogInstalled(database: SQLiteDatabase) throws {
        let catalog = BundledPricingCatalog.defaultCatalog
        let count = try database.intScalar(
            sql: "SELECT COUNT(*) FROM codex_pricing_catalogs WHERE catalog_version = ?;",
            bindings: [catalog.catalogVersion]
        )

        if count > 0 { return }

        try database.transaction {
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
                    catalog.catalogSha256,
                    "{}"
                ]
            )

            // 将其他目录置为非活跃
            try database.executeUpdate(
                sql: "UPDATE codex_pricing_catalogs SET is_active = 0 WHERE catalog_version != ?;",
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
                            input_usd_nano_per_token, cached_usd_nano_per_token, output_usd_nano_per_token,
                            catalog_version
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                        """,
                        bindings: [
                            rule.ruleId,
                            modelEntry.modelKey,
                            rule.serviceTier,
                            rule.effectiveFromMs,
                            rule.effectiveToMs,
                            rule.inputNanoUsdPerToken,
                            rule.cachedNanoUsdPerToken,
                            rule.outputNanoUsdPerToken,
                            catalog.catalogVersion
                        ]
                    )
                }
            }

            // 递增定价版本代号
            try database.executeUpdate(
                sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('pricing_catalog_generation', unixepoch(), unixepoch());",
                bindings: []
            )
        }
    }

    public func loadSnapshot(database: SQLiteDatabase) throws -> PricingCatalogSnapshot {
        let aliases = try database.executeQuery(
            sql: """
            SELECT alias_pattern, target_model_key
            FROM codex_model_aliases
            ORDER BY catalog_version DESC;
            """
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
                input_usd_nano_per_token, cached_usd_nano_per_token, output_usd_nano_per_token
            FROM codex_pricing_rules
            ORDER BY model_key ASC, effective_from_ms DESC;
            """
        ) { stmt -> (String, PricingRuleEntry) in
            let modelKey = String(cString: sqlite3_column_text(stmt, 0)).lowercased()
            let tier = sqlite3_column_type(stmt, 2) != SQLITE_NULL && sqlite3_column_text(stmt, 2) != nil
                ? String(cString: sqlite3_column_text(stmt, 2)!).lowercased()
                : nil
            let effectiveTo = sqlite3_column_type(stmt, 4) != SQLITE_NULL
                ? sqlite3_column_int64(stmt, 4)
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
                    outputNanoUsdPerToken: sqlite3_column_int64(stmt, 7)
                )
            )
        }

        var rulesByModel: [String: [PricingRuleEntry]] = [:]
        for (modelKey, rule) in ruleRows {
            rulesByModel[modelKey, default: []].append(rule)
        }

        return PricingCatalogSnapshot(aliases: aliasMap, rulesByModel: rulesByModel)
    }

    /// 使用已安装到 SQLite 的版本化价格目录评估单条事件。
    public func evaluate(
        database: SQLiteDatabase,
        modelCanonical: String,
        serviceTier: String?,
        timestampMs: Int64,
        tokens: TokenBreakdown
    ) throws -> PricingEvaluationResult {
        let normalizedModel = modelCanonical.lowercased()
        let aliasedModel = try database.stringScalar(
            sql: """
            SELECT target_model_key
            FROM codex_model_aliases
            WHERE alias_pattern = ?
            ORDER BY catalog_version DESC
            LIMIT 1;
            """,
            bindings: [normalizedModel]
        ) ?? normalizedModel

        let tier = serviceTier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows = try database.executeQuery(
            sql: """
            SELECT rule_id, input_usd_nano_per_token, cached_usd_nano_per_token, output_usd_nano_per_token
            FROM codex_pricing_rules
            WHERE model_key = ?
              AND effective_from_ms <= ?
              AND (effective_to_ms IS NULL OR effective_to_ms > ?)
              AND (service_tier IS NULL OR lower(service_tier) = ?)
            ORDER BY
              CASE
                WHEN ? IS NOT NULL AND lower(service_tier) = ? THEN 0
                WHEN service_tier IS NULL THEN 1
                ELSE 2
              END,
              effective_from_ms DESC
            LIMIT 1;
            """,
            bindings: [aliasedModel, timestampMs, timestampMs, tier, tier, tier]
        ) { stmt -> PricingRuleEntry in
            PricingRuleEntry(
                ruleId: String(cString: sqlite3_column_text(stmt, 0)),
                serviceTier: tier,
                effectiveFromMs: 0,
                effectiveToMs: nil,
                inputNanoUsdPerToken: sqlite3_column_int64(stmt, 1),
                cachedNanoUsdPerToken: sqlite3_column_int64(stmt, 2),
                outputNanoUsdPerToken: sqlite3_column_int64(stmt, 3)
            )
        }

        guard let rule = rows.first else {
            let knownModelCount = try database.intScalar(
                sql: "SELECT COUNT(*) FROM codex_pricing_rules WHERE model_key = ?;",
                bindings: [aliasedModel]
            )
            return PricingEvaluationResult(
                estimatedCost: .zero,
                pricingStatus: knownModelCount > 0 ? .unpricedHistoricalRuleMissing : .unpricedUnknownModel,
                pricingRuleId: nil
            )
        }

        return PricingEvaluator.evaluate(rule: rule, tokens: tokens)
    }
}

// MARK: - 价格估算引擎
public struct PricingCatalogSnapshot: Sendable {
    public let aliases: [String: String]
    public let rulesByModel: [String: [PricingRuleEntry]]

    public init(aliases: [String: String], rulesByModel: [String: [PricingRuleEntry]]) {
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
                pricingRuleId: nil
            )
        }

        let tier = serviceTier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = rules.filter { rule in
            if timestampMs < rule.effectiveFromMs { return false }
            if let to = rule.effectiveToMs, timestampMs >= to { return false }
            guard let ruleTier = rule.serviceTier?.lowercased() else { return true }
            return tier != nil && ruleTier == tier
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
                pricingStatus: .unpricedHistoricalRuleMissing,
                pricingRuleId: nil
            )
        }

        return PricingEvaluator.evaluate(rule: matchedRule, tokens: tokens)
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
}

public struct PricingEvaluationResult: Sendable {
    public let estimatedCost: MoneyNanoUSD
    public let pricingStatus: PricingStatus
    public let pricingRuleId: String?

    public init(estimatedCost: MoneyNanoUSD, pricingStatus: PricingStatus, pricingRuleId: String?) {
        self.estimatedCost = estimatedCost
        self.pricingStatus = pricingStatus
        self.pricingRuleId = pricingRuleId
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
        guard let modelEntry = catalog.models.first(where: { entry in
            entry.modelKey == normalizedModel || entry.aliases.contains(normalizedModel)
        }) else {
            return PricingEvaluationResult(
                estimatedCost: .zero,
                pricingStatus: .unpricedUnknownModel,
                pricingRuleId: nil
            )
        }

        // 2. 匹配规则（按 service_tier 与生效时间）
        let matchedRule = modelEntry.rules.first(where: { rule in
            if let tier = rule.serviceTier {
                if tier.lowercased() != serviceTier?.lowercased() { return false }
            } else if serviceTier != nil && serviceTier?.lowercased() != "standard" && serviceTier?.lowercased() != "default" {
                // 如果事件有特殊 tier，优先不匹配默认规则
                return false
            }

            if timestampMs < rule.effectiveFromMs { return false }
            if let to = rule.effectiveToMs, timestampMs >= to { return false }
            return true
        }) ?? modelEntry.rules.first(where: { $0.serviceTier == nil }) // 降级为默认标准规则

        guard let rule = matchedRule else {
            return PricingEvaluationResult(
                estimatedCost: .zero,
                pricingStatus: .unpricedHistoricalRuleMissing,
                pricingRuleId: nil
            )
        }

        return evaluate(rule: rule, tokens: tokens)
    }

    public static func evaluate(rule: PricingRuleEntry, tokens: TokenBreakdown) -> PricingEvaluationResult {
        let uncachedInput = tokens.uncachedInputTokens
        let cachedInput = tokens.cachedInputTokens
        let output = tokens.outputTokens

        let (inCost, inOverflow) = uncachedInput.multipliedReportingOverflow(by: rule.inputNanoUsdPerToken)
        let (cacheCost, cacheOverflow) = cachedInput.multipliedReportingOverflow(by: rule.cachedNanoUsdPerToken)
        let (outCost, outOverflow) = output.multipliedReportingOverflow(by: rule.outputNanoUsdPerToken)

        if inOverflow || cacheOverflow || outOverflow {
            return PricingEvaluationResult(
                estimatedCost: .zero,
                pricingStatus: .unpricedCalculationOverflow,
                pricingRuleId: rule.ruleId
            )
        }

        let (partial, addOverflow) = inCost.addingReportingOverflow(cacheCost)
        let (total, totalOverflow) = partial.addingReportingOverflow(outCost)
        if addOverflow || totalOverflow {
            return PricingEvaluationResult(
                estimatedCost: .zero,
                pricingStatus: .unpricedCalculationOverflow,
                pricingRuleId: rule.ruleId
            )
        }

        return PricingEvaluationResult(
            estimatedCost: MoneyNanoUSD(total),
            pricingStatus: .priced,
            pricingRuleId: rule.ruleId
        )
    }
}
