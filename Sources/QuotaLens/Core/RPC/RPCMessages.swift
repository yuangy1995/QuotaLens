// Codex App Server JSON-RPC 消息与 DTO 协议定义
// 宽松兼容 camelCase/snake_case 与未知字段，避免 Schema 小幅变化导致崩溃。

import Foundation

public struct JSONRPCRequest: Codable, Sendable {
    public var jsonrpc: String = "2.0"
    public let id: Int64
    public let method: String
    public let params: [String: AnyCodable]?

    public init(id: Int64, method: String, params: [String: AnyCodable]? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCResponse: Codable, Sendable {
    public let jsonrpc: String?
    public let id: Int64?
    public let result: AnyCodable?
    public let error: JSONRPCError?
}

public struct JSONRPCNotification: Codable, Sendable {
    public var jsonrpc: String = "2.0"
    public let method: String
    public let params: AnyCodable?

    public init(method: String, params: AnyCodable? = nil) {
        self.method = method
        self.params = params
    }
}

public struct JSONRPCError: Codable, Sendable {
    public let code: Int
    public let message: String
    public let data: AnyCodable?
}

// MARK: - 真实业务 DTO

public struct AccountReadResult: Codable, Sendable {
    public struct AccountInfo: Codable, Sendable {
        public let id: String?
        public let accountId: String?
        public let type: String?
        public let email: String?
        public let planType: String?
        public let subscriptionStartsAt: Int64?
        public let subscriptionEndsAt: Int64?

        public var stableIdentifier: String {
            email ?? accountId ?? id ?? type ?? "chatgpt_user"
        }

        public var displayIdentifier: String {
            email ?? stableIdentifier
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: FlexibleCodingKey.self)
            self.id = try container.decodeIfPresent(String.self, forKeys: ["id"])
            self.accountId = try container.decodeIfPresent(String.self, forKeys: ["accountId", "account_id"])
            self.type = try container.decodeIfPresent(String.self, forKeys: ["type"])
            self.email = try container.decodeIfPresent(String.self, forKeys: ["email"])
            self.planType = try container.decodeIfPresent(String.self, forKeys: ["planType", "plan_type"])
            let subscription = try container.decodeIfPresent(SubscriptionPeriodInfo.self, forKeys: [
                "subscription",
                "currentSubscription",
                "current_subscription",
                "billingPeriod",
                "billing_period",
                "currentPeriod",
                "current_period"
            ])
            self.subscriptionStartsAt = try container.decodeFlexibleEpochSeconds(forKeys: [
                "subscriptionStartsAt",
                "subscription_starts_at",
                "subscriptionStartAt",
                "subscription_start_at",
                "subscriptionStart",
                "subscription_start",
                "currentPeriodStart",
                "current_period_start",
                "periodStart",
                "period_start",
                "startsAt",
                "starts_at"
            ]) ?? subscription?.startsAt
            self.subscriptionEndsAt = try container.decodeFlexibleEpochSeconds(forKeys: [
                "subscriptionEndsAt",
                "subscription_ends_at",
                "subscriptionEndAt",
                "subscription_end_at",
                "subscriptionEnd",
                "subscription_end",
                "currentPeriodEnd",
                "current_period_end",
                "periodEnd",
                "period_end",
                "renewsAt",
                "renews_at",
                "renewalAt",
                "renewal_at",
                "expiresAt",
                "expires_at"
            ]) ?? subscription?.endsAt
        }
    }

    public let account: AccountInfo?
    public let requiresOpenaiAuth: Bool?

    enum CodingKeys: String, CodingKey {
        case account
        case requiresOpenaiAuth = "requiresOpenaiAuth"
    }
}

public struct SubscriptionPeriodInfo: Codable, Sendable {
    public let startsAt: Int64?
    public let endsAt: Int64?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexibleCodingKey.self)
        self.startsAt = try container.decodeFlexibleEpochSeconds(forKeys: [
            "startsAt",
            "starts_at",
            "startAt",
            "start_at",
            "startedAt",
            "started_at",
            "currentPeriodStart",
            "current_period_start",
            "periodStart",
            "period_start"
        ])
        self.endsAt = try container.decodeFlexibleEpochSeconds(forKeys: [
            "endsAt",
            "ends_at",
            "endAt",
            "end_at",
            "endedAt",
            "ended_at",
            "currentPeriodEnd",
            "current_period_end",
            "periodEnd",
            "period_end",
            "renewsAt",
            "renews_at",
            "renewalAt",
            "renewal_at",
            "expiresAt",
            "expires_at"
        ])
    }
}

public struct RateLimitWindowDetail: Codable, Sendable {
    public let usedPercent: Double?
    public let windowDurationMins: Int?
    public let resetsAt: Int64?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexibleCodingKey.self)
        self.usedPercent = try container.decodeFlexibleDouble(forKeys: ["usedPercent", "used_percent"])
        self.windowDurationMins = try container.decodeFlexibleInt(forKeys: ["windowDurationMins", "window_duration_mins", "windowMinutes", "window_minutes"])
        self.resetsAt = try container.decodeFlexibleInt64(forKeys: ["resetsAt", "resets_at"])
    }
}

public struct RateLimitsObject: Codable, Sendable {
    public let limitId: String?
    public let limitName: String?
    public let primary: RateLimitWindowDetail?
    public let secondary: RateLimitWindowDetail?
    public let planType: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexibleCodingKey.self)
        self.limitId = try container.decodeIfPresent(String.self, forKeys: ["limitId", "limit_id"])
        self.limitName = try container.decodeIfPresent(String.self, forKeys: ["limitName", "limit_name"])
        self.primary = try container.decodeIfPresent(RateLimitWindowDetail.self, forKeys: ["primary"])
        self.secondary = try container.decodeIfPresent(RateLimitWindowDetail.self, forKeys: ["secondary"])
        self.planType = try container.decodeIfPresent(String.self, forKeys: ["planType", "plan_type"])
    }
}

public struct RateLimitResetCredit: Codable, Sendable {
    public let id: String?
    public let resetType: String?
    public let status: String?
    public let grantedAt: Int64?
    public let expiresAt: Int64?
    public let title: String?
    public let description: String?

    public init(
        id: String? = nil,
        resetType: String? = nil,
        status: String? = nil,
        grantedAt: Int64? = nil,
        expiresAt: Int64? = nil,
        title: String? = nil,
        description: String? = nil
    ) {
        self.id = id
        self.resetType = resetType
        self.status = status
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.title = title
        self.description = description
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexibleCodingKey.self)
        self.id = try container.decodeIfPresent(String.self, forKeys: ["id", "creditId", "credit_id"])
        self.resetType = try container.decodeIfPresent(String.self, forKeys: ["resetType", "reset_type", "type"])
        self.status = try container.decodeIfPresent(String.self, forKeys: ["status", "state"])
        self.grantedAt = try container.decodeFlexibleEpochSeconds(forKeys: ["grantedAt", "granted_at", "createdAt", "created_at"])
        self.expiresAt = try container.decodeFlexibleEpochSeconds(forKeys: ["expiresAt", "expires_at", "deadline", "resetsAt", "resets_at"])
        self.title = try container.decodeIfPresent(String.self, forKeys: ["title", "name"])
        self.description = try container.decodeIfPresent(String.self, forKeys: ["description", "detail", "summary"])
    }
}

public struct RateLimitResetCreditsObject: Codable, Sendable {
    public let availableCount: Int?
    public let credits: [RateLimitResetCredit]?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexibleCodingKey.self)
        self.availableCount = try container.decodeFlexibleInt(forKeys: ["availableCount", "available_count"])
        self.credits = try container.decodeLossyArrayIfPresent(RateLimitResetCredit.self, forKeys: ["credits"])
    }
}

public struct RateLimitsReadResult: Codable, Sendable {
    public let rateLimits: RateLimitsObject?
    public let rateLimitsByLimitId: [String: RateLimitsObject]?
    public let rateLimitResetCredits: RateLimitResetCreditsObject?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexibleCodingKey.self)
        self.rateLimits = try container.decodeIfPresent(RateLimitsObject.self, forKeys: ["rateLimits", "rate_limits"])
        self.rateLimitsByLimitId = try container.decodeIfPresent([String: RateLimitsObject].self, forKeys: ["rateLimitsByLimitId", "rate_limits_by_limit_id"])
        self.rateLimitResetCredits = try? container.decodeIfPresent(RateLimitResetCreditsObject.self, forKeys: ["rateLimitResetCredits", "rate_limit_reset_credits"])
    }
}

public enum ConsumeRateLimitResetCreditOutcome: String, Codable, Sendable {
    case reset
    case nothingToReset
    case noCredit
    case alreadyRedeemed
}

public struct ConsumeRateLimitResetCreditResponse: Codable, Sendable {
    public let outcome: ConsumeRateLimitResetCreditOutcome

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexibleCodingKey.self)
        self.outcome = try container.decodeIfPresent(ConsumeRateLimitResetCreditOutcome.self, forKeys: ["outcome"])
            ?? .nothingToReset
    }
}

public struct DailyUsageBucketDTO: Codable, Sendable {
    public let startDate: String
    public let tokens: Int64

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexibleCodingKey.self)
        self.startDate = try container.decodeIfPresent(String.self, forKeys: ["startDate", "start_date", "date"]) ?? ""
        self.tokens = try container.decodeFlexibleInt64(forKeys: ["tokens", "totalTokens", "total_tokens"]) ?? 0
    }
}

public struct UsageSummaryDTO: Codable, Sendable {
    public let lifetimeTokens: Int64?
    public let peakDailyTokens: Int64?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexibleCodingKey.self)
        self.lifetimeTokens = try container.decodeFlexibleInt64(forKeys: ["lifetimeTokens", "lifetime_tokens"])
        self.peakDailyTokens = try container.decodeFlexibleInt64(forKeys: ["peakDailyTokens", "peak_daily_tokens"])
    }
}

public struct AccountUsageReadResult: Codable, Sendable {
    public let summary: UsageSummaryDTO?
    public let dailyUsageBuckets: [DailyUsageBucketDTO]?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexibleCodingKey.self)
        self.summary = try container.decodeIfPresent(UsageSummaryDTO.self, forKeys: ["summary"])
        self.dailyUsageBuckets = try container.decodeIfPresent([DailyUsageBucketDTO].self, forKeys: ["dailyUsageBuckets", "daily_usage_buckets", "buckets"])
    }
}

public struct FlexibleCodingKey: CodingKey, Sendable {
    public let stringValue: String
    public let intValue: Int?

    public init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    public init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

private extension KeyedDecodingContainer where Key == FlexibleCodingKey {
    func key(_ names: [String]) -> FlexibleCodingKey? {
        names.compactMap { FlexibleCodingKey(stringValue: $0) }.first { contains($0) }
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKeys names: [String]) throws -> T? {
        guard let key = key(names) else { return nil }
        return try decodeIfPresent(type, forKey: key)
    }

    func decodeFlexibleDouble(forKeys names: [String]) throws -> Double? {
        guard let key = key(names) else { return nil }
        if let double = try? decode(Double.self, forKey: key) { return double }
        if let int = try? decode(Int64.self, forKey: key) { return Double(int) }
        if let string = try? decode(String.self, forKey: key) { return Double(string) }
        return nil
    }

    func decodeFlexibleInt(forKeys names: [String]) throws -> Int? {
        guard let value = try decodeFlexibleInt64(forKeys: names) else { return nil }
        return Int(value)
    }

    func decodeFlexibleInt64(forKeys names: [String]) throws -> Int64? {
        guard let key = key(names) else { return nil }
        if let int = try? decode(Int64.self, forKey: key) { return int }
        if let int = try? decode(Int.self, forKey: key) { return Int64(int) }
        if let double = try? decode(Double.self, forKey: key) { return Int64(double) }
        if let string = try? decode(String.self, forKey: key) { return Int64(string) }
        return nil
    }

    func decodeLossyArrayIfPresent<T: Decodable>(_ type: T.Type, forKeys names: [String]) throws -> [T]? {
        guard let key = key(names), try !decodeNil(forKey: key) else { return nil }
        return try? decode(LossyDecodableArray<T>.self, forKey: key).values
    }

    func decodeFlexibleEpochSeconds(forKeys names: [String]) throws -> Int64? {
        guard let key = key(names) else { return nil }
        if let int = try? decode(Int64.self, forKey: key) { return normalizeEpochSeconds(int) }
        if let int = try? decode(Int.self, forKey: key) { return normalizeEpochSeconds(Int64(int)) }
        if let double = try? decode(Double.self, forKey: key) { return normalizeEpochSeconds(Int64(double)) }
        if let string = try? decode(String.self, forKey: key) {
            if let int = Int64(string) {
                return normalizeEpochSeconds(int)
            }
            if let date = FlexibleDateParser.parse(string) {
                return Int64(date.timeIntervalSince1970)
            }
        }
        return nil
    }

    private func normalizeEpochSeconds(_ value: Int64) -> Int64 {
        abs(value) > 10_000_000_000 ? value / 1_000 : value
    }
}

private struct LossyDecodableArray<Element: Decodable>: Decodable {
    let values: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decodedValues: [Element] = []
        while !container.isAtEnd {
            let elementDecoder = try container.superDecoder()
            if let value = try? Element(from: elementDecoder) {
                decodedValues.append(value)
            }
        }
        self.values = decodedValues
    }
}

private enum FlexibleDateParser {
    static func parse(_ value: String) -> Date? {
        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: value) {
            return date
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }
}

// MARK: - AnyCodable 辅助，支持任意 JSON 动态结构解析
public struct AnyCodable: Codable, Sendable {
    public let value: Sendable

    public init(_ value: Sendable) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int64.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "AnyCodable 无法解码未知类型")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int64:
            try container.encode(int)
        case let int as Int:
            try container.encode(Int64(int))
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Sendable]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Sendable]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encode(String(describing: value))
        }
    }
}
