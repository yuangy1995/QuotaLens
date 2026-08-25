// QuotaLens macOS 应用入口 (主窗口 + MenuBarExtra 菜单栏)

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = AppEnvironment.shared
        environment.applyDockIconVisibility()
        environment.applyThemeAppearance()
        environment.installStartupMenuBarController()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if AppEnvironment.shared.focusExistingMainWindow() {
            return false
        }
        return true
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

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // 主窗口
        Window("QuotaLens", id: "main") {
            MainView(state: env.state)
                .environmentObject(env)
                .frame(minWidth: 960, minHeight: 650)
                .onAppear {
                    env.installMenuBarController(
                        onOpenMainWindow: {
                            env.openOrFocusMainWindow {
                                openWindow(id: "main")
                            }
                        },
                        onRefresh: {
                            Task {
                                await env.refreshAllData()
                            }
                        }
                    )
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
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
