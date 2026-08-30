import AppKit
import Combine
import SwiftUI

public enum ToolOverlayPreferences {
    private static let defaultsPrefix = "QuotaLens.Overlay.ToolEnabled.v1"

    public static func isEnabled(for tool: MonitoringToolID, defaults: UserDefaults = .standard) -> Bool {
        let key = defaultsPrefix + "." + tool.rawValue
        if defaults.object(forKey: key) != nil {
            return defaults.bool(forKey: key)
        }
        if tool == .codex {
            return UsageFeatureFlags.shared.isOverlayEnabled
        }
        return true
    }

    public static func setEnabled(_ enabled: Bool, for tool: MonitoringToolID, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsPrefix + "." + tool.rawValue)
        if tool == .codex {
            UsageFeatureFlags.shared.isOverlayEnabled = enabled
        }
    }

    public static func reset(defaults: UserDefaults = .standard) {
        for descriptor in ToolRegistry.shared.descriptors {
            defaults.removeObject(forKey: defaultsPrefix + "." + descriptor.id.rawValue)
        }
    }
}

@MainActor
public final class ToolOverlayCoordinator {
    private weak var environment: AppEnvironment?
    private var foregroundToolCancellable: AnyCancellable?

    public init(environment: AppEnvironment) {
        self.environment = environment
        foregroundToolCancellable = environment.frontmostToolTracker.$foregroundTool
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.refreshVisibility()
                }
            }
    }

    public func refreshConfiguration() {
        guard let environment else { return }
        let codexEnabled = environment.enabledToolsStore.isEnabled(.codex)
            && ToolOverlayPreferences.isEnabled(for: .codex)
        let claudeEnabled = environment.enabledToolsStore.isEnabled(.claude)
            && ToolOverlayPreferences.isEnabled(for: .claude)
        let antigravityEnabled = environment.enabledToolsStore.isEnabled(.antigravity)
            && ToolOverlayPreferences.isEnabled(for: .antigravity)

        CodexUsageOverlayController.shared.setEnabled(codexEnabled, environment: environment)
        ClaudeUsageOverlayController.shared.setEnabled(claudeEnabled, environment: environment)
        AntigravityUsageOverlayController.shared.setEnabled(antigravityEnabled, environment: environment)
        refreshVisibility()
    }

    public func setEnabled(_ enabled: Bool, for tool: MonitoringToolID) {
        ToolOverlayPreferences.setEnabled(enabled, for: tool)
        refreshConfiguration()
    }

    public func resetPosition(for tool: MonitoringToolID) {
        switch tool {
        case .codex:
            CodexUsageOverlayController.shared.resetPinning()
        case .claude:
            ClaudeUsageOverlayController.shared.resetPosition()
        case .antigravity:
            AntigravityUsageOverlayController.shared.resetPosition()
        default:
            break
        }
    }

    public func refreshRecoveryBubbles() {
        CodexUsageOverlayController.shared.updateVisibilityForFrontmostApp()
        ClaudeUsageOverlayController.shared.updateVisibilityForFrontmostApp()
        AntigravityUsageOverlayController.shared.updateVisibilityForFrontmostApp()
    }

    private func refreshVisibility() {
        CodexUsageOverlayController.shared.updateVisibilityForFrontmostApp()
        ClaudeUsageOverlayController.shared.updateVisibilityForFrontmostApp()
        AntigravityUsageOverlayController.shared.updateVisibilityForFrontmostApp()
    }
}

@MainActor
public final class ClaudeUsageOverlayController: NSObject, ObservableObject {
    public static let shared = ClaudeUsageOverlayController()

    private static let positionXDefaultsKey = "QuotaLens.Overlay.Claude.RelativeX"
    private static let positionYDefaultsKey = "QuotaLens.Overlay.Claude.RelativeY"

    private weak var environment: AppEnvironment?
    private var panel: NSPanel?
    private var recoveryPresenter: WeeklyQuotaRecoveryOverlayPresenter?
    private var trackerTask: Task<Void, Never>?
    private var trackedWindowID: CGWindowID?
    private var trackedFrame: CGRect?
    private var manualPosition: CodexOverlayRelativePosition?
    private var isDragging = false
    private var dragStartMouseLocation: NSPoint?
    private var dragStartOrigin: NSPoint?
    private let shadowMargin: CGFloat = 10

    public func setEnabled(_ enabled: Bool, environment: AppEnvironment) {
        self.environment = environment
        if enabled {
            startTracking()
        } else {
            stopTracking()
        }
    }

    public func resetPosition() {
        manualPosition = nil
        UserDefaults.standard.removeObject(forKey: Self.positionXDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.positionYDefaultsKey)
        updateVisibilityForFrontmostApp()
    }

    private func startTracking() {
        guard panel == nil, let environment else { return }
        loadPosition()
        let contentSize = NSSize(width: 218, height: 92)
        let panelSize = NSSize(
            width: contentSize.width + shadowMargin * 2,
            height: contentSize.height + shadowMargin * 2
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
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
        panel.contentView = NSHostingView(
            rootView: ClaudeOverlayView(
                state: environment.state,
                onDragChanged: { [weak self] in self?.handleDragChanged() },
                onDragEnded: { [weak self] in self?.handleDragEnded() }
            )
        )
        self.panel = panel
        self.recoveryPresenter = WeeklyQuotaRecoveryOverlayPresenter(
            state: environment.state,
            tool: .claude,
            onAcknowledge: { [weak self] in
                self?.acknowledgeWeeklyQuotaRecovery()
            }
        )
        updateVisibilityForFrontmostApp()
        trackerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let delay: UInt64 = self?.environment?.frontmostToolTracker.foregroundTool == .claude
                    ? 150_000_000
                    : 1_000_000_000
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                self?.updateVisibilityForFrontmostApp()
            }
        }
    }

    private func stopTracking() {
        trackerTask?.cancel()
        trackerTask = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        recoveryPresenter?.close()
        recoveryPresenter = nil
        trackedWindowID = nil
        trackedFrame = nil
    }

    public func updateVisibilityForFrontmostApp() {
        guard let environment,
              let panel else { return }
        if isDragging {
            recoveryPresenter?.hide()
            return
        }
        guard environment.frontmostToolTracker.foregroundTool == .claude,
              let processID = environment.frontmostToolTracker.foregroundApplicationPID else {
            hide(panel)
            return
        }

        let windows = CodexOverlayWindowLocator.visibleWindows()
        guard let target = CodexOverlayWindowLocator.selectWindow(
            processIDs: [processID],
            focusedProcessID: processID,
            previousWindowID: trackedWindowID,
            windows: windows
        ), let appKitFrame = CodexOverlayWindowLocator.appKitFrame(
            from: target.quartzFrame,
            displays: CodexOverlayWindowLocator.displaySpaces()
        ) else {
            hide(panel)
            return
        }

        trackedWindowID = target.windowID
        trackedFrame = appKitFrame
        let frame = positionedFrame(panelSize: panel.frame.size, in: appKitFrame)
        if panel.frame != frame {
            panel.setFrame(frame, display: true, animate: false)
        }
        recoveryPresenter?.update(
            anchorFrame: panel.frame,
            targetFrame: appKitFrame,
            isWidgetVisible: true
        )
        panel.ignoresMouseEvents = false
        if !panel.isVisible || !CodexOverlayWindowLocator.isWindow(
            CGWindowID(panel.windowNumber),
            above: target.windowID,
            windows: windows
        ) {
            panel.orderFrontRegardless()
        }
    }

    private func hide(_ panel: NSPanel) {
        recoveryPresenter?.hide()
        panel.ignoresMouseEvents = true
        if panel.isVisible {
            panel.orderOut(nil)
        }
        trackedWindowID = nil
        trackedFrame = nil
    }

    private func acknowledgeWeeklyQuotaRecovery() {
        environment?.acknowledgeWeeklyQuotaRecovery()
        recoveryPresenter?.hide()
    }

    private func positionedFrame(panelSize: CGSize, in target: CGRect) -> CGRect {
        if let manualPosition {
            return CodexOverlayLayout.frame(
                in: target,
                panelSize: panelSize,
                shadowMargin: shadowMargin,
                helpLeadingX: nil,
                manualPosition: manualPosition
            )
        }
        let preferred = CGRect(
            x: target.maxX - panelSize.width - 18,
            y: target.maxY - panelSize.height - 18,
            width: panelSize.width,
            height: panelSize.height
        )
        return CodexOverlayLayout.clampedFrame(preferred, in: target)
    }

    private func handleDragChanged() {
        guard let panel, let trackedFrame else { return }
        isDragging = true
        let mouse = NSEvent.mouseLocation
        if dragStartMouseLocation == nil {
            dragStartMouseLocation = mouse
            dragStartOrigin = panel.frame.origin
        }
        guard let startMouse = dragStartMouseLocation,
              let startOrigin = dragStartOrigin else { return }
        let proposed = CGRect(
            x: startOrigin.x + mouse.x - startMouse.x,
            y: startOrigin.y + mouse.y - startMouse.y,
            width: panel.frame.width,
            height: panel.frame.height
        )
        panel.setFrameOrigin(CodexOverlayLayout.clampedFrame(proposed, in: trackedFrame).origin)
    }

    private func handleDragEnded() {
        defer {
            isDragging = false
            dragStartMouseLocation = nil
            dragStartOrigin = nil
        }
        guard let panel, let trackedFrame else { return }
        let frame = CodexOverlayLayout.clampedFrame(panel.frame, in: trackedFrame)
        panel.setFrame(frame, display: true, animate: false)
        let position = CodexOverlayLayout.relativePosition(for: frame, in: trackedFrame)
        manualPosition = position
        UserDefaults.standard.set(Double(position.horizontal), forKey: Self.positionXDefaultsKey)
        UserDefaults.standard.set(Double(position.vertical), forKey: Self.positionYDefaultsKey)
    }

    private func loadPosition() {
        let defaults = UserDefaults.standard
        guard let horizontal = defaults.object(forKey: Self.positionXDefaultsKey) as? NSNumber,
              let vertical = defaults.object(forKey: Self.positionYDefaultsKey) as? NSNumber else {
            manualPosition = nil
            return
        }
        manualPosition = CodexOverlayRelativePosition(
            horizontal: CGFloat(truncating: horizontal),
            vertical: CGFloat(truncating: vertical)
        )
    }
}

private struct ClaudeOverlayView: View {
    @ObservedObject var state: AppState
    let onDragChanged: () -> Void
    let onDragEnded: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let amber = AppTheme.accentAmber(for: colorScheme)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ToolAppIcon(tool: .claude, size: 16)
                Text(state.quotaDisplayMode.shortTitle)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                Text(summaryPercentText)
                    .font(.system(size: 11.5, weight: .heavy, design: .monospaced))
                    .foregroundStyle(summaryQuotaColor)
                    .monospacedDigit()
                Spacer()
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }

            if let usage = state.latestClaudeUsage, usage.hasQuota {
                if let window = usage.fiveHourForDisplay {
                    quotaRow(window)
                }
                if let window = usage.sevenDay {
                    quotaRow(window)
                }
            } else {
                Text(state.claudeUsageErrorText ?? L10n.text("等待额度同步", "Waiting for quota sync"))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            colorScheme == .dark ? Color(red: 0.08, green: 0.10, blue: 0.16).opacity(0.94) : Color.white.opacity(0.96),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(amber.opacity(colorScheme == .dark ? 0.55 : 0.38), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.42 : 0.18), radius: 6, y: 2)
        .padding(10)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { _ in onDragChanged() }
                .onEnded { _ in onDragEnded() }
        )
    }

    private var summaryWindow: ClaudeUsageSnapshot.Window? {
        guard let usage = state.latestClaudeUsage, usage.hasQuota else { return nil }
        return usage.fiveHourForDisplay ?? usage.sevenDay
    }

    private var summaryPercentText: String {
        guard let window = summaryWindow else { return "--" }
        let shown = state.quotaDisplayMode == .used ? window.usedPercent : window.remainingPercent
        return UsageNumberFormatter.percent(shown, maximumFractionDigits: 0)
    }

    private var summaryQuotaColor: Color {
        guard let window = summaryWindow else {
            return AppTheme.textSecondary(for: colorScheme)
        }
        if window.remainingPercent <= 15 { return AppTheme.accentRose(for: colorScheme) }
        if window.remainingPercent <= 35 { return AppTheme.accentAmber(for: colorScheme) }
        return AppTheme.accentEmerald(for: colorScheme)
    }

    private func quotaRow(_ window: ClaudeUsageSnapshot.Window) -> some View {
        let shown = state.quotaDisplayMode == .used ? window.usedPercent : window.remainingPercent
        let tint: Color = window.usedPercent >= 85
            ? AppTheme.accentRose(for: colorScheme)
            : (window.usedPercent >= 60
                ? AppTheme.accentAmber(for: colorScheme)
                : AppTheme.accentEmerald(for: colorScheme))
        return VStack(spacing: 3) {
            HStack {
                Text(window.localizedTitle)
                Spacer()
                Text(UsageNumberFormatter.percent(shown, maximumFractionDigits: 0))
                    .foregroundStyle(tint)
            }
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            ProgressView(value: shown / 100)
                .tint(tint)
        }
    }
}
