// QuotaLens macOS 应用入口 (主窗口 + MenuBarExtra 菜单栏)

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppEnvironment.shared.applyDockIconVisibility()
        AppEnvironment.shared.applyThemeAppearance()
        NSApp.activate(ignoringOtherApps: true)
        // 强制立即初始化全局单例环境
        _ = AppEnvironment.shared
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppEnvironment.shared.prepareForMainWindowActivation()
        if !flag {
            for window in sender.windows {
                window.makeKeyAndOrderFront(nil)
            }
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
                                await env.refreshData()
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
                .disabled(env.updateManager.isConfigured && !env.updateManager.canCheckForUpdates)

                Button(L10n.text("刷新数据", "Refresh Data")) {
                    Task {
                        await env.refreshData()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
