// 账号浏览与当前工具状态隔离；独立授权只在用户明确点击时启动。
import AppKit
import Combine
import Foundation

@MainActor
final class CodexAccountsStore: ObservableObject {
    @Published private(set) var selectedKey: String = ""
    @Published private(set) var accounts: [ManagedCodexAccount] = []
    @Published private(set) var snapshots: [RateLimitSnapshotRecord] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isAuthorizing = false
    @Published var error: String?
    private let reader: CodexAccountQuotaReader
    private let defaults: UserDefaults
    private let root: URL
    private var generation = 0
    private var loginManager: CodexProcessManager?
    private var loginTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var authorizationID: UUID?
    private var completingAuthorization = false
    private static let storageKey = "QuotaLens.managedCodexAccounts"

    init(database: SQLiteDatabase, defaults: UserDefaults = .standard, root: URL? = nil,
         reader: CodexAccountQuotaReader? = nil) {
        self.reader = reader ?? CodexAccountQuotaReader(database: database)
        self.defaults = defaults
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuotaLens/CodexAccounts", isDirectory: true)
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([ManagedCodexAccount].self, from: data) {
            accounts = saved
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
        Set(state.storedAccountKeys(for: .codex) + accounts.map(\.accountKey) + [state.account?.accountKey].compactMap { $0 }).sorted()
    }

    func select(_ key: String) {
        guard selectedKey != key else { return }
        generation += 1
        selectedKey = key
        snapshots = []
        error = nil
    }

    func loadSelection(refresh: Bool) async {
        let key = selectedKey
        guard !key.isEmpty else { return }
        generation += 1
        let request = generation
        if let cached = try? await reader.cached(accountKey: key), request == generation {
            snapshots = cached
        }
        guard !Task.isCancelled, request == generation else { return }
        guard refresh, !isRefreshing, !isAuthorizing,
              let account = accounts.first(where: { $0.accountKey == key }) else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let result = try await reader.refresh(homeURL: home(for: account.directoryID), expectedAccountKey: key)
            guard request == generation, selectedKey == key else { return }
            snapshots = result.2
            error = nil
        } catch {
            guard request == generation else { return }
            self.error = L10n.text("无法刷新此账号，请重新授权后重试。", "Unable to refresh this account. Authorize it again and retry.")
        }
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
            let previous = accounts.first { $0.accountKey == identity.accountKey }
            accounts.removeAll { $0.accountKey == identity.accountKey }
            accounts.append(ManagedCodexAccount(accountKey: identity.accountKey, directoryID: id,
                                               name: previous?.name ?? identity.displayName))
            persist()
            if let previous { removeUnusedHome(previous.directoryID) }
            select(identity.accountKey)
            let result = try await reader.refresh(homeURL: home(for: id), expectedAccountKey: identity.accountKey)
            guard authorizationID == id, selectedKey == result.0 else { return }
            snapshots = result.2
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
    private func persist() { defaults.set(try? JSONEncoder().encode(accounts), forKey: Self.storageKey) }
    private struct LoginStart: Decodable { let authUrl: String }
    private struct LoginCompletion: Decodable, Sendable { let success: Bool }
}
