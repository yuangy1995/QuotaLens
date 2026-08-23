// QuotaLens 全局依赖注入与生命周期协调器 (后台异步流式加载，零主线程阻塞)

import Foundation
import SwiftUI
import AppKit
import Combine

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

    private var refreshLoopTask: Task<Void, Never>?
    private var serverRecoveryTask: Task<Void, Never>?
    private var resetCreditReminderTask: Task<Void, Never>?
    private var subscriptionEntitlementRetryTask: Task<Void, Never>?
    private var notificationHandlersRegistered = false
    private var isFetchingServerSnapshot = false
    private var isFetchingSubscriptionEntitlement = false
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

        do {
            DevelopmentDatabaseReset.resetIfLegacySyntheticDataExists(databasePath: dbPath)
            self.database = try SQLiteDatabase(path: dbPath)
            try SchemaMigrations.migrate(database: database)
        } catch {
            fatalError("无法初始化 QuotaLens 数据库: \(error)")
        }

        self.repositories = Repositories(database: database)
        self.transport = JSONRPCTransport()
        self.processManager = CodexProcessManager(transport: transport)
        self.accountProbe = AccountProbeActor(transport: transport, repositories: repositories)
        self.updateManager = UpdateManager()
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

        // 4. 立即触发首帧数据刷新
        Task { @MainActor [weak self] in
            await self?.refreshData()
        }

        // 5. 启动可配置的周期性状态刷新，默认 1 分钟。
        self.scheduleRefreshTimer()

        // 6. 用 Web entitlement 后台补齐订阅周期、续费/降级状态。
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

    public func openOrFocusMainWindow(createWindow: () -> Void) {
        if let window = NSApp.windows.first(where: isMainWindow) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
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
        guard !isFetchingSubscriptionEntitlement else {
            return state.subscriptionRenewalState != .unknown
        }
        let accountKeyAtStart = currentStateAccountKey()
        isFetchingSubscriptionEntitlement = true
        defer { isFetchingSubscriptionEntitlement = false }

        let localPeriod = ChatGPTSubscriptionClient.localSubscriptionPeriodFromAuth()
        if currentStateAccountKey() == accountKeyAtStart {
            state.applyLocalSubscriptionPeriodFallback(startsAt: localPeriod.startsAt, endsAt: localPeriod.endsAt)
        }

        do {
            let snapshot = try await ChatGPTSubscriptionClient.fetch()
            guard currentStateAccountKey() == accountKeyAtStart else {
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
            guard currentStateAccountKey() == accountKeyAtStart else {
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
        state.selectedAccountKey = key
        Task {
            await refreshData()
        }
    }

    /// 删除指定账户
    public func deleteAccount(accountKey: String) {
        try? repositories.deleteAccount(accountKey: accountKey)
        if state.selectedAccountKey == accountKey {
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
        state.isRefreshing = true
        defer {
            state.isRefreshing = false
            state.lastRefreshTime = Date()
        }

        do {
            if fetchServer {
                await fetchServerSnapshotIfPossible(scheduleRetryOnFailure: scheduleRetryOnFailure)
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

            // 2. 读取真实主额度快照
            state.latestRateLimit = try latestPrimaryQuotaSnapshot(accountKey: accKey)
            if state.hasCurrentServerQuota && state.latestRateLimit == nil {
                state.hasCurrentServerQuota = false
                if scheduleRetryOnFailure {
                    scheduleServerRecovery()
                }
            }
            if !state.hasCurrentServerQuota {
                state.latestRateLimit = nil
            }
            restoreResetCreditState(for: accKey, snapshot: state.latestRateLimit)
            await refreshSubscriptionEntitlementIfPossible(scheduleRetryOnFailure: scheduleRetryOnFailure)
        } catch {
            // 刷新容错
        }
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

        do {
            async let accountPayload = try? rpcPayload(AccountReadResult.self, method: "account/read")
            async let rateLimitsPayload = try? rpcPayload(RateLimitsReadResult.self, method: "account/rateLimits/read")
            let account = await accountPayload
            let rateLimits = await rateLimitsPayload

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

    private func rpcPayload<T: Decodable>(_ type: T.Type, method: String) async throws -> (value: T?, rawJson: String) {
        let response = try await transport.sendRequest(method: method, params: [:], timeoutSeconds: 5.0)
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
        guard !isFetchingServerSnapshot else { return state.hasCurrentServerQuota }
        isFetchingServerSnapshot = true
        defer { isFetchingServerSnapshot = false }

        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try CodexServerSnapshotClient.fetch()
            }.value

            try persistServerSnapshot(snapshot)
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
            state.hasCurrentServerQuota = false
            state.latestRateLimit = nil
            restoreResetCreditState(for: state.selectedAccountKey ?? state.account?.accountKey ?? "acc_local", snapshot: nil)
            state.connectionStatus = .failed(L10n.format("Quota refresh failed: %@", zhHans: "额度刷新失败：%@", error.localizedDescription))
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

    private func persistServerSnapshot(_ snapshot: CodexServerSnapshot) throws {
        let now = Int64(Date().timeIntervalSince1970)
        var accountKey = state.selectedAccountKey ?? state.account?.accountKey ?? "acc_local"

        if let accountInfo = snapshot.account?.account {
            let identifier = accountInfo.stableIdentifier
            accountKey = AccountIdentity.stableAccountKey(from: identifier)
            let record = AccountRecord(
                accountKey: accountKey,
                emailHash: AccountIdentity.emailHash(from: identifier),
                planType: accountInfo.planType,
                firstSeenAt: now,
                lastSeenAt: now
            )
            try repositories.upsertAccount(record)
            serverAccountDisplayNames[accountKey] = accountInfo.displayIdentifier
            state.accountDisplayNames[accountKey] = accountInfo.displayIdentifier
            state.selectedAccountKey = accountKey
            state.account = record
            state.allAccounts = [record]
            state.applyLocalSubscriptionPeriodFallback(
                startsAt: accountInfo.subscriptionStartsAt,
                endsAt: accountInfo.subscriptionEndsAt
            )
        }

        if let rateLimits = snapshot.rateLimits {
            updateResetCreditState(from: rateLimits.rateLimitResetCredits, accountKey: accountKey)
            let insertedCount = try persistRateLimits(rateLimits, accountKey: accountKey, observedAt: now, rawJson: snapshot.rateLimitsRawJson)
            state.hasCurrentServerQuota = insertedCount > 0
            state.latestRateLimit = try latestPrimaryQuotaSnapshot(accountKey: accountKey)
            if insertedCount == 0 || state.latestRateLimit == nil {
                state.hasCurrentServerQuota = false
                state.latestRateLimit = nil
            }
        } else {
            updateResetCreditState(from: nil, accountKey: accountKey)
            state.hasCurrentServerQuota = false
            state.latestRateLimit = nil
        }

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
}
