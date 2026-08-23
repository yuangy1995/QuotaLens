// Sparkle-backed online update coordination.

import Foundation
import AppKit
import Sparkle

@MainActor
public final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    private var updaterController: SPUStandardUpdaterController?
    @Published public private(set) var isCheckingForUpdates = false
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

    public var canCheckForUpdates: Bool {
        updaterController?.updater.canCheckForUpdates ?? false
    }

    public var automaticallyChecksForUpdates: Bool {
        get { updaterController?.updater.automaticallyChecksForUpdates ?? false }
        set {
            updaterController?.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    public var automaticallyDownloadsUpdates: Bool {
        get { updaterController?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            updaterController?.updater.automaticallyDownloadsUpdates = newValue
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
            return
        }
        isCheckingForUpdates = true
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

    public func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard isCheckingForUpdates else {
            return
        }
        manualUpdateCheckHandled = true
        showUpdateAvailableAlert(for: item)
    }

    public func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        guard isCheckingForUpdates else {
            return
        }
        manualUpdateCheckHandled = true
        showNoUpdateFoundAlert(error: error as NSError)
    }

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
            DispatchQueue.main.async {
                updater.checkForUpdates()
            }
            return
        }

        if !handledResult, let error {
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
        switch noUpdateFoundReasonValue(for: error) {
        case 3, 4, 5:
            return L10n.text(
                "可用更新不符合这台 Mac 的 macOS 或硬件要求。",
                "The available update does not match this Mac's macOS or hardware requirements."
            )
        default:
            return L10n.format(
                "QuotaLens %@ is currently the newest version available.",
                zhHans: "QuotaLens %@ 是当前可用的最新版本。",
                AppVersion.marketingVersion
            )
        }
    }

    private func noUpdateFoundReasonValue(for error: NSError) -> Int? {
        (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
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
