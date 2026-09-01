import Foundation
import CryptoKit
import SQLite3

public struct AntigravityLocalCredentials: Sendable, Equatable {
    public let source: AntigravityStateSource
    public let legacyAccountKey: String
    public let accessToken: String?
    public let refreshToken: String
    public let expiresAt: Date?
    public let isGCPToS: Bool
}

public enum AntigravityCredentialError: Error, Equatable, LocalizedError, Sendable {
    case applicationNotFound
    case profileNotFound
    case credentialsMissing
    case databaseBusy
    case databaseOpenFailed
    case unsupportedSchema
    case malformedPayload
    case permissionDenied
    case databaseCorrupt

    public var errorDescription: String? {
        switch self {
        case .applicationNotFound:
            return L10n.text("未找到 Antigravity，请先安装并登录。", "Antigravity was not found. Install it and sign in first.")
        case .profileNotFound:
            return L10n.text("尚未找到 Antigravity 本地记录，请先打开并完成设置。", "No Antigravity local records were found. Open it and finish setup first.")
        case .credentialsMissing:
            return L10n.text("请先在 Antigravity 中登录。", "Sign in to Antigravity first.")
        case .databaseBusy:
            return L10n.text("Antigravity 正在使用本地记录，将稍后自动重试。", "Antigravity local records are busy. An automatic retry will follow.")
        case .permissionDenied:
            return L10n.text("没有权限读取 Antigravity 本地记录，请检查访问权限。", "Antigravity local records cannot be accessed. Check access permissions.")
        case .unsupportedSchema, .malformedPayload:
            return L10n.text("Antigravity 的数据格式已变化，请检查 QuotaLens 更新。", "Antigravity's data format has changed. Check for a QuotaLens update.")
        case .databaseCorrupt:
            return L10n.text("Antigravity 本地记录已损坏，请尝试重新打开 Antigravity。", "Antigravity local records are damaged. Try reopening Antigravity.")
        case .databaseOpenFailed:
            return L10n.text("暂时无法读取 Antigravity 本地记录，将稍后自动重试。", "Antigravity local records cannot be read right now. An automatic retry will follow.")
        }
    }

    static func databaseError(_ status: Int32) -> Self {
        switch status & 0xff {
        case SQLITE_BUSY, SQLITE_LOCKED: return .databaseBusy
        case SQLITE_PERM, SQLITE_AUTH: return .permissionDenied
        case SQLITE_CORRUPT, SQLITE_NOTADB: return .databaseCorrupt
        case SQLITE_SCHEMA, SQLITE_ERROR: return .unsupportedSchema
        default: return .databaseOpenFailed
        }
    }
}

public enum AntigravityFetchError: Error, Equatable, LocalizedError, Sendable {
    case missingCredentials
    case malformedCredentials
    case unauthorized
    case forbidden
    case rateLimited(retryAfter: TimeInterval?)
    case needsInitialization
    case noQuotaData
    case incompatibleResponse
    case partialResponse
    case endpointUnavailable
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .missingCredentials, .malformedCredentials: return "Antigravity 登录状态不可用"
        case .unauthorized: return "Antigravity 登录已失效"
        case .forbidden: return "当前账号暂时无法读取 Antigravity 额度"
        case .rateLimited: return "Antigravity 额度刷新暂时受限"
        case .needsInitialization: return "请先在 Antigravity 中完成首次设置"
        case .noQuotaData: return "暂时没有 Antigravity 额度数据"
        case .incompatibleResponse, .partialResponse, .endpointUnavailable:
            return L10n.text("Antigravity 的数据格式已变化，请检查 QuotaLens 更新。", "Antigravity's data format has changed. Check for a QuotaLens update.")
        case .unavailable: return "暂时无法更新 Antigravity 额度"
        }
    }
}

public struct AntigravityLocalStateReader: Sendable {
    private let configuredSources: [AntigravityStateSource]?

    public init(sources: [AntigravityStateSource]? = nil) {
        self.configuredSources = sources
    }

    public static func candidateSources() -> [AntigravityStateSource] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            AntigravityStateSource(
                profile: .ide,
                databaseURL: home.appendingPathComponent("Library/Application Support/Antigravity IDE/User/globalStorage/state.vscdb")
            ),
            AntigravityStateSource(
                profile: .legacy,
                databaseURL: home.appendingPathComponent("Library/Application Support/Antigravity/User/globalStorage/state.vscdb")
            )
        ]
    }

    public func read(preferredProfile: AntigravityStateProfile? = nil) throws -> AntigravityLocalCredentials {
        let discovery = discoverSources()
        let candidates = discovery.sources
        guard !candidates.isEmpty else {
            if let error = discovery.failures.values.first { throw error }
            let applicationDirectories = [URL(fileURLWithPath: "/Applications"),
                                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
            let isInstalled = applicationDirectories.contains { directory in
                ["Antigravity IDE.app", "Antigravity.app"].contains {
                    FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
                }
            }
            throw configuredSources != nil || isInstalled
                ? AntigravityCredentialError.profileNotFound
                : AntigravityCredentialError.applicationNotFound
        }

        let ordered: [AntigravityStateSource]
        if let preferredProfile,
           let preferred = candidates.first(where: { $0.profile == preferredProfile }) {
            ordered = [preferred] + candidates.filter { $0.profile != preferredProfile }
        } else {
            ordered = candidates.sorted { modificationDate(of: $0.databaseURL) > modificationDate(of: $1.databaseURL) }
        }

        var readError: Error = discovery.failures.values.first ?? AntigravityCredentialError.credentialsMissing
        for source in ordered {
            do {
                return try readCredentials(from: source)
            } catch {
                if (readError as? AntigravityCredentialError) == .credentialsMissing {
                    readError = error
                }
            }
        }
        throw readError
    }

    public func readRawValue(
        key: String,
        preferredProfile: AntigravityStateProfile? = nil
    ) throws -> (source: AntigravityStateSource, value: String)? {
        try readRawValues(key: key, preferredProfile: preferredProfile).first
    }

    public func readRawValues(
        key: String,
        preferredProfile: AntigravityStateProfile? = nil
    ) throws -> [(source: AntigravityStateSource, value: String)] {
        let result = scanRawValues(key: key, preferredProfile: preferredProfile)
        if let error = result.failedSources.values.first { throw error }
        return result.values
    }

    func scanRawValues(
        key: String,
        preferredProfile: AntigravityStateProfile?
    ) -> (
        values: [(source: AntigravityStateSource, value: String)],
        successfulProfiles: Set<AntigravityStateProfile>,
        failedSources: [URL: AntigravityCredentialError]
    ) {
        let discovery = discoverSources()
        let ordered = orderedSources(discovery.sources, preferredProfile: preferredProfile)
        var values: [(source: AntigravityStateSource, value: String)] = []
        var successfulProfiles = Set<AntigravityStateProfile>()
        var failedSources = discovery.failures
        for source in ordered {
            do {
                if let value = try readItemValue(from: source.databaseURL, key: key) {
                    values.append((source, value))
                }
                successfulProfiles.insert(source.profile)
            } catch {
                failedSources[source.databaseURL] = (error as? AntigravityCredentialError) ?? .databaseOpenFailed
            }
        }
        return (values, successfulProfiles, failedSources)
    }

    private func discoverSources() -> (sources: [AntigravityStateSource], failures: [URL: AntigravityCredentialError]) {
        var sources: [AntigravityStateSource] = []
        var failures: [URL: AntigravityCredentialError] = [:]
        for source in configuredSources ?? Self.candidateSources() {
            do {
                _ = try FileManager.default.attributesOfItem(atPath: source.databaseURL.path)
                sources.append(source)
            } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
                continue
            } catch CocoaError.fileReadNoPermission {
                failures[source.databaseURL] = .permissionDenied
            } catch {
                failures[source.databaseURL] = .databaseOpenFailed
            }
        }
        return (sources, failures)
    }

    private func orderedSources(
        _ candidates: [AntigravityStateSource],
        preferredProfile: AntigravityStateProfile?
    ) -> [AntigravityStateSource] {
        guard let preferredProfile,
              let preferred = candidates.first(where: { $0.profile == preferredProfile }) else {
            return candidates.sorted { modificationDate(of: $0.databaseURL) > modificationDate(of: $1.databaseURL) }
        }
        return [preferred] + candidates.filter { $0.profile != preferredProfile }
    }

    private func readCredentials(from source: AntigravityStateSource) throws -> AntigravityLocalCredentials {
        guard let raw = try readItemValue(from: source.databaseURL, key: "antigravityUnifiedStateSync.oauthToken") else {
            throw AntigravityCredentialError.credentialsMissing
        }
        guard let data = Data(base64Encoded: raw),
              let oauthData = try extractPayload(data: data, sentinel: "oauthTokenInfoSentinelKey") else {
            throw AntigravityCredentialError.malformedPayload
        }

        var reader = AntigravityProtoReader(data: oauthData)
        var accessToken: String?
        var refreshToken: String?
        var expiresAt: Date?
        var isGCPToS = false

        while let field = try reader.nextField() {
            switch field.number {
            case 1 where field.wireType == 2:
                accessToken = String(data: field.bytes, encoding: .utf8)
            case 3 where field.wireType == 2:
                refreshToken = String(data: field.bytes, encoding: .utf8)
            case 4 where field.wireType == 2:
                expiresAt = try parseTimestamp(field.bytes)
            case 6 where field.wireType == 0:
                isGCPToS = field.varint != 0
            default:
                break
            }
        }

        guard let refreshToken, !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AntigravityCredentialError.malformedPayload
        }

        return AntigravityLocalCredentials(
            source: source,
            legacyAccountKey: "antigravity_\(Self.shortHash(refreshToken))",
            accessToken: accessToken?.nilIfEmpty,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            isGCPToS: isGCPToS
        )
    }

    private func readItemValue(from url: URL, key: String) throws -> String? {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw AntigravityCredentialError.permissionDenied
        }
        var database: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw AntigravityCredentialError.databaseError(status)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 750)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw AntigravityCredentialError.databaseError(sqlite3_errcode(database)) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, (key as NSString).utf8String, -1, transient)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw AntigravityCredentialError.databaseError(step) }
        guard let pointer = sqlite3_column_text(statement, 0) else {
            throw AntigravityCredentialError.malformedPayload
        }
        return String(cString: pointer)
    }

    private func extractPayload(data: Data, sentinel: String) throws -> Data? {
        var outer = AntigravityProtoReader(data: data)
        while let field = try outer.nextField() {
            guard field.number == 1, field.wireType == 2 else { continue }
            var entry = AntigravityProtoReader(data: field.bytes)
            var key: String?
            var row: Data?
            while let nested = try entry.nextField() {
                if nested.number == 1, nested.wireType == 2 {
                    key = String(data: nested.bytes, encoding: .utf8)
                } else if nested.number == 2, nested.wireType == 2 {
                    row = nested.bytes
                }
            }
            guard key == sentinel, let row else { continue }
            var rowReader = AntigravityProtoReader(data: row)
            while let rowField = try rowReader.nextField() {
                guard rowField.number == 1, rowField.wireType == 2,
                      let encoded = String(data: rowField.bytes, encoding: .utf8) else { continue }
                return Data(base64Encoded: encoded)
            }
        }
        return nil
    }

    private func parseTimestamp(_ data: Data) throws -> Date? {
        var reader = AntigravityProtoReader(data: data)
        var seconds: Int64?
        var nanos: Int64 = 0
        while let field = try reader.nextField() {
            if field.number == 1, field.wireType == 0 { seconds = Int64(bitPattern: field.varint) }
            if field.number == 2, field.wireType == 0 { nanos = Int64(clamping: field.varint) }
        }
        guard let seconds else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
    }

    private func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func shortHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}

struct AntigravityAccountIdentity: Sendable {
    let accountKey: String
    let email: String?

    init(userInfo: [String: Any]) throws {
        email = (userInfo["email"] as? String)?.nilIfEmpty
        let identifier: String
        if let subject = (userInfo["sub"] as? String)?.nilIfEmpty
            ?? (userInfo["id"] as? String)?.nilIfEmpty {
            identifier = "user:\(subject)"
        } else if let email {
            identifier = "email:\(email.lowercased())"
        } else {
            // Without a verified identity, keep the last account's cache
            // isolated instead of assigning quota to a token-derived account.
            throw AntigravityFetchError.incompatibleResponse
        }
        let hash = SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
        accountKey = "antigravity_\(hash)"
    }
}

public struct AntigravityQuotaClient: Sendable {
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    private static let userInfoEndpoint = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!
    private static var clientID: String {
        let p1 = "1071006060591"
        let p2 = "tmhssin2h21lcre235vtolojh4g403ep"
        let domain = "apps.googleusercontent.com"
        return "\(p1)-\(p2).\(domain)"
    }
    private static var clientSecret: String {
        let prefix = "GOCSPX"
        let body = "K58FWR486LdLJ1mLB8sXC4z6qDAf"
        return "\(prefix)-\(body)"
    }
    private let session: URLSession
    private let reader: AntigravityLocalStateReader
    private let version: String

    public init(
        session: URLSession = .shared,
        reader: AntigravityLocalStateReader = AntigravityLocalStateReader(),
        version: String? = nil
    ) {
        self.session = session
        self.reader = reader
        self.version = version ?? Self.installedVersion()
    }

    public func fetch(preferredProfile: AntigravityStateProfile? = nil) async throws -> AntigravityQuotaSnapshot {
        try await fetch(credentials: localCredentials(preferredProfile: preferredProfile))
    }

    func localCredentials(preferredProfile: AntigravityStateProfile?) throws -> AntigravityLocalCredentials {
        try reader.read(preferredProfile: preferredProfile)
    }

    func fetch(credentials: AntigravityLocalCredentials) async throws -> AntigravityQuotaSnapshot {
        let token = try await freshAccessToken(for: credentials)
        let identity = try await fetchIdentity(token: token.accessToken)
        let baseURL = credentials.isGCPToS
            ? "https://cloudcode-pa.googleapis.com"
            : "https://daily-cloudcode-pa.googleapis.com"

        let load = try await requestJSON(
            url: URL(string: "\(baseURL)/v1internal:loadCodeAssist")!,
            token: token.accessToken,
            body: try jsonData([
                "metadata": [
                    "ideName": "antigravity",
                    "ideType": "ANTIGRAVITY",
                    "ideVersion": version,
                    "pluginVersion": AppVersion.marketingVersion,
                    "platform": "DARWIN_\(Self.architecture())",
                    "updateChannel": "stable",
                    "pluginType": "GEMINI"
                ],
                "mode": "FULL_ELIGIBILITY_CHECK"
            ]),
            includeLoadHeaders: true
        )
        let projectID = extractProjectID(from: load)
        let requestBody = try jsonData(projectID.map { ["project": $0] } ?? [:])

        async let modelsResponse = requestJSON(
            url: URL(string: "\(baseURL)/v1internal:fetchAvailableModels")!,
            token: token.accessToken,
            body: requestBody,
            includeLoadHeaders: false
        )
        async let summaryResponse = requestJSON(
            url: URL(string: "\(baseURL)/v1internal:retrieveUserQuotaSummary")!,
            token: token.accessToken,
            body: requestBody,
            includeLoadHeaders: false
        )
        let (modelsJSON, summaryJSON) = try await (modelsResponse, summaryResponse)
        guard modelsJSON["models"] != nil || summaryJSON["groups"] != nil else {
            throw AntigravityFetchError.incompatibleResponse
        }
        let models = try parseModels(modelsJSON)
        let groups = try parseGroups(summaryJSON)
        guard !groups.isEmpty || !models.isEmpty else { throw AntigravityFetchError.noQuotaData }

        let plan = humanizedPlanName(
            stringValue(load["paidTier"] as? [String: Any], key: "id")
                ?? stringValue(load["currentTier"] as? [String: Any], key: "id")
        )
        return AntigravityQuotaSnapshot(
            sourceProfile: credentials.source.profile.rawValue,
            accountKey: identity.accountKey,
            accountDisplayName: identity.email,
            planName: plan,
            capturedAt: Date(),
            groups: groups,
            models: models,
            legacyAccountKey: credentials.legacyAccountKey
        )
    }

    private func freshAccessToken(for credentials: AntigravityLocalCredentials) async throws -> (accessToken: String, expiresAt: Date?) {
        if let accessToken = credentials.accessToken,
           let expiresAt = credentials.expiresAt,
           expiresAt > Date().addingTimeInterval(300) {
            return (accessToken, expiresAt)
        }
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            ("client_id", Self.clientID),
            ("client_secret", Self.clientSecret),
            ("refresh_token", credentials.refreshToken),
            ("grant_type", "refresh_token")
        ]).data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw AntigravityFetchError.malformedCredentials
        }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return (accessToken, Date().addingTimeInterval(expiresIn))
    }

    private func requestJSON(
        url: URL,
        token: String,
        body: Data,
        includeLoadHeaders: Bool
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("antigravity/\(version) darwin/\(Self.architecture())", forHTTPHeaderField: "User-Agent")
        if includeLoadHeaders { request.setValue("gl-node/22.21.1", forHTTPHeaderField: "x-goog-api-client") }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try validate(response)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravityFetchError.incompatibleResponse
        }
        return json
    }

    private func fetchIdentity(token: String) async throws -> AntigravityAccountIdentity {
        var request = URLRequest(url: Self.userInfoEndpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravityFetchError.incompatibleResponse
        }
        return try AntigravityAccountIdentity(userInfo: json)
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw AntigravityFetchError.unavailable }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw AntigravityFetchError.unauthorized
        case 403: throw AntigravityFetchError.forbidden
        case 404: throw AntigravityFetchError.endpointUnavailable
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) }
            throw AntigravityFetchError.rateLimited(retryAfter: retryAfter)
        default: throw AntigravityFetchError.unavailable
        }
    }

    func parseGroups(_ root: [String: Any]) throws -> [AntigravityQuotaSnapshot.Group] {
        guard let rawGroups = root["groups"] else { return [] }
        guard let groups = rawGroups as? [[String: Any]] else {
            throw AntigravityFetchError.incompatibleResponse
        }
        return try groups.enumerated().map { index, group in
            guard let rawBuckets = group["buckets"] as? [[String: Any]], !rawBuckets.isEmpty else {
                throw AntigravityFetchError.partialResponse
            }
            let buckets = try rawBuckets.map { bucket -> AntigravityQuotaSnapshot.Bucket in
                guard let id = (bucket["bucketId"] as? String)?.nilIfEmpty,
                      let fraction = number(bucket["remainingFraction"]),
                      fraction.isFinite, (0...1).contains(fraction) else {
                    throw AntigravityFetchError.partialResponse
                }
                return AntigravityQuotaSnapshot.Bucket(
                    id: id,
                    title: (bucket["displayName"] as? String)?.nilIfEmpty ?? id,
                    window: AntigravityQuotaWindow(bucketID: id, window: bucket["window"] as? String),
                    remainingPercent: fraction * 100,
                    resetAt: try parseDate(bucket["resetTime"])
                )
            }
            return AntigravityQuotaSnapshot.Group(
                id: (group["groupId"] as? String)?.nilIfEmpty ?? "group-\(index)",
                title: (group["displayName"] as? String)?.nilIfEmpty ?? L10n.text("模型额度", "Model Quota"),
                buckets: buckets
            )
        }
    }

    func parseModels(_ root: [String: Any]) throws -> [AntigravityQuotaSnapshot.Model] {
        guard let rawModels = root["models"] else { return [] }
        guard let models = rawModels as? [String: Any] else {
            throw AntigravityFetchError.incompatibleResponse
        }
        return try models.keys.sorted().map { id in
            guard let info = models[id] as? [String: Any],
                  let quota = info["quotaInfo"] as? [String: Any],
                  let fraction = number(quota["remainingFraction"]),
                  fraction.isFinite, (0...1).contains(fraction) else {
                throw AntigravityFetchError.partialResponse
            }
            return AntigravityQuotaSnapshot.Model(
                id: id,
                displayName: (info["displayName"] as? String)?.nilIfEmpty,
                remainingPercent: fraction * 100,
                resetAt: try parseDate(quota["resetTime"])
            )
        }
    }

    private func extractProjectID(from root: [String: Any]) -> String? {
        if let project = root["cloudaicompanionProject"] as? String { return project.nilIfEmpty }
        if let project = root["cloudaicompanionProject"] as? [String: Any],
           let id = project["id"] as? String { return id.nilIfEmpty }
        return nil
    }

    private func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func jsonData(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }

    private func parseDate(_ value: Any?) throws -> Date? {
        guard let value, !(value is NSNull) else { return nil }
        guard let raw = value as? String else { throw AntigravityFetchError.partialResponse }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else {
            throw AntigravityFetchError.partialResponse
        }
        return date
    }

    private func stringValue(_ object: [String: Any]?, key: String) -> String? {
        (object?[key] as? String)?.nilIfEmpty
    }

    private func humanizedPlanName(_ value: String?) -> String? {
        guard let value = value?.lowercased() else { return nil }
        if value.contains("enterprise") { return "Enterprise" }
        if value.contains("ultra") { return "Ultra" }
        if value.contains("pro") { return "Pro" }
        if value.contains("free") { return "Free" }
        return L10n.text("已登录", "Signed In")
    }

    private static func installedVersion() -> String {
        for path in ["/Applications/Antigravity IDE.app", "/Applications/Antigravity.app"] {
            if let version = Bundle(path: path)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
               !version.isEmpty { return version }
        }
        return "1.20.5"
    }

    private static func architecture() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }

    private static func formBody(_ pairs: [(String, String)]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return pairs.map { key, value in
            let encode: (String) -> String = { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
            return "\(encode(key))=\(encode(value))"
        }.joined(separator: "&")
    }
}

public actor AntigravityQuotaPoller {
    public static let defaultInterval: TimeInterval = 300
    public static let minimumGap: TimeInterval = 15

    private let client: AntigravityQuotaClient
    private let database: SQLiteDatabase
    private let interval: TimeInterval
    private let onResult: @Sendable (Result<ProviderQuotaRefreshResult<AntigravityQuotaSnapshot>, Error>) async -> Void
    private let onSyncState: @Sendable (ProviderSyncState) async -> Void
    private let onCachedSnapshot: @Sendable (AntigravityQuotaSnapshot?) async -> Void
    private let onAccountResolutionState: @Sendable (AccountResolutionState) async -> Void
    private var loopTask: Task<Void, Never>?
    private var lastAttemptAt: Date?
    private var lastSuccessAt: Date?
    private var nextAttemptAt: Date?
    private var cooldownUntil: Date?
    private var latestSnapshot: AntigravityQuotaSnapshot?
    private var isStopped = false
    private var isStarting = false
    private var startGeneration: UInt64 = 0
    private var isPolling = false
    private var pendingSnapshots: [String: AntigravityQuotaSnapshot] = [:]
    private var migrationWarnings = Set<String>()

    public init(
        client: AntigravityQuotaClient = AntigravityQuotaClient(),
        database: SQLiteDatabase,
        interval: TimeInterval = AntigravityQuotaPoller.defaultInterval,
        initialSnapshot: AntigravityQuotaSnapshot? = nil,
        onResult: @escaping @Sendable (Result<ProviderQuotaRefreshResult<AntigravityQuotaSnapshot>, Error>) async -> Void,
        onSyncState: @escaping @Sendable (ProviderSyncState) async -> Void = { _ in },
        onCachedSnapshot: @escaping @Sendable (AntigravityQuotaSnapshot?) async -> Void = { _ in },
        onAccountResolutionState: @escaping @Sendable (AccountResolutionState) async -> Void = { _ in }
    ) {
        self.client = client
        self.database = database
        self.interval = interval
        self.latestSnapshot = initialSnapshot
        self.lastSuccessAt = initialSnapshot?.capturedAt
        self.onResult = onResult
        self.onSyncState = onSyncState
        self.onCachedSnapshot = onCachedSnapshot
        self.onAccountResolutionState = onAccountResolutionState
    }

    public func start() async {
        guard loopTask == nil, !isStarting else { return }
        isStarting = true
        isStopped = false
        startGeneration &+= 1
        let generation = startGeneration
        defer {
            if generation == startGeneration { isStarting = false }
        }
        nextAttemptAt = Date().addingTimeInterval(2)
        await onSyncState(syncState())
        if let latestSnapshot {
            await onAccountResolutionState(.resolved(latestSnapshot.accountKey))
        }
        guard !isStopped, generation == startGeneration else { return }
        loopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            while !Task.isCancelled {
                guard let self, await self.startGeneration == generation else { return }
                await self.pollOnce(force: false, preferredProfile: nil)
                let delay = await self.nextDelay()
                guard await self.startGeneration == generation else { return }
                await self.scheduleNextAttempt(after: delay)
                try? await Task.sleep(nanoseconds: UInt64(max(1, delay) * 1_000_000_000))
            }
        }
    }

    public func stop() async {
        isStopped = true
        startGeneration &+= 1
        isStarting = false
        loopTask?.cancel()
        loopTask = nil
        nextAttemptAt = nil
        await onSyncState(syncState())
    }

    public func pollOnce(force: Bool, preferredProfile: AntigravityStateProfile?) async {
        guard !isStopped, !isPolling else { return }
        let now = Date()
        if let cooldownUntil, cooldownUntil > now { return }
        if !force, let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < Self.minimumGap { return }
        lastAttemptAt = now
        isPolling = true
        defer { isPolling = false }
        await onSyncState(syncState())
        for (key, pending) in pendingSnapshots {
            do {
                if try AntigravityQuotaRepository.persist(pending, database: database) {
                    migrationWarnings.insert(key)
                }
                pendingSnapshots[key] = nil
            } catch { /* Retain the snapshot for the next scheduled attempt. */ }
        }
        do {
            let credentials = try client.localCredentials(preferredProfile: preferredProfile)
            let previousSnapshot = latestSnapshot
            if let previousSnapshot,
               previousSnapshot.legacyAccountKey != credentials.legacyAccountKey,
               previousSnapshot.accountKey != credentials.legacyAccountKey {
                let hydrated = try? AntigravityQuotaRepository.hydrate(
                    database: database,
                    accountKey: credentials.legacyAccountKey,
                    sourceProfile: credentials.source.profile.rawValue
                )
                if let hydrated {
                    latestSnapshot = hydrated
                    lastSuccessAt = hydrated.capturedAt
                    await onCachedSnapshot(hydrated)
                    await onAccountResolutionState(.resolved(hydrated.accountKey))
                } else {
                    await onAccountResolutionState(.resolving(previousAccountKey: previousSnapshot.accountKey))
                }
            }
            let snapshot = try await client.fetch(credentials: credentials)
            guard !isStopped else { return }
            let previousAccountKey = latestSnapshot?.accountKey
            latestSnapshot = snapshot
            lastSuccessAt = snapshot.capturedAt
            if let previousAccountKey, previousAccountKey != snapshot.accountKey {
                await onAccountResolutionState(.switched(from: previousAccountKey, to: snapshot.accountKey))
            } else {
                await onAccountResolutionState(.resolved(snapshot.accountKey))
            }
            cooldownUntil = nil
            nextAttemptAt = Date().addingTimeInterval(interval)
            var historySaved = true
            do {
                if try AntigravityQuotaRepository.persist(snapshot, database: database) {
                    migrationWarnings.insert(snapshot.accountKey)
                }
                pendingSnapshots[snapshot.accountKey] = nil
            } catch {
                historySaved = false
                pendingSnapshots[snapshot.accountKey] = snapshot
            }
            await onSyncState(syncState())
            await onResult(.success(ProviderQuotaRefreshResult(
                snapshot: snapshot,
                historySaved: historySaved,
                migrationWarning: migrationWarnings.remove(snapshot.accountKey) != nil
            )))
        } catch let error as AntigravityCredentialError {
            guard !isStopped else { return }
            if error == .credentialsMissing || error == .applicationNotFound || error == .profileNotFound {
                latestSnapshot = nil
                lastSuccessAt = nil
                await onCachedSnapshot(nil)
            }
            nextAttemptAt = Date().addingTimeInterval(interval)
            await onSyncState(syncState())
            await onResult(.failure(error))
        } catch let error as AntigravityFetchError {
            guard !isStopped else { return }
            if case .rateLimited(let retryAfter) = error {
                cooldownUntil = now.addingTimeInterval(max(60, retryAfter ?? 300))
                nextAttemptAt = cooldownUntil
            } else {
                nextAttemptAt = Date().addingTimeInterval(interval)
            }
            await onSyncState(syncState())
            await onResult(.failure(error))
        } catch {
            guard !isStopped else { return }
            nextAttemptAt = Date().addingTimeInterval(interval)
            await onSyncState(syncState())
            await onResult(.failure(error))
        }
    }

    public func currentSyncState() -> ProviderSyncState {
        syncState()
    }

    private func nextDelay() -> TimeInterval {
        if let cooldownUntil, cooldownUntil > Date() {
            return cooldownUntil.timeIntervalSinceNow
        }
        return interval
    }

    private func scheduleNextAttempt(after delay: TimeInterval) async {
        nextAttemptAt = Date().addingTimeInterval(max(1, delay))
        await onSyncState(syncState())
    }

    private func syncState() -> ProviderSyncState {
        ProviderSyncState(
            provider: .antigravity,
            lastAttemptAt: lastAttemptAt,
            lastSuccessAt: lastSuccessAt,
            nextAttemptAt: nextAttemptAt,
            cooldownUntil: cooldownUntil
        )
    }
}

struct AntigravityProtoReader {
    struct Field {
        let number: Int
        let wireType: Int
        let varint: UInt64
        let bytes: Data
    }

    let data: Data
    var offset: Int = 0

    mutating func nextField() throws -> Field? {
        guard offset < data.count else { return nil }
        let tag = try readVarint()
        let number = Int(tag >> 3)
        guard number > 0 else { throw AntigravityCredentialError.malformedPayload }
        let wireType = Int(tag & 7)
        switch wireType {
        case 0:
            return Field(number: number, wireType: wireType, varint: try readVarint(), bytes: Data())
        case 2:
            let rawLength = try readVarint()
            guard rawLength <= UInt64(data.count - offset) else { throw AntigravityCredentialError.malformedPayload }
            let length = Int(rawLength)
            let bytes = data[offset..<(offset + length)]
            offset += length
            return Field(number: number, wireType: wireType, varint: 0, bytes: Data(bytes))
        case 1:
            guard data.count - offset >= 8 else { throw AntigravityCredentialError.malformedPayload }
            offset += 8
            return Field(number: number, wireType: wireType, varint: 0, bytes: Data())
        case 5:
            guard data.count - offset >= 4 else { throw AntigravityCredentialError.malformedPayload }
            offset += 4
            return Field(number: number, wireType: wireType, varint: 0, bytes: Data())
        default:
            throw AntigravityCredentialError.malformedPayload
        }
    }

    private mutating func readVarint() throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count, shift <= 63 {
            let byte = data[offset]
            offset += 1
            guard shift < 63 || byte <= 1 else { throw AntigravityCredentialError.malformedPayload }
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        throw AntigravityCredentialError.malformedPayload
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
