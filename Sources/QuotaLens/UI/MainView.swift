// QuotaLens 科技风全息主界面与侧边栏框架 (Dual Theme Navigation Frame)

import SwiftUI
import AppKit

public enum NavigationTab: CaseIterable, Identifiable {
    case dashboard
    case settings
    case about

    public var id: Self { self }

    public var title: String {
        switch self {
        case .dashboard: return L10n.text("概览", "Overview")
        case .settings: return L10n.text("设置", "Settings")
        case .about: return L10n.text("关于", "About")
        }
    }

    public var icon: String {
        switch self {
        case .dashboard: return "gauge.with.needle.fill"
        case .settings: return "gearshape.2.fill"
        case .about: return "info.circle.fill"
        }
    }

    public var subtitle: String {
        switch self {
        case .dashboard: return L10n.text("额度", "Quota")
        case .settings: return L10n.text("偏好", "Preferences")
        case .about: return L10n.text("版本", "Version")
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
                Color.clear
                    .frame(height: 64)

                // 顶部当前账户全息身份芯片
                sidebarIdentityCard

                CyberDivider(glowColor: cyan.opacity(isDark ? 0.25 : 0.15))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)

                // 侧边栏导航列表
                VStack(spacing: 8) {
                    ForEach(NavigationTab.allCases) { tab in
                        SidebarNavigationRow(
                            tab: tab,
                            isSelected: selectedTab == tab,
                            colorScheme: colorScheme
                        ) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                                selectedTab = tab
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)

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

                ZStack {
                    // 环境自适应背景画布
                    AppTheme.canvasGradient(for: colorScheme)
                        .ignoresSafeArea()

                    Group {
                        switch selectedTab {
                        case .dashboard:
                            DashboardView(state: state)
                        case .settings:
                            SettingsView(state: state)
                        case .about:
                            AboutView(state: state)
                        }
                    }
                }
                .frame(minWidth: 720, minHeight: 540)
            }
        }
        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
        .tint(cyan)
        .preferredColorScheme(state.colorScheme)
        .environment(\.controlActiveState, .key)
        .background(StableWindowConfigurator())
    }

    private var topChromeBar: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let isDark = colorScheme == .dark

        return HStack(spacing: 12) {
            Text("QuotaLens")
                .font(.system(size: 16, weight: .black, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

            Spacer()

            Button(action: {
                Task {
                    await env.refreshData()
                }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(
                        isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.05),
                        in: Circle()
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.09), lineWidth: 0.8)
                    )
                    .foregroundStyle(cyan)
            }
            .buttonStyle(.plain)
            .help(L10n.text("立即刷新数据", "Refresh data now"))
            .disabled(state.isRefreshing)
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
        .padding(10)
        .background(
            isDark ? Color(red: 0.105, green: 0.135, blue: 0.215).opacity(0.72) : Color.white.opacity(0.85),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.08), lineWidth: 0.8)
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    // MARK: - 侧边栏底座状态指示坞
    private var sidebarBottomHUDDock: some View {
        let emerald = AppTheme.accentEmerald(for: colorScheme)
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
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .foregroundStyle(state.connectionStatus.isConnected ? emerald : AppTheme.textSecondary(for: colorScheme))
                }

                Spacer()

                Text(AppVersion.displayString)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .padding(.top, 4)
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
        let selectedSecondary = Color.white.opacity(0.84)

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

                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.title)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(isSelected ? selectedPrimary : AppTheme.textPrimary(for: colorScheme))
                        .shadow(color: isSelected ? Color.black.opacity(0.22) : Color.clear, radius: 1, x: 0, y: 1)

                    Text(tab.subtitle)
                        .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                        .foregroundStyle(isSelected ? selectedSecondary : AppTheme.textSecondary(for: colorScheme))
                }

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
