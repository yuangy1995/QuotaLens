// QuotaLens 科技风全息主界面与侧边栏框架 (Dual Theme Navigation Frame)

import SwiftUI
import AppKit

public struct MainView: View {
    @ObservedObject var state: AppState
    @ObservedObject var enabledTools: EnabledToolsStore
    @ObservedObject var navigation: AppNavigationStore
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.colorScheme) var colorScheme
    @State private var isContextSwitcherPresented = false

    public init(
        state: AppState,
        enabledTools: EnabledToolsStore,
        navigation: AppNavigationStore
    ) {
        self.state = state
        self.enabledTools = enabledTools
        self.navigation = navigation
    }

    public var body: some View {
        let isDark = colorScheme == .dark
        let cyan = AppTheme.accentCyan(for: colorScheme)

        HStack(spacing: 0) {
            VStack(spacing: 0) {
                // 顶部当前账户全息身份芯片（高度与右侧 topChromeBar 64pt 严格平齐）
                sidebarIdentityCard
                    .frame(height: 64)

                CyberDivider(glowColor: isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.07))

                if enabledTools.enabledToolIDs.count >= 2 {
                    contextSwitcher
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                }

                VStack(spacing: 6) {
                    if enabledTools.enabledToolIDs.isEmpty {
                        SidebarNavigationRow(
                            title: L10n.text("开始使用", "Get Started"),
                            icon: "plus.circle.fill",
                            isSelected: navigation.fixedDestination == nil,
                            colorScheme: colorScheme,
                            onSelect: { navigation.selectContext(.overview) }
                        )
                    } else if navigation.selectedContext == .overview {
                        SidebarNavigationRow(
                            title: L10n.text("运营总览", "Operations Overview"),
                            icon: "square.grid.2x2.fill",
                            isSelected: navigation.fixedDestination == nil,
                            colorScheme: colorScheme,
                            onSelect: { navigation.selectContext(.overview) }
                        )
                    } else if case .tool(let toolID) = navigation.selectedContext {
                        ForEach(availablePages(for: toolID)) { page in
                            SidebarNavigationRow(
                                title: page.title,
                                icon: page.icon,
                                isSelected: navigation.fixedDestination == nil
                                    && navigation.selectedPage(for: toolID) == page,
                                colorScheme: colorScheme,
                                onSelect: { navigation.selectToolPage(page, for: toolID) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)

                Spacer()

                VStack(spacing: 6) {
                    ForEach([FixedNavigationDestination.appSettings, .about], id: \.rawValue) { destination in
                        SidebarNavigationRow(
                            title: destination.title,
                            icon: destination.icon,
                            isSelected: navigation.fixedDestination == destination,
                            colorScheme: colorScheme,
                            onSelect: { navigation.showFixedDestination(destination) }
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

                sidebarBottomHUDDock
            }
            .frame(width: 248)
            .background(
                AppTheme.sidebarGradient(for: colorScheme)
            )

            Rectangle()
                .fill(isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.06))
                .frame(width: 1)

            VStack(spacing: 0) {
                topChromeBar

                if isCurrentContextScanning {
                    mainScanProgressStrip
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let warning = state.appInitializationWarningText {
                    storageInitializationWarningStrip(warning)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let warning = state.antigravityActivityWarningText,
                   navigation.selectedContext == .overview || navigation.selectedContext == .tool(.antigravity) {
                    storageInitializationWarningStrip(warning)
                }

                ZStack {
                    // 环境自适应背景画布
                    AppTheme.canvasGradient(for: colorScheme)
                        .ignoresSafeArea()

                    currentContent
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: 560,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
        .tint(cyan)
        .preferredColorScheme(state.colorScheme)
        .environment(\.controlActiveState, .key)
        .background(StableWindowConfigurator())
        .overlay {
            UpdateCheckOverlay(updateManager: env.updateManager)
        }
        .onAppear {
            navigation.normalize(
                enabledTools: enabledTools.enabledToolIDs,
                activeTool: env.frontmostToolTracker.foregroundTool
            )
        }
        .onChange(of: enabledTools.enabledToolIDs) { _, enabled in
            navigation.normalize(
                enabledTools: enabled,
                activeTool: env.frontmostToolTracker.foregroundTool
            )
        }
    }

    @ViewBuilder
    private var currentContent: some View {
        if let fixed = navigation.fixedDestination {
            switch fixed {
            case .appSettings:
                GlobalSettingsView(state: state)
            case .about:
                AboutView(state: state, updateManager: env.updateManager)
            }
        } else if enabledTools.enabledToolIDs.isEmpty {
            MonitoringSetupView()
        } else {
            switch navigation.selectedContext {
            case .overview:
                OverviewDashboardView(state: state, facade: env.usageQueryFacade) { tool in
                    navigation.selectContext(.tool(tool))
                }
            case .tool(let toolID):
                toolContent(toolID)
            }
        }
    }

    @ViewBuilder
    private func toolContent(_ toolID: MonitoringToolID) -> some View {
        switch (toolID, navigation.selectedPage(for: toolID)) {
        case (.codex, .quota):
            CodexOverviewView(state: state)
        case (.codex, .usage):
            CodexUsageDashboardView(facade: env.usageQueryFacade)
        case (.codex, .history):
            CodexHistoryView(facade: env.usageQueryFacade)
        case (.codex, .sessions):
            CodexSessionsView(facade: env.usageQueryFacade)
        case (.codex, .resetCards):
            ResetCardsView(state: state)
        case (.codex, .settings):
            CodexSettingsView(state: state)
        case (.claude, .quota):
            ClaudeOverviewView(state: state, facade: env.usageQueryFacade)
        case (.claude, .usage):
            ClaudeUsageDashboardView(facade: env.usageQueryFacade)
        case (.claude, .history):
            ClaudeHistoryView(facade: env.usageQueryFacade)
        case (.claude, .sessions):
            ClaudeSessionsView(facade: env.usageQueryFacade)
        case (.claude, .settings):
            ClaudeSettingsView(state: state)
        case (.antigravity, .quota):
            AntigravityOverviewView(state: state)
        case (.antigravity, .usage):
            AntigravityUsageDashboardView(facade: env.usageQueryFacade)
        case (.antigravity, .sessions):
            AntigravitySessionsView(facade: env.usageQueryFacade)
        case (.antigravity, .settings):
            AntigravitySettingsView(state: state)
        default:
            MonitoringSetupView()
        }
    }

    private var currentPageTitle: String {
        if let fixed = navigation.fixedDestination {
            return fixed.title
        }
        switch navigation.selectedContext {
        case .overview:
            return enabledTools.enabledToolIDs.isEmpty
                ? L10n.text("设置监控工具", "Set Up Monitoring")
                : L10n.text("运营总览", "Operations Overview")
        case .tool(let tool):
            return navigation.selectedPage(for: tool).title
        }
    }

    private func availablePages(for toolID: MonitoringToolID) -> [ToolPage] {
        guard let descriptor = ToolRegistry.shared.descriptor(for: toolID) else { return [] }
        return ToolPage.allCases.filter { descriptor.capabilities.contains($0.capability) }
    }

    private var isCurrentContextScanning: Bool {
        switch navigation.selectedContext {
        case .overview:
            return env.scanCoordinator.isScanning
                || env.claudeScanCoordinator.isScanning
                || env.antigravityActivityCoordinator.isScanning
        case .tool(.codex):
            return env.scanCoordinator.isScanning
        case .tool(.claude):
            return env.claudeScanCoordinator.isScanning
        case .tool(.antigravity):
            return env.antigravityActivityCoordinator.isScanning
        case .tool:
            return false
        }
    }

    private var currentScanProgress: Double? {
        switch navigation.selectedContext {
        case .tool(.claude): return nil
        case .tool(.antigravity): return nil
        case .overview where env.claudeScanCoordinator.isScanning && !env.scanCoordinator.isScanning:
            return nil
        case .overview where env.antigravityActivityCoordinator.isScanning
            && !env.scanCoordinator.isScanning
            && !env.claudeScanCoordinator.isScanning:
            return nil
        default:
            return env.scanCoordinator.progress
        }
    }

    private var currentScanStatusText: String {
        switch navigation.selectedContext {
        case .tool(.claude): return env.claudeScanCoordinator.statusText
        case .tool(.antigravity): return env.antigravityActivityCoordinator.statusText
        case .overview where env.claudeScanCoordinator.isScanning && !env.scanCoordinator.isScanning:
            return env.claudeScanCoordinator.statusText
        case .overview where env.antigravityActivityCoordinator.isScanning
            && !env.scanCoordinator.isScanning
            && !env.claudeScanCoordinator.isScanning:
            return env.antigravityActivityCoordinator.statusText
        default:
            return env.scanCoordinator.statusText
        }
    }

    private func refreshCurrentContext() async {
        switch navigation.selectedContext {
        case .overview:
            await env.refreshAllData()
        case .tool(let tool):
            await env.refreshMonitoringTool(tool)
        }
    }

    private var contextSwitcher: some View {
        Button {
            isContextSwitcherPresented.toggle()
        } label: {
            HStack(spacing: 9) {
                contextIcon(size: 24)
                Text(currentContextDescriptor?.displayName ?? L10n.text("总览", "Overview"))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                Spacer()
                Image(systemName: isContextSwitcherPresented ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .popover(
            isPresented: $isContextSwitcherPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            ContextSwitcherPopover(
                selectedContext: navigation.selectedContext,
                descriptors: enabledTools.enabledDescriptors,
                onSelect: { context in
                    navigation.selectContext(context)
                    isContextSwitcherPresented = false
                }
            )
        }
        .accessibilityLabel(L10n.text("切换工具空间", "Switch Tool Space"))
    }

    @ViewBuilder
    private func contextIcon(size: CGFloat) -> some View {
        if let descriptor = currentContextDescriptor {
            ToolAppIcon(tool: descriptor.id, size: size)
        } else {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: size * 0.55, weight: .bold))
                .foregroundStyle(AppTheme.accentCyan(for: colorScheme))
                .frame(width: size, height: size)
        }
    }

    private var currentContextDescriptor: MonitoringToolDescriptor? {
        guard case .tool(let tool) = navigation.selectedContext else { return nil }
        return ToolRegistry.shared.descriptor(for: tool)
    }

    private var topChromeBar: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let isDark = colorScheme == .dark

        return HStack(spacing: 12) {
            Text(currentPageTitle)
                .font(.system(size: 16, weight: .black, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

            Spacer()

            Button(action: {
                Task {
                    await refreshCurrentContext()
                }
            }) {
                ZStack {
                    Circle()
                        .fill(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                        .frame(width: 34, height: 34)
                        .overlay(
                            Circle()
                                .strokeBorder(isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.09), lineWidth: 0.8)
                        )

                    if isCurrentContextScanning || state.isRefreshing || state.isRefreshingClaudeUsage {
                        ProgressView()
                            .controlSize(.small)
                            .tint(cyan)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(cyan)
                    }
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .help(L10n.text("立即刷新数据", "Refresh data now"))
            .disabled(state.isRefreshing || state.isRefreshingClaudeUsage || isCurrentContextScanning)
        }
        .frame(height: 64)
        .padding(.horizontal, 28)
        .background(
            (isDark ? Color(red: 0.065, green: 0.08, blue: 0.13).opacity(0.98) : Color(red: 0.965, green: 0.98, blue: 0.995).opacity(0.96))
                .ignoresSafeArea(edges: .top)
        )
        .overlay(alignment: .bottom) {
            CyberDivider(glowColor: isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.07))
        }
    }

    private var mainScanProgressStrip: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let isDark = colorScheme == .dark
        let progress = currentScanProgress

        return VStack(spacing: 8) {
            HStack(spacing: 9) {
                CyberScanIndicator(size: 20, accentColor: cyan)

                Text(L10n.text("正在扫描本地记录", "Scanning local history"))
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                if !currentScanStatusText.isEmpty {
                    Text(currentScanStatusText)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if let progress {
                    Text(UsageNumberFormatter.percent(progress * 100.0, maximumFractionDigits: 0))
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .foregroundStyle(cyan)
                        .monospacedDigit()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(cyan.opacity(isDark ? 0.16 : 0.10), in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(cyan.opacity(isDark ? 0.38 : 0.26), lineWidth: 0.8)
                        )
                }
            }

            CyberProgressBar(value: progress, height: 4.5, accentColor: cyan)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 9)
        .background(
            (isDark
                ? Color(red: 0.055, green: 0.07, blue: 0.12).opacity(0.96)
                : Color(red: 0.95, green: 0.965, blue: 0.985).opacity(0.96))
        )
        .overlay(alignment: .bottom) {
            CyberDivider(glowColor: cyan.opacity(isDark ? 0.28 : 0.18))
        }
    }

    private func storageInitializationWarningStrip(_ warning: String) -> some View {
        let amber = AppTheme.accentAmber(for: colorScheme)
        let isDark = colorScheme == .dark

        return HStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(amber)

            Text(warning)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                .lineLimit(2)

            Spacer(minLength: 8)

            Button(L10n.text("查看设置", "Open Settings")) {
                navigation.showFixedDestination(.appSettings)
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .bold, design: .rounded))
            .foregroundStyle(amber)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 8)
        .background(amber.opacity(isDark ? 0.12 : 0.09))
        .overlay(alignment: .bottom) {
            CyberDivider(glowColor: amber.opacity(0.22))
        }
    }

    // MARK: - 侧边栏当前账户全息芯片
    private var sidebarIdentityCard: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let purple = AppTheme.accentPurple(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)
        let isDark = colorScheme == .dark

        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [cyan, purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                    )
                    .shadow(color: cyan.opacity(isDark ? 0.4 : 0.2), radius: 5)

                if currentContextDescriptor != nil {
                    contextIcon(size: 22)
                } else {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(sidebarPrimaryTitle)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(sidebarSecondaryTitle.uppercased())
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(cyan.opacity(isDark ? 0.15 : 0.12), in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(cyan.opacity(0.35), lineWidth: 0.6)
                        )
                        .foregroundStyle(cyan)

                    ZStack {
                        Circle()
                            .fill((currentContextIsConnected ? emerald : Color.gray).opacity(0.3))
                            .frame(width: 8, height: 8)
                            .blur(radius: 1.5)

                        Circle()
                            .fill(currentContextIsConnected ? emerald : Color.gray.opacity(0.6))
                            .frame(width: 5, height: 5)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            isDark ? Color(red: 0.105, green: 0.135, blue: 0.215).opacity(0.72) : Color.white.opacity(0.85),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.08), lineWidth: 0.8)
        )
        .padding(.horizontal, 14)
    }

    private var sidebarPrimaryTitle: String {
        switch navigation.selectedContext {
        case .overview:
            return L10n.text("所有监控工具", "All Monitored Tools")
        case .tool(.codex):
            return state.displayName(for: state.account?.accountKey)
        case .tool(.claude):
            return "Claude"
        case .tool(.antigravity):
            return state.latestAntigravityQuota?.accountDisplayName ?? "Antigravity"
        case .tool(let id):
            return ToolRegistry.shared.descriptor(for: id)?.displayName ?? "QuotaLens"
        }
    }

    private var sidebarSecondaryTitle: String {
        switch navigation.selectedContext {
        case .overview:
            return L10n.format("%d tools enabled", zhHans: "已启用 %d 个工具", enabledTools.enabledToolIDs.count)
        case .tool(.codex):
            return state.subscriptionPlanTitle
        case .tool(.claude):
            return state.latestClaudeUsage?.tier ?? L10n.text("等待同步", "Waiting for Sync")
        case .tool(.antigravity):
            return state.latestAntigravityQuota?.planName ?? L10n.text("等待同步", "Waiting for Sync")
        case .tool:
            return L10n.text("监控中", "Monitoring")
        }
    }

    private var currentContextIsConnected: Bool {
        switch navigation.selectedContext {
        case .overview:
            return (enabledTools.enabledToolIDs.contains(.codex) && state.connectionStatus.isConnected)
                || (enabledTools.enabledToolIDs.contains(.claude) && state.latestClaudeUsage?.hasQuota == true)
        case .tool(.codex):
            return state.connectionStatus.isConnected
        case .tool(.claude):
            return state.latestClaudeUsage?.hasQuota == true
        case .tool(.antigravity):
            return state.antigravityHasQuota
        case .tool:
            return false
        }
    }

    // MARK: - 侧边栏底座状态指示坞
    private var sidebarBottomHUDDock: some View {
        let emerald = AppTheme.accentEmerald(for: colorScheme)
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let isDark = colorScheme == .dark

        return VStack(spacing: 6) {
            CyberDivider(glowColor: isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                .padding(.horizontal, 14)

            HStack {
                HStack(spacing: 5) {
                    Circle()
                        .fill(currentContextIsConnected ? emerald : AppTheme.textSecondary(for: colorScheme))
                        .frame(width: 5, height: 5)

                    Text(currentContextIsConnected ? L10n.text("已连接", "Connected") : L10n.text("等待同步", "Waiting for Sync"))
                        .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                        .foregroundStyle(currentContextIsConnected ? emerald : AppTheme.textSecondary(for: colorScheme))
                }

                Spacer()

                HStack(spacing: 4) {
                    Text("QuotaLens")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary(for: colorScheme).opacity(0.85))

                    Text(AppVersion.displayString)
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(cyan)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }
}

private struct UpdateCheckOverlay: View {
    @ObservedObject var updateManager: UpdateManager
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        if let dialog = updateManager.updateDialog {
            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(colorScheme == .dark ? 0.52 : 0.28))
                    .ignoresSafeArea()

                UpdateCheckDialog(
                    dialog: dialog,
                    colorScheme: colorScheme,
                    onPrimary: {
                        updateManager.performUpdateDialogPrimaryAction()
                    },
                    onSecondary: {
                        updateManager.performUpdateDialogSecondaryAction()
                    }
                )
                .frame(width: dialog.newVersion != nil || dialog.releaseNotes != nil ? 460 : 360)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: dialog.id)
        }
    }
}

private struct UpdateCheckDialog: View {
    let dialog: UpdateDialogState
    let colorScheme: ColorScheme
    let onPrimary: () -> Void
    let onSecondary: () -> Void
    @State private var isAnimating = false

    var body: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let blue = AppTheme.accentBlue(for: colorScheme)
        let purple = AppTheme.accentPurple(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)
        let isDark = colorScheme == .dark

        VStack(alignment: .leading, spacing: 16) {
            // 头部：图标 + 标题 + 版本与包大小胶囊
                HStack(alignment: .center, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(iconBackgroundColor.opacity(isDark ? 0.18 : 0.12))
                            .frame(width: 52, height: 52)
                            .overlay(
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .strokeBorder(iconBackgroundColor.opacity(isDark ? 0.35 : 0.25), lineWidth: 0.8)
                            )

                        if dialog.kind == .checking {
                            // 科技感双层旋转光环
                            Circle()
                                .trim(from: 0.1, to: 0.85)
                                .stroke(
                                    AngularGradient(
                                        colors: [cyan.opacity(0.2), cyan, blue],
                                        center: .center
                                    ),
                                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                                )
                                .frame(width: 34, height: 34)
                                .rotationEffect(.degrees(isAnimating ? 360 : 0))
                                .animation(.linear(duration: 1.0).repeatForever(autoreverses: false), value: isAnimating)

                            Circle()
                                .trim(from: 0.2, to: 0.7)
                                .stroke(
                                    purple.opacity(0.7),
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                                )
                                .frame(width: 22, height: 22)
                                .rotationEffect(.degrees(isAnimating ? -360 : 0))
                                .animation(.linear(duration: 1.5).repeatForever(autoreverses: false), value: isAnimating)
                        } else {
                            Image(systemName: iconName)
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(iconBackgroundColor)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(dialog.title)
                            .font(.system(size: 17, weight: .black, design: .rounded))
                            .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                        // 版本对比与体积徽章
                        if let newVer = dialog.newVersion {
                            HStack(spacing: 6) {
                                HStack(spacing: 4) {
                                    if let curVer = dialog.currentVersion {
                                        Text("v\(curVer)")
                                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                                        Image(systemName: "arrow.right")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(cyan)
                                    }
                                    Text("v\(newVer)")
                                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                        .foregroundStyle(cyan)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(cyan.opacity(isDark ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 5))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .strokeBorder(cyan.opacity(isDark ? 0.40 : 0.25), lineWidth: 0.7)
                                )

                                if let bytes = dialog.packageSizeBytes {
                                    HStack(spacing: 3) {
                                        Image(systemName: "shippingbox.fill")
                                            .font(.system(size: 9))
                                        Text(formattedByteSize(bytes))
                                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                    }
                                    .foregroundStyle(emerald)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(emerald.opacity(isDark ? 0.15 : 0.10), in: RoundedRectangle(cornerRadius: 5))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5)
                                            .strokeBorder(emerald.opacity(isDark ? 0.40 : 0.25), lineWidth: 0.7)
                                    )
                                }
                            }
                            .padding(.top, 2)
                        } else if dialog.kind != .progress && dialog.kind != .installing && dialog.progress == nil {
                            Text(dialog.message)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                                .lineLimit(2)
                        }
                    }

                    Spacer(minLength: 0)
                }

                // 核心内容区：更新日志或进度条
                if dialog.kind == .available {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(cyan)
                            Text(L10n.text("更新内容与亮点", "Release Notes & Improvements"))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                            Spacer()
                        }

                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 6) {
                                let lines = parsedReleaseNotes(dialog.releaseNotes ?? dialog.message)
                                ForEach(lines, id: \.self) { line in
                                    HStack(alignment: .top, spacing: 6) {
                                        Text("•")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(cyan)
                                        Text(L10n.localizeChangelogText(line))
                                            .font(.system(size: 11.5, weight: .medium))
                                            .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .padding(10)
                        }
                        .frame(maxHeight: 140)
                        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
                        )
                    }
                } else if dialog.kind == .progress || dialog.kind == .installing || dialog.progress != nil {
                    let currentProgress = dialog.progress ?? 0.0
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(dialog.message)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                            Spacer()
                            Text("\(Int(currentProgress * 100))%")
                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(cyan)
                        }

                        CyberProgressBar(value: max(0.0, min(1.0, currentProgress)), height: 5, accentColor: cyan)
                    }
                    .padding(12)
                    .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
                    )
                }

                // 底部按钮栏
                HStack(spacing: 10) {
                    if let secondary = dialog.secondaryButtonTitle {
                        Button(action: onSecondary) {
                            Text(secondary)
                                .font(.system(size: 12, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
                                )
                                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                        }
                        .buttonStyle(.plain)
                        .disabled(dialog.kind == .checking)
                    }

                    Button(action: onPrimary) {
                        HStack(spacing: 6) {
                            if dialog.kind == .available {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            Text(dialog.primaryButtonTitle)
                                .font(.system(size: 12, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            dialog.kind == .checking
                                ? AnyShapeStyle(AppTheme.insetSurface(for: colorScheme))
                                : AnyShapeStyle(LinearGradient(
                                    colors: [cyan, blue],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .foregroundStyle(dialog.kind == .checking ? AppTheme.textSecondary(for: colorScheme) : Color.white)
                        .shadow(color: dialog.kind == .available ? cyan.opacity(0.35) : Color.clear, radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .disabled(!dialog.primaryButtonEnabled)
                }
                .padding(.top, 4)
            }
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isDark ? Color(red: 0.08, green: 0.095, blue: 0.14) : Color(red: 0.98, green: 0.985, blue: 1.0))
            )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(cyan.opacity(isDark ? 0.35 : 0.22), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isDark ? 0.55 : 0.20), radius: 32, x: 0, y: 16)
        .onAppear {
            isAnimating = true
        }
    }

    private func formattedByteSize(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func parsedReleaseNotes(_ text: String) -> [String] {
        let rawLines = text.components(separatedBy: .newlines)
        var result: [String] = []
        for line in rawLines {
            var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                trimmed = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !trimmed.isEmpty {
                result.append(trimmed)
            }
        }
        return result.isEmpty ? [text] : result
    }

    private var iconName: String {
        switch dialog.kind {
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .available:
            return "arrow.down.circle.fill"
        case .latest:
            return "checkmark.seal.fill"
        case .failure:
            return "exclamationmark.triangle.fill"
        case .progress:
            return "arrow.down.circle.fill"
        case .ready:
            return "restart.circle.fill"
        case .installing:
            return "shippingbox.circle.fill"
        }
    }

    private var iconBackgroundColor: Color {
        switch dialog.kind {
        case .checking:
            return AppTheme.accentCyan(for: colorScheme)
        case .available:
            return AppTheme.accentCyan(for: colorScheme)
        case .latest:
            return AppTheme.accentEmerald(for: colorScheme)
        case .failure:
            return AppTheme.accentAmber(for: colorScheme)
        case .progress:
            return AppTheme.accentCyan(for: colorScheme)
        case .ready:
            return AppTheme.accentEmerald(for: colorScheme)
        case .installing:
            return AppTheme.accentPurple(for: colorScheme)
        }
    }
}

private struct ContextSwitcherPopover: View {
    let selectedContext: AppContext
    let descriptors: [MonitoringToolDescriptor]
    let onSelect: (AppContext) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let isDark = colorScheme == .dark

        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("切换工作空间", "Switch Workspace"))
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                .padding(.horizontal, 8)
                .padding(.bottom, 2)

            contextRow(
                title: L10n.text("总览", "Overview"),
                context: .overview,
                icon: "square.grid.2x2.fill"
            )

            Divider()
                .opacity(isDark ? 0.28 : 0.55)
                .padding(.vertical, 2)

            ForEach(descriptors) { descriptor in
                contextRow(
                    title: descriptor.displayName,
                    context: .tool(descriptor.id),
                    tool: descriptor.id,
                    icon: descriptor.systemImage
                )
            }
        }
        .padding(10)
        .frame(width: 212)
        .background(AppTheme.popoverGradient(for: colorScheme))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(cyan.opacity(isDark ? 0.35 : 0.24), lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Color.black.opacity(isDark ? 0.42 : 0.18), radius: 14, y: 5)
        .tint(cyan)
        .preferredColorScheme(colorScheme)
    }

    @ViewBuilder
    private func contextRow(
        title: String,
        context: AppContext,
        tool: MonitoringToolID? = nil,
        icon: String
    ) -> some View {
        let isSelected = selectedContext == context
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let blue = AppTheme.accentBlue(for: colorScheme)
        let isDark = colorScheme == .dark

        Button {
            onSelect(context)
        } label: {
            HStack(spacing: 10) {
                if let tool {
                    ToolAppIcon(tool: tool, size: 22)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(isSelected ? Color.white : cyan)
                        .frame(width: 22, height: 22)
                }

                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .bold : .medium, design: .rounded))
                    .foregroundStyle(isSelected ? Color.white : AppTheme.textPrimary(for: colorScheme))

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(Color.white)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(
                isSelected
                    ? AnyShapeStyle(LinearGradient(colors: [cyan, blue], startPoint: .leading, endPoint: .trailing))
                    : AnyShapeStyle(isDark ? Color.white.opacity(0.035) : Color.black.opacity(0.025)),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? cyan.opacity(0.55) : AppTheme.insetBorder(for: colorScheme),
                        lineWidth: 0.7
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SidebarNavigationRow: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let colorScheme: ColorScheme
    let onSelect: () -> Void

    var body: some View {
        let isDark = colorScheme == .dark
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let blue = AppTheme.accentBlue(for: colorScheme)
        let selectedPrimary = Color.white

        Button(action: onSelect) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.18) : (isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.04)))
                        .frame(width: 26, height: 26)

                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(isSelected ? selectedPrimary : AppTheme.textSecondary(for: colorScheme))
                }

                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(isSelected ? selectedPrimary : AppTheme.textPrimary(for: colorScheme))
                    .shadow(color: isSelected ? Color.black.opacity(0.22) : Color.clear, radius: 1, x: 0, y: 1)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(LinearGradient(
                        colors: [cyan, blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )) : AnyShapeStyle(isDark ? Color.white.opacity(0.035) : Color.black.opacity(0.025)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? cyan.opacity(0.55) : (isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)), lineWidth: 0.8)
            )
            .shadow(color: isSelected ? cyan.opacity(isDark ? 0.24 : 0.12) : Color.clear, radius: 8, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct StableWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configure(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(nsView.window)
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        if window.titleVisibility != .hidden {
            window.titleVisibility = .hidden
        }
        if !window.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = true
        }
        if !window.isMovableByWindowBackground {
            window.isMovableByWindowBackground = true
        }
        if window.toolbar != nil {
            window.toolbar = nil
        }
    }
}
