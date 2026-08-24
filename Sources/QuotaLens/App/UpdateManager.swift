// Sparkle-backed online update coordination.

import Foundation
import AppKit
import Sparkle

@MainActor
public final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    private var updaterController: SPUStandardUpdaterController?
    @Published public private(set) var isCheckingForUpdates = false
    @Published public private(set) var updateStatusText: String?
    @Published public private(set) var updateDetailText: String?
    private var manualUpdateCheckHandled = false
    private var pendingUserInitiatedUpdatePresentation = false
    private static let projectURL = URL(string: "https://github.com/yuangy1995/QuotaLens")!
    private static let releaseFeedBaseURL = "https://github.com/yuangy1995/QuotaLens/releases/latest/download"

    public override init() {
        super.init()
        if Self.hasValidSparkleConfiguration {
            self.updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: self,
                userDriverDelegate: nil
            )
        }
    }

    public var isConfigured: Bool {
        updaterController != nil
    }

    public var statusText: String {
        if isConfigured {
            return L10n.text("在线升级已启用", "Online updates enabled")
        }
        return L10n.text("在线升级不可用", "Online updates unavailable")
    }

    public var feedURLText: String {
        Self.currentArchitectureFeedURL.absoluteString
    }

    public var canCheckForUpdates: Bool {
        updaterController?.updater.canCheckForUpdates ?? false
    }

    public var automaticallyChecksForUpdates: Bool {
        get { updaterController?.updater.automaticallyChecksForUpdates ?? false }
        set {
            updaterController?.updater.automaticallyChecksForUpdates = newValue
            if !newValue {
                updaterController?.updater.automaticallyDownloadsUpdates = false
            }
            objectWillChange.send()
        }
    }

    public var allowsAutomaticDownloads: Bool {
        updaterController?.updater.allowsAutomaticUpdates ?? false
    }

    public var automaticallyDownloadsUpdates: Bool {
        get { updaterController?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            guard let updater = updaterController?.updater else {
                updateStatusText = L10n.text("在线升级不可用", "Online updates unavailable")
                updateDetailText = L10n.text("当前构建未配置 Sparkle，无法更改自动下载设置。", "Sparkle is not configured in this build, so automatic downloads cannot be changed.")
                objectWillChange.send()
                return
            }

            if newValue, updater.automaticallyChecksForUpdates == false {
                updater.automaticallyChecksForUpdates = true
            }

            updater.automaticallyDownloadsUpdates = newValue
            let appliedValue = updater.automaticallyDownloadsUpdates
            if appliedValue == newValue {
                updateStatusText = newValue
                    ? L10n.text("自动下载已开启", "Automatic downloads enabled")
                    : L10n.text("自动下载已关闭", "Automatic downloads disabled")
                updateDetailText = newValue
                    ? L10n.text("发现新版本后，Sparkle 会在后台下载更新。", "When a new version is found, Sparkle will download it in the background.")
                    : L10n.text("发现新版本后，将只提示下载和安装。", "When a new version is found, QuotaLens will only prompt before downloading and installing.")
            } else {
                updateStatusText = L10n.text("自动下载未能开启", "Automatic downloads could not be enabled")
                updateDetailText = updater.allowsAutomaticUpdates
                    ? L10n.text("Sparkle 没有接受这次设置写入，请确认应用不是从磁盘镜像或只读位置运行。", "Sparkle did not accept this setting change. Confirm the app is not running from a disk image or read-only location.")
                    : L10n.text("Sparkle 当前报告不允许自动下载。已为你保留手动检查和手动安装。", "Sparkle currently reports that automatic downloads are not allowed. Manual checks and installs remain available.")
            }
            objectWillChange.send()
        }
    }

    public var updateCheckInterval: TimeInterval {
        get { updaterController?.updater.updateCheckInterval ?? 86_400 }
        set {
            updaterController?.updater.updateCheckInterval = newValue
            objectWillChange.send()
        }
    }

    public var lastUpdateCheckText: String {
        guard let date = updaterController?.updater.lastUpdateCheckDate else {
            return L10n.text("尚未检查", "Never checked")
        }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    public func checkForUpdates() {
        guard let updater = updaterController?.updater else {
            showUpdatesNotConfiguredAlert()
            return
        }
        guard updater.canCheckForUpdates else {
            updateStatusText = L10n.text("暂时无法检查更新", "Cannot check for updates right now")
            updateDetailText = L10n.text("Sparkle 正在处理另一个更新会话，请稍后再试。", "Sparkle is handling another update session. Try again shortly.")
            return
        }
        isCheckingForUpdates = true
        updateStatusText = L10n.text("正在检查更新", "Checking for updates")
        updateDetailText = L10n.format("Update feed: %@", zhHans: "正在读取更新源：%@", feedURLText)
        manualUpdateCheckHandled = false
        pendingUserInitiatedUpdatePresentation = false
        updater.checkForUpdateInformation()
    }

    public func openProjectPage() {
        NSWorkspace.shared.open(Self.projectURL)
    }

    public func feedURLString(for updater: SPUUpdater) -> String? {
        Self.currentArchitectureFeedURL.absoluteString
    }

    @objc(updater:didFinishLoadingAppcast:)
    public func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        guard isCheckingForUpdates else { return }
        updateStatusText = L10n.text("已读取更新信息", "Update feed loaded")
        updateDetailText = L10n.text("正在比较当前版本与可安装版本。", "Comparing the current version with installable updates.")
    }

    @objc(updater:didFindValidUpdate:)
    public func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard isCheckingForUpdates else {
            return
        }
        manualUpdateCheckHandled = true
        updateStatusText = L10n.text("发现可用更新", "Update available")
        updateDetailText = L10n.format("QuotaLens %@ is available.", zhHans: "QuotaLens %@ 已可下载。", item.displayVersionString)
        showUpdateAvailableAlert(for: item)
    }

    @objc(updaterDidNotFindUpdate:error:)
    public func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        guard isCheckingForUpdates else {
            return
        }
        manualUpdateCheckHandled = true
        updateStatusText = L10n.text("未发现可用更新", "No update found")
        updateDetailText = noUpdateFoundDetail(for: error as NSError)
        showNoUpdateFoundAlert(error: error as NSError)
    }

    @objc(updater:didFinishUpdateCycleForUpdateCheck:error:)
    public func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard isCheckingForUpdates else {
            return
        }

        let shouldPresentUpdate = pendingUserInitiatedUpdatePresentation
        let handledResult = manualUpdateCheckHandled
        isCheckingForUpdates = false
        manualUpdateCheckHandled = false
        pendingUserInitiatedUpdatePresentation = false

        if shouldPresentUpdate {
            updateStatusText = L10n.text("正在打开更新安装器", "Opening update installer")
            updateDetailText = L10n.text("Sparkle 将继续下载并安装所选更新。", "Sparkle will continue downloading and installing the selected update.")
            DispatchQueue.main.async {
                updater.checkForUpdates()
            }
            return
        }

        if !handledResult, let error {
            updateStatusText = L10n.text("检查更新失败", "Update check failed")
            updateDetailText = error.localizedDescription
            showUpdateCheckFailedAlert(error: error as NSError)
        }
    }

    private static var hasValidSparkleConfiguration: Bool {
        guard let feedURL = bundleString(forKey: "SUFeedURL"),
              let publicKey = bundleString(forKey: "SUPublicEDKey") else {
            return false
        }
        return !isPlaceholder(feedURL) && !isPlaceholder(publicKey)
    }

    private static func bundleString(forKey key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isPlaceholder(_ value: String) -> Bool {
        value.hasPrefix("__") || value.hasSuffix("__")
    }

    private static var currentArchitectureFeedURL: URL {
        URL(string: "\(releaseFeedBaseURL)/appcast-\(currentArchitectureKey).xml")!
    }

    private static var currentArchitectureKey: String {
        #if arch(arm64)
        return "apple-silicon"
        #elseif arch(x86_64)
        return "intel"
        #else
        return "universal"
        #endif
    }

    private func showUpdateAvailableAlert(for item: SUAppcastItem) {
        let alert = NSAlert()
        alert.messageText = L10n.text("发现可用更新", "Update Available")
        alert.informativeText = L10n.format(
            "QuotaLens %@ is available. Continue to download and install it.",
            zhHans: "QuotaLens %@ 已可下载。是否下载并安装？",
            item.displayVersionString
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.text("下载并安装", "Download and Install"))
        alert.addButton(withTitle: L10n.text("稍后", "Later"))
        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            pendingUserInitiatedUpdatePresentation = true
        }
    }

    private func showNoUpdateFoundAlert(error: NSError) {
        let alert = NSAlert()
        alert.messageText = noUpdateFoundTitle(for: error)
        alert.informativeText = noUpdateFoundDetail(for: error)
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.text("好", "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showUpdateCheckFailedAlert(error: NSError) {
        let alert = NSAlert()
        alert.messageText = L10n.text("无法检查更新", "Unable to Check for Updates")
        alert.informativeText = error.localizedDescription.isEmpty
            ? L10n.text("QuotaLens 未能完成更新检测，请稍后再试。", "QuotaLens could not complete the update check. Try again later.")
            : error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.text("好", "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func noUpdateFoundTitle(for error: NSError) -> String {
        switch noUpdateFoundReasonValue(for: error) {
        case 3, 4, 5:
            return L10n.text("发现新版本，但这台 Mac 无法安装", "A newer QuotaLens is available, but this Mac cannot install it.")
        default:
            return L10n.text("您使用的就是最新版本！", "You're up to date!")
        }
    }

    private func noUpdateFoundDetail(for error: NSError) -> String {
        let latestVersionText = latestAppcastDisplayVersion(for: error)
        switch noUpdateFoundReasonValue(for: error) {
        case 3, 4, 5:
            return L10n.text(
                "可用更新不符合这台 Mac 的 macOS 或硬件要求。",
                "The available update does not match this Mac's macOS or hardware requirements."
            )
        default:
            if let latestVersionText, latestVersionText != AppVersion.marketingVersion {
                return L10n.format(
                    "The update feed reports QuotaLens %@, but Sparkle did not select it for installation. Feed: %@",
                    zhHans: "更新源报告 QuotaLens %@，但 Sparkle 未选择安装。更新源：%@",
                    latestVersionText,
                    feedURLText
                )
            }
            return L10n.format(
                "QuotaLens %@ is currently the newest version available. Feed: %@",
                zhHans: "QuotaLens %@ 是当前更新源中的最新版本。更新源：%@",
                latestVersionText ?? AppVersion.marketingVersion,
                feedURLText
            )
        }
    }

    private func noUpdateFoundReasonValue(for error: NSError) -> Int? {
        (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
    }

    private func latestAppcastDisplayVersion(for error: NSError) -> String? {
        (error.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem)?.displayVersionString
    }

    private func showUpdatesNotConfiguredAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.text("当前构建未配置在线升级", "This build is not configured for online updates")
        alert.informativeText = L10n.text("当前版本暂不支持在线升级。", "This version does not support online updates.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.text("知道了", "OK"))
        alert.runModal()
    }
}
