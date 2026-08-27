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
    private var resetCreditIdempotencyKeys: [String: String] = {
        guard let data = UserDefaults.standard.data(forKey: "QuotaLens.resetCreditIdempotencyKeys"),
              let keys = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return keys
    }()
    private static let serverRetryDelaysSeconds: [UInt64] = [3, 10, 30]
    private static let subscriptionRetryDelaysSeconds: [UInt64] = [30, 120, 300, 900]
    private static let resetCreditDetailsCacheDefaultsPrefix = "QuotaLens.resetCreditDetailsCache"
    private static let resetCreditIdempotencyKeysDefaultsKey = "QuotaLens.resetCreditIdempotencyKeys"

    private struct AccountResetCreditState: Codable, Sendable {
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
                initializationWarning = L10n.text(
                    "暂时无法读取原有用量记录，本次只显示临时记录。",
                    "Existing usage records cannot be read right now, so this launch will only show temporary records."
                )
            } catch {
                do {
                    let memoryDatabase = try SQLiteDatabase(path: ":memory:")
                    try SchemaMigrations.migrate(database: memoryDatabase)
                    initializedDatabase = memoryDatabase
                    initializationWarning = L10n.text(
                        "本地记录本次暂时不能保存，请稍后重试。",
                        "Local records cannot be saved for this launch. Try again later."
                    )
                } catch {
                    initializedDatabase = SQLiteDatabase.disconnectedFallback()
                    initializationWarning = L10n.text(
                        "本地存储暂时不可用，额度监控仍可运行，但本次不会保存本地用量记录。",
                        "Local storage is temporarily unavailable. Quota monitoring can still run, but local usage records will not be saved for this launch."
                    )
                }
            }
        }
        do {
            let recovery = try UsageAnalyticsRepository(
                database: initializedDatabase
            ).recoverIncompleteSessionDeletions(
                historyRootURL: CodexHistoryRootResolver.resolveRootURL()
            )
            if let message = recovery.message,
               recovery.finalizedCount > 0
                || recovery.rolledBackCount > 0
                || recovery.rollbackRequiredCount > 0 {
                initializationWarning = [initializationWarning, message]
                    .compactMap { $0 }
                    .joined(separator: "\n")
            }
        } catch {
            let message = (error as? SessionDeletionError)?.errorDescription ?? L10n.text(
                "上一次删除尚未完全处理；为避免数据不一致，本地用量更新已暂停。",
                "A previous deletion is not fully resolved. Local usage updates are paused to avoid inconsistent data."
            )
            initializationWarning = [initializationWarning, message]
                .compactMap { $0 }
                .joined(separator: "\n")
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
        let requestScopeKey = resetCreditRequestScopeKey(for: credit)
        let request = ConsumeRateLimitResetCreditRequest(
            creditId: credit.id,
            idempotencyKey: resetCreditIdempotencyKey(for: requestScopeKey)
        )
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

        let payload = try await rpcPayload(
            ConsumeRateLimitResetCreditResponse.self,
            method: ConsumeRateLimitResetCreditRequest.method,
            params: request.params,
            timeoutSeconds: 10.0
        )
        let outcome = payload.value?.outcome ?? .nothingToReset
        removeResetCreditIdempotencyKey(for: requestScopeKey)
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
            state.launchAtLoginStatusText = L10n.text(
                "设置失败，请检查系统权限后重试。",
                "Setup failed. Check system permissions and try again."
            )
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
            state.markSubscriptionEntitlementUnavailable(L10n.text(
                "订阅状态暂时无法读取，请稍后重试。",
                "Subscription status cannot be read right now. Try again later."
            ))
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
        resetCreditStatesByAccountKey.removeValue(forKey: accountKey)
        removeResetCreditIdempotencyKeys(for: accountKey)
        removePersistedResetCreditState(for: accountKey)
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
                state.connectionStatus = .failed(L10n.text(
                    "额度刷新未完成，请稍后重试。",
                    "Quota refresh did not finish. Try again later."
                ))
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

    private func latestQuotaSnapshots(accountKey: String) throws -> [RateLimitSnapshotRecord] {
        let primarySnapshots = try repositories.getLatestRateLimitSnapshots(
            accountKey: accountKey,
            limitId: Self.primaryQuotaLimitId
        )
        if !primarySnapshots.isEmpty {
            return primarySnapshots
        }
        return try repositories.getLatestRateLimitSnapshots(accountKey: accountKey)
    }

    private func latestDisplayableQuotaSnapshots(accountKey: String) throws -> [RateLimitSnapshotRecord] {
        let now = Int64(Date().timeIntervalSince1970)
        return try latestQuotaSnapshots(accountKey: accountKey)
            .filter { $0.isCurrentQuotaWindow(at: now) }
    }

    @discardableResult
    private func applyCachedQuotaSnapshotIfAvailable(for accountKey: String) -> Bool {
        guard let snapshots = try? latestDisplayableQuotaSnapshots(accountKey: accountKey),
              let snapshot = RateLimitSnapshotRecord.mostRestrictiveCurrentSnapshot(
                  from: snapshots,
                  at: Int64(Date().timeIntervalSince1970)
              ) else {
            return false
        }
        state.currentQuotaSnapshots = snapshots
        state.latestRateLimit = snapshot
        state.hasCurrentServerQuota = true
        return true
    }

    private func clearQuotaSnapshotState() {
        state.currentQuotaSnapshots = []
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

    private func resetCreditRequestScopeKey(for credit: ResetCreditDisplay) -> String {
        let accountKey = currentStateAccountKey() ?? credit.accountKey ?? "acc_local"
        return "\(accountKey)|\(credit.id)"
    }

    private func resetCreditIdempotencyKey(for scopeKey: String) -> String {
        if let existing = resetCreditIdempotencyKeys[scopeKey] {
            return existing
        }

        let generated = UUID().uuidString
        resetCreditIdempotencyKeys[scopeKey] = generated
        persistResetCreditIdempotencyKeys()
        return generated
    }

    private func removeResetCreditIdempotencyKey(for scopeKey: String) {
        guard resetCreditIdempotencyKeys.removeValue(forKey: scopeKey) != nil else { return }
        persistResetCreditIdempotencyKeys()
    }

    private func removeResetCreditIdempotencyKeys(for accountKey: String) {
        let prefix = "\(accountKey)|"
        let keysToRemove = resetCreditIdempotencyKeys.keys.filter { $0.hasPrefix(prefix) }
        guard !keysToRemove.isEmpty else { return }
        keysToRemove.forEach { resetCreditIdempotencyKeys.removeValue(forKey: $0) }
        persistResetCreditIdempotencyKeys()
    }

    private func persistResetCreditIdempotencyKeys() {
        guard let data = try? JSONEncoder().encode(resetCreditIdempotencyKeys) else { return }
        UserDefaults.standard.set(data, forKey: Self.resetCreditIdempotencyKeysDefaultsKey)
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
            let liveSnapshots = liveRateLimitSnapshots(
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
            let currentLiveSnapshots = liveSnapshots.filter { $0.isCurrentQuotaWindow(at: now) }
            if let liveSnapshot = RateLimitSnapshotRecord.mostRestrictiveCurrentSnapshot(
                from: currentLiveSnapshots,
                at: now
            ) {
                state.currentQuotaSnapshots = currentLiveSnapshots
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

    private func liveRateLimitSnapshots(
        from dto: RateLimitsReadResult,
        accountKey: String,
        observedAt: Int64,
        rawJson: String
    ) -> [RateLimitSnapshotRecord] {
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

        var snapshotsByLimitID: [String: [RateLimitSnapshotRecord]] = [:]
        var limitIDOrder: [String] = []
        var seen = Set<String>()
        for candidate in candidates {
            let limitID = candidate.limits.limitId ?? candidate.fallbackID
            if snapshotsByLimitID[limitID] == nil {
                snapshotsByLimitID[limitID] = []
                limitIDOrder.append(limitID)
            }

            let details: [(slot: String, detail: RateLimitWindowDetail?)] = [
                ("primary", candidate.limits.primary),
                ("secondary", candidate.limits.secondary)
            ]
            for (slot, detail) in details {
                guard let detail,
                      let rawUsedPercent = detail.usedPercent,
                      seen.insert("\(limitID)|\(slot)").inserted else {
                    continue
                }
                let usedPercent = min(max(rawUsedPercent, 0), 100)
                snapshotsByLimitID[limitID, default: []].append(
                    RateLimitSnapshotRecord(
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
                )
            }
        }

        for limitID in limitIDOrder {
            if let snapshots = snapshotsByLimitID[limitID], !snapshots.isEmpty {
                return snapshots
            }
        }
        return []
    }

    private func restoreResetCreditState(for accountKey: String, snapshot: RateLimitSnapshotRecord?) {
        updateResetCreditState(from: resetCreditObject(from: snapshot), accountKey: accountKey)
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
        let fallbackState = resetCreditStatesByAccountKey[accountKey]
            ?? persistedDetailedResetCreditState(for: accountKey)
        let resetCreditState = Self.makeResetCreditState(
            from: creditsObject,
            accountKey: accountKey,
            preserving: fallbackState
        )
        resetCreditStatesByAccountKey[accountKey] = resetCreditState
        updatePersistedResetCreditState(resetCreditState, from: creditsObject)
        applyResetCreditState(resetCreditState)
    }

    private static func makeResetCreditState(
        from creditsObject: RateLimitResetCreditsObject?,
        accountKey: String,
        preserving fallbackState: AccountResetCreditState? = nil,
        now: Date = Date()
    ) -> AccountResetCreditState {
        guard let creditsObject else {
            return fallbackState ?? emptyResetCreditState(accountKey: accountKey)
        }

        let detailedCredits = creditsObject.credits.map { credits in
            credits
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
        }

        if creditsObject.availableCount == nil, detailedCredits == nil {
            return fallbackState ?? emptyResetCreditState(accountKey: accountKey)
        }

        let detailedAvailableCount = detailedCredits?.filter { $0.isValidAvailable(now: now) }.count ?? 0
        let availableCount = max(0, creditsObject.availableCount ?? detailedAvailableCount)
        guard availableCount > 0 else {
            return emptyResetCreditState(accountKey: accountKey)
        }

        if let detailedCredits, !detailedCredits.isEmpty {
            return AccountResetCreditState(
                accountKey: accountKey,
                availableCount: availableCount,
                credits: detailedCredits
            )
        }

        // Codex 明细接口失败时仍会返回数量。此时保留上次已确认且尚未过期的明细，避免周期刷新把列表清空。
        let preservedCredits = Array(
            (fallbackState?.credits ?? [])
                .filter { $0.isValidAvailable(now: now) }
                .prefix(availableCount)
        )
        return AccountResetCreditState(
            accountKey: accountKey,
            availableCount: availableCount,
            credits: preservedCredits
        )
    }

    private static func emptyResetCreditState(accountKey: String) -> AccountResetCreditState {
        AccountResetCreditState(accountKey: accountKey, availableCount: 0, credits: [])
    }

    private func persistedDetailedResetCreditState(for accountKey: String) -> AccountResetCreditState? {
        guard let data = UserDefaults.standard.data(forKey: resetCreditDetailsCacheKey(for: accountKey)),
              let cachedState = try? JSONDecoder().decode(AccountResetCreditState.self, from: data),
              cachedState.accountKey == accountKey else {
            return nil
        }
        return cachedState
    }

    private func updatePersistedResetCreditState(
        _ resetCreditState: AccountResetCreditState,
        from creditsObject: RateLimitResetCreditsObject?
    ) {
        if creditsObject?.availableCount == 0 {
            removePersistedResetCreditState(for: resetCreditState.accountKey)
            return
        }

        guard let details = creditsObject?.credits,
              !details.isEmpty,
              !resetCreditState.credits.isEmpty else {
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(resetCreditState) else { return }

        let key = resetCreditDetailsCacheKey(for: resetCreditState.accountKey)
        if UserDefaults.standard.data(forKey: key) != data {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func removePersistedResetCreditState(for accountKey: String) {
        UserDefaults.standard.removeObject(forKey: resetCreditDetailsCacheKey(for: accountKey))
    }

    private func resetCreditDetailsCacheKey(for accountKey: String) -> String {
        "\(Self.resetCreditDetailsCacheDefaultsPrefix).\(accountKey)"
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

        do {
            try UsageAnalyticsRepository(database: database)
                .assertNoIncompleteSessionDeletionJournal(
                    historyRootURL: CodexHistoryRootResolver.resolveRootURL()
                )
        } catch {
            state.appInitializationWarningText = (error as? SessionDeletionError)?.errorDescription
                ?? L10n.text(
                    "当前本地记录需要先完成恢复处理，暂时无法重置。",
                    "Local records need recovery before reset can continue."
                )
            return
        }

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
        state.currentQuotaSnapshots = []
        state.latestRateLimit = nil
        state.hasCurrentServerQuota = false
        resetCreditStatesByAccountKey.removeAll()
        resetCreditIdempotencyKeys.removeAll()
        persistResetCreditIdempotencyKeys()
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
