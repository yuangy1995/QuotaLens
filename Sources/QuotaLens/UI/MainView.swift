// QuotaLens 科技风全息主界面与侧边栏框架 (Dual Theme Navigation Frame)

import SwiftUI
import AppKit

public enum NavigationTab: CaseIterable, Identifiable {
    case dashboard
    case usageDashboard
    case history
    case sessions
    case resetCards
    case settings
    case about

    public var id: Self { self }

    public var title: String {
        switch self {
        case .dashboard: return L10n.text("额度概览", "Overview")
        case .usageDashboard: return L10n.text("用量大盘", "Usage Dashboard")
        case .history: return L10n.text("历史记录", "History")
        case .sessions: return L10n.text("会话明细", "Sessions")
        case .resetCards: return L10n.text("重置卡", "Reset Cards")
        case .settings: return L10n.text("设置", "Settings")
        case .about: return L10n.text("关于", "About")
        }
    }

    public var icon: String {
        switch self {
        case .dashboard: return "gauge.with.needle.fill"
        case .usageDashboard: return "chart.bar.xaxis"
        case .history: return "calendar.badge.clock"
        case .sessions: return "bubble.left.and.bubble.right.fill"
        case .resetCards: return "ticket.fill"
        case .settings: return "gearshape.2.fill"
        case .about: return "info.circle.fill"
        }
    }
}

public struct MainView: View {
    @ObservedObject var state: AppState
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.colorScheme) var colorScheme
    @State private var selectedTab: NavigationTab = .dashboard

    public init(state: AppState) {
        self.state = state
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

                // 侧边栏导航列表
                VStack(spacing: 6) {
                    ForEach(NavigationTab.allCases) { tab in
                        SidebarNavigationRow(
                            tab: tab,
                            isSelected: selectedTab == tab,
                            colorScheme: colorScheme
                        ) {
                            if selectedTab != tab {
                                selectedTab = tab
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)

                Spacer()

                // 侧边栏底座状态指示坞
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

                if env.scanCoordinator.isScanning {
                    mainScanProgressStrip
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let warning = state.appInitializationWarningText {
                    storageInitializationWarningStrip(warning)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                ZStack {
                    // 环境自适应背景画布
                    AppTheme.canvasGradient(for: colorScheme)
                        .ignoresSafeArea()

                    Group {
                        switch selectedTab {
                        case .dashboard:
                            DashboardView(state: state)
                        case .usageDashboard:
                            UsageDashboardView(facade: env.usageQueryFacade)
                        case .history:
                            HistoryView(facade: env.usageQueryFacade)
                        case .sessions:
                            SessionsView(facade: env.usageQueryFacade)
                        case .resetCards:
                            ResetCardsView(state: state)
                        case .settings:
                            SettingsView(state: state)
                        case .about:
                            AboutView(state: state, updateManager: env.updateManager)
                        }
                    }
                }
                .frame(minWidth: 780, minHeight: 560)
            }
        }
        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
        .tint(cyan)
        .preferredColorScheme(state.colorScheme)
        .environment(\.controlActiveState, .key)
        .background(StableWindowConfigurator())
        .overlay {
            UpdateCheckOverlay(updateManager: env.updateManager)
        }
    }

    private var topChromeBar: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let isDark = colorScheme == .dark

        return HStack(spacing: 12) {
            Text(selectedTab.title)
                .font(.system(size: 16, weight: .black, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

            Spacer()

            Button(action: {
                Task {
                    await env.refreshAllData()
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

                    if env.scanCoordinator.isScanning || state.isRefreshing {
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
            .disabled(state.isRefreshing || env.scanCoordinator.isScanning)
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
        let progress = env.scanCoordinator.progress

        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(cyan)

                Text(L10n.text("正在扫描本地记录", "Scanning local history"))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                Text(env.scanCoordinator.statusText)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if let progress {
                    Text(UsageNumberFormatter.percent(progress * 100.0, maximumFractionDigits: 0))
                        .font(.system(size: 10.5, weight: .black, design: .monospaced))
                        .foregroundStyle(cyan)
                        .monospacedDigit()
                }
            }

            if let progress {
                ProgressView(value: progress)
                    .tint(cyan)
            } else {
                ProgressView()
                    .tint(cyan)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 8)
        .background(isDark ? Color.white.opacity(0.045) : Color.black.opacity(0.035))
        .overlay(alignment: .bottom) {
            CyberDivider(glowColor: isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.07))
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
                selectedTab = .settings
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

                Image(systemName: "person.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(state.displayName(for: state.account?.accountKey))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(state.subscriptionPlanTitle.uppercased())
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
                            .fill((state.connectionStatus.isConnected ? emerald : Color.gray).opacity(0.3))
                            .frame(width: 8, height: 8)
                            .blur(radius: 1.5)

                        Circle()
                            .fill(state.connectionStatus.isConnected ? emerald : Color.gray.opacity(0.6))
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
                        .fill(state.connectionStatus.isConnected ? emerald : AppTheme.textSecondary(for: colorScheme))
                        .frame(width: 5, height: 5)

                    Text(state.connectionStatus.isConnected ? L10n.text("已连接", "Connected") : L10n.text("未连接", "Offline"))
                        .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                        .foregroundStyle(state.connectionStatus.isConnected ? emerald : AppTheme.textSecondary(for: colorScheme))
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
                    .fill(Color.black.opacity(colorScheme == .dark ? 0.44 : 0.24))
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
                .frame(width: 340)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: dialog.id)
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
        let isDark = colorScheme == .dark

        VStack(alignment: .leading, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(iconBackgroundColor.opacity(isDark ? 0.22 : 0.14))
                    .frame(width: 62, height: 62)

                if dialog.kind == .checking {
                    Circle()
                        .trim(from: 0.12, to: 0.86)
                        .stroke(
                            AngularGradient(
                                colors: [cyan.opacity(0.2), cyan, AppTheme.accentBlue(for: colorScheme)],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .frame(width: 44, height: 44)
                        .rotationEffect(.degrees(isAnimating ? 360 : 0))
                        .animation(.linear(duration: 1.0).repeatForever(autoreverses: false), value: isAnimating)

                    Circle()
                        .fill(cyan)
                        .frame(width: 8, height: 8)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(iconBackgroundColor)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(dialog.title)
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                Text(dialog.message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)

                if let progress = dialog.progress {
                    ProgressView(value: progress)
                        .tint(cyan)
                }
            }

            HStack(spacing: 10) {
                if let secondary = dialog.secondaryButtonTitle {
                    Button(action: onSecondary) {
                        Text(secondary)
                            .font(.system(size: 12, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(dialog.kind == .checking)
                }

                Button(action: onPrimary) {
                    Text(dialog.primaryButtonTitle)
                        .font(.system(size: 12, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            dialog.kind == .checking
                                ? AnyShapeStyle(AppTheme.insetSurface(for: colorScheme))
                                : AnyShapeStyle(LinearGradient(
                                    colors: [cyan, AppTheme.accentBlue(for: colorScheme)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .foregroundStyle(dialog.kind == .checking ? AppTheme.textSecondary(for: colorScheme) : Color.white)
                }
                .buttonStyle(.plain)
                .disabled(!dialog.primaryButtonEnabled)
            }
        }
        .padding(26)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(isDark ? Color(red: 0.075, green: 0.09, blue: 0.14) : Color(red: 0.97, green: 0.985, blue: 1.0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(cyan.opacity(isDark ? 0.30 : 0.22), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isDark ? 0.45 : 0.18), radius: 28, x: 0, y: 18)
        .onAppear {
            isAnimating = true
        }
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
            return AppTheme.accentBlue(for: colorScheme)
        case .latest:
            return AppTheme.accentEmerald(for: colorScheme)
        case .failure:
            return AppTheme.accentAmber(for: colorScheme)
        case .progress:
            return AppTheme.accentBlue(for: colorScheme)
        case .ready:
            return AppTheme.accentEmerald(for: colorScheme)
        case .installing:
            return AppTheme.accentCyan(for: colorScheme)
        }
    }
}

private struct SidebarNavigationRow: View {
    let tab: NavigationTab
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

                    Image(systemName: tab.icon)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(isSelected ? selectedPrimary : AppTheme.textSecondary(for: colorScheme))
                }

                Text(tab.title)
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
        DispatchQueue.main.async {
            configure(nsView.window)
        }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.toolbar = nil
    }
}
