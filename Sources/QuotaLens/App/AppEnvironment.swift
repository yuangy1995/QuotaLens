// QuotaLens 全局依赖注入与生命周期协调器 (后台异步流式加载，零主线程阻塞)

import Foundation
import SwiftUI
import AppKit
import Combine
import SQLite3

@MainActor
public final class AppEnvironment: ObservableObject {
    public static let shared = AppEnvironment()
    private static let primaryQuotaLimitId = "codex"

    public let state: AppState
    public let database: SQLiteDatabase
    public let repositories: Repositories
    public let transport: JSONRPCTransport
    public let processManager: CodexProcessManager
    public let accountProbe: AccountProbeActor
    public let updateManager: UpdateManager
    public let usageQueryFacade: UsageQueryFacade
    public let scanCoordinator: CodexUsageScanCoordinator

    private var refreshLoopTask: Task<Void, Never>?
    private var serverRecoveryTask: Task<Void, Never>?
    private var resetCreditReminderTask: Task<Void, Never>?
    private var subscriptionEntitlementRetryTask: Task<Void, Never>?
    private var notificationHandlersRegistered = false
    private var isFetchingServerSnapshot = false
    private var isFetchingSubscriptionEntitlement = false
    private var accountDataGeneration = 0
    private var refreshDataRequestGeneration = 0
    private var serverSnapshotRequestGeneration = 0
    private var subscriptionEntitlementRequestGeneration = 0
    private var serverSnapshotInFlightAccountKey: String?
    private var subscriptionEntitlementInFlightAccountKey: String?
    private var menuBarController: MenuBarStatusItemController?
    private var themeModeCancellable: AnyCancellable?
    private var systemAppearanceObserver: NSObjectProtocol?
    private var serverAccountDisplayNames: [String: String] = [:]
    private var resetCreditStatesByAccountKey: [String: AccountResetCreditState] = [:]
    private static let serverRetryDelaysSeconds: [UInt64] = [3, 10, 30]
    private static let subscriptionRetryDelaysSeconds: [UInt64] = [30, 120, 300, 900]

    private struct AccountResetCreditState: Sendable {
        let accountKey: String
        let availableCount: Int
        let credits: [ResetCreditDisplay]
    }

    private init() {
        self.state = AppState()

        // 1. 初始化本地 SQLite
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbDir = appSupport.appendingPathComponent("QuotaLens", isDirectory: true)
        let dbPath = dbDir.appendingPathComponent("quotalens.sqlite").path

        var initializationWarning: String?
        let initializedDatabase: SQLiteDatabase
        do {
            DevelopmentDatabaseReset.resetIfLegacySyntheticDataExists(databasePath: dbPath)
            let primaryDatabase = try SQLiteDatabase(path: dbPath)
            try SchemaMigrations.migrate(database: primaryDatabase)
            initializedDatabase = primaryDatabase
        } catch {
            let fallbackPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("QuotaLens-Recovery-\(UUID().uuidString).sqlite")
                .path
            do {
                let recoveryDatabase = try SQLiteDatabase(path: fallbackPath)
                try SchemaMigrations.migrate(database: recoveryDatabase)
                initializedDatabase = recoveryDatabase
                initializationWarning = L10n.format(
                    "Local database initialization failed, using a temporary recovery database: %@",
                    zhHans: "本地数据库初始化失败，已使用临时恢复数据库：%@",
                    error.localizedDescription
                )
            } catch let recoveryError {
                do {
                    let memoryDatabase = try SQLiteDatabase(path: ":memory:")
                    try SchemaMigrations.migrate(database: memoryDatabase)
                    initializedDatabase = memoryDatabase
                    initializationWarning = L10n.format(
                        "Persistent storage is unavailable; using an in-memory recovery database for this launch. Primary: %@ · Recovery: %@",
                        zhHans: "持久化存储不可用；本次启动已使用内存恢复数据库。主库：%@ · 恢复库：%@",
                        error.localizedDescription,
                        recoveryError.localizedDescription
                    )
                } catch let memoryError {
                    initializedDatabase = SQLiteDatabase.disconnectedFallback()
                    initializationWarning = L10n.format(
                        "Local storage is unavailable; quota monitoring remains available without persistence. Primary: %@ · Recovery: %@ · Memory: %@",
                        zhHans: "本地存储不可用；额度监控仍可继续，但本次不会持久化。主库：%@ · 恢复库：%@ · 内存库：%@",
                        error.localizedDescription,
                        recoveryError.localizedDescription,
                        memoryError.localizedDescription
                    )
                }
            }
        }
        self.database = initializedDatabase
        self.state.appInitializationWarningText = initializationWarning

        self.repositories = Repositories(database: database)
        self.transport = JSONRPCTransport()
        self.processManager = CodexProcessManager(transport: transport)
        self.accountProbe = AccountProbeActor(transport: transport, repositories: repositories)
        self.updateManager = UpdateManager()
        self.usageQueryFacade = UsageQueryFacade(database: database)
        self.scanCoordinator = CodexUsageScanCoordinator.shared
        self.scanCoordinator.configure(database: database)
        self.installThemeAppearanceObservers()
        self.applyThemeAppearance()
        self.registerRPCNotifications()
        self.refreshLoginItemState()

        // 2. 立即导入本地 ~/.codex 真实账号 (0.1ms 完成，首帧立即可见)
        _ = LocalAccountImporter.importLocalAccounts(into: repositories)
        self.state.accountDisplayNames = LocalAccountImporter.displayNamesByAccountKey()
        let loadedAccounts = (try? repositories.getAllAccounts()) ?? []
        if let firstAcc = loadedAccounts.first {
            self.state.account = firstAcc
            self.state.selectedAccountKey = firstAcc.accountKey
            self.state.allAccounts = [firstAcc]
        }
        let localPeriod = ChatGPTSubscriptionClient.localSubscriptionPeriodFromAuth()
        self.state.applyLocalSubscriptionPeriodFallback(startsAt: localPeriod.startsAt, endsAt: localPeriod.endsAt)

        // 3. 后台连接真实服务。
        Task(priority: .utility) { [weak self] in
            guard let self = self else { return }
            await self.backgroundBootstrap()
        }

        // 4. 启动即扫描本地 Codex 记录；不要被服务连接阻塞。
        Task(priority: .utility) { [weak self] in
            guard let self = self else { return }
            if UsageFeatureFlags.shared.isAnalyticsEnabled {
                await self.scanCoordinator.scanNow()
            }
        }

        if UsageFeatureFlags.shared.isOverlayEnabled {
            CodexUsageOverlayController.shared.setEnabled(true, environment: self)
        }

        // 5. 立即触发首帧数据刷新
        Task { @MainActor [weak self] in
            await self?.refreshData()
        }

        // 6. 启动可配置的周期性状态刷新，默认 1 分钟。
        self.scheduleRefreshTimer()

        // 7. 用 Web entitlement 后台补齐订阅周期、续费/降级状态。
        Task { @MainActor [weak self] in
            _ = await self?.refreshSubscriptionEntitlementIfPossible()
        }
    }

    private func scheduleRefreshTimer() {
        refreshLoopTask?.cancel()

        let intervalSeconds = UInt64(state.refreshIntervalSeconds)
        refreshLoopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
                } catch {
                    return
                }

                if Task.isCancelled { return }
                await self?.refreshData()
            }
        }
    }

    public func setRefreshInterval(seconds: Int) {
        state.setRefreshInterval(seconds: seconds)
        scheduleRefreshTimer()
    }

    public func setDockIconHidden(_ hidden: Bool) {
        state.setDockIconHidden(hidden)
        applyDockIconVisibility()
    }

    public func setResetCreditReminderEnabled(_ enabled: Bool) {
        state.setResetCreditReminderEnabled(enabled)
        scheduleResetCreditReminderTimer()
    }

    public func acknowledgeResetCreditReminder() {
        state.acknowledgeActiveResetCreditReminder()
        scheduleResetCreditReminderTimer()
    }

    public func snoozeResetCreditReminder(hours: Int) {
        state.snoozeActiveResetCreditReminder(hours: hours)
        scheduleResetCreditReminderTimer()
    }

    public func consumeResetCredit(_ credit: ResetCreditDisplay) async throws -> ConsumeRateLimitResetCreditOutcome {
        guard credit.isValidAvailable() else {
            throw NSError(
                domain: "QuotaLens.ResetCredit",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.text("这张重置卡当前不可用。", "This reset card is not currently available.")]
            )
        }

        let currentStatus = await processManager.getStatus()
        if !currentStatus.isConnected {
            let started = await processManager.start()
            state.connectionStatus = await processManager.getStatus()
            guard started else {
                throw NSError(
                    domain: "QuotaLens.ResetCredit",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: L10n.text("无法连接 Codex，暂时不能使用重置卡。", "Codex is not connected, so the reset card cannot be used yet.")]
                )
            }
        }

        let params: [String: AnyCodable] = [
            "creditId": AnyCodable(credit.id),
            "idempotencyKey": AnyCodable(UUID().uuidString)
        ]
        let payload = try await rpcPayload(
            ConsumeRateLimitResetCreditResponse.self,
            method: "account/rateLimitResetCredit/consume",
            params: params,
            timeoutSeconds: 10.0
        )
        let outcome = payload.value?.outcome ?? .nothingToReset
        await refreshData()
        return outcome
    }

    public func applyDockIconVisibility() {
        guard let app = NSApp else { return }
        app.setActivationPolicy(state.hideDockIcon ? .accessory : .regular)
    }

    public func applyThemeAppearance() {
        guard let app = NSApp else { return }

        let appearance: NSAppearance?
        switch state.themeMode {
        case .light:
            appearance = NSAppearance(named: .aqua)
        case .dark:
            appearance = NSAppearance(named: .darkAqua)
        case .system:
            appearance = nil
        }

        app.appearance = appearance
        app.windows.forEach { $0.appearance = appearance }
        menuBarController?.refreshAppearance()
    }

    public func prepareForMainWindowActivation() {
        menuBarController?.closePopoverAndSuppressOpening()
    }

    @discardableResult
    public func focusExistingMainWindow() -> Bool {
        prepareForMainWindowActivation()
        guard let window = NSApp.windows.first(where: isMainWindow) else {
            return false
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    public func openOrFocusMainWindow(createWindow: () -> Void) {
        if focusExistingMainWindow() {
            return
        }
        prepareForMainWindowActivation()
        createWindow()
        DispatchQueue.main.async { [weak self] in
            if let window = NSApp.windows.first(where: { self?.isMainWindow($0) == true }) {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    public func setLaunchAtLogin(enabled: Bool) {
        do {
            try LoginItemManager.setEnabled(enabled)
            refreshLoginItemState()
        } catch {
            refreshLoginItemState()
            state.launchAtLoginStatusText = L10n.format("Failed: %@", zhHans: "设置失败：%@", error.localizedDescription)
        }
    }

    public func refreshLoginItemState() {
        let loginState = LoginItemManager.currentState()
        state.launchAtLoginEnabled = loginState.isEnabled
        state.launchAtLoginStatusText = loginState.description
    }

    public func installStartupMenuBarController() {
        installMenuBarController(
            onOpenMainWindow: { [weak self] in
                guard let self else { return }
                if !self.focusExistingMainWindow() {
                    NSApp.activate(ignoringOtherApps: true)
                }
            },
            onRefresh: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.refreshAllData()
                }
            }
        )
    }

    private func isMainWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == "main" || window.title == "QuotaLens"
    }

    public func installMenuBarController(
        onOpenMainWindow: @escaping () -> Void,
        onRefresh: @escaping () -> Void
    ) {
        if let menuBarController {
            menuBarController.updateActions(
                onOpenMainWindow: onOpenMainWindow,
                onRefresh: onRefresh,
                onAcknowledgeResetCreditReminder: { [weak self] in
                    self?.acknowledgeResetCreditReminder()
                },
                onSnoozeResetCreditReminder: { [weak self] hours in
                    self?.snoozeResetCreditReminder(hours: hours)
                }
            )
        } else {
            menuBarController = MenuBarStatusItemController(
                state: state,
                usageFacade: usageQueryFacade,
                onOpenMainWindow: onOpenMainWindow,
                onRefresh: onRefresh,
                onAcknowledgeResetCreditReminder: { [weak self] in
                    self?.acknowledgeResetCreditReminder()
                },
                onSnoozeResetCreditReminder: { [weak self] hours in
                    self?.snoozeResetCreditReminder(hours: hours)
                }
            )
        }
    }

    private func installThemeAppearanceObservers() {
        themeModeCancellable = state.$themeMode
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.applyThemeAppearance()
                }
            }

        systemAppearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.state.themeMode == .system else { return }
                self?.applyThemeAppearance()
            }
        }
    }

    private func scheduleResetCreditReminderTimer() {
        resetCreditReminderTask?.cancel()
        state.pruneResetCreditReminderState()

        guard let plan = state.nextResetCreditReminderPlan(now: Date()) else {
            state.updateNextResetCreditReminderAt(nil)
            return
        }

        if plan.shouldFireNow {
            triggerResetCreditReminder(plan)
            return
        }

        state.updateNextResetCreditReminderAt(plan.dueAt)
        let delay = max(0, plan.dueAt.timeIntervalSinceNow)
        resetCreditReminderTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            self?.fireDueResetCreditReminder()
        }
    }

    private func fireDueResetCreditReminder() {
        guard let plan = state.nextResetCreditReminderPlan(now: Date()), plan.shouldFireNow else {
            scheduleResetCreditReminderTimer()
            return
        }
        triggerResetCreditReminder(plan)
    }

    private func triggerResetCreditReminder(_ plan: ResetCreditReminderPlan) {
        state.activateResetCreditReminder(plan)
        scheduleResetCreditReminderTimer()
    }

    @discardableResult
    private func refreshSubscriptionEntitlementIfPossible(scheduleRetryOnFailure: Bool = true) async -> Bool {
        let accountKeyAtStart = currentStateAccountKey()
        if isFetchingSubscriptionEntitlement && subscriptionEntitlementInFlightAccountKey == accountKeyAtStart {
            return state.subscriptionRenewalState != .unknown
        }

        subscriptionEntitlementRequestGeneration += 1
        let requestGeneration = subscriptionEntitlementRequestGeneration
        isFetchingSubscriptionEntitlement = true
        subscriptionEntitlementInFlightAccountKey = accountKeyAtStart
        defer {
            if requestGeneration == subscriptionEntitlementRequestGeneration {
                isFetchingSubscriptionEntitlement = false
                subscriptionEntitlementInFlightAccountKey = nil
            }
        }

        let localPeriod = ChatGPTSubscriptionClient.localSubscriptionPeriodFromAuth()
        if isSubscriptionRequestCurrent(requestGeneration, accountKey: accountKeyAtStart) {
            state.applyLocalSubscriptionPeriodFallback(startsAt: localPeriod.startsAt, endsAt: localPeriod.endsAt)
        }

        do {
            let snapshot = try await ChatGPTSubscriptionClient.fetch()
            guard isSubscriptionRequestCurrent(requestGeneration, accountKey: accountKeyAtStart) else {
                return false
            }
            state.applySubscriptionEntitlement(snapshot)
            cancelSubscriptionEntitlementRetry()
            if state.nearestResetCredit != nil {
                state.pruneResetCreditReminderState()
                scheduleResetCreditReminderTimer()
            }
            return true
        } catch {
            guard isSubscriptionRequestCurrent(requestGeneration, accountKey: accountKeyAtStart) else {
                return false
            }
            state.markSubscriptionEntitlementUnavailable(error.localizedDescription)
            if scheduleRetryOnFailure {
                scheduleSubscriptionEntitlementRetry()
            }
            if state.nearestResetCredit != nil {
                state.pruneResetCreditReminderState()
                scheduleResetCreditReminderTimer()
            }
            return false
        }
    }

    private func scheduleSubscriptionEntitlementRetry() {
        guard subscriptionEntitlementRetryTask == nil else { return }
        subscriptionEntitlementRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.subscriptionEntitlementRetryTask = nil }

            var attempt = 0
            while !Task.isCancelled {
                let delay = Self.subscriptionRetryDelaysSeconds[min(attempt, Self.subscriptionRetryDelaysSeconds.count - 1)]
                attempt += 1
                do {
                    try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                } catch {
                    return
                }
                if await self.refreshSubscriptionEntitlementIfPossible(scheduleRetryOnFailure: false) {
                    return
                }
            }
        }
    }

    private func cancelSubscriptionEntitlementRetry() {
        subscriptionEntitlementRetryTask?.cancel()
        subscriptionEntitlementRetryTask = nil
    }

    /// 后台异步启动逻辑
    private func backgroundBootstrap() async {
        // 1. 连接真实 Codex App Server 并执行在线探针
        await connectCodex()

        // 2. 刷新 UI 状态
        await refreshData()
    }

    /// 兼容旧入口：当前版本不在 UI 中提供手动切换。
    public func selectAccount(accountKey: String) {
        guard state.selectedAccountKey != accountKey else {
            Task {
                await refreshData()
            }
            return
        }
        beginAccountScopeChange()
        state.selectedAccountKey = accountKey
        Task {
            await refreshData()
        }
    }

    /// 导入本地 ~/.codex 账号
    public func importLocalAccount() {
        let list = LocalAccountImporter.importLocalAccounts(into: repositories)
        state.accountDisplayNames = LocalAccountImporter.displayNamesByAccountKey()
        if let first = list.first {
            if state.selectedAccountKey != first.accountKey {
                beginAccountScopeChange()
            }
            state.selectedAccountKey = first.accountKey
        }
        Task {
            await refreshData()
        }
    }

    /// 手动添加新账户
    public func addAccount(email: String, planType: String) {
        let now = Int64(Date().timeIntervalSince1970)
        let key = AccountIdentity.stableAccountKey(from: email)
        let record = AccountRecord(
            accountKey: key,
            emailHash: AccountIdentity.emailHash(from: email),
            planType: planType,
            firstSeenAt: now,
            lastSeenAt: now
        )
        try? repositories.upsertAccount(record)
        state.accountDisplayNames[key] = email
        if state.selectedAccountKey != key {
            beginAccountScopeChange()
        }
        state.selectedAccountKey = key
        Task {
            await refreshData()
        }
    }

    /// 删除指定账户
    public func deleteAccount(accountKey: String) {
        try? repositories.deleteAccount(accountKey: accountKey)
        if state.selectedAccountKey == accountKey {
            beginAccountScopeChange()
            state.selectedAccountKey = nil
        }
        Task {
            await refreshData()
        }
    }

    /// 连接真实 Codex App Server
    public func connectCodex() async {
        await fetchServerSnapshotIfPossible()

        let success = await processManager.start()
        let status = await processManager.getStatus()
        if !state.connectionStatus.isConnected {
            self.state.connectionStatus = status
        }

        if success {
            if !state.hasCurrentServerQuota {
                _ = await fetchConnectedServerSnapshotIfPossible(scheduleRetryOnFailure: false)
            }
            await refreshData(fetchServer: false)
            if !state.hasQuotaSnapshot {
                scheduleServerRecovery()
            }
        }
    }

    /// 全量刷新数据视图
    public func refreshData(fetchServer: Bool = true, scheduleRetryOnFailure: Bool = true) async {
        refreshDataRequestGeneration += 1
        let requestGeneration = refreshDataRequestGeneration
        state.isRefreshing = true
        defer {
            if requestGeneration == refreshDataRequestGeneration {
                state.isRefreshing = false
                state.lastRefreshTime = Date()
            }
        }

        do {
            if fetchServer {
                await fetchServerSnapshotIfPossible(scheduleRetryOnFailure: scheduleRetryOnFailure)
                guard requestGeneration == refreshDataRequestGeneration else { return }
            }

            // 1. 只展示当前 Codex 账号。历史账号保留在本地库里，但不进入当前界面。
            var displayNames = LocalAccountImporter.displayNamesByAccountKey()
            for (key, value) in serverAccountDisplayNames {
                displayNames[key] = value
            }
            state.accountDisplayNames = displayNames

            let storedAccounts = try repositories.getAllAccounts()
            if let selected = state.selectedAccountKey, let matched = storedAccounts.first(where: { $0.accountKey == selected }) {
                state.account = matched
                state.allAccounts = [matched]
            } else if let firstAcc = storedAccounts.first {
                state.account = firstAcc
                state.selectedAccountKey = firstAcc.accountKey
                state.allAccounts = [firstAcc]
            } else {
                state.account = nil
                state.allAccounts = []
            }

            let accKey = state.account?.accountKey ?? "acc_local"

            // 2. 读取同账号仍在当前窗口内的主额度快照。服务端短暂失败时继续展示最后一次成功结果。
            if !applyCachedQuotaSnapshotIfAvailable(for: accKey) {
                clearQuotaSnapshotState()
                if scheduleRetryOnFailure {
                    scheduleServerRecovery()
                }
            }
            restoreResetCreditState(for: accKey, snapshot: state.latestRateLimit)
            await refreshSubscriptionEntitlementIfPossible(scheduleRetryOnFailure: scheduleRetryOnFailure)
        } catch {
            // 刷新容错
        }
    }

    /// 刷新所有用户可见数据：本地 Codex 用量先完成索引，再读取服务器额度快照。
    public func refreshAllData(fetchServer: Bool = true, scheduleRetryOnFailure: Bool = true) async {
        if UsageFeatureFlags.shared.isAnalyticsEnabled {
            await scanCoordinator.scanNow()
        }
        await refreshData(fetchServer: fetchServer, scheduleRetryOnFailure: scheduleRetryOnFailure)
    }

    private func currentStateAccountKey() -> String? {
        state.selectedAccountKey ?? state.account?.accountKey
    }

    @discardableResult
    private func fetchConnectedServerSnapshotIfPossible(scheduleRetryOnFailure: Bool = true) async -> Bool {
        guard case .connected(let version, let binaryPath) = await processManager.getStatus() else {
            if scheduleRetryOnFailure {
                scheduleServerRecovery()
            }
            return false
        }

        let requestGeneration = beginServerSnapshotRequest()
        defer { finishServerSnapshotRequest(requestGeneration) }

        do {
            async let accountPayload = try? rpcPayload(AccountReadResult.self, method: "account/read")
            async let rateLimitsPayload = try? rpcPayload(RateLimitsReadResult.self, method: "account/rateLimits/read")
            let account = await accountPayload
            let rateLimits = await rateLimitsPayload

            guard isServerSnapshotRequestCurrent(requestGeneration) else {
                return false
            }

            guard account != nil || rateLimits != nil else {
                throw NSError(domain: "QuotaLens.RPC", code: -1, userInfo: [NSLocalizedDescriptionKey: L10n.text("暂时没有获取到额度数据", "Quota data was not available yet")])
            }

            let snapshot = CodexServerSnapshot(
                version: version,
                binaryPath: binaryPath,
                account: account?.value,
                accountRawJson: account?.rawJson ?? "{}",
                rateLimits: rateLimits?.value,
                rateLimitsRawJson: rateLimits?.rawJson ?? "{}"
            )

            try persistServerSnapshot(snapshot)
            guard isServerSnapshotRequestCurrent(requestGeneration) else {
                return false
            }
            state.connectionStatus = .connected(version: version, binaryPath: binaryPath)
            if state.hasCurrentServerQuota {
                cancelServerRecovery()
                return true
            }

            if scheduleRetryOnFailure {
                scheduleServerRecovery()
            }
            return false
        } catch {
            if scheduleRetryOnFailure {
                scheduleServerRecovery()
            }
            return false
        }
    }

    private func rpcPayload<T: Decodable>(
        _ type: T.Type,
        method: String,
        params: [String: AnyCodable] = [:],
        timeoutSeconds: Double = 5.0
    ) async throws -> (value: T?, rawJson: String) {
        let response = try await transport.sendRequest(method: method, params: params, timeoutSeconds: timeoutSeconds)
        if let error = response.error {
            throw NSError(domain: "QuotaLens.RPC", code: error.code, userInfo: [NSLocalizedDescriptionKey: error.message])
        }
        guard let result = response.result else {
            return (nil, "{}")
        }
        let data = try JSONEncoder().encode(result)
        return (try? JSONDecoder().decode(T.self, from: data), String(data: data, encoding: .utf8) ?? "{}")
    }

    @discardableResult
    private func fetchServerSnapshotIfPossible(scheduleRetryOnFailure: Bool = true) async -> Bool {
        let accountKeyAtStart = currentStateAccountKey()
        if isFetchingServerSnapshot && serverSnapshotInFlightAccountKey == accountKeyAtStart {
            return state.hasCurrentServerQuota
        }

        let requestGeneration = beginServerSnapshotRequest()
        isFetchingServerSnapshot = true
        defer { finishServerSnapshotRequest(requestGeneration) }

        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try CodexServerSnapshotClient.fetch()
            }.value

            guard isServerSnapshotRequestCurrent(requestGeneration) else {
                return false
            }
            try persistServerSnapshot(snapshot)
            guard isServerSnapshotRequestCurrent(requestGeneration) else {
                return false
            }
            state.connectionStatus = .connected(version: snapshot.version, binaryPath: snapshot.binaryPath)
            if state.hasCurrentServerQuota {
                cancelServerRecovery()
                return true
            }

            if scheduleRetryOnFailure {
                scheduleServerRecovery()
            }
            return false
        } catch {
            guard isServerSnapshotRequestCurrent(requestGeneration) else {
                return false
            }
            let accountKey = state.selectedAccountKey ?? state.account?.accountKey ?? "acc_local"
            if applyCachedQuotaSnapshotIfAvailable(for: accountKey) {
                restoreResetCreditState(for: accountKey, snapshot: state.latestRateLimit)
            } else {
                clearQuotaSnapshotState()
                restoreResetCreditState(for: accountKey, snapshot: nil)
            }
            if !state.connectionStatus.isConnected {
                state.connectionStatus = .failed(L10n.format("Quota refresh failed: %@", zhHans: "额度刷新失败：%@", error.localizedDescription))
            }
            if scheduleRetryOnFailure {
                scheduleServerRecovery()
            }
            let now = Int64(Date().timeIntervalSince1970)
            let event = QuotaEventRecord(
                eventId: "server_probe_failed_\(now)",
                occurredAt: now,
                eventType: "server_probe_failed",
                severity: "warning",
                limitId: nil,
                oldCycleId: nil,
                newCycleId: nil,
                evidenceJson: "{\"message\":\"\(jsonEscaped(error.localizedDescription))\"}"
            )
            try? repositories.insertQuotaEvent(event)
            return false
        }
    }

    private func scheduleServerRecovery() {
        guard serverRecoveryTask == nil else { return }
        state.isRetryingServerConnection = true

        serverRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.serverRecoveryTask = nil
                self.state.isRetryingServerConnection = false
            }

            for delaySeconds in Self.serverRetryDelaysSeconds {
                do {
                    try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
                } catch {
                    return
                }

                if Task.isCancelled { return }
                if await self.recoverServerSnapshotOnce() {
                    return
                }
            }
        }
    }

    private func cancelServerRecovery() {
        serverRecoveryTask?.cancel()
        serverRecoveryTask = nil
        state.isRetryingServerConnection = false
    }

    private func recoverServerSnapshotOnce() async -> Bool {
        let currentStatus = await processManager.getStatus()
        if !currentStatus.isConnected {
            _ = await processManager.start()
            state.connectionStatus = await processManager.getStatus()
        }

        if await fetchConnectedServerSnapshotIfPossible(scheduleRetryOnFailure: false) {
            await refreshData(fetchServer: false, scheduleRetryOnFailure: false)
            return state.hasQuotaSnapshot
        }

        await refreshData(fetchServer: true, scheduleRetryOnFailure: false)
        return state.hasQuotaSnapshot
    }

    private func latestPrimaryQuotaSnapshot(accountKey: String) throws -> RateLimitSnapshotRecord? {
        try repositories.getLatestRateLimitSnapshot(accountKey: accountKey, limitId: Self.primaryQuotaLimitId)
            ?? repositories.getLatestRateLimitSnapshot(accountKey: accountKey)
    }

    private func latestDisplayablePrimaryQuotaSnapshot(accountKey: String) throws -> RateLimitSnapshotRecord? {
        guard let snapshot = try latestPrimaryQuotaSnapshot(accountKey: accountKey) else {
            return nil
        }
        let now = Int64(Date().timeIntervalSince1970)
        return snapshot.isCurrentQuotaWindow(at: now) ? snapshot : nil
    }

    @discardableResult
    private func applyCachedQuotaSnapshotIfAvailable(for accountKey: String) -> Bool {
        guard let snapshot = try? latestDisplayablePrimaryQuotaSnapshot(accountKey: accountKey) else {
            return false
        }
        state.latestRateLimit = snapshot
        state.hasCurrentServerQuota = true
        return true
    }

    private func clearQuotaSnapshotState() {
        state.latestRateLimit = nil
        state.hasCurrentServerQuota = false
    }

    @discardableResult
    private func beginAccountScopeChange(
        invalidateServerSnapshot: Bool = true,
        invalidateRefreshRequests: Bool = true
    ) -> Int {
        accountDataGeneration += 1
        if invalidateRefreshRequests {
            refreshDataRequestGeneration += 1
        }

        subscriptionEntitlementRequestGeneration += 1
        isFetchingSubscriptionEntitlement = false
        subscriptionEntitlementInFlightAccountKey = nil

        if invalidateServerSnapshot {
            serverSnapshotRequestGeneration += 1
            isFetchingServerSnapshot = false
            serverSnapshotInFlightAccountKey = nil
        }

        cancelServerRecovery()
        cancelSubscriptionEntitlementRetry()
        resetCreditReminderTask?.cancel()
        resetCreditReminderTask = nil
        return accountDataGeneration
    }

    private func beginServerSnapshotRequest() -> Int {
        serverSnapshotRequestGeneration += 1
        isFetchingServerSnapshot = true
        serverSnapshotInFlightAccountKey = currentStateAccountKey()
        return serverSnapshotRequestGeneration
    }

    private func finishServerSnapshotRequest(_ requestGeneration: Int) {
        guard requestGeneration == serverSnapshotRequestGeneration else { return }
        isFetchingServerSnapshot = false
        serverSnapshotInFlightAccountKey = nil
    }

    private func isServerSnapshotRequestCurrent(_ requestGeneration: Int) -> Bool {
        requestGeneration == serverSnapshotRequestGeneration
    }

    private func isSubscriptionRequestCurrent(_ requestGeneration: Int, accountKey: String?) -> Bool {
        requestGeneration == subscriptionEntitlementRequestGeneration && currentStateAccountKey() == accountKey
    }

    private func persistServerSnapshot(_ snapshot: CodexServerSnapshot) throws {
        let now = Int64(Date().timeIntervalSince1970)
        var accountKey = state.selectedAccountKey ?? state.account?.accountKey ?? "acc_local"

        if let accountInfo = snapshot.account?.account {
            let identifier = accountInfo.stableIdentifier
            accountKey = AccountIdentity.stableAccountKey(from: identifier)
            if state.selectedAccountKey != accountKey {
                beginAccountScopeChange(invalidateServerSnapshot: false, invalidateRefreshRequests: false)
            }
            let record = AccountRecord(
                accountKey: accountKey,
                emailHash: AccountIdentity.emailHash(from: identifier),
                planType: accountInfo.planType,
                firstSeenAt: now,
                lastSeenAt: now
            )
            serverAccountDisplayNames[accountKey] = accountInfo.displayIdentifier
            state.accountDisplayNames[accountKey] = accountInfo.displayIdentifier
            state.selectedAccountKey = accountKey
            state.account = record
            state.allAccounts = [record]
            state.applyLocalSubscriptionPeriodFallback(
                startsAt: accountInfo.subscriptionStartsAt,
                endsAt: accountInfo.subscriptionEndsAt
            )
            // The online quota UI must not depend on local persistence. A
            // disconnected fallback keeps the live state and simply skips this
            // best-effort write.
            try? repositories.upsertAccount(record)
        }

        if let rateLimits = snapshot.rateLimits {
            updateResetCreditState(from: rateLimits.rateLimitResetCredits, accountKey: accountKey)
            let liveSnapshot = liveRateLimitSnapshot(
                from: rateLimits,
                accountKey: accountKey,
                observedAt: now,
                rawJson: snapshot.rateLimitsRawJson
            )
            let insertedCount = (try? persistRateLimits(
                rateLimits,
                accountKey: accountKey,
                observedAt: now,
                rawJson: snapshot.rateLimitsRawJson
            )) ?? 0
            if insertedCount > 0, applyCachedQuotaSnapshotIfAvailable(for: accountKey) {
                return
            }
            if let liveSnapshot {
                state.latestRateLimit = liveSnapshot
                state.hasCurrentServerQuota = true
            } else if !applyCachedQuotaSnapshotIfAvailable(for: accountKey) {
                clearQuotaSnapshotState()
            }
        } else {
            updateResetCreditState(from: nil, accountKey: accountKey)
            if !applyCachedQuotaSnapshotIfAvailable(for: accountKey) {
                clearQuotaSnapshotState()
            }
        }

    }

    private func liveRateLimitSnapshot(
        from dto: RateLimitsReadResult,
        accountKey: String,
        observedAt: Int64,
        rawJson: String
    ) -> RateLimitSnapshotRecord? {
        var candidates: [(fallbackID: String, limits: RateLimitsObject)] = []
        if let exact = dto.rateLimitsByLimitId?[Self.primaryQuotaLimitId] {
            candidates.append((Self.primaryQuotaLimitId, exact))
        }
        if let limits = dto.rateLimits {
            candidates.append((limits.limitId ?? Self.primaryQuotaLimitId, limits))
        }
        if let byLimitID = dto.rateLimitsByLimitId {
            for key in byLimitID.keys.sorted() where key != Self.primaryQuotaLimitId {
                if let limits = byLimitID[key] {
                    candidates.append((key, limits))
                }
            }
        }

        var seen = Set<String>()
        for candidate in candidates {
            let limitID = candidate.limits.limitId ?? candidate.fallbackID
            guard seen.insert(limitID).inserted else { continue }
            let detail: RateLimitWindowDetail
            let slot: String
            if let primary = candidate.limits.primary {
                detail = primary
                slot = "primary"
            } else if let secondary = candidate.limits.secondary {
                detail = secondary
                slot = "secondary"
            } else {
                continue
            }
            guard let rawUsedPercent = detail.usedPercent else { continue }
            let usedPercent = min(max(rawUsedPercent, 0), 100)
            return RateLimitSnapshotRecord(
                accountKey: accountKey,
                observedAt: observedAt,
                limitId: limitID,
                slot: slot,
                usedPercentMilli: Int((usedPercent * 1_000).rounded()),
                windowDurationMins: detail.windowDurationMins,
                resetsAt: detail.resetsAt,
                planType: candidate.limits.planType,
                rawJson: rawJson
            )
        }
        return nil
    }

    private func restoreResetCreditState(for accountKey: String, snapshot: RateLimitSnapshotRecord?) {
        if let creditsObject = resetCreditObject(from: snapshot) {
            updateResetCreditState(from: creditsObject, accountKey: accountKey)
            return
        }

        if let cachedState = resetCreditStatesByAccountKey[accountKey] {
            applyResetCreditState(cachedState)
            return
        }

        updateResetCreditState(from: nil, accountKey: accountKey)
    }

    private func resetCreditObject(from snapshot: RateLimitSnapshotRecord?) -> RateLimitResetCreditsObject? {
        guard let rawJson = snapshot?.rawJson,
              let data = rawJson.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RateLimitsReadResult.self, from: data) else {
            return nil
        }
        return decoded.rateLimitResetCredits
    }

    private func updateResetCreditState(from creditsObject: RateLimitResetCreditsObject?, accountKey: String) {
        let resetCreditState = makeResetCreditState(from: creditsObject, accountKey: accountKey)
        resetCreditStatesByAccountKey[accountKey] = resetCreditState
        applyResetCreditState(resetCreditState)
    }

    private func makeResetCreditState(from creditsObject: RateLimitResetCreditsObject?, accountKey: String) -> AccountResetCreditState {
        let credits = (creditsObject?.credits ?? [])
            .enumerated()
            .map { index, credit in
                ResetCreditDisplay(
                    id: credit.id ?? "reset_credit_\(index)_\(credit.grantedAt ?? 0)_\(credit.expiresAt ?? 0)",
                    accountKey: accountKey,
                    title: credit.title,
                    resetType: credit.resetType,
                    status: credit.status,
                    grantedAt: credit.grantedAt,
                    expiresAt: credit.expiresAt
                )
            }
            .sorted {
                switch ($0.expiresAt, $1.expiresAt) {
                case let (lhs?, rhs?): return lhs < rhs
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return $0.id < $1.id
                }
            }
        return AccountResetCreditState(
            accountKey: accountKey,
            availableCount: creditsObject?.availableCount ?? credits.filter(\.isAvailable).count,
            credits: credits
        )
    }

    private func applyResetCreditState(_ resetCreditState: AccountResetCreditState) {
        if let currentAccountKey = currentStateAccountKey(),
           currentAccountKey != resetCreditState.accountKey {
            return
        }
        state.replaceResetCredits(
            resetCreditState.credits,
            availableCount: resetCreditState.availableCount,
            accountKey: resetCreditState.accountKey
        )
        scheduleResetCreditReminderTimer()
    }

    private func persistRateLimits(
        _ dto: RateLimitsReadResult,
        accountKey: String,
        observedAt: Int64,
        rawJson: String
    ) throws -> Int {
        var seen: Set<String> = []
        var insertedCount = 0

        if let limits = dto.rateLimits {
            insertedCount += try persistRateLimitObject(
                limits,
                fallbackLimitId: limits.limitId ?? Self.primaryQuotaLimitId,
                accountKey: accountKey,
                observedAt: observedAt,
                rawJson: rawJson,
                seen: &seen
            )
        }

        if let byLimitId = dto.rateLimitsByLimitId {
            for (limitId, limits) in byLimitId {
                insertedCount += try persistRateLimitObject(
                    limits,
                    fallbackLimitId: limitId,
                    accountKey: accountKey,
                    observedAt: observedAt,
                    rawJson: rawJson,
                    seen: &seen
                )
            }
        }

        return insertedCount
    }

    private func persistRateLimitObject(
        _ limits: RateLimitsObject,
        fallbackLimitId: String,
        accountKey: String,
        observedAt: Int64,
        rawJson: String,
        seen: inout Set<String>
    ) throws -> Int {
        let limitId = limits.limitId ?? fallbackLimitId
        var insertedCount = 0
        if let primary = limits.primary {
            if try persistRateLimitWindow(
                primary,
                slot: "primary",
                limitId: limitId,
                planType: limits.planType,
                accountKey: accountKey,
                observedAt: observedAt,
                rawJson: rawJson,
                seen: &seen
            ) {
                insertedCount += 1
            }
        }
        if let secondary = limits.secondary {
            if try persistRateLimitWindow(
                secondary,
                slot: "secondary",
                limitId: limitId,
                planType: limits.planType,
                accountKey: accountKey,
                observedAt: observedAt,
                rawJson: rawJson,
                seen: &seen
            ) {
                insertedCount += 1
            }
        }
        return insertedCount
    }

    private func persistRateLimitWindow(
        _ detail: RateLimitWindowDetail,
        slot: String,
        limitId: String,
        planType: String?,
        accountKey: String,
        observedAt: Int64,
        rawJson: String,
        seen: inout Set<String>
    ) throws -> Bool {
        let uniqueKey = "\(limitId)|\(slot)"
        guard seen.insert(uniqueKey).inserted else { return false }
        guard let usedPercentValue = detail.usedPercent else { return false }

        let usedPercent = min(max(usedPercentValue, 0.0), 100.0)
        let record = RateLimitSnapshotRecord(
            accountKey: accountKey,
            observedAt: observedAt,
            limitId: limitId,
            slot: slot,
            usedPercentMilli: Int((usedPercent * 1000.0).rounded()),
            windowDurationMins: detail.windowDurationMins,
            resetsAt: detail.resetsAt,
            planType: planType,
            rawJson: rawJson
        )
        try repositories.insertRateLimitSnapshot(record)
        return true
    }

    private func registerRPCNotifications() {
        guard !notificationHandlersRegistered else { return }
        notificationHandlersRegistered = true
        Task {
            await transport.onNotification { [weak self] notification in
                Task { @MainActor [weak self] in
                    await self?.handleRPCNotification(notification)
                }
            }
        }
    }

    private func handleRPCNotification(_ notification: JSONRPCNotification) async {
        switch notification.method {
        case "account/rateLimits/updated":
            await accountProbe.probeRateLimits()
            await refreshData()
        default:
            break
        }
    }

    private func jsonEscaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// 一键重置所有数据与偏好配置，并重新开始数据索引与同步
    public func resetAllDataAndFactoryDefaults() async {
        state.isRefreshing = true
        defer { state.isRefreshing = false }

        // 1. 重置偏好设置 (UserDefaults)
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        UserDefaults.standard.synchronize()

        // 2. 恢复 Feature Flags 默认配置
        UsageFeatureFlags.shared.isAnalyticsEnabled = true
        UsageFeatureFlags.shared.isOverlayEnabled = false
        UsageFeatureFlags.shared.isAXSnappingEnabled = false
        UsageFeatureFlags.shared.isForecastEnabled = true

        // 3. 清空 SQLite 数据库所有表数据并重新初始化 Schema
        do {
            try database.execute(sql: "PRAGMA foreign_keys = OFF;")
            let allTables = try database.executeQuery(
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';"
            ) { stmt in
                String(cString: sqlite3_column_text(stmt, 0))
            }
            for table in allTables {
                try? database.execute(sql: "DROP TABLE IF EXISTS \(table);")
            }
            try database.execute(sql: "PRAGMA user_version = 0;")
            try database.execute(sql: "PRAGMA foreign_keys = ON;")
            try database.execute(sql: "VACUUM;")
            try SchemaMigrations.migrate(database: database)
        } catch {
            print("Database reset warning: \(error)")
        }

        // 4. 重置内存 AppState
        state.account = nil
        state.allAccounts = []
        state.selectedAccountKey = nil
        state.connectionStatus = .disconnected
        state.latestRateLimit = nil
        state.hasCurrentServerQuota = false
        state.resetCreditAvailableCount = 0
        state.resetCredits = []
        state.subscriptionStartsAt = nil
        state.subscriptionEndsAt = nil
        state.subscriptionPlanDisplayName = nil
        state.subscriptionRenewalState = .unknown
        state.subscriptionTargetPlanDisplayName = nil
        state.themeMode = .system
        state.quotaDisplayMode = .used
        state.refreshIntervalSeconds = AppState.defaultRefreshIntervalSeconds

        // 5. 重新触发全量数据扫描与重构
        await scanCoordinator.scanNow(forceRebuild: true)
        await refreshAllData(fetchServer: true, scheduleRetryOnFailure: true)
    }
}
