// QuotaLens 目标窗口悬浮挂件控制器与跟踪器 (CodexUsageOverlayController)
// 纯 AppKit 非激活浮动 Panel，贴靠 ChatGPT / Codex 窗口边缘，提供即时用量与额度浮窗

import SwiftUI
import AppKit

public final class CodexUsageOverlayController: NSObject, ObservableObject, @unchecked Sendable {
    public static let shared = CodexUsageOverlayController()

    private var panel: NSPanel?
    private var trackerTask: Task<Void, Never>?
    private var isExpanded: Bool = false
    @MainActor private weak var environment: AppEnvironment?

    public override init() {
        super.init()
    }

    @MainActor
    public func setEnabled(_ enabled: Bool, environment: AppEnvironment? = nil) {
        if let environment {
            self.environment = environment
        }
        if enabled {
            startTracking()
        } else {
            stopTracking()
        }
    }

    @MainActor
    public func startTracking() {
        guard panel == nil else { return }
        guard let environment else { return }

        let p = NSPanel(
            contentRect: NSRect(x: 100, y: 100, width: 140, height: 34),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isFloatingPanel = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true

        let overlayView = CodexOverlayView(onToggleExpand: { [weak self] in
            self?.toggleExpand()
        })
        .environmentObject(environment)
        p.contentView = NSHostingView(rootView: overlayView)
        p.orderFront(nil)
        self.panel = p

        startWindowTrackerLoop()
    }

    @MainActor
    public func stopTracking() {
        trackerTask?.cancel()
        trackerTask = nil
        panel?.close()
        panel = nil
    }

    @MainActor
    private func toggleExpand() {
        isExpanded.toggle()
        guard let p = panel else { return }

        let newSize = isExpanded ? NSSize(width: 240, height: 160) : NSSize(width: 140, height: 34)
        var frame = p.frame
        frame.size = newSize
        p.setFrame(frame, display: true, animate: true)
    }

    private func startWindowTrackerLoop() {
        trackerTask?.cancel()
        trackerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 每秒检测前台目标窗口
                } catch {
                    return
                }

                guard let self = self, let p = self.panel else { return }
                if let targetRect = CodexWindowTracker.findTargetWindowFrame() {
                    // 吸附在目标窗口右上角
                    let overlayX = targetRect.maxX - p.frame.width - 16
                    let overlayY = targetRect.maxY - p.frame.height - 16
                    let targetPoint = NSPoint(x: overlayX, y: overlayY)
                    p.setFrameOrigin(targetPoint)
                    if !p.isVisible { p.orderFront(nil) }
                }
            }
        }
    }
}

// MARK: - 目标应用窗口定位器
public enum CodexWindowTracker {
    public static let targetBundleIdentifiers: Set<String> = [
        "com.openai.chat",
        "com.openai.codex",
        "com.google.antigravity",
        "com.microsoft.VSCode",
        "com.apple.Terminal"
    ]

    public static func findTargetWindowFrame() -> NSRect? {
        guard let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in windowInfoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let ownerName = info[kCGWindowOwnerName as String] as? String else {
                continue
            }

            let isTarget = ownerName.localizedCaseInsensitiveContains("codex")
                || ownerName.localizedCaseInsensitiveContains("chatgpt")
                || ownerName.localizedCaseInsensitiveContains("antigravity")

            if isTarget {
                let x = boundsDict["X"] as? CGFloat ?? 0
                let y = boundsDict["Y"] as? CGFloat ?? 0
                let width = boundsDict["Width"] as? CGFloat ?? 0
                let height = boundsDict["Height"] as? CGFloat ?? 0

                // Quartz 坐标系转换为 AppKit 屏幕坐标系
                let mainScreenHeight = NSScreen.main?.frame.height ?? 1080
                let appKitY = mainScreenHeight - (y + height)
                return NSRect(x: x, y: appKitY, width: width, height: height)
            }
        }
        return nil
    }
}

// MARK: - 挂件 SwiftUI 视图
public struct CodexOverlayView: View {
    let onToggleExpand: () -> Void
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.colorScheme) var colorScheme

    public var body: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let isDark = colorScheme == .dark

        Button(action: onToggleExpand) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(cyan)
                        .frame(width: 8, height: 8)
                    Circle()
                        .fill(cyan.opacity(0.35))
                        .frame(width: 14, height: 14)
                }

                Text("Codex")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(cyan)

                Text(env.state.displayedQuotaPercentString)
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isDark ? Color.black.opacity(0.85) : Color.white.opacity(0.92),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(cyan.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.3), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }
}
