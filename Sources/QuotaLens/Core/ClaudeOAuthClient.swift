import Foundation
import Darwin

struct ClaudeStoredCredentials: Sendable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresAtMs: Double?
    let scopes: [String]?
}

struct ClaudeRefreshedCredentials: Sendable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresAtMs: Double
}

enum ClaudeOAuthCache {
    static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuotaLens", isDirectory: true)
            .appendingPathComponent("claude-oauth.json")
    }

    static func load(from url: URL = defaultURL()) -> ClaudeStoredCredentials? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ClaudeUsageClient.parseCredentials(data)
    }

    static func save(
        _ credentials: ClaudeRefreshedCredentials,
        scopes: [String]?,
        to url: URL = defaultURL()
    ) throws {
        var inner: [String: Any] = [
            "accessToken": credentials.accessToken,
            "expiresAt": credentials.expiresAtMs
        ]
        if let refreshToken = credentials.refreshToken {
            inner["refreshToken"] = refreshToken
        }
        if let scopes { inner["scopes"] = scopes }
        let data = try JSONSerialization.data(
            withJSONObject: ["claudeAiOauth": inner],
            options: [.sortedKeys]
        )
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
    }

    static func clear(at url: URL = defaultURL()) {
        try? FileManager.default.removeItem(at: url)
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
        case unavailable

        var isAuthenticationFailure: Bool {
            switch self {
            case .noCredentials, .insufficientScope, .unauthorized: return true
            case .rateLimited, .unavailable: return false
            }
        }
    }

    private static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let session: URLSession
    private let endpoint: URL
    private let cacheURL: URL
    private let tokenRefresher: ClaudeTokenRefresher
    private var memoryToken: String?
    private var rejectedTokens: Set<String> = []
    private var keychainUnavailable = false
    private var refreshTask: Task<ClaudeStoredCredentials?, Never>?

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
    }

    private func fetch(retriedAfterUnauthorized: Bool) async throws -> ClaudeUsageSnapshot {
        guard let token = await loadAccessToken() else {
            throw FetchError.noCredentials
        }
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
            return try Self.decode(data, capturedAt: Date())
        case 401:
            rejectedTokens.insert(token)
            memoryToken = nil
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

    private func loadAccessToken() async -> String? {
        if let memoryToken, !rejectedTokens.contains(memoryToken) {
            return memoryToken
        }

        var candidates: [ClaudeStoredCredentials] = []
        if let cached = ClaudeOAuthCache.load(from: cacheURL) {
            candidates.append(cached)
            if Self.isUsable(cached, rejected: rejectedTokens) {
                memoryToken = cached.accessToken
                return cached.accessToken
            }
        }
        if let file = Self.readClaudeCredentialsFile() {
            candidates.append(file)
            if Self.isUsable(file, rejected: rejectedTokens) {
                memoryToken = file.accessToken
                return file.accessToken
            }
        }
        if !keychainUnavailable {
            switch Self.readKeychainCredentials(timeout: 2) {
            case .credentials(let credentials):
                candidates.append(credentials)
                if Self.isUsable(credentials, rejected: rejectedTokens) {
                    memoryToken = credentials.accessToken
                    return credentials.accessToken
                }
            case .permanentlyUnavailable:
                keychainUnavailable = true
            case .temporarilyUnavailable:
                break
            }
        }

        let refreshTokens = candidates.compactMap(\.refreshToken).filter { !$0.isEmpty }
        if let refreshToken = refreshTokens.first,
           let refreshed = await refreshSingleFlight(refreshToken, candidates: candidates) {
            memoryToken = refreshed.accessToken
            return refreshed.accessToken
        }
        return candidates.first?.accessToken
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
                    let scopes = candidates.first(where: { $0.refreshToken == token })?.scopes
                    try? ClaudeOAuthCache.save(refreshed, scopes: scopes, to: self.cacheURL)
                    return ClaudeStoredCredentials(
                        accessToken: refreshed.accessToken,
                        refreshToken: refreshed.refreshToken,
                        expiresAtMs: refreshed.expiresAtMs,
                        scopes: scopes
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

    static func decode(_ data: Data, capturedAt: Date) throws -> ClaudeUsageSnapshot {
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
            throw FetchError.unavailable
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
        ) -> ClaudeUsageSnapshot.Window? {
            guard let wire,
                  let used = wire.utilization ?? wire.used_percent,
                  used.isFinite,
                  let reset = date(wire.resets_at ?? wire.reset_at) else { return nil }
            return .init(id: id, title: title, usedPercent: used, resetAt: reset, windowDuration: duration)
        }
        func structuredWindow(
            id: String,
            title: String,
            wire: LimitWire?,
            duration: TimeInterval
        ) -> ClaudeUsageSnapshot.Window? {
            guard let wire,
                  let used = wire.percent,
                  used.isFinite,
                  let reset = date(wire.resets_at) else { return nil }
            return .init(id: id, title: title, usedPercent: used, resetAt: reset, windowDuration: duration)
        }

        let limits = wire.limits ?? []
        let fiveStructured = structuredWindow(
            id: "claude",
            title: L10n.text("5 小时", "5 Hours"),
            wire: limits.first(where: { $0.kind == "session" }),
            duration: 18_000
        )
        let weeklyStructured = structuredWindow(
            id: "claude-weekly",
            title: L10n.text("7 天", "7 Days"),
            wire: limits.first(where: { $0.kind == "weekly_all" }),
            duration: 604_800
        )
        var scoped: [ClaudeUsageSnapshot.Window] = []
        if let fable = window(
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
                  let decoded = structuredWindow(
                    id: id,
                    title: "\(displayName) · 7d",
                    wire: item,
                    duration: 604_800
                  ) else { continue }
            if let index = scoped.firstIndex(where: { $0.id == id }) {
                scoped[index] = decoded
            } else {
                scoped.append(decoded)
            }
        }
        if let opus = window(
            id: "opus", title: "Opus · 7d", wire: wire.seven_day_opus, duration: 604_800
        ), !scoped.contains(where: { $0.id == "opus" }), opus.usedPercent > 0.5 {
            scoped.append(opus)
        }
        if let sonnet = window(
            id: "sonnet", title: "Sonnet · 7d", wire: wire.seven_day_sonnet, duration: 604_800
        ), !scoped.contains(where: { $0.id == "sonnet" }), sonnet.usedPercent > 0.5 {
            scoped.append(sonnet)
        }

        return ClaudeUsageSnapshot(
            capturedAt: capturedAt,
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
            scopes: inner.scopes
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

    private static func readKeychainCredentials(timeout: TimeInterval) -> KeychainReadResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return .temporarilyUnavailable
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            let stopDeadline = Date().addingTimeInterval(0.2)
            while process.isRunning && Date() < stopDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            return .permanentlyUnavailable
        }
        guard process.terminationStatus == 0 else {
            let text = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .lowercased() ?? ""
            return text.contains("not found") || text.contains("could not be found")
                || text.contains("interaction") || text.contains("denied")
                ? .permanentlyUnavailable
                : .temporarilyUnavailable
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
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
            scopes: nil
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
