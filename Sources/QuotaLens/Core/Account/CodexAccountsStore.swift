// 账号浏览与当前工具状态隔离；独立授权只在用户明确点击时启动。
import AppKit
import Combine
import Foundation
import CryptoKit

@MainActor
final class CodexAccountsStore: ObservableObject {
    @Published private(set) var selectedKey: String = ""
    @Published private(set) var accounts: [ManagedCodexAccount] = []
    @Published private(set) var snapshots: [RateLimitSnapshotRecord] = []
    @Published private(set) var accountSnapshots: [String: [RateLimitSnapshotRecord]] = [:]
    @Published private(set) var accountErrors: [String: String] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var isAuthorizing = false
    @Published var error: String?
    @Published var operationMessage: String?
    @Published private(set) var importFailures: [String] = []
    @Published private(set) var importProgress = 0
    @Published private(set) var importTotal = 0
    let provider: UsageProvider
    private let database: SQLiteDatabase
    private let client: QueryCredentialClient
    private let loadCredential: @Sendable (UUID) throws -> QueryCredential
    private let saveCredential: @Sendable (QueryCredential, UUID) throws -> Void
    private let deleteCredential: @Sendable (UUID) throws -> Void
    private let renewCredential: @Sendable (UsageProvider, QueryCredential) async throws -> QueryCredential
    private let localCredentialProvider: (@Sendable () throws -> [QueryCredential])?
    private var pendingImports: [String: QueryCredential] = [:]
    private var ignoredLocalKeys: Set<String> = []
    private var browserFlow: QueryOAuthFlow?
    private var completingBrowserAuthorization = false
    private var pendingCredentialWrites: [UUID: QueryCredential] = [:]
    private var pendingCodexWrites: [UUID: Data] = [:]
    private var codexVault: LocalCredentialStore {
        LocalCredentialStore(root: root.appendingPathComponent("EncryptedCredentials"))
    }
    private var didValidate = false
    private var lastLocalDigest: Data?
    private let reader: CodexAccountQuotaReader
    private let defaults: UserDefaults
    private let root: URL
    private var generation = 0
    private var loginManager: CodexProcessManager?
    private var loginTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var authorizationID: UUID?
    private var completingAuthorization = false
    private var storageKey: String {
        provider == .codex ? "QuotaLens.managedCodexAccounts" : "QuotaLens.queryAccounts.\(provider.rawValue)"
    }

    init(database: SQLiteDatabase, defaults: UserDefaults = .standard, root: URL? = nil,
         reader: CodexAccountQuotaReader? = nil, provider: UsageProvider = .codex,
         client: QueryCredentialClient = QueryCredentialClient(),
         loadCredential: @escaping @Sendable (UUID) throws -> QueryCredential = { try QueryCredentialVault.load(id: $0) },
         saveCredential: @escaping @Sendable (QueryCredential, UUID) throws -> Void = { try QueryCredentialVault.save($0, id: $1) },
         deleteCredential: @escaping @Sendable (UUID) throws -> Void = { try QueryCredentialVault.remove(id: $0) },
         renewCredential: @escaping @Sendable (UsageProvider, QueryCredential) async throws -> QueryCredential = {
             try await QueryOAuthClient(provider: $0).refresh($1)
         }, localCredentialProvider: (@Sendable () throws -> [QueryCredential])? = nil) {
        self.client = client
        self.loadCredential = loadCredential
        self.saveCredential = saveCredential
        self.deleteCredential = deleteCredential
        self.renewCredential = renewCredential
        self.localCredentialProvider = localCredentialProvider
        self.provider = provider
        self.database = database
        self.reader = reader ?? CodexAccountQuotaReader(database: database)
        self.defaults = defaults
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(provider == .codex ? "QuotaLens/CodexAccounts" : "QuotaLens/QueryAccounts/\(provider.rawValue)", isDirectory: true)
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([ManagedCodexAccount].self, from: data) {
            accounts = saved
        }
        ignoredLocalKeys = Set(defaults.stringArray(forKey: storageKey + ".ignoredLocal") ?? [])
        selectedKey = defaults.string(forKey: storageKey + ".selection") ?? ""
        if !accounts.contains(where: { $0.accountKey == selectedKey && $0.canQuery }) { selectedKey = "" }
        if !selectedKey.isEmpty {
            snapshots = (try? Repositories(database: database).getLatestRateLimitSnapshots(accountKey: selectedKey, provider: provider)) ?? []
        }
        for account in accounts {
            accountSnapshots[account.accountKey] = (try? Repositories(database: database)
                .getLatestRateLimitSnapshots(accountKey: account.accountKey, provider: provider)) ?? []
        }
    }

    func name(for key: String, state: AppState) -> String {
        if let account = accounts.first(where: { $0.accountKey == key }) { return account.name }
        if state.accountDisplayNames[key] == nil {
            let index = (keys(state: state).firstIndex(of: key) ?? 0) + 1
            return L10n.format("Unidentified account %d", zhHans: "待识别账号 %d", index)
        }
        return state.displayName(for: key)
    }

    func keys(state: AppState) -> [String] {
        accounts.filter(\.canQuery).map(\.accountKey).sorted()
    }

    func select(_ key: String) {
        guard key.isEmpty || accounts.contains(where: { $0.accountKey == key && $0.canQuery }) else { return }
        guard selectedKey != key else { return }
        generation += 1
        selectedKey = key
        defaults.set(key, forKey: storageKey + ".selection")
        snapshots = key.isEmpty ? [] : (try? Repositories(database: database).getLatestRateLimitSnapshots(accountKey: key, provider: provider)) ?? []
        error = nil
    }

    func loadSelection(refresh: Bool) async {
        let key = selectedKey
        guard !key.isEmpty, !isRefreshing, !isAuthorizing,
              let account = accounts.first(where: { $0.accountKey == key && $0.status == .available }) else { return }
        if !refresh { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            if !selectedKey.isEmpty, selectedKey != key {
                Task { await self.loadSelection(refresh: true) }
            }
        }
        await verify(account)
    }

    private func verify(_ account: ManagedCodexAccount) async {
        let key = account.accountKey
        do {
            let rows: [RateLimitSnapshotRecord]
            if provider == .codex && (account.source == nil || account.source == .independent) {
                rows = try await readIndependentCodex(account)
            } else {
                var credential = try pendingCredentialWrites[account.directoryID] ?? loadCredential(account.directoryID)
                let independent = credential.hasRefreshToken
                var refreshed = false
                if independent, credential.hasRefreshToken, credential.needsRefresh(),
                   pendingCredentialWrites[account.directoryID] == nil {
                    credential = try await renewCredential(provider, credential)
                    pendingCredentialWrites[account.directoryID] = credential
                    refreshed = true
                }
                if let pending = pendingCredentialWrites[account.directoryID] {
                    try saveCredential(pending, account.directoryID)
                    pendingCredentialWrites[account.directoryID] = nil
                }
                let result: QueryAccountResult
                do { result = try await client.fetch(credential, provider: provider) }
                catch let failure as QueryAccountError where (failure == .authorization || failure == .expired) && independent && !refreshed && credential.hasRefreshToken {
                    credential = try await renewCredential(provider, credential)
                    pendingCredentialWrites[account.directoryID] = credential
                    try saveCredential(credential, account.directoryID)
                    pendingCredentialWrites[account.directoryID] = nil
                    result = try await client.fetch(credential, provider: provider)
                }
                guard result.key == key else { throw QueryAccountError.identity }
                try saveResult(result)
                rows = result.snapshots
                if let index = accounts.firstIndex(where: { $0.directoryID == account.directoryID }) {
                    accounts[index].accessExpiresAt = credential.effectiveExpiry
                    accounts[index].hasRefreshToken = credential.hasRefreshToken
                }
            }
            guard let index = accounts.firstIndex(where: { $0.directoryID == account.directoryID }) else { return }
            accounts[index].status = .available
            accounts[index].verifiedAt = Date()
            persist()
            if selectedKey.isEmpty { select(key) }
            if selectedKey == key { snapshots = rows }
            accountSnapshots[key] = rows
            accountErrors[key] = nil
            error = nil
        } catch {
            if let failure = error as? QueryAccountError,
               let index = accounts.firstIndex(where: { $0.directoryID == account.directoryID }) {
                switch failure {
                case .credentialMissing: accounts[index].status = .missingCredentials
                case .expired: accounts[index].status = .accessExpired
                case .authorization, .identity: accounts[index].status = .needsAuthorization
                default: break
                }
                persist()
                if selectedKey == key, !accounts[index].canQuery { select("") }
            }
            self.error = queryErrorMessage(error)
            accountErrors[key] = self.error
        }
    }

    func refreshAvailableAccounts() async {
        guard !isRefreshing, !isAuthorizing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        for account in accounts where account.canQuery {
            if Task.isCancelled { break }
            await verify(account)
        }
    }

    func renewDueAccounts() async {
        guard !isRefreshing, !isAuthorizing else { return }
        let due = accounts.filter {
            $0.status == .available && ($0.source == .independent || $0.hasRefreshToken == true)
                && $0.accessExpiresAt.map { $0 <= Date().addingTimeInterval(300) } == true
        }
        guard !due.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        for account in due { await verify(account) }
    }

    private func readIndependentCodex(_ account: ManagedCodexAccount) async throws -> [RateLimitSnapshotRecord] {
        let id = account.directoryID
        let name = "codex-" + id.uuidString
        let data = try pendingCodexWrites[id] ?? codexVault.load(Data.self, id: name)
        let scratch = root.appendingPathComponent("query-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let auth = scratch.appendingPathComponent("auth.json")
        try data.write(to: auth, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
        let result: Result<[RateLimitSnapshotRecord], Error>
        do { result = .success(try await reader.refresh(homeURL: scratch, expectedAccountKey: account.accountKey).2) }
        catch { result = .failure(error) }
        // The isolated server may rotate a token even if the subsequent quota read fails.
        let refreshed = try Data(contentsOf: auth)
        pendingCodexWrites[id] = refreshed
        try codexVault.save(refreshed, id: name)
        pendingCodexWrites[id] = nil
        if let credential = try? QueryCredential.parse(refreshed, provider: .codex),
           let index = accounts.firstIndex(where: { $0.directoryID == id }) {
            accounts[index].accessExpiresAt = credential.effectiveExpiry
            accounts[index].hasRefreshToken = credential.hasRefreshToken
        }
        return try result.get()
    }

    func prepare() async {
        guard !didValidate, !isRefreshing, !isAuthorizing else { return }
        didValidate = true
        isRefreshing = true
        for account in accounts {
            if Task.isCancelled { didValidate = false; break }
            await verify(account)
        }
        isRefreshing = false
        if snapshots.isEmpty, error == nil, !selectedKey.isEmpty { await loadSelection(refresh: true) }
    }

    func validate(_ key: String) async {
        guard !isRefreshing, !isAuthorizing, let account = accounts.first(where: { $0.accountKey == key }) else { return }
        isRefreshing = true
        await verify(account)
        isRefreshing = false
        if !selectedKey.isEmpty, selectedKey != key { await loadSelection(refresh: true) }
    }

    func importCredential(_ data: Data, source: QueryCredentialSource = .imported,
                          allowIgnored: Bool = false) async {
        guard !isRefreshing, !isAuthorizing else { error = QueryAccountError.busy.userMessage; return }
        operationMessage = nil
        importFailures = []
        importProgress = 0
        importTotal = 0
        do {
            let items = try QueryCredentialTransfer.parse(data, provider: provider)
            await importItems(items, source: source, allowIgnored: allowIgnored,
                              report: true)
        } catch { self.error = queryErrorMessage(error) }
    }

    private func importItems(_ items: [Result<QueryCredentialImportItem, QueryAccountError>],
                             source: QueryCredentialSource, allowIgnored: Bool, report: Bool) async {
        guard !isRefreshing, !isAuthorizing else { return }
        isRefreshing = true
        if report { operationMessage = nil; importFailures = []; importProgress = 0; importTotal = items.count; error = nil }
        defer { isRefreshing = false }
        var added = 0
        var unchanged = 0
        var failures: [String] = []
        for (offset, item) in items.enumerated() {
            if Task.isCancelled { break }
            do {
                let candidate = try item.get()
                if try await install(candidate, source: source, allowIgnored: allowIgnored) { added += 1 }
                else { unchanged += 1 }
            } catch {
                failures.append("\(offset + 1). " + queryErrorMessage(error))
            }
            if report { importProgress = offset + 1 }
        }
        if report {
            importFailures = failures
            operationMessage = L10n.format("Imported/updated %d · unchanged %d · failed %d",
                zhHans: "导入或更新 %d 项 · 未变更 %d 项 · 失败 %d 项", added, unchanged, failures.count)
            error = failures.isEmpty ? nil : failures.first
        }
    }

    private func install(_ item: QueryCredentialImportItem, source: QueryCredentialSource,
                         allowIgnored: Bool) async throws -> Bool {
        let hash = Data(SHA256.hash(data: Data((item.credential.refreshToken ?? item.credential.accessToken).utf8))).base64EncodedString()
        var credential = pendingImports[hash] ?? item.credential
        var renewed = false
        if credential.needsRefresh(), credential.hasRefreshToken {
            credential = try await renewCredential(provider, credential)
            pendingImports[hash] = credential
            renewed = true
        } else if credential.accessToken.isEmpty || credential.effectiveExpiry.map({ $0 <= Date() }) == true {
            throw QueryAccountError.expired
        }
        let result: QueryAccountResult
        do { result = try await client.fetch(credential, provider: provider) }
        catch QueryAccountError.authorization where credential.hasRefreshToken && !renewed {
            credential = try await renewCredential(provider, credential)
            pendingImports[hash] = credential
            result = try await client.fetch(credential, provider: provider)
        }
        if let expected = item.expectedAccountKey, expected != result.key { throw QueryAccountError.identity }
        if source == .local, ignoredLocalKeys.contains(result.key), !allowIgnored { return false }
        let existing = accounts.first { $0.accountKey == result.key }
        // Never silently replace a healthy independent grant with a shared token chain.
        if source != .independent, let existing, existing.source == nil || existing.source == .independent,
           existing.canQuery {
            return false
        }
        let replacingCodexGrant = provider == .codex && existing != nil && (existing?.source == nil || existing?.source == .independent)
        let id = replacingCodexGrant ? UUID() : existing?.directoryID ?? UUID()
        try saveCredential(credential, id)
        do { try saveResult(result) }
        catch {
            if existing == nil || replacingCodexGrant { try? deleteCredential(id) }
            throw error
        }
        accounts.removeAll { $0.accountKey == result.key }
        let importedName = item.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        accounts.append(.init(accountKey: result.key, directoryID: id,
            name: existing?.name ?? (importedName?.isEmpty == false ? String(importedName!.prefix(200)) : result.name),
            source: source, status: .available, verifiedAt: Date(), accessExpiresAt: credential.effectiveExpiry,
            hasRefreshToken: credential.hasRefreshToken))
        persist()
        pendingImports[hash] = nil
        pendingCredentialWrites[id] = nil
        if replacingCodexGrant, let existing {
            try? codexVault.remove(id: "codex-" + existing.directoryID.uuidString)
        }
        if allowIgnored {
            ignoredLocalKeys.remove(result.key)
            defaults.set(Array(ignoredLocalKeys), forKey: storageKey + ".ignoredLocal")
        }
        if source != .local || selectedKey.isEmpty { select(result.key) }
        if selectedKey == result.key { snapshots = result.snapshots }
        accountSnapshots[result.key] = result.snapshots
        accountErrors[result.key] = nil
        return true
    }

    func discoverLocal(force: Bool = false) async {
        guard !isRefreshing, !isAuthorizing else {
            if force { error = QueryAccountError.busy.userMessage }
            return
        }
        do {
            let credentials = try localCredentialProvider?() ?? readLocalCredentials()
            guard !credentials.isEmpty else { throw QueryAccountError.credentialMissing }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let fingerprint = try encoder.encode(credentials)
            let digest = Data(SHA256.hash(data: fingerprint))
            guard force || lastLocalDigest != digest else { return }
            let items: [Result<QueryCredentialImportItem, QueryAccountError>] = credentials.map {
                .success(.init(credential: $0, name: nil, expectedAccountKey: nil))
            }
            await importItems(items, source: .local, allowIgnored: force, report: force)
            // Automatic discovery retries after changed credentials; explicit import always retries.
            lastLocalDigest = digest
        } catch {
            if force {
                operationMessage = nil
                importFailures = []
                self.error = queryErrorMessage(error)
            }
        }
    }

    private func readLocalCredentials() throws -> [QueryCredential] {
        switch provider {
        case .codex:
            let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            let url = home.appendingPathComponent("auth.json")
            guard FileManager.default.fileExists(atPath: url.path) else { throw QueryAccountError.credentialMissing }
            return [try QueryCredential.parse(Data(contentsOf: url), provider: .codex)]
        case .claude:
            return ClaudeUsageClient.localQueryCredentialCandidates().map {
                QueryCredential(accessToken: $0.accessToken, refreshToken: $0.refreshToken,
                    expiresAt: $0.expiresAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }, isGCPToS: false)
            }
        case .antigravity:
            let profiles = Set(AntigravityLocalStateReader.candidateSources().map(\.profile))
            return profiles.sorted { $0.rawValue < $1.rawValue }.compactMap { profile in
                guard let credential = try? AntigravityQuotaClient().localCredentials(preferredProfile: profile) else { return nil }
                return QueryCredential(accessToken: credential.accessToken ?? "", refreshToken: credential.refreshToken,
                    expiresAt: credential.expiresAt, isGCPToS: credential.isGCPToS)
            }
        }
    }

    func exportCredentials(_ keys: [String]) throws -> Data {
        guard !isRefreshing, !isAuthorizing else { throw QueryAccountError.busy }
        guard !keys.isEmpty else { throw QueryAccountError.credentialMissing }
        let entries = try keys.map { key -> (String, String, QueryCredential) in
            guard let account = accounts.first(where: { $0.accountKey == key }) else { throw QueryAccountError.credentialMissing }
            let credential: QueryCredential
            if provider == .codex, account.source == nil || account.source == .independent {
                let data = try pendingCodexWrites[account.directoryID]
                    ?? codexVault.load(Data.self, id: "codex-" + account.directoryID.uuidString)
                credential = try QueryCredential.parse(data, provider: provider)
            } else {
                credential = try pendingCredentialWrites[account.directoryID] ?? loadCredential(account.directoryID)
            }
            return (key, account.name, credential)
        }
        return try QueryCredentialTransfer.export(provider: provider, entries: entries)
    }

    func resetCreditHistory(accountKey: String, cursor: String? = nil) async throws -> ResetCreditHistoryPage {
        guard provider == .codex else { throw QueryAccountError.wrongProvider }
        let credential: QueryCredential
        if let account = accounts.first(where: { $0.accountKey == accountKey }) {
            if account.source == nil || account.source == .independent {
                let data = try pendingCodexWrites[account.directoryID]
                    ?? codexVault.load(Data.self, id: "codex-" + account.directoryID.uuidString)
                credential = try QueryCredential.parse(data, provider: .codex)
            } else {
                credential = try pendingCredentialWrites[account.directoryID] ?? loadCredential(account.directoryID)
            }
        } else {
            let candidates = try readLocalCredentials()
            guard let current = candidates.first(where: {
                let auth = QueryCredential.claims($0.accessToken)["https://api.openai.com/auth"] as? [String: Any]
                return (auth?["chatgpt_account_id"] as? String).map { AccountIdentity.stableAccountKey(from: $0) } == accountKey
            }) else { throw QueryAccountError.credentialMissing }
            credential = current
        }
        return try await client.resetCreditHistory(credential, accountKey: accountKey, cursor: cursor)
    }

    func removeCredential(_ key: String) {
        guard !isRefreshing, !isAuthorizing, let account = accounts.first(where: { $0.accountKey == key }) else { return }
        do {
            if provider != .codex || account.source == .imported || account.source == .local {
                try deleteCredential(account.directoryID)
                pendingCredentialWrites[account.directoryID] = nil
            } else {
                try codexVault.remove(id: "codex-" + account.directoryID.uuidString)
                pendingCodexWrites[account.directoryID] = nil
                // Retain the credential in the system Trash rather than erase it irreversibly.
                let directory = home(for: account.directoryID)
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
                }
            }
            accounts.removeAll { $0.accountKey == key }
            accountSnapshots[key] = nil
            accountErrors[key] = nil
            ignoredLocalKeys.insert(key)
            defaults.set(Array(ignoredLocalKeys), forKey: storageKey + ".ignoredLocal")
            persist()
            if selectedKey == key { select("") }
        } catch { self.error = queryErrorMessage(error) }
    }

    private func saveResult(_ result: QueryAccountResult) throws {
        let repository = Repositories(database: database)
        try database.transaction {
            try repository.upsertAccount(.init(accountKey: result.key, emailHash: nil,
                planType: result.snapshots.first?.planType, firstSeenAt: Int64(Date().timeIntervalSince1970),
                lastSeenAt: Int64(Date().timeIntervalSince1970)))
            // Append only: importing/removing a credential must not prune or migrate historical ledgers.
            for row in result.snapshots {
                try database.executeUpdate(sql: """
                    INSERT INTO rate_limit_snapshots
                    (account_key, observed_at, limit_id, slot, used_percent_milli,
                     window_duration_mins, resets_at, plan_type, raw_json, provider)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """, bindings: [row.accountKey, row.observedAt, row.limitId, row.slot,
                        row.usedPercentMilli, row.windowDurationMins, row.resetsAt,
                        row.planType, row.rawJson, provider.rawValue])
            }
        }
    }

    private func queryErrorMessage(_ error: Error) -> String {
        if let failure = error as? QueryAccountError { return failure.userMessage }
        if error is CryptoKitError || (error as NSError).domain == NSCocoaErrorDomain { return QueryAccountError.storage.userMessage }
        return QueryAccountError.unavailable.userMessage
    }

    func rename(_ key: String, to name: String, state: AppState) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let index = accounts.firstIndex(where: { $0.accountKey == key }) {
            accounts[index].name = name
            persist()
        }
        state.setAccountDisplayName(name, for: key)
        objectWillChange.send()
    }

    func authorize() {
        guard !isAuthorizing, !isRefreshing else { return }
        operationMessage = nil
        importFailures = []
        if provider != .codex {
            authorizeInBrowser()
            return
        }
        isAuthorizing = true
        error = nil
        let id = UUID()
        completingAuthorization = false
        authorizationID = id
        let directory = home(for: id)
        loginTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, authorizationID == id else { return }
            let transport = JSONRPCTransport()
            let manager = CodexProcessManager(transport: transport, accountHomeURL: directory, maximumReconnectAttempts: 0)
            loginManager = manager
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                await transport.onNotification { [weak self] notification in
                    guard notification.method == "account/login/completed", let params = notification.params,
                          let data = try? JSONEncoder().encode(params),
                          let completion = try? JSONDecoder().decode(LoginCompletion.self, from: data) else { return }
                    Task { @MainActor [weak self] in
                        await self?.finishAuthorization(id: id, success: completion.success)
                    }
                }
                guard await manager.start(), !Task.isCancelled, authorizationID == id else {
                    throw RPCPayloadError.missingResult(method: "initialize")
                }
                let response = try await transport.sendRequest(method: "account/login/start", params: ["type": AnyCodable("chatgpt")], timeoutSeconds: 15)
                let login = try CodexAccountConnection.decode(response, as: LoginStart.self)
                guard !Task.isCancelled, authorizationID == id,
                      let url = CodexAccountConnection.validatedLoginURL(login.authUrl), NSWorkspace.shared.open(url) else {
                    throw RPCPayloadError.invalidPayload(method: "login")
                }
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(180)) } catch { return }
                    await self?.finishAuthorization(id: id, success: false)
                }
            } catch {
                await manager.stop()
                await finishAuthorization(id: id, success: false)
                removeUnusedHome(id)
            }
        }
    }

    func cancelAuthorization() async {
        browserFlow?.cancel()
        browserFlow = nil
        completingBrowserAuthorization = false
        let id = authorizationID
        authorizationID = nil
        loginTask?.cancel()
        timeoutTask?.cancel()
        let manager = loginManager
        loginManager = nil
        await manager?.stop()
        if let id { removeUnusedHome(id) }
        isAuthorizing = false
    }

    private func authorizeInBrowser() {
        let flow = QueryOAuthFlow(provider: provider)
        browserFlow = flow
        isAuthorizing = true
        error = nil
        flow.onCode = { [weak self] code in
            Task { await self?.completeBrowserAuthorization(code) }
        }
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(600)) } catch { return }
            guard let self, browserFlow?.id == flow.id else { return }
            await cancelAuthorization()
            error = L10n.text("授权未完成，请重试。", "Authorization did not complete. Try again.")
        }
        loginTask = Task { [weak self] in
            do {
                let url = try await flow.startURL()
                guard let self, browserFlow?.id == flow.id, !Task.isCancelled else { return }
                guard NSWorkspace.shared.open(url) else { throw QueryAccountError.unavailable }
            } catch {
                guard let self, browserFlow?.id == flow.id else { return }
                await cancelAuthorization()
                self.error = L10n.text("授权未完成，请重试。", "Authorization did not complete. Try again.")
            }
        }
    }

    func completeBrowserAuthorization(_ code: String) async {
        guard let flow = browserFlow, isAuthorizing, !completingBrowserAuthorization else { return }
        completingBrowserAuthorization = true
        defer { completingBrowserAuthorization = false }
        do {
            let credential = try await flow.exchange(code)
            guard browserFlow?.id == flow.id, isAuthorizing else { return }
            var values: [String: Any] = ["accessToken": credential.accessToken, "refreshToken": credential.refreshToken ?? ""]
            if let expiry = credential.expiresAt { values["expires_at"] = expiry.timeIntervalSince1970 }
            let data = try JSONSerialization.data(withJSONObject: values)
            timeoutTask?.cancel()
            flow.cancel()
            browserFlow = nil
            isAuthorizing = false
            await importCredential(data, source: .independent)
        } catch {
            guard browserFlow?.id == flow.id else { return }
            await cancelAuthorization()
            self.error = L10n.text("授权未完成，请重试。", "Authorization did not complete. Try again.")
        }
    }

    private func finishAuthorization(id: UUID, success: Bool) async {
        guard authorizationID == id, !completingAuthorization else { return }
        completingAuthorization = true
        timeoutTask?.cancel()
        let manager = loginManager
        loginManager = nil
        await manager?.stop()
        defer {
            if authorizationID == id {
                authorizationID = nil
                isAuthorizing = false
                completingAuthorization = false
            }
            removeUnusedHome(id)
        }
        guard authorizationID == id else { return }
        guard success else {
            error = L10n.text("授权未完成，请重试。", "Authorization did not complete. Try again.")
            return
        }
        do {
            // 先保存已成功授权的身份。额度服务暂时失败不应丢失登录结果。
            guard let identity = LocalAccountImporter.discoverLocalIdentities(
                authFile: home(for: id).appendingPathComponent("auth.json")
            ).first else { throw RPCPayloadError.missingResult(method: "account") }
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                ofItemAtPath: home(for: id).appendingPathComponent("auth.json").path)
            let authorizedFile = home(for: id).appendingPathComponent("auth.json")
            try codexVault.save(Data(contentsOf: authorizedFile), id: "codex-" + id.uuidString)
            try FileManager.default.removeItem(at: authorizedFile)
            let previous = accounts.first { $0.accountKey == identity.accountKey }
            accounts.removeAll { $0.accountKey == identity.accountKey }
            accounts.append(ManagedCodexAccount(accountKey: identity.accountKey, directoryID: id,
                                               name: previous?.name ?? identity.displayName,
                                               source: .independent, status: .unverified))
            persist()
            if let previous {
                if previous.source == .imported || previous.source == .local {
                    try? deleteCredential(previous.directoryID)
                } else {
                    try? codexVault.remove(id: "codex-" + previous.directoryID.uuidString)
                    removeUnusedHome(previous.directoryID)
                }
            }
            if let account = accounts.first(where: { $0.directoryID == id }) {
                await verify(account)
                select(identity.accountKey)
            }
        } catch {
            guard authorizationID == id else { return }
            self.error = L10n.text("无法刷新此账号，请重新授权后重试。", "Unable to refresh this account. Authorize it again and retry.")
        }
    }

    private func home(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func removeUnusedHome(_ id: UUID) {
        guard !(authorizationID == id && completingAuthorization) else { return }
        guard !accounts.contains(where: { $0.directoryID == id }) else { return }
        // 仅清理本功能创建的单个授权目录，绝不触碰用户的 Codex 目录。
        try? FileManager.default.removeItem(at: home(for: id))
    }
    private func persist() { defaults.set(try? JSONEncoder().encode(accounts), forKey: storageKey) }
    private struct LoginStart: Decodable { let authUrl: String }
    private struct LoginCompletion: Decodable, Sendable { let success: Bool }
}
