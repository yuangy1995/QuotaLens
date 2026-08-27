// QuotaLens 全局响应式状态中枢

import Foundation
import SwiftUI
import Combine

public enum QuotaDisplayMode: String, CaseIterable, Identifiable {
    case used
    case remaining

    public var id: String { rawValue }

    public var pickerTitle: String {
        switch self {
        case .used: return L10n.text("已用", "Used")
        case .remaining: return L10n.text("剩余可用", "Remaining")
        }
    }

    public var shortTitle: String {
        switch self {
        case .used: return L10n.text("已用", "Used")
        case .remaining: return L10n.text("可用", "Free")
        }
    }

    public var ringTitle: String {
        ringTitle(for: .weekly)
    }

    public func ringTitle(for window: QuotaWindowKind) -> String {
        switch self {
        case .used:
            return window == .fiveHour
                ? L10n.text("5小时已用", "Used in 5 Hours")
                : L10n.text("本周已用", "Used This Week")
        case .remaining:
            return window == .fiveHour
                ? L10n.text("5小时可用", "Available in 5 Hours")
                : L10n.text("本周可用", "Available This Week")
        }
    }

    public var primaryLabel: String {
        switch self {
        case .used: return L10n.text("已用:", "Used:")
        case .remaining: return L10n.text("可用:", "Available:")
        }
    }

    public var complementLabel: String {
        switch self {
        case .used: return L10n.text("可用:", "Available:")
        case .remaining: return L10n.text("已用:", "Used:")
        }
    }
}

public struct ResetCreditDisplay: Identifiable, Codable, Sendable {
    public let id: String
    public let accountKey: String?
    public let title: String?
    public let resetType: String?
    public let status: String?
    public let grantedAt: Int64?
    public let expiresAt: Int64?

    public var isAvailable: Bool {
        (status ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "available"
    }

    public func isValidAvailable(now: Date = Date()) -> Bool {
        guard isAvailable else { return false }
        guard let expiresAt else { return true }
        return expiresAt > Int64(now.timeIntervalSince1970)
    }

    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let resetType, !resetType.isEmpty { return resetType }
        return L10n.text("重置卡", "Reset card")
    }
}

public enum ResetCreditReminderSource: String, Sendable {
    case scheduled
    case snoozed
}

public struct ResetCreditReminderPlan: Sendable {
    public let accountKey: String?
    public let credit: ResetCreditDisplay
    public let deadlineAt: Int64
    public let usesSubscriptionDeadline: Bool
    public let dueAt: Date
    public let source: ResetCreditReminderSource
    public let deliveryKey: String
    public let shouldFireNow: Bool
}

public struct ResetCreditReminderAlert: Identifiable, Sendable {
    public let id: String
    public let accountKey: String?
    public let creditId: String
    public let creditTitle: String
    public let creditExpiresAt: Int64
    public let deadlineAt: Int64
    public let usesSubscriptionDeadline: Bool
    public let dueAt: Date
    public let triggeredAt: Date
    public let source: ResetCreditReminderSource
}

public enum AppThemeMode: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .light: return L10n.text("浅色", "Light")
        case .dark: return L10n.text("深色", "Dark")
        case .system: return L10n.text("跟随系统", "System")
        }
    }

    public var icon: String {
        switch self {
        case .light: return "sun.max.fill"
        case .dark: return "moon.stars.fill"
        case .system: return "circle.righthalf.filled"
        }
    }
}

@MainActor
public final class AppState: ObservableObject {
    private static let themeModeDefaultsKey = "QuotaLens.themeMode"
    private static let quotaDisplayModeDefaultsKey = "QuotaLens.quotaDisplayMode"
    private static let refreshIntervalDefaultsKey = "QuotaLens.refreshIntervalSeconds"
    private static let hideDockIconDefaultsKey = "QuotaLens.hideDockIcon"
    private static let resetCreditReminderEnabledDefaultsKey = "QuotaLens.resetCreditReminder.enabled"
    private static let resetCreditReminderAcknowledgedCreditIdDefaultsKey = "QuotaLens.resetCreditReminder.acknowledgedCreditId"
    private static let resetCreditReminderAcknowledgedExpiresAtDefaultsKey = "QuotaLens.resetCreditReminder.acknowledgedExpiresAt"
    private static let resetCreditReminderSnoozedCreditIdDefaultsKey = "QuotaLens.resetCreditReminder.snoozedCreditId"
    private static let resetCreditReminderSnoozeUntilDefaultsKey = "QuotaLens.resetCreditReminder.snoozeUntil"
    private static let resetCreditReminderLastDeliveredKeyDefaultsKey = "QuotaLens.resetCreditReminder.lastDeliveredKey"
    private static let dismissedSuggestionCycleKeysDefaultsKey = "QuotaLens.dismissedSuggestionCycleKeys"
    nonisolated public static let defaultRefreshIntervalSeconds = 60

    // 当前账户与外观主题
    @Published public var themeMode: AppThemeMode {
        didSet {
            UserDefaults.standard.set(themeMode.rawValue, forKey: Self.themeModeDefaultsKey)
        }
    }
    @Published public var languageMode: AppLanguageMode {
        didSet {
            UserDefaults.standard.set(languageMode.rawValue, forKey: L10n.languageModeDefaultsKey)
        }
    }
    @Published public var account: AccountRecord?
    @Published public var allAccounts: [AccountRecord] = []
    @Published public var selectedAccountKey: String? = nil {
        didSet {
            guard oldValue != selectedAccountKey else { return }
            resetAccountScopedStateForAccountChange(to: selectedAccountKey)
        }
    }
    @Published public var accountDisplayNames: [String: String] = [:]
    @Published public var connectionStatus: ProcessStatus = .disconnected
    @Published public var isRefreshing: Bool = false
    @Published public var isRetryingServerConnection: Bool = false
    @Published public var lastRefreshTime: Date = Date()
    @Published public var quotaDisplayMode: QuotaDisplayMode {
        didSet {
            UserDefaults.standard.set(quotaDisplayMode.rawValue, forKey: Self.quotaDisplayModeDefaultsKey)
        }
    }
    @Published public var refreshIntervalSeconds: Int {
        didSet {
            UserDefaults.standard.set(refreshIntervalSeconds, forKey: Self.refreshIntervalDefaultsKey)
        }
    }
    @Published public var hideDockIcon: Bool {
        didSet {
            UserDefaults.standard.set(hideDockIcon, forKey: Self.hideDockIconDefaultsKey)
        }
    }
    @Published public var resetCreditReminderEnabled: Bool {
        didSet {
            UserDefaults.standard.set(resetCreditReminderEnabled, forKey: Self.resetCreditReminderEnabledDefaultsKey)
        }
    }
    @Published public var launchAtLoginEnabled: Bool = false
    @Published public var launchAtLoginStatusText: String = L10n.text("未开启", "Off")
    @Published public private(set) var dismissedSuggestionCycleKeys: [String: String] = [:]

    // 当前额度
    @Published public var latestRateLimit: RateLimitSnapshotRecord?
    @Published public var hasCurrentServerQuota: Bool = false
    @Published public var resetCreditAvailableCount: Int = 0
    @Published public var resetCredits: [ResetCreditDisplay] = []
    @Published public var subscriptionStartsAt: Int64?
    @Published public var subscriptionEndsAt: Int64?
    @Published public var subscriptionPlanDisplayName: String?
    @Published public var subscriptionRenewalState: SubscriptionRenewalState = .unknown
    @Published public var subscriptionTargetPlanDisplayName: String?
    @Published public var subscriptionEntitlementFetchedAt: Int64?
    @Published public var subscriptionEntitlementErrorText: String?
    @Published public var appInitializationWarningText: String?
    @Published public var activeResetCreditReminder: ResetCreditReminderAlert?
    @Published public var nextResetCreditReminderAt: Date?

    private var acknowledgedResetCreditId: String?
    private var acknowledgedResetCreditExpiresAt: Int64?
    private var snoozedResetCreditId: String?
    private var resetCreditReminderSnoozeUntil: Date?
    private var lastDeliveredResetCreditReminderKey: String?

    public init() {
        let storedTheme = UserDefaults.standard.string(forKey: Self.themeModeDefaultsKey)
        self.themeMode = AppThemeMode(rawValue: storedTheme ?? "") ?? .light
        self.languageMode = L10n.languageMode

        let storedMode = UserDefaults.standard.string(forKey: Self.quotaDisplayModeDefaultsKey)
        self.quotaDisplayMode = QuotaDisplayMode(rawValue: storedMode ?? "") ?? .used

        let storedInterval = UserDefaults.standard.integer(forKey: Self.refreshIntervalDefaultsKey)
        self.refreshIntervalSeconds = Self.clampedRefreshInterval(
            storedInterval > 0 ? storedInterval : Self.defaultRefreshIntervalSeconds
        )
        self.hideDockIcon = UserDefaults.standard.bool(forKey: Self.hideDockIconDefaultsKey)
        if UserDefaults.standard.object(forKey: Self.resetCreditReminderEnabledDefaultsKey) == nil {
            self.resetCreditReminderEnabled = true
        } else {
            self.resetCreditReminderEnabled = UserDefaults.standard.bool(forKey: Self.resetCreditReminderEnabledDefaultsKey)
        }
        if let storedSuggestions = UserDefaults.standard.dictionary(forKey: Self.dismissedSuggestionCycleKeysDefaultsKey) as? [String: String] {
            self.dismissedSuggestionCycleKeys = storedSuggestions
        }
        self.loadResetCreditReminderState(accountKey: nil)
    }

    public var colorScheme: ColorScheme? {
        switch themeMode {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    public var effectiveColorScheme: ColorScheme {
        colorScheme ?? Self.currentSystemColorScheme
    }

    public static var currentSystemColorScheme: ColorScheme {
        let interfaceStyle = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        return interfaceStyle == "Dark" ? .dark : .light
    }

    public func setThemeMode(_ mode: AppThemeMode) {
        self.themeMode = mode
    }

    public func setLanguageMode(_ mode: AppLanguageMode) {
        languageMode = mode
        launchAtLoginStatusText = LoginItemManager.currentState().description
    }

    // 格式化辅助方法
    public var currentUsedPercent: Double {
        guard let snap = latestRateLimit else { return 0.0 }
        return Double(snap.usedPercentMilli) / 1000.0
    }

    public var currentRemainingPercent: Double {
        max(0.0, 100.0 - currentUsedPercent)
    }

    public var quotaWindowKind: QuotaWindowKind {
        QuotaWindowKind(windowDurationMins: latestRateLimit?.windowDurationMins)
    }

    public var isQuotaExhausted: Bool {
        hasQuotaSnapshot && currentRemainingPercent <= 0.000_1
    }

    public var currentUsedPercentString: String {
        formatPercent(currentUsedPercent)
    }

    public var currentRemainingPercentString: String {
        guard latestRateLimit != nil else { return "100%" }
        return formatPercent(currentRemainingPercent)
    }

    public var displayedQuotaPercent: Double {
        switch quotaDisplayMode {
        case .used: return currentUsedPercent
        case .remaining: return currentRemainingPercent
        }
    }

    public var displayedQuotaProgress: Double {
        min(max(displayedQuotaPercent / 100.0, 0.0), 1.0)
    }

    public var quotaRiskProgress: Double {
        min(max(currentUsedPercent / 100.0, 0.0), 1.0)
    }

    public var displayedQuotaPercentString: String {
        formatPercent(displayedQuotaPercent)
    }

    public var complementQuotaPercentString: String {
        switch quotaDisplayMode {
        case .used: return currentRemainingPercentString
        case .remaining: return currentUsedPercentString
        }
    }

    public var menuBarQuotaString: String {
        "\(quotaDisplayMode.shortTitle) \(displayedQuotaPercentString)"
    }

    public var hasQuotaSnapshot: Bool {
        latestRateLimit != nil && hasCurrentServerQuota && connectionStatus.isConnected
    }

    public var menuBarStatusString: String {
        guard hasQuotaSnapshot else {
            switch connectionStatus {
            case .connecting:
                return L10n.text("连接中", "Connecting")
            case .connected:
                if isRetryingServerConnection {
                    return L10n.text("重试中", "Retrying")
                }
                return L10n.text("已连接", "Connected")
            case .failed(let message):
                if isRetryingServerConnection {
                    return L10n.text("重试中", "Retrying")
                }
                if Self.isMissingCodexMessage(message) {
                    return L10n.text("未安装", "Missing")
                }
                return L10n.text("未连接", "Offline")
            case .disconnected:
                return L10n.text("未连接", "Offline")
            }
        }
        return menuBarQuotaString
    }

    public var quotaUnavailableTitle: String {
        if isRetryingServerConnection {
            return L10n.text("正在重新读取额度", "Retrying quota read")
        }

        switch connectionStatus {
        case .connecting:
            return L10n.text("正在连接", "Connecting")
        case .connected:
            return L10n.text("还没读到额度", "No quota yet")
        case .failed(let message):
            if Self.isMissingCodexMessage(message) {
                return L10n.text("未找到 Codex 可执行文件", "Codex executable not found")
            }
            return L10n.text("无法连接", "Cannot connect")
        case .disconnected:
            return L10n.text("未连接", "Offline")
        }
    }

    public var quotaUnavailableDescription: String {
        if isRetryingServerConnection {
            return L10n.text("暂时没有获取到额度，正在自动重试。", "Quota data was not available yet. Retrying automatically.")
        }

        switch connectionStatus {
        case .connecting:
            return L10n.text("连接成功后会显示当前账号额度。", "Quota for the current account appears after connection succeeds.")
        case .connected:
            return L10n.text("请确认已登录账号，稍后刷新。", "Confirm you are signed in, then refresh again shortly.")
        case .failed(let message):
            if Self.isMissingCodexMessage(message) {
                return Self.cleanedConnectionFailureMessage(message)
            }
            return Self.cleanedConnectionFailureMessage(message)
        case .disconnected:
            return L10n.text("连接后会显示当前账号额度。", "Quota for the current account appears after connecting.")
        }
    }

    public var quotaSeverityColor: Color {
        if currentRemainingPercent <= 15.0 {
            return .red
        }
        if currentRemainingPercent <= 35.0 {
            return .orange
        }
        return .green
    }

    public func setQuotaDisplayMode(_ mode: QuotaDisplayMode) {
        quotaDisplayMode = mode
    }

    public func toggleQuotaDisplayMode() {
        setQuotaDisplayMode(quotaDisplayMode == .used ? .remaining : .used)
    }

    public func setRefreshInterval(seconds: Int) {
        refreshIntervalSeconds = Self.clampedRefreshInterval(seconds)
    }

    public func setDockIconHidden(_ hidden: Bool) {
        hideDockIcon = hidden
    }

    public func setResetCreditReminderEnabled(_ enabled: Bool) {
        resetCreditReminderEnabled = enabled
        if !enabled {
            activeResetCreditReminder = nil
            nextResetCreditReminderAt = nil
            clearResetCreditReminderSnooze()
        }
    }

    public var refreshIntervalDescription: String {
        L10n.duration(seconds: refreshIntervalSeconds)
    }

    nonisolated public static func clampedRefreshInterval(_ seconds: Int) -> Int {
        min(max(seconds, 15), 3600)
    }

    private func formatPercent(_ value: Double) -> String {
        UsageNumberFormatter.percent(value)
    }

    public var resetCountdownString: String {
        guard let snap = latestRateLimit, let resetsAt = snap.resetsAt else { return L10n.text("未知", "Unknown") }
        let now = Date().timeIntervalSince1970
        let diff = resetsAt - Int64(now)
        if diff <= 0 {
            return L10n.text("即将重置", "Resetting soon")
        }
        let days = diff / 86400
        let hours = (diff % 86400) / 3600
        let mins = (diff % 3600) / 60
        let secs = diff % 60
        return L10n.countdown(days: days, hours: hours, minutes: mins, seconds: secs)
    }

    public func preciseCountdownString(until timestamp: Int64?, now: Date = Date()) -> String {
        guard let timestamp else { return L10n.text("未知", "Unknown") }
        return preciseDurationString(seconds: max(0, timestamp - Int64(now.timeIntervalSince1970)))
    }

    public func preciseDurationString(seconds: Int64) -> String {
        let safeSeconds = max(0, seconds)
        let days = safeSeconds / 86_400
        let hours = (safeSeconds % 86_400) / 3_600
        let minutes = (safeSeconds % 3_600) / 60
        let remainderSeconds = safeSeconds % 60
        return L10n.format(
            "%lld days %lld hours %lld minutes %lld seconds",
            zhHans: "%lld天 %lld时 %lld分 %lld秒",
            days,
            hours,
            minutes,
            remainderSeconds
        )
    }

    public var resetExactDateString: String? {
        guard let snap = latestRateLimit, let resetsAt = snap.resetsAt else { return nil }
        return formatFullDate(resetsAt)
    }

    /// 当前周期剩余天数（浮点数，支持传入当前基准时间）
    public func currentPeriodRemainingDays(now: Date = Date()) -> Double? {
        guard let snap = latestRateLimit, let resetsAt = snap.resetsAt else { return nil }
        let nowTs = now.timeIntervalSince1970
        let diff = resetsAt - Int64(nowTs)
        guard diff > 0 else { return 0.0 }
        return Double(diff) / 86400.0
    }

    public var currentPeriodRemainingDays: Double? {
        currentPeriodRemainingDays(now: Date())
    }

    /// 当前额度窗口内，按统一速率消耗至重置时刚好用完所需的时间单位数。
    public func currentQuotaRemainingUnits(now: Date = Date()) -> Double? {
        guard let resetsAt = latestRateLimit?.resetsAt else { return nil }
        let seconds = Double(resetsAt) - now.timeIntervalSince1970
        guard seconds > 0 else { return 0.0 }
        return seconds / quotaWindowKind.paceUnitSeconds
    }

    /// 建议按当前额度窗口均匀消耗的百分比。
    public func recommendedQuotaPacePercent(now: Date = Date()) -> Double? {
        guard currentRemainingPercent > 0.000_1 else { return nil }
        guard let units = currentQuotaRemainingUnits(now: now), units > 0 else { return nil }
        let pace = max(0.0, currentRemainingPercent / units)
        return quotaWindowKind == .fiveHour ? pace : min(100.0, pace)
    }

    public var recommendedQuotaPaceTitle: String {
        switch quotaWindowKind {
        case .fiveHour:
            return L10n.text("建议每小时消耗", "Hourly Budget Pace")
        case .weekly:
            return L10n.text("建议日均消耗", "Daily Budget Pace")
        }
    }

    public var recommendedQuotaPaceUnit: String {
        switch quotaWindowKind {
        case .fiveHour:
            return L10n.text("小时", "hour")
        case .weekly:
            return L10n.text("天", "day")
        }
    }

    public func recommendedQuotaPacePercentString(now: Date = Date()) -> String {
        guard let pace = recommendedQuotaPacePercent(now: now) else { return "--%" }
        return String(format: "%.1f%%", pace)
    }

    /// 建议额度速率短文案。
    public func recommendedQuotaPaceSubtitle(now: Date = Date()) -> String {
        if latestRateLimit != nil, currentRemainingPercent <= 0.000_1 {
            return L10n.text("本周期无可用额度 · 等待重置", "No quota remaining · Waiting for reset")
        }
        guard let units = currentQuotaRemainingUnits(now: now), units > 0 else {
            return L10n.text("周期即将结束", "Cycle ending soon")
        }

        switch quotaWindowKind {
        case .fiveHour:
            if units < 1.0 {
                let minutes = max(1, Int(units * 60.0))
                return L10n.format(
                    "About %d minutes remaining · Even pace",
                    zhHans: "剩余约 %d 分钟 · 匀速可用",
                    minutes
                )
            }
            return L10n.format(
                "About %.1f hours remaining · Even pace",
                zhHans: "剩余约 %.1f 小时 · 匀速可用",
                units
            )

        case .weekly:
            if units < 1.0 {
                let hours = max(1, Int(units * 24.0))
                return L10n.format("Remaining %d hours · Even pace", zhHans: "剩余约 %d 小时 · 匀速可用", hours)
            }
            return L10n.format("Remaining %.1f days · Even pace", zhHans: "剩余 %.1f 天 · 匀速可用", units)
        }
    }

    public var recommendedQuotaPacePercent: Double? {
        recommendedQuotaPacePercent(now: Date())
    }

    public var recommendedQuotaPacePercentString: String {
        recommendedQuotaPacePercentString(now: Date())
    }

    public var recommendedQuotaPaceSubtitle: String {
        recommendedQuotaPaceSubtitle(now: Date())
    }

    // 保留旧接口，避免外部调用方升级时失去周额度行为。
    public func recommendedDailyQuotaPercent(now: Date = Date()) -> Double? {
        recommendedQuotaPacePercent(now: now)
    }

    public var recommendedDailyQuotaPercent: Double? {
        recommendedQuotaPacePercent
    }

    public func recommendedDailyQuotaPercentString(now: Date = Date()) -> String {
        recommendedQuotaPacePercentString(now: now)
    }

    public var recommendedDailyQuotaPercentString: String {
        recommendedQuotaPacePercentString
    }

    public func recommendedDailyQuotaSubtitle(now: Date = Date()) -> String {
        recommendedQuotaPaceSubtitle(now: now)
    }

    public var recommendedDailyQuotaSubtitle: String {
        recommendedQuotaPaceSubtitle
    }

    public var quotaWindowStartDateString: String? {
        guard let startAt = quotaWindowStartAt else { return nil }
        return formatFullDate(startAt)
    }

    public var quotaWindowEndDateString: String? {
        guard let endAt = latestRateLimit?.resetsAt else { return nil }
        return formatFullDate(endAt)
    }

    public var availableResetCredits: [ResetCreditDisplay] {
        resetCredits.filter(\.isAvailable)
    }

    public var validResetCredits: [ResetCreditDisplay] {
        sortedValidResetCredits()
    }

    public var resetCreditMissingDetailCount: Int {
        max(0, resetCreditAvailableCount - validResetCredits.count)
    }

    public func sortedValidResetCredits(now: Date = Date()) -> [ResetCreditDisplay] {
        resetCredits
            .filter { $0.isValidAvailable(now: now) }
            .sorted {
                switch ($0.expiresAt, $1.expiresAt) {
                case let (lhs?, rhs?):
                    if lhs != rhs { return lhs < rhs }
                    return ($0.grantedAt ?? 0) < ($1.grantedAt ?? 0)
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return ($0.grantedAt ?? 0) < ($1.grantedAt ?? 0)
                }
            }
    }

    public var nearestValidResetCredit: ResetCreditDisplay? {
        validResetCredits.first
    }

    public var dashboardResetCredits: [ResetCreditDisplay] {
        nearestValidResetCredit.map { [$0] } ?? []
    }

    public var nearestResetCredit: ResetCreditDisplay? {
        let available = validResetCredits
        let pool = available.isEmpty ? resetCredits : available
        return pool
            .filter { $0.expiresAt != nil }
            .min { ($0.expiresAt ?? Int64.max) < ($1.expiresAt ?? Int64.max) }
            ?? pool.first
    }

    public var nearestResetCreditExpiryShortString: String? {
        guard let expiresAt = nearestResetCredit?.expiresAt else { return nil }
        return formatShortDate(expiresAt)
    }

    public func applySubscriptionEntitlement(_ snapshot: SubscriptionEntitlementSnapshot) {
        if let startsAt = snapshot.periodStartsAt {
            subscriptionStartsAt = startsAt
        }
        if let endsAt = snapshot.periodEndsAt {
            subscriptionEndsAt = endsAt
        }
        subscriptionPlanDisplayName = snapshot.planDisplayName
        subscriptionRenewalState = snapshot.renewalState
        subscriptionTargetPlanDisplayName = snapshot.targetPlanDisplayName
        subscriptionEntitlementFetchedAt = snapshot.fetchedAt
        subscriptionEntitlementErrorText = nil
    }

    public func applyLocalSubscriptionPeriodFallback(startsAt: Int64?, endsAt: Int64?) {
        if subscriptionStartsAt == nil {
            subscriptionStartsAt = startsAt
        }
        if subscriptionEndsAt == nil {
            subscriptionEndsAt = endsAt
        }
    }

    public func markSubscriptionEntitlementUnavailable(_ message: String) {
        subscriptionEntitlementErrorText = message
    }

    public var subscriptionPlanTitle: String {
        if let subscriptionPlanDisplayName, !subscriptionPlanDisplayName.isEmpty {
            return subscriptionPlanDisplayName
        }
        if let planType = account?.planType, !planType.isEmpty {
            return planType.uppercased()
        }
        return "UNKNOWN"
    }

    public var subscriptionRenewalStatusText: String {
        switch subscriptionRenewalState {
        case .autoRenews:
            return L10n.text("自动续费", "Auto-renews")
        case .ending:
            return L10n.text("到期终止订阅", "Ends at period close")
        case .changing:
            if let target = subscriptionTargetPlanDisplayName, !target.isEmpty {
                return L10n.format("Changes to %@", zhHans: "到期变更为 %@", target)
            }
            return L10n.text("到期变更订阅", "Plan changes at period close")
        case .unknown:
            if subscriptionEntitlementErrorText != nil {
                return L10n.text("续费状态待同步", "Renewal status pending")
            }
            return L10n.text("续费状态未知", "Renewal status unknown")
        }
    }

    public var subscriptionRenewalStatusShortText: String {
        switch subscriptionRenewalState {
        case .autoRenews:
            return L10n.text("自动续费", "Auto")
        case .ending:
            return L10n.text("到期终止", "Ending")
        case .changing:
            if let target = subscriptionTargetPlanDisplayName, !target.isEmpty {
                return L10n.format("To %@", zhHans: "变更到 %@", target)
            }
            return L10n.text("到期变更", "Changing")
        case .unknown:
            return L10n.text("待同步", "Pending")
        }
    }

    public var hasActiveResetCreditReminder: Bool {
        resetCreditReminderEnabled && activeResetCreditReminder != nil
    }

    public var resetCreditReminderStatusText: String {
        guard resetCreditReminderEnabled else { return L10n.text("已关闭", "Off") }
        if hasActiveResetCreditReminder {
            return L10n.text("等待处理", "Needs action")
        }
        guard let credit = nearestAvailableResetCreditForReminder else {
            return L10n.text("暂无可提醒重置卡", "No card to remind")
        }
        if isAcknowledged(credit) {
            return L10n.text("本张已确认", "Acknowledged")
        }
        if let nextResetCreditReminderAt {
            return L10n.format("Next %@", zhHans: "下次 %@", formatMonthDayTime(nextResetCreditReminderAt))
        }
        return L10n.text("已开启", "On")
    }

    public var resetCreditReminderDetailText: String {
        guard resetCreditReminderEnabled else {
            return L10n.text("开启后会在最近一张可用重置卡到期前一周提醒。", "When enabled, QuotaLens reminds you during the week before the nearest available reset card expires.")
        }
        guard let credit = nearestAvailableResetCreditForReminder, let expiresAt = credit.expiresAt else {
            return L10n.text("读取到可用重置卡后，将自动安排到期前提醒。", "A reminder will be scheduled automatically after an available reset card is detected.")
        }
        let deadline = effectiveResetCreditReminderDeadline(for: credit)
        if deadline.usesSubscriptionDeadline {
            return L10n.format(
                "The nearest %@ expires %@; the subscription ends or changes on %@.",
                zhHans: "最近一张 %@ 截止 %@，订阅将在 %@ 终止或变更。",
                credit.displayTitle,
                formatFullDate(expiresAt),
                formatFullDate(deadline.deadlineAt)
            )
        }
        return L10n.format("The nearest %@ expires %@", zhHans: "最近一张 %@ 截止 %@", credit.displayTitle, formatFullDate(expiresAt))
    }

    public var activeResetCreditReminderMessage: String {
        guard let reminder = activeResetCreditReminder else { return "" }
        if reminder.usesSubscriptionDeadline {
            return L10n.format(
                "%@ expires %@, but the subscription ends or changes on %@. Use it soon.",
                zhHans: "%@ 截止 %@，但订阅将在 %@ 终止或变更，请及时使用。",
                reminder.creditTitle,
                formatFullDate(reminder.creditExpiresAt),
                formatFullDate(reminder.deadlineAt)
            )
        }
        return L10n.format(
            "%@ expires %@. Use it soon.",
            zhHans: "%@ 将在 %@ 到期，请及时使用。",
            reminder.creditTitle,
            formatFullDate(reminder.creditExpiresAt)
        )
    }

    public func updateNextResetCreditReminderAt(_ date: Date?) {
        nextResetCreditReminderAt = date
    }

    public func replaceResetCredits(_ credits: [ResetCreditDisplay], availableCount: Int, accountKey: String?) {
        resetCredits = credits
        resetCreditAvailableCount = availableCount
        if let activeResetCreditReminder,
           activeResetCreditReminder.accountKey != accountKey {
            self.activeResetCreditReminder = nil
        }
        pruneResetCreditReminderState()
    }

    public func nextResetCreditReminderPlan(now: Date = Date()) -> ResetCreditReminderPlan? {
        guard resetCreditReminderEnabled,
              let credit = nearestAvailableResetCreditForReminder,
              credit.expiresAt != nil,
              !isAcknowledged(credit) else {
            return nil
        }

        let reminderDeadline = effectiveResetCreditReminderDeadline(for: credit)
        guard Date(timeIntervalSince1970: Double(reminderDeadline.deadlineAt)) > now else {
            return nil
        }

        let fixedSchedule = reminderScheduleDates(expiresAt: reminderDeadline.deadlineAt)
        let latestPastSchedule = fixedSchedule
            .filter { $0 <= now }
            .last
        if let dueAt = latestPastSchedule {
            let key = deliveryKey(for: credit, deadlineAt: reminderDeadline.deadlineAt, dueAt: dueAt, source: .scheduled)
            if key != lastDeliveredResetCreditReminderKey {
                return ResetCreditReminderPlan(
                    accountKey: credit.accountKey,
                    credit: credit,
                    deadlineAt: reminderDeadline.deadlineAt,
                    usesSubscriptionDeadline: reminderDeadline.usesSubscriptionDeadline,
                    dueAt: dueAt,
                    source: .scheduled,
                    deliveryKey: key,
                    shouldFireNow: true
                )
            }
        }

        if snoozedResetCreditId == credit.id,
           let snoozeUntil = resetCreditReminderSnoozeUntil,
           snoozeUntil <= now {
            let key = deliveryKey(for: credit, deadlineAt: reminderDeadline.deadlineAt, dueAt: snoozeUntil, source: .snoozed)
            if key != lastDeliveredResetCreditReminderKey {
                return ResetCreditReminderPlan(
                    accountKey: credit.accountKey,
                    credit: credit,
                    deadlineAt: reminderDeadline.deadlineAt,
                    usesSubscriptionDeadline: reminderDeadline.usesSubscriptionDeadline,
                    dueAt: snoozeUntil,
                    source: .snoozed,
                    deliveryKey: key,
                    shouldFireNow: true
                )
            }
            clearResetCreditReminderSnooze()
        }

        let nextFixedSchedule = fixedSchedule.first { $0 > now }
        let nextSnooze = (snoozedResetCreditId == credit.id) ? resetCreditReminderSnoozeUntil : nil
        let candidates = [nextFixedSchedule, nextSnooze].compactMap { $0 }
        guard let nextDue = candidates.min() else { return nil }
        let source: ResetCreditReminderSource = nextDue == nextSnooze ? .snoozed : .scheduled
        return ResetCreditReminderPlan(
            accountKey: credit.accountKey,
            credit: credit,
            deadlineAt: reminderDeadline.deadlineAt,
            usesSubscriptionDeadline: reminderDeadline.usesSubscriptionDeadline,
            dueAt: nextDue,
            source: source,
            deliveryKey: deliveryKey(for: credit, deadlineAt: reminderDeadline.deadlineAt, dueAt: nextDue, source: source),
            shouldFireNow: false
        )
    }

    public func activateResetCreditReminder(_ plan: ResetCreditReminderPlan, now: Date = Date()) {
        lastDeliveredResetCreditReminderKey = plan.deliveryKey
        UserDefaults.standard.set(
            plan.deliveryKey,
            forKey: resetCreditReminderScopedDefaultsKey(Self.resetCreditReminderLastDeliveredKeyDefaultsKey, accountKey: plan.accountKey)
        )
        if plan.source == .snoozed {
            clearResetCreditReminderSnooze(accountKey: plan.accountKey)
        }
        activeResetCreditReminder = ResetCreditReminderAlert(
            id: plan.deliveryKey,
            accountKey: plan.accountKey,
            creditId: plan.credit.id,
            creditTitle: plan.credit.displayTitle,
            creditExpiresAt: plan.credit.expiresAt ?? 0,
            deadlineAt: plan.deadlineAt,
            usesSubscriptionDeadline: plan.usesSubscriptionDeadline,
            dueAt: plan.dueAt,
            triggeredAt: now,
            source: plan.source
        )
    }

    public func acknowledgeActiveResetCreditReminder() {
        guard let reminder = activeResetCreditReminder else { return }
        acknowledgedResetCreditId = reminder.creditId
        acknowledgedResetCreditExpiresAt = reminder.creditExpiresAt
        UserDefaults.standard.set(reminder.creditId, forKey: resetCreditReminderScopedDefaultsKey(Self.resetCreditReminderAcknowledgedCreditIdDefaultsKey, accountKey: reminder.accountKey))
        UserDefaults.standard.set(reminder.creditExpiresAt, forKey: resetCreditReminderScopedDefaultsKey(Self.resetCreditReminderAcknowledgedExpiresAtDefaultsKey, accountKey: reminder.accountKey))
        activeResetCreditReminder = nil
        nextResetCreditReminderAt = nil
        clearResetCreditReminderSnooze(accountKey: reminder.accountKey)
    }

    public func snoozeActiveResetCreditReminder(hours: Int) {
        guard let reminder = activeResetCreditReminder else { return }
        let snoozeUntil = Date().addingTimeInterval(Double(hours) * 3600)
        snoozedResetCreditId = reminder.creditId
        resetCreditReminderSnoozeUntil = snoozeUntil
        UserDefaults.standard.set(reminder.creditId, forKey: resetCreditReminderScopedDefaultsKey(Self.resetCreditReminderSnoozedCreditIdDefaultsKey, accountKey: reminder.accountKey))
        UserDefaults.standard.set(snoozeUntil.timeIntervalSince1970, forKey: resetCreditReminderScopedDefaultsKey(Self.resetCreditReminderSnoozeUntilDefaultsKey, accountKey: reminder.accountKey))
        activeResetCreditReminder = nil
        nextResetCreditReminderAt = snoozeUntil
    }

    public func pruneResetCreditReminderState() {
        guard let credit = nearestAvailableResetCreditForReminder,
              let expiresAt = credit.expiresAt,
              Date(timeIntervalSince1970: Double(expiresAt)) > Date(),
              Date(timeIntervalSince1970: Double(effectiveResetCreditReminderDeadline(for: credit).deadlineAt)) > Date() else {
            activeResetCreditReminder = nil
            nextResetCreditReminderAt = nil
            clearResetCreditReminderSnooze()
            return
        }

        if let activeResetCreditReminder,
           activeResetCreditReminder.accountKey != credit.accountKey ||
           activeResetCreditReminder.creditId != credit.id ||
           activeResetCreditReminder.creditExpiresAt != expiresAt {
            self.activeResetCreditReminder = nil
        }

        if snoozedResetCreditId != nil,
           (snoozedResetCreditId != credit.id || resetCreditReminderSnoozeUntil == nil) {
            clearResetCreditReminderSnooze()
        }
    }

    public var accountPeriodStartDateString: String? {
        guard let startAt = subscriptionStartsAt else { return nil }
        return formatFullDate(startAt)
    }

    public var accountPeriodEndDateString: String? {
        guard let endAt = subscriptionEndsAt else { return nil }
        return formatFullDate(endAt)
    }

    public var hasSubscriptionPeriod: Bool {
        subscriptionStartsAt != nil || subscriptionEndsAt != nil
    }

    public var subscriptionPeriodText: String {
        guard hasSubscriptionPeriod else { return "" }

        let start = accountPeriodStartDateString ?? L10n.text("未知开始", "Unknown start")
        let end = accountPeriodEndDateString ?? L10n.text("未知结束", "Unknown end")
        return "\(start)  ~  \(end) · \(subscriptionPlanTitle) · \(subscriptionRenewalStatusText)"
    }

    public var subscriptionPeriodShortText: String {
        guard hasSubscriptionPeriod else { return "" }

        let start = subscriptionStartsAt.map(formatShortDate) ?? L10n.text("未知开始", "Unknown start")
        let end = subscriptionEndsAt.map(formatShortDate) ?? L10n.text("未知结束", "Unknown end")
        return "\(start) ~ \(end) · \(subscriptionRenewalStatusShortText)"
    }

    public var subscriptionPeriodRangeShortText: String {
        guard hasSubscriptionPeriod else { return "" }

        let start = subscriptionStartsAt.map(formatShortDate) ?? L10n.text("未知开始", "Unknown start")
        let end = subscriptionEndsAt.map(formatShortDate) ?? L10n.text("未知结束", "Unknown end")
        return "\(start) ~ \(end)"
    }

    private var quotaWindowStartAt: Int64? {
        guard let snap = latestRateLimit,
              let resetsAt = snap.resetsAt,
              let duration = snap.windowDurationMins else {
            return nil
        }
        return resetsAt - Int64(duration * 60)
    }

    public func formatFullDate(_ timestamp: Int64) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = L10n.locale
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp)))
    }

    private func formatShortDate(_ timestamp: Int64) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = L10n.locale
        formatter.timeZone = .current
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp)))
    }

    public func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = L10n.locale
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    public func formatMonthDayTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = L10n.locale
        formatter.timeZone = .current
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    public func displayName(for accountKey: String?) -> String {
        guard let accountKey else { return L10n.text("未选择账号", "No account selected") }
        if let displayName = accountDisplayNames[accountKey] {
            return displayName
        }
        if accountKey.hasPrefix("acc_"), accountKey.contains("@") {
            return String(accountKey.dropFirst("acc_".count))
        }
        if accountKey.hasPrefix("acc_") {
            return L10n.format("Local account %@", zhHans: "本地账号 %@", String(accountKey.dropFirst("acc_".count).prefix(8)))
        }
        return accountKey
    }

    private static func isMissingCodexMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("未找到 codex")
            || lower.contains("没有找到 codex")
            || lower.contains("codex executable")
            || lower.contains("codex was not found")
            || lower.contains("codex cli")
            || lower.contains("not found")
    }

    private static func cleanedConnectionFailureMessage(_ message: String) -> String {
        var cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["额度刷新失败：", "Quota refresh failed: "] {
            if cleaned.hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return cleaned.isEmpty
            ? L10n.text("请检查 Codex 是否已安装并登录。", "Check that Codex is installed and signed in.")
            : cleaned
    }

    private var nearestAvailableResetCreditForReminder: ResetCreditDisplay? {
        availableResetCredits
            .filter { credit in
                guard let expiresAt = credit.expiresAt else { return false }
                return Date(timeIntervalSince1970: Double(expiresAt)) > Date()
            }
            .min { ($0.expiresAt ?? Int64.max) < ($1.expiresAt ?? Int64.max) }
    }

    private func reminderScheduleDates(expiresAt: Int64) -> [Date] {
        let expiryDate = Date(timeIntervalSince1970: Double(expiresAt))
        let calendar = Calendar.current
        let expiryDay = calendar.startOfDay(for: expiryDate)
        var dates: [Date] = []

        for daysBefore in stride(from: 7, through: 1, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -daysBefore, to: expiryDay) else { continue }
            let hours = daysBefore >= 4 ? [10] : [10, 14, 19]
            for hour in hours {
                guard let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day),
                      date < expiryDate else {
                    continue
                }
                dates.append(date)
            }
        }

        return dates.sorted()
    }

    private func isAcknowledged(_ credit: ResetCreditDisplay) -> Bool {
        acknowledgedResetCreditId == credit.id && acknowledgedResetCreditExpiresAt == credit.expiresAt
    }

    private func effectiveResetCreditReminderDeadline(for credit: ResetCreditDisplay) -> (deadlineAt: Int64, usesSubscriptionDeadline: Bool) {
        let creditExpiresAt = credit.expiresAt ?? Int64.max
        guard subscriptionRenewalState == .ending || subscriptionRenewalState == .changing,
              let subscriptionEndsAt,
              subscriptionEndsAt > Int64(Date().timeIntervalSince1970),
              subscriptionEndsAt < creditExpiresAt else {
            return (creditExpiresAt, false)
        }
        return (subscriptionEndsAt, true)
    }

    private func deliveryKey(for credit: ResetCreditDisplay, deadlineAt: Int64, dueAt: Date, source: ResetCreditReminderSource) -> String {
        "\(source.rawValue):\(credit.accountKey ?? "unscoped"):\(credit.id):\(credit.expiresAt ?? 0):\(deadlineAt):\(Int64(dueAt.timeIntervalSince1970))"
    }

    private func resetAccountScopedStateForAccountChange(to accountKey: String?) {
        if account?.accountKey != accountKey {
            account = nil
            allAccounts = []
        }
        latestRateLimit = nil
        hasCurrentServerQuota = false
        resetCreditAvailableCount = 0
        resetCredits = []
        activeResetCreditReminder = nil
        nextResetCreditReminderAt = nil
        loadResetCreditReminderState(accountKey: accountKey)
        subscriptionStartsAt = nil
        subscriptionEndsAt = nil
        subscriptionPlanDisplayName = nil
        subscriptionRenewalState = .unknown
        subscriptionTargetPlanDisplayName = nil
        subscriptionEntitlementFetchedAt = nil
        subscriptionEntitlementErrorText = nil
    }

    private func loadResetCreditReminderState(accountKey: String?) {
        acknowledgedResetCreditId = UserDefaults.standard.string(forKey: resetCreditReminderScopedDefaultsKey(Self.resetCreditReminderAcknowledgedCreditIdDefaultsKey, accountKey: accountKey))
        let acknowledgedExpiresAt = UserDefaults.standard.object(
            forKey: resetCreditReminderScopedDefaultsKey(Self.resetCreditReminderAcknowledgedExpiresAtDefaultsKey, accountKey: accountKey)
        ) as? NSNumber
        acknowledgedResetCreditExpiresAt = acknowledgedExpiresAt?.int64Value
        snoozedResetCreditId = UserDefaults.standard.string(forKey: resetCreditReminderScopedDefaultsKey(Self.resetCreditReminderSnoozedCreditIdDefaultsKey, accountKey: accountKey))
        let snoozeUntil = UserDefaults.standard.double(forKey: resetCreditReminderScopedDefaultsKey(Self.resetCreditReminderSnoozeUntilDefaultsKey, accountKey: accountKey))
        resetCreditReminderSnoozeUntil = snoozeUntil > 0 ? Date(timeIntervalSince1970: snoozeUntil) : nil
        lastDeliveredResetCreditReminderKey = UserDefaults.standard.string(forKey: resetCreditReminderScopedDefaultsKey(Self.resetCreditReminderLastDeliveredKeyDefaultsKey, accountKey: accountKey))
    }

    private func resetCreditReminderScopedDefaultsKey(_ baseKey: String, accountKey: String? = nil) -> String {
        "\(baseKey).\(accountKey ?? selectedAccountKey ?? "unscoped")"
    }

    private func clearResetCreditReminderSnooze(accountKey: String? = nil) {
        snoozedResetCreditId = nil
        resetCreditReminderSnoozeUntil = nil
        UserDefaults.standard.removeObject(forKey: resetCreditReminderScopedDefaultsKey(Self.resetCreditReminderSnoozedCreditIdDefaultsKey, accountKey: accountKey))
        UserDefaults.standard.removeObject(forKey: resetCreditReminderScopedDefaultsKey(Self.resetCreditReminderSnoozeUntilDefaultsKey, accountKey: accountKey))
    }

    // MARK: - 首页智能建议引擎 (Dashboard Smart Suggestions)
    public var currentCycleKey: String? {
        guard let snap = latestRateLimit, let resetsAt = snap.resetsAt else { return nil }
        let accountKey = selectedAccountKey ?? account?.accountKey ?? "default"
        return "\(accountKey):\(resetsAt)"
    }

    public func dismissSuggestion(_ id: DashboardSuggestionID) {
        guard let cycleKey = currentCycleKey else { return }
        dismissedSuggestionCycleKeys[id.rawValue] = cycleKey
        UserDefaults.standard.set(dismissedSuggestionCycleKeys, forKey: Self.dismissedSuggestionCycleKeysDefaultsKey)
    }

    public func isSuggestionDismissedForCurrentCycle(_ id: DashboardSuggestionID) -> Bool {
        guard let currentCycleKey else { return false }
        return dismissedSuggestionCycleKeys[id.rawValue] == currentCycleKey
    }

    public var activeDashboardSuggestion: DashboardSuggestion? {
        // 规则 1: 额度耗尽且存在有效重置卡时，提示使用重置卡恢复额度
        if hasQuotaSnapshot,
           isQuotaExhausted,
           resetCreditAvailableCount > 0,
           let credit = nearestValidResetCredit,
           !isSuggestionDismissedForCurrentCycle(.useResetCardWhenExhausted) {

            let title = L10n.text("建议使用重置卡恢复额度", "Restore Quota with Reset Card")
            let expiryText = credit.expiresAt != nil ? formatFullDate(credit.expiresAt!) : nil
            let message: String
            if let expiryText {
                message = L10n.format(
                    "Current quota is exhausted. You have %d valid reset card (expires %@). Use it now to restore your quota.",
                    zhHans: "本周期可用额度已耗尽。检测到您持有 %d 张有效重置卡（最近截止 %@），建议立即使用恢复可用额度。",
                    resetCreditAvailableCount,
                    expiryText
                )
            } else {
                message = L10n.format(
                    "Current quota is exhausted. You have %d valid reset card. Use it now to restore your quota.",
                    zhHans: "本周期可用额度已耗尽。检测到您持有 %d 张有效重置卡，建议立即使用恢复可用额度。",
                    resetCreditAvailableCount
                )
            }

            return DashboardSuggestion(
                id: .useResetCardWhenExhausted,
                title: title,
                message: message,
                icon: "sparkles",
                primaryActionTitle: L10n.text("立即使用", "Use Now"),
                dismissActionTitle: L10n.text("本周期内忽略", "Dismiss for this cycle"),
                payload: .resetCredit(credit)
            )
        }

        return nil
    }
}
