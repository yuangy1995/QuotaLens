import AppKit
import SwiftUI

@MainActor
public final class AntigravityUsageOverlayController: NSObject, ObservableObject {
    public static let shared = AntigravityUsageOverlayController()

    private static let expandedDefaultsKey = "QuotaLens.Overlay.Antigravity.IsExpanded"
    private static let positionXDefaultsKey = "QuotaLens.Overlay.Antigravity.RelativeX"
    private static let positionYDefaultsKey = "QuotaLens.Overlay.Antigravity.RelativeY"
    private static let compactContentSize = NSSize(width: 240, height: 34)
    private static let expandedContentSize = NSSize(width: 340, height: 392)
    private static let detailsContentSize = NSSize(width: 350, height: 392)

    private weak var environment: AppEnvironment?
    private var panel: NSPanel?
    private var detailsPanel: NSPanel?
    private var recoveryPresenter: WeeklyQuotaRecoveryOverlayPresenter?
    private var trackerTask: Task<Void, Never>?
    private var detailsCloseTask: Task<Void, Never>?
    private var trackedWindowID: CGWindowID?
    private var trackedFrame: CGRect?
    private var manualPosition: CodexOverlayRelativePosition?
    private var isDragging = false
    private var dragStartMouseLocation: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var isSummaryHovered = false
    private var isDetailsHovered = false
    private var isExpanded = false
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
        isExpanded = UserDefaults.standard.bool(forKey: Self.expandedDefaultsKey)
        let contentSize = isExpanded ? Self.expandedContentSize : Self.compactContentSize
        let panelSize = panelSize(for: contentSize)
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
        panel.isMovableByWindowBackground = false
        panel.contentView = NSHostingView(
            rootView: AntigravityOverlaySummaryView(
                state: environment.state,
                toolTracker: environment.frontmostToolTracker,
                isExpanded: isExpanded,
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
        )
        self.panel = panel
        self.recoveryPresenter = WeeklyQuotaRecoveryOverlayPresenter(
            state: environment.state,
            tool: .antigravity,
            onAcknowledge: { [weak self] in
                self?.acknowledgeWeeklyQuotaRecovery()
            }
        )
        updateVisibilityForFrontmostApp()

        trackerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let delay: UInt64 = self?.environment?.frontmostToolTracker.foregroundTool == .antigravity
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
        detailsCloseTask?.cancel()
        detailsCloseTask = nil
        panel?.orderOut(nil)
        panel?.close()
        detailsPanel?.orderOut(nil)
        detailsPanel?.close()
        recoveryPresenter?.close()
        recoveryPresenter = nil
        panel = nil
        detailsPanel = nil
        trackedWindowID = nil
        trackedFrame = nil
        isSummaryHovered = false
        isDetailsHovered = false
        isExpanded = false
    }

    private func panelSize(for contentSize: NSSize) -> NSSize {
        NSSize(
            width: contentSize.width + shadowMargin * 2,
            height: contentSize.height + shadowMargin * 2
        )
    }

    private func setExpanded(_ expanded: Bool, persist: Bool) {
        isExpanded = expanded
        if persist {
            UserDefaults.standard.set(expanded, forKey: Self.expandedDefaultsKey)
        }

        if expanded {
            closeDetails()
        }

        guard let panel else { return }
        let newSize = panelSize(
            for: expanded ? Self.expandedContentSize : Self.compactContentSize
        )
        let frame: CGRect
        if let trackedFrame {
            frame = positionedFrame(panelSize: newSize, in: trackedFrame)
        } else {
            var fallback = panel.frame
            fallback.origin.y -= newSize.height - fallback.height
            fallback.size = newSize
            frame = fallback
        }
        panel.setFrame(
            frame,
            display: true,
            animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )

        if !expanded, isSummaryHovered {
            showDetails()
        }
    }

    public func updateVisibilityForFrontmostApp() {
        guard let panel else { return }
        if isDragging {
            recoveryPresenter?.hide()
            return
        }
        guard environment?.frontmostToolTracker.foregroundTool == .antigravity,
              let processID = environment?.frontmostToolTracker.foregroundApplicationPID else {
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
        let recoveryVisible = recoveryPresenter?.update(
            anchorFrame: panel.frame,
            targetFrame: appKitFrame,
            isWidgetVisible: true
        ) == true
        if recoveryVisible {
            closeDetails()
        }
        if detailsPanel?.isVisible == true {
            updateDetailsPanelFrame(in: appKitFrame)
        }

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
        isSummaryHovered = false
        closeDetails()
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
        if isSummaryHovered && !isExpanded {
            showDetails()
        }
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
        } else {
            closeDetails()
        }
    }

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

    private func showDetails() {
        detailsCloseTask?.cancel()
        detailsCloseTask = nil
        guard !isDragging,
              !isExpanded,
              panel?.isVisible == true,
              let trackedFrame else { return }

        let details: NSPanel
        if let detailsPanel {
            details = detailsPanel
        } else {
            guard let created = makeDetailsPanel() else { return }
            details = created
        }
        updateDetailsPanelFrame(in: trackedFrame)
        details.ignoresMouseEvents = false
        if !details.isVisible {
            details.orderFrontRegardless()
        }
    }

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

    private func closeDetails() {
        detailsCloseTask?.cancel()
        detailsCloseTask = nil
        isDetailsHovered = false
        detailsPanel?.ignoresMouseEvents = true
        detailsPanel?.orderOut(nil)
    }

    private func makeDetailsPanel() -> NSPanel? {
        guard let environment else { return nil }
        let details = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.detailsContentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        details.level = .normal
        details.isFloatingPanel = false
        details.isOpaque = false
        details.backgroundColor = .clear
        details.hasShadow = false
        details.hidesOnDeactivate = false
        details.acceptsMouseMovedEvents = true
        details.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        details.isMovableByWindowBackground = false
        details.contentView = NSHostingView(
            rootView: AntigravityOverlayDetailsView(
                state: environment.state,
                toolTracker: environment.frontmostToolTracker,
                onHoverChanged: { [weak self] hovering in
                    self?.detailsHoverChanged(hovering)
                }
            )
        )
        detailsPanel = details
        return details
    }

    private func updateDetailsPanelFrame(in target: CGRect) {
        guard let summaryFrame = panel?.frame,
              let detailsPanel else { return }

        let preferredAbove = CGRect(
            x: summaryFrame.minX,
            y: summaryFrame.maxY,
            width: detailsPanel.frame.width,
            height: detailsPanel.frame.height
        )
        let preferredBelow = CGRect(
            x: summaryFrame.minX,
            y: summaryFrame.minY - detailsPanel.frame.height,
            width: detailsPanel.frame.width,
            height: detailsPanel.frame.height
        )
        let preferred = preferredAbove.maxY <= target.maxY ? preferredAbove : preferredBelow
        let frame = CodexOverlayLayout.clampedFrame(preferred, in: target)
        if detailsPanel.frame != frame {
            detailsPanel.setFrame(frame, display: detailsPanel.isVisible, animate: false)
        }
    }

    private func handleDragChanged() {
        guard let panel, let trackedFrame else { return }
        isDragging = true
        closeDetails()
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
        let shouldShowDetails = isSummaryHovered && !isExpanded
        defer {
            isDragging = false
            dragStartMouseLocation = nil
            dragStartOrigin = nil
            if shouldShowDetails {
                showDetails()
            }
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

private struct AntigravityOverlaySummaryView: View {
    @ObservedObject var state: AppState
    @ObservedObject var toolTracker: FrontmostToolTracker
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded: Bool
    let onToggleExpand: (Bool, Bool) -> Void
    let onHoverChanged: (Bool) -> Void
    let onDragChanged: () -> Void
    let onDragEnded: () -> Void

    init(
        state: AppState,
        toolTracker: FrontmostToolTracker,
        isExpanded: Bool,
        onToggleExpand: @escaping (Bool, Bool) -> Void,
        onHoverChanged: @escaping (Bool) -> Void,
        onDragChanged: @escaping () -> Void,
        onDragEnded: @escaping () -> Void
    ) {
        self.state = state
        self.toolTracker = toolTracker
        self._isExpanded = State(initialValue: isExpanded)
        self.onToggleExpand = onToggleExpand
        self.onHoverChanged = onHoverChanged
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
    }

    var body: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let isDark = colorScheme == .dark
        let statusColor = compactQuotaStatusColor

        VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    ToolAppIcon(tool: .antigravity, size: 16)
                    ZStack {
                        Circle()
                            .fill(statusColor.opacity(0.24))
                            .frame(width: 12, height: 12)
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                    }
                    .help(compactStatusHelp)

                }
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleExpanded()
                }

                Spacer(minLength: 4)

                AntigravityCompactQuotaSummary(
                    state: state,
                    onToggleMode: {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                            state.toggleQuotaDisplayMode()
                        }
                    }
                )
                .layoutPriority(1)

                Button {
                    toggleExpanded()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8.5, weight: .black))
                        .foregroundStyle(cyan)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.text("展开或收起详情", "Show or hide quota details"))
            }

            if isExpanded {
                Divider()
                    .opacity(isDark ? 0.25 : 0.4)
                AntigravityQuotaRowsView(
                    state: state,
                    activityProfile: toolTracker.foregroundAntigravityProfile
                )
            }
        }
        .padding(.horizontal, isExpanded ? 12 : 10)
        .padding(.vertical, isExpanded ? 10 : 6)
        .background(
            isDark
                ? Color(red: 0.08, green: 0.10, blue: 0.16).opacity(0.94)
                : Color.white.opacity(0.96),
            in: RoundedRectangle(cornerRadius: isExpanded ? 14 : 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: isExpanded ? 14 : 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            cyan.opacity(isDark ? 0.60 : 0.45),
                            AppTheme.accentPurple(for: colorScheme).opacity(isDark ? 0.34 : 0.22),
                            cyan.opacity(isDark ? 0.45 : 0.34)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(isDark ? 0.44 : 0.18), radius: 6, y: 2)
        .padding(10)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { _ in onDragChanged() }
                .onEnded { _ in onDragEnded() }
        )
        .onHover(perform: onHoverChanged)
        .onDisappear { onHoverChanged(false) }
        .animation(
            reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82),
            value: isExpanded
        )
        .preferredColorScheme(state.colorScheme)
    }

    private func toggleExpanded() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82)) {
            isExpanded.toggle()
        }
        onToggleExpand(isExpanded, true)
    }

    private var compactQuotaStatusColor: Color {
        if let insight = state.primaryAntigravityQuotaInsight {
            if insight.freshness == .stale || insight.risk == .critical {
                return AppTheme.accentRose(for: colorScheme)
            }
            if insight.freshness == .delayed || insight.risk == .warning {
                return AppTheme.accentAmber(for: colorScheme)
            }
        }
        guard let remaining = state.latestAntigravityQuota?
            .orderedCompactFiveHourBuckets
            .map(\.bucket.remainingPercent)
            .min() else {
            return AppTheme.textSecondary(for: colorScheme)
        }
        if remaining <= 15 { return AppTheme.accentRose(for: colorScheme) }
        if remaining <= 35 { return AppTheme.accentAmber(for: colorScheme) }
        return AppTheme.accentEmerald(for: colorScheme)
    }

    private var compactStatusHelp: String {
        guard let insight = state.primaryAntigravityQuotaInsight else {
            return state.antigravityDataFreshness.localizedTitle
        }
        return "\(insight.freshness.localizedTitle) · \(insight.risk.localizedTitle)"
    }
}

private struct AntigravityOverlayDetailsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var toolTracker: FrontmostToolTracker
    let onHoverChanged: (Bool) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let isDark = colorScheme == .dark

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                ToolAppIcon(tool: .antigravity, size: 16)
                Text(toolTracker.foregroundAntigravityProfile?.displayName ?? "Antigravity")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                Spacer()
                AntigravityCompactQuotaSummary(state: state)
            }

            AntigravityQuotaRowsView(
                state: state,
                activityProfile: toolTracker.foregroundAntigravityProfile
            )
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
                        colors: [
                            cyan.opacity(isDark ? 0.60 : 0.45),
                            AppTheme.accentPurple(for: colorScheme).opacity(isDark ? 0.34 : 0.22),
                            cyan.opacity(isDark ? 0.45 : 0.34)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(isDark ? 0.44 : 0.18), radius: 6, y: 2)
        .padding(10)
        .contentShape(Rectangle())
        .onHover(perform: onHoverChanged)
        .onDisappear { onHoverChanged(false) }
        .preferredColorScheme(state.colorScheme)
    }

}

private struct AntigravityQuotaRowsView: View {
    @ObservedObject var state: AppState
    let activityProfile: AntigravityStateProfile?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !state.antigravityQuotaInsights.isEmpty {
                ForEach(Array(state.antigravityQuotaInsights.prefix(4))) { insight in
                    quotaInsightRow(insight)
                }
                if state.antigravityQuotaInsights.count > 4 {
                    Text(L10n.format(
                        "%d more quota pools are available in the main window",
                        zhHans: "主窗口中还有 %d 个额度池",
                        state.antigravityQuotaInsights.count - 4
                    ))
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }
            } else if let quota = state.latestAntigravityQuota, quota.hasQuota {
                ForEach(quota.orderedDisplayBuckets.filter {
                    $0.bucket.window == .fiveHour || $0.bucket.window == .weekly
                }.prefix(4)) { item in
                    quotaRow(groupTitle: item.groupTitle, bucket: item.bucket)
                }
            } else {
                Text(state.antigravityQuotaErrorText ?? L10n.text(
                    "等待额度同步",
                    "Waiting for quota sync"
                ))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                .lineLimit(2)
            }

            Divider().opacity(0.35)

            syncAndActivitySummary

            if let recommendation = state.primaryRecommendation(for: .antigravity) {
                Label(recommendation.title, systemImage: recommendation.severity.symbolName)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(recommendationTint(recommendation.severity))
                    .lineLimit(2)
                    .help(recommendation.message)
            }

            if let activity = state.antigravityActivitySnapshot(for: activityProfile) {
                Text(activity.latestActivityAt.map {
                    L10n.format(
                        "Last activity %@",
                        zhHans: "最后活动 %@",
                        UsageNumberFormatter.relativeTimeString(from: $0)
                    )
                } ?? L10n.text("尚未发现本机活动", "No local activity found"))
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                .lineLimit(1)
            }

            if let message = state.antigravityQuotaErrorText,
               state.latestAntigravityQuota?.hasQuota == true {
                Text(message)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    .lineLimit(1)
            }
        }
    }

    private func quotaInsightRow(_ insight: ProviderQuotaInsight) -> some View {
        let shown = state.quotaDisplayMode == .used
            ? insight.input.usedPercent
            : insight.remainingPercent
        let tint = insightTint(insight)

        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label(
                    "\(AntigravityQuotaSnapshot.groupDisplayTitle(for: insight.input.groupTitle)) · \(insight.input.windowTitle)",
                    systemImage: insight.risk == .critical
                        ? "exclamationmark.triangle.fill"
                        : insight.freshness.symbolName
                )
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                Spacer()
                Text(UsageNumberFormatter.percent(shown, maximumFractionDigits: 0))
                    .foregroundStyle(tint)
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))

            HStack(spacing: 5) {
                Text(rateText(insight))
                Text("·")
                Text(forecastText(insight))
                Spacer(minLength: 4)
                if let reset = insight.input.resetAt {
                    Text(L10n.format(
                        "Reset %@",
                        zhHans: "%@重置",
                        UsageNumberFormatter.relativeTimeString(from: reset)
                    ))
                }
            }
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            .lineLimit(1)

            AdaptiveQuotaProgress(value: shown / 100, tint: tint)
        }
        .accessibilityElement(children: .combine)
    }

    private var syncAndActivitySummary: some View {
        let freshness = state.antigravityDataFreshness
        let last = state.antigravitySyncState.lastSuccessAt ?? state.latestAntigravityQuota?.capturedAt
        let next = state.antigravitySyncState.cooldownUntil
            ?? state.antigravitySyncState.nextAttemptAt
            ?? last?.addingTimeInterval(TimeInterval(state.antigravityRefreshIntervalSeconds))
        let activity = state.antigravityActivitySnapshot(for: activityProfile)?.sevenDayMetrics

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(freshness.localizedTitle, systemImage: freshness.symbolName)
                    .foregroundStyle(freshnessTint(freshness))
                Spacer()
                Text(L10n.format(
                    "%d tasks · %@ steps",
                    zhHans: "%d 个任务 · %@ 步",
                    activity?.taskCount ?? 0,
                    UsageNumberFormatter.compactTokenCount(activity?.stepCount ?? 0)
                ))
                    .foregroundStyle(AppTheme.accentCyan(for: colorScheme))
            }
            HStack {
                Text(last.map {
                    L10n.format("Last %@", zhHans: "上次 %@", UsageNumberFormatter.relativeTimeString(from: $0))
                } ?? L10n.text("尚未成功同步", "No successful sync"))
                Spacer()
                if let next {
                    Text(L10n.format("Next %@", zhHans: "下次 %@", UsageNumberFormatter.relativeTimeString(from: next)))
                }
            }
            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
        }
        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
    }

    private func quotaRow(
        groupTitle: String,
        bucket: AntigravityQuotaSnapshot.Bucket
    ) -> some View {
        let shown = state.quotaDisplayMode == .used
            ? 100 - bucket.remainingPercent
            : bucket.remainingPercent
        let tint: Color = bucket.remainingPercent <= 15
            ? AppTheme.accentRose(for: colorScheme)
            : (bucket.remainingPercent <= 35
                ? AppTheme.accentAmber(for: colorScheme)
                : AppTheme.accentEmerald(for: colorScheme))

        return VStack(spacing: 3) {
            HStack {
                Text("\(AntigravityQuotaSnapshot.groupDisplayTitle(for: groupTitle)) · \(bucket.window.localizedTitle)")
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                Spacer()
                Text(UsageNumberFormatter.percent(shown, maximumFractionDigits: 0))
                    .foregroundStyle(tint)
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            AdaptiveQuotaProgress(value: shown / 100, tint: tint)
        }
    }

    private func rateText(_ insight: ProviderQuotaInsight) -> String {
        guard insight.hasUsableForecast else { return L10n.text("正在积累数据", "Collecting data") }
        return String(format: "%.2f %@", insight.burnRateForDisplay, insight.rateUnitTitle)
    }

    private func forecastText(_ insight: ProviderQuotaInsight) -> String {
        guard insight.hasUsableForecast else { return L10n.text("预测待积累", "Forecast pending") }
        if insight.risk == .critical, let exhaustion = insight.forecast.estimatedExhaustionDate {
            return L10n.format(
                "Runs out %@",
                zhHans: "%@耗尽",
                UsageNumberFormatter.relativeTimeString(from: exhaustion)
            )
        }
        guard let remaining = insight.forecast.projectedRemainingAtReset else {
            return L10n.text("预测待积累", "Forecast pending")
        }
        return L10n.format(
            "%@ left at reset",
            zhHans: "重置时剩余 %@",
            UsageNumberFormatter.percent(remaining, maximumFractionDigits: 0)
        )
    }

    private func insightTint(_ insight: ProviderQuotaInsight) -> Color {
        if insight.freshness == .stale || insight.risk == .critical {
            return AppTheme.accentRose(for: colorScheme)
        }
        if insight.freshness == .delayed || insight.risk == .warning {
            return AppTheme.accentAmber(for: colorScheme)
        }
        return AppTheme.accentEmerald(for: colorScheme)
    }

    private func freshnessTint(_ freshness: ProviderDataFreshness) -> Color {
        switch freshness {
        case .fresh: return AppTheme.accentEmerald(for: colorScheme)
        case .delayed: return AppTheme.accentAmber(for: colorScheme)
        case .stale: return AppTheme.accentRose(for: colorScheme)
        case .unknown: return AppTheme.textSecondary(for: colorScheme)
        }
    }

    private func recommendationTint(_ severity: QuotaRecommendationSeverity) -> Color {
        switch severity {
        case .critical: return AppTheme.accentRose(for: colorScheme)
        case .warning: return AppTheme.accentAmber(for: colorScheme)
        case .information: return AppTheme.accentCyan(for: colorScheme)
        case .healthy: return AppTheme.accentEmerald(for: colorScheme)
        }
    }
}

private struct AdaptiveQuotaProgress: View {
    let value: Double
    let tint: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(AppTheme.insetBorder(for: colorScheme).opacity(colorScheme == .dark ? 0.9 : 0.72))
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 6)
    }
}
