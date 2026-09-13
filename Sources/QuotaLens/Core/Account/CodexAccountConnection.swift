// QuotaLens 管理的独立账号连接；不读写正在使用的 Codex 登录目录。
import Foundation

enum CodexAccountConnection {
    static let arguments = ["app-server", "--stdio", "-c", "cli_auth_credentials_store=\"file\""]

    static func environment(homeURL: URL, base: [String: String] = CodexBinaryLocator.augmentedEnvironment()) -> [String: String] {
        var result = base
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_AUTH_JSON", "CODEX_REMOTE_TOKEN"] {
            result.removeValue(forKey: key)
        }
        result["CODEX_HOME"] = homeURL.path
        return result
    }

    static func decode<T: Decodable>(_ response: JSONRPCResponse, as type: T.Type) throws -> T {
        guard response.error == nil, let result = response.result else {
            throw RPCPayloadError.missingResult(method: "account")
        }
        return try JSONDecoder().decode(type, from: JSONEncoder().encode(result))
    }

    static func validatedLoginURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https",
              url.user == nil, url.password == nil,
              ["auth.openai.com", "chatgpt.com", "auth.chatgpt.com"].contains(url.host?.lowercased() ?? "") else { return nil }
        return url
    }
}

struct ManagedCodexAccount: Codable, Identifiable, Sendable {
    var id: String { accountKey }
    let accountKey: String
    let directoryID: UUID
    var name: String
    var source: QueryCredentialSource?
    var status: QueryCredentialStatus?
    var verifiedAt: Date?
    var accessExpiresAt: Date?
    var hasRefreshToken: Bool?

    var canQuery: Bool {
        guard status == .available else { return false }
        if source == .local || source == .imported, let expiry = accessExpiresAt {
            return expiry > Date() || hasRefreshToken == true
        }
        return true
    }
    var statusMessage: String {
        switch status {
        case .available: return canQuery ? L10n.text("已验证", "Verified") : QueryAccountError.expired.userMessage
        case .missingCredentials: return QueryAccountError.credentialMissing.userMessage
        case .accessExpired: return QueryAccountError.expired.userMessage
        case .needsAuthorization: return QueryAccountError.authorization.userMessage
        default: return L10n.text("待验证", "Not verified")
        }
    }
}

enum QueryCredentialSource: String, Codable, Sendable {
    case independent, imported, local
}

enum QueryCredentialStatus: String, Codable, Sendable {
    case available, unverified, needsAuthorization, missingCredentials, accessExpired
}

actor CodexAccountQuotaReader {
    private let repositories: Repositories
    private let fetch: @Sendable (URL) throws -> CodexServerSnapshot
    private let fetchSubscription: @Sendable (URL, String) async -> String?
    init(database: SQLiteDatabase, fetch: @escaping @Sendable (URL) throws -> CodexServerSnapshot = {
        try CodexServerSnapshotClient.fetch(timeoutSeconds: 15, accountHomeURL: $0)
    }, fetchSubscription: @escaping @Sendable (URL, String) async -> String? = { home, key in
        try? await ChatGPTSubscriptionClient.fetch(timeoutSeconds: 3, accountHomeURL: home, expectedAccountKey: key).subscriptionPlan
    }) {
        repositories = Repositories(database: database)
        self.fetch = fetch
        self.fetchSubscription = fetchSubscription
    }

    func cached(accountKey: String) throws -> [RateLimitSnapshotRecord] {
        try repositories.getLatestRateLimitSnapshots(accountKey: accountKey, provider: .codex)
    }

    func refresh(homeURL: URL, expectedAccountKey: String?) async throws -> (String, String, [RateLimitSnapshotRecord]) {
        let snapshot = try fetch(homeURL)
        guard let read = snapshot.account else { throw QueryAccountError.unavailable }
        guard let account = read.account, account.type?.lowercased() == "chatgpt" else { throw QueryAccountError.authorization }
        guard let limits = snapshot.rateLimits else { throw QueryAccountError.unavailable }
        let local = LocalAccountImporter.discoverLocalIdentities(authFile: homeURL.appendingPathComponent("auth.json")).first
        // 服务端有明确账号 ID 时必须与本地授权身份一致，不能只相信文件中的 ID。
        if let identifier = account.accountId ?? account.id, let local,
           AccountIdentity.stableAccountKey(from: identifier) != local.accountKey {
            throw QueryAccountError.identity
        }
        let key = local?.accountKey ?? AccountIdentity.stableAccountKey(from: account.stableIdentifier)
        guard expectedAccountKey == nil || expectedAccountKey == key else {
            throw QueryAccountError.identity
        }
        let subscriptionPlan = await fetchSubscription(homeURL, key)
        let name = account.email ?? local?.displayName ?? account.displayIdentifier
        let now = Int64(snapshot.capturedAt.timeIntervalSince1970)
        var rows: [RateLimitSnapshotRecord] = []
        var groups = limits.rateLimitsByLimitId ?? [:]
        if let primary = limits.rateLimits, groups[primary.limitId ?? "codex"] == nil {
            groups[primary.limitId ?? "codex"] = primary
        }
        for id in groups.keys.sorted() {
            guard let group = groups[id] else { continue }
            for (slot, window) in [("primary", group.primary), ("secondary", group.secondary)] {
                guard let window, let used = window.usedPercent, used.isFinite else { continue }
                rows.append(RateLimitSnapshotRecord(accountKey: key, observedAt: now, limitId: id,
                    slot: slot, usedPercentMilli: Int((min(100, max(0, used)) * 1000).rounded()),
                    windowDurationMins: window.windowDurationMins, resetsAt: window.resetsAt,
                    planType: group.planType ?? account.planType, rawJson: snapshot.rateLimitsRawJson))
            }
        }
        guard !rows.isEmpty else { throw QueryAccountError.unavailable }
        try repositories.db.transaction {
            try repositories.upsertAccount(AccountRecord(accountKey: key,
                emailHash: AccountIdentity.emailHash(from: account.email ?? account.stableIdentifier),
                planType: account.planType, firstSeenAt: now, lastSeenAt: now))
            for row in rows { try repositories.insertRateLimitSnapshot(row) }
            try CodexCapacityStore(database: repositories.db).record(.make(
                accountKey: key, observedAt: now, usage: snapshot.accountUsage, snapshots: rows, subscriptionPlan: subscriptionPlan
            ))
        }
        return (key, name, rows)
    }
}
