import Foundation

public enum SubscriptionRenewalState: String, Sendable {
    case autoRenews
    case ending
    case changing
    case unknown
}

public struct SubscriptionEntitlementSnapshot: Sendable {
    public let periodStartsAt: Int64?
    public let periodEndsAt: Int64?
    public let planType: String?
    public let subscriptionPlan: String?
    public let planDisplayName: String
    public let renewalState: SubscriptionRenewalState
    public let targetPlanDisplayName: String?
    public let renewsAt: Int64?
    public let expiresAt: Int64?
    public let cancelsAt: Int64?
    public let hasActiveSubscription: Bool?
    public let fetchedAt: Int64
}

public struct ChatGPTSubscriptionClient: Sendable {
    private static let authEndpoint = URL(string: "https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27")!

    public static func fetch(timeoutSeconds: Double = 10.0) async throws -> SubscriptionEntitlementSnapshot {
        let auth = try loadLocalAuth()
        var request = URLRequest(url: authEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutSeconds
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("QuotaLens/\(AppVersion.marketingVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw NSError(domain: "QuotaLens.Subscription", code: -2, userInfo: [NSLocalizedDescriptionKey: L10n.text("订阅接口暂不可用", "Subscription API is temporarily unavailable")])
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = root["accounts"] as? [String: Any],
              let defaultAccount = accounts["default"] as? [String: Any] else {
            throw NSError(domain: "QuotaLens.Subscription", code: -3, userInfo: [NSLocalizedDescriptionKey: L10n.text("订阅接口返回结构不可识别", "Subscription API returned an unrecognized response")])
        }

        let account = defaultAccount["account"] as? [String: Any]
        let entitlement = defaultAccount["entitlement"] as? [String: Any]
        let lastActiveSubscription = defaultAccount["last_active_subscription"] as? [String: Any]

        let planType = string(account?["plan_type"])
        let subscriptionPlan = string(entitlement?["subscription_plan"])
        let targetPlan = scheduledPlanTarget(defaultAccount["scheduled_plan_change"] ?? entitlement?["scheduled_plan_change"])
        let willRenew = bool(lastActiveSubscription?["will_renew"])
        let renewsAt = epochSeconds(entitlement?["renews_at"])
        let expiresAt = epochSeconds(entitlement?["expires_at"])
        let cancelsAt = epochSeconds(entitlement?["cancels_at"])
        let hasActiveSubscription = bool(entitlement?["has_active_subscription"])
        let state = renewalState(willRenew: willRenew, cancelsAt: cancelsAt, targetPlan: targetPlan)
        let periodEnd = preferredPeriodEnd(state: state, renewsAt: renewsAt, expiresAt: expiresAt, cancelsAt: cancelsAt, fallback: auth.subscriptionActiveUntil)

        return SubscriptionEntitlementSnapshot(
            periodStartsAt: auth.subscriptionActiveStart,
            periodEndsAt: periodEnd,
            planType: planType,
            subscriptionPlan: subscriptionPlan,
            planDisplayName: planDisplayName(planType: planType, subscriptionPlan: subscriptionPlan),
            renewalState: state,
            targetPlanDisplayName: targetPlan.map { planDisplayName(planType: nil, subscriptionPlan: $0) },
            renewsAt: renewsAt,
            expiresAt: expiresAt,
            cancelsAt: cancelsAt,
            hasActiveSubscription: hasActiveSubscription,
            fetchedAt: Int64(Date().timeIntervalSince1970)
        )
    }

    public static func localSubscriptionPeriodFromAuth() -> (startsAt: Int64?, endsAt: Int64?) {
        guard let auth = try? loadLocalAuth() else { return (nil, nil) }
        return (auth.subscriptionActiveStart, auth.subscriptionActiveUntil)
    }

    private struct LocalAuth {
        let accessToken: String
        let subscriptionActiveStart: Int64?
        let subscriptionActiveUntil: Int64?
    }

    private static func loadLocalAuth() throws -> LocalAuth {
        let authFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
        let data = try Data(contentsOf: authFile)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty else {
            throw NSError(domain: "QuotaLens.Subscription", code: -1, userInfo: [NSLocalizedDescriptionKey: L10n.text("未找到本地登录凭据", "Local sign-in credentials not found")])
        }

        let idClaims = (tokens["id_token"] as? String).flatMap(jwtClaims)
        let authClaims = idClaims?["https://api.openai.com/auth"] as? [String: Any]

        return LocalAuth(
            accessToken: accessToken,
            subscriptionActiveStart: epochSeconds(authClaims?["chatgpt_subscription_active_start"]),
            subscriptionActiveUntil: epochSeconds(authClaims?["chatgpt_subscription_active_until"])
        )
    }

    private static func jwtClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func renewalState(willRenew: Bool?, cancelsAt: Int64?, targetPlan: String?) -> SubscriptionRenewalState {
        if targetPlan != nil {
            return .changing
        }
        if cancelsAt != nil || willRenew == false {
            return .ending
        }
        if willRenew == true {
            return .autoRenews
        }
        return .unknown
    }

    private static func preferredPeriodEnd(
        state: SubscriptionRenewalState,
        renewsAt: Int64?,
        expiresAt: Int64?,
        cancelsAt: Int64?,
        fallback: Int64?
    ) -> Int64? {
        switch state {
        case .autoRenews:
            return renewsAt ?? fallback ?? expiresAt
        case .ending, .changing:
            return cancelsAt ?? expiresAt ?? renewsAt ?? fallback
        case .unknown:
            return renewsAt ?? fallback ?? expiresAt ?? cancelsAt
        }
    }

    private static func scheduledPlanTarget(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = string(value), !string.isEmpty {
            return string
        }
        guard let object = value as? [String: Any] else { return nil }

        let directKeys = [
            "target_plan", "targetPlan", "target_subscription_plan", "targetSubscriptionPlan",
            "new_plan", "newPlan", "to_plan", "toPlan", "plan", "plan_type", "planType",
            "subscription_plan", "subscriptionPlan"
        ]
        for key in directKeys {
            if let value = string(object[key]), !value.isEmpty {
                return value
            }
        }

        return object
            .sorted { $0.key < $1.key }
            .compactMap { key, value -> String? in
                let lowerKey = key.lowercased()
                guard lowerKey.contains("plan") || lowerKey.contains("tier") || lowerKey.contains("product") else {
                    return nil
                }
                return string(value)
            }
            .first
    }

    private static func planDisplayName(planType: String?, subscriptionPlan: String?) -> String {
        let normalizedSubscriptionPlan = subscriptionPlan.map(normalizedPlanIdentifier)
        let raw = [subscriptionPlan, planType]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        guard !raw.isEmpty else { return L10n.text("未知套餐", "Unknown Plan") }

        if let normalizedSubscriptionPlan {
            if normalizedSubscriptionPlan == "chatgptpro" || normalizedSubscriptionPlan == "chatgptproplan" {
                return "Pro 20x"
            }
            if normalizedSubscriptionPlan.contains("chatgptprolite")
                || normalizedSubscriptionPlan.contains("prolite")
                || (normalizedSubscriptionPlan.contains("pro") && normalizedSubscriptionPlan.contains("lite")) {
                return "Pro 5x"
            }
        }
        if raw.contains("20x") || raw.contains("20_x") || raw.contains("20-x") || raw.contains("max") {
            return "Pro 20x"
        }
        if raw.contains("5x") || raw.contains("5_x") || raw.contains("5-x") {
            return "Pro 5x"
        }
        if raw.contains("pro") {
            return "Pro"
        }
        if raw.contains("plus") {
            return "Plus"
        }
        if raw.contains("team") {
            return "Team"
        }
        if raw.contains("enterprise") {
            return "Enterprise"
        }
        if raw.contains("free") || raw.contains("gratis") {
            return "Free"
        }
        return subscriptionPlan ?? planType ?? L10n.text("未知套餐", "Unknown Plan")
    }

    private static func normalizedPlanIdentifier(_ value: String) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func epochSeconds(_ value: Any?) -> Int64? {
        guard let value else { return nil }
        if let int = value as? Int64 { return normalizeEpochSeconds(int) }
        if let int = value as? Int { return normalizeEpochSeconds(Int64(int)) }
        if let double = value as? Double { return normalizeEpochSeconds(Int64(double)) }
        if let string = value as? String {
            if let int = Int64(string) {
                return normalizeEpochSeconds(int)
            }
            if let date = FlexibleISODateParser.parse(string) {
                return Int64(date.timeIntervalSince1970)
            }
        }
        return nil
    }

    private static func normalizeEpochSeconds(_ value: Int64) -> Int64 {
        abs(value) > 10_000_000_000 ? value / 1_000 : value
    }

    private static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }
}

private enum FlexibleISODateParser {
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
