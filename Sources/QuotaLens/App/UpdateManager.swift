// Sparkle 在线升级协调器。

import Foundation
import AppKit
import Sparkle

public enum UpdateDialogKind: Sendable, Equatable {
    case checking
    case available
    case latest
    case failure
    case progress
    case ready
    case installing
}

public struct UpdateDialogState: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let kind: UpdateDialogKind
    public let title: String
    public let message: String
    public let newVersion: String?
    public let currentVersion: String?
    public let packageSizeBytes: UInt64?
    public let releaseNotes: String?
    public let releaseNotesURL: URL?
    public let primaryButtonTitle: String
    public let secondaryButtonTitle: String?
    public let progress: Double?
    public let primaryButtonEnabled: Bool

    public init(
        kind: UpdateDialogKind,
        title: String,
        message: String,
        newVersion: String? = nil,
        currentVersion: String? = nil,
        packageSizeBytes: UInt64? = nil,
        releaseNotes: String? = nil,
        releaseNotesURL: URL? = nil,
        primaryButtonTitle: String,
        secondaryButtonTitle: String? = nil,
        progress: Double? = nil,
        primaryButtonEnabled: Bool = true
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.newVersion = newVersion
        self.currentVersion = currentVersion
        self.packageSizeBytes = packageSizeBytes
        self.releaseNotes = releaseNotes
        self.releaseNotesURL = releaseNotesURL
        self.primaryButtonTitle = primaryButtonTitle
        self.secondaryButtonTitle = secondaryButtonTitle
        self.progress = progress
        self.primaryButtonEnabled = primaryButtonEnabled
    }
}

@MainActor
public final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    private let userDriver = QuotaLensSparkleUserDriver()
    private var updater: SPUUpdater?
    @Published public private(set) var isCheckingForUpdates = false
    @Published public private(set) var updateStatusText: String?
    @Published public private(set) var updateDetailText: String?
    @Published public private(set) var updateDialog: UpdateDialogState?
    private var dialogPrimaryAction: (() -> Void)?
    private var dialogSecondaryAction: (() -> Void)?
    private static let projectURL = URL(string: "https://github.com/yuangy1995/QuotaLens")!
    private static let releaseFeedBaseURL = "https://github.com/yuangy1995/QuotaLens/releases/latest/download"

    public override init() {
        super.init()
        userDriver.updateManager = self

        guard Self.hasValidSparkleConfiguration else {
            return
        }

        let updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: userDriver,
            delegate: self
        )
        do {
            try updater.start()
            self.updater = updater
            _ = updater.clearFeedURLFromUserDefaults()
        } catch {
            updateStatusText = L10n.text("在线升级不可用", "Online updates unavailable")
            updateDetailText = error.localizedDescription
        }
    }

    public var isConfigured: Bool {
        updater != nil
    }

    public var statusText: String {
        if isConfigured {
            return L10n.text("在线升级已启用", "Online updates enabled")
        }
        return L10n.text("在线升级不可用", "Online updates unavailable")
    }

    public var automaticallyChecksForUpdates: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set {
            updater?.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    public var automaticallyDownloadsUpdates: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set {
            updater?.automaticallyDownloadsUpdates = newValue
            objectWillChange.send()
        }
    }

    public var updateCheckInterval: TimeInterval {
        get { updater?.updateCheckInterval ?? 86_400 }
        set {
            updater?.updateCheckInterval = newValue
            objectWillChange.send()
        }
    }

    public var lastUpdateCheckText: String {
        guard let date = updater?.lastUpdateCheckDate else {
            return L10n.text("尚未检查", "Never checked")
        }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    public func checkForUpdates() {
        guard let updater else {
            showUpdateDialog(
                kind: .failure,
                title: L10n.text("在线升级不可用", "Online updates unavailable"),
                message: L10n.text("当前构建未配置在线升级。", "This build is not configured for online updates."),
                primaryButtonTitle: L10n.text("知道了", "OK"),
                primaryAction: { [weak self] in self?.dismissUpdateDialog() }
            )
            return
        }

        // 清理 URLCache，确保每次手动检查更新都向服务器获取最新 Appcast
        URLCache.shared.removeAllCachedResponses()
        updater.checkForUpdates()
    }

    public func performUpdateDialogPrimaryAction() {
        let action = dialogPrimaryAction
        clearDialogActions()
        action?()
    }

    public func performUpdateDialogSecondaryAction() {
        let action = dialogSecondaryAction
        clearDialogActions()
        action?()
    }

    public func dismissUpdateDialog() {
        updateDialog = nil
        clearDialogActions()
    }

    public func openProjectPage() {
        NSWorkspace.shared.open(Self.projectURL)
    }

    public func openReleasesPage() {
        if let url = URL(string: "https://github.com/yuangy1995/QuotaLens/releases") {
            NSWorkspace.shared.open(url)
        }
    }

    public func openIssuesPage() {
        if let url = URL(string: "https://github.com/yuangy1995/QuotaLens/issues") {
            NSWorkspace.shared.open(url)
        }
    }

    public func openLicensePage() {
        if let url = URL(string: "https://github.com/yuangy1995/QuotaLens/blob/main/LICENSE") {
            NSWorkspace.shared.open(url)
        }
    }

    public func feedURLString(for updater: SPUUpdater) -> String? {
        let base = Self.currentArchitectureFeedURL.absoluteString
        let timestamp = Int(Date().timeIntervalSince1970)
        return "\(base)?t=\(timestamp)"
    }

    fileprivate func showChecking(cancellation: @escaping () -> Void) {
        isCheckingForUpdates = true
        updateStatusText = L10n.text("正在检查更新", "Checking for updates")
        updateDetailText = L10n.text("正在连接更新服务并比较版本。", "Connecting to the update service and comparing versions.")
        showUpdateDialog(
            kind: .checking,
            title: L10n.text("正在检查更新", "Checking for updates"),
            message: L10n.text("正在连接更新服务并比较版本。", "Connecting to the update service and comparing versions."),
            primaryButtonTitle: L10n.text("取消", "Cancel"),
            primaryAction: { [weak self] in
                cancellation()
                self?.dismissUpdateDialog()
            }
        )
    }

    fileprivate func showPermissionRequest(reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        showUpdateDialog(
            kind: .available,
            title: L10n.text("启用自动更新", "Enable automatic updates"),
            message: L10n.text("QuotaLens 可以自动检查并下载后续更新。", "QuotaLens can automatically check for and download future updates."),
            primaryButtonTitle: L10n.text("启用", "Enable"),
            secondaryButtonTitle: L10n.text("稍后", "Later"),
            primaryAction: { [weak self] in
                reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, automaticUpdateDownloading: true, sendSystemProfile: false))
                self?.dismissUpdateDialog()
            },
            secondaryAction: { [weak self] in
                reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, automaticUpdateDownloading: false, sendSystemProfile: false))
                self?.dismissUpdateDialog()
            }
        )
    }

    fileprivate func showUpdateFound(appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        isCheckingForUpdates = false
        updateStatusText = L10n.text("发现可用更新", "Update available")
        updateDetailText = L10n.format("QuotaLens %@ is available.", zhHans: "QuotaLens %@ 已可下载。", appcastItem.displayVersionString)

        let releaseNotesText = Self.cleanReleaseNotes(appcastItem.itemDescription, version: appcastItem.displayVersionString)

        showUpdateDialog(
            kind: .available,
            title: L10n.text("发现可用更新", "Update available"),
            message: updateDetailText ?? L10n.text("发现新版本，可以下载并安装。", "A new version is available to download and install."),
            newVersion: appcastItem.displayVersionString,
            currentVersion: AppVersion.marketingVersion,
            packageSizeBytes: appcastItem.contentLength > 0 ? UInt64(appcastItem.contentLength) : nil,
            releaseNotes: releaseNotesText,
            releaseNotesURL: appcastItem.releaseNotesURL,
            primaryButtonTitle: state.stage == .downloaded ? L10n.text("安装更新", "Install Update") : L10n.text("下载并安装", "Download and Install"),
            secondaryButtonTitle: L10n.text("稍后", "Later"),
            primaryAction: { [weak self] in
                reply(.install)
                self?.showProgress(
                    title: L10n.text("正在准备更新", "Preparing update"),
                    message: L10n.text("Sparkle 正在准备下载或安装更新。", "Sparkle is preparing to download or install the update."),
                    progress: nil
                )
            },
            secondaryAction: { [weak self] in
                reply(.dismiss)
                self?.dismissUpdateDialog()
            }
        )
    }

    fileprivate func showUpdateNotFound(error: NSError, acknowledgement: @escaping () -> Void) {
        isCheckingForUpdates = false
        updateStatusText = L10n.text("未发现可用更新", "No update found")
        updateDetailText = noUpdateFoundDetail(for: error)
        showUpdateDialog(
            kind: noUpdateFoundDialogKind(for: error),
            title: noUpdateFoundTitle(for: error),
            message: updateDetailText ?? noUpdateFoundDetail(for: error),
            primaryButtonTitle: L10n.text("知道了", "OK"),
            primaryAction: { [weak self] in
                acknowledgement()
                self?.dismissUpdateDialog()
            }
        )
    }

    fileprivate func showUpdaterError(error: NSError, acknowledgement: @escaping () -> Void) {
        isCheckingForUpdates = false
        updateStatusText = L10n.text("检查更新失败", "Update check failed")
        updateDetailText = cleanUpdateErrorMessage(error.localizedDescription)
        showUpdateDialog(
            kind: .failure,
            title: L10n.text("无法检查更新", "Unable to Check for Updates"),
            message: updateDetailText ?? L10n.text("QuotaLens 未能完成更新检测，请稍后再试。", "QuotaLens could not complete the update check. Try again later."),
            primaryButtonTitle: L10n.text("知道了", "OK"),
            primaryAction: { [weak self] in
                acknowledgement()
                self?.dismissUpdateDialog()
            }
        )
    }

    fileprivate func showDownloadStarted(cancellation: @escaping () -> Void) {
        showUpdateDialog(
            kind: .progress,
            title: L10n.text("正在下载更新", "Downloading update"),
            message: L10n.format("%d%% downloaded", zhHans: "已下载 %d%%", 0),
            primaryButtonTitle: L10n.text("取消", "Cancel"),
            progress: 0.0,
            primaryAction: { [weak self] in
                cancellation()
                self?.dismissUpdateDialog()
            }
        )
    }

    fileprivate func showProgress(title: String, message: String, progress: Double?) {
        updateStatusText = title
        updateDetailText = message
        let isCancellable = dialogPrimaryAction != nil
        showUpdateDialog(
            kind: .progress,
            title: title,
            message: message,
            primaryButtonTitle: isCancellable ? L10n.text("取消", "Cancel") : L10n.text("请稍候", "Please wait"),
            progress: progress,
            primaryButtonEnabled: isCancellable
        )
    }

    fileprivate func showProgressWithoutCancellation(title: String, message: String, progress: Double?) {
        clearDialogActions()
        showProgress(title: title, message: message, progress: progress)
    }

    fileprivate func showReadyToInstall(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        showUpdateDialog(
            kind: .ready,
            title: L10n.text("更新已准备好", "Update Ready"),
            message: L10n.text("更新已下载完成，可以安装并重启 QuotaLens。", "The update has finished downloading and is ready to install and relaunch QuotaLens."),
            primaryButtonTitle: L10n.text("安装并重启", "Install and Relaunch"),
            secondaryButtonTitle: L10n.text("稍后", "Later"),
            primaryAction: { [weak self] in
                reply(.install)
                self?.showInstalling(applicationTerminated: false, retryTerminatingApplication: {})
            },
            secondaryAction: { [weak self] in
                reply(.dismiss)
                self?.dismissUpdateDialog()
            }
        )
    }

    fileprivate func showInstalling(applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        showUpdateDialog(
            kind: .installing,
            title: L10n.text("正在安装更新", "Installing Update"),
            message: applicationTerminated
                ? L10n.text("QuotaLens 已退出，正在完成安装。", "QuotaLens has quit and the update is being installed.")
                : L10n.text("正在安装更新，必要时会自动重启应用。", "Installing the update. The app will relaunch if needed."),
            primaryButtonTitle: L10n.text("请稍候", "Please wait")
        )
    }

    fileprivate func showInstalled(relaunched: Bool, acknowledgement: @escaping () -> Void) {
        showUpdateDialog(
            kind: .latest,
            title: L10n.text("更新已安装", "Update Installed"),
            message: relaunched
                ? L10n.text("QuotaLens 已更新并重新启动。", "QuotaLens has updated and relaunched.")
                : L10n.text("QuotaLens 已完成更新。", "QuotaLens has finished updating."),
            primaryButtonTitle: L10n.text("知道了", "OK"),
            primaryAction: { [weak self] in
                acknowledgement()
                self?.dismissUpdateDialog()
            }
        )
    }

    fileprivate func dismissUpdateInstallation() {
        isCheckingForUpdates = false
        dismissUpdateDialog()
    }

    fileprivate func focusUpdateDialog() {
        NSApp.activate(ignoringOtherApps: true)
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

    private func noUpdateFoundTitle(for error: NSError) -> String {
        switch noUpdateFoundReasonValue(for: error) {
        case 3, 4, 5:
            return L10n.text("发现新版本，但这台 Mac 无法安装", "A newer QuotaLens is available, but this Mac cannot install it.")
        default:
            return L10n.text("您使用的就是最新版本！", "You're up to date!")
        }
    }

    private func noUpdateFoundDialogKind(for error: NSError) -> UpdateDialogKind {
        switch noUpdateFoundReasonValue(for: error) {
        case 3, 4, 5:
            return .failure
        default:
            return .latest
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
                    "QuotaLens %@ was found, but it was not selected for installation on this Mac.",
                    zhHans: "检测到 QuotaLens %@，但这台 Mac 当前无法安装。",
                    latestVersionText
                )
            }
            return L10n.format(
                "QuotaLens %@ is currently the newest version available.",
                zhHans: "QuotaLens %@ 已是当前最新版本。",
                latestVersionText ?? AppVersion.marketingVersion
            )
        }
    }

    private func noUpdateFoundReasonValue(for error: NSError) -> Int? {
        (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
    }

    private func latestAppcastDisplayVersion(for error: NSError) -> String? {
        (error.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem)?.displayVersionString
    }

    private func cleanUpdateErrorMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return L10n.text("QuotaLens 未能完成更新检测，请稍后再试。", "QuotaLens could not complete the update check. Try again later.")
        }
        if trimmed.localizedCaseInsensitiveContains("http://")
            || trimmed.localizedCaseInsensitiveContains("https://")
            || trimmed.localizedCaseInsensitiveContains("appcast") {
            return L10n.text("无法读取更新信息，请检查网络后重试。", "Update information could not be loaded. Check the network and try again.")
        }
        return trimmed
    }

    nonisolated static func cleanReleaseNotes(_ raw: String?, version: String) -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return L10n.text("全新版本发布与多项性能优化。", "New version release with performance and stability improvements.")
        }

        var cleaned = raw
            .replacingOccurrences(of: "<![CDATA[", with: "")
            .replacingOccurrences(of: "]]>", with: "")
            .replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</li>", with: "\n", options: .caseInsensitive)

        while let start = cleaned.range(of: "<"), let end = cleaned.range(of: ">", range: start.lowerBound..<cleaned.endIndex) {
            cleaned.removeSubrange(start.lowerBound...end.lowerBound)
        }

        let lines = cleaned.components(separatedBy: .newlines)
        var meaningfulLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.localizedCaseInsensitiveContains("architecture-specific")
                || trimmed.localizedCaseInsensitiveContains("in-app update feed")
                || trimmed.localizedCaseInsensitiveContains("appcast")
                || trimmed.lowercased() == "quotalens v\(version.lowercased())"
                || trimmed.lowercased() == "quotalens \(version.lowercased())"
                || trimmed.lowercased() == "v\(version.lowercased())"
                || trimmed.lowercased() == version.lowercased() {
                continue
            }
            meaningfulLines.append(trimmed)
        }

        if meaningfulLines.isEmpty {
            return L10n.text("全新版本发布与多项性能优化。", "New version release with performance and stability improvements.")
        }

        return meaningfulLines.joined(separator: "\n")
    }

    private func showUpdateDialog(
        kind: UpdateDialogKind,
        title: String,
        message: String,
        newVersion: String? = nil,
        currentVersion: String? = nil,
        packageSizeBytes: UInt64? = nil,
        releaseNotes: String? = nil,
        releaseNotesURL: URL? = nil,
        primaryButtonTitle: String,
        secondaryButtonTitle: String? = nil,
        progress: Double? = nil,
        primaryButtonEnabled: Bool? = nil,
        primaryAction: (() -> Void)? = nil,
        secondaryAction: (() -> Void)? = nil
    ) {
        if let primaryAction {
            dialogPrimaryAction = primaryAction
        } else if kind != .checking && kind != .progress {
            dialogPrimaryAction = nil
        }
        dialogSecondaryAction = secondaryAction
        updateDialog = UpdateDialogState(
            kind: kind,
            title: title,
            message: message,
            newVersion: newVersion,
            currentVersion: currentVersion,
            packageSizeBytes: packageSizeBytes,
            releaseNotes: releaseNotes,
            releaseNotesURL: releaseNotesURL,
            primaryButtonTitle: primaryButtonTitle,
            secondaryButtonTitle: secondaryButtonTitle,
            progress: progress,
            primaryButtonEnabled: primaryButtonEnabled ?? (primaryAction != nil || (kind == .checking || kind == .progress) && dialogPrimaryAction != nil)
        )
    }

    private func clearDialogActions() {
        dialogPrimaryAction = nil
        dialogSecondaryAction = nil
    }
}

@MainActor
private final class QuotaLensSparkleUserDriver: NSObject, SPUUserDriver {
    weak var updateManager: UpdateManager?
    private var expectedContentLength: UInt64 = 0
    private var receivedContentLength: UInt64 = 0

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        updateManager?.showPermissionRequest(reply: reply)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        updateManager?.showChecking(cancellation: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        updateManager?.showUpdateFound(appcastItem: appcastItem, state: state, reply: reply)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        updateManager?.showUpdateNotFound(error: error as NSError, acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        updateManager?.showUpdaterError(error: error as NSError, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedContentLength = 0
        receivedContentLength = 0
        updateManager?.showDownloadStarted(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        self.expectedContentLength = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedContentLength += length
        guard expectedContentLength > 0 else { return }
        let progress = min(1, Double(receivedContentLength) / Double(expectedContentLength))
        updateManager?.showProgress(
            title: L10n.text("正在下载更新", "Downloading update"),
            message: L10n.format("%d%% downloaded", zhHans: "已下载 %d%%", Int(progress * 100)),
            progress: progress
        )
    }

    func showDownloadDidStartExtractingUpdate() {
        updateManager?.showProgressWithoutCancellation(
            title: L10n.text("正在解压更新", "Extracting update"),
            message: L10n.text("更新已下载完成，正在解压。", "The update has downloaded and is being extracted."),
            progress: nil
        )
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        updateManager?.showProgressWithoutCancellation(
            title: L10n.text("正在解压更新", "Extracting update"),
            message: L10n.format("%d%% extracted", zhHans: "已解压 %d%%", Int(progress * 100)),
            progress: progress
        )
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        updateManager?.showReadyToInstall(reply: reply)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        updateManager?.showInstalling(applicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        updateManager?.showInstalled(relaunched: relaunched, acknowledgement: acknowledgement)
    }

    func dismissUpdateInstallation() {
        updateManager?.dismissUpdateInstallation()
    }

    func showUpdateInFocus() {
        updateManager?.focusUpdateDialog()
    }
}
