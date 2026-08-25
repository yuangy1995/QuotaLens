// QuotaLens 目标窗口悬浮挂件控制器与跟踪器 (CodexUsageOverlayController)
// 纯 AppKit 非激活浮动 Panel，贴靠 ChatGPT / Codex 窗口边缘，提供即时用量与额度浮窗

import SwiftUI
import AppKit
import ApplicationServices

public final class CodexUsageOverlayController: NSObject, ObservableObject, @unchecked Sendable {
    public static let shared = CodexUsageOverlayController()

    private var panel: NSPanel?
    private var trackerTask: Task<Void, Never>?
    private var isExpanded: Bool = false
    private var isUserPinned: Bool = false
    private var dragStartOrigin: NSPoint?
    private let edgeInset: CGFloat = 16
    @MainActor private weak var environment: AppEnvironment?
    @Published public private(set) var isAccessibilityTrusted: Bool = AXIsProcessTrusted()

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

        let initialSize = NSSize(width: 140, height: 34)
        let p = NSPanel(
            contentRect: NSRect(origin: Self.defaultEdgeOrigin(for: initialSize, inset: edgeInset), size: initialSize),
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
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false

        let overlayView = CodexOverlayView(onToggleExpand: { [weak self] expanded in
            self?.setExpanded(expanded)
        }, onDragChanged: { [weak self] translation in
            self?.handleDragChanged(translation)
        }, onDragEnded: { [weak self] translation in
            self?.handleDragEnded(translation)
        })
        .environmentObject(environment)
        p.contentView = NSHostingView(rootView: overlayView)
        p.orderFront(nil)
        self.panel = p

        startWindowTrackerLoop()
    }

    /// Precise mode is opt-in. Only a user action calls this API with `true`, so
    /// QuotaLens never prompts for Accessibility permission during launch.
    @MainActor
    public func setAXSnappingEnabled(_ enabled: Bool) {
        if enabled && !AXIsProcessTrusted() {
            // This is the documented value of kAXTrustedCheckOptionPrompt. A
            // literal avoids importing the mutable C global across an actor
            // boundary under Swift 6 strict concurrency.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            isAccessibilityTrusted = AXIsProcessTrustedWithOptions(options)
        } else {
            isAccessibilityTrusted = AXIsProcessTrusted()
        }
    }

    @MainActor
    public func stopTracking() {
        trackerTask?.cancel()
        trackerTask = nil
        panel?.close()
        panel = nil
    }

    @MainActor
    private func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        guard let p = panel else { return }

        let newSize = isExpanded ? NSSize(width: 240, height: 160) : NSSize(width: 140, height: 34)
        var frame = p.frame
        frame.size = newSize
        frame.origin = Self.constrainedOrigin(frame.origin, size: newSize, preferredScreen: Self.screen(for: frame), inset: edgeInset)
        applyFrame(frame, to: p, animate: true)
    }

    private func startWindowTrackerLoop() {
        trackerTask?.cancel()
        trackerTask = Task { @MainActor [weak self] in
            var nextPollNanoseconds: UInt64 = 0
            while !Task.isCancelled {
                if nextPollNanoseconds > 0 {
                    do {
                        try await Task.sleep(nanoseconds: nextPollNanoseconds)
                    } catch {
                        return
                    }
                }

                guard let self = self, let p = self.panel else { return }
                guard !self.isUserPinned else {
                    self.keepPanelVisible(p)
                    continue
                }

                let wantsPreciseSnapping = UsageFeatureFlags.shared.isAXSnappingEnabled
                let isTrusted = AXIsProcessTrusted()
                if self.isAccessibilityTrusted != isTrusted {
                    self.isAccessibilityTrusted = isTrusted
                }

                if let targetRect = CodexWindowTracker.findTargetWindowFrame(
                    preferAccessibility: wantsPreciseSnapping && isTrusted
                ) {
                    nextPollNanoseconds = wantsPreciseSnapping && isTrusted
                        ? 350_000_000
                        : 1_500_000_000
                    let screen = Self.screen(for: targetRect)
                    let targetPoint = NSPoint(
                        x: targetRect.maxX - p.frame.width - self.edgeInset,
                        y: targetRect.maxY - p.frame.height - self.edgeInset
                    )
                    self.applyOrigin(
                        Self.constrainedOrigin(targetPoint, size: p.frame.size, preferredScreen: screen, inset: self.edgeInset),
                        to: p,
                        animate: false
                    )
                    if !p.isVisible { p.orderFront(nil) }
                } else {
                    nextPollNanoseconds = 5_000_000_000
                    self.applyOrigin(Self.defaultEdgeOrigin(for: p.frame.size, inset: self.edgeInset), to: p, animate: false)
                }
            }
        }
    }

    @MainActor
    private func handleDragChanged(_ translation: CGSize) {
        guard let p = panel else { return }
        if dragStartOrigin == nil {
            dragStartOrigin = p.frame.origin
        }
        guard let start = dragStartOrigin else { return }
        isUserPinned = true
        let proposed = NSPoint(x: start.x + translation.width, y: start.y - translation.height)
        applyOrigin(
            Self.constrainedOrigin(proposed, size: p.frame.size, preferredScreen: Self.screen(for: p.frame), inset: edgeInset),
            to: p,
            animate: false
        )
    }

    @MainActor
    private func handleDragEnded(_ translation: CGSize) {
        guard let p = panel else { return }
        if let start = dragStartOrigin {
            let proposed = NSPoint(x: start.x + translation.width, y: start.y - translation.height)
            let screen = Self.screen(for: NSRect(origin: proposed, size: p.frame.size))
            let constrained = Self.constrainedOrigin(proposed, size: p.frame.size, preferredScreen: screen, inset: edgeInset)
            applyOrigin(Self.snappedEdgeOrigin(constrained, size: p.frame.size, screen: screen, inset: edgeInset), to: p, animate: true)
        } else {
            keepPanelVisible(p)
        }
        dragStartOrigin = nil
    }

    @MainActor
    private func keepPanelVisible(_ p: NSPanel) {
        let screen = Self.screen(for: p.frame)
        let origin = Self.constrainedOrigin(p.frame.origin, size: p.frame.size, preferredScreen: screen, inset: edgeInset)
        if abs(origin.x - p.frame.origin.x) > 0.5 || abs(origin.y - p.frame.origin.y) > 0.5 {
            applyOrigin(origin, to: p, animate: false)
        }
        if !p.isVisible {
            p.orderFront(nil)
        }
    }

    @MainActor
    private func applyOrigin(_ origin: NSPoint, to panel: NSPanel, animate: Bool) {
        var frame = panel.frame
        frame.origin = origin
        applyFrame(frame, to: panel, animate: animate)
    }

    @MainActor
    private func applyFrame(_ frame: NSRect, to panel: NSPanel, animate: Bool) {
        panel.setFrame(frame, display: true, animate: animate)
    }

    private static func defaultEdgeOrigin(for size: NSSize, inset: CGFloat) -> NSPoint {
        let screen = screen(containing: NSEvent.mouseLocation)
        return snappedEdgeOrigin(
            NSPoint(x: screen.visibleFrame.maxX - size.width - inset, y: screen.visibleFrame.maxY - size.height - inset),
            size: size,
            screen: screen,
            inset: inset
        )
    }

    private static func snappedEdgeOrigin(_ origin: NSPoint, size: NSSize, screen: NSScreen, inset: CGFloat) -> NSPoint {
        let visibleFrame = screen.visibleFrame
        let constrained = constrainedOrigin(origin, size: size, preferredScreen: screen, inset: inset)
        let leftX = visibleFrame.minX + inset
        let rightX = visibleFrame.maxX - size.width - inset
        let centerX = constrained.x + (size.width / 2)
        return NSPoint(x: centerX < visibleFrame.midX ? leftX : rightX, y: constrained.y)
    }

    private static func constrainedOrigin(_ origin: NSPoint, size: NSSize, preferredScreen: NSScreen, inset: CGFloat) -> NSPoint {
        let visibleFrame = preferredScreen.visibleFrame.insetBy(dx: inset, dy: inset)
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - size.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - size.height)
        return NSPoint(
            x: min(max(origin.x, visibleFrame.minX), maxX),
            y: min(max(origin.y, visibleFrame.minY), maxY)
        )
    }

    private static func screen(for rect: NSRect) -> NSScreen {
        var bestScreen: NSScreen?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let area = screen.frame.intersection(rect).area
            if area > bestArea {
                bestArea = area
                bestScreen = screen
            }
        }
        if let bestScreen {
            return bestScreen
        }
        return screen(containing: NSPoint(x: rect.midX, y: rect.midY))
    }

    private static func screen(containing point: NSPoint) -> NSScreen {
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            return screen
        }
        if let main = NSScreen.main {
            return main
        }
        guard let firstScreen = NSScreen.screens.first else {
            preconditionFailure("QuotaLens overlay requires at least one screen")
        }
        return firstScreen
    }
}

// MARK: - 目标应用窗口定位器
public enum CodexWindowTracker {
    public static let targetBundleIdentifiers: Set<String> = [
        "com.openai.chat",
        "com.openai.codex",
        "com.google.antigravity",
        "com.microsoft.VSCode",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty"
    ]
    private static let directTargetBundleIdentifiers: Set<String> = [
        "com.openai.chat",
        "com.openai.codex",
        "com.google.antigravity"
    ]
    private static let hostedTargetBundleIdentifiers: Set<String> = targetBundleIdentifiers.subtracting(directTargetBundleIdentifiers)
    private static let targetKeywords = ["codex", "chatgpt", "antigravity"]

    public static func findTargetWindowFrame(preferAccessibility: Bool = false) -> NSRect? {
        if preferAccessibility, let frame = findAccessibleTargetWindowFrame() {
            return frame
        }

        guard let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in windowInfoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let ownerName = info[kCGWindowOwnerName as String] as? String else {
                continue
            }

            let windowName = info[kCGWindowName as String] as? String
            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber).map { pid_t($0.intValue) }
            let bundleIdentifier = ownerPID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
            let isTarget = isTargetWindow(ownerName: ownerName, windowName: windowName, bundleIdentifier: bundleIdentifier)

            if isTarget {
                let x = cgFloat(boundsDict["X"]) ?? 0
                let y = cgFloat(boundsDict["Y"]) ?? 0
                let width = cgFloat(boundsDict["Width"]) ?? 0
                let height = cgFloat(boundsDict["Height"]) ?? 0

                let quartzRect = NSRect(x: x, y: y, width: width, height: height)
                return appKitRect(fromQuartz: quartzRect)
            }
        }
        return nil
    }

    /// Reads only AX position, size, and minimized state for a direct target
    /// application. Hosted apps still use the privacy-preserving basic matcher.
    private static func findAccessibleTargetWindowFrame() -> NSRect? {
        guard AXIsProcessTrusted(),
              let frontmost = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = frontmost.bundleIdentifier,
              directTargetBundleIdentifiers.contains(bundleIdentifier),
              !frontmost.isHidden else {
            return nil
        }

        let application = AXUIElementCreateApplication(frontmost.processIdentifier)
        guard let window = accessibilityWindow(
            application: application,
            attribute: kAXFocusedWindowAttribute as CFString
        ) ?? accessibilityWindow(
            application: application,
            attribute: kAXMainWindowAttribute as CFString
        ), !isAccessibilityWindowMinimized(window),
        let quartzFrame = accessibilityFrame(of: window),
        quartzFrame.width > 1,
        quartzFrame.height > 1 else {
            return nil
        }
        return appKitRect(fromQuartz: quartzFrame)
    }

    private static func accessibilityWindow(application: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func accessibilityFrame(of window: AXUIElement) -> NSRect? {
        var positionReference: CFTypeRef?
        var sizeReference: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionReference) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeReference) == .success,
              let positionReference,
              let sizeReference,
              CFGetTypeID(positionReference) == AXValueGetTypeID(),
              CFGetTypeID(sizeReference) == AXValueGetTypeID() else {
            return nil
        }

        let positionValue = unsafeDowncast(positionReference, to: AXValue.self)
        let sizeValue = unsafeDowncast(sizeReference, to: AXValue.self)
        guard AXValueGetType(positionValue) == .cgPoint,
              AXValueGetType(sizeValue) == .cgSize else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return NSRect(origin: point, size: size)
    }

    private static func isAccessibilityWindowMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return false
        }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }

    private static func isTargetWindow(ownerName: String, windowName: String?, bundleIdentifier: String?) -> Bool {
        if let bundleIdentifier, directTargetBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }
        let searchableText = [ownerName, windowName].compactMap { $0 }.joined(separator: " ")
        let hasTargetKeyword = targetKeywords.contains { searchableText.localizedCaseInsensitiveContains($0) }
        if let bundleIdentifier, hostedTargetBundleIdentifiers.contains(bundleIdentifier) {
            return hasTargetKeyword
        }
        return hasTargetKeyword
    }

    private static func appKitRect(fromQuartz quartzRect: NSRect) -> NSRect {
        var best: (screen: NSScreen, quartzBounds: CGRect, area: CGFloat)?
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let quartzBounds = CGDisplayBounds(displayID)
            let area = quartzBounds.intersection(quartzRect).area
            if best == nil || area > (best?.area ?? 0) {
                best = (screen, quartzBounds, area)
            }
        }
        guard let best else {
            let mainMaxY = NSScreen.main?.frame.maxY ?? 900
            return NSRect(
                x: quartzRect.minX,
                y: mainMaxY - quartzRect.maxY,
                width: quartzRect.width,
                height: quartzRect.height
            )
        }
        let x = best.screen.frame.minX + (quartzRect.minX - best.quartzBounds.minX)
        let yFromTop = quartzRect.minY - best.quartzBounds.minY
        let y = best.screen.frame.maxY - yFromTop - quartzRect.height
        return NSRect(x: x, y: y, width: quartzRect.width, height: quartzRect.height)
    }

    private static func cgFloat(_ value: Any?) -> CGFloat? {
        if let number = value as? NSNumber {
            return CGFloat(truncating: number)
        }
        if let value = value as? CGFloat {
            return value
        }
        if let value = value as? Double {
            return CGFloat(value)
        }
        if let value = value as? Int {
            return CGFloat(value)
        }
        return nil
    }
}

// MARK: - 挂件 SwiftUI 视图
public struct CodexOverlayView: View {
    let onToggleExpand: (Bool) -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize) -> Void
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.colorScheme) var colorScheme
    @State private var isExpanded = false
    @ObservedObject private var flags = UsageFeatureFlags.shared
    @ObservedObject private var overlayController = CodexUsageOverlayController.shared

    public var body: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let isDark = colorScheme == .dark

        VStack(alignment: .leading, spacing: isExpanded ? 9 : 0) {
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

                Spacer(minLength: 4)

                Text(env.state.displayedQuotaPercentString)
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                isExpanded.toggle()
                onToggleExpand(isExpanded)
            }

            if isExpanded {
                Divider().opacity(0.35)

                overlayDetailRow(
                    title: env.state.quotaDisplayMode.pickerTitle,
                    value: env.state.displayedQuotaPercentString,
                    color: env.state.quotaSeverityColor
                )
                overlayDetailRow(
                    title: L10n.text("距离重置", "Until reset"),
                    value: env.state.resetCountdownString,
                    color: cyan
                )
                overlayDetailRow(
                    title: L10n.text("订阅", "Plan"),
                    value: env.state.subscriptionPlanTitle,
                    color: AppTheme.accentPurple(for: colorScheme)
                )
                Text(overlayModeDescription)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isDark ? Color.black.opacity(0.85) : Color.white.opacity(0.92),
            in: RoundedRectangle(cornerRadius: isExpanded ? 12 : 17, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: isExpanded ? 12 : 17, style: .continuous)
                .strokeBorder(cyan.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 6, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: isExpanded ? 12 : 17, style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { onDragChanged($0.translation) }
                .onEnded { onDragEnded($0.translation) }
        )
    }

    private var overlayModeDescription: String {
        if flags.isAXSnappingEnabled && overlayController.isAccessibilityTrusted {
            return L10n.text("精确模式 · 只读取位置与尺寸", "Precise mode · Position and size only")
        }
        return L10n.text("基础模式 · 不读取窗口文本", "Basic mode · No window text access")
    }

    private func overlayDetailRow(title: String, value: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            Spacer()
            Text(value)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}

private extension NSRect {
    var area: CGFloat {
        guard !isNull && !isEmpty else { return 0 }
        return width * height
    }
}
