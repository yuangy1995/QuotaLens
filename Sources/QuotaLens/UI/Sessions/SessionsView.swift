// QuotaLens 会话浏览器与明细视图 (SessionsView)

import SwiftUI
import AppKit
import Combine

public struct SessionsView: View {
    @StateObject private var store: SessionsStore
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.colorScheme) var colorScheme
    @State private var sessionPendingDeletion: CodexSessionDTO?

    public init(facade: UsageQueryFacade) {
        _store = StateObject(wrappedValue: SessionsStore(facade: facade))
    }

    public var body: some View {
        HSplitView {
            // 左栏：会话列表与搜索
            sessionsSidebar
                .frame(minWidth: 260, idealWidth: 290, maxWidth: 360)

            // 右栏：会话明细与事件时间线
            sessionDetailArea
                .frame(minWidth: 460, maxWidth: .infinity)
        }
        .task {
            env.scanCoordinator.triggerScan()
            await store.reloadSessions()
        }
        .onReceive(env.scanCoordinator.$dataGeneration.dropFirst()) { _ in
            Task {
                await store.reloadSessions()
            }
        }
        .confirmationDialog(
            L10n.text("删除会话？", "Delete Session?"),
            isPresented: Binding(
                get: { sessionPendingDeletion != nil },
                set: { if !$0 { sessionPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: sessionPendingDeletion
        ) { session in
            Button(L10n.text("移到废纸篓", "Move to Trash"), role: .destructive) {
                sessionPendingDeletion = nil
                Task {
                    if await store.deleteSession(session) {
                        env.scanCoordinator.triggerScan()
                    }
                }
            }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {
                sessionPendingDeletion = nil
            }
        } message: { _ in
            Text(L10n.text(
                "该会话及其子代理的 Codex 源文件会移到 macOS 废纸篓，可从废纸篓恢复。",
                "The Codex source files for this session and its subagents will be moved to the macOS Trash, where they can be restored."
            ))
        }
        .alert(
            L10n.text("操作失败", "Operation Failed"),
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button(L10n.text("好", "OK"), role: .cancel) {
                store.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    // MARK: - 左栏：会话列表
    private var sessionsSidebar: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)

        return VStack(spacing: 0) {
            // 搜索与排序栏
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))

                    TextField(L10n.text("搜索会话 / 项目 / 路径…", "Search sessions..."), text: $store.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                    if !store.searchText.isEmpty {
                        Button(action: { store.searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
                )

                Menu {
                    ForEach(SessionSort.allCases) { sort in
                        Button(action: { store.sortOption = sort }) {
                            HStack {
                                Text(sort.localizedTitle)
                                if store.sortOption == sort {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(cyan)
                        .frame(width: 24, height: 24)
                        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
                .accessibilityLabel(L10n.text("筛选与排序", "Filter and Sort"))
                .accessibilityIdentifier("sessions.filterAndSort")
            }
            .padding(10)

            CyberDivider()

            // 会话列表
            if store.isLoading && store.sessions.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                        .tint(cyan)
                    Text(L10n.text("正在加载会话…", "Loading sessions..."))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 24))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme).opacity(0.6))
                    Text(L10n.text("未发现会话记录", "No sessions found"))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(store.sessions) { session in
                            SessionSidebarRow(
                                session: session,
                                isSelected: store.selectedSessionId == session.sessionId,
                                colorScheme: colorScheme,
                                onSelect: {
                                    store.selectedSessionId = session.sessionId
                                },
                                onDelete: {
                                    sessionPendingDeletion = session
                                }
                            )
                        }

                        if store.isLoadingNextPage {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.vertical, 10)
                        } else if store.hasMoreSessions {
                            Color.clear
                                .frame(height: 1)
                                .task { await store.loadNextPage() }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(AppTheme.sidebarGradient(for: colorScheme))
    }

    // MARK: - 右栏：会话明细
    private var sessionDetailArea: some View {
        Group {
            if store.isLoadingDetail {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(L10n.text("正在加载会话明细…", "Loading details..."))
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let detail = store.selectedDetail {
                SessionDetailView(
                    detail: detail,
                    onBackToRoot: {
                        store.selectedSessionId = detail.session.rootSessionId
                    },
                    onSelectSubagent: { subagentId in
                        store.selectedSessionId = subagentId
                    }
                )
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme).opacity(0.5))
                    Text(L10n.text("请在左侧选择一个会话查看明细", "Select a session to view details"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - 会话侧边栏单行
private struct SessionSidebarRow: View {
    let session: CodexSessionDTO
    let isSelected: Bool
    let colorScheme: ColorScheme
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let isDark = colorScheme == .dark
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let emerald = AppTheme.accentEmerald(for: colorScheme)

        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if session.hasSubagents {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(AppTheme.accentPurple(for: colorScheme))
                    }

                    Text(session.displayTitle)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(isSelected ? Color.white : AppTheme.textPrimary(for: colorScheme))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(UsageNumberFormatter.relativeTimeString(from: session.lastEventAt ?? session.updatedAt))
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : AppTheme.textSecondary(for: colorScheme))
                }

                HStack(spacing: 6) {
                    if let project = session.projectName {
                        Text(project)
                            .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.9) : cyan)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                isSelected ? Color.white.opacity(0.2) : cyan.opacity(isDark ? 0.15 : 0.10),
                                in: RoundedRectangle(cornerRadius: 3)
                            )
                    }

                    if let agentType = session.agentType, !agentType.isEmpty {
                        Text(agentType)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.9) : AppTheme.accentPurple(for: colorScheme))
                            .lineLimit(1)
                    }

                    Spacer()

                    // Token 统计徽标
                    Text(UsageNumberFormatter.compactTokenCount(session.tokens.canonicalTotalTokens))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.white : AppTheme.textPrimary(for: colorScheme))

                    // 价值估算徽标
                    if session.estimatedCost.rawValue > 0 {
                        Text(UsageNumberFormatter.currencyUSD(session.estimatedCost))
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(isSelected ? Color.white : emerald)
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(LinearGradient(
                        colors: [cyan, AppTheme.accentBlue(for: colorScheme)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )) : AnyShapeStyle(isDark ? Color.white.opacity(0.03) : Color.black.opacity(0.02)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? cyan.opacity(0.6) : (isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label(L10n.text("删除", "Delete"), systemImage: "trash")
            }
        }
    }
}
