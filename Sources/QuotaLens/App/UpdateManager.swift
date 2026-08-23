// Sparkle-backed online update coordination.

import Foundation
import AppKit
import Sparkle

@MainActor
public final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    private var updaterController: SPUStandardUpdaterController?
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
        return L10n.text("开发者发布密钥未配置", "Developer update signing key is not configured")
    }

    public var detailText: String {
        if isConfigured {
            return L10n.format("In-app updates automatically use the %@ build; users do not choose a package manually.", zhHans: "App 内升级会自动使用 %@ 版本，不需要手动选择安装包。", architectureDisplayName)
        }
        return L10n.text("正式发布前需要写入 Sparkle 公钥，并在 GitHub Secrets 中保存私钥。", "Before release, embed the Sparkle public key and store the private key in GitHub Secrets.")
    }

    public var architectureDisplayName: String {
        switch Self.currentArchitectureKey {
        case "apple-silicon":
            return "Apple Silicon"
        case "intel":
            return "Intel"
        default:
            return "macOS"
        }
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
        updater.checkForUpdates()
    }

    public func openProjectPage() {
        NSWorkspace.shared.open(Self.projectURL)
    }

    public func feedURLString(for updater: SPUUpdater) -> String? {
        Self.currentArchitectureFeedURL.absoluteString
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

    private func showUpdatesNotConfiguredAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.text("当前构建未配置在线升级", "This build is not configured for online updates")
        alert.informativeText = detailText
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.text("知道了", "OK"))
        alert.runModal()
    }
}
