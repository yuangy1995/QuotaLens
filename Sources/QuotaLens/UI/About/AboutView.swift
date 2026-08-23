// QuotaLens about and update center.

import SwiftUI

public struct AboutView: View {
    @ObservedObject var state: AppState
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.colorScheme) var colorScheme

    private let featureRows: [(String, String)] = [
        ("gauge.with.needle.fill", L10n.text("额度使用与剩余额度", "Quota usage and remaining quota")),
        ("clock.arrow.2.circlepath", L10n.text("自动刷新与手动同步额度", "Automatic and manual quota refresh")),
        ("ticket.fill", L10n.text("重置卡储备与到期提醒", "Reset-card reserve and expiry reminders")),
        ("calendar.badge.clock", L10n.text("订阅周期、续订与计划变更识别", "Subscription period, renewal, and plan-change detection")),
        ("menubar.rectangle", L10n.text("菜单栏常驻模式与隐藏 Dock 图标", "Menu bar mode with optional hidden Dock icon")),
        ("arrow.triangle.2.circlepath.circle.fill", L10n.text("应用内在线升级", "In-app online updates"))
    ]

    public var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                versionCard
                featureCard
                updateCard
            }
            .padding(24)
        }
        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
    }

    private var header: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(L10n.text("关于", "About"))
                    .font(.system(.title, design: .rounded, weight: .black))
                Text("QUOTALENS")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(cyan)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(cyan.opacity(colorScheme == .dark ? 0.15 : 0.12), in: RoundedRectangle(cornerRadius: 4))
            }
            Text(L10n.text("Codex 额度监测与菜单栏监控", "Codex quota tracking and menu bar monitoring."))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var versionCard: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        return VStack(alignment: .leading, spacing: 14) {
            CyberSectionHeader(
                tag: "01",
                title: L10n.text("版本信息", "Version information"),
                icon: "info.circle.fill"
            )
            CyberDivider()

            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [cyan, AppTheme.accentBlue(for: colorScheme)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 58, height: 58)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1.2))
                    Image(systemName: "gauge.with.needle.fill")
                        .font(.system(size: 24, weight: .black))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("QuotaLens")
                        .font(.system(size: 22, weight: .black, design: .rounded))
                    Text(AppVersion.displayString)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(cyan)
                    Text("Apache License 2.0")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }

                Spacer()

                Button(action: {
                    env.updateManager.openProjectPage()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.forward.app.fill")
                        Text("GitHub")
                    }
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
            }
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    private var featureCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CyberSectionHeader(
                tag: "02",
                title: L10n.text("核心功能", "Features"),
                icon: "sparkles"
            )
            CyberDivider()

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                ForEach(featureRows, id: \.1) { row in
                    HStack(spacing: 9) {
                        Image(systemName: row.0)
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 24, height: 24)
                            .foregroundStyle(AppTheme.accentCyan(for: colorScheme))
                            .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 6))
                        Text(row.1)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                            .lineLimit(2)
                    }
                    .padding(10)
                    .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8))
                }
            }
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    private var updateCard: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let updateManager = env.updateManager

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                CyberSectionHeader(
                    tag: "03",
                    title: L10n.text("在线升级", "Online Updates"),
                    icon: "arrow.triangle.2.circlepath.circle.fill"
                )
                Spacer()
                Text(updateManager.isConfigured ? L10n.text("已启用", "Enabled") : L10n.text("待配置", "Pending"))
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(updateManager.isConfigured ? AppTheme.accentEmerald(for: colorScheme) : AppTheme.accentAmber(for: colorScheme))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((updateManager.isConfigured ? AppTheme.accentEmerald(for: colorScheme) : AppTheme.accentAmber(for: colorScheme)).opacity(0.12), in: Capsule())
            }

            CyberDivider()

            VStack(alignment: .leading, spacing: 4) {
                Text(updateManager.statusText)
                    .font(.system(size: 14, weight: .bold))
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("上次检查", "Last check"))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    Text(updateManager.lastUpdateCheckText)
                        .font(.system(size: 12, weight: .semibold))
                }

                Spacer()

                Toggle(L10n.text("自动检测", "Auto-check"), isOn: Binding(
                    get: { updateManager.automaticallyChecksForUpdates },
                    set: { updateManager.automaticallyChecksForUpdates = $0 }
                ))
                .disabled(!updateManager.isConfigured)

                Toggle(L10n.text("自动下载", "Auto-download"), isOn: Binding(
                    get: { updateManager.automaticallyDownloadsUpdates },
                    set: { updateManager.automaticallyDownloadsUpdates = $0 }
                ))
                .disabled(!updateManager.isConfigured || !updateManager.allowsAutomaticDownloads)
            }
            .font(.system(size: 12, weight: .semibold))

            HStack {
                Button(action: {
                    updateManager.checkForUpdates()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                        Text(updateManager.isCheckingForUpdates ? L10n.text("正在检查...", "Checking...") : L10n.text("检查更新", "Check for Updates"))
                    }
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(cyan.opacity(colorScheme == .dark ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(cyan.opacity(0.42), lineWidth: 0.8))
                    .foregroundStyle(cyan)
                }
                .buttonStyle(.plain)
                .disabled(!updateManager.isConfigured || updateManager.isCheckingForUpdates || !updateManager.canCheckForUpdates)

                Spacer()
            }
        }
        .cyberCard(cornerRadius: 16, padding: 18, isHighlighted: updateManager.isConfigured, glowColor: cyan)
    }
}
