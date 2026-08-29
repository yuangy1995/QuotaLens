// QuotaLens macOS 应用入口 (主窗口 + MenuBarExtra 菜单栏)

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = AppEnvironment.shared
        environment.applyDockIconVisibility()
        environment.applyThemeAppearance()
        environment.installStartupMenuBarController()
        environment.mainWindowCoordinator.showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppEnvironment.shared.mainWindowCoordinator.showMainWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct QuotaLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var env: AppEnvironment

    public init() {
        let environment = AppEnvironment.shared
        _env = StateObject(wrappedValue: environment)
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button(L10n.text("应用设置", "App Settings")) {
                    env.mainWindowCoordinator.showAppSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button(L10n.text("检查更新...", "Check for Updates...")) {
                    env.updateManager.checkForUpdates()
                }

                Button(L10n.text("刷新数据", "Refresh Data")) {
                    Task {
                        await env.refreshAllData()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
