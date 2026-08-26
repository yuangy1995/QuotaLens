// QuotaLens 目标窗口悬浮挂件控制器与跟踪器 (CodexUsageOverlayController)
// 纯 AppKit 非激活浮动 Panel，贴靠 ChatGPT / Codex 窗口边缘，提供即时用量与额度浮窗

import SwiftUI
import AppKit
import ApplicationServices

public final class CodexUsageOverlayController: NSObject, ObservableObject, @unchecked Sendable {
    public static let shared = CodexUsageOverlayController()

    private static let overlayExpandedDefaultsKey = "QuotaLens.Overlay.IsExpanded"
    private static let overlayPinnedDefaultsKey = "QuotaLens.Overlay.IsUserPinned"
    private static let overlayOriginXDefaultsKey = "QuotaLens.Overlay.OriginX"
    private static let overlayOriginYDefaultsKey = "QuotaLens.Overlay.OriginY"

    private var panel: NSPanel?
    private var trackerTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    public private(set) var isExpanded: Bool = false
    private var isUserPinned: Bool = false
    private var isDragging: Bool = false
    private var dragStartMouseLocation: NSPoint?
    private var dragStartOrigin: NSPoint?
    private let edgeInset: CGFloat = 16
    private let shadowMargin: CGFloat = 10
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

        let savedExpanded = UserDefaults.standard.bool(forKey: Self.overlayExpandedDefaultsKey)
        self.isExpanded = savedExpanded

        let contentSize = savedExpanded ? NSSize(width: 256, height: 196) : NSSize(width: 162, height: 34)
        let initialSize = NSSize(
            width: contentSize.width + shadowMargin * 2,
            height: contentSize.height + shadowMargin * 2
        )

        let isPinned = UserDefaults.standard.bool(forKey: Self.overlayPinnedDefaultsKey)
        let initialOrigin: NSPoint
        if isPinned,
           UserDefaults.standard.object(forKey: Self.overlayOriginXDefaultsKey) != nil,
           UserDefaults.standard.object(forKey: Self.overlayOriginYDefaultsKey) != nil {
            let x = CGFloat(UserDefaults.standard.double(forKey: Self.overlayOriginXDefaultsKey))
            let y = CGFloat(UserDefaults.standard.double(forKey: Self.overlayOriginYDefaultsKey))
            let proposed = NSPoint(x: x, y: y)
            let screen = Self.screen(for: NSRect(origin: proposed, size: initialSize))
            initialOrigin = Self.constrainedOrigin(proposed, size: initialSize, preferredScreen: screen, inset: edgeInset)
            self.isUserPinned = true
        } else {
            initialOrigin = Self.defaultEdgeOrigin(for: initialSize, inset: edgeInset)
            self.isUserPinned = false
        }

        let p = NSPanel(
            contentRect: NSRect(origin: initialOrigin, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isFloatingPanel = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false

        let overlayView = CodexOverlayView(
            state: environment.state,
            isExpanded: savedExpanded,
            onToggleExpand: { [weak self] expanded in
                self?.setExpanded(expanded)
            },
            onDragChanged: { [weak self] in
                self?.handleDragChanged()
            },
            onDragEnded: { [weak self] in
                self?.handleDragEnded()
            }
        )
        .environmentObject(environment)
        p.contentView = NSHostingView(rootView: overlayView)

        self.panel = p

        setupWorkspaceObservers()
        updateVisibilityForFrontmostApp()
        startWindowTrackerLoop()
    }

    /// Precise mode is opt-in. Only a user action calls this API with `true`, so
    /// QuotaLens never prompts for Accessibility permission during launch.
    @MainActor
    public func setAXSnappingEnabled(_ enabled: Bool) {
        if enabled && !AXIsProcessTrusted() {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            isAccessibilityTrusted = AXIsProcessTrustedWithOptions(options)
        } else {
            isAccessibilityTrusted = AXIsProcessTrusted()
        }
    }

    @MainActor
    public func resetPinning() {
        isUserPinned = false
        UserDefaults.standard.removeObject(forKey: Self.overlayPinnedDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.overlayOriginXDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.overlayOriginYDefaultsKey)
        if let p = panel {
            let initialOrigin = Self.defaultEdgeOrigin(for: p.frame.size, inset: edgeInset)
            applyOrigin(initialOrigin, to: p, animate: true)
        }
    }

    @MainActor
    public func stopTracking() {
        trackerTask?.cancel()
        trackerTask = nil

        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        panel?.close()
        panel = nil
    }

    @MainActor
    private func setupWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        let obs1 = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let activatedApp = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                self?.updateVisibilityForFrontmostApp(activeApp: activatedApp)
            }
        }
        let obs2 = center.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateVisibilityForFrontmostApp(activeApp: nil)
            }
        }
        workspaceObservers = [obs1, obs2]
    }

    @MainActor
    public func updateVisibilityForFrontmostApp(activeApp: NSRunningApplication? = nil) {
        guard let p = panel, UsageFeatureFlags.shared.isOverlayEnabled else { return }
        if isDragging { return }

        let currentApp = activeApp ?? NSWorkspace.shared.frontmostApplication
        let shouldShow: Bool
        if UsageFeatureFlags.shared.isOverlayOnlyWhenActive {
            guard let currentApp else { return }
            shouldShow = currentApp.processIdentifier == ProcessInfo.processInfo.processIdentifier || CodexWindowTracker.isTargetApplication(currentApp)
        } else {
            shouldShow = true
        }

        if shouldShow {
            if !p.isVisible {
                p.orderFront(nil)
            }
        } else {
            if p.isVisible {
                p.orderOut(nil)
            }
        }
    }

    private func isTargetForeground() -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return false
        }
        if frontmost.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return true
        }
        return CodexWindowTracker.isTargetApplication(frontmost)
    }

    @MainActor
    private func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        UserDefaults.standard.set(expanded, forKey: Self.overlayExpandedDefaultsKey)
        guard let p = panel else { return }

        let contentSize = expanded ? NSSize(width: 256, height: 196) : NSSize(width: 162, height: 34)
        let newSize = NSSize(
            width: contentSize.width + shadowMargin * 2,
            height: contentSize.height + shadowMargin * 2
        )

        var frame = p.frame
        let heightDiff = newSize.height - frame.height
        frame.origin.y -= heightDiff
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

                if self.isDragging {
                    nextPollNanoseconds = 100_000_000
                    continue
                }

                let isForeground = self.isTargetForeground()
                let onlyWhenActive = UsageFeatureFlags.shared.isOverlayOnlyWhenActive

                if onlyWhenActive && !isForeground {
                    if p.isVisible {
                        p.orderOut(nil)
                    }
                    nextPollNanoseconds = 800_000_000
                    continue
                } else {
                    if !p.isVisible {
                        p.orderFront(nil)
                    }
                }

                guard !self.isUserPinned else {
                    self.keepPanelVisible(p)
                    nextPollNanoseconds = 2_000_000_000
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
                } else {
                    nextPollNanoseconds = 3_000_000_000
                    self.applyOrigin(Self.defaultEdgeOrigin(for: p.frame.size, inset: self.edgeInset), to: p, animate: false)
                }
            }
        }
    }

    @MainActor
    private func handleDragChanged() {
        guard let p = panel else { return }
        isDragging = true
        isUserPinned = true

        let currentMouse = NSEvent.mouseLocation
        if dragStartMouseLocation == nil {
            dragStartMouseLocation = currentMouse
            dragStartOrigin = p.frame.origin
        }
        guard let startMouse = dragStartMouseLocation, let startOrigin = dragStartOrigin else { return }

        let deltaX = currentMouse.x - startMouse.x
        let deltaY = currentMouse.y - startMouse.y
        let proposed = NSPoint(x: startOrigin.x + deltaX, y: startOrigin.y + deltaY)
        let screen = Self.screen(for: NSRect(origin: proposed, size: p.frame.size))
        let constrained = Self.constrainedOrigin(proposed, size: p.frame.size, preferredScreen: screen, inset: edgeInset)
        p.setFrameOrigin(constrained)
    }

    @MainActor
    private func handleDragEnded() {
        guard let p = panel else {
            isDragging = false
            dragStartMouseLocation = nil
            dragStartOrigin = nil
            return
        }

        let currentMouse = NSEvent.mouseLocation
        if let startMouse = dragStartMouseLocation, let startOrigin = dragStartOrigin {
            let deltaX = currentMouse.x - startMouse.x
            let deltaY = currentMouse.y - startMouse.y
            let proposed = NSPoint(x: startOrigin.x + deltaX, y: startOrigin.y + deltaY)
            let screen = Self.screen(for: NSRect(origin: proposed, size: p.frame.size))
            let snapped = Self.softSnappedOrigin(proposed, size: p.frame.size, screen: screen, inset: edgeInset)
            applyOrigin(snapped, to: p, animate: true)

            UserDefaults.standard.set(true, forKey: Self.overlayPinnedDefaultsKey)
            UserDefaults.standard.set(Double(snapped.x), forKey: Self.overlayOriginXDefaultsKey)
            UserDefaults.standard.set(Double(snapped.y), forKey: Self.overlayOriginYDefaultsKey)
        }
        isDragging = false
        dragStartMouseLocation = nil
        dragStartOrigin = nil
    }

    @MainActor
    private func keepPanelVisible(_ p: NSPanel) {
        let screen = Self.screen(for: p.frame)
        let origin = Self.constrainedOrigin(p.frame.origin, size: p.frame.size, preferredScreen: screen, inset: edgeInset)
        if abs(origin.x - p.frame.origin.x) > 0.5 || abs(origin.y - p.frame.origin.y) > 0.5 {
            applyOrigin(origin, to: p, animate: false)
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
        let visibleFrame = screen.visibleFrame
        return NSPoint(
            x: visibleFrame.maxX - size.width - inset,
            y: visibleFrame.maxY - size.height - inset
        )
    }

    private static func softSnappedOrigin(_ origin: NSPoint, size: NSSize, screen: NSScreen, inset: CGFloat) -> NSPoint {
        let visibleFrame = screen.visibleFrame.insetBy(dx: inset, dy: inset)
        let constrained = constrainedOrigin(origin, size: size, preferredScreen: screen, inset: inset)
        let snapThreshold: CGFloat = 28

        var resultX = constrained.x
        var resultY = constrained.y

        if abs(constrained.x - visibleFrame.minX) < snapThreshold {
            resultX = visibleFrame.minX
        } else if abs(constrained.x - (visibleFrame.maxX - size.width)) < snapThreshold {
            resultX = visibleFrame.maxX - size.width
        }

        if abs(constrained.y - (visibleFrame.maxY - size.height)) < snapThreshold {
            resultY = visibleFrame.maxY - size.height
        } else if abs(constrained.y - visibleFrame.minY) < snapThreshold {
            resultY = visibleFrame.minY
        }

        return NSPoint(x: resultX, y: resultY)
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

// MARK: - 目标应用窗口定位器 (专注于 ChatGPT / Codex 客户端)
public enum CodexWindowTracker {
    public static let targetBundleIdentifiers: Set<String> = [
        "com.openai.chat",
        "com.openai.codex",
        "com.openai.chatgpt",
        "com.openai.chat.standalone",
        "com.google.antigravity"
    ]
    private static let directTargetBundleIdentifiers: Set<String> = targetBundleIdentifiers
    public static let targetKeywords = ["codex", "chatgpt", "openai", "antigravity"]

    public static func isTargetApplication(_ app: NSRunningApplication) -> Bool {
        if let bundleID = app.bundleIdentifier?.lowercased() {
            if targetBundleIdentifiers.contains(where: { bundleID.caseInsensitiveCompare($0) == .orderedSame }) {
                return true
            }
            if bundleID.contains("openai") || bundleID.contains("chatgpt") || bundleID.contains("codex") {
                return true
            }
        }
        let localizedName = (app.localizedName ?? "").lowercased()
        if targetKeywords.contains(where: { localizedName.contains($0) }) {
            return true
        }
        return false
    }

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

    private static func findAccessibleTargetWindowFrame() -> NSRect? {
        guard AXIsProcessTrusted(),
              let frontmost = NSWorkspace.shared.frontmostApplication,
              isTargetApplication(frontmost),
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
        if let bundleIdentifier, targetBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }
        let searchableText = [ownerName, windowName].compactMap { $0 }.joined(separator: " ").lowercased()
        return targetKeywords.contains { searchableText.contains($0) }
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

// MARK: - 挂件 SwiftUI 视图 (纯净极简科技风 HUD)
public struct CodexOverlayView: View {
    let onToggleExpand: (Bool) -> Void
    let onDragChanged: () -> Void
    let onDragEnded: () -> Void
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) var colorScheme
    @State private var isExpanded: Bool
    @State private var isPulsing = false
    @ObservedObject private var flags = UsageFeatureFlags.shared
    @ObservedObject private var overlayController = CodexUsageOverlayController.shared

    public init(
        state: AppState,
        isExpanded: Bool = false,
        onToggleExpand: @escaping (Bool) -> Void,
        onDragChanged: @escaping () -> Void,
        onDragEnded: @escaping () -> Void
    ) {
        self.state = state
        self._isExpanded = State(initialValue: isExpanded)
        self.onToggleExpand = onToggleExpand
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
    }

    public var body: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let purple = AppTheme.accentPurple(for: colorScheme)
        let amber = AppTheme.accentAmber(for: colorScheme)
        let isDark = colorScheme == .dark
        let statusColor = state.quotaSeverityColor

        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: isExpanded ? 9 : 0) {
                // MARK: 顶部 / 收起状态栏 (纯净无内嵌胶囊排版，绝不截断)
                HStack(spacing: 6) {
                    // 左侧：发光指示器 + 品牌文字
                    HStack(spacing: 5) {
                        ZStack {
                            Circle()
                                .fill(statusColor.opacity(isPulsing ? 0.35 : 0.18))
                                .frame(width: 12, height: 12)
                                .scaleEffect(isPulsing ? 1.15 : 0.9)
                            Circle()
                                .fill(statusColor)
                                .frame(width: 6, height: 6)
                                .shadow(color: statusColor.opacity(0.8), radius: 2)
                        }

                        Text("Codex")
                            .font(.system(size: 11, weight: .black, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [cyan, isDark ? Color.white : cyan],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .fixedSize()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        toggleExpanded()
                    }

                    // 中间单弹性分隔：把品牌与右侧视角/折叠按钮自然拉开
                    Spacer(minLength: 8)

                    // 右侧区域：视角模式与百分比 + 展开箭头紧凑并排
                    HStack(spacing: 6) {
                        Button(action: {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                                state.toggleQuotaDisplayMode()
                            }
                        }) {
                            HStack(spacing: 3.5) {
                                Text(state.quotaDisplayMode.shortTitle)
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                                    .fixedSize()

                                Text(state.displayedQuotaPercentString)
                                    .font(.system(size: 11.5, weight: .heavy, design: .monospaced))
                                    .foregroundStyle(statusColor)
                                    .monospacedDigit()
                                    .fixedSize()
                            }
                        }
                        .buttonStyle(.plain)
                        .help(L10n.text("点击切换已用/可用视角", "Click to toggle used/available view"))

                        // 展开 / 收起箭头
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8.5, weight: .black))
                            .foregroundStyle(cyan)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                toggleExpanded()
                            }
                    }
                }

                // MARK: 展开后详情卡片区域
                if isExpanded {
                    Divider()
                        .opacity(isDark ? 0.25 : 0.4)

                    // 霓虹微型渐变进度条 (随用量/可用比例即时动态平滑延伸)
                    VStack(alignment: .leading, spacing: 3) {
                        GeometryReader { proxy in
                            let trackWidth = proxy.size.width
                            let progress = min(max(state.displayedQuotaProgress, 0.0), 1.0)
                            let fillWidth = max(5, trackWidth * CGFloat(progress))

                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.08))
                                    .frame(height: 4)

                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [cyan, statusColor],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: fillWidth, height: 4)
                                    .shadow(color: statusColor.opacity(0.5), radius: 2)
                                    .animation(.spring(response: 0.35, dampingFraction: 0.78), value: state.displayedQuotaProgress)
                            }
                        }
                        .frame(height: 4)
                    }
                    .padding(.vertical, 2)

                    // 核心指标行 (去除内部嵌套框，保持整洁)
                    VStack(spacing: 5) {
                        overlayDetailRow(
                            icon: "gauge.with.dots.needle.bottom.50percent",
                            iconColor: statusColor,
                            title: state.quotaDisplayMode.pickerTitle,
                            value: state.displayedQuotaPercentString,
                            valueColor: statusColor
                        )

                        overlayDetailRow(
                            icon: "hourglass",
                            iconColor: cyan,
                            title: L10n.text("距离重置", "Until reset"),
                            value: state.resetCountdownString,
                            valueColor: cyan
                        )

                        overlayDetailRow(
                            icon: "crown.fill",
                            iconColor: purple,
                            title: L10n.text("订阅计划", "Plan"),
                            value: state.subscriptionPlanTitle.uppercased(),
                            valueColor: purple
                        )

                        overlayDetailRow(
                            icon: "ticket.fill",
                            iconColor: amber,
                            title: L10n.text("重置卡储备", "Reset Cards"),
                            value: L10n.format("%d available", zhHans: "%d 张可用", state.resetCreditAvailableCount),
                            valueColor: state.resetCreditAvailableCount > 0 ? amber : AppTheme.textSecondary(for: colorScheme)
                        )
                    }

                    // 底部极简模式说明
                    HStack(spacing: 4) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 8))
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        Text(overlayModeDescription)
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        Spacer()
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, isExpanded ? 12 : 10)
            .padding(.vertical, isExpanded ? 10 : 6)
            .background(
                isDark ? Color(red: 0.08, green: 0.10, blue: 0.16).opacity(0.92) : Color.white.opacity(0.95),
                in: RoundedRectangle(cornerRadius: isExpanded ? 14 : 18, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: isExpanded ? 14 : 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                cyan.opacity(isDark ? 0.6 : 0.45),
                                purple.opacity(isDark ? 0.35 : 0.25),
                                cyan.opacity(isDark ? 0.45 : 0.35)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(isDark ? 0.45 : 0.20), radius: 6, x: 0, y: 2)
            .padding(10)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { _ in onDragChanged() }
                    .onEnded { _ in onDragEnded() }
            )
            .onAppear {
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
        }
    }

    private func toggleExpanded() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            isExpanded.toggle()
        }
        onToggleExpand(isExpanded)
    }

    private var overlayModeDescription: String {
        if flags.isAXSnappingEnabled && overlayController.isAccessibilityTrusted {
            return L10n.text("精确贴边 · 只读取尺寸", "Precise mode · Window attached")
        }
        return L10n.text("基础模式 · 保护隐私", "Basic mode · Privacy preserved")
    }

    private func overlayDetailRow(
        icon: String,
        iconColor: Color,
        title: String,
        value: String,
        valueColor: Color
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(iconColor)
                .frame(width: 14)

            Text(title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                .fixedSize()

            Spacer()

            Text(value)
                .font(.system(size: 10.5, weight: .heavy, design: .monospaced))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .monospacedDigit()
                .fixedSize()
        }
    }
}

private extension NSRect {
    var area: CGFloat {
        guard !isNull && !isEmpty else { return 0 }
        return width * height
    }
}


