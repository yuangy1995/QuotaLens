import Foundation
import Security

struct ClaudeStoredCredentials: Sendable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresAtMs: Double?
    let scopes: [String]?
    let accountKey: String?
}

struct ClaudeRefreshedCredentials: Sendable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresAtMs: Double
}

enum ClaudeOAuthCache {
    private struct Secret: Codable {
        let accessToken: String
        let refreshToken: String?
    }

    private struct Metadata: Codable {
        let version: Int
        let expiresAtMs: Double?
        let scopes: [String]?
        let accountKey: String?
        let keychainAccount: String
    }

    private enum KeychainError: LocalizedError {
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case .status(let status):
                return SecCopyErrorMessageString(status, nil) as String?
            }
        }
    }

    private static let keychainService = "com.quotalens.macos.claude-oauth"

    static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuotaLens", isDirectory: true)
            .appendingPathComponent("claude-oauth-metadata.json")
    }

    private static func legacyURL() -> URL {
        defaultURL().deletingLastPathComponent()
            .appendingPathComponent("claude-oauth.json")
    }

    static func load(from url: URL = defaultURL()) -> ClaudeStoredCredentials? {
        if isDefaultURL(url),
           let legacyData = try? Data(contentsOf: legacyURL()),
           let legacy = ClaudeUsageClient.parseCredentials(legacyData) {
            do {
                try saveStored(legacy, to: url)
                return legacy
            } catch {
                return legacy
            }
        }

        var metadata: Metadata?
        if let data = try? Data(contentsOf: url) {
            if let legacy = ClaudeUsageClient.parseCredentials(data) {
                do {
                    try saveStored(legacy, to: url)
                    return legacy
                } catch {
                    return legacy
                }
            }
            metadata = try? JSONDecoder().decode(Metadata.self, from: data)
        }

        let keychainAccount = metadata?.keychainAccount ?? account(for: url)
        guard let secret = readSecret(account: keychainAccount) else { return nil }
        return ClaudeStoredCredentials(
            accessToken: secret.accessToken,
            refreshToken: secret.refreshToken,
            expiresAtMs: metadata?.expiresAtMs,
            scopes: metadata?.scopes,
            accountKey: metadata?.accountKey
        )
    }

    static func save(
        _ credentials: ClaudeRefreshedCredentials,
        scopes: [String]?,
        accountKey: String,
        fallbackRefreshToken: String,
        to url: URL = defaultURL()
    ) throws {
        try saveStored(
            ClaudeStoredCredentials(
                accessToken: credentials.accessToken,
                refreshToken: credentials.refreshToken ?? fallbackRefreshToken,
                expiresAtMs: credentials.expiresAtMs,
                scopes: scopes,
                accountKey: accountKey
            ),
            to: url
        )
    }

    static func clear(at url: URL = defaultURL()) {
        let metadata = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode(Metadata.self, from: $0) }
        deleteSecret(account: metadata?.keychainAccount ?? account(for: url))
        try? FileManager.default.removeItem(at: url)
        if isDefaultURL(url) {
            try? FileManager.default.removeItem(at: legacyURL())
        }
    }

    private static func saveStored(
        _ credentials: ClaudeStoredCredentials,
        to url: URL
    ) throws {
        let keychainAccount = account(for: url)
        try writeSecret(
            Secret(
                accessToken: credentials.accessToken,
                refreshToken: credentials.refreshToken
            ),
            account: keychainAccount
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Metadata(
            version: 1,
            expiresAtMs: credentials.expiresAtMs,
            scopes: credentials.scopes,
            accountKey: credentials.accountKey,
            keychainAccount: keychainAccount
        ))
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        if isDefaultURL(url) {
            try? FileManager.default.removeItem(at: legacyURL())
        }
    }

    private static func writeSecret(_ secret: Secret, account: String) throws {
        let data = try JSONEncoder().encode(secret)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.status(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData] = data
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.status(addStatus)
        }
    }

    private static func readSecret(account: String) -> Secret? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(Secret.self, from: data)
    }

    private static func deleteSecret(account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func account(for url: URL) -> String {
        if isDefaultURL(url) { return "current" }
        return AccountIdentity.stableAccountKey(
            from: url.standardizedFileURL.path
        )
    }

    private static func isDefaultURL(_ url: URL) -> Bool {
        url.standardizedFileURL == defaultURL().standardizedFileURL
    }
}

actor ClaudeTokenRefresher {
    enum RefreshError: Error {
        case http(Int)
        case malformed
        case transport
    }

    static let endpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private let session: URLSession
    private let endpoint: URL
    private let clientID: String

    init(
        session: URLSession = .shared,
        endpoint: URL = ClaudeTokenRefresher.endpoint,
        clientID: String = ClaudeTokenRefresher.clientID
    ) {
        self.session = session
        self.endpoint = endpoint
        self.clientID = clientID
    }

    func refresh(_ refreshToken: String) async throws -> ClaudeRefreshedCredentials {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formBody([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID)
        ]).utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RefreshError.transport
        }
        guard let http = response as? HTTPURLResponse else {
            throw RefreshError.malformed
        }
        guard http.statusCode == 200 else {
            throw RefreshError.http(http.statusCode)
        }

        struct Wire: Decodable {
            let access_token: String?
            let refresh_token: String?
            let expires_in: Double?
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data),
              let token = wire.access_token,
              !token.isEmpty else {
            throw RefreshError.malformed
        }
        return ClaudeRefreshedCredentials(
            accessToken: token,
            refreshToken: wire.refresh_token,
            expiresAtMs: (Date().timeIntervalSince1970 + (wire.expires_in ?? 28_800)) * 1_000
        )
    }

    static func formBody(_ pairs: [(String, String)]) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        }
        return pairs.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }
}

actor ClaudeUsageClient {
    enum FetchError: Error, Equatable {
        case noCredentials
        case insufficientScope
        case unauthorized
        case rateLimited(retryAfter: TimeInterval?)
        case incompatibleResponse
        case partialResponse
        case unavailable

        var isAuthenticationFailure: Bool {
            switch self {
            case .noCredentials, .insufficientScope, .unauthorized: return true
            case .rateLimited, .incompatibleResponse, .partialResponse, .unavailable: return false
            }
        }
    }

    private static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let session: URLSession
    private let endpoint: URL
    private let cacheURL: URL
    private let tokenRefresher: ClaudeTokenRefresher
    private var memoryToken: String?
    private var memoryAccountKey: String?
    private var rejectedTokens: Set<String> = []
    private var keychainUnavailable = false
    private var refreshTask: Task<ClaudeStoredCredentials?, Never>?
    private var confirmedLegacyAccountKey: String?

    init(
        session: URLSession = .shared,
        endpoint: URL = ClaudeUsageClient.usageEndpoint,
        cacheURL: URL = ClaudeOAuthCache.defaultURL(),
        tokenRefresher: ClaudeTokenRefresher = ClaudeTokenRefresher()
    ) {
        self.session = session
        self.endpoint = endpoint
        self.cacheURL = cacheURL
        self.tokenRefresher = tokenRefresher
    }

    func fetch() async throws -> ClaudeUsageSnapshot {
        try await fetch(retriedAfterUnauthorized: false)
    }

    func clearMemoryToken() {
        memoryToken = nil
        memoryAccountKey = nil
    }

    func activeAccountKey() async -> String? {
        await loadAccessToken()?.accountKey
    }

    func legacyAccountKeyForMigration() -> String? {
        confirmedLegacyAccountKey
    }

    private func fetch(retriedAfterUnauthorized: Bool) async throws -> ClaudeUsageSnapshot {
        guard let credentials = await loadAccessToken() else {
            throw FetchError.noCredentials
        }
        let token = credentials.accessToken
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FetchError.unavailable
        }
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.unavailable
        }
        switch http.statusCode {
        case 200:
            rejectedTokens.removeAll()
            return try Self.decode(data, capturedAt: Date(), accountKey: credentials.accountKey)
        case 401:
            rejectedTokens.insert(token)
            memoryToken = nil
            memoryAccountKey = nil
            if !retriedAfterUnauthorized {
                return try await fetch(retriedAfterUnauthorized: true)
            }
            throw FetchError.unauthorized
        case 403:
            let body = String(data: data, encoding: .utf8)?.lowercased() ?? ""
            throw body.contains("scope") ? FetchError.insufficientScope : FetchError.unauthorized
        case 429:
            throw FetchError.rateLimited(retryAfter: Self.retryAfter(from: http))
        default:
            throw FetchError.unavailable
        }
    }

    private func loadAccessToken() async -> (accessToken: String, accountKey: String)? {
        let cached = ClaudeOAuthCache.load(from: cacheURL)
        var localCredentials: [ClaudeStoredCredentials] = []
        if let file = Self.readClaudeCredentialsFile() {
            localCredentials.append(file)
        }
        if !keychainUnavailable {
            switch Self.readKeychainCredentials(timeout: 2) {
            case .credentials(let credentials):
                localCredentials.append(credentials)
            case .permanentlyUnavailable:
                keychainUnavailable = true
            case .temporarilyUnavailable:
                break
            }
        }

        func resolvedKey(_ credentials: ClaudeStoredCredentials) -> String {
            if let cached, let key = cached.accountKey,
               credentials.accessToken == cached.accessToken
                || (credentials.refreshToken != nil && credentials.refreshToken == cached.refreshToken) {
                return key
            }
            return accountKey(for: credentials)
        }
        guard let active = localCredentials.first ?? cached else {
            clearMemoryToken()
            confirmedLegacyAccountKey = nil
            return nil
        }
        let activeKey = resolvedKey(active)
        let knownKeys = Set(localCredentials.map(resolvedKey))
        confirmedLegacyAccountKey = cached?.accountKey == activeKey
            && knownKeys.isSubset(of: [activeKey]) ? activeKey : nil

        var candidates = localCredentials.filter { resolvedKey($0) == activeKey }
        if let cached, resolvedKey(cached) == activeKey {
            candidates.insert(cached, at: 0)
        }
        if let memoryToken, memoryAccountKey == activeKey, !rejectedTokens.contains(memoryToken) {
            return (memoryToken, activeKey)
        }
        clearMemoryToken()
        for candidate in candidates where Self.isUsable(candidate, rejected: rejectedTokens) {
            memoryToken = candidate.accessToken
            memoryAccountKey = activeKey
            return (candidate.accessToken, activeKey)
        }

        let refreshTokens = candidates.compactMap(\.refreshToken).filter { !$0.isEmpty }
        if let refreshToken = refreshTokens.first,
           let refreshed = await refreshSingleFlight(refreshToken, candidates: candidates) {
            memoryToken = refreshed.accessToken
            memoryAccountKey = activeKey
            return (refreshed.accessToken, activeKey)
        }
        guard let first = candidates.first else { return nil }
        memoryAccountKey = activeKey
        return (first.accessToken, activeKey)
    }

    private func accountKey(for credentials: ClaudeStoredCredentials) -> String {
        credentials.accountKey
            ?? AccountIdentity.stableAccountKey(from: credentials.refreshToken ?? credentials.accessToken)
    }

    private func refreshSingleFlight(
        _ refreshToken: String,
        candidates: [ClaudeStoredCredentials]
    ) async -> ClaudeStoredCredentials? {
        if let refreshTask { return await refreshTask.value }
        let task = Task<ClaudeStoredCredentials?, Never> {
            var seen = Set<String>()
            let ordered = ([refreshToken] + candidates.compactMap(\.refreshToken))
                .filter { seen.insert($0).inserted }
            for token in ordered {
                do {
                    let refreshed = try await self.tokenRefresher.refresh(token)
                    let source = candidates.first(where: { $0.refreshToken == token })
                    let scopes = source?.scopes
                    let stableAccountKey = source.map { self.accountKey(for: $0) }
                        ?? AccountIdentity.stableAccountKey(from: token)
                    let effectiveRefreshToken = refreshed.refreshToken ?? token
                    try? ClaudeOAuthCache.save(
                        refreshed,
                        scopes: scopes,
                        accountKey: stableAccountKey,
                        fallbackRefreshToken: token,
                        to: self.cacheURL
                    )
                    return ClaudeStoredCredentials(
                        accessToken: refreshed.accessToken,
                        refreshToken: effectiveRefreshToken,
                        expiresAtMs: refreshed.expiresAtMs,
                        scopes: scopes,
                        accountKey: stableAccountKey
                    )
                } catch ClaudeTokenRefresher.RefreshError.http(let code) where (400..<500).contains(code) {
                    if ClaudeOAuthCache.load(from: self.cacheURL)?.refreshToken == token {
                        ClaudeOAuthCache.clear(at: self.cacheURL)
                    }
                    continue
                } catch {
                    return nil
                }
            }
            return nil
        }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }

    static func decode(_ data: Data, capturedAt: Date, accountKey: String) throws -> ClaudeUsageSnapshot {
        struct Wire: Decodable {
            let rate_limit_tier: String?
            let five_hour: WindowWire?
            let seven_day: WindowWire?
            let seven_day_opus: WindowWire?
            let seven_day_sonnet: WindowWire?
            let seven_day_fable: WindowWire?
            let limits: [LimitWire]?
        }
        struct WindowWire: Decodable {
            let utilization: Double?
            let used_percent: Double?
            let resets_at: String?
            let reset_at: String?
        }
        struct LimitWire: Decodable {
            struct Scope: Decodable {
                struct Model: Decodable { let display_name: String? }
                let model: Model?
            }
            let kind: String?
            let percent: Double?
            let resets_at: String?
            let scope: Scope?
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            throw FetchError.incompatibleResponse
        }

        func date(_ raw: String?) -> Date? {
            guard let raw else { return nil }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        }
        func window(
            id: String,
            title: String,
            wire: WindowWire?,
            duration: TimeInterval
        ) throws -> ClaudeUsageSnapshot.Window? {
            guard let wire else { return nil }
            guard let used = wire.utilization ?? wire.used_percent,
                  used.isFinite,
                  let reset = date(wire.resets_at ?? wire.reset_at) else { throw FetchError.partialResponse }
            return .init(id: id, title: title, usedPercent: used, resetAt: reset, windowDuration: duration)
        }
        func structuredWindow(
            id: String,
            title: String,
            wire: LimitWire?,
            duration: TimeInterval
        ) throws -> ClaudeUsageSnapshot.Window? {
            guard let wire else { return nil }
            guard let used = wire.percent,
                  used.isFinite,
                  let reset = date(wire.resets_at) else { throw FetchError.partialResponse }
            return .init(id: id, title: title, usedPercent: used, resetAt: reset, windowDuration: duration)
        }

        let limits = wire.limits ?? []
        let fiveStructured = try structuredWindow(
            id: "claude",
            title: L10n.text("5 小时", "5 Hours"),
            wire: limits.first(where: { $0.kind == "session" }),
            duration: 18_000
        )
        let weeklyStructured = try structuredWindow(
            id: "claude-weekly",
            title: L10n.text("7 天", "7 Days"),
            wire: limits.first(where: { $0.kind == "weekly_all" }),
            duration: 604_800
        )
        var scoped: [ClaudeUsageSnapshot.Window] = []
        if let fable = try window(
            id: "fable",
            title: "Fable 5 · 7d",
            wire: wire.seven_day_fable,
            duration: 604_800
        ) {
            scoped.append(fable)
        }
        for item in limits where item.kind == "weekly_scoped" {
            guard let displayName = item.scope?.model?.display_name,
                  let id = canonicalLimitID(displayName),
                  let decoded = try structuredWindow(
                    id: id,
                    title: "\(displayName) · 7d",
                    wire: item,
                    duration: 604_800
                  ) else { throw FetchError.partialResponse }
            if let index = scoped.firstIndex(where: { $0.id == id }) {
                scoped[index] = decoded
            } else {
                scoped.append(decoded)
            }
        }
        if let opus = try window(
            id: "opus", title: "Opus · 7d", wire: wire.seven_day_opus, duration: 604_800
        ), !scoped.contains(where: { $0.id == "opus" }), opus.usedPercent > 0.5 {
            scoped.append(opus)
        }
        if let sonnet = try window(
            id: "sonnet", title: "Sonnet · 7d", wire: wire.seven_day_sonnet, duration: 604_800
        ), !scoped.contains(where: { $0.id == "sonnet" }), sonnet.usedPercent > 0.5 {
            scoped.append(sonnet)
        }

        let snapshot = try ClaudeUsageSnapshot(
            capturedAt: capturedAt,
            accountKey: accountKey,
            tier: wire.rate_limit_tier,
            fiveHour: fiveStructured ?? window(
                id: "claude", title: L10n.text("5 小时", "5 Hours"),
                wire: wire.five_hour, duration: 18_000
            ),
            sevenDay: weeklyStructured ?? window(
                id: "claude-weekly", title: L10n.text("7 天", "7 Days"),
                wire: wire.seven_day, duration: 604_800
            ),
            scopedWeekly: scoped
        )
        guard snapshot.hasQuota else { throw FetchError.incompatibleResponse }
        return snapshot
    }

    private static func canonicalLimitID(_ value: String) -> String? {
        let parts = value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let raw = parts.joined(separator: "-")
        if raw.contains("fable") { return "fable" }
        return raw.isEmpty ? nil : raw
    }

    static func parseCredentials(_ data: Data) -> ClaudeStoredCredentials? {
        struct Wrapper: Decodable {
            struct Inner: Decodable {
                let accessToken: String?
                let refreshToken: String?
                let expiresAt: Double?
                let scopes: [String]?
                let accountKey: String?
            }
            let claudeAiOauth: Inner?
        }
        guard let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data),
              let inner = wrapper.claudeAiOauth,
              let token = inner.accessToken,
              !token.isEmpty else { return nil }
        return ClaudeStoredCredentials(
            accessToken: token,
            refreshToken: inner.refreshToken,
            expiresAtMs: inner.expiresAt,
            scopes: inner.scopes,
            accountKey: inner.accountKey
        )
    }

    private static func readClaudeCredentialsFile() -> ClaudeStoredCredentials? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(".credentials.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parseCredentials(data)
    }

    private enum KeychainReadResult {
        case credentials(ClaudeStoredCredentials)
        case permanentlyUnavailable
        case temporarilyUnavailable
    }

    private static func readKeychainCredentials(timeout _: TimeInterval) -> KeychainReadResult {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Claude Code-credentials",
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            switch status {
            case errSecAuthFailed, errSecUserCanceled:
                return .permanentlyUnavailable
            default:
                return .temporarilyUnavailable
            }
        }
        guard let data = item as? Data else { return .temporarilyUnavailable }
        let trimmed = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return .temporarilyUnavailable }
        if let parsed = parseCredentials(Data(trimmed.utf8)) {
            return .credentials(parsed)
        }
        if (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil {
            return .temporarilyUnavailable
        }
        return .credentials(ClaudeStoredCredentials(
            accessToken: trimmed,
            refreshToken: nil,
            expiresAtMs: nil,
            scopes: nil,
            accountKey: nil
        ))
    }

    private static func isUsable(
        _ credentials: ClaudeStoredCredentials,
        rejected: Set<String>,
        now: Date = Date()
    ) -> Bool {
        guard !rejected.contains(credentials.accessToken) else { return false }
        guard let expiresAtMs = credentials.expiresAtMs else { return true }
        return now.timeIntervalSince1970 < expiresAtMs / 1_000 - 60
    }

    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        return nil
    }
}
