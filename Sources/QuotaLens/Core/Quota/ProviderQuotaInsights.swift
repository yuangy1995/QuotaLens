import Foundation
import SQLite3

public enum ProviderDataFreshness: Int, Comparable, Sendable {
    case fresh
    case delayed
    case stale
    case unknown

    public static func < (lhs: ProviderDataFreshness, rhs: ProviderDataFreshness) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var localizedTitle: String {
        switch self {
        case .fresh: return L10n.text("数据最新", "Up to date")
        case .delayed: return L10n.text("更新延迟", "Update delayed")
        case .stale: return L10n.text("数据已过期", "Data is stale")
        case .unknown: return L10n.text("等待首次同步", "Waiting for first sync")
        }
    }

    public var symbolName: String {
        switch self {
        case .fresh: return "checkmark.circle.fill"
        case .delayed: return "clock.badge.exclamationmark.fill"
        case .stale: return "exclamationmark.triangle.fill"
        case .unknown: return "ellipsis.circle.fill"
        }
    }

    public static func evaluate(
        capturedAt: Date?,
        refreshInterval: TimeInterval,
        now: Date = Date()
    ) -> ProviderDataFreshness {
        guard let capturedAt else { return .unknown }
        let age = max(0, now.timeIntervalSince(capturedAt))
        if age > refreshInterval * 4 { return .stale }
        if age > refreshInterval * 2 { return .delayed }
        return .fresh
    }
}

public struct ProviderQuotaRefreshResult<Snapshot: Sendable>: Sendable {
    public let snapshot: Snapshot
    public let historySaved: Bool
    public let migrationWarning: Bool
    public let credentialPersistenceWarning: Bool

    public init(
        snapshot: Snapshot,
        historySaved: Bool,
        migrationWarning: Bool = false,
        credentialPersistenceWarning: Bool = false
    ) {
        self.snapshot = snapshot
        self.historySaved = historySaved
        self.migrationWarning = migrationWarning
        self.credentialPersistenceWarning = credentialPersistenceWarning
    }

    public var storageWarningText: String? {
        var warnings: [String] = []
        if !historySaved {
            warnings.append(L10n.text(
                "在线额度已更新，但本地历史记录暂时未保存。",
                "Online quota was updated, but local history was not saved."
            ))
        }
        if migrationWarning {
            warnings.append(L10n.text(
                "额度和新记录已保存，但部分旧记录未能恢复。",
                "Quota and new records were saved, but some older records could not be recovered."
            ))
        }
        if credentialPersistenceWarning {
            warnings.append(L10n.text(
                "Claude 登录信息已临时刷新，但未能保存到系统钥匙串；重启后可能需要重新登录。",
                "Claude sign-in was refreshed temporarily but could not be saved to the system keychain. You may need to sign in again after restarting."
            ))
        }
        return warnings.isEmpty ? nil : warnings.joined(separator: " ")
    }
}

public enum AccountResolutionState: Equatable, Sendable {
    case resolved(String)
    case resolving(previousAccountKey: String)
    case switched(from: String, to: String)
}

public struct ProviderSyncState: Equatable, Sendable {
    public let provider: UsageProvider
    public let lastAttemptAt: Date?
    public let lastSuccessAt: Date?
    public let nextAttemptAt: Date?
    public let cooldownUntil: Date?

    public init(
        provider: UsageProvider,
        lastAttemptAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        nextAttemptAt: Date? = nil,
        cooldownUntil: Date? = nil
    ) {
        self.provider = provider
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.nextAttemptAt = nextAttemptAt
        self.cooldownUntil = cooldownUntil
    }

    public func freshness(refreshInterval: TimeInterval, now: Date = Date()) -> ProviderDataFreshness {
        ProviderDataFreshness.evaluate(
            capturedAt: lastSuccessAt,
            refreshInterval: refreshInterval,
            now: now
        )
    }
}

public struct ProviderQuotaPoolInput: Identifiable, Sendable {
    public let provider: UsageProvider
    public let accountKey: String
    public let limitID: String
    public let slot: String
    public let groupTitle: String
    public let windowTitle: String
    public let usedPercent: Double
    public let windowDurationMins: Int?
    public let resetAt: Date?
    public let capturedAt: Date

    public var id: String {
        "\(provider.rawValue)|\(accountKey)|\(limitID)|\(slot)"
    }

    public init(
        provider: UsageProvider,
        accountKey: String,
        limitID: String,
        slot: String,
        groupTitle: String,
        windowTitle: String,
        usedPercent: Double,
        windowDurationMins: Int?,
        resetAt: Date?,
        capturedAt: Date
    ) {
        self.provider = provider
        self.accountKey = accountKey
        self.limitID = limitID
        self.slot = slot
        self.groupTitle = groupTitle
        self.windowTitle = windowTitle
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.windowDurationMins = windowDurationMins
        self.resetAt = resetAt
        self.capturedAt = capturedAt
    }
}

public struct ProviderQuotaTrendPoint: Identifiable, Sendable {
    public let timestamp: Date
    public let usedPercent: Double

    public var id: Date { timestamp }

    public init(timestamp: Date, usedPercent: Double) {
        self.timestamp = timestamp
        self.usedPercent = usedPercent
    }
}

public struct ProviderQuotaInsight: Identifiable, Sendable {
    public let input: ProviderQuotaPoolInput
    public let forecast: QuotaForecastDTO
    public let freshness: ProviderDataFreshness
    public let sustainableRatePercentPerHour: Double
    public let trendPoints: [ProviderQuotaTrendPoint]

    public var id: String { input.id }
    public var provider: UsageProvider { input.provider }
    public var remainingPercent: Double { max(0, 100 - input.usedPercent) }
    public var risk: QuotaForecastRisk {
        freshness == .stale ? .insufficientData : forecast.risk
    }

    public var rateMultiplier: Double {
        input.windowDurationMins == 300 ? 1 : 24
    }

    public var burnRateForDisplay: Double {
        forecast.burnRatePercentPerHour * rateMultiplier
    }

    public var sustainableRateForDisplay: Double {
        sustainableRatePercentPerHour * rateMultiplier
    }

    public var rateUnitTitle: String {
        input.windowDurationMins == 300
            ? L10n.text("%/小时", "%/hour")
            : L10n.text("%/天", "%/day")
    }

    public var hasUsableForecast: Bool {
        freshness != .stale && forecast.confidence != .insufficientData
    }

    public init(
        input: ProviderQuotaPoolInput,
        forecast: QuotaForecastDTO,
        freshness: ProviderDataFreshness,
        sustainableRatePercentPerHour: Double,
        trendPoints: [ProviderQuotaTrendPoint]
    ) {
        self.input = input
        self.forecast = forecast
        self.freshness = freshness
        self.sustainableRatePercentPerHour = sustainableRatePercentPerHour
        self.trendPoints = trendPoints
    }
}

public enum QuotaRecommendationSeverity: Int, Comparable, Sendable {
    case healthy
    case information
    case warning
    case critical

    public static func < (lhs: QuotaRecommendationSeverity, rhs: QuotaRecommendationSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var symbolName: String {
        switch self {
        case .healthy: return "checkmark.circle.fill"
        case .information: return "info.circle.fill"
        case .warning: return "speedometer"
        case .critical: return "exclamationmark.triangle.fill"
        }
    }
}

public struct QuotaRecommendation: Identifiable, Sendable {
    public let id: String
    public let provider: UsageProvider?
    public let severity: QuotaRecommendationSeverity
    public let title: String
    public let message: String

    public init(
        id: String,
        provider: UsageProvider?,
        severity: QuotaRecommendationSeverity,
        title: String,
        message: String
    ) {
        self.id = id
        self.provider = provider
        self.severity = severity
        self.title = title
        self.message = message
    }
}

struct ProviderQuotaHistoryRecord: Sendable {
    let provider: UsageProvider
    let accountKey: String
    let observedAt: Int64
    let limitID: String
    let slot: String
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int64?
}

enum ProviderQuotaHistoryRepository {
    static func fetch(
        database: SQLiteDatabase,
        provider: UsageProvider,
        accountKey: String,
        since: Date
    ) throws -> [ProviderQuotaHistoryRecord] {
        try database.executeQuery(
            sql: """
            SELECT account_key, observed_at, limit_id, slot, used_percent_milli,
                   window_duration_mins, resets_at
            FROM rate_limit_snapshots
            WHERE provider = ? AND account_key = ? AND observed_at >= ?
            ORDER BY observed_at ASC, id ASC;
            """,
            bindings: [provider.rawValue, accountKey, Int64(since.timeIntervalSince1970)]
        ) { statement in
            let duration = sqlite3_column_type(statement, 5) == SQLITE_NULL
                ? nil
                : Int(sqlite3_column_int64(statement, 5))
            let reset = sqlite3_column_type(statement, 6) == SQLITE_NULL
                ? nil
                : sqlite3_column_int64(statement, 6)
            return ProviderQuotaHistoryRecord(
                provider: provider,
                accountKey: String(cString: sqlite3_column_text(statement, 0)),
                observedAt: sqlite3_column_int64(statement, 1),
                limitID: String(cString: sqlite3_column_text(statement, 2)),
                slot: String(cString: sqlite3_column_text(statement, 3)),
                usedPercent: Double(sqlite3_column_int64(statement, 4)) / 1_000,
                windowDurationMins: duration,
                resetsAt: reset
            )
        }
    }
}

public struct ProviderQuotaInsightsBuildResult: Sendable {
    public let insights: [UsageProvider: [ProviderQuotaInsight]]
    public let storageWarnings: Set<UsageProvider>
}

public actor ProviderQuotaInsightsService {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func build(
        inputs: [ProviderQuotaPoolInput],
        refreshIntervals: [UsageProvider: TimeInterval],
        now: Date = Date()
    ) -> ProviderQuotaInsightsBuildResult {
        let since = now.addingTimeInterval(-TimeInterval(RateLimitSnapshotRetention.retentionSeconds))
        let scopes = Set(inputs.map { "\($0.provider.rawValue)|\($0.accountKey)" })
        var historyByScope: [String: [ProviderQuotaHistoryRecord]] = [:]
        var storageWarnings = Set<UsageProvider>()
        for input in inputs {
            let scope = "\(input.provider.rawValue)|\(input.accountKey)"
            guard scopes.contains(scope), historyByScope[scope] == nil else { continue }
            do {
                historyByScope[scope] = try ProviderQuotaHistoryRepository.fetch(
                    database: database,
                    provider: input.provider,
                    accountKey: input.accountKey,
                    since: since
                )
            } catch {
                historyByScope[scope] = []
                storageWarnings.insert(input.provider)
            }
        }

        var result: [UsageProvider: [ProviderQuotaInsight]] = [:]
        for input in inputs {
            let refreshInterval = refreshIntervals[input.provider] ?? 300
            let freshness = ProviderDataFreshness.evaluate(
                capturedAt: input.capturedAt,
                refreshInterval: refreshInterval,
                now: now
            )
            let resetTimestamp = input.resetAt.map { Int64($0.timeIntervalSince1970) }
            let cycleKey = resetTimestamp.map {
                QuotaForecastEngine.QuotaCycleKey(
                    accountID: input.accountKey,
                    limitID: input.limitID,
                    slot: input.slot,
                    resetAt: $0,
                    windowDurationMins: input.windowDurationMins
                )
            }
            let scope = "\(input.provider.rawValue)|\(input.accountKey)"
            let matchingHistory = (historyByScope[scope] ?? []).filter {
                $0.limitID == input.limitID
                    && $0.slot == input.slot
                    && $0.resetsAt == resetTimestamp
            }
            var enginePoints = matchingHistory.compactMap { record -> QuotaForecastEngine.RateSnapshotPoint? in
                guard let reset = record.resetsAt else { return nil }
                return QuotaForecastEngine.RateSnapshotPoint(
                    timestamp: Date(timeIntervalSince1970: Double(record.observedAt)),
                    usedPercent: record.usedPercent,
                    cycleKey: QuotaForecastEngine.QuotaCycleKey(
                        accountID: record.accountKey,
                        limitID: record.limitID,
                        slot: record.slot,
                        resetAt: reset,
                        windowDurationMins: record.windowDurationMins
                    )
                )
            }
            if let cycleKey {
                enginePoints.append(
                    QuotaForecastEngine.RateSnapshotPoint(
                        timestamp: input.capturedAt,
                        usedPercent: input.usedPercent,
                        cycleKey: cycleKey
                    )
                )
            }
            let forecast: QuotaForecastDTO
            if freshness == .stale {
                forecast = QuotaForecastDTO(
                    risk: .insufficientData,
                    confidence: .insufficientData,
                    naturalResetDate: input.resetAt
                )
            } else {
                forecast = QuotaForecastEngine.forecast(
                    currentUsedPercent: input.usedPercent,
                    resetsAt: resetTimestamp,
                    currentCycleKey: cycleKey,
                    snapshots: enginePoints,
                    now: now
                )
            }
            let hoursUntilReset = input.resetAt.map { max(0, $0.timeIntervalSince(now) / 3_600) } ?? 0
            let sustainableRate = hoursUntilReset > 0
                ? max(0, 100 - input.usedPercent) / hoursUntilReset
                : 0
            let rawTrend = matchingHistory.map {
                ProviderQuotaTrendPoint(
                    timestamp: Date(timeIntervalSince1970: Double($0.observedAt)),
                    usedPercent: $0.usedPercent
                )
            } + [ProviderQuotaTrendPoint(timestamp: input.capturedAt, usedPercent: input.usedPercent)]
            let insight = ProviderQuotaInsight(
                input: input,
                forecast: forecast,
                freshness: freshness,
                sustainableRatePercentPerHour: sustainableRate,
                trendPoints: Self.downsample(rawTrend.sorted { $0.timestamp < $1.timestamp })
            )
            result[input.provider, default: []].append(insight)
        }

        for provider in Array(result.keys) {
            result[provider]?.sort(by: Self.isHigherPriority)
        }
        return ProviderQuotaInsightsBuildResult(insights: result, storageWarnings: storageWarnings)
    }

    private static func isHigherPriority(_ lhs: ProviderQuotaInsight, _ rhs: ProviderQuotaInsight) -> Bool {
        let lhsFreshness = freshnessPriority(lhs.freshness)
        let rhsFreshness = freshnessPriority(rhs.freshness)
        if lhsFreshness != rhsFreshness { return lhsFreshness > rhsFreshness }
        let lhsRisk = riskPriority(lhs.risk)
        let rhsRisk = riskPriority(rhs.risk)
        if lhsRisk != rhsRisk { return lhsRisk > rhsRisk }
        if lhs.remainingPercent != rhs.remainingPercent { return lhs.remainingPercent < rhs.remainingPercent }
        return lhs.input.id < rhs.input.id
    }

    private static func freshnessPriority(_ freshness: ProviderDataFreshness) -> Int {
        switch freshness {
        case .stale: return 3
        case .unknown: return 2
        case .delayed: return 1
        case .fresh: return 0
        }
    }

    private static func riskPriority(_ risk: QuotaForecastRisk) -> Int {
        switch risk {
        case .critical: return 4
        case .warning: return 3
        case .onTrack: return 2
        case .underPaced: return 1
        case .insufficientData: return 0
        }
    }

    private static func downsample(_ points: [ProviderQuotaTrendPoint], maximumCount: Int = 240) -> [ProviderQuotaTrendPoint] {
        var deduplicated: [ProviderQuotaTrendPoint] = []
        for point in points {
            if deduplicated.last?.timestamp == point.timestamp {
                deduplicated[deduplicated.count - 1] = point
            } else {
                deduplicated.append(point)
            }
        }
        guard deduplicated.count > maximumCount else { return deduplicated }
        let stride = max(1, deduplicated.count / (maximumCount - 1))
        var sampled = Swift.stride(from: 0, to: deduplicated.count, by: stride).map { deduplicated[$0] }
        if sampled.last?.timestamp != deduplicated.last?.timestamp, let last = deduplicated.last {
            sampled.append(last)
        }
        return sampled
    }
}

public enum QuotaRecommendationEngine {
    public static func make(
        insights: [UsageProvider: [ProviderQuotaInsight]],
        enabledProviders: Set<UsageProvider>,
        errors: [UsageProvider: String],
        antigravityActivity: AntigravityActivitySnapshot?
    ) -> [QuotaRecommendation] {
        var recommendations: [QuotaRecommendation] = []

        for provider in enabledProviders.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let error = errors[provider], !error.isEmpty {
                recommendations.append(
                    QuotaRecommendation(
                        id: "sync-error-\(provider.rawValue)",
                        provider: provider,
                        severity: .critical,
                        title: L10n.format("%@ needs attention", zhHans: "%@ 需要处理", provider.localizedName),
                        message: error
                    )
                )
                continue
            }
            if insights[provider]?.isEmpty != false {
                recommendations.append(
                    QuotaRecommendation(
                        id: "waiting-\(provider.rawValue)",
                        provider: provider,
                        severity: .information,
                        title: L10n.format("Waiting for %@ quota", zhHans: "等待 %@ 额度", provider.localizedName),
                        message: L10n.text(
                            "首次同步完成后会显示消耗速度和预测。",
                            "Usage pace and forecasts will appear after the first sync."
                        )
                    )
                )
                continue
            }
            if let stale = insights[provider]?.first(where: { $0.freshness == .stale }) {
                recommendations.append(
                    QuotaRecommendation(
                        id: "stale-\(stale.id)",
                        provider: provider,
                        severity: .critical,
                        title: L10n.format("%@ data is stale", zhHans: "%@ 数据已过期", provider.localizedName),
                        message: L10n.text(
                            "预测已暂停，请刷新额度后再判断使用节奏。",
                            "Forecasting is paused. Refresh quota before judging usage pace."
                        )
                    )
                )
            }
        }

        for insight in insights.values.flatMap({ $0 }) {
            switch insight.risk {
            case .critical:
                let isReliable = insight.forecast.confidence == .high || insight.forecast.confidence == .medium
                recommendations.append(
                    QuotaRecommendation(
                        id: "critical-\(insight.id)",
                        provider: insight.provider,
                        severity: isReliable ? .critical : .warning,
                        title: isReliable
                            ? L10n.text("预计会在重置前耗尽", "Expected to run out before reset")
                            : L10n.text("消耗可能偏快", "Usage may be too fast"),
                        message: L10n.format(
                            "%@ · %@ is using quota faster than the sustainable pace.",
                            zhHans: "%@ · %@ 的额度消耗快于可持续速度。",
                            insight.input.groupTitle,
                            insight.input.windowTitle
                        )
                    )
                )
            case .warning:
                recommendations.append(
                    QuotaRecommendation(
                        id: "warning-\(insight.id)",
                        provider: insight.provider,
                        severity: .warning,
                        title: L10n.text("额度消耗偏快", "Quota usage is elevated"),
                        message: L10n.format(
                            "%@ · %@ is %.1fx the sustainable pace.",
                            zhHans: "%@ · %@ 当前是可持续速度的 %.1f 倍。",
                            insight.input.groupTitle,
                            insight.input.windowTitle,
                            insight.forecast.paceRatio
                        )
                    )
                )
            default:
                break
            }
        }

        let antigravityInsights = insights[.antigravity] ?? []
        let grouped = Dictionary(grouping: antigravityInsights) { $0.input.windowDurationMins ?? -1 }
        for (window, values) in grouped where values.count >= 2 {
            guard let lowest = values.min(by: { $0.remainingPercent < $1.remainingPercent }),
                  let highest = values.max(by: { $0.remainingPercent < $1.remainingPercent }),
                  highest.remainingPercent - lowest.remainingPercent >= 20 else { continue }
            recommendations.append(
                QuotaRecommendation(
                    id: "imbalance-\(window)",
                    provider: .antigravity,
                    severity: .information,
                    title: L10n.text("额度池余量不均衡", "Quota pools are imbalanced"),
                    message: L10n.format(
                        "%@ has more room than %@. Use it for flexible work when appropriate.",
                        zhHans: "%@ 比 %@ 余量更充足，适合时可优先用于灵活任务。",
                        highest.input.groupTitle,
                        lowest.input.groupTitle
                    )
                )
            )
        }

        if let activity = antigravityActivity {
            let current = activity.sevenDayMetrics.taskCount
            let previous = activity.previousSevenDayMetrics.taskCount
            if current + previous >= 5 {
                if previous == 0, current >= 5 {
                    recommendations.append(activityIncreaseRecommendation(percent: nil))
                } else if previous > 0 {
                    let change = (Double(current - previous) / Double(previous)) * 100
                    if change >= 25 {
                        recommendations.append(activityIncreaseRecommendation(percent: change))
                    } else if change <= -25 {
                        recommendations.append(
                            QuotaRecommendation(
                                id: "antigravity-activity-down",
                                provider: .antigravity,
                                severity: .information,
                                title: L10n.text("近期活动减少", "Recent activity decreased"),
                                message: L10n.format(
                                    "Antigravity tasks are down %.0f%% from the previous 7 days.",
                                    zhHans: "Antigravity 任务数比前 7 天减少 %.0f%%。",
                                    abs(change)
                                )
                            )
                        )
                    }
                }
            }
        }

        if recommendations.isEmpty, !enabledProviders.isEmpty {
            recommendations.append(
                QuotaRecommendation(
                    id: "all-healthy",
                    provider: nil,
                    severity: .healthy,
                    title: L10n.text("当前使用节奏平稳", "Current usage pace is healthy"),
                    message: L10n.text(
                        "暂未发现需要处理的额度或同步问题。",
                        "No quota or sync issues need attention right now."
                    )
                )
            )
        }

        return recommendations
            .sorted {
                let leftPriority = recommendationPriority($0)
                let rightPriority = recommendationPriority($1)
                if leftPriority != rightPriority { return leftPriority < rightPriority }
                if $0.severity != $1.severity { return $0.severity > $1.severity }
                return $0.id < $1.id
            }
            .reduce(into: [QuotaRecommendation]()) { result, item in
                guard result.count < 3,
                      !result.contains(where: { $0.id == item.id }) else { return }
                result.append(item)
            }
    }

    private static func recommendationPriority(_ recommendation: QuotaRecommendation) -> Int {
        if recommendation.id.hasPrefix("sync-error-")
            || recommendation.id.hasPrefix("stale-")
            || recommendation.id.hasPrefix("waiting-") {
            return 0
        }
        if recommendation.id.hasPrefix("critical-") { return 1 }
        if recommendation.id.hasPrefix("warning-") { return 2 }
        if recommendation.id.hasPrefix("imbalance-") { return 3 }
        if recommendation.id.hasPrefix("antigravity-activity-") { return 4 }
        return 5
    }

    private static func activityIncreaseRecommendation(percent: Double?) -> QuotaRecommendation {
        let message: String
        if let percent {
            message = L10n.format(
                "Antigravity tasks are up %.0f%% from the previous 7 days. Watch quota pace as activity grows.",
                zhHans: "Antigravity 任务数比前 7 天增加 %.0f%%，活动增长时请留意额度速度。",
                percent
            )
        } else {
            message = L10n.text(
                "前 7 天没有任务，本周 Antigravity 活动已经恢复；活动增长时请留意额度速度。",
                "Antigravity activity increased from no tasks in the previous 7 days. Watch quota pace as activity grows."
            )
        }
        return QuotaRecommendation(
            id: "antigravity-activity-up",
            provider: .antigravity,
            severity: .information,
            title: L10n.text("近期活动增加", "Recent activity increased"),
            message: message
        )
    }
}
