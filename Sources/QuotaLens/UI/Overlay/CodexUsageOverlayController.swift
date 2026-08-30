// QuotaLens 目标窗口悬浮挂件控制器与跟踪器 (CodexUsageOverlayController)
// 纯 AppKit 非激活 Panel，贴靠 Codex 窗口，提供即时用量与额度浮窗

import SwiftUI
import AppKit
import ApplicationServices

public final class CodexUsageOverlayController: NSObject, ObservableObject, @unchecked Sendable {
    public static let shared = CodexUsageOverlayController()

    private static let overlayExpandedDefaultsKey = "QuotaLens.Overlay.IsExpanded"
    private static let overlayPositionXDefaultsKey = "QuotaLens.Overlay.RelativeX"
    private static let overlayPositionYDefaultsKey = "QuotaLens.Overlay.RelativeY"
    private static let legacyPinnedDefaultsKey = "QuotaLens.Overlay.IsUserPinned"
    private static let legacyOriginXDefaultsKey = "QuotaLens.Overlay.OriginX"
    private static let legacyOriginYDefaultsKey = "QuotaLens.Overlay.OriginY"

    private var panel: NSPanel?
    private var detailsPanel: NSPanel?
    private var recoveryPresenter: WeeklyQuotaRecoveryOverlayPresenter?
    private var trackerTask: Task<Void, Never>?
    private var helpAnchorTask: Task<Void, Never>?
    private var detailsCloseTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    public private(set) var isExpanded: Bool = false
    private var manualPosition: CodexOverlayRelativePosition?
    private var isDragging: Bool = false
    private var isSummaryHovered = false
    private var isDetailsHovered = false
    private var dragStartMouseLocation: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var trackedWindowID: CGWindowID?
    private var trackedProcessID: pid_t?
    private var trackedAppKitFrame: CGRect?
    private var helpAnchor: CodexHelpAnchor?
    private var helpAnchorGeneration = 0
    private var helpAnchorFailures = 0
    private var helpAnchorNextAttempt: Date?
    private var helpAnchorWindowID: CGWindowID?
    private var helpAnchorProcessID: pid_t?
    private var helpAnchorWindowSize: CGSize?
    private var lastFocusState: FocusState = .hidden
    private let edgeInset: CGFloat = 16
    private let shadowMargin: CGFloat = 10
    @MainActor private weak var environment: AppEnvironment?
    @Published public private(set) var isAccessibilityTrusted: Bool = AXIsProcessTrusted()
    @Published public private(set) var isOverlayVisible = false

    private enum FocusState: Equatable {
        case codex(pid_t)
        case hidden
    }

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

        loadManualPosition()
        let initialOrigin = Self.defaultEdgeOrigin(for: initialSize, inset: edgeInset)

        let p = NSPanel(
            contentRect: NSRect(origin: initialOrigin, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .normal
        p.isFloatingPanel = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.acceptsMouseMovedEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false

        let overlayView = CodexOverlayView(
            state: environment.state,
            isExpanded: savedExpanded,
            onToggleExpand: { [weak self] expanded, persist in
                self?.setExpanded(expanded, persist: persist)
            },
            onHoverChanged: { [weak self] hovering in
                self?.summaryHoverChanged(hovering)
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
        self.recoveryPresenter = WeeklyQuotaRecoveryOverlayPresenter(
            state: environment.state,
            tool: .codex,
            onAcknowledge: { [weak self] in
                self?.acknowledgeWeeklyQuotaRecovery()
            }
        )

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
        resetHelpAnchor(clearAnchor: true)
    }

    @MainActor
    public func resetPinning() {
        manualPosition = nil
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.overlayPositionXDefaultsKey)
        defaults.removeObject(forKey: Self.overlayPositionYDefaultsKey)
        removeLegacyPositionDefaults()
        if let panel, let trackedAppKitFrame {
            let frame = positionedFrame(
                panelSize: panel.frame.size,
                in: trackedAppKitFrame
            )
            applyFrame(frame, to: panel, animate: true)
        }
    }

    @MainActor
    public func stopTracking() {
        trackerTask?.cancel()
        trackerTask = nil
        resetHelpAnchor(clearAnchor: true)

        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }

        isSummaryHovered = false
        isOverlayVisible = false
        panel?.close()
        panel = nil
        recoveryPresenter?.close()
        recoveryPresenter = nil
        closeDetails()
        detailsPanel?.close()
        detailsPanel = nil
        trackedWindowID = nil
        trackedProcessID = nil
        trackedAppKitFrame = nil
    }

    @MainActor
    private func setupWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        let names: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didWakeNotification
        ]
        workspaceObservers = names.map { name in
            center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateVisibilityForFrontmostApp()
                }
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateVisibilityForFrontmostApp()
            }
        }
    }

    @MainActor
    public func updateVisibilityForFrontmostApp() {
        guard let p = panel else { return }
        if isDragging {
            recoveryPresenter?.hide()
            return
        }
        _ = refreshTrackedWindow(panel: p)
    }

    @MainActor
    private func focusState(for application: NSRunningApplication?) -> FocusState {
        _ = application
        guard environment?.frontmostToolTracker.foregroundTool == .codex,
              let processID = environment?.frontmostToolTracker.foregroundApplicationPID else {
            return .hidden
        }
        return .codex(processID)
    }

    @MainActor
    private func setExpanded(_ expanded: Bool, persist: Bool) {
        isExpanded = expanded
        if expanded {
            closeDetails()
        }
        if persist {
            UserDefaults.standard.set(expanded, forKey: Self.overlayExpandedDefaultsKey)
        }
        guard let p = panel else { return }

        let contentSize = expanded ? NSSize(width: 256, height: 196) : NSSize(width: 162, height: 34)
        let newSize = NSSize(
            width: contentSize.width + shadowMargin * 2,
            height: contentSize.height + shadowMargin * 2
        )

        let frame: CGRect
        if let trackedAppKitFrame {
            frame = positionedFrame(panelSize: newSize, in: trackedAppKitFrame)
        } else {
            var fallbackFrame = p.frame
            let heightDiff = newSize.height - fallbackFrame.height
            fallbackFrame.origin.y -= heightDiff
            fallbackFrame.size = newSize
            fallbackFrame.origin = Self.constrainedOrigin(
                fallbackFrame.origin,
                size: newSize,
                preferredScreen: Self.screen(for: fallbackFrame),
                inset: edgeInset
            )
            frame = fallbackFrame
        }
        applyFrame(frame, to: p, animate: true)
    }

    @MainActor
    private func summaryHoverChanged(_ hovering: Bool) {
        isSummaryHovered = hovering
        guard !isDragging else { return }
        if hovering, !isExpanded {
            if recoveryPresenter?.hasVisibleItems == true {
                closeDetails()
            } else {
                showDetails()
            }
        } else if !hovering {
            scheduleDetailsClose()
        }
    }

    @MainActor
    private func detailsHoverChanged(_ hovering: Bool) {
        guard !isDragging else {
            isDetailsHovered = false
            return
        }
        isDetailsHovered = hovering
        if hovering {
            detailsCloseTask?.cancel()
            detailsCloseTask = nil
        } else {
            scheduleDetailsClose()
        }
    }

    @MainActor
    private func showDetails() {
        detailsCloseTask?.cancel()
        detailsCloseTask = nil
        guard !isDragging,
              !isExpanded,
              panel?.isVisible == true,
              let trackedAppKitFrame else { return }
        switch lastFocusState {
        case .codex:
            break
        case .hidden:
            return
        }

        let details: NSPanel
        if let detailsPanel {
            details = detailsPanel
        } else {
            guard let created = makeDetailsPanel() else { return }
            details = created
        }
        updateDetailsPanelFrame(in: trackedAppKitFrame)
        details.ignoresMouseEvents = false
        if !details.isVisible {
            details.orderFrontRegardless()
        }
    }

    @MainActor
    private func scheduleDetailsClose() {
        detailsCloseTask?.cancel()
        detailsCloseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled,
                  let self,
                  !self.isSummaryHovered,
                  !self.isDetailsHovered else { return }
            self.closeDetails()
        }
    }

    @MainActor
    private func closeDetails() {
        detailsCloseTask?.cancel()
        detailsCloseTask = nil
        isDetailsHovered = false
        detailsPanel?.orderOut(nil)
    }

    @MainActor
    private func makeDetailsPanel() -> NSPanel? {
        guard let state = environment?.state else { return nil }
        let size = NSSize(width: 276, height: 184)
        let details = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        details.level = .normal
        details.isFloatingPanel = false
        details.isOpaque = false
        details.backgroundColor = .clear
        details.hasShadow = false
        details.acceptsMouseMovedEvents = true
        details.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        details.isMovableByWindowBackground = false
        details.hidesOnDeactivate = false
        details.contentView = NSHostingView(
            rootView: CodexOverlayHoverDetailsView(
                state: state,
                onHoverChanged: { [weak self] hovering in
                    self?.detailsHoverChanged(hovering)
                }
            )
        )
        detailsPanel = details
        return details
    }

    @MainActor
    private func updateDetailsPanelFrame(in codexWindow: CGRect) {
        guard let summaryFrame = panel?.frame,
              let detailsPanel else { return }
        let gap: CGFloat = 0
        let preferred = CGRect(
            x: summaryFrame.minX,
            y: summaryFrame.maxY + gap,
            width: detailsPanel.frame.width,
            height: detailsPanel.frame.height
        )
        let frame: CGRect
        if preferred.maxY <= codexWindow.maxY {
            frame = CodexOverlayLayout.clampedFrame(preferred, in: codexWindow)
        } else {
            frame = CodexOverlayLayout.clampedFrame(
                CGRect(
                    x: summaryFrame.minX,
                    y: summaryFrame.minY - gap - detailsPanel.frame.height,
                    width: detailsPanel.frame.width,
                    height: detailsPanel.frame.height
                ),
                in: codexWindow
            )
        }
        if detailsPanel.frame != frame {
            detailsPanel.setFrame(frame, display: detailsPanel.isVisible, animate: false)
        }
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
                nextPollNanoseconds = self.refreshTrackedWindow(panel: p)
            }
        }
    }

    @MainActor
    private func refreshTrackedWindow(panel: NSPanel) -> UInt64 {
        let focus = focusState(for: NSWorkspace.shared.frontmostApplication)
        let focusChanged = focus != lastFocusState
        lastFocusState = focus
        let runningProcessIDs = CodexOverlayWindowLocator.runningProcessIDs()
        guard !runningProcessIDs.isEmpty else {
            hidePanel(panel, clearTarget: true)
            return 2_000_000_000
        }

        let focusedProcessID: pid_t?
        switch focus {
        case let .codex(processID):
            focusedProcessID = processID
        case .hidden:
            focusedProcessID = nil
        }

        let windows = CodexOverlayWindowLocator.visibleWindows()
        guard let target = CodexOverlayWindowLocator.selectWindow(
            processIDs: runningProcessIDs,
            focusedProcessID: focusedProcessID,
            previousWindowID: trackedWindowID,
            windows: windows
        ), let appKitFrame = CodexOverlayWindowLocator.appKitFrame(
            from: target.quartzFrame,
            displays: CodexOverlayWindowLocator.displaySpaces()
        ) else {
            hidePanel(panel, clearTarget: false)
            return 700_000_000
        }

        let targetChanged = target.windowID != trackedWindowID
            || target.processID != trackedProcessID
        trackedWindowID = target.windowID
        trackedProcessID = target.processID
        trackedAppKitFrame = appKitFrame

        updateHelpAnchorIfNeeded(
            target: target,
            focus: focus,
            targetChanged: targetChanged,
            now: Date()
        )

        let frame = positionedFrame(panelSize: panel.frame.size, in: appKitFrame)
        if panel.frame != frame {
            applyFrame(frame, to: panel, animate: false)
        } else if detailsPanel?.isVisible == true {
            updateDetailsPanelFrame(in: appKitFrame)
        }
        let isWidgetVisible: Bool
        switch focus {
        case .codex:
            isWidgetVisible = true
        case .hidden:
            isWidgetVisible = false
        }
        let recoveryVisible = recoveryPresenter?.update(
            anchorFrame: panel.frame,
            targetFrame: appKitFrame,
            isWidgetVisible: isWidgetVisible
        ) == true
        if recoveryVisible {
            closeDetails()
        }
        let panelIsAboveTarget = CodexOverlayWindowLocator.isWindow(
            CGWindowID(panel.windowNumber),
            above: target.windowID,
            windows: windows
        )

        switch focus {
        case .codex:
            if !isOverlayVisible { isOverlayVisible = true }
            panel.ignoresMouseEvents = false
            if focusChanged || targetChanged || !panel.isVisible || !panelIsAboveTarget {
                panel.orderFrontRegardless()
            }
            return 100_000_000
        case .hidden:
            hidePanel(panel, clearTarget: false)
            return 1_000_000_000
        }
    }

    @MainActor
    private func hidePanel(_ panel: NSPanel, clearTarget: Bool) {
        recoveryPresenter?.hide()
        isSummaryHovered = false
        if isOverlayVisible { isOverlayVisible = false }
        closeDetails()
        if panel.isVisible {
            panel.orderOut(nil)
        }
        if clearTarget {
            trackedWindowID = nil
            trackedProcessID = nil
            trackedAppKitFrame = nil
            resetHelpAnchor(clearAnchor: true)
        }
    }

    @MainActor
    private func acknowledgeWeeklyQuotaRecovery() {
        environment?.acknowledgeWeeklyQuotaRecovery()
        recoveryPresenter?.hide()
        if isSummaryHovered && !isExpanded {
            showDetails()
        }
    }

    @MainActor
    private func positionedFrame(panelSize: CGSize, in codexWindow: CGRect) -> CGRect {
        CodexOverlayLayout.frame(
            in: codexWindow,
            panelSize: panelSize,
            shadowMargin: shadowMargin,
            helpLeadingX: helpAnchor?.leadingX(in: codexWindow),
            manualPosition: manualPosition
        )
    }

    @MainActor
    private func updateHelpAnchorIfNeeded(
        target: CodexOverlayWindow,
        focus: FocusState,
        targetChanged: Bool,
        now: Date
    ) {
        let preciseModeEnabled = UsageFeatureFlags.shared.isAXSnappingEnabled
        let trusted = AXIsProcessTrusted()
        if isAccessibilityTrusted != trusted {
            isAccessibilityTrusted = trusted
        }
        guard preciseModeEnabled, trusted else {
            if helpAnchor != nil
                || helpAnchorTask != nil
                || helpAnchorWindowID != nil {
                resetHelpAnchor(clearAnchor: true)
            }
            return
        }

        let sizeChanged = helpAnchorWindowSize != target.quartzFrame.size
        let discoveryTargetChanged = targetChanged
            || helpAnchorWindowID != target.windowID
            || helpAnchorProcessID != target.processID
        if discoveryTargetChanged {
            resetHelpAnchor(clearAnchor: true)
            helpAnchorWindowID = target.windowID
            helpAnchorProcessID = target.processID
            helpAnchorWindowSize = target.quartzFrame.size
        } else if sizeChanged {
            helpAnchorWindowSize = target.quartzFrame.size
            helpAnchorNextAttempt = now
        }

        guard case .codex = focus,
              helpAnchorTask == nil,
              helpAnchorNextAttempt.map({ now >= $0 }) ?? true else {
            return
        }
        startHelpAnchorLookup(target: target)
    }

    @MainActor
    private func startHelpAnchorLookup(target: CodexOverlayWindow) {
        helpAnchorGeneration &+= 1
        let generation = helpAnchorGeneration
        helpAnchorTask = Task.detached(priority: .utility) { [weak self] in
            let anchor = CodexAccessibilityAnchorReader.helpAnchor(
                processID: target.processID,
                matching: target.quartzFrame
            )
            guard !Task.isCancelled else { return }
            await self?.finishHelpAnchorLookup(
                anchor: anchor,
                target: target,
                generation: generation,
                completedAt: Date()
            )
        }
    }

    @MainActor
    private func finishHelpAnchorLookup(
        anchor: CodexHelpAnchor?,
        target: CodexOverlayWindow,
        generation: Int,
        completedAt: Date
    ) {
        guard generation == helpAnchorGeneration else { return }
        helpAnchorTask = nil
        guard trackedWindowID == target.windowID,
              trackedProcessID == target.processID else {
            return
        }
        guard helpAnchorWindowSize == target.quartzFrame.size else {
            helpAnchorNextAttempt = completedAt
            return
        }

        if let anchor {
            helpAnchor = anchor
            helpAnchorFailures = 0
            helpAnchorNextAttempt = completedAt.addingTimeInterval(12)
        } else {
            helpAnchorFailures += 1
            if helpAnchorFailures >= 2 {
                helpAnchor = nil
            }
            let exponent = min(4, max(0, helpAnchorFailures - 1))
            let delay = min(8, 0.5 * pow(2, Double(exponent)))
            helpAnchorNextAttempt = completedAt.addingTimeInterval(delay)
        }

        if let panel, let trackedAppKitFrame {
            let frame = positionedFrame(
                panelSize: panel.frame.size,
                in: trackedAppKitFrame
            )
            if panel.frame != frame {
                applyFrame(frame, to: panel, animate: false)
            }
        }
    }

    @MainActor
    private func resetHelpAnchor(clearAnchor: Bool) {
        helpAnchorGeneration &+= 1
        helpAnchorTask?.cancel()
        helpAnchorTask = nil
        helpAnchorFailures = 0
        helpAnchorNextAttempt = nil
        helpAnchorWindowID = nil
        helpAnchorProcessID = nil
        helpAnchorWindowSize = nil
        if clearAnchor {
            helpAnchor = nil
        }
    }

    @MainActor
    private func handleDragChanged() {
        guard let p = panel, let trackedAppKitFrame else { return }
        isDragging = true
        closeDetails()

        let currentMouse = NSEvent.mouseLocation
        if dragStartMouseLocation == nil {
            dragStartMouseLocation = currentMouse
            dragStartOrigin = p.frame.origin
        }
        guard let startMouse = dragStartMouseLocation, let startOrigin = dragStartOrigin else { return }

        let deltaX = currentMouse.x - startMouse.x
        let deltaY = currentMouse.y - startMouse.y
        let proposed = CGRect(
            origin: NSPoint(x: startOrigin.x + deltaX, y: startOrigin.y + deltaY),
            size: p.frame.size
        )
        p.setFrameOrigin(
            CodexOverlayLayout.clampedFrame(proposed, in: trackedAppKitFrame).origin
        )
    }

    @MainActor
    private func handleDragEnded() {
        let shouldShowDetails = isSummaryHovered && !isExpanded
        defer {
            isDragging = false
            dragStartMouseLocation = nil
            dragStartOrigin = nil
            if shouldShowDetails {
                showDetails()
            }
        }
        guard let p = panel else {
            return
        }

        if let trackedAppKitFrame {
            let clamped = CodexOverlayLayout.clampedFrame(
                p.frame,
                in: trackedAppKitFrame
            )
            applyFrame(clamped, to: p, animate: true)
            let position = CodexOverlayLayout.relativePosition(
                for: clamped,
                in: trackedAppKitFrame
            )
            manualPosition = position
            UserDefaults.standard.set(
                Double(position.horizontal),
                forKey: Self.overlayPositionXDefaultsKey
            )
            UserDefaults.standard.set(
                Double(position.vertical),
                forKey: Self.overlayPositionYDefaultsKey
            )
            removeLegacyPositionDefaults()
        }
    }

    private func loadManualPosition() {
        let defaults = UserDefaults.standard
        if let horizontal = defaults.object(
            forKey: Self.overlayPositionXDefaultsKey
        ) as? NSNumber,
        let vertical = defaults.object(
            forKey: Self.overlayPositionYDefaultsKey
        ) as? NSNumber {
            manualPosition = CodexOverlayRelativePosition(
                horizontal: CGFloat(truncating: horizontal),
                vertical: CGFloat(truncating: vertical)
            )
        } else {
            manualPosition = nil
        }
        removeLegacyPositionDefaults()
    }

    private func removeLegacyPositionDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.legacyPinnedDefaultsKey)
        defaults.removeObject(forKey: Self.legacyOriginXDefaultsKey)
        defaults.removeObject(forKey: Self.legacyOriginYDefaultsKey)
    }

    @MainActor
    private func applyFrame(_ frame: NSRect, to panel: NSPanel, animate: Bool) {
        panel.setFrame(frame, display: true, animate: animate)
        if detailsPanel?.isVisible == true, let trackedAppKitFrame {
            updateDetailsPanelFrame(in: trackedAppKitFrame)
        }
    }

    private static func defaultEdgeOrigin(for size: NSSize, inset: CGFloat) -> NSPoint {
        let screen = screen(containing: NSEvent.mouseLocation)
        let visibleFrame = screen.visibleFrame
        return NSPoint(
            x: visibleFrame.maxX - size.width - inset,
            y: visibleFrame.maxY - size.height - inset
        )
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

// MARK: - 挂件 SwiftUI 视图 (纯净极简科技风 HUD)
public struct CodexOverlayView: View {
    let onToggleExpand: (Bool, Bool) -> Void
    let onHoverChanged: (Bool) -> Void
    let onDragChanged: () -> Void
    let onDragEnded: () -> Void
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) var colorScheme
    @State private var isExpanded: Bool
    @State private var isDraggingWidget = false
    @ObservedObject private var flags = UsageFeatureFlags.shared
    @ObservedObject private var overlayController = CodexUsageOverlayController.shared

    public init(
        state: AppState,
        isExpanded: Bool = false,
        onToggleExpand: @escaping (Bool, Bool) -> Void,
        onHoverChanged: @escaping (Bool) -> Void,
        onDragChanged: @escaping () -> Void,
        onDragEnded: @escaping () -> Void
    ) {
        self.state = state
        self._isExpanded = State(initialValue: isExpanded)
        self.onToggleExpand = onToggleExpand
        self.onHoverChanged = onHoverChanged
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
    }

    public var body: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let purple = AppTheme.accentPurple(for: colorScheme)
        let amber = AppTheme.accentAmber(for: colorScheme)
        let isDark = colorScheme == .dark
        let statusColor = state.preferredDisplayQuotaSeverityColor

        if overlayController.isOverlayVisible {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: isExpanded ? 9 : 0) {
                // MARK: 顶部 / 收起状态栏 (纯净无内嵌胶囊排版，绝不截断)
                HStack(spacing: 6) {
                    // 左侧：发光指示器 + 品牌文字
                    HStack(spacing: 5) {
                        ToolAppIcon(tool: .codex, size: 16)
                        ZStack {
                            Circle()
                                .fill(statusColor.opacity(0.24))
                                .frame(width: 12, height: 12)
                            Circle()
                                .fill(statusColor)
                                .frame(width: 6, height: 6)
                                .shadow(color: statusColor.opacity(0.8), radius: 2)
                        }

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

                                Text(state.preferredDisplayQuotaPercentString)
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

                        if isDraggingWidget {
                            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                                .font(.system(size: 8.5, weight: .black))
                                .foregroundStyle(amber)
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
                            let progress = min(max(state.preferredDisplayQuotaProgress, 0.0), 1.0)
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
                                    .animation(.spring(response: 0.35, dampingFraction: 0.78), value: state.preferredDisplayQuotaProgress)
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
                            value: state.preferredDisplayQuotaPercentString,
                            valueColor: statusColor
                        )

                        if state.fiveHourQuotaSnapshot != nil,
                           let weekly = state.weeklyQuotaSnapshot {
                            overlayDetailRow(
                                icon: "calendar",
                                iconColor: AppTheme.accentEmerald(for: colorScheme),
                                title: L10n.text("周额度", "Weekly Quota"),
                                value: weeklyQuotaDisplayPercent(for: weekly),
                                valueColor: AppTheme.accentEmerald(for: colorScheme)
                            )
                        }

                        overlayDetailRow(
                            icon: "hourglass",
                            iconColor: cyan,
                            title: L10n.text("距离重置", "Until reset"),
                            value: state.preferredDisplayResetCountdownString,
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
            .gesture(moveGesture)
            .onHover(perform: onHoverChanged)
            .onDisappear { onHoverChanged(false) }
            }
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { _ in
                isDraggingWidget = true
                onDragChanged()
            }
            .onEnded { _ in
                onDragEnded()
                isDraggingWidget = false
            }
    }

    private func toggleExpanded() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            isExpanded.toggle()
        }
        onToggleExpand(isExpanded, true)
    }

    private func weeklyQuotaDisplayPercent(for snapshot: RateLimitSnapshotRecord) -> String {
        switch state.quotaDisplayMode {
        case .used:
            return UsageNumberFormatter.percent(snapshot.usedPercent)
        case .remaining:
            return UsageNumberFormatter.percent(snapshot.remainingPercent)
        }
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

private struct CodexOverlayHoverDetailsView: View {
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let purple = AppTheme.accentPurple(for: colorScheme)
        let amber = AppTheme.accentAmber(for: colorScheme)
        let statusColor = state.preferredDisplayQuotaSeverityColor
        let isDark = colorScheme == .dark

        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ToolAppIcon(tool: .codex, size: 16)
                    Text("Codex")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(cyan)
                    Spacer()
                    Text(state.quotaDisplayMode.shortTitle)
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    Text(state.preferredDisplayQuotaPercentString)
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .foregroundStyle(statusColor)
                        .monospacedDigit()
                }

                GeometryReader { proxy in
                    let progress = min(max(state.preferredDisplayQuotaProgress, 0), 1)
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
                            .frame(width: max(5, proxy.size.width * CGFloat(progress)), height: 4)
                    }
                }
                .frame(height: 4)

                VStack(spacing: 5) {
                    detailRow(
                        icon: "gauge.with.dots.needle.bottom.50percent",
                        color: statusColor,
                        title: state.quotaDisplayMode.pickerTitle,
                        value: state.preferredDisplayQuotaPercentString
                    )
                    if state.fiveHourQuotaSnapshot != nil,
                       let weekly = state.weeklyQuotaSnapshot {
                        detailRow(
                            icon: "calendar",
                            color: AppTheme.accentEmerald(for: colorScheme),
                            title: L10n.text("周额度", "Weekly Quota"),
                            value: weeklyQuotaDisplayPercent(for: weekly)
                        )
                    }
                    detailRow(
                        icon: "hourglass",
                        color: cyan,
                        title: L10n.text("距离重置", "Until reset"),
                        value: state.preferredDisplayResetCountdownString
                    )
                    detailRow(
                        icon: "crown.fill",
                        color: purple,
                        title: L10n.text("订阅计划", "Plan"),
                        value: state.subscriptionPlanTitle.uppercased()
                    )
                    detailRow(
                        icon: "ticket.fill",
                        color: state.resetCreditAvailableCount > 0
                            ? amber
                            : AppTheme.textSecondary(for: colorScheme),
                        title: L10n.text("重置卡储备", "Reset Cards"),
                        value: L10n.format(
                            "%d available",
                            zhHans: "%d 张可用",
                            state.resetCreditAvailableCount
                        )
                    )
                }
            }
            .padding(12)
            .background(
                isDark
                    ? Color(red: 0.08, green: 0.10, blue: 0.16).opacity(0.96)
                    : Color.white.opacity(0.98),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [cyan.opacity(0.6), purple.opacity(0.35), cyan.opacity(0.45)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(isDark ? 0.45 : 0.20), radius: 6, y: 2)
            .padding(10)
            .contentShape(Rectangle())
            .onHover(perform: onHoverChanged)
            .onDisappear { onHoverChanged(false) }
        }
    }

    private func detailRow(
        icon: String,
        color: Color,
        title: String,
        value: String
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 14)
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                .fixedSize()
            Spacer()
            Text(value)
                .font(.system(size: 10.5, weight: .heavy, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .monospacedDigit()
        }
    }

    private func weeklyQuotaDisplayPercent(for snapshot: RateLimitSnapshotRecord) -> String {
        switch state.quotaDisplayMode {
        case .used:
            return UsageNumberFormatter.percent(snapshot.usedPercent)
        case .remaining:
            return UsageNumberFormatter.percent(snapshot.remainingPercent)
        }
    }
}

private extension NSRect {
    var area: CGFloat {
        guard !isNull && !isEmpty else { return 0 }
        return width * height
    }
}
