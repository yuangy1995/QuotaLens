// QuotaLens 预测引擎模型定义与评估结果 (Forecast Models)

import Foundation

// MARK: - 预测置信度
public enum ForecastConfidence: String, Hashable, Sendable {
    case high = "high"
    case medium = "medium"
    case low = "low"
    case insufficientData = "insufficientData"

    public var localizedDescription: String {
        switch self {
        case .high: return L10n.text("高置信度", "High confidence")
        case .medium: return L10n.text("中等置信度", "Medium confidence")
        case .low: return L10n.text("低置信度 (波动较大)", "Low confidence (volatile)")
        case .insufficientData: return L10n.text("数据样本不足", "Insufficient data")
        }
    }
}

// MARK: - 服务器配额耗尽风险级别
public enum QuotaForecastRisk: String, Hashable, Sendable {
    case critical = "critical"      // 预计在重置日前提前耗尽
    case warning = "warning"        // 消耗速率偏快 (Pace > 1.25)
    case onTrack = "onTrack"        // 匀速消耗 (0.75 <= Pace <= 1.25)
    case underPaced = "underPaced"  // 消耗平缓，额度充足 (Pace < 0.75)
    case insufficientData = "insufficientData"

    public var localizedTitle: String {
        switch self {
        case .critical: return L10n.text("预计提前耗尽", "Exhaustion Expected")
        case .warning: return L10n.text("消耗过快", "Accelerated Pace")
        case .onTrack: return L10n.text("节奏均衡", "On Track")
        case .underPaced: return L10n.text("额度充裕", "Quota Abundant")
        case .insufficientData: return L10n.text("数据收集中", "Collecting Data")
        }
    }
}

// MARK: - 服务器在线额度预测 DTO
public struct QuotaForecastDTO: Sendable {
    public let risk: QuotaForecastRisk
    public let confidence: ForecastConfidence
    public let burnRatePercentPerHour: Double
    public let paceRatio: Double
    public let estimatedExhaustionDate: Date?
    public let naturalResetDate: Date?
    public let hoursUntilExhaustion: Double?
    public let projectedRemainingAtReset: Double? // 0%~100%
    public let samplePointsCount: Int

    public init(
        risk: QuotaForecastRisk = .insufficientData,
        confidence: ForecastConfidence = .insufficientData,
        burnRatePercentPerHour: Double = 0.0,
        paceRatio: Double = 1.0,
        estimatedExhaustionDate: Date? = nil,
        naturalResetDate: Date? = nil,
        hoursUntilExhaustion: Double? = nil,
        projectedRemainingAtReset: Double? = nil,
        samplePointsCount: Int = 0
    ) {
        self.risk = risk
        self.confidence = confidence
        self.burnRatePercentPerHour = burnRatePercentPerHour
        self.paceRatio = paceRatio
        self.estimatedExhaustionDate = estimatedExhaustionDate
        self.naturalResetDate = naturalResetDate
        self.hoursUntilExhaustion = hoursUntilExhaustion
        self.projectedRemainingAtReset = projectedRemainingAtReset
        self.samplePointsCount = samplePointsCount
    }
}

// MARK: - 本机未来用量趋势预测 DTO
public struct LocalUsageForecastDTO: Sendable {
    public let daysHorizon: Int
    public let projectedTotalTokens: Int64
    public let projectedTotalCost: MoneyNanoUSD
    public let confidence: ForecastConfidence
    public let dailyProjections: [DailyProjectionPoint]

    public struct DailyProjectionPoint: Identifiable, Sendable {
        public var id: String { dayKey.yyyyMMdd }
        public let dayKey: LocalDayKey
        public let date: Date
        public let p50Tokens: Int64
        public let p10Tokens: Int64
        public let p90Tokens: Int64
        public let p50Cost: MoneyNanoUSD
    }

    public init(
        daysHorizon: Int = 7,
        projectedTotalTokens: Int64 = 0,
        projectedTotalCost: MoneyNanoUSD = .zero,
        confidence: ForecastConfidence = .insufficientData,
        dailyProjections: [DailyProjectionPoint] = []
    ) {
        self.daysHorizon = daysHorizon
        self.projectedTotalTokens = projectedTotalTokens
        self.projectedTotalCost = projectedTotalCost
        self.confidence = confidence
        self.dailyProjections = dailyProjections
    }
}
