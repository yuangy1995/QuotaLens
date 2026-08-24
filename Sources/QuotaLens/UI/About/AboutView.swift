// QuotaLens about and update center.

import SwiftUI

public struct AboutView: View {
    @ObservedObject var state: AppState
    @ObservedObject var updateManager: UpdateManager
    @Environment(\.colorScheme) var colorScheme

    // 核心特性数据结构
    private struct FeatureItem: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let description: String
        let tintColor: Color
    }

    private var features: [FeatureItem] {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let blue = AppTheme.accentBlue(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)
        let purple = AppTheme.accentPurple(for: colorScheme)
        let amber = AppTheme.accentAmber(for: colorScheme)

        return [
            FeatureItem(
                icon: "gauge.with.needle.fill",
                title: L10n.text("配额实时追踪", "Real-Time Quota Tracking"),
                description: L10n.text("毫秒级捕获 Codex 与 AI 配额用量及剩余百分比", "Track Codex & AI quota usage and remaining percentage instantly."),
                tintColor: cyan
            ),
            FeatureItem(
                icon: "calendar.badge.clock",
                title: L10n.text("智能周期识别", "Smart Cycle Detection"),
                description: L10n.text("自动计算 5 小时重置窗口、周度配额与续订周期", "Detect 5-hour reset windows, weekly quotas, and renewal dates."),
                tintColor: blue
            ),
            FeatureItem(
                icon: "ticket.fill",
                title: L10n.text("重置卡失效预警", "Reset Card Alerts"),
                description: L10n.text("多张重置卡储备追踪，智能预警最近到期时间", "Monitor multiple reset card reserves and get timely expiry alerts."),
                tintColor: amber
            ),
            FeatureItem(
                icon: "menubar.rectangle",
                title: L10n.text("极简菜单栏模式", "Menu Bar Compact Mode"),
                description: L10n.text("支持常驻 macOS 菜单栏与隐藏 Dock 图标静默运行", "Run quietly in the macOS menu bar with an optional hidden Dock icon."),
                tintColor: purple
            ),
            FeatureItem(
                icon: "clock.arrow.2.circlepath",
                title: L10n.text("自适应双模同步", "Adaptive Dual-Sync Engine"),
                description: L10n.text("智能后台自适应轮询与即时一键快照刷新", "Combine intelligent background polling with one-click snapshot sync."),
                tintColor: emerald
            ),
            FeatureItem(
                icon: "arrow.triangle.2.circlepath.circle.fill",
                title: L10n.text("无缝在线热更新", "Seamless In-App Updates"),
                description: L10n.text("基于 Sparkle 框架的一键增量在线检测与平滑升级", "High-security delta updates and smooth installations powered by Sparkle."),
                tintColor: cyan
            )
        ]
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                heroBrandCard
                updateCenterCard
                featureGridCard
                footerInfo
            }
            .padding(24)
        }
        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
    }

    // MARK: - 顶部标题区
    private var header: some View {
        let isDark = colorScheme == .dark
        let cyan = AppTheme.accentCyan(for: colorScheme)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(L10n.text("关于 QuotaLens", "About QuotaLens"))
                    .font(.system(.title, design: .rounded, weight: .black))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                Text("QUOTALENS")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(cyan)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(cyan.opacity(isDark ? 0.15 : 0.12), in: RoundedRectangle(cornerRadius: 4))
            }

            Text(L10n.text("版本信息、功能特性与在线升级", "Version info, core features, and online updates"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 核心品牌与版本卡片
    private var heroBrandCard: some View {
        let isDark = colorScheme == .dark
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let blue = AppTheme.accentBlue(for: colorScheme)

        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 18) {
                // 应用立体光晕图标
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [cyan, blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 64, height: 64)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1.2)
                        )
                        .shadow(color: cyan.opacity(isDark ? 0.35 : 0.22), radius: 10, x: 0, y: 4)

                    Image(systemName: "gauge.with.needle.fill")
                        .font(.system(size: 28, weight: .black))
                        .foregroundStyle(.white)
                }

                // 核心品牌标题与版本信息
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("QuotaLens")
                            .font(.system(size: 24, weight: .black, design: .rounded))
                            .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                        // 版本胶囊
                        Text(AppVersion.displayString)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(cyan)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(cyan.opacity(isDark ? 0.18 : 0.12), in: Capsule())
                            .overlay(Capsule().strokeBorder(cyan.opacity(0.35), lineWidth: 0.8))

                        // 构建号
                        Text("\(L10n.text("构建", "Build")) \(AppVersion.buildNumber)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    }

                    // Slogan 定位
                    Text(L10n.text("实时掌控 Codex 与 AI 模型配额的桌面助手", "A desktop dashboard for tracking Codex & AI model quotas in real time."))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        .lineLimit(2)
                }

                Spacer()
            }

            CyberDivider()

            // 快捷入口芯片组
            HStack(spacing: 10) {
                quickLinkButton(
                    icon: "arrow.up.forward.app.fill",
                    title: "GitHub",
                    action: { updateManager.openProjectPage() }
                )

                quickLinkButton(
                    icon: "list.bullet.rectangle.portrait.fill",
                    title: L10n.text("更新日志", "Changelog"),
                    action: { updateManager.openReleasesPage() }
                )

                quickLinkButton(
                    icon: "ladybug.fill",
                    title: L10n.text("问题反馈", "Feedback"),
                    action: { updateManager.openIssuesPage() }
                )

                quickLinkButton(
                    icon: "doc.text.fill",
                    title: L10n.text("开源协议", "License"),
                    action: { updateManager.openLicensePage() }
                )

                Spacer()
            }
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    private func quickLinkButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)

        return Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(cyan)
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 在线升级与维护卡片
    private var updateCenterCard: some View {
        let isDark = colorScheme == .dark
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)
        let amber = AppTheme.accentAmber(for: colorScheme)

        return VStack(alignment: .leading, spacing: 14) {
            // 顶部标题与状态指示
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(cyan)

                    Text(L10n.text("在线升级与维护", "Updates & Maintenance"))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                }

                Spacer()

                // 状态指示徽章
                if updateManager.isCheckingForUpdates {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(L10n.text("检查中", "Checking"))
                            .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    }
                    .foregroundStyle(cyan)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(cyan.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(cyan.opacity(0.35), lineWidth: 0.8))
                } else {
                    let isReady = updateManager.isConfigured
                    HStack(spacing: 5) {
                        Circle()
                            .fill(isReady ? emerald : amber)
                            .frame(width: 6, height: 6)
                        Text(isReady ? L10n.text("已启用", "Enabled") : L10n.text("待配置", "Pending"))
                            .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    }
                    .foregroundStyle(isReady ? emerald : amber)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background((isReady ? emerald : amber).opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder((isReady ? emerald : amber).opacity(0.35), lineWidth: 0.8))
                }
            }

            CyberDivider()

            // 升级核心状态与操作栏
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(updateManager.statusText)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                    Text(updateManager.updateStatusText ?? L10n.text("可手动检查新版本，也可以保持自动检测。", "Check manually or keep automatic checks enabled."))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        .lineLimit(2)

                    HStack(spacing: 4) {
                        Text("\(L10n.text("上次检查时间", "Last Checked")): ")
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        Text(updateManager.lastUpdateCheckText)
                            .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                    }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .padding(.top, 2)
                }

                Spacer()

                Button(action: {
                    updateManager.checkForUpdates()
                }) {
                    HStack(spacing: 6) {
                        if updateManager.isCheckingForUpdates {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise.circle.fill")
                        }
                        Text(updateManager.isCheckingForUpdates ? L10n.text("正在检查...", "Checking...") : L10n.text("检查更新", "Check for Updates"))
                    }
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        LinearGradient(
                            colors: [cyan.opacity(isDark ? 0.22 : 0.15), cyan.opacity(isDark ? 0.12 : 0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(cyan.opacity(0.45), lineWidth: 0.9)
                    )
                    .foregroundStyle(cyan)
                }
                .buttonStyle(.plain)
                .disabled(updateManager.isCheckingForUpdates || !updateManager.isConfigured)
            }
            .padding(12)
            .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
            )

            // 升级偏好设置（双列微卡片）
            HStack(spacing: 12) {
                updatePreferenceToggleCard(
                    icon: "clock.badge.checkmark",
                    title: L10n.text("自动检查更新", "Automatic Check"),
                    description: L10n.text("后台定期检查新版本并提醒", "Check for updates periodically in background"),
                    isOn: Binding(
                        get: { updateManager.automaticallyChecksForUpdates },
                        set: { updateManager.automaticallyChecksForUpdates = $0 }
                    )
                )

                updatePreferenceToggleCard(
                    icon: "arrow.down.circle",
                    title: L10n.text("自动下载更新", "Automatic Download"),
                    description: L10n.text("发现新版本时在后台静默下载", "Download new versions automatically in background"),
                    isOn: Binding(
                        get: { updateManager.automaticallyDownloadsUpdates },
                        set: { updateManager.automaticallyDownloadsUpdates = $0 }
                    )
                )
            }
        }
        .cyberCard(cornerRadius: 16, padding: 18, isHighlighted: updateManager.isConfigured, glowColor: cyan)
    }

    private func updatePreferenceToggleCard(icon: String, title: String, description: String, isOn: Binding<Bool>) -> some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)

        return HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(cyan)
                .frame(width: 26, height: 26)
                .background(cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                Text(description)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    .lineLimit(1)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!updateManager.isConfigured)
        }
        .padding(10)
        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
        )
    }

    // MARK: - 核心特性矩阵卡片
    private var featureGridCard: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(cyan)

                Text(L10n.text("核心特性", "Key Features"))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                Spacer()
            }

            CyberDivider()

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ],
                spacing: 12
            ) {
                ForEach(features) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.icon)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(item.tintColor)
                            .frame(width: 28, height: 28)
                            .background(item.tintColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(item.tintColor.opacity(0.28), lineWidth: 0.8)
                            )

                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                            Text(item.description)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
                    )
                }
            }
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    // MARK: - 底部版权与环境说明
    private var footerInfo: some View {
        VStack(spacing: 5) {
            Text(L10n.text("专为 macOS 打造 · 基于 SwiftUI 构建", "Designed for macOS · Powered by SwiftUI"))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))

            Text("Copyright © 2026 QuotaLens Contributors · \(L10n.text("遵循 Apache-2.0 开源协议", "Open source under Apache-2.0 License"))")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme).opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

