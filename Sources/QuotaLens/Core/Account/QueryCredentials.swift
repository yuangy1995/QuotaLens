import Foundation

enum QueryAccountError: Error, Equatable {
    case authorization, format, unavailable, storage, identity
    case credentialMissing, expired, wrongProvider, unsupported, tooLarge, busy
}

/// Imported credentials may share a refresh-token chain with another client.
/// Renewal is coordinated by the account store and never writes to that client.
struct QueryCredential: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let isGCPToS: Bool
    var idToken: String? = nil
    var oauthClientKey: String? = nil

    var effectiveExpiry: Date? {
        let jwt = (Self.claims(accessToken)["exp"] as? Double).map(Date.init(timeIntervalSince1970:))
        return [expiresAt, jwt].compactMap { $0 }.min()
    }
    var hasRefreshToken: Bool { refreshToken?.isEmpty == false }
    func needsRefresh(now: Date = Date()) -> Bool {
        accessToken.isEmpty || effectiveExpiry.map { $0 <= now.addingTimeInterval(300) } == true
    }

    static func parse(_ data: Data, provider: UsageProvider) throws -> Self {
        let items = try QueryCredentialTransfer.parse(data, provider: provider)
        guard items.count == 1 else { throw QueryAccountError.format }
        return try items[0].get().credential
    }

    static func claims(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return [:] }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    func checkExpiry() throws {
        if accessToken.isEmpty { throw QueryAccountError.expired }
        if let expiry = effectiveExpiry, expiry <= Date() { throw QueryAccountError.expired }
    }
}

enum QueryCredentialVault {
    static func save(_ credential: QueryCredential, id: UUID) throws {
        try LocalCredentialStore.applicationStore.save(credential, id: id.uuidString)
    }
    static func load(id: UUID) throws -> QueryCredential {
        do { return try LocalCredentialStore.applicationStore.load(QueryCredential.self, id: id.uuidString) }
        catch let error as QueryAccountError { throw error }
        catch { throw QueryAccountError.storage }
    }
    static func remove(id: UUID) throws {
        try LocalCredentialStore.applicationStore.remove(id: id.uuidString)
    }
}

struct QueryAccountResult: Sendable {
    let key: String
    let name: String
    let snapshots: [RateLimitSnapshotRecord]
}

struct QueryCredentialClient: Sendable {
    var session: URLSession = .shared

    func resetCreditHistory(_ credential: QueryCredential, accountKey: String, cursor: String? = nil) async throws -> ResetCreditHistoryPage {
        try credential.checkExpiry()
        let auth = QueryCredential.claims(credential.accessToken)["https://api.openai.com/auth"] as? [String: Any]
        guard let id = auth?["chatgpt_account_id"] as? String,
              AccountIdentity.stableAccountKey(from: id) == accountKey else { throw QueryAccountError.identity }
        var url = URLComponents(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/history")!
        if let cursor { url.queryItems = [URLQueryItem(name: "cursor", value: cursor)] }
        return try ResetCreditHistoryPage.decode(await get(url.url!.absoluteString, credential: credential, accountID: id))
    }

    private func get(_ url: String, credential: QueryCredential, accountID: String? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if url.contains("anthropic.com") {
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        }
        if let accountID { request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw QueryAccountError.unavailable }
        if http.statusCode == 401 { throw QueryAccountError.authorization }
        // A 403 can be policy, scope or a transient upstream refusal, not necessarily a revoked credential.
        guard http.statusCode == 200 else { throw QueryAccountError.unavailable }
        return data
    }

    func fetch(_ credential: QueryCredential, provider: UsageProvider) async throws -> QueryAccountResult {
        try credential.checkExpiry()
        let now = Int64(Date().timeIntervalSince1970)
        switch provider {
        case .codex:
            // Claims are only used as identity after the server accepts the access token.
            let claims = QueryCredential.claims(credential.accessToken)
            let auth = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
            guard let id = auth["chatgpt_account_id"] as? String, !id.isEmpty else { throw QueryAccountError.format }
            let data = try await get("https://chatgpt.com/backend-api/wham/usage", credential: credential, accountID: id)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rate = root["rate_limit"] as? [String: Any] else { throw QueryAccountError.format }
            let key = AccountIdentity.stableAccountKey(from: id)
            var rows: [RateLimitSnapshotRecord] = []
            for (slot, field) in [("primary", "primary_window"), ("secondary", "secondary_window")] {
                guard let window = rate[field] as? [String: Any],
                      let used = window["used_percent"] as? Double, used.isFinite else { continue }
                rows.append(.init(accountKey: key, observedAt: now, limitId: "codex", slot: slot,
                    usedPercentMilli: Int(min(100, max(0, used)) * 1000),
                    windowDurationMins: (window["limit_window_seconds"] as? Int).map { $0 / 60 },
                    resetsAt: (window["reset_at"] as? Int64), planType: root["plan_type"] as? String,
                    rawJson: String(data: data, encoding: .utf8) ?? "{}"))
            }
            guard !rows.isEmpty else { throw QueryAccountError.format }
            let profile = claims["https://api.openai.com/profile"] as? [String: Any]
            return .init(key: key, name: profile?["email"] as? String ?? id, snapshots: rows)
        case .claude:
            let profileData = try await get("https://api.anthropic.com/api/oauth/profile", credential: credential)
            guard let profile = try JSONSerialization.jsonObject(with: profileData) as? [String: Any],
                  let account = profile["account"] as? [String: Any],
                  let id = account["uuid"] as? String, !id.isEmpty else { throw QueryAccountError.identity }
            let key = AccountIdentity.stableAccountKey(from: id)
            let data = try await get("https://api.anthropic.com/api/oauth/usage", credential: credential)
            let usage = try ClaudeUsageClient.decode(data, capturedAt: Date(), accountKey: key,
                identityConfidence: .stableProviderID, accountAliases: [])
            let windows = [usage.fiveHour, usage.sevenDay].compactMap { $0 } + usage.scopedWeekly
            guard !windows.isEmpty else { throw QueryAccountError.format }
            let rows = windows.map { window in
                RateLimitSnapshotRecord(accountKey: key, observedAt: now, limitId: window.title, slot: window.id,
                    usedPercentMilli: Int(window.usedPercent * 1000), windowDurationMins: Int(window.windowDuration / 60),
                    resetsAt: Int64(window.resetAt.timeIntervalSince1970), planType: usage.tier, rawJson: "{}")
            }
            return .init(key: key, name: account["email"] as? String ?? account["email_address"] as? String ?? id,
                         snapshots: rows)
        case .antigravity:
            let local = AntigravityLocalCredentials(
                source: .init(profile: .ide, databaseURL: URL(fileURLWithPath: "/dev/null")),
                legacyAccountKey: "", accessToken: credential.accessToken, refreshToken: "",
                expiresAt: credential.expiresAt, isGCPToS: credential.isGCPToS)
            let quota: AntigravityQuotaSnapshot
            do { quota = try await AntigravityQuotaClient(session: session).fetch(credentials: local, allowRefresh: false) }
            catch AntigravityFetchError.unauthorized { throw QueryAccountError.authorization }
            let rows = quota.groups.flatMap { group in group.buckets.map { bucket in
                let title: String
                switch bucket.window {
                case .fiveHour: title = L10n.text("5 小时额度", "5-hour quota")
                case .weekly: title = L10n.text("周额度", "Weekly quota")
                case .other: title = bucket.title
                }
                return RateLimitSnapshotRecord(accountKey: quota.accountKey, observedAt: now, limitId: group.title + " · " + title, slot: bucket.id,
                    usedPercentMilli: Int((100 - bucket.remainingPercent) * 1000), windowDurationMins: nil,
                    resetsAt: bucket.resetAt.map { Int64($0.timeIntervalSince1970) }, planType: quota.planName, rawJson: "{}")
            } }
            let modelRows = quota.models.map { model in
                RateLimitSnapshotRecord(accountKey: quota.accountKey, observedAt: now, limitId: model.displayName ?? model.id,
                    slot: model.id, usedPercentMilli: Int((100 - model.remainingPercent) * 1000), windowDurationMins: nil,
                    resetsAt: model.resetAt.map { Int64($0.timeIntervalSince1970) }, planType: quota.planName, rawJson: "{}")
            }
            guard !rows.isEmpty || !modelRows.isEmpty else { throw QueryAccountError.format }
            return .init(key: quota.accountKey, name: quota.accountDisplayName ?? quota.accountKey,
                         snapshots: rows.isEmpty ? modelRows : rows)
        }
    }
}
