// Custom AppKit menu bar item so the percentage can keep its own color.

import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
public final class MenuBarStatusItemController: NSObject {
    private let state: AppState
    private let usageFacade: UsageQueryFacade
    private let claudeScanCoordinator: ClaudeUsageScanCoordinator
    private let enabledTools: EnabledToolsStore
    private let toolTracker: FrontmostToolTracker
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let recoveryPopover: NSPopover
    private var cancellable: AnyCancellable?
    private var settingsCancellable: AnyCancellable?
    private var antigravityCancellable: AnyCancellable?
    private var toolCancellable: AnyCancellable?
    private var enabledToolsCancellable: AnyCancellable?
    private var appearanceRefreshScheduled = false
    private var onOpenMainWindow: () -> Void
    private var onRefresh: (MonitoringToolID?) -> Void
    private var onAcknowledgeResetCreditReminder: () -> Void
    private var onSnoozeResetCreditReminder: (Int) -> Void
    private var onAcknowledgeWeeklyQuotaRecovery: () -> Void
    private var suppressPopoverUntil = Date.distantPast
    private var restoreMainWindowFocusAfterPopover = false
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private let popoverWidth: CGFloat = 340
    private let minimumPopoverHeight: CGFloat = 575

    public init(
        state: AppState,
        usageFacade: UsageQueryFacade,
        claudeScanCoordinator: ClaudeUsageScanCoordinator,
        enabledTools: EnabledToolsStore,
        toolTracker: FrontmostToolTracker,
        onOpenMainWindow: @escaping () -> Void,
        onRefresh: @escaping (MonitoringToolID?) -> Void,
        onAcknowledgeResetCreditReminder: @escaping () -> Void,
        onSnoozeResetCreditReminder: @escaping (Int) -> Void,
        onAcknowledgeWeeklyQuotaRecovery: @escaping () -> Void
    ) {
        self.state = state
        self.usageFacade = usageFacade
        self.claudeScanCoordinator = claudeScanCoordinator
        self.enabledTools = enabledTools
        self.toolTracker = toolTracker
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.recoveryPopover = NSPopover()
        self.onOpenMainWindow = onOpenMainWindow
        self.onRefresh = onRefresh
        self.onAcknowledgeResetCreditReminder = onAcknowledgeResetCreditReminder
        self.onSnoozeResetCreditReminder = onSnoozeResetCreditReminder
        self.onAcknowledgeWeeklyQuotaRecovery = onAcknowledgeWeeklyQuotaRecovery
        super.init()

        configureStatusButton()
        configurePopover()
        configureRecoveryPopover()
        observeState()
        updateStatusTitle()
        updateRecoveryPopover()
    }

    public func updateActions(
        onOpenMainWindow: @escaping () -> Void,
        onRefresh: @escaping (MonitoringToolID?) -> Void,
        onAcknowledgeResetCreditReminder: @escaping () -> Void,
        onSnoozeResetCreditReminder: @escaping (Int) -> Void,
        onAcknowledgeWeeklyQuotaRecovery: @escaping () -> Void
    ) {
        self.onOpenMainWindow = onOpenMainWindow
        self.onRefresh = onRefresh
        self.onAcknowledgeResetCreditReminder = onAcknowledgeResetCreditReminder
        self.onSnoozeResetCreditReminder = onSnoozeResetCreditReminder
        self.onAcknowledgeWeeklyQuotaRecovery = onAcknowledgeWeeklyQuotaRecovery
    }

    public func closePopoverAndSuppressOpening(for interval: TimeInterval = 0.55) {
        suppressPopoverUntil = Date().addingTimeInterval(interval)
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    public func refreshAppearance() {
        updatePopoverAppearance()
        updateRecoveryPopoverAppearance()
        updateStatusIcon()
        updateStatusTitle()
        updateRecoveryPopover()
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.imagePosition = .imageLeading
        button.toolTip = "QuotaLens"
        button.wantsLayer = true
        button.layer?.masksToBounds = false
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        if let currentDisplayTool,
           let baseImage = ToolAppIcon.applicationImage(for: currentDisplayTool) {
            let image = baseImage.copy() as? NSImage ?? baseImage
            image.size = NSSize(width: 16, height: 16)
            image.isTemplate = false
            button.image = image
            button.contentTintColor = nil
            return
        }

        let isLight = isLightAppearance
        let iconColor = isLight
            ? NSColor(red: 0.02, green: 0.36, blue: 0.74, alpha: 1.0)
            : NSColor(red: 0.0, green: 0.92, blue: 1.0, alpha: 1.0)

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)

        let symbolName: String
        switch currentDisplayTool {
        case .claude: symbolName = "sparkles"
        case .antigravity: symbolName = "wand.and.stars"
        default: symbolName = "gauge.with.needle.fill"
        }
        if let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "QuotaLens") {
            if let configuredImage = baseImage.withSymbolConfiguration(config) {
                configuredImage.isTemplate = true
                button.image = configuredImage
            } else {
                baseImage.isTemplate = true
                button.image = baseImage
            }
        }
        button.contentTintColor = iconColor
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.delegate = self
        updatePopoverAppearance()
        popover.contentSize = NSSize(width: 340, height: 575)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarContentView(
                state: state,
                usageFacade: usageFacade,
                claudeScanCoordinator: claudeScanCoordinator,
                displayTool: currentDisplayTool,
                onOpenMainWindow: { [weak self] in
                    self?.popover.performClose(nil)
                    DispatchQueue.main.async { [weak self] in
                        self?.onOpenMainWindow()
                    }
                },
                onRefresh: { [weak self] in
                    guard let self else { return }
                    self.onRefresh(self.currentDisplayTool)
                }
            )
        )
    }

    private func configureRecoveryPopover() {
        recoveryPopover.behavior = .applicationDefined
        recoveryPopover.delegate = self
        recoveryPopover.animates = true
        updateRecoveryPopoverAppearance()
    }

    private func updatePopoverAppearance() {
        switch state.themeMode {
        case .light:
            popover.appearance = NSAppearance(named: .aqua)
        case .dark:
            popover.appearance = NSAppearance(named: .darkAqua)
        case .system:
            popover.appearance = nil
        }
    }

    private func updateRecoveryPopoverAppearance() {
        switch state.themeMode {
        case .light:
            recoveryPopover.appearance = NSAppearance(named: .aqua)
        case .dark:
            recoveryPopover.appearance = NSAppearance(named: .darkAqua)
        case .system:
            recoveryPopover.appearance = nil
        }
    }

    private func observeState() {
        cancellable = state.objectWillChange.sink { [weak self] _ in
            guard let self, !self.appearanceRefreshScheduled else { return }
            self.appearanceRefreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.appearanceRefreshScheduled = false
                self.refreshAppearance()
            }
        }
        settingsCancellable = state.$latestClaudeUsage.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.updateStatusTitle()
            }
        }
        antigravityCancellable = state.$latestAntigravityQuota
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.updateStatusTitle()
                }
            }
        toolCancellable = Publishers.CombineLatest3(
            toolTracker.$foregroundTool,
            toolTracker.$lastActiveTool,
            toolTracker.$foregroundBundleIdentifier
        ).sink { [weak self] _, _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.updatePopoverTool()
            }
        }
        enabledToolsCancellable = enabledTools.$enabledToolIDs.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.updatePopoverTool()
            }
        }
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }

        let isLight = isLightAppearance
        let labelColor = isLight
            ? NSColor(red: 0.02, green: 0.06, blue: 0.13, alpha: 1.0)
            : NSColor(red: 0.95, green: 0.97, blue: 1.0, alpha: 1.0)

        guard let displayTool = currentDisplayTool else {
            let title = NSAttributedString(
                string: " -- ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: isLight ? NSColor(red: 0.20, green: 0.26, blue: 0.36, alpha: 1.0) : NSColor.secondaryLabelColor
                ]
            )
            button.attributedTitle = title
            button.toolTip = L10n.text("QuotaLens · 等待识别工具", "QuotaLens · Waiting for a tool")
            statusItem.length = NSStatusItem.variableLength
            updateCapsuleAppearance(isReminderActive: state.hasActiveResetCreditReminder)
            return
        }

        if displayTool == .claude {
            let label = " \(state.quotaDisplayMode.shortTitle) "
            let percent = "\(state.claudeMenuBarPercentString) "
            let title = NSMutableAttributedString()
            let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            title.append(NSAttributedString(
                string: label,
                attributes: [
                    .font: font,
                    .foregroundColor: labelColor
                ]
            ))
            title.append(NSAttributedString(
                string: percent,
                attributes: [
                    .font: font,
                    .foregroundColor: claudeSeverityColor()
                ]
            ))
            button.attributedTitle = title
            button.toolTip = "QuotaLens \(label)\(percent)"
            statusItem.length = NSStatusItem.variableLength
            updateCapsuleAppearance(isReminderActive: state.hasActiveResetCreditReminder)
            return
        }

        if displayTool == .antigravity {
            updateAntigravityStatusTitle(button: button, labelColor: labelColor)
            statusItem.length = NSStatusItem.variableLength
            updateCapsuleAppearance(isReminderActive: state.hasActiveResetCreditReminder)
            return
        }

        let label = " \(state.quotaDisplayMode.shortTitle) "
        let percent = "\(state.preferredDisplayQuotaPercentString) "
        let title = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        title.append(NSAttributedString(
            string: label,
            attributes: [
                .font: font,
                .foregroundColor: labelColor
            ]
        ))

        title.append(NSAttributedString(
            string: percent,
            attributes: [
                .font: font,
                .foregroundColor: severityColor()
            ]
        ))

        button.attributedTitle = title
        button.toolTip = "QuotaLens \(label)\(percent)"
        statusItem.length = NSStatusItem.variableLength
        updateCapsuleAppearance(isReminderActive: state.hasActiveResetCreditReminder)
    }

    private func updateAntigravityStatusTitle(button: NSStatusBarButton, labelColor: NSColor) {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let title = NSMutableAttributedString()
        let prefix = " \(state.quotaDisplayMode.shortTitle) 5h "
        title.append(NSAttributedString(
            string: prefix,
            attributes: [
                .font: font,
                .foregroundColor: labelColor
            ]
        ))

        let buckets = state.latestAntigravityQuota?.orderedCompactFiveHourBuckets ?? []
        if buckets.isEmpty {
            title.append(NSAttributedString(
                string: "-- ",
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            ))
        } else {
            for (index, item) in buckets.enumerated() {
                if index > 0 {
                    title.append(NSAttributedString(
                        string: " · ",
                        attributes: [
                            .font: font,
                            .foregroundColor: NSColor.secondaryLabelColor
                        ]
                    ))
                }
                let shown = state.quotaDisplayMode == .used
                    ? max(0, 100 - item.bucket.remainingPercent)
                    : item.bucket.remainingPercent
                title.append(NSAttributedString(
                    string: "\(item.shortTitle) ",
                    attributes: [
                        .font: font,
                        .foregroundColor: labelColor
                    ]
                ))
                title.append(NSAttributedString(
                    string: "\(UsageNumberFormatter.percent(shown, maximumFractionDigits: 0)) ",
                    attributes: [
                        .font: font,
                        .foregroundColor: antigravitySeverityColor(for: item.bucket.remainingPercent)
                    ]
                ))
            }
        }
        button.attributedTitle = title
        button.toolTip = state.antigravityMenuBarTooltip
        button.setAccessibilityLabel(state.antigravityMenuBarTooltip)
    }

    private var currentDisplayTool: MonitoringToolID? {
        if let detected = ToolRegistry.shared.tool(
            forBundleIdentifier: toolTracker.foregroundBundleIdentifier
        ), enabledTools.isEnabled(detected) {
            return detected
        }
        if let foreground = toolTracker.foregroundTool, enabledTools.isEnabled(foreground) {
            return foreground
        }
        if let last = toolTracker.lastActiveTool, enabledTools.isEnabled(last) {
            return last
        }
        return nil
    }

    private func updatePopoverTool() {
        guard let hostingController = popover.contentViewController as? NSHostingController<MenuBarContentView> else {
            configurePopover()
            return
        }
        hostingController.rootView = MenuBarContentView(
            state: state,
            usageFacade: usageFacade,
            claudeScanCoordinator: claudeScanCoordinator,
            displayTool: currentDisplayTool,
            onOpenMainWindow: { [weak self] in
                self?.popover.performClose(nil)
                DispatchQueue.main.async { [weak self] in
                    self?.onOpenMainWindow()
                }
            },
            onRefresh: { [weak self] in
                guard let self else { return }
                self.onRefresh(self.currentDisplayTool)
            }
        )
        updateStatusIcon()
        updateStatusTitle()
    }

    private func updateRecoveryPopover() {
        let items = state.weeklyQuotaRecoveryUnreadItems
        guard state.weeklyQuotaRecoveryEnabled, !items.isEmpty, !popover.isShown,
              let button = statusItem.button else {
            if recoveryPopover.isShown {
                recoveryPopover.performClose(nil)
            }
            return
        }

        button.superview?.layoutSubtreeIfNeeded()
        let view = WeeklyQuotaRecoveryBubbleView(
            items: items,
            onAcknowledge: { [weak self] in
                self?.acknowledgeWeeklyQuotaRecovery()
            },
            theme: state.colorScheme
        )
        if let hostingController = recoveryPopover.contentViewController as? NSHostingController<WeeklyQuotaRecoveryBubbleView> {
            hostingController.rootView = view
        } else {
            recoveryPopover.contentViewController = NSHostingController(rootView: view)
        }

        if let hostingController = recoveryPopover.contentViewController as? NSHostingController<WeeklyQuotaRecoveryBubbleView> {
            let fittingSize = hostingController.sizeThatFits(in: CGSize(width: 280, height: 500))
            recoveryPopover.contentSize = NSSize(width: 280, height: max(112, ceil(fittingSize.height)))
        }

        if !recoveryPopover.isShown {
            recoveryPopover.show(
                relativeTo: button.bounds,
                of: button,
                preferredEdge: .minY
            )
        }
    }

    private func acknowledgeWeeklyQuotaRecovery() {
        onAcknowledgeWeeklyQuotaRecovery()
        if recoveryPopover.isShown {
            recoveryPopover.performClose(nil)
        }
    }

    private func closeRecoveryPopover() {
        if recoveryPopover.isShown {
            recoveryPopover.performClose(nil)
        }
    }

    private func severityColor() -> NSColor {
        let isLight = isLightAppearance
        if state.preferredDisplayRemainingPercent <= 15.0 {
            return isLight ? NSColor(red: 0.80, green: 0.04, blue: 0.18, alpha: 1.0) : .systemRed
        }
        if state.preferredDisplayRemainingPercent <= 35.0 {
            return isLight ? NSColor(red: 0.72, green: 0.34, blue: 0.00, alpha: 1.0) : .systemOrange
        }
        return isLight ? NSColor(red: 0.00, green: 0.48, blue: 0.25, alpha: 1.0) : .systemGreen
    }

    private func claudeSeverityColor() -> NSColor {
        guard let window = state.latestClaudeUsage?.fiveHourForDisplay
            ?? state.latestClaudeUsage?.sevenDay else {
            return isLightAppearance ? NSColor.secondaryLabelColor : NSColor.secondaryLabelColor
        }
        if window.remainingPercent <= 15 {
            return .systemRed
        }
        if window.remainingPercent <= 35 {
            return .systemOrange
        }
        return .systemGreen
    }

    private func antigravitySeverityColor(for remaining: Double) -> NSColor {
        if remaining <= 15 { return .systemRed }
        if remaining <= 35 { return .systemOrange }
        return .systemGreen
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard Date() >= suppressPopoverUntil else {
            popover.performClose(sender)
            closeRecoveryPopover()
            return
        }

        if state.hasActiveResetCreditReminder {
            popover.performClose(sender)
            closeRecoveryPopover()
            showResetCreditReminderAlert()
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            closeRecoveryPopover()
            restoreMainWindowFocusAfterPopover = AppEnvironment.shared.mainWindowCoordinator.window?.isKeyWindow == true
            showPopover(relativeTo: sender)
        }
    }

    private func showPopover(relativeTo sender: NSStatusBarButton) {
        closeRecoveryPopover()
        // The status item's frame can still be stale immediately after its
        // variable-length title changes. Layout first so the popover is
        // anchored to the actual menu bar button, not its previous frame.
        sender.superview?.layoutSubtreeIfNeeded()

        if let hostingController = popover.contentViewController as? NSHostingController<MenuBarContentView> {
            let fittingSize = hostingController.sizeThatFits(
                in: CGSize(width: popoverWidth, height: 1_000)
            )
            popover.contentSize = NSSize(
                width: popoverWidth,
                height: max(minimumHeightForCurrentTool, ceil(fittingSize.height))
            )
        } else {
            popover.contentSize = NSSize(width: popoverWidth, height: minimumHeightForCurrentTool)
        }

        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        startOutsideClickMonitoring()
    }

    private func startOutsideClickMonitoring() {
        stopOutsideClickMonitoring()

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.popover.isShown else { return }
                self.popover.performClose(nil)
            }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            let location = NSEvent.mouseLocation
            let isInsidePopover = self.popover.contentViewController?.view.window?.frame.contains(location) == true
            let isInsideStatusItem = self.statusItem.button?.window?.frame.contains(location) == true
            if !isInsidePopover && !isInsideStatusItem {
                self.popover.performClose(nil)
            }
            return event
        }
    }

    private func stopOutsideClickMonitoring() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
    }

    private var minimumHeightForCurrentTool: CGFloat {
        switch currentDisplayTool {
        case .codex: return minimumPopoverHeight
        case .claude: return 330
        case .antigravity: return 430
        default: return 180
        }
    }

    private func updateCapsuleAppearance(isReminderActive: Bool) {
        guard let button = statusItem.button, let layer = button.layer else { return }
        let height = max(button.bounds.height, 22)
        layer.cornerRadius = height / 2
        layer.borderWidth = isLightAppearance ? 1.15 : 1

        let isLight = isLightAppearance

        if isReminderActive {
            layer.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.18).cgColor
            layer.borderColor = NSColor.systemOrange.withAlphaComponent(0.95).cgColor
            layer.shadowRadius = 7
            layer.shadowOffset = .zero
            layer.shadowColor = NSColor.systemOrange.cgColor
            layer.shadowOpacity = 0.45
            startReminderPulse(on: layer)
        } else {
            if isLight {
                layer.backgroundColor = NSColor.white.withAlphaComponent(0.82).cgColor
                layer.borderColor = NSColor(red: 0.02, green: 0.42, blue: 0.82, alpha: 0.62).cgColor
                layer.shadowRadius = 4
                layer.shadowOffset = .zero
                layer.shadowColor = NSColor(red: 0.02, green: 0.36, blue: 0.74, alpha: 0.26).cgColor
                layer.shadowOpacity = 0.20
            } else {
                layer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
                layer.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
                layer.shadowRadius = 3
                layer.shadowOffset = .zero
                layer.shadowColor = NSColor.controlAccentColor.cgColor
                layer.shadowOpacity = 0.18
            }
            stopReminderPulse(on: layer)
        }
    }

    private var isLightAppearance: Bool {
        state.effectiveColorScheme == .light
    }

    private func startReminderPulse(on layer: CALayer) {
        if layer.animation(forKey: "resetCreditReminderBorderPulse") != nil {
            return
        }

        let border = CABasicAnimation(keyPath: "borderColor")
        border.fromValue = NSColor.systemOrange.withAlphaComponent(0.35).cgColor
        border.toValue = NSColor.systemOrange.withAlphaComponent(1.0).cgColor
        border.duration = 0.9
        border.autoreverses = true
        border.repeatCount = .infinity
        border.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let shadow = CABasicAnimation(keyPath: "shadowOpacity")
        shadow.fromValue = 0.20
        shadow.toValue = 0.72
        shadow.duration = 0.9
        shadow.autoreverses = true
        shadow.repeatCount = .infinity
        shadow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        layer.add(border, forKey: "resetCreditReminderBorderPulse")
        layer.add(shadow, forKey: "resetCreditReminderShadowPulse")
    }

    private func stopReminderPulse(on layer: CALayer) {
        layer.removeAnimation(forKey: "resetCreditReminderBorderPulse")
        layer.removeAnimation(forKey: "resetCreditReminderShadowPulse")
    }

    private func showResetCreditReminderAlert() {
        guard state.activeResetCreditReminder != nil else { return }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("最近一张重置卡即将到期", "Nearest reset card is expiring soon")
        alert.informativeText = state.activeResetCreditReminderMessage
        alert.addButton(withTitle: L10n.text("收到", "OK"))
        alert.addButton(withTitle: L10n.text("1 小时后提醒", "Remind in 1 hour"))
        alert.addButton(withTitle: L10n.text("2 小时后提醒", "Remind in 2 hours"))
        alert.window.level = .floating

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            onAcknowledgeResetCreditReminder()
        case .alertSecondButtonReturn:
            onSnoozeResetCreditReminder(1)
        case .alertThirdButtonReturn:
            onSnoozeResetCreditReminder(2)
        default:
            break
        }
    }
}

extension MenuBarStatusItemController: NSPopoverDelegate {
    public func popoverDidClose(_ notification: Notification) {
        if notification.object as? NSPopover === recoveryPopover { return }
        stopOutsideClickMonitoring()
        if restoreMainWindowFocusAfterPopover {
            restoreMainWindowFocusAfterPopover = false
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
               let window = AppEnvironment.shared.mainWindowCoordinator.window,
               window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
        }
        updateRecoveryPopover()
    }
}
