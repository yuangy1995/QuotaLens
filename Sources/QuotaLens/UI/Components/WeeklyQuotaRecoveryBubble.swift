import AppKit
import SwiftUI

struct WeeklyQuotaRecoveryBubbleView: View {
    let items: [WeeklyQuotaRecoveryItem]
    let onAcknowledge: () -> Void
    let theme: ColorScheme?
    let drawsBackground: Bool

    @Environment(\.colorScheme) private var colorScheme

    init(
        items: [WeeklyQuotaRecoveryItem],
        onAcknowledge: @escaping () -> Void,
        theme: ColorScheme? = nil,
        drawsBackground: Bool = true
    ) {
        self.items = items
        self.onAcknowledge = onAcknowledge
        self.theme = theme
        self.drawsBackground = drawsBackground
    }

    var body: some View {
        Button(action: onAcknowledge) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AppTheme.accentEmerald(for: colorScheme))
                    Text(titleText)
                        .font(.system(size: 12.5, weight: .black, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                    Spacer(minLength: 0)
                }

                if items.count > 1 {
                    ForEach(Array(items.prefix(4))) { item in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(AppTheme.accentEmerald(for: colorScheme))
                                .frame(width: 5, height: 5)
                            Text(item.displayName)
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                    }
                }

                if items.count > 4 {
                    Text(L10n.format("%d more", zhHans: "还有 %d 项", items.count - 4))
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }

                HStack(spacing: 5) {
                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text(L10n.text("点击关闭", "Click to close"))
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                }
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                .padding(.top, 1)
            }
            .padding(12)
            .frame(width: 280, alignment: .leading)
            .background {
                if drawsBackground {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(colorScheme == .dark
                            ? Color(red: 0.08, green: 0.13, blue: 0.12).opacity(0.97)
                            : Color.white.opacity(0.98))
                }
            }
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .help(L10n.text("点击关闭全部提醒", "Click to close all reminders"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(L10n.text("点击关闭全部周额度恢复提醒", "Click to close all weekly quota recovery reminders"))
        .preferredColorScheme(theme)
    }

    private var accessibilityLabel: String {
        let names = items.map(\.displayName).joined(separator: "、")
        return L10n.format(
            "Weekly quota restored to 100%: %@",
            zhHans: "周额度已恢复 100%：%@",
            names
        )
    }

    private var titleText: String {
        let restored = L10n.text("周额度已恢复 100%", "Weekly quota restored to 100%")
        guard items.count == 1, let item = items.first else { return restored }
        return "\(item.displayName) \(restored)"
    }
}

@MainActor
final class WeeklyQuotaRecoveryOverlayPresenter {
    private let state: AppState
    private let tool: MonitoringToolID
    private let onAcknowledge: () -> Void
    private var panel: NSPanel?

    init(state: AppState, tool: MonitoringToolID, onAcknowledge: @escaping () -> Void) {
        self.state = state
        self.tool = tool
        self.onAcknowledge = onAcknowledge
    }

    var hasVisibleItems: Bool {
        state.weeklyQuotaRecoveryEnabled
            && state.weeklyQuotaRecoveryUnreadItems.contains { $0.tool == tool }
    }

    @discardableResult
    func update(anchorFrame: CGRect?, targetFrame: CGRect?, isWidgetVisible: Bool) -> Bool {
        let items = state.weeklyQuotaRecoveryUnreadItems.filter { $0.tool == tool }
        guard state.weeklyQuotaRecoveryEnabled,
              !items.isEmpty,
              isWidgetVisible,
              let anchorFrame,
              let targetFrame else {
            hide()
            return false
        }

        let panel = ensurePanel()
        let rootView = WeeklyQuotaRecoveryBubbleView(
            items: items,
            onAcknowledge: { [weak self] in
                self?.acknowledge()
            },
            theme: state.colorScheme
        )
        if let hostingController = panel.contentViewController as? NSHostingController<WeeklyQuotaRecoveryBubbleView> {
            hostingController.rootView = rootView
            let fittingSize = hostingController.sizeThatFits(in: CGSize(width: 280, height: 600))
            panel.setContentSize(NSSize(width: 280, height: ceil(fittingSize.height)))
        } else {
            let hostingController = NSHostingController(rootView: rootView)
            panel.contentViewController = hostingController
            let fittingSize = hostingController.sizeThatFits(in: CGSize(width: 280, height: 600))
            panel.setContentSize(NSSize(width: 280, height: ceil(fittingSize.height)))
        }

        let frame = Self.positionedFrame(
            panelSize: panel.frame.size,
            anchorFrame: anchorFrame,
            targetFrame: targetFrame
        )
        if panel.frame != frame {
            panel.setFrame(frame, display: true, animate: false)
        }
        panel.ignoresMouseEvents = false
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        return true
    }

    func hide() {
        panel?.ignoresMouseEvents = true
        panel?.orderOut(nil)
    }

    func close() {
        hide()
        panel?.close()
        panel = nil
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 280, height: 108)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .normal
        panel.isFloatingPanel = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isMovableByWindowBackground = false
        self.panel = panel
        return panel
    }

    static func positionedFrame(panelSize: CGSize, anchorFrame: CGRect, targetFrame: CGRect) -> CGRect {
        let preferredAbove = CGRect(
            x: anchorFrame.midX - panelSize.width / 2,
            y: anchorFrame.maxY + 8,
            width: panelSize.width,
            height: panelSize.height
        )
        let preferredBelow = CGRect(
            x: anchorFrame.midX - panelSize.width / 2,
            y: anchorFrame.minY - panelSize.height - 8,
            width: panelSize.width,
            height: panelSize.height
        )
        let clampedAbove = CodexOverlayLayout.clampedFrame(preferredAbove, in: targetFrame)
        if clampedAbove.minY >= preferredAbove.minY {
            return clampedAbove
        }
        return CodexOverlayLayout.clampedFrame(preferredBelow, in: targetFrame)
    }

    private func acknowledge() {
        onAcknowledge()
        hide()
    }
}
