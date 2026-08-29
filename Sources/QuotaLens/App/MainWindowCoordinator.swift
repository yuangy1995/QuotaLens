import AppKit
import SwiftUI

@MainActor
public final class MainWindowCoordinator: NSObject, NSWindowDelegate {
    private weak var environment: AppEnvironment?
    private var windowController: NSWindowController?

    public init(environment: AppEnvironment) {
        self.environment = environment
        super.init()
    }

    public var window: NSWindow? {
        windowController?.window
    }

    public var isMainWindowVisible: Bool {
        window?.isVisible == true
    }

    public func showMainWindow() {
        guard let environment else { return }
        environment.prepareForMainWindowActivation()
        let window = ensureWindow(environment: environment)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @discardableResult
    public func focusExistingMainWindow() -> Bool {
        guard windowController?.window != nil else { return false }
        showMainWindow()
        return true
    }

    public func showAppSettings() {
        environment?.navigationStore.showFixedDestination(.appSettings)
        showMainWindow()
    }

    private func ensureWindow(environment: AppEnvironment) -> NSWindow {
        if let window = windowController?.window {
            return window
        }

        let content = MainView(
            state: environment.state,
            enabledTools: environment.enabledToolsStore,
            navigation: environment.navigationStore
        )
        .environmentObject(environment)
        .frame(minWidth: 960, minHeight: 650)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.title = "QuotaLens"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = nil
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 960, height: 650)
        window.contentViewController = NSHostingController(rootView: content)
        window.delegate = self
        window.setFrameAutosaveName("QuotaLens.MainWindow")
        if !window.setFrameUsingName("QuotaLens.MainWindow") {
            window.center()
        }

        let controller = NSWindowController(window: window)
        windowController = controller
        return window
    }
}
