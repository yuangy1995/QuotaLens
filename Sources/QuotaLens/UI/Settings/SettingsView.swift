// QuotaLens system settings view.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

public enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case account
    case overlay
    case codex
    case storage

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general:
            return L10n.text("常规与外观", "General")
        case .account:
            return L10n.text("账号与同步", "Account & Sync")
        case .overlay:
            return L10n.text("悬浮窗挂件", "Overlay HUD")
        case .codex:
            return L10n.text("Codex 环境", "Codex Environment")
        case .storage:
            return L10n.text("存储与诊断", "Data & Diagnostics")
        }
    }

    public var icon: String {
        switch self {
        case .general:
            return "paintpalette.fill"
        case .account:
            return "person.crop.circle.badge.checkmark"
        case .overlay:
            return "macwindow.badge.plus"
        case .codex:
            return "cpu.fill"
        case .storage:
            return "externaldrive.fill"
        }
    }
}

public struct SettingsView: View {
    @ObservedObject var state: AppState
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.colorScheme) var colorScheme

    @AppStorage("settings_selected_tab_v2") private var selectedTab: SettingsTab = .general
    @State private var customPath: String = ""
    @State private var isCopiedDbPath: Bool = false
    @State private var isShowingBinaryTargetDialog: Bool = false
    @State private var binaryTargetAlertMessage: String?
    @State private var autoDetectedBinaryResult: CodexBinaryLookupResult?
    @State private var usageDiagnostics: UsageDiagnosticsDTO?
    @State private var diagnosticsExportStatus: String?
    @State private var missingSourceCleanupStatus: String?
    @State private var missingSourceCleanupPreview: MissingSourceCleanupPreviewDTO?
    @State private var showMissingSourceCleanupDialog: Bool = false
    @State private var isPreparingMissingSourceCleanup: Bool = false
    @State private var isCleaningMissingSources: Bool = false
    @State private var showResetConfirmDialog: Bool = false
    @State private var isResettingApp: Bool = false
    @ObservedObject private var overlayController = CodexUsageOverlayController.shared

    private let presetIntervals: [Int] = [15, 30, 60, 300, 900]

    public var body: some View {
        VStack(spacing: 0) {
            // 顶部分类导航切换栏
            tabPickerHeader
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 12)

            CyberDivider()
                .padding(.horizontal, 24)

            // 分类内容区域
            ScrollView {
                VStack(spacing: 18) {
                    switch selectedTab {
                    case .general:
                        generalTabPane
                    case .account:
                        accountTabPane
                    case .overlay:
                        overlayTabPane
                    case .codex:
                        codexTabPane
                    case .storage:
                        storageTabPane
                    }
                }
                .padding(24)
            }
        }
        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
        .task {
            await refreshAutoDetectedBinaryPath()
            await refreshUsageDiagnostics()
        }
        .onReceive(env.scanCoordinator.$dataGeneration.dropFirst()) { _ in
            Task { await refreshUsageDiagnostics() }
        }
        .confirmationDialog(
            L10n.text("确认重置所有数据与配置？", "Reset all data and preferences?"),
            isPresented: $showResetConfirmDialog,
            titleVisibility: .visible
        ) {
            Button(L10n.text("确认重置并重新读取", "Reset and Read Again"), role: .destructive) {
                isResettingApp = true
                Task {
                    await env.resetAllDataAndFactoryDefaults()
                    isResettingApp = false
                }
            }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("此操作将清除所有本地用量记录与个性化设置，并重新读取本地 Codex 数据。此操作不可撤销。", "This will clear all local usage records and personalized settings, then read local Codex data again. This cannot be undone."))
        }
        .confirmationDialog(
            L10n.text("清理本地记录？", "Clean Local Records?"),
            isPresented: $showMissingSourceCleanupDialog,
            titleVisibility: .visible
        ) {
            Button(L10n.text("确认清理本地记录", "Clean Local Records"), role: .destructive) {
                performMissingSourceCleanup()
            }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(missingSourceCleanupPreviewText)
        }
    }

    // MARK: - 顶部分类导航切换栏
    private var tabPickerHeader: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let blue = AppTheme.accentBlue(for: colorScheme)
        let isDark = colorScheme == .dark

        return HStack(spacing: 8) {
            ForEach(SettingsTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button(action: {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        selectedTab = tab
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11.5, weight: isSelected ? .bold : .semibold))
                            .foregroundStyle(isSelected ? Color.white : (isDark ? Color.white.opacity(0.7) : Color.black.opacity(0.6)))

                        Text(tab.title)
                            .font(.system(size: 12, weight: isSelected ? .bold : .medium, design: .rounded))
                            .foregroundStyle(isSelected ? Color.white : AppTheme.textPrimary(for: colorScheme))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        ZStack {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [cyan, blue],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .shadow(color: cyan.opacity(isDark ? 0.35 : 0.20), radius: 6, y: 2)
                            } else {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(AppTheme.insetSurface(for: colorScheme))
                            }
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                isSelected ? cyan.opacity(0.8) : AppTheme.insetBorder(for: colorScheme),
                                lineWidth: isSelected ? 1 : 0.7
                            )
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }

    // MARK: - Tab 1 · 常规与外观
    private var generalTabPane: some View {
        VStack(spacing: 18) {
            appearanceHUDCard
            launchBehaviorHUDCard
        }
    }

    // MARK: - Tab 2 · 账号与同步
    private var accountTabPane: some View {
        VStack(spacing: 18) {
            accountIdentityHUDCard
            syncPolicyHUDCard
        }
    }

    // MARK: - Tab 3 · 悬浮窗与挂件
    private var overlayTabPane: some View {
        VStack(spacing: 18) {
            overlayHUDCard
        }
    }

    // MARK: - Tab 4 · Codex 环境
    private var codexTabPane: some View {
        VStack(spacing: 18) {
            codexPathHUDCard
            codexScanHUDCard
        }
    }

    // MARK: - Tab 5 · 存储与诊断
    private var storageTabPane: some View {
        VStack(spacing: 18) {
            storageCoreHUDCard
            if let diagnostics = usageDiagnostics {
                diagnosticsGridHUDCard(diagnostics)
            }
        }
    }

    // MARK: - 全息悬浮窗与用量挂件
    private var overlayHUDCard: some View {
        let flags = UsageFeatureFlags.shared

        return VStack(alignment: .leading, spacing: 14) {
            CyberSectionHeader(
                title: L10n.text("桌面全息悬浮挂件与预测", "Desktop Floating Overlay & Forecast"),
                icon: "macwindow.badge.plus"
            )

            CyberDivider()

            VStack(spacing: 10) {
                // 1. 启用本地 Codex 分析
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("启用本地 Codex 用量分析", "Enable Local Codex Analytics"))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                        Text(L10n.text("读取本机会话记录，统计 Token 与 API 价值", "Read local sessions for token and API value"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { flags.isAnalyticsEnabled },
                        set: { enabled in
                            flags.isAnalyticsEnabled = enabled
                            if enabled {
                                Task {
                                    await env.scanCoordinator.scanNow(forceRebuild: false)
                                }
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                .padding(12)
                .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10))

                // 2. 启用 ChatGPT / Codex 窗口悬浮挂件
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("ChatGPT / Codex 窗口悬浮挂件", "Window Floating Overlay"))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                        Text(L10n.text("在目标应用前台窗口边缘附着小胶囊，显示实时配额", "Floating pill attached to target window"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { flags.isOverlayEnabled },
                        set: { enabled in
                            flags.isOverlayEnabled = enabled
                            CodexUsageOverlayController.shared.setEnabled(enabled, environment: env)
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                .padding(12)
                .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10))

                if flags.isOverlayEnabled {
                    // 仅在前台使用时显示
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("仅在目标应用前台时显示", "Only Show When Target App is Active"))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                            Text(L10n.text("切换至其他应用时自动隐藏挂件，避免干扰桌面操作", "Automatically hide overlay when switching to other applications"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { flags.isOverlayOnlyWhenActive },
                            set: { enabled in
                                flags.isOverlayOnlyWhenActive = enabled
                                overlayController.updateVisibilityForFrontmostApp()
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    .padding(12)
                    .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10))

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("精确窗口吸附（辅助功能）", "Precise Window Snapping (Accessibility)"))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                            Text(overlayController.isAccessibilityTrusted
                                ? L10n.text("只读取目标窗口的位置与尺寸，不读取窗口文本", "Reads only target window position and size; never window text")
                                : L10n.text("由你主动授权；未授权时自动保持基础模式", "Opt-in only; basic mode remains active until authorized"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { flags.isAXSnappingEnabled },
                            set: { enabled in
                                flags.isAXSnappingEnabled = enabled
                                overlayController.setAXSnappingEnabled(enabled)
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    .padding(12)
                    .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10))

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("重置挂件吸附位置", "Reset Overlay Position"))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                            Text(L10n.text("恢复挂件至默认吸附状态（屏幕右上角）", "Reset floating overlay to default top-right position"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        }
                        Spacer()
                        Button(action: {
                            overlayController.resetPinning()
                        }) {
                            Text(L10n.text("重置位置", "Reset"))
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(AppTheme.accentCyan(for: colorScheme).opacity(colorScheme == .dark ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(AppTheme.accentCyan(for: colorScheme).opacity(0.4), lineWidth: 0.8)
                                )
                                .foregroundStyle(AppTheme.accentCyan(for: colorScheme))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10))
                }

                // 3. 智能预测引擎
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("智能预测引擎", "Smart Forecast Engine"))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                        Text(L10n.text("计算服务器额度耗尽时间与未来 7 天用量趋势", "Calculates burn rate and 7-day usage trends"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { flags.isForecastEnabled },
                        set: { flags.isForecastEnabled = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                .padding(12)
                .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    // MARK: - 诊断表格卡片
    private func diagnosticsGridHUDCard(_ diagnostics: UsageDiagnosticsDTO) -> some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)
        let amber = AppTheme.accentAmber(for: colorScheme)
        let purple = AppTheme.accentPurple(for: colorScheme)
        let blue = AppTheme.accentBlue(for: colorScheme)

        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .decimal

        let totalEventsFormatted = numberFormatter.string(from: NSNumber(value: diagnostics.totalEvents)) ?? "\(diagnostics.totalEvents)"
        let violations = diagnostics.invariantViolationCount + diagnostics.foreignKeyViolationCount

        let columns = [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ]

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                CyberSectionHeader(
                    title: L10n.text("本地记录与问题报告", "Local Records & Reports"),
                    icon: "stethoscope"
                )

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        prepareMissingSourceCleanup()
                    } label: {
                        HStack(spacing: 5) {
                            if isPreparingMissingSourceCleanup || isCleaningMissingSources {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "tray.and.arrow.down.fill")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            Text(L10n.text("预览可清理记录", "Preview Cleanup"))
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(amber.opacity(colorScheme == .dark ? 0.16 : 0.12), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(amber.opacity(0.4), lineWidth: 0.8)
                        )
                        .foregroundStyle(amber)
                    }
                    .buttonStyle(.plain)
                    .disabled(diagnostics.missingSourceCount == 0 || isPreparingMissingSourceCleanup || isCleaningMissingSources)
                    .help(L10n.text(
                        "仅对已确认不存在的记录提供预览清理；权限或读取异常会保留记录。执行前会重新校验预览。",
                        "Only records confirmed as no longer present can be previewed for cleanup. Records with permission or read errors are kept, and the preview is rechecked before cleanup."
                    ))

                    Button {
                        exportUsageDiagnostics(diagnostics)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 10, weight: .bold))
                            Text(L10n.text("导出问题报告", "Export Report"))
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(cyan.opacity(colorScheme == .dark ? 0.16 : 0.12), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(cyan.opacity(0.4), lineWidth: 0.8)
                        )
                        .foregroundStyle(cyan)
                    }
                    .buttonStyle(.plain)
                }
            }

            CyberDivider()

            LazyVGrid(columns: columns, spacing: 10) {
                // Row 1: 用户可理解的读取与费用状态
                DiagnosticMetricTile(
                    title: L10n.text("本地记录", "Local Records"),
                    value: "\(diagnostics.sourcesIndexed) / \(diagnostics.sourcesDiscovered)",
                    icon: "folder.fill",
                    accentColor: cyan,
                    statusBadge: diagnostics.sourcesIndexed == diagnostics.sourcesDiscovered ? L10n.text("就绪", "Ready") : nil,
                    isSuccess: true,
                    colorScheme: colorScheme
                )

                DiagnosticMetricTile(
                    title: L10n.text("用量记录", "Usage Records"),
                    value: totalEventsFormatted,
                    icon: "bolt.fill",
                    accentColor: blue,
                    colorScheme: colorScheme
                )

                DiagnosticMetricTile(
                    title: L10n.text("数据读取", "Data Reading"),
                    value: L10n.text("已启用", "On"),
                    icon: "gearshape.2.fill",
                    accentColor: purple,
                    statusBadge: L10n.text("就绪", "Ready"),
                    colorScheme: colorScheme
                )

                DiagnosticMetricTile(
                    title: L10n.text("API 价值", "API Value"),
                    value: L10n.text("公开价格", "Public rates"),
                    icon: "tag.fill",
                    accentColor: amber,
                    colorScheme: colorScheme
                )

                DiagnosticMetricTile(
                    title: L10n.text("费用更新", "Cost Update"),
                    value: diagnostics.pricingMigrationState.localizedDescription,
                    icon: "arrow.triangle.branch",
                    accentColor: diagnostics.pricingMigrationState == .fullyCurrent ? emerald : amber,
                    statusBadge: pricingUpdateBadge(diagnostics),
                    isSuccess: diagnostics.pricingMigrationState == .fullyCurrent,
                    isWarning: diagnostics.pricingMigrationState != .fullyCurrent,
                    colorScheme: colorScheme
                )

                DiagnosticMetricTile(
                    title: L10n.text("费用更新进度", "Cost Update Progress"),
                    value: progressText(
                        processed: diagnostics.pricingRepriceProcessedEvents,
                        total: diagnostics.pricingRepriceTotalEvents
                    ),
                    icon: "arrow.triangle.2.circlepath.circle.fill",
                    accentColor: purple,
                    statusBadge: friendlyStatusLabel(diagnostics.pricingRepriceStatus),
                    isSuccess: diagnostics.pricingRepriceStatus == "completed",
                    isWarning: ["failed", "pending"].contains(diagnostics.pricingRepriceStatus),
                    colorScheme: colorScheme
                )

                DiagnosticMetricTile(
                    title: L10n.text("记录更新", "Record Update"),
                    value: progressText(
                        processed: diagnostics.parserRebuildProcessedSources,
                        total: diagnostics.parserRebuildTotalSources
                    ),
                    icon: "arrow.triangle.2.circlepath",
                    accentColor: ["failed", "pending"].contains(diagnostics.parserRebuildStatus) ? amber : cyan,
                    statusBadge: friendlyStatusLabel(diagnostics.parserRebuildStatus),
                    isSuccess: diagnostics.parserRebuildStatus == "completed",
                    isWarning: ["failed", "pending"].contains(diagnostics.parserRebuildStatus),
                    colorScheme: colorScheme
                )

                // Row 2: 完整性与健康
                DiagnosticMetricTile(
                    title: L10n.text("数据检查", "Data Check"),
                    value: diagnostics.integrityCheckPassed ? L10n.text("通过", "Passed") : L10n.text("需要处理", "Needs attention"),
                    icon: "checkmark.shield.fill",
                    accentColor: emerald,
                    statusBadge: diagnostics.integrityCheckPassed ? L10n.text("正常", "OK") : L10n.text("异常", "Issue"),
                    isSuccess: diagnostics.integrityCheckPassed,
                    isWarning: !diagnostics.integrityCheckPassed,
                    colorScheme: colorScheme
                )

                DiagnosticMetricTile(
                    title: L10n.text("一致性检查", "Consistency Check"),
                    value: "\(violations)",
                    icon: "scalemass.fill",
                    accentColor: violations == 0 ? emerald : amber,
                    statusBadge: violations == 0 ? L10n.text("正常", "Pass") : L10n.text("警告", "Warn"),
                    isSuccess: violations == 0,
                    isWarning: violations > 0,
                    colorScheme: colorScheme
                )

                DiagnosticMetricTile(
                    title: L10n.text("已恢复记录", "Restored Records"),
                    value: "\(diagnostics.rebuiltSourceCount)",
                    icon: "arrow.triangle.2.circlepath",
                    accentColor: cyan,
                    colorScheme: colorScheme
                )

                DiagnosticMetricTile(
                    title: L10n.text("无法估算费用", "Cannot Estimate"),
                    value: "\(diagnostics.unpricedEvents)",
                    icon: "dollarsign.circle",
                    accentColor: diagnostics.unpricedEvents == 0 ? emerald : amber,
                    isWarning: diagnostics.unpricedEvents > 0,
                    colorScheme: colorScheme
                )

                DiagnosticMetricTile(
                    title: L10n.text("暂不可读记录", "Unreadable Records"),
                    value: "\(diagnostics.missingSourceCount)",
                    icon: "externaldrive.badge.questionmark",
                    accentColor: diagnostics.missingSourceCount == 0 ? emerald : amber,
                    statusBadge: diagnostics.pendingSourceCount > 0 ? L10n.text("待处理", "Pending") : nil,
                    isSuccess: diagnostics.missingSourceCount == 0,
                    isWarning: diagnostics.missingSourceCount > 0 || diagnostics.pendingSourceCount > 0,
                    colorScheme: colorScheme
                )

                DiagnosticMetricTile(
                    title: L10n.text("历史金额", "Historical Amounts"),
                    value: diagnostics.legacyAggregateCost.rawValue > 0
                        ? UsageNumberFormatter.currencyUSD(diagnostics.legacyAggregateCost)
                        : UsageNumberFormatter.compactTokenCount(diagnostics.legacyAggregateTokens),
                    icon: "archivebox.fill",
                    accentColor: diagnostics.legacyAggregateEventCount == 0 ? blue : amber,
                    statusBadge: diagnostics.legacyAggregateEventCount == 0 ? nil : "\(diagnostics.legacyAggregateEventCount)",
                    isWarning: diagnostics.legacyAggregateEventCount > 0,
                    colorScheme: colorScheme
                )

                // Row 3: 异常追踪与兜底
                DiagnosticMetricTile(
                    title: L10n.text("未知模型", "Unknown Models"),
                    value: "\(diagnostics.unknownModelEvents + diagnostics.genericGPT56Events)",
                    icon: "questionmark.app.fill",
                    accentColor: diagnostics.unknownModelEvents + diagnostics.genericGPT56Events == 0 ? blue : amber,
                    isWarning: diagnostics.unknownModelEvents + diagnostics.genericGPT56Events > 0,
                    colorScheme: colorScheme
                )

                DiagnosticMetricTile(
                    title: L10n.text("时间待确认", "Time Needs Review"),
                    value: "\(diagnostics.fallbackTimestampEvents)",
                    icon: "clock.badge.questionmark",
                    accentColor: diagnostics.fallbackTimestampEvents == 0 ? blue : amber,
                    isWarning: diagnostics.fallbackTimestampEvents > 0,
                    colorScheme: colorScheme
                )

                DiagnosticMetricTile(
                    title: L10n.text("无法读取的记录", "Unreadable Entries"),
                    value: "\(diagnostics.malformedLineCount)",
                    icon: "exclamationmark.triangle.fill",
                    accentColor: diagnostics.malformedLineCount == 0 ? emerald : amber,
                    isWarning: diagnostics.malformedLineCount > 0,
                    colorScheme: colorScheme
                )

                DiagnosticMetricTile(
                    title: L10n.text("缺少时间", "Missing Time"),
                    value: "\(diagnostics.unresolvedTimestampCount)",
                    icon: "hourglass.badge.plus",
                    accentColor: diagnostics.unresolvedTimestampCount == 0 ? blue : amber,
                    isWarning: diagnostics.unresolvedTimestampCount > 0,
                    colorScheme: colorScheme
                )

                DiagnosticMetricTile(
                    title: L10n.text("时间不一致", "Time Mismatch"),
                    value: "\(diagnostics.timestampConflictCount)",
                    icon: "clock.badge.exclamationmark",
                    accentColor: diagnostics.timestampConflictCount == 0 ? blue : amber,
                    isWarning: diagnostics.timestampConflictCount > 0,
                    colorScheme: colorScheme
                )

                DiagnosticMetricTile(
                    title: L10n.text("删除恢复", "Deletion Recovery"),
                    value: "\(diagnostics.pendingDeletionJournalCount)",
                    icon: "arrow.uturn.backward.circle.fill",
                    accentColor: diagnostics.pendingDeletionJournalCount == 0
                        && diagnostics.rollbackRequiredDeletionJournalCount == 0 ? emerald : amber,
                    statusBadge: diagnostics.rollbackRequiredDeletionJournalCount > 0
                        ? L10n.text("需处理", "Manual") : nil,
                    isSuccess: diagnostics.pendingDeletionJournalCount == 0
                        && diagnostics.rollbackRequiredDeletionJournalCount == 0,
                    isWarning: diagnostics.pendingDeletionJournalCount > 0
                        || diagnostics.rollbackRequiredDeletionJournalCount > 0,
                    colorScheme: colorScheme
                )
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: diagnostics.missingSourceCount == 0 ? "checkmark.circle.fill" : "info.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(diagnostics.missingSourceCount == 0 ? emerald : amber)
                Text(diagnostics.missingSourceCount == 0
                    ? L10n.text(
                        "未发现需要清理的本地记录。",
                        "No local records need cleanup."
                    )
                    : L10n.format(
                        "%d 个记录暂时无法读取；QuotaLens 会保留现有用量。只有确认记录已不存在并通过预览后，才允许显式清理。",
                        zhHans: "%d 个记录暂时无法读取；QuotaLens 会保留现有用量。只有确认记录已不存在并通过预览后，才允许显式清理。",
                        diagnostics.missingSourceCount
                    ))
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }
            .padding(.top, 2)

            if let missingSourceCleanupStatus {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(cyan)
                    Text(missingSourceCleanupStatus)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }
                .padding(.top, 2)
            }

            if let diagnosticsExportStatus {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(emerald)
                    Text(diagnosticsExportStatus)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }
                .padding(.top, 2)
            }

            if diagnostics.genericGPT56Events > 0 {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(amber)
                    Text(L10n.format(
                        "%d generic gpt-5.6 events are intentionally unpriced until Codex records a concrete Sol/Terra/Luna SKU.",
                        zhHans: "%d 条通用 gpt-5.6 事件会保持未计价，直到 Codex 记录明确的 Sol/Terra/Luna 型号。",
                        diagnostics.genericGPT56Events
                    ))
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }
                .padding(.top, 2)
            }
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    // MARK: - 模块 01 · 外观与语言
    private var appearanceHUDCard: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let isDark = colorScheme == .dark

        return VStack(alignment: .leading, spacing: 14) {
            CyberSectionHeader(
                title: L10n.text("外观与语言", "Appearance & Language"),
                icon: "paintpalette.fill"
            )

            CyberDivider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(L10n.text("界面视觉皮肤", "Interface Theme"))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                    }
                    Text(L10n.text("选择浅色、深色，或跟随系统外观", "Choose light, dark, or follow the macOS appearance."))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }

                Spacer()

                HStack(spacing: 8) {
                    ForEach(AppThemeMode.allCases) { mode in
                        ThemeModeChip(
                            mode: mode,
                            isSelected: state.themeMode == mode,
                            isDark: isDark,
                            cyan: cyan,
                            textSecondary: AppTheme.textSecondary(for: colorScheme),
                            onSelect: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                    state.setThemeMode(mode)
                                }
                            }
                        )
                    }
                }
            }
            .padding(12)
            .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
            )

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(L10n.text("界面语言", "Interface Language"))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                    }
                    Text(L10n.text("默认跟随系统，也可以选择固定语言", "Follow the system by default, or choose a fixed language."))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }

                Spacer()

                LanguageModeMenu(
                    selection: state.languageMode,
                    isDark: isDark,
                    cyan: cyan,
                    textSecondary: AppTheme.textSecondary(for: colorScheme)
                ) { mode in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        state.setLanguageMode(mode)
                    }
                }
            }
            .padding(12)
            .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
            )
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    // MARK: - 模块 02 · 账号
    private var accountIdentityHUDCard: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let purple = AppTheme.accentPurple(for: colorScheme)

        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                CyberSectionHeader(
                    title: L10n.text("账号", "Account"),
                    icon: "person.crop.circle.badge.checkmark"
                )

                Spacer()

                Button(action: {
                    Task {
                        await env.refreshData()
                    }
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .bold))
                        Text(L10n.text("刷新账号", "Refresh Account"))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(cyan.opacity(colorScheme == .dark ? 0.15 : 0.12), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(cyan.opacity(0.4), lineWidth: 0.8)
                    )
                    .foregroundStyle(cyan)
                }
                .buttonStyle(.plain)
                .disabled(state.isRefreshing)
            }

            CyberDivider()

            // 身份状态卡片
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [cyan, purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(0.4), lineWidth: 1.5)
                        )
                        .shadow(color: cyan.opacity(colorScheme == .dark ? 0.4 : 0.25), radius: 6)

                    Image(systemName: "person.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(state.displayName(for: state.account?.accountKey))
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                        HStack(spacing: 4) {
                            Text(L10n.text("套餐:", "Plan:"))
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(cyan)
                            Text(state.subscriptionPlanTitle.uppercased())
                                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(cyan.opacity(colorScheme == .dark ? 0.15 : 0.12), in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(cyan.opacity(0.35), lineWidth: 0.8)
                        )
                    }

                    Text(L10n.text("使用当前登录账号", "Using the current signed-in account"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }

                Spacer()

                StatusBadge.forConnection(state.connectionStatus)
            }
            .padding(14)
            .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
            )
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    // MARK: - 系统启动与常驻行为
    private var launchBehaviorHUDCard: some View {
        return VStack(alignment: .leading, spacing: 14) {
            CyberSectionHeader(
                title: L10n.text("系统与启动偏好", "System & Launch Preferences"),
                icon: "gearshape.2.fill"
            )

            CyberDivider()

            VStack(spacing: 10) {
                // 开机自启动
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(L10n.text("开机自动启动", "Launch at Login"))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                        }
                        Text(L10n.format("Status: %@", zhHans: "状态: %@", state.launchAtLoginStatusText))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    }

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { state.launchAtLoginEnabled },
                        set: { env.setLaunchAtLogin(enabled: $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                .padding(12)
                .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
                )

                // 隐藏 Dock 图标 / 纯菜单栏模式
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(L10n.text("仅显示菜单栏图标", "Show in Menu Bar Only"))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                        }
                        Text(L10n.text("开启后，QuotaLens 只显示在菜单栏中", "When enabled, QuotaLens only appears in the menu bar."))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    }

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { state.hideDockIcon },
                        set: { env.setDockIconHidden($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                .padding(12)
                .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
                )
            }
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    // MARK: - 额度同步与提醒策略
    private var syncPolicyHUDCard: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let amber = AppTheme.accentAmber(for: colorScheme)
        let isDark = colorScheme == .dark

        return VStack(alignment: .leading, spacing: 14) {
            CyberSectionHeader(
                title: L10n.text("同步频率与提醒", "Sync & Reminders"),
                icon: "timer"
            )

            CyberDivider()

            // 1. 自动刷新周期设置与快速芯片
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(L10n.text("刷新频率", "Refresh Rate"))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                        }
                        Text(L10n.format("Refreshes quota every %@.", zhHans: "每 %@ 自动刷新额度", state.refreshIntervalDescription))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    }

                    Spacer()

                    // 快速预设芯片选择器
                    HStack(spacing: 6) {
                        ForEach(presetIntervals, id: \.self) { seconds in
                            let isSelected = state.refreshIntervalSeconds == seconds
                            Button(action: {
                                env.setRefreshInterval(seconds: seconds)
                            }) {
                                Text(displayPreset(seconds))
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        isSelected ? cyan.opacity(isDark ? 0.24 : 0.18) : (isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.04)),
                                        in: RoundedRectangle(cornerRadius: 5)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5)
                                            .strokeBorder(
                                                isSelected ? cyan.opacity(0.65) : (isDark ? Color.white.opacity(0.18) : Color.black.opacity(0.10)),
                                                lineWidth: isSelected ? 1 : 0.6
                                            )
                                    )
                                    .foregroundStyle(isSelected ? cyan : AppTheme.textPrimary(for: colorScheme))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Stepper(
                        "",
                        value: Binding(
                            get: { state.refreshIntervalSeconds },
                            set: { env.setRefreshInterval(seconds: $0) }
                        ),
                        in: 15...3600,
                        step: 15
                    )
                    .labelsHidden()
                }
            }
            .padding(12)
            .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
            )

            // 重置卡到期提醒
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(L10n.text("重置卡到期提醒", "Reset Card Expiry Reminder"))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                    }
                    Text(state.resetCreditReminderDetailText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        .lineLimit(2)
                }

                Spacer()

                Text(state.resetCreditReminderStatusText)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(state.hasActiveResetCreditReminder ? amber : AppTheme.textSecondary(for: colorScheme))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((state.hasActiveResetCreditReminder ? amber : AppTheme.textSecondary(for: colorScheme)).opacity(colorScheme == .dark ? 0.14 : 0.10), in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder((state.hasActiveResetCreditReminder ? amber : AppTheme.textSecondary(for: colorScheme)).opacity(0.36), lineWidth: 0.8)
                    )

                Toggle("", isOn: Binding(
                    get: { state.resetCreditReminderEnabled },
                    set: { env.setResetCreditReminderEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            .padding(12)
            .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder((state.hasActiveResetCreditReminder ? amber : (isDark ? Color.white : Color.black)).opacity(state.hasActiveResetCreditReminder ? 0.34 : 0.10), lineWidth: 0.8)
            )
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    // MARK: - Codex 路径探测与连接
    private var codexPathHUDCard: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let amber = AppTheme.accentAmber(for: colorScheme)
        let isDark = colorScheme == .dark

        return VStack(alignment: .leading, spacing: 14) {
            CyberSectionHeader(
                title: L10n.text("Codex 可执行文件路径", "Codex Executable Path"),
                icon: "terminal.fill"
            )

            CyberDivider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button(action: {
                        isShowingBinaryTargetDialog = true
                    }) {
                        HStack(spacing: 7) {
                            Image(systemName: customPath.isEmpty ? "scope" : "terminal.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(cyan)

                            Text(cliBinaryTargetDescription)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: 8)

                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isDark ? Color.black.opacity(0.4) : Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(cyan.opacity(0.35), lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("选择 Codex 路径", "Choose Codex Path"))
                    .accessibilityValue(cliBinaryTargetDescription)
                    .confirmationDialog(L10n.text("选择 Codex 路径", "Choose Codex Path"), isPresented: $isShowingBinaryTargetDialog) {
                        Button(L10n.text("自动探测 codex", "Auto-detect codex")) {
                            customPath = ""
                        }

                        ForEach(binaryTargetCandidates, id: \.self) { target in
                            Button(target) {
                                customPath = target
                            }
                        }

                        Button(L10n.text("从文件中选择…", "Choose from File...")) {
                            DispatchQueue.main.async {
                                chooseCodexBinaryTarget()
                            }
                        }

                        Button(L10n.text("取消", "Cancel"), role: .cancel) {}
                    } message: {
                        Text(L10n.text("选择 Codex 的位置，或保持自动探测。", "Choose where Codex is installed, or keep auto-detection enabled."))
                    }

                    Button(action: {
                        Task {
                            await env.processManager.setCustomBinaryPath(customPath.isEmpty ? nil : customPath)
                            await env.connectCodex()
                            await refreshAutoDetectedBinaryPath()
                        }
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 10))
                            Text(L10n.text("重新连接", "Reconnect"))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            LinearGradient(
                                colors: [cyan, AppTheme.accentBlue(for: colorScheme)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                        .foregroundStyle(.white)
                        .shadow(color: cyan.opacity(isDark ? 0.3 : 0.15), radius: 4)
                    }
                    .buttonStyle(.plain)
                }

                if let failure = autoDetectedBinaryFailureText {
                    Text(failure)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(amber)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
            )
            .alert(L10n.text("无法选择目标", "Cannot choose target"), isPresented: Binding(
                get: { binaryTargetAlertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        binaryTargetAlertMessage = nil
                    }
                }
            )) {
                Button(L10n.text("知道了", "OK"), role: .cancel) {
                    binaryTargetAlertMessage = nil
                }
            } message: {
                Text(binaryTargetAlertMessage ?? "")
            }
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    // MARK: - Codex 扫描与记录控制
    private var codexScanHUDCard: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)
        let isDark = colorScheme == .dark
        let flags = UsageFeatureFlags.shared

        return VStack(alignment: .leading, spacing: 14) {
            CyberSectionHeader(
                title: L10n.text("本地用量与 API 价值", "Local Usage & API Value"),
                icon: "waveform.path.ecg"
            )

            CyberDivider()

            VStack(spacing: 10) {
                // 扫描归档会话
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("包含归档会话", "Scan Archived Sessions"))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                        Text(L10n.text("扫描并汇总已归档的历史会话", "Include archived sessions in total history"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { flags.isScanArchivedSessionsEnabled },
                        set: { flags.isScanArchivedSessionsEnabled = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                .padding(12)
                .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10))
            }

            // 索引状态与操作
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L10n.text("按 API 价格折算", "Converted at API rates"))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(cyan)

                    Spacer()

                    Text(L10n.text("官方列表价已激活", "Official rates active"))
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundStyle(emerald)
                }

                HStack(spacing: 10) {
                    Button(action: {
                        Task {
                            await env.scanCoordinator.scanNow(forceRebuild: false)
                        }
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10, weight: .bold))
                            Text(L10n.text("立即读取", "Read Now"))
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(cyan.opacity(isDark ? 0.16 : 0.12), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(cyan.opacity(0.4), lineWidth: 0.8)
                        )
                        .foregroundStyle(cyan)
                    }
                    .buttonStyle(.plain)
                    .disabled(env.scanCoordinator.isScanning)

                    Button(action: {
                        Task {
                            await env.scanCoordinator.scanNow(forceRebuild: true)
                        }
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 10, weight: .bold))
                            Text(L10n.text("重新读取全部", "Read All Again"))
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(AppTheme.accentAmber(for: colorScheme).opacity(isDark ? 0.16 : 0.12), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(AppTheme.accentAmber(for: colorScheme).opacity(0.4), lineWidth: 0.8)
                        )
                        .foregroundStyle(AppTheme.accentAmber(for: colorScheme))
                    }
                    .buttonStyle(.plain)
                    .disabled(env.scanCoordinator.isScanning)

                    Spacer()

                    if env.scanCoordinator.isScanning {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(env.scanCoordinator.statusText)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        }
                    } else if let lastTime = env.scanCoordinator.lastScanTime {
                        Text(L10n.format("Last scan: %@", zhHans: "最后扫描: %@", UsageNumberFormatter.relativeTimeString(from: lastTime)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    }
                }
            }
            .padding(12)
            .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10))
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    // MARK: - 模块 05 · 本地数据
    private var storageCoreHUDCard: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let isDark = colorScheme == .dark

        return VStack(alignment: .leading, spacing: 14) {
            CyberSectionHeader(
                title: L10n.text("本地数据", "Local Data"),
                icon: "externaldrive.fill"
            )

            CyberDivider()

            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dbPath = appSupport.appendingPathComponent("QuotaLens/quotalens.sqlite").path

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.text("数据位置:", "Data location:"))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))

                    Spacer()

                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(dbPath, forType: .string)
                        isCopiedDbPath = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            isCopiedDbPath = false
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: isCopiedDbPath ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                            Text(isCopiedDbPath ? L10n.text("已复制", "Copied") : L10n.text("复制路径", "Copy Path"))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                        }
                        .foregroundStyle(isCopiedDbPath ? AppTheme.accentEmerald(for: colorScheme) : cyan)
                    }
                    .buttonStyle(.plain)
                }

                DatabasePathViewer(
                    dbPath: dbPath,
                    isDark: isDark,
                    textColor: AppTheme.textPrimary(for: colorScheme)
                )
            }
            .padding(12)
            .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
            )

            HStack {
                Button(action: {
                    Task {
                        await env.refreshAllData()
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11, weight: .bold))
                        Text(L10n.text("重新同步数据", "Resync Data"))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(cyan.opacity(colorScheme == .dark ? 0.15 : 0.12), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(cyan.opacity(0.4), lineWidth: 0.8)
                    )
                    .foregroundStyle(cyan)
                }
                .buttonStyle(.plain)
                .disabled(state.isRefreshing || isResettingApp)

                Spacer()
            }

            CyberDivider()

            // 危险区：一键重置 App 与出厂设置
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(AppTheme.accentAmber(for: colorScheme))
                            Text(L10n.text("重置 App 与出厂设置", "Reset App & Factory Defaults"))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                        }
                        Text(L10n.text("清除本地用量记录、重置偏好配置并重新读取本地数据", "Clears local usage records, resets preferences, and reads local data again"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    }

                    Spacer()

                    Button(action: {
                        showResetConfirmDialog = true
                    }) {
                        HStack(spacing: 6) {
                            if isResettingApp {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "trash.fill")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            Text(isResettingApp ? L10n.text("正在重置...", "Resetting...") : L10n.text("一键重置所有数据", "Reset All Data"))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(colorScheme == .dark ? 0.20 : 0.12), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.red.opacity(0.45), lineWidth: 0.8)
                        )
                        .foregroundStyle(Color.red)
                    }
                    .buttonStyle(.plain)
                    .disabled(isResettingApp || state.isRefreshing)
                }
            }
            .padding(12)
            .background(Color.red.opacity(colorScheme == .dark ? 0.06 : 0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.red.opacity(0.20), lineWidth: 0.8)
            )
        }
        .cyberCard(cornerRadius: 16, padding: 18)
    }

    private func displayPreset(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        }
        return "\(seconds / 60)m"
    }

    private var cliBinaryTargetDescription: String {
        let trimmedPath = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            if let detectedPath = currentDetectedBinaryPath {
                return L10n.format("Auto-detect · %@", zhHans: "自动探测 · %@", detectedPath)
            }
            return L10n.text("自动探测 Codex", "Auto-detect Codex")
        }
        return trimmedPath
    }

    private var currentDetectedBinaryPath: String? {
        if case .connected(_, let binaryPath) = state.connectionStatus {
            return binaryPath
        }
        return autoDetectedBinaryResult?.binaryPath
    }

    private var autoDetectedBinaryFailureText: String? {
        guard customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              currentDetectedBinaryPath == nil else {
            return nil
        }
        return autoDetectedBinaryResult?.failureReason
    }

    private var binaryTargetCandidates: [String] {
        let fileManager = FileManager.default
        let homePath = fileManager.homeDirectoryForCurrentUser.path
        var candidates: [String] = []

        if let detectedBinaryPath = currentDetectedBinaryPath {
            candidates.append(detectedBinaryPath)
        }

        candidates.append(contentsOf: CodexBinaryLocator.standardSearchPaths.map { path in
            path.replacingOccurrences(of: "~", with: homePath)
        })

        if !customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(expandedPath(customPath))
        }

        var seen = Set<String>()
        return candidates.filter { path in
            guard seen.insert(path).inserted else { return false }
            return fileManager.isExecutableFile(atPath: path)
        }
    }

    private func chooseCodexBinaryTarget() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择 Codex", "Choose Codex")
        panel.message = L10n.text("请选择 Codex 可执行文件。", "Choose the Codex executable.")
        panel.prompt = L10n.text("选择", "Choose")
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.showsHiddenFiles = true

        if let directoryURL = binaryTargetInitialDirectoryURL() {
            panel.directoryURL = directoryURL
        }

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        let selectedPath = selectedURL.path
        guard FileManager.default.isExecutableFile(atPath: selectedPath) else {
            binaryTargetAlertMessage = L10n.text("所选文件不可执行，请重新选择。", "The selected file is not executable. Choose another file.")
            return
        }

        customPath = selectedPath
    }

    private func binaryTargetInitialDirectoryURL() -> URL? {
        let fileManager = FileManager.default
        let trimmedPath = customPath.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedPath.isEmpty {
            let currentURL = URL(fileURLWithPath: expandedPath(trimmedPath))
            let directoryURL = currentURL.deletingLastPathComponent()
            if fileManager.fileExists(atPath: directoryURL.path) {
                return directoryURL
            }
        }

        for candidate in ["/opt/homebrew/bin", "/usr/local/bin", fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/bin").path] {
            if fileManager.fileExists(atPath: candidate) {
                return URL(fileURLWithPath: candidate, isDirectory: true)
            }
        }

        return fileManager.homeDirectoryForCurrentUser
    }

    private func expandedPath(_ path: String) -> String {
        path.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    private func refreshAutoDetectedBinaryPath() async {
        let result = await Task.detached(priority: .utility) {
            CodexBinaryLocator.inspectBinary()
        }.value
        autoDetectedBinaryResult = result
    }

    private func refreshUsageDiagnostics() async {
        usageDiagnostics = try? await env.usageQueryFacade.getDiagnostics()
    }

    private func progressText(processed: Int, total: Int) -> String {
        guard total > 0 else { return L10n.text("就绪", "Ready") }
        return "\(processed) / \(total)"
    }

    private func friendlyStatusLabel(_ status: String) -> String? {
        switch status {
        case "completed":
            return L10n.text("完成", "Done")
        case "running":
            return L10n.text("进行中", "Running")
        case "pending":
            return L10n.text("待处理", "Pending")
        case "failed":
            return L10n.text("未完成", "Incomplete")
        default:
            return nil
        }
    }

    private func pricingUpdateBadge(_ diagnostics: UsageDiagnosticsDTO) -> String? {
        switch diagnostics.pricingMigrationState {
        case .fullyCurrent:
            return L10n.text("完成", "Done")
        case .mixedLegacy:
            return L10n.text("部分保留", "Partial")
        case .pendingSources:
            return L10n.text("待处理", "Pending")
        case .failed:
            return L10n.text("未完成", "Incomplete")
        }
    }

    private func userFacingCleanupError(_ error: Error) -> String {
        if let localized = (error as? MissingSourceCleanupError)?.errorDescription {
            return localized
        }
        if let localized = (error as? SessionDeletionError)?.errorDescription {
            return localized
        }
        return L10n.text(
            "暂时无法完成这项操作。请稍后重试；如需排查，可导出问题报告。",
            "This action cannot be completed right now. Try again later, or export a report for troubleshooting."
        )
    }

    private var missingSourceCleanupPreviewText: String {
        guard let preview = missingSourceCleanupPreview else {
            return L10n.text(
                "请先生成影响预览。",
                "Generate the impact preview first."
            )
        }
        return L10n.format(
            "将清理 %d 个已确认不存在的本地记录，影响 %d 个会话、%@ Token 和 %@ 费用估算。执行前会重新校验；如果记录恢复或影响范围变化，本次清理会被拒绝。",
            zhHans: "将清理 %d 个已确认不存在的本地记录，影响 %d 个会话、%@ Token 和 %@ 费用估算。执行前会重新校验；如果记录恢复或影响范围变化，本次清理会被拒绝。",
            preview.items.count,
            preview.totalSessions,
            UsageNumberFormatter.compactTokenCount(preview.totalTokens),
            UsageNumberFormatter.currencyUSD(preview.estimatedCost)
        )
    }

    @MainActor
    private func prepareMissingSourceCleanup() {
        isPreparingMissingSourceCleanup = true
        missingSourceCleanupStatus = nil
        Task { @MainActor in
            do {
                let preview = try await env.usageQueryFacade.previewMissingSourceCleanup()
                missingSourceCleanupPreview = preview
                if preview.items.isEmpty {
                    missingSourceCleanupStatus = L10n.text(
                        "没有可清理的本地记录。",
                        "There are no local records to clean."
                    )
                } else {
                    showMissingSourceCleanupDialog = true
                }
            } catch {
                missingSourceCleanupStatus = userFacingCleanupError(error)
            }
            isPreparingMissingSourceCleanup = false
        }
    }

    @MainActor
    private func performMissingSourceCleanup() {
        guard let preview = missingSourceCleanupPreview else { return }
        isCleaningMissingSources = true
        missingSourceCleanupStatus = nil
        Task { @MainActor in
            do {
                let result = try await env.usageQueryFacade.cleanupMissingSourceIndexes(
                    previewId: preview.previewId
                )
                missingSourceCleanupStatus = L10n.format(
                    "Cleaned %d local records, %d sessions, %@ tokens.",
                    zhHans: "已清理 %d 个本地记录、%d 个会话、%@ Token。",
                    result.sourcesRemoved,
                    result.sessionsRemoved,
                    UsageNumberFormatter.compactTokenCount(result.tokensRemoved)
                )
                missingSourceCleanupPreview = nil
                await refreshUsageDiagnostics()
            } catch {
                missingSourceCleanupStatus = userFacingCleanupError(error)
            }
            isCleaningMissingSources = false
        }
    }

    @MainActor
    private func exportUsageDiagnostics(_ diagnostics: UsageDiagnosticsDTO) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "QuotaLens-report-\(Self.diagnosticFileTimestamp()).json"
        panel.title = L10n.text("导出问题报告", "Export Report")

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let report = UsageDiagnosticsExport(diagnostics: diagnostics)
            try report.jsonData().write(to: destination, options: .atomic)
            diagnosticsExportStatus = L10n.text(
                "问题报告已导出；不包含对话内容或本地文件位置。",
                "Report exported without conversation content or local file locations."
            )
        } catch {
            diagnosticsExportStatus = L10n.text(
                "暂时无法导出问题报告，请稍后重试。",
                "The report could not be exported right now. Try again later."
            )
        }
    }

    private static func diagnosticFileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - 诊断微型指标卡片组件
private struct DiagnosticMetricTile: View {
    let title: String
    let value: String
    let icon: String
    let accentColor: Color
    var statusBadge: String? = nil
    var isSuccess: Bool? = nil
    var isWarning: Bool = false
    let colorScheme: ColorScheme

    var body: some View {
        let isDark = colorScheme == .dark

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(accentColor)

                Text(title)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    .lineLimit(1)

                Spacer(minLength: 0)

                if let badge = statusBadge {
                    Text(badge)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(isSuccess == true ? AppTheme.accentEmerald(for: colorScheme) : (isWarning ? AppTheme.accentAmber(for: colorScheme) : accentColor))
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1.5)
                        .background(
                            (isSuccess == true ? AppTheme.accentEmerald(for: colorScheme) : (isWarning ? AppTheme.accentAmber(for: colorScheme) : accentColor))
                                .opacity(isDark ? 0.18 : 0.12),
                            in: Capsule()
                        )
                }
            }

            Text(value)
                .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                .foregroundStyle(isWarning ? AppTheme.accentAmber(for: colorScheme) : AppTheme.textPrimary(for: colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.insetSurface(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isWarning ? AppTheme.accentAmber(for: colorScheme).opacity(0.35) : AppTheme.insetBorder(for: colorScheme),
                    lineWidth: 0.8
                )
        )
    }
}

// MARK: - 主题模式芯片按钮组件
private struct ThemeModeChip: View {
    let mode: AppThemeMode
    let isSelected: Bool
    let isDark: Bool
    let cyan: Color
    let textSecondary: Color
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: mode.icon)
                    .font(.system(size: 11, weight: .bold))
                Text(mode.title)
                    .font(.system(size: 11, weight: isSelected ? .bold : .semibold, design: .rounded))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                chipBackground,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(chipBorder, lineWidth: isSelected ? 1.2 : 0.8)
            )
            .foregroundStyle(isSelected ? cyan : textSecondary)
        }
        .buttonStyle(.plain)
    }

    private var chipBackground: Color {
        if isSelected {
            return isDark ? cyan.opacity(0.24) : cyan.opacity(0.18)
        }
        return isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
    }

    private var chipBorder: Color {
        if isSelected {
            return cyan.opacity(isDark ? 0.75 : 0.6)
        }
        return isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.10)
    }
}

// MARK: - 语言模式菜单选择器
private struct LanguageModeMenu: View {
    let selection: AppLanguageMode
    let isDark: Bool
    let cyan: Color
    let textSecondary: Color
    let onSelect: (AppLanguageMode) -> Void

    var body: some View {
        Menu {
            ForEach(AppLanguageMode.allCases) { mode in
                Button(action: {
                    onSelect(mode)
                }) {
                    Label(mode.title, systemImage: selection == mode ? "checkmark.circle.fill" : mode.icon)
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: selection.icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(cyan)
                    .frame(width: 22, height: 22)
                    .background(cyan.opacity(isDark ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(cyan.opacity(isDark ? 0.45 : 0.30), lineWidth: 0.8)
                    )

                Text(selection.title)
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary(for: isDark ? .dark : .light))
                    .lineLimit(1)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(cyan.opacity(isDark ? 0.35 : 0.25), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(L10n.text("界面语言", "Interface Language"))
        .accessibilityValue(selection.title)
    }
}

// MARK: - 数据库路径展示子视图
private struct DatabasePathViewer: View {
    let dbPath: String
    let isDark: Bool
    let textColor: Color

    var body: some View {
        Text(dbPath)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(textColor)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isDark ? Color.black.opacity(0.4) : Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.10), lineWidth: 0.6)
            )
            .textSelection(.enabled)
    }
}
