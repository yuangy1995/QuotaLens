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
    public let quotaInsightsService: ProviderQuotaInsightsService
    public let scanCoordinator: CodexUsageScanCoordinator
    public let claudeScanCoordinator: ClaudeUsageScanCoordinator
    public let antigravityActivityCoordinator: AntigravityActivityScanCoordinator
    public let enabledToolsStore: EnabledToolsStore
    public let frontmostToolTracker: FrontmostToolTracker
    public let navigationStore: AppNavigationStore
    public lazy var mainWindowCoordinator = MainWindowCoordinator(environment: self)
    public lazy var toolOverlayCoordinator = ToolOverlayCoordinator(environment: self)

    private var refreshLoopTask: Task<Void, Never>?
    private var serverRecoveryTask: Task<Void, Never>?
    private var serverRecoveryGeneration: UInt64 = 0
    private var resetCreditReminderTask: Task<Void, Never>?
    private var subscriptionEntitlementRetryTask: Task<Void, Never>?
    private var claudeUsagePoller: ClaudeUsagePoller?
    private var claudeFileWatcher: ClaudeFileWatcher?
    private var antigravityQuotaPoller: AntigravityQuotaPoller?
    private var antigravityFileWatcher: AntigravityStateFileWatcher?
    private var notificationHandlersRegistered = false
    private var isFetchingServerSnapshot = false
    private var isFetchingSubscriptionEntitlement = false
    private var accountDataGeneration = 0
    private var refreshDataRequestGeneration = 0
    private var serverSnapshotRequestGeneration = 0
    private var subscriptionEntitlementRequestGeneration = 0
    private var quotaInsightsGeneration = 0
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
        let enabledToolsStore = EnabledToolsStore()
        self.enabledToolsStore = enabledToolsStore
        let frontmostToolTracker = FrontmostToolTracker(enabledTools: enabledToolsStore)
        self.frontmostToolTracker = frontmostToolTracker
        frontmostToolTracker.start()
        self.navigationStore = AppNavigationStore(
            enabledTools: enabledToolsStore,
            activeTool: frontmostToolTracker.foregroundTool
        )
        self.state = AppState()
        ClaudeUsageSettings.shared.isEnabled = enabledToolsStore.isEnabled(.claude)

        // 1. 初始化本地 SQLite
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbDir = appSupport.appendingPathComponent("QuotaLens", isDirectory: true)
        let dbPath = dbDir.appendingPathComponent("quotalens.sqlite").path

        var initializationWarning: String?
        let initializedDatabase: SQLiteDatabase
        do {
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
        self.quotaInsightsService = ProviderQuotaInsightsService(database: database)
        self.transport = JSONRPCTransport()
        self.processManager = CodexProcessManager(transport: transport)
        self.accountProbe = AccountProbeActor(transport: transport, repositories: repositories)
        self.updateManager = UpdateManager()
        self.usageQueryFacade = UsageQueryFacade(database: database)
        self.scanCoordinator = CodexUsageScanCoordinator.shared
        self.scanCoordinator.configure(database: database)
        self.claudeScanCoordinator = ClaudeUsageScanCoordinator()
        self.claudeScanCoordinator.configure(database: database)
        self.antigravityActivityCoordinator = AntigravityActivityScanCoordinator()
        self.antigravityActivityCoordinator.configure(database: database)
        self.installThemeAppearanceObservers()
        self.applyThemeAppearance()
        self.registerRPCNotifications()
        self.registerProcessStatusUpdates()
        self.refreshLoginItemState()

        if enabledToolsStore.isEnabled(.claude) {
            self.state.claudeUsageStatus = .loading
            self.startClaudeServices()
        } else {
            self.state.claudeUsageStatus = .disabled
        }

        if enabledToolsStore.isEnabled(.antigravity) {
            if let credentials = try? AntigravityLocalStateReader().read(),
               let hydrated = try? AntigravityQuotaRepository.hydrate(
                   database: database,
                   accountKey: credentials.legacyAccountKey,
                   sourceProfile: credentials.source.profile.rawValue
               ) {
                self.state.latestAntigravityQuota = hydrated
                self.state.antigravityQuotaStatus = .available
                self.state.antigravitySyncState = ProviderSyncState(
                    provider: .antigravity,
                    lastSuccessAt: hydrated.capturedAt
                )
            } else {
                self.state.antigravityQuotaStatus = .loading
            }
            self.startAntigravityServices()
        } else {
            self.state.antigravityQuotaStatus = .disabled
        }

        // 2. 立即导入本地 ~/.codex 真实账号 (0.1ms 完成，首帧立即可见)
        if enabledToolsStore.isEnabled(.codex) {
            _ = LocalAccountImporter.importLocalAccounts(into: repositories)
            self.state.accountDisplayNames = LocalAccountImporter.displayNamesByAccountKey()
            let loadedAccounts = (try? repositories.getAllAccounts()) ?? []
            if let firstAcc = loadedAccounts.first {
                self.state.account = firstAcc
                self.state.selectedAccountKey = firstAcc.accountKey
                self.state.allAccounts = [firstAcc]
            }
        }

        if enabledToolsStore.isEnabled(.antigravity) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.scanAntigravityActivity()
                await self.refreshAntigravityQuota(force: true)
            }
        }
        Task { @MainActor [weak self] in
            await self?.refreshProviderQuotaInsights()
        }
        let localPeriod = ChatGPTSubscriptionClient.localSubscriptionPeriodFromAuth()
        self.state.applyLocalSubscriptionPeriodFallback(startsAt: localPeriod.startsAt, endsAt: localPeriod.endsAt)

        // 3. 后台连接真实服务。
        if enabledToolsStore.isEnabled(.codex) {
            Task(priority: .utility) { [weak self] in
                guard let self = self else { return }
                await self.backgroundBootstrap()
            }
        }

        // 4. 启动即扫描本地 Codex 记录；不要被服务连接阻塞。
        Task(priority: .utility) { [weak self] in
            guard let self = self else { return }
            if UsageFeatureFlags.shared.isAnalyticsEnabled {
                if self.enabledToolsStore.isEnabled(.codex) {
                    await self.scanCoordinator.scanNow()
                }
                if self.enabledToolsStore.isEnabled(.claude) {
                    await self.claudeScanCoordinator.scanNow()
                }
            }
        }

        UsageFeatureFlags.shared.isOverlayEnabled = ToolOverlayPreferences.isEnabled(for: .codex)
        self.toolOverlayCoordinator.refreshConfiguration()

        // 5. 立即触发首帧数据刷新
        if enabledToolsStore.isEnabled(.codex) {
            Task { @MainActor [weak self] in
                await self?.refreshData(fetchServer: false)
            }
        }

        // 6. 启动可配置的周期性状态刷新，默认 1 分钟。
        self.scheduleRefreshTimer()

        // 7. 用 Web entitlement 后台补齐订阅周期、续费/降级状态。
        if enabledToolsStore.isEnabled(.codex) {
            Task { @MainActor [weak self] in
                _ = await self?.refreshSubscriptionEntitlementIfPossible()
            }
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
        Task { @MainActor [weak self] in
            await self?.refreshProviderQuotaInsights()
        }
    }

    public func setClaudeRefreshInterval(seconds: Int) {
        state.setClaudeRefreshInterval(seconds: seconds)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let poller = self.claudeUsagePoller {
                await poller.stop()
            }
            self.claudeUsagePoller = nil
            self.startClaudeServices()
            await self.refreshClaudeUsage(force: true)
            await self.refreshProviderQuotaInsights()
        }
    }

    public func setAntigravityRefreshInterval(seconds: Int) {
        state.setAntigravityRefreshInterval(seconds: seconds)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let poller = self.antigravityQuotaPoller {
                await poller.stop()
            }
            self.antigravityQuotaPoller = nil
            self.startAntigravityServices()
            await self.refreshAntigravityQuota(force: true)
            await self.refreshProviderQuotaInsights()
        }
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

    public func setWeeklyQuotaRecoveryEnabled(_ enabled: Bool) {
        state.setWeeklyQuotaRecoveryEnabled(enabled)
        guard enabled else {
            toolOverlayCoordinator.refreshRecoveryBubbles()
            menuBarController?.refreshAppearance()
            return
        }

        establishCurrentWeeklyQuotaRecoveryBaselines()
        toolOverlayCoordinator.refreshRecoveryBubbles()
        menuBarController?.refreshAppearance()
    }

    public func acknowledgeWeeklyQuotaRecovery() {
        state.acknowledgeWeeklyQuotaRecovery()
        toolOverlayCoordinator.refreshRecoveryBubbles()
        menuBarController?.refreshAppearance()
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
        let outcome = payload.outcome
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
        mainWindowCoordinator.focusExistingMainWindow()
    }

    public func openOrFocusMainWindow(createWindow: () -> Void) {
        _ = createWindow
        mainWindowCoordinator.showMainWindow()
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
                DispatchQueue.main.async { [weak self] in
                    self?.mainWindowCoordinator.showMainWindow()
                }
            },
            onRefresh: { [weak self] tool in
                Task { @MainActor [weak self] in
                    if let tool {
                        await self?.refreshMonitoringTool(tool)
                    } else {
                        await self?.refreshAllData()
                    }
                }
            }
        )
    }

    public func installMenuBarController(
        onOpenMainWindow: @escaping () -> Void,
        onRefresh: @escaping (MonitoringToolID?) -> Void
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
                },
                onAcknowledgeWeeklyQuotaRecovery: { [weak self] in
                    self?.acknowledgeWeeklyQuotaRecovery()
                }
            )
        } else {
            menuBarController = MenuBarStatusItemController(
                state: state,
                usageFacade: usageQueryFacade,
                claudeScanCoordinator: claudeScanCoordinator,
                enabledTools: enabledToolsStore,
                toolTracker: frontmostToolTracker,
                onOpenMainWindow: onOpenMainWindow,
                onRefresh: onRefresh,
                onAcknowledgeResetCreditReminder: { [weak self] in
                    self?.acknowledgeResetCreditReminder()
                },
                onSnoozeResetCreditReminder: { [weak self] hours in
                    self?.snoozeResetCreditReminder(hours: hours)
                },
                onAcknowledgeWeeklyQuotaRecovery: { [weak self] in
                    self?.acknowledgeWeeklyQuotaRecovery()
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
        // 连接真实 Codex App Server；连接流程会完成首次额度读取。
        await connectCodex()
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
        cancelServerRecovery()
        state.connectionStatus = .launching
        if await fetchServerSnapshotIfPossible(scheduleRetryOnFailure: false) {
            await refreshData(fetchServer: false)
            return
        }

        let success = await processManager.start()
        let status = await processManager.getStatus()

        if success {
            state.connectionStatus = .handshaking
            _ = await fetchConnectedServerSnapshotIfPossible(scheduleRetryOnFailure: false)
            await refreshData(fetchServer: false)
            if !state.hasQuotaSnapshot {
                scheduleServerRecovery()
            }
        } else {
            state.connectionStatus = status
            await refreshData(fetchServer: false)
            scheduleServerRecovery()
        }
    }

    /// 全量刷新数据视图
    public func refreshData(
        fetchServer: Bool = true,
        scheduleRetryOnFailure: Bool = true,
        forceReconnect: Bool = false
    ) async {
        guard enabledToolsStore.isEnabled(.codex) else { return }
        refreshDataRequestGeneration += 1
        let requestGeneration = refreshDataRequestGeneration
        state.lastRefreshAttemptAt = Date()
        state.isRefreshing = true
        defer {
            if requestGeneration == refreshDataRequestGeneration {
                state.isRefreshing = false
            }
        }

        do {
            if fetchServer {
                var fetchedServerSnapshot = await fetchServerSnapshotIfPossible(
                    scheduleRetryOnFailure: false
                )
                if !fetchedServerSnapshot, forceReconnect {
                    cancelServerRecovery()
                    let currentStatus = await processManager.getStatus()
                    if currentStatus.isConnected {
                        fetchedServerSnapshot = await fetchConnectedServerSnapshotIfPossible(
                            scheduleRetryOnFailure: false
                        )
                    } else {
                        let started = await processManager.start()
                        if started {
                            state.connectionStatus = .handshaking
                            fetchedServerSnapshot = await fetchConnectedServerSnapshotIfPossible(
                                scheduleRetryOnFailure: false
                            )
                        } else {
                            state.connectionStatus = await processManager.getStatus()
                        }
                    }
                }
                if !fetchedServerSnapshot, scheduleRetryOnFailure {
                    scheduleServerRecovery()
                }
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
            state.codexStorageErrorText = L10n.text(
                "在线额度仍可使用，但本地记录暂时无法读取或保存。",
                "Online quota remains available, but local records cannot currently be read or saved."
            )
        }
        await refreshProviderQuotaInsights()
    }

    /// 刷新所有用户可见数据：本地 Codex 用量先完成索引，再读取服务器额度快照。
    public func refreshAllData(
        fetchServer: Bool = true,
        scheduleRetryOnFailure: Bool = true,
        forceCodexReconnect: Bool = true
    ) async {
        if enabledToolsStore.isEnabled(.claude) {
            startClaudeServices()
        }
        if UsageFeatureFlags.shared.isAnalyticsEnabled {
            if enabledToolsStore.isEnabled(.codex) {
                await scanCoordinator.scanNow()
            }
            if enabledToolsStore.isEnabled(.claude) {
                await claudeScanCoordinator.scanNow()
            }
        }
        if enabledToolsStore.isEnabled(.claude) {
            await refreshClaudeUsage(force: true)
        }
        if enabledToolsStore.isEnabled(.antigravity) {
            startAntigravityServices()
            await scanAntigravityActivity()
            await refreshAntigravityQuota(force: true)
        }
        if enabledToolsStore.isEnabled(.codex) {
            await refreshData(
                fetchServer: fetchServer,
                scheduleRetryOnFailure: scheduleRetryOnFailure,
                forceReconnect: forceCodexReconnect
            )
        } else {
            await refreshProviderQuotaInsights()
        }
    }

    public func refreshProviderQuotaInsights() async {
        quotaInsightsGeneration += 1
        let generation = quotaInsightsGeneration
        let inputs = quotaInsightInputs()
        let refreshIntervals: [UsageProvider: TimeInterval] = [
            .codex: TimeInterval(state.refreshIntervalSeconds),
            .claude: TimeInterval(state.claudeRefreshIntervalSeconds),
            .antigravity: TimeInterval(state.antigravityRefreshIntervalSeconds)
        ]
        let enabledProviders = Set(enabledToolsStore.enabledToolIDs.compactMap { tool -> UsageProvider? in
            switch tool {
            case .codex: return .codex
            case .claude: return .claude
            case .antigravity: return .antigravity
            default: return nil
            }
        })
        var errors: [UsageProvider: String] = [:]
        if enabledProviders.contains(.codex), !state.hasQuotaSnapshot {
            errors[.codex] = state.quotaUnavailableDescription
        }
        if enabledProviders.contains(.claude),
           state.latestClaudeUsage?.hasQuota != true,
           let error = state.claudeUsageErrorText {
            errors[.claude] = error
        }
        if enabledProviders.contains(.antigravity),
           !state.antigravityHasQuota,
           let error = state.antigravityQuotaErrorText {
            errors[.antigravity] = error
        }
        let activity = state.latestAntigravityActivity
        let result = await quotaInsightsService.build(
            inputs: inputs,
            refreshIntervals: refreshIntervals
        )
        guard generation == quotaInsightsGeneration else { return }
        state.providerQuotaInsights = result.insights
        state.providerHistoryWarnings = result.storageWarnings
        for provider in result.storageWarnings where errors[provider] == nil {
            errors[provider] = state.historyWarningText(for: provider)
        }
        state.quotaRecommendations = QuotaRecommendationEngine.make(
            insights: result.insights,
            enabledProviders: enabledProviders,
            errors: errors,
            antigravityActivity: activity
        )
    }

    private func quotaInsightInputs() -> [ProviderQuotaPoolInput] {
        var inputs: [ProviderQuotaPoolInput] = []
        if enabledToolsStore.isEnabled(.codex) {
            inputs.append(contentsOf: state.currentQuotaSnapshots.map { snapshot in
                let window = QuotaWindowKind(windowDurationMins: snapshot.windowDurationMins)
                return ProviderQuotaPoolInput(
                    provider: .codex,
                    accountKey: snapshot.accountKey,
                    limitID: snapshot.limitId,
                    slot: snapshot.slot,
                    groupTitle: Self.codexWeeklyDisplayName(for: snapshot.limitId) ?? "Codex",
                    windowTitle: window == .fiveHour
                        ? L10n.text("5 小时", "5 Hours")
                        : L10n.text("7 天", "7 Days"),
                    usedPercent: snapshot.usedPercent,
                    windowDurationMins: snapshot.windowDurationMins,
                    resetAt: snapshot.resetsAt.map { Date(timeIntervalSince1970: Double($0)) },
                    capturedAt: Date(timeIntervalSince1970: Double(snapshot.observedAt))
                )
            })
        }
        if enabledToolsStore.isEnabled(.claude), let usage = state.latestClaudeUsage {
            let windows = [usage.fiveHourForDisplay, usage.sevenDay].compactMap { $0 } + usage.scopedWeekly
            inputs.append(contentsOf: windows.map { window in
                ProviderQuotaPoolInput(
                    provider: .claude,
                    accountKey: usage.accountKey,
                    limitID: window.id,
                    slot: window.windowDuration <= 18_000 ? "primary" : "secondary",
                    groupTitle: "Claude",
                    windowTitle: window.localizedTitle,
                    usedPercent: window.usedPercent,
                    windowDurationMins: Int(window.windowDuration / 60),
                    resetAt: window.resetAt,
                    capturedAt: usage.capturedAt
                )
            })
        }
        if enabledToolsStore.isEnabled(.antigravity), let quota = state.latestAntigravityQuota {
            for group in quota.groups {
                for bucket in group.buckets {
                    let duration: Int?
                    switch bucket.window {
                    case .fiveHour: duration = 300
                    case .weekly: duration = 10_080
                    case .other: duration = nil
                    }
                    inputs.append(
                        ProviderQuotaPoolInput(
                            provider: .antigravity,
                            accountKey: quota.accountKey,
                            limitID: group.id,
                            slot: bucket.id,
                            groupTitle: group.title,
                            windowTitle: bucket.window.localizedTitle,
                            usedPercent: 100 - bucket.remainingPercent,
                            windowDurationMins: duration,
                            resetAt: bucket.resetAt,
                            capturedAt: quota.capturedAt
                        )
                    )
                }
            }
        }
        return inputs
    }

    public func refreshMonitoringTool(_ tool: MonitoringToolID) async {
        guard enabledToolsStore.isEnabled(tool) else { return }
        switch tool {
        case .codex:
            await refreshData(forceReconnect: true)
            if UsageFeatureFlags.shared.isAnalyticsEnabled {
                await scanCoordinator.scanNow()
            }
        case .claude:
            startClaudeServices()
            if UsageFeatureFlags.shared.isAnalyticsEnabled {
                await claudeScanCoordinator.scanNow()
            }
            await refreshClaudeUsage(force: true)
        case .antigravity:
            startAntigravityServices()
            await scanAntigravityActivity()
            await refreshAntigravityQuota(force: true)
        default:
            break
        }
        Task { @MainActor [weak self] in
            await self?.refreshProviderQuotaInsights()
        }
    }

    public func setMonitoringToolEnabled(_ enabled: Bool, tool: MonitoringToolID) {
        enabledToolsStore.setEnabled(enabled, for: tool)
        navigationStore.normalize(
            enabledTools: enabledToolsStore.enabledToolIDs,
            activeTool: frontmostToolTracker.foregroundTool
        )
        frontmostToolTracker.refresh()

        switch tool {
        case .codex:
            if enabled {
                importLocalAccount()
                establishCurrentWeeklyQuotaRecoveryBaselines()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.connectCodex()
                    if UsageFeatureFlags.shared.isAnalyticsEnabled {
                        await self.scanCoordinator.scanNow()
                    }
                    self.toolOverlayCoordinator.refreshConfiguration()
                }
            } else {
                cancelServerRecovery()
                cancelSubscriptionEntitlementRetry()
                toolOverlayCoordinator.refreshConfiguration()
                Task { [weak self] in
                    await self?.processManager.stop()
                    await MainActor.run {
                        self?.state.connectionStatus = .disconnected
                    }
                }
            }
        case .claude:
            setClaudeEnabled(enabled)
        case .antigravity:
            setAntigravityEnabled(enabled)
        default:
            break
        }
        Task { @MainActor [weak self] in
            await self?.refreshProviderQuotaInsights()
        }
    }

    public func setClaudeEnabled(_ enabled: Bool) {
        if enabledToolsStore.isEnabled(.claude) != enabled {
            enabledToolsStore.setEnabled(enabled, for: .claude)
        }
        ClaudeUsageSettings.shared.isEnabled = enabled
        if enabled {
            state.claudeUsageStatus = .loading
            startClaudeServices()
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.claudeScanCoordinator.scanNow()
                await self.refreshClaudeUsage(force: true)
            }
        } else {
            stopClaudeServices()
            state.latestClaudeUsage = nil
            state.claudeUsageStatus = .disabled
            state.claudeUsageErrorText = nil
            state.claudeUsageCooldownUntil = nil
            state.isRefreshingClaudeUsage = false
        }
        toolOverlayCoordinator.refreshConfiguration()
    }

    public func refreshClaudeUsage(force: Bool = true) async {
        guard ClaudeUsageSettings.shared.isEnabled,
              let poller = claudeUsagePoller else { return }
        state.isRefreshingClaudeUsage = true
        defer { state.isRefreshingClaudeUsage = false }
        await poller.pollOnce(force: force)
    }

    public func redetectClaudeCredentials() async {
        guard ClaudeUsageSettings.shared.isEnabled,
              let poller = claudeUsagePoller else { return }
        state.isRefreshingClaudeUsage = true
        defer { state.isRefreshingClaudeUsage = false }
        await poller.redetectCredentials()
    }

    private func startClaudeServices() {
        guard ClaudeUsageSettings.shared.isEnabled else { return }
        if claudeUsagePoller == nil {
            let poller = ClaudeUsagePoller(
                database: database,
                interval: TimeInterval(state.claudeRefreshIntervalSeconds),
                initialSnapshot: state.latestClaudeUsage,
                onResult: { [weak self] result in
                    await MainActor.run {
                        self?.applyClaudeUsageResult(result)
                    }
                },
                onCooldown: { [weak self] until in
                    await MainActor.run {
                        self?.state.claudeUsageCooldownUntil = until
                        if let until {
                            self?.state.claudeUsageStatus = .limited(until: until)
                        }
                    }
                },
                onCachedSnapshot: { [weak self] snapshot in
                    await MainActor.run {
                        guard let self, ClaudeUsageSettings.shared.isEnabled else { return }
                        self.state.latestClaudeUsage = snapshot
                        self.state.claudeUsageStatus = snapshot == nil ? .loading : .available
                        self.state.claudeUsageErrorText = nil
                        if let snapshot {
                            self.state.establishWeeklyQuotaRecoveryBaseline(
                                tool: .claude,
                                samples: self.weeklyQuotaSamples(from: snapshot),
                                accountKey: snapshot.accountKey
                            )
                        }
                    }
                }
            )
            claudeUsagePoller = poller
            Task { await poller.start() }
        }
        if claudeFileWatcher == nil {
            let watcher = ClaudeFileWatcher { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.claudeScanCoordinator.scanNow()
                }
            }
            if watcher.start() {
                claudeFileWatcher = watcher
            }
        }
    }

    private func stopClaudeServices() {
        if let poller = claudeUsagePoller {
            Task { await poller.stop() }
        }
        claudeUsagePoller = nil
        claudeFileWatcher?.stop()
        claudeFileWatcher = nil
    }

    private func stopClaudeServicesAndWait() async {
        if let poller = claudeUsagePoller {
            await poller.stop()
        }
        claudeUsagePoller = nil
        claudeFileWatcher?.stop()
        claudeFileWatcher = nil
    }

    private func applyClaudeUsageResult(_ result: Result<ProviderQuotaRefreshResult<ClaudeUsageSnapshot>, Error>) {
        guard ClaudeUsageSettings.shared.isEnabled else { return }
        switch result {
        case .success(let refresh):
            let snapshot = refresh.snapshot
            state.processWeeklyQuotaRecovery(
                tool: .claude,
                samples: weeklyQuotaSamples(from: snapshot),
                accountKey: snapshot.accountKey,
                now: snapshot.capturedAt
            )
            state.latestClaudeUsage = snapshot
            state.claudeUsageStatus = .available
            state.claudeUsageErrorText = refresh.storageWarningText
            state.claudeUsageCooldownUntil = nil
        case .failure(let error as ClaudeUsageClient.FetchError):
            switch error {
            case .noCredentials:
                state.claudeUsageStatus = .missingCredentials
                state.claudeUsageErrorText = L10n.text(
                    "请先在 Claude Code 中登录。",
                    "Sign in to Claude Code first."
                )
            case .insufficientScope, .unauthorized:
                state.claudeUsageStatus = .signInRequired
                state.claudeUsageErrorText = L10n.text(
                    "Claude 登录已失效，请重新登录。",
                    "Your Claude sign-in has expired. Sign in again."
                )
            case .rateLimited(let retryAfter):
                let until = retryAfter.map { Date().addingTimeInterval($0) }
                    ?? state.claudeUsageCooldownUntil
                state.claudeUsageStatus = .limited(until: until)
                state.claudeUsageErrorText = L10n.text(
                    "Claude 暂时延迟刷新，将自动重试。",
                    "Claude refresh is temporarily delayed and will retry automatically."
                )
            case .incompatibleResponse, .partialResponse:
                state.claudeUsageStatus = .unavailable
                state.claudeUsageErrorText = L10n.format(
                    "%@ quota could not be read completely. Check for a QuotaLens update.",
                    zhHans: "暂时无法完整读取 %@ 额度，请检查 QuotaLens 更新。",
                    "Claude"
                )
            case .unavailable:
                state.claudeUsageStatus = .unavailable
                state.claudeUsageErrorText = L10n.text(
                    "暂时无法更新 Claude 额度。",
                    "Claude quota could not be updated right now."
                )
            }
        case .failure:
            state.claudeUsageStatus = .unavailable
            state.claudeUsageErrorText = L10n.text(
                "暂时无法更新 Claude 额度。",
                "Claude quota could not be updated right now."
            )
        }
        Task { @MainActor [weak self] in
            await self?.refreshProviderQuotaInsights()
        }
    }

    public func setAntigravityEnabled(_ enabled: Bool) {
        if enabled {
            if let credentials = try? AntigravityLocalStateReader().read(preferredProfile: preferredAntigravityProfile),
               let hydrated = try? AntigravityQuotaRepository.hydrate(
                   database: database,
                   accountKey: credentials.legacyAccountKey,
                   sourceProfile: credentials.source.profile.rawValue
               ) {
                state.latestAntigravityQuota = hydrated
                state.antigravityQuotaStatus = .available
                state.antigravitySyncState = ProviderSyncState(
                    provider: .antigravity,
                    lastSuccessAt: hydrated.capturedAt
                )
                state.establishWeeklyQuotaRecoveryBaseline(
                    tool: .antigravity,
                    samples: weeklyQuotaSamples(from: hydrated),
                    accountKey: hydrated.accountKey
                )
            } else {
                state.antigravityQuotaStatus = .loading
            }
            startAntigravityServices()
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.scanAntigravityActivity()
                await self.refreshAntigravityQuota(force: true)
            }
        } else {
            stopAntigravityServices()
            state.latestAntigravityQuota = nil
            state.latestAntigravityActivity = nil
            state.antigravityActivityWarningText = nil
            state.antigravityActivitySnapshotsByProfile = [:]
            state.antigravityQuotaStatus = .disabled
            state.antigravityQuotaErrorText = nil
            state.isRefreshingAntigravityQuota = false
            state.antigravitySyncState = ProviderSyncState(provider: .antigravity)
            state.antigravityAccountResolutionState = nil
            state.providerQuotaInsights[.antigravity] = nil
        }
        Task { @MainActor [weak self] in
            await self?.refreshProviderQuotaInsights()
        }
        toolOverlayCoordinator.refreshConfiguration()
    }

    public func refreshAntigravityQuota(force: Bool = true) async {
        guard enabledToolsStore.isEnabled(.antigravity) else { return }
        startAntigravityServices()
        guard let poller = antigravityQuotaPoller else { return }
        state.isRefreshingAntigravityQuota = true
        defer { state.isRefreshingAntigravityQuota = false }
        await poller.pollOnce(force: force, preferredProfile: preferredAntigravityProfile)
    }

    public func scanAntigravityActivity() async {
        guard enabledToolsStore.isEnabled(.antigravity) else { return }
        await antigravityActivityCoordinator.scanNow(preferredProfile: preferredAntigravityProfile)
        guard enabledToolsStore.isEnabled(.antigravity) else { return }
        state.latestAntigravityActivity = antigravityActivityCoordinator.latestSnapshot
        state.antigravityActivitySnapshotsByProfile = antigravityActivityCoordinator.snapshotsByProfile
        state.antigravityActivityWarningText = antigravityActivityCoordinator.isPartial
            ? antigravityActivityCoordinator.statusText : nil
        await refreshProviderQuotaInsights()
    }

    private func startAntigravityServices() {
        guard enabledToolsStore.isEnabled(.antigravity) else { return }
        if antigravityQuotaPoller == nil {
            let poller = AntigravityQuotaPoller(
                database: database,
                interval: TimeInterval(state.antigravityRefreshIntervalSeconds),
                initialSnapshot: state.latestAntigravityQuota,
                onResult: { [weak self] result in
                    await MainActor.run {
                        self?.applyAntigravityQuotaResult(result)
                    }
                },
                onSyncState: { [weak self] syncState in
                    await MainActor.run {
                        self?.state.antigravitySyncState = syncState
                    }
                },
                onCachedSnapshot: { [weak self] snapshot in
                    await MainActor.run {
                        guard let self, self.enabledToolsStore.isEnabled(.antigravity) else { return }
                        self.state.latestAntigravityQuota = snapshot
                        self.state.antigravityQuotaStatus = snapshot == nil ? .loading : .available
                        self.state.antigravityQuotaErrorText = nil
                        if let snapshot {
                            self.state.establishWeeklyQuotaRecoveryBaseline(
                                tool: .antigravity,
                                samples: self.weeklyQuotaSamples(from: snapshot),
                                accountKey: snapshot.accountKey
                            )
                        }
                    }
                },
                onAccountResolutionState: { [weak self] resolutionState in
                    await MainActor.run {
                        guard let self, self.enabledToolsStore.isEnabled(.antigravity) else { return }
                        self.state.antigravityAccountResolutionState = resolutionState
                        if case .resolving = resolutionState,
                           self.state.latestAntigravityQuota?.hasQuota == true {
                            self.state.antigravityQuotaStatus = .available
                            self.state.antigravityQuotaErrorText = L10n.text(
                                "正在确认 Antigravity 账号，当前显示上次缓存。",
                                "Confirming the Antigravity account. Showing the previous cache for now."
                            )
                        }
                    }
                }
            )
            antigravityQuotaPoller = poller
            Task { await poller.start() }
        }
        if antigravityFileWatcher == nil {
            let watcher = AntigravityStateFileWatcher { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.enabledToolsStore.isEnabled(.antigravity) else { return }
                    await self.scanAntigravityActivity()
                }
            }
            if watcher.start() {
                antigravityFileWatcher = watcher
            }
        }
    }

    private func stopAntigravityServices() {
        if let poller = antigravityQuotaPoller {
            Task { await poller.stop() }
        }
        antigravityQuotaPoller = nil
        antigravityFileWatcher?.stop()
        antigravityFileWatcher = nil
    }

    private func applyAntigravityQuotaResult(_ result: Result<ProviderQuotaRefreshResult<AntigravityQuotaSnapshot>, Error>) {
        guard enabledToolsStore.isEnabled(.antigravity) else { return }
        switch result {
        case .success(let refresh):
            let snapshot = refresh.snapshot
            state.processWeeklyQuotaRecovery(
                tool: .antigravity,
                samples: weeklyQuotaSamples(from: snapshot),
                accountKey: snapshot.accountKey,
                now: snapshot.capturedAt
            )
            state.latestAntigravityQuota = snapshot
            state.antigravityQuotaStatus = .available
            state.antigravityQuotaErrorText = refresh.storageWarningText
        case .failure(let error):
            let presentation = AntigravityQuotaFailurePresentation.make(
                error: error,
                accountResolution: state.antigravityAccountResolutionState,
                hasCachedQuota: state.latestAntigravityQuota?.hasQuota == true
            )
            state.antigravityQuotaStatus = presentation.status
            state.antigravityQuotaErrorText = presentation.message
        }
        Task { @MainActor [weak self] in
            await self?.refreshProviderQuotaInsights()
        }
    }

    private var preferredAntigravityProfile: AntigravityStateProfile? {
        frontmostToolTracker.foregroundAntigravityProfile
    }

    private func currentStateAccountKey() -> String? {
        state.selectedAccountKey ?? state.account?.accountKey
    }

    private func establishCurrentWeeklyQuotaRecoveryBaselines() {
        let codexSamples = weeklyQuotaSamples(from: state.currentQuotaSnapshots)
        state.establishWeeklyQuotaRecoveryBaseline(
            tool: .codex,
            samples: codexSamples,
            accountKey: codexSamples.first?.key.accountKey ?? currentStateAccountKey() ?? "acc_local"
        )

        if let claude = state.latestClaudeUsage {
            state.establishWeeklyQuotaRecoveryBaseline(
                tool: .claude,
                samples: weeklyQuotaSamples(from: claude),
                accountKey: claude.accountKey
            )
        }
        if let antigravity = state.latestAntigravityQuota {
            state.establishWeeklyQuotaRecoveryBaseline(
                tool: .antigravity,
                samples: weeklyQuotaSamples(from: antigravity),
                accountKey: antigravity.accountKey
            )
        }
    }

    private func weeklyQuotaSamples(from snapshots: [RateLimitSnapshotRecord]) -> [WeeklyQuotaPoolSample] {
        snapshots
            .filter { QuotaWindowKind(windowDurationMins: $0.windowDurationMins) == .weekly }
            .map { snapshot in
                WeeklyQuotaPoolSample(
                    key: WeeklyQuotaPoolKey(
                        tool: .codex,
                        accountKey: snapshot.accountKey,
                        poolID: "\(snapshot.limitId)|\(snapshot.slot)"
                    ),
                    displayName: Self.codexWeeklyDisplayName(for: snapshot.limitId),
                    remainingPercent: snapshot.remainingPercent,
                    resetAt: snapshot.resetsAt.map { Date(timeIntervalSince1970: Double($0)) },
                    capturedAt: Date(timeIntervalSince1970: Double(snapshot.observedAt))
                )
            }
    }

    private func weeklyQuotaSamples(from snapshot: ClaudeUsageSnapshot) -> [WeeklyQuotaPoolSample] {
        let windows = [snapshot.sevenDay].compactMap { $0 } + snapshot.scopedWeekly
        return windows.map { window in
            WeeklyQuotaPoolSample(
                key: WeeklyQuotaPoolKey(
                    tool: .claude,
                    accountKey: snapshot.accountKey,
                    poolID: window.id
                ),
                displayName: window.id == "claude-weekly" ? nil : window.localizedTitle,
                remainingPercent: window.remainingPercent,
                resetAt: window.resetAt,
                capturedAt: snapshot.capturedAt
            )
        }
    }

    private func weeklyQuotaSamples(from snapshot: AntigravityQuotaSnapshot) -> [WeeklyQuotaPoolSample] {
        snapshot.groups.flatMap { group in
            group.buckets
                .filter { $0.window == .weekly }
                .map { bucket in
                    WeeklyQuotaPoolSample(
                        key: WeeklyQuotaPoolKey(
                            tool: .antigravity,
                            accountKey: snapshot.accountKey,
                            poolID: "\(group.id)|\(bucket.id)"
                        ),
                        displayName: Self.antigravityWeeklyDisplayName(for: group.title),
                        remainingPercent: bucket.remainingPercent,
                        resetAt: bucket.resetAt,
                        capturedAt: snapshot.capturedAt
                    )
                }
        }
    }

    private static func antigravityWeeklyDisplayName(for groupTitle: String) -> String {
        let normalized = groupTitle.lowercased()
        if normalized.contains("gemini") { return "Gemini" }
        if normalized.contains("claude") || normalized.contains("gpt") { return "Claude/GPT" }
        return groupTitle
    }

    private static func codexWeeklyDisplayName(for limitID: String) -> String? {
        guard limitID != primaryQuotaLimitId else { return nil }
        let trimmed = limitID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        if normalized.hasPrefix("codex_") || normalized.hasPrefix("codex-") {
            return L10n.text("其他模型", "Other model")
        }
        return trimmed.replacingOccurrences(of: "_", with: " ")
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
            async let accountPayload = rpcPayload(AccountReadResult.self, method: "account/read")
            async let rateLimitsPayload = rpcPayload(RateLimitsReadResult.self, method: "account/rateLimits/read")
            async let accountUsagePayload = try? rpcPayload(CodexAccountUsagePayload.self, method: "account/usage/read")
            let account = try await accountPayload
            let rateLimits = try await rateLimitsPayload
            let accountUsage = await accountUsagePayload

            guard isServerSnapshotRequestCurrent(requestGeneration) else {
                return false
            }

            let snapshot = CodexServerSnapshot(
                capturedAt: Date(),
                version: version,
                binaryPath: binaryPath,
                account: account,
                accountRawJson: encodedRPCPayloadJSON(account),
                rateLimits: rateLimits,
                rateLimitsRawJson: encodedRPCPayloadJSON(rateLimits),
                accountUsage: accountUsage
            )

            try persistServerSnapshot(snapshot)
            guard isServerSnapshotRequestCurrent(requestGeneration) else {
                return false
            }
            guard state.hasCurrentServerQuota else {
                throw RPCPayloadError.invalidPayload(method: "account/rateLimits/read")
            }
            state.connectionStatus = .connected(version: version, binaryPath: binaryPath)
            recordCodexRefreshSuccess(at: snapshot.capturedAt)
            await processManager.markConnectionHealthy()
            if state.hasCurrentServerQuota {
                cancelServerRecovery()
                return true
            }

            if scheduleRetryOnFailure {
                scheduleServerRecovery()
            }
            return false
        } catch {
            if let transportError = error as? JSONRPCTransportError {
                await processManager.reportTransportFailure(
                    transportError.localizedDescription
                )
            }
            recordCodexRefreshFailure(error)
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
    ) async throws -> T {
        let response: JSONRPCResponse
        do {
            response = try await transport.sendRequest(
                method: method,
                params: params,
                timeoutSeconds: timeoutSeconds
            )
        } catch {
            if let data = CodexRPCErrorBodySalvage.data(from: error.localizedDescription),
               let value = try? decodeRPCPayload(T.self, method: method, data: data) {
                return value
            }
            throw error
        }
        if let error = response.error {
            throw NSError(domain: "QuotaLens.RPC", code: error.code, userInfo: [NSLocalizedDescriptionKey: error.message])
        }
        guard let result = response.result else {
            throw RPCPayloadError.missingResult(method: method)
        }
        let data = try JSONEncoder().encode(result)
        return try decodeRPCPayload(T.self, method: method, data: data)
    }

    private func decodeRPCPayload<T: Decodable>(
        _ type: T.Type,
        method: String,
        data: Data
    ) throws -> T {
        let value: T
        do {
            value = try JSONDecoder().decode(type, from: data)
        } catch {
            throw RPCPayloadError.decodeFailed(method: method)
        }
        if let validating = value as? any RPCPayloadValidating,
           !validating.hasRecognizedPayload {
            throw RPCPayloadError.invalidPayload(method: method)
        }
        return value
    }

    private func encodedRPCPayloadJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
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
            recordCodexRefreshSuccess(at: snapshot.capturedAt)
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
            recordCodexRefreshFailure(error)
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
        guard enabledToolsStore.isEnabled(.codex) else { return }
        state.isRetryingServerConnection = true
        serverRecoveryGeneration &+= 1
        let recoveryGeneration = serverRecoveryGeneration

        serverRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if recoveryGeneration == self.serverRecoveryGeneration {
                    self.serverRecoveryTask = nil
                    self.state.isRetryingServerConnection = false
                }
            }

            var retryIndex = 0
            while !Task.isCancelled,
                  self.enabledToolsStore.isEnabled(.codex) {
                let delaySeconds = Self.serverRetryDelaysSeconds[
                    min(retryIndex, Self.serverRetryDelaysSeconds.count - 1)
                ]
                retryIndex += 1
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

    private func recordCodexRefreshSuccess(at capturedAt: Date) {
        state.lastSuccessfulRefreshAt = capturedAt
        state.codexRefreshErrorText = nil
    }

    private func recordCodexRefreshFailure(_ error: Error) {
        let message: String
        if let payloadError = error as? RPCPayloadError {
            message = payloadError.localizedDescription
        } else if let transportError = error as? JSONRPCTransportError {
            switch transportError {
            case .frameTooLarge, .invalidFrame:
                message = transportError.localizedDescription
            default:
                message = L10n.text(
                    "额度刷新未完成，正在保留上次成功的数据。",
                    "Quota refresh did not finish. The last successful data is being kept."
                )
            }
        } else {
            message = L10n.text(
                "额度刷新未完成，正在保留上次成功的数据。",
                "Quota refresh did not finish. The last successful data is being kept."
            )
        }
        state.codexRefreshErrorText = message
        state.connectionStatus = .failed(message)
    }

    private func cancelServerRecovery() {
        serverRecoveryGeneration &+= 1
        serverRecoveryTask?.cancel()
        serverRecoveryTask = nil
        state.isRetryingServerConnection = false
    }

    private func recoverServerSnapshotOnce() async -> Bool {
        if await fetchServerSnapshotIfPossible(scheduleRetryOnFailure: false) {
            await refreshData(fetchServer: false, scheduleRetryOnFailure: false)
            return state.hasQuotaSnapshot
        }
        if await fetchConnectedServerSnapshotIfPossible(scheduleRetryOnFailure: false) {
            await refreshData(fetchServer: false, scheduleRetryOnFailure: false)
            return state.hasQuotaSnapshot
        }

        await refreshData(fetchServer: false, scheduleRetryOnFailure: false)
        return false
    }

    private func latestQuotaSnapshots(accountKey: String) throws -> [RateLimitSnapshotRecord] {
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
        let capturedAt = Date(timeIntervalSince1970: Double(snapshot.observedAt))
        if state.lastSuccessfulRefreshAt.map({ capturedAt > $0 }) ?? true {
            state.lastSuccessfulRefreshAt = capturedAt
        }
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
        state.codexAccountUsage = nil
        state.lastSuccessfulRefreshAt = nil
        state.codexRefreshErrorText = nil
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
        let now = Int64(snapshot.capturedAt.timeIntervalSince1970)
        var storageFailed = false
        defer {
            state.codexStorageErrorText = storageFailed
                ? L10n.text(
                    "在线额度已更新，但本地历史暂时未保存。",
                    "Online quota was updated, but local history was not saved."
                )
                : nil
        }
        var accountKey = state.selectedAccountKey ?? state.account?.accountKey ?? "acc_local"

        if let accountInfo = snapshot.account?.account {
            let identifier = accountInfo.stableIdentifier
            let generatedAccountKey = AccountIdentity.stableAccountKey(from: identifier)
            let emailHash = AccountIdentity.emailHash(from: accountInfo.email ?? identifier)
            if accountInfo.accountId == nil, accountInfo.id == nil {
                accountKey = ((try? repositories.getAllAccounts()) ?? [])
                    .filter { $0.emailHash == emailHash }
                    .min { $0.firstSeenAt < $1.firstSeenAt }?
                    .accountKey ?? generatedAccountKey
            } else {
                accountKey = generatedAccountKey
            }
            let legacyIdentifiers = [
                accountInfo.email,
                accountInfo.accountId.map { "account_\($0.prefix(8))" },
                accountInfo.id,
                accountInfo.type
            ].compactMap { $0 }
            for legacyIdentifier in Set(legacyIdentifiers) {
                do {
                    try repositories.migrateAccountKey(
                        from: AccountIdentity.stableAccountKey(from: legacyIdentifier),
                        to: accountKey
                    )
                } catch {
                    storageFailed = true
                }
            }
            do {
                try repositories.migrateLegacyChatGPTAccount(
                    to: accountKey,
                    emailHash: emailHash
                )
            } catch {
                storageFailed = true
            }
            if state.selectedAccountKey != accountKey {
                beginAccountScopeChange(invalidateServerSnapshot: false, invalidateRefreshRequests: false)
            }
            let record = AccountRecord(
                accountKey: accountKey,
                emailHash: emailHash,
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
            do {
                try repositories.upsertAccount(record)
            } catch {
                storageFailed = true
            }
        }

        if let accountUsage = snapshot.accountUsage {
            state.codexAccountUsage = CodexAccountUsageSnapshot(payload: accountUsage)
        }

        if let rateLimits = snapshot.rateLimits {
            updateResetCreditState(from: rateLimits.rateLimitResetCredits, accountKey: accountKey)
            let liveSnapshots = liveRateLimitSnapshots(
                from: rateLimits,
                accountKey: accountKey,
                observedAt: now,
                rawJson: snapshot.rateLimitsRawJson
            )
            let currentLiveSnapshots = liveSnapshots.filter { $0.isCurrentQuotaWindow(at: now) }
            state.processWeeklyQuotaRecovery(
                tool: .codex,
                samples: weeklyQuotaSamples(from: currentLiveSnapshots),
                accountKey: accountKey,
                now: Date(timeIntervalSince1970: Double(now))
            )
            let insertedCount: Int
            do {
                insertedCount = try persistRateLimits(
                    rateLimits,
                    accountKey: accountKey,
                    observedAt: now,
                    rawJson: snapshot.rateLimitsRawJson
                )
            } catch {
                storageFailed = true
                insertedCount = 0
            }
            if insertedCount > 0, applyCachedQuotaSnapshotIfAvailable(for: accountKey) {
                return
            }
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
            let rawLimitID = candidate.limits.limitId ?? candidate.fallbackID
            let limitID = candidate.fallbackID == Self.primaryQuotaLimitId
                ? Self.primaryQuotaLimitId
                : (candidate.limits.limitName?.isEmpty == false
                    ? candidate.limits.limitName!
                    : rawLimitID)
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

        return limitIDOrder.flatMap { snapshotsByLimitID[$0] ?? [] }
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

        try RateLimitSnapshotRetention.prune(database: database)
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
        let rawLimitID = limits.limitId ?? fallbackLimitId
        let limitId = fallbackLimitId == Self.primaryQuotaLimitId
            ? Self.primaryQuotaLimitId
            : (limits.limitName?.isEmpty == false ? limits.limitName! : rawLimitID)
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

    private func registerProcessStatusUpdates() {
        Task { [weak self] in
            guard let self else { return }
            await processManager.onStatusChange { [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if status.isConnected {
                        guard self.serverRecoveryTask != nil,
                              !self.isFetchingServerSnapshot else { return }
                        if await self.fetchConnectedServerSnapshotIfPossible(
                            scheduleRetryOnFailure: true
                        ) {
                            await self.refreshData(
                                fetchServer: false,
                                scheduleRetryOnFailure: false
                            )
                        }
                        return
                    }

                    // UI 的 connected 还要求核心额度响应通过严格解码。
                    if self.state.hasQuotaSnapshot,
                       self.state.codexRefreshErrorText == nil {
                        return
                    }
                    self.state.connectionStatus = status
                    switch status {
                    case .failed, .reconnecting:
                        self.scheduleServerRecovery()
                    case .disconnected, .launching, .handshaking, .connected:
                        break
                    }
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

        ClaudeUsageSettings.shared.resetToDefaults()
        await stopClaudeServicesAndWait()
        stopAntigravityServices()

        // 1. 重置偏好设置 (UserDefaults)
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        UserDefaults.standard.synchronize()

        // 2. 恢复 Feature Flags 默认配置
        UsageFeatureFlags.shared.isAnalyticsEnabled = true
        UsageFeatureFlags.shared.isOverlayEnabled = true
        UsageFeatureFlags.shared.isAXSnappingEnabled = false
        UsageFeatureFlags.shared.isForecastEnabled = true
        ToolOverlayPreferences.reset()
        ClaudeOAuthCache.clear()

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
        state.lastRefreshAttemptAt = nil
        state.lastSuccessfulRefreshAt = nil
        state.codexRefreshErrorText = nil
        state.codexStorageErrorText = nil
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
        state.claudeRefreshIntervalSeconds = AppState.defaultClaudeRefreshIntervalSeconds
        state.antigravityRefreshIntervalSeconds = AppState.defaultAntigravityRefreshIntervalSeconds
        state.resetWeeklyQuotaRecoveryToFactoryDefaults()
        state.latestClaudeUsage = nil
        state.claudeUsageStatus = .disabled
        state.claudeUsageErrorText = nil
        state.claudeUsageCooldownUntil = nil
        state.latestAntigravityQuota = nil
        state.antigravityQuotaStatus = .disabled
        state.antigravityQuotaErrorText = nil
        state.latestAntigravityActivity = nil
        state.antigravityActivityWarningText = nil
        state.antigravityActivitySnapshotsByProfile = [:]
        state.providerQuotaInsights = [:]
        state.providerHistoryWarnings = []
        state.quotaRecommendations = []
        state.antigravitySyncState = ProviderSyncState(provider: .antigravity)
        state.antigravityAccountResolutionState = nil
        enabledToolsStore.resetToDefaults()
        frontmostToolTracker.refresh()
        navigationStore.normalize(
            enabledTools: enabledToolsStore.enabledToolIDs,
            activeTool: frontmostToolTracker.foregroundTool
        )
        toolOverlayCoordinator.refreshConfiguration()

        // 5. 重新触发全量数据扫描与重构
        await scanCoordinator.scanNow(forceRebuild: true)
        await refreshAllData(fetchServer: true, scheduleRetryOnFailure: true)
    }
}
