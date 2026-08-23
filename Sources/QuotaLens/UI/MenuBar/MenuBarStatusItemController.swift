// Custom AppKit menu bar item so the percentage can keep its own color.

import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
public final class MenuBarStatusItemController: NSObject {
    private let state: AppState
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var cancellable: AnyCancellable?
    private var onOpenMainWindow: () -> Void
    private var onRefresh: () -> Void
    private var onAcknowledgeResetCreditReminder: () -> Void
    private var onSnoozeResetCreditReminder: (Int) -> Void

    public init(
        state: AppState,
        onOpenMainWindow: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onAcknowledgeResetCreditReminder: @escaping () -> Void,
        onSnoozeResetCreditReminder: @escaping (Int) -> Void
    ) {
        self.state = state
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.onOpenMainWindow = onOpenMainWindow
        self.onRefresh = onRefresh
        self.onAcknowledgeResetCreditReminder = onAcknowledgeResetCreditReminder
        self.onSnoozeResetCreditReminder = onSnoozeResetCreditReminder
        super.init()

        configureStatusButton()
        configurePopover()
        observeState()
        updateStatusTitle()
    }

    public func updateActions(
        onOpenMainWindow: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onAcknowledgeResetCreditReminder: @escaping () -> Void,
        onSnoozeResetCreditReminder: @escaping (Int) -> Void
    ) {
        self.onOpenMainWindow = onOpenMainWindow
        self.onRefresh = onRefresh
        self.onAcknowledgeResetCreditReminder = onAcknowledgeResetCreditReminder
        self.onSnoozeResetCreditReminder = onSnoozeResetCreditReminder
        configurePopover()
    }

    public func refreshAppearance() {
        updatePopoverAppearance()
        updateStatusIcon()
        updateStatusTitle()
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
        let isLight = isLightAppearance
        let iconColor = isLight
            ? NSColor(red: 0.02, green: 0.36, blue: 0.74, alpha: 1.0)
            : NSColor(red: 0.0, green: 0.92, blue: 1.0, alpha: 1.0)

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)

        if let baseImage = NSImage(systemSymbolName: "gauge.with.needle.fill", accessibilityDescription: "QuotaLens") {
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
        updatePopoverAppearance()
        popover.contentSize = NSSize(width: 340, height: 410)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarContentView(
                state: state,
                onOpenMainWindow: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.onOpenMainWindow()
                },
                onRefresh: { [weak self] in
                    self?.onRefresh()
                }
            )
        )
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

    private func observeState() {
        cancellable = state.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAppearance()
            }
        }
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        updateStatusIcon()

        let isLight = isLightAppearance
        let labelColor = isLight
            ? NSColor(red: 0.02, green: 0.06, blue: 0.13, alpha: 1.0)
            : NSColor(red: 0.95, green: 0.97, blue: 1.0, alpha: 1.0)

        guard state.hasQuotaSnapshot else {
            let title = NSAttributedString(
                string: " \(state.menuBarStatusString) ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: isLight ? NSColor(red: 0.20, green: 0.26, blue: 0.36, alpha: 1.0) : NSColor.secondaryLabelColor
                ]
            )
            button.attributedTitle = title
            button.toolTip = "QuotaLens \(state.quotaUnavailableTitle)"
            statusItem.length = NSStatusItem.variableLength
            updateCapsuleAppearance(isReminderActive: state.hasActiveResetCreditReminder)
            return
        }

        let label = " \(state.quotaDisplayMode.shortTitle) "
        let percent = "\(state.displayedQuotaPercentString) "
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

    private func severityColor() -> NSColor {
        let isLight = isLightAppearance
        if state.currentRemainingPercent <= 15.0 {
            return isLight ? NSColor(red: 0.80, green: 0.04, blue: 0.18, alpha: 1.0) : .systemRed
        }
        if state.currentRemainingPercent <= 35.0 {
            return isLight ? NSColor(red: 0.72, green: 0.34, blue: 0.00, alpha: 1.0) : .systemOrange
        }
        return isLight ? NSColor(red: 0.00, green: 0.48, blue: 0.25, alpha: 1.0) : .systemGreen
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if state.hasActiveResetCreditReminder {
            popover.performClose(sender)
            showResetCreditReminderAlert()
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
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
