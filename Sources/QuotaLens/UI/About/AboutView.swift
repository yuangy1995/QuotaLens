// QuotaLens about and update center.

import Foundation
import SwiftUI
import AppKit

public struct AboutView: View {
    @ObservedObject var state: AppState
    @ObservedObject var updateManager: UpdateManager
    @Environment(\.colorScheme) var colorScheme

    @State private var activeModal: AboutModalType? = nil
    @State private var isLicenseCopied: Bool = false

    // 动态网络获取状态
    @State private var remoteChangelogs: [ChangelogEntry]? = nil
    @State private var isFetchingChangelog: Bool = false
    @State private var remoteLicenseText: String? = nil
    @State private var isFetchingLicense: Bool = false

    private enum AboutModalType: Identifiable {
        case changelog
        case license

        var id: Self { self }
    }

    // 核心特性数据结构
    private struct FeatureItem: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let description: String
        let tintColor: Color
    }

    // 版本更新记录数据模型
    private struct ChangelogEntry: Identifiable, Sendable, Equatable {
        let id: String
        let version: String
        let date: String
        let changes: [String]

        var isCurrent: Bool {
            let current = AppVersion.marketingVersion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let target = version.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .replacingOccurrences(of: "v", with: "")
            return current == target
        }
    }

    // 本地内置兜底数据（保障首次秒开与离线状态）
    private var defaultChangelogs: [ChangelogEntry] {
        [
            ChangelogEntry(
                id: "v1.0.27",
                version: "v1.0.27",
                date: "2026-09-01",
                changes: [
                    L10n.text("升级后自动修复 Claude 子任务的历史用量、费用汇总与父子层级", "Automatically repairs historical Claude child-task usage, cost summaries, and parent-child hierarchy after upgrading"),
                    L10n.text("优化 Claude 登录失效后的凭据刷新，避免重复使用已失效的访问凭据", "Improved Claude credential refresh after sign-in expiration without retrying rejected access credentials"),
                    L10n.text("增强 Antigravity 账号切换与凭据轮换期间的缓存保留和错误提示", "Improved cache retention and error messages during Antigravity account changes and credential rotation"),
                    L10n.text("强化多工具会话隔离、旧账号迁移与 Universal 安装包验证", "Strengthened cross-tool session isolation, legacy account migration, and Universal package verification")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.26",
                version: "v1.0.26",
                date: "2026-08-31",
                changes: [
                    L10n.text("新增 Antigravity 深度用量解析与官方 API 定价目录引擎，支持 Gemini 3.7/3.6/3.5 Flash 与 3.1 Pro 成本测算与长上下文折算", "Added Antigravity deep usage parsing and official API pricing catalog engine with cost auditing for Gemini 3.7/3.6/3.5 Flash and 3.1 Pro"),
                    L10n.text("全面优化周度配额完全恢复气泡提醒，支持多项配额折叠提示、确认关闭交互与精致视觉质感", "Enhanced weekly quota recovery notification bubbles with multi-quota folding, interactive dismiss, and refined visual aesthetics"),
                    L10n.text("提升概览看板、用量看板与历史会话的高频刷新性能与暗色模式视觉层次", "Improved high-frequency refresh performance and dark mode visual hierarchy across overview, dashboard, and session views"),
                    L10n.text("全面完善 10 种语言的多语言本地化翻译字典与更新日志多语言映射", "Comprehensive localization dictionary refinements and changelog translation mapping across 10 supported languages")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.25",
                version: "v1.0.25",
                date: "2026-08-30",
                changes: [
                    L10n.text("优先采用系统 CLI 路径检索 Codex 核心二进制，提升对 Homebrew 与本地定制环境的兼容性", "Prioritized CLI search paths for Codex binary detection, improving compatibility with Homebrew and custom environments"),
                    L10n.text("优化 Codex 服务器额度快照收集与连接恢复机制，保障弱网与高延迟环境下的数据完整性", "Refined Codex server quota snapshot collection and recovery mechanisms, ensuring data integrity in high-latency environments"),
                    L10n.text("改进菜单栏实时预测数据流采样与会话详情默认视图排版，优化用量指标快速查阅体验", "Improved menu bar real-time forecast data stream sampling and streamlined session detail default tab layout"),
                    L10n.text("全面完善 10 种语言的多语言本地化翻译字典与更新日志多语言映射", "Comprehensive localization dictionary refinements and changelog translation mapping across 10 supported languages")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.24",
                version: "v1.0.24",
                date: "2026-08-30",
                changes: [
                    L10n.text("全新引入全息科技感线性进度条与动态雷达扫描指示器，显著提升扫描与更新过程的视觉体验", "Introduced cyber linear progress bars and dynamic radar scanner indicators for a refined visual scanning and updating experience"),
                    L10n.text("优化 Codex App Server 连接恢复与自动重连调度生命周期，防止无效重试并支持即时强制重连", "Optimized Codex App Server connection recovery and reconnection lifecycle to prevent redundant retries and enable instant manual reconnect"),
                    L10n.text("升级主界面扫描横幅、更新检查对话框与菜单栏风险进度条的视觉呈现与暗色模式适配", "Upgraded visual styling and dark mode adaptation for main view scan banners, update check dialogs, and menu bar risk progress bars"),
                    L10n.text("全面完善 10 种语言的多语言本地化翻译字典与更新日志多语言映射", "Comprehensive localization dictionary refinements and changelog translation mapping across 10 supported languages")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.23",
                version: "v1.0.23",
                date: "2026-08-30",
                changes: [
                    L10n.text("重构 Codex 连接、重连与额度刷新状态，连接失败和缓存数据现在会准确显示", "Reworked Codex connection, reconnection, and quota refresh states so failures and cached data are shown accurately"),
                    L10n.text("严格校验额度与重置卡响应，并将 Claude 登录凭据安全迁移至 macOS 钥匙串", "Added strict validation for quota and reset card responses, and moved Claude sign-in credentials to macOS Keychain"),
                    L10n.text("优化大型历史记录导入、汇总查询和后台监听，显著降低启动、CPU 与内存占用", "Optimized large history imports, summary queries, and background monitoring to significantly reduce startup time, CPU use, and memory use"),
                    L10n.text("改进本地多账号识别与跨架构安装包验证，提升 Apple Silicon、Intel 和 Universal 版本的发布可靠性", "Improved local multi-account identification and cross-architecture package checks for more reliable Apple Silicon, Intel, and Universal releases")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.22",
                version: "v1.0.22",
                date: "2026-08-30",
                changes: [
                    L10n.text("新增周度配额完全恢复（100%）智能气泡提醒，支持多工具额度满血通知与一键快捷交互", "Introduced weekly quota full recovery (100%) notification bubbles with cross-tool status alerts and quick interactions"),
                    L10n.text("优化菜单栏状态图标与指示环排版，支持在状态栏直观切换已用与可用额度视角", "Optimized menu bar status item indicators and ring layout with intuitive toggling between used and available quota perspectives"),
                    L10n.text("深度优化 Antigravity 与 Codex 全息悬浮挂件的吸附平滑度与窗口前台感知链路", "Deeply refined floating overlay snapping smoothness and foreground window awareness across Antigravity and Codex"),
                    L10n.text("全面完善 10 种语言的多语言本地化翻译字典与更新日志多语言映射", "Comprehensive localization dictionary refinements and changelog translation mapping across 10 supported languages")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.21",
                version: "v1.0.21",
                date: "2026-08-30",
                changes: [
                    L10n.text("全面接入 Google Antigravity (AGY) 智能体编程工具生态，支持多周期模型配额与本机活跃度监控", "Full integration with Google Antigravity (AGY) agentic ecosystem with multi-window quota and local activity monitoring"),
                    L10n.text("新增 Antigravity 专属全息悬浮挂件与自动吸附定位，支持随前台应用智能唤醒与模型余量一览", "Dedicated Antigravity floating overlay with smart window snapping, foreground auto-wake, and real-time model quota breakdown"),
                    L10n.text("在菜单栏、总览看板与设置中深度集成 Antigravity 指标卡片、任务趋势与多空间无缝切换", "Deeply integrated Antigravity metric cards, task trends, and multi-workspace switching across menu bar, overview, and settings"),
                    L10n.text("全面完善 10 种语言的多语言本地化翻译字典与更新日志多语言映射", "Comprehensive localization dictionary refinements and changelog translation mapping across 10 supported languages")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.20",
                version: "v1.0.20",
                date: "2026-08-29",
                changes: [
                    L10n.text("引入 Claude (Claude Code / Cursor) 多工具生态用量监控体系，支持 OAuth 授权与多周期配额轮询", "Introduced Claude (Claude Code / Cursor) multi-tool usage monitoring with OAuth authorization and multi-cycle quota polling"),
                    L10n.text("全新升级统一「总览」看板与多工具导航中心，支持 Codex 与 Claude 跨工具配额一览与智能联动", "Upgraded unified Overview dashboard and multi-tool navigation hub for seamless cross-tool quota overview and smart linkage"),
                    L10n.text("重构全息悬浮挂件多工具协同调度器，支持根据当前前台活跃的 AI 编程工具智能自动切换展示视角", "Restructured floating overlay multi-tool coordinator to intelligently auto-switch display perspectives based on the active foreground tool"),
                    L10n.text("全面完善 10 种语言的多语言本地化翻译字典与更新日志多语言映射", "Comprehensive localization dictionary refinements and changelog translation mapping across 10 supported languages")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.19",
                version: "v1.0.19",
                date: "2026-08-29",
                changes: [
                    L10n.text("架构级重构 Codex 悬浮挂件定位与吸附感知引擎，模块化解耦辅助功能锚点读取与坐标计算", "Architectural refactor of Codex overlay positioning and snapping engine, decoupling accessibility anchor detection and geometry calculation"),
                    L10n.text("升级精准锚定算法：直接定位 Codex 窗口与其内部 Help 按钮锚点，完全无需读取任何对话正文，彻底保障用户隐私", "Upgraded precision anchoring: directly targets Codex window and Help button anchors without reading any conversation text for total privacy"),
                    L10n.text("优化悬浮挂件吸附与重置交互，支持一键恢复挂件在 Codex 窗口内的智能默认吸附位置", "Refined overlay snapping and reset interactions with one-click restoration to the intelligent default position inside the Codex window"),
                    L10n.text("全面完善 10 种语言的多语言本地化翻译字典与更新日志多语言映射", "Comprehensive localization dictionary refinements and changelog translation mapping across 10 supported languages")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.18",
                version: "v1.0.18",
                date: "2026-08-28",
                changes: [
                    L10n.text("新增 Codex 会话正文按需解析与对话记录回放，支持在会话详情中直接浏览用户提示词与助手完整回复", "Introduced on-demand Codex conversation parsing and message history viewer in session details for user prompts and assistant replies"),
                    L10n.text("支持会话标题与对话正文全文混合检索，秒级过滤历史对话内容并自动匹配相关工程上下文", "Full-text hybrid search across session titles and conversation bodies with instant filtering and project context matching"),
                    L10n.text("优化会话明细卡片排版，支持「对话内容」与「用量统计」无缝分栏切换与附件标记识别", "Refined session detail layout with seamless switching between Conversation and Usage tabs along with attachment badges"),
                    L10n.text("全面完善 10 种语言的多语言本地化翻译字典与更新日志多语言映射", "Comprehensive localization dictionary refinements and changelog translation mapping across 10 supported languages")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.17",
                version: "v1.0.17",
                date: "2026-08-28",
                changes: [
                    L10n.text("深度优化全界面异步数据加载机制，引入防抖过滤与按需刷新，大幅降低高频切换时的 CPU 与数据库 I/O 占用", "Deeply optimized asynchronous UI data loading with debouncing and on-demand refresh, reducing CPU and database I/O overhead"),
                    L10n.text("重构用量看板预测引擎响应链路，实现轻量级额度变化即时计算与重度历史分析按需解耦", "Decoupled usage dashboard forecast calculations from heavy historical queries for instant rate limit updates and smoother interaction"),
                    L10n.text("优化菜单栏常驻面板与悬浮挂件的生命周期交互，提升多屏协同与窗口切换时的响应流畅度", "Refined menu bar popover and floating overlay lifecycle interactions, enhancing smoothness during multi-display and window transitions"),
                    L10n.text("全面完善 10 种语言的多语言本地化翻译字典与更新日志多语言映射", "Comprehensive localization dictionary refinements and changelog translation mapping across 10 supported languages")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.16",
                version: "v1.0.16",
                date: "2026-08-27",
                changes: [
                    L10n.text("引入 5 小时与周度双周期配额预算与建议节奏引擎，根据窗口类型自动按小时/天智能推算合理配额消耗", "Introduced dual-window quota pace budget engine for 5-hour and weekly cycles with window-aware hourly/daily consumption pace"),
                    L10n.text("动态调整 5 小时短周期的预测门限与采样新鲜度，支持高频周度快照保留并提升预测覆盖率", "Dynamically adjusted forecast thresholds and sampling freshness for 5-hour windows with enhanced snapshot retention"),
                    L10n.text("增强多账号额度同步与历史快照存储持久化，提升 JSON-RPC 传输容错与弱网恢复能力", "Hardened multi-account quota snapshot persistence and JSON-RPC transport resilience against network fluctuations"),
                    L10n.text("优化菜单栏、全息悬浮窗与看板对 5 小时周期的环形指示与文案感知，全方位完善 10 种语言本地化", "Optimized 5-hour cycle ring indicators and contextual labels across menu bar, overlay, and dashboard with 10-language translations")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.15",
                version: "v1.0.15",
                date: "2026-08-27",
                changes: [
                    L10n.text("全新升级全息悬浮挂件交互与智能感知：支持「仅在目标应用前台时显示」自动防打扰，并新增一键重置吸附位置", "Upgraded floating overlay interactions: added auto-hide when target app is inactive and one-click position reset"),
                    L10n.text("优化悬浮挂件视觉排版与隐私保护模式提示，增强已用/可用配额视角的平滑切换", "Refined overlay layout and privacy-preserved mode indicator with smooth view switching between used and available quota"),
                    L10n.text("重构用量看板预测卡片布局，实现自适应等高对齐并提升多分辨率下的展示美观度", "Restructured usage dashboard forecast cards with adaptive equal-height alignment for enhanced layout aesthetics across displays"),
                    L10n.text("全面完善 10 种语言的多语言本地化翻译字典与更新日志多语言映射", "Comprehensive localization dictionary refinements and changelog translation mapping across 10 supported languages")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.14",
                version: "v1.0.14",
                date: "2026-08-26",
                changes: [
                    L10n.text("全新升级 Codex 计费与定价目录引擎，支持模型历史分段价格、缓存命中折算与多周期计费回溯", "Upgraded Codex pricing and catalog engine with historical tiered pricing, prompt cache savings, and multi-cycle cost auditing"),
                    L10n.text("重构数据索引与数据库重建机制，增强原子化写入、损坏文件自动隔离与跨时区自然日精确对齐", "Restructured data indexing and database rebuild pipeline with atomic commits, corrupted file quarantine, and timezone alignment"),
                    L10n.text("强化重置卡明细持久化与容错解析能力，在多账号切换与同步中提供平滑兜底与状态占位", "Hardened reset card persistence and lossy decoding resilience across account switches and syncing gaps"),
                    L10n.text("优化历史明细、用量看板与设置界面的高频刷新性能与内存占用", "Optimized memory footprint and high-frequency refresh performance across history, dashboard, and settings views")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.13",
                version: "v1.0.13",
                date: "2026-08-25",
                changes: [
                    L10n.text("优化 App 启动阶段菜单栏控制器初始化生命周期，确保冷启动时即刻可靠挂载菜单栏图标并响应交互", "Optimized menu bar controller initialization during app startup ensuring instant and reliable menu bar presence"),
                    L10n.text("完善主窗口唤醒与数据刷新回调联动，提升菜单栏常驻模式下的响应速度与稳定性", "Refined main window focus and refresh callback bindings for enhanced menu bar responsiveness")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.12",
                version: "v1.0.12",
                date: "2026-08-25",
                changes: [
                    L10n.text("新增下载更新时实时显示下载进度条与百分比（从 0% 起始终保持滚动条展示）", "Enhanced in-app update downloading with persistent progress bar and percentage tracker from 0% onwards"),
                    L10n.text("在设置「存储与诊断」新增「一键重置 App 与出厂设置」功能，支持安全清除本地数据、还原默认配置并重新读取记录", "Added one-click Factory Reset & Read Again in Settings storage pane with safety confirmation dialog"),
                    L10n.text("彻底解决升级弹窗更新日志显示 HTML 标签乱码问题，并支持条目全语言多维度本地化翻译", "Fixed update dialog changelog HTML tag artifacts with automated multi-language localization"),
                    L10n.text("全面完善 10 种语言的多语言本地化翻译字典", "Comprehensive localized translation coverage across 10 supported languages")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.11",
                version: "v1.0.11",
                date: "2026-08-25",
                changes: [
                    L10n.text("全新重构「本地记录与问题报告」卡片排版为现代化自适应 4 列网格，重点突出 12 项关键健康指标", "Redesigned local records and report layout into a modern adaptive 4-column grid highlighting 12 key health metrics"),
                    L10n.text("优化升级弹窗视觉细节，移除弹窗顶部横条，呈现纯净圆角卡片质感", "Polished update dialog visual aesthetics by removing top gradient bar for a sleek border design"),
                    L10n.text("修复更新日志在多语言环境下的刷新机制，所有非简体中文语言点击刷新均可拉取并自动本地化翻译", "Fixed changelog refresh for all supported non-Simplified-Chinese languages with instant localized translation"),
                    L10n.text("加固重置卡数据解析与容错逻辑，兼容多种服务端命名格式并增加空明细智能兜底", "Hardened reset card decoding resilience against varied payload formats with smart empty-state fallbacks")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.10",
                version: "v1.0.10",
                date: "2026-08-25",
                changes: [
                    L10n.text("全新重构设置界面为 5 大分类 Tab 架构（常规外观、账号同步、悬浮挂件、Codex 环境、存储诊断），告别冗长滚动", "Restructured Settings view into a 5-tab layout (General, Account, Overlay, Codex, Storage) with persistent state and zero long-scrolling"),
                    L10n.text("升级弹窗全新高颜值重构，支持版本跃迁对比、安装包体积展示（如 📦 7.3 MB）与更新日志独立滚动面板", "Redesigned software update dialog with version transition badges, download package size, and scrollable release notes panel"),
                    L10n.text("新增模型推理级别（Reasoning Effort）深度解析，并在历史明细与会话详情中以高对比度渐变徽章醒目展示", "Parsed model reasoning effort levels from Codex sessions and displayed high-contrast reasoning badges in history and session views"),
                    L10n.text("会话列表支持按项目（代码工作区）分组与过滤筛选，支持一键折叠展开并统计项目用量", "Added project-based session grouping, filtering chips, and expand/collapse support with project usage totals"),
                    L10n.text("新增 Prompt 缓存命中率与节约效益分析，并在主看板增加配额耗尽与重置卡智能建议横幅", "Added prompt cache hit rate efficiency analysis and smart suggestion banners for quota exhaustion and reset cards"),
                    L10n.text("优化当日无活动时的友好空状态展示，精简掉默认的 DEFAULT/STANDARD 服务层级标签", "Refined empty-day activity cards with user-friendly copy and removed redundant default service tier badges")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.9",
                version: "v1.0.9",
                date: "2026-08-25",
                changes: [
                    L10n.text("新增会话删除与安全清理能力，支持将 Codex 本地记录移至废纸篓，并同步清理 QuotaLens 中的相关统计", "Session deletion with Trash support and matching cleanup of related QuotaLens summaries"),
                    L10n.text("新增配额耗尽（0% 配额）预警与专属状态展示，并在配额耗尽时智能静默预测", "Dedicated quota exhausted state handling and intelligent forecast suppression"),
                    L10n.text("全面升级全息悬浮窗交互，支持磁吸贴边、自由拖拽定位与置顶固定状态记忆", "Enhanced floating HUD overlay with magnetic edge snapping, dragging, and pin persistence"),
                    L10n.text("用量分析看板与年度热力图新增鼠标跟随悬浮详情卡片，并大幅优化历史全天汇总查询性能", "Pointer-following detail cards for usage charts and heatmap with faster compact summary queries"),
                    L10n.text("优化 Dock 图标聚焦与菜单栏弹窗交互行为，关于页更新日志支持多语言自适应显示", "Refined Dock and menu bar activation behaviors, with localized changelog rendering")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.8",
                version: "v1.0.8",
                date: "2026-08-25",
                changes: [
                    L10n.text("新增 Codex 本地历史用量读取，支持快速更新 Token 统计与费用估算", "Added local Codex history reading for fast token summaries and estimated cost"),
                    L10n.text("新增配额消耗预测引擎（基于线性投影与历史会话特征预估周期耗尽时间与建议节奏）", "Quota consumption forecast engine with linear projection and runout estimation"),
                    L10n.text("新增「会话明细」与「历史用量」分析看板，支持按会话、模型、分支多维度聚合统计", "Interactive session breakdown and usage analytics dashboard"),
                    L10n.text("新增独立全息悬浮置顶窗与菜单栏交互增强，实时监控用量与重置倒计时", "Floating HUD overlay window and enhanced menu bar interactions"),
                    L10n.text("修复在线检查更新源 URL 缓存问题，确保每次请求均拉取远端最新版本", "Fixed update feed cache-busting to ensure latest release metadata")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.7",
                version: "v1.0.7",
                date: "2026-08-24",
                changes: [
                    L10n.text("全面优化「确认使用重置卡」弹窗 Cyber 视觉质感，并严格按规则智能生成确认提示文案", "Refined reset card confirmation dialog visual aesthetics with smart rule-based copy"),
                    L10n.text("顶栏左侧升级为动态展示当前菜单名称，并将 App 品牌整合至侧边栏底座", "Dynamic top bar title reflecting active tab and brand integration in sidebar footer"),
                    L10n.text("全局清理各菜单页面内容顶部的冗余大标题，将概览页视图模式与同步状态下沉至 Hero 卡片", "Cleaned up redundant page titles and streamlined overview controls into Hero header"),
                    L10n.text("倒计时与建议日均消耗全面升级为秒级精确度，接入 TimelineView 实现每秒实时平滑跳动", "Upgraded countdown and daily budget pace to real-time second-level precision"),
                    L10n.text("全面覆盖 10 种语言的多语言本地化翻译", "Complete localized translations for 10 supported languages")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.6",
                version: "v1.0.6",
                date: "2026-08-24",
                changes: [
                    L10n.text("更新日志与开源协议升级为动态网络拉取，每次点开弹窗时自动获取最新发布内容", "Dynamic fetching and manual refresh for changelog & license"),
                    L10n.text("修复当前版本高亮匹配逻辑，与当前运行应用版本实时保持一致", "Fixed current version matching algorithm to accurately highlight active release")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.5",
                version: "v1.0.5",
                date: "2026-08-24",
                changes: [
                    L10n.text("新增建议日均消耗微卡片，根据当前周期的剩余时间与剩余配额智能推算均摊用量", "Added daily budget pace module based on cycle remaining time and quota"),
                    L10n.text("全局清理页面与侧边栏次级说明小字，提升界面清爽与精致度", "Cleaned up auxiliary subtitles and tags across pages and sidebar"),
                    L10n.text("全面覆盖 10 种语言的多语言本地化翻译并清理冗余词条", "Complete 10-language localized translations and code cleanup")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.4",
                version: "v1.0.4",
                date: "2026-08-24",
                changes: [
                    L10n.text("简化版本信息与页面标记，让界面更清爽", "Simplified version information and page labels for a cleaner interface"),
                    L10n.text("更新日志与开源协议采用应用内可滚动弹窗展示，并支持一键复制", "In-app scrollable dialogs for changelog and license with one-click copy support"),
                    L10n.text("进一步优化全息卡片间距与界面精致度", "Refined card spacing and visual aesthetics")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.3",
                version: "v1.0.3",
                date: "2026-08-24",
                changes: [
                    L10n.text("全新关于页面 UI 排版重构，引入 Hero 品牌中心与 2x3 核心特性矩阵", "Redesigned About view layout with Hero brand center and 2x3 feature grid"),
                    L10n.text("全面覆盖 10 种语言的多语言本地化翻译", "Complete localized translations for 10 supported languages"),
                    L10n.text("优化在线升级交互与状态指示面板", "Polished online update interactions and status indicators")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.2",
                version: "v1.0.2",
                date: "2026-08-24",
                changes: [
                    L10n.text("修复在线升级检测与版本比对流程", "Fixed in-app update checking and version comparison"),
                    L10n.text("统一语言与偏好设置图标", "Unified language and preference setting icons")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.1",
                version: "v1.0.1",
                date: "2026-08-24",
                changes: [
                    L10n.text("新增轻量菜单栏模式与 Dock 隐藏支持", "Added menu bar compact mode and optional hidden Dock icon"),
                    L10n.text("优化 ChatGPT 与 Codex 额度快照读取", "Improved ChatGPT and Codex quota snapshot reading")
                ]
            ),
            ChangelogEntry(
                id: "v1.0.0",
                version: "v1.0.0",
                date: "2026-08-24",
                changes: [
                    L10n.text("QuotaLens 正式发布！首发支持实时配额监控、重置卡追踪与周期推算", "Initial release of QuotaLens with real-time quota tracking, reset card alerts, and cycle detection")
                ]
            )
        ]
    }

    private var displayedChangelogs: [ChangelogEntry] {
        remoteChangelogs ?? defaultChangelogs
    }

    private var displayedLicenseText: String {
        remoteLicenseText ?? apacheLicenseText
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
                title: L10n.text("多工具额度总览", "Cross-Tool Quota Overview"),
                description: L10n.text("统一查看 Codex、Claude 与 Antigravity 的多周期及模型额度", "See multi-window and model quotas for Codex, Claude, and Antigravity."),
                tintColor: cyan
            ),
            FeatureItem(
                icon: "chart.bar.xaxis",
                title: L10n.text("用量与活动分析", "Usage & Activity Analytics"),
                description: L10n.text("汇总会话、Token、模型构成、任务趋势与项目活动", "Explore sessions, tokens, model mix, task trends, and project activity."),
                tintColor: blue
            ),
            FeatureItem(
                icon: "clock.arrow.2.circlepath",
                title: L10n.text("节奏与恢复预测", "Pace & Recovery Forecasts"),
                description: L10n.text("根据近期趋势预测额度耗尽与重置，并给出节奏建议", "Forecast quota runout and resets from recent trends, with practical pace guidance."),
                tintColor: amber
            ),
            FeatureItem(
                icon: "macwindow.badge.plus",
                title: L10n.text("智能窗口挂件", "Context-Aware Overlays"),
                description: L10n.text("随前台 Codex、Claude 或 Antigravity 自动切换并贴靠窗口", "Follow the foreground Codex, Claude, or Antigravity window automatically."),
                tintColor: purple
            ),
            FeatureItem(
                icon: "menubar.rectangle",
                title: L10n.text("菜单栏即时监控", "Menu Bar Monitoring"),
                description: L10n.text("常驻显示已用或可用额度、重置倒计时与同步状态", "Keep used or available quota, reset timing, and sync status at a glance."),
                tintColor: emerald
            ),
            FeatureItem(
                icon: "lock.shield.fill",
                title: L10n.text("本地优先与隐私", "Local-First Privacy"),
                description: L10n.text("只读取已启用工具的数据，分析结果保存在本机", "Read only enabled tool data and keep analytics on your Mac."),
                tintColor: cyan
            )
        ]
    }

    public var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 20) {
                    heroBrandCard
                    updateCenterCard
                    featureGridCard
                    footerInfo
                }
                .padding(24)
            }
            .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

            // 弹窗遮罩层
            if let modal = activeModal {
                modalOverlayView(for: modal)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: activeModal != nil)
        .onChange(of: state.languageMode) { _, _ in
            remoteChangelogs = nil
            if activeModal == .changelog {
                Task { await fetchRemoteChangelogs() }
            }
        }
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
                    }

                    // Slogan 定位
                    Text(L10n.text("在 macOS 上统一掌握 Codex、Claude 与 Antigravity 的额度和用量", "Quota and usage insights for Codex, Claude, and Antigravity on macOS."))
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
                    action: {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            activeModal = .changelog
                        }
                        Task {
                            await fetchRemoteChangelogs()
                        }
                    }
                )

                quickLinkButton(
                    icon: "ladybug.fill",
                    title: L10n.text("问题反馈", "Feedback"),
                    action: { updateManager.openIssuesPage() }
                )

                quickLinkButton(
                    icon: "doc.text.fill",
                    title: L10n.text("开源协议", "License"),
                    action: {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            activeModal = .license
                        }
                        Task {
                            await fetchRemoteLicense()
                        }
                    }
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
            Text(L10n.text("专为 macOS 打造", "Designed for macOS"))
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

    // MARK: - 弹窗遮罩视图
    @ViewBuilder
    private func modalOverlayView(for modal: AboutModalType) -> some View {
        let isDark = colorScheme == .dark
        let cyan = AppTheme.accentCyan(for: colorScheme)
        let isFetching = modal == .changelog ? isFetchingChangelog : isFetchingLicense

        ZStack {
            // 背景暗色遮罩
            Color.black.opacity(isDark ? 0.58 : 0.38)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        activeModal = nil
                    }
                }

            // 居中卡片容器
            VStack(alignment: .leading, spacing: 14) {
                // Header
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: modal == .changelog ? "list.bullet.rectangle.portrait.fill" : "doc.text.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(cyan)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(modal == .changelog ? L10n.text("更新日志", "Changelog") : L10n.text("开源许可证 (Apache License 2.0)", "Open Source License (Apache License 2.0)"))
                                .font(.system(size: 15, weight: .black, design: .rounded))
                                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                            HStack(spacing: 6) {
                                if isFetching {
                                    ProgressView()
                                        .controlSize(.mini)
                                    Text(L10n.text("正在获取最新内容...", "Fetching latest updates..."))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(cyan)
                                } else {
                                    Text(modal == .changelog ? L10n.text("版本发布历史与更新日志", "Release history and changelog") : "Apache License 2.0")
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                                }
                            }
                        }
                    }

                    Spacer()

                    // 手动刷新按钮
                    Button(action: {
                        Task {
                            if modal == .changelog {
                                await fetchRemoteChangelogs()
                            } else {
                                await fetchRemoteLicense()
                            }
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(isFetching ? cyan : AppTheme.textSecondary(for: colorScheme))
                            .frame(width: 26, height: 26)
                            .background(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isFetching)

                    // 关闭按钮
                    Button(action: {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            activeModal = nil
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                            .frame(width: 26, height: 26)
                            .background(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                CyberDivider()

                // 内容滚动区域
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if modal == .changelog {
                            changelogContent
                        } else {
                            licenseContent
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 360)

                CyberDivider()

                // 底部操作栏
                HStack {
                    if modal == .license {
                        Button(action: copyLicenseToClipboard) {
                            HStack(spacing: 5) {
                                Image(systemName: isLicenseCopied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 11, weight: .bold))
                                Text(isLicenseCopied ? L10n.text("已复制", "Copied") : L10n.text("复制协议", "Copy License"))
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8))
                            .foregroundStyle(isLicenseCopied ? AppTheme.accentEmerald(for: colorScheme) : AppTheme.textPrimary(for: colorScheme))
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    Button(action: {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            activeModal = nil
                        }
                    }) {
                        Text(L10n.text("关闭", "Close"))
                            .font(.system(size: 12, weight: .bold))
                            .padding(.horizontal, 18)
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
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            .frame(width: 580)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isDark ? Color(red: 0.085, green: 0.105, blue: 0.165) : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(cyan.opacity(isDark ? 0.35 : 0.25), lineWidth: 1.0)
            )
            .shadow(color: Color.black.opacity(isDark ? 0.55 : 0.22), radius: 26, x: 0, y: 14)
        }
    }

    // MARK: - 更新日志内容
    private var changelogContent: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)

        return VStack(alignment: .leading, spacing: 16) {
            ForEach(displayedChangelogs) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(entry.version)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(entry.isCurrent ? cyan : AppTheme.textPrimary(for: colorScheme))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(
                                (entry.isCurrent ? cyan : Color.gray).opacity(0.12),
                                in: Capsule()
                            )

                        if entry.isCurrent {
                            Text(L10n.text("当前版本", "Current Version"))
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(AppTheme.accentEmerald(for: colorScheme))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(AppTheme.accentEmerald(for: colorScheme).opacity(0.12), in: Capsule())
                        }

                        Spacer()

                        if !entry.date.isEmpty {
                            Text(entry.date)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(entry.changes, id: \.self) { change in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(cyan)
                                Text(L10n.localizeChangelogText(change))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.leading, 4)
                }
                .padding(12)
                .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
                )
            }
        }
    }

    // MARK: - 开源协议内容
    private var licenseContent: some View {
        Text(displayedLicenseText)
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(AppTheme.textPrimary(for: colorScheme).opacity(0.92))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.8)
            )
            .textSelection(.enabled)
    }

    private func copyLicenseToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(displayedLicenseText, forType: .string)
        withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
            isLicenseCopied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                isLicenseCopied = false
            }
        }
    }

    // MARK: - 异步网络拉取逻辑
    @MainActor
    private func fetchRemoteChangelogs() async {
        isFetchingChangelog = true
        defer { isFetchingChangelog = false }

        remoteChangelogs = nil
        let requestedLanguage = L10n.language

        // 1. 优先拉取 raw CHANGELOG.md（包含详细改动项）
        let changelogURL = URL(string: "https://raw.githubusercontent.com/yuangy1995/QuotaLens/main/CHANGELOG.md")!
        var request = URLRequest(url: changelogURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 8)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let text = String(data: data, encoding: .utf8) {
                let parsed = parseMarkdownChangelog(text)
                if !parsed.isEmpty, L10n.language == requestedLanguage {
                    remoteChangelogs = parsed
                    return
                }
            }
        } catch {
            // 继续尝试 GitHub Releases API
        }

        // 2. 备用方案：拉取 GitHub Releases API
        let releasesURL = URL(string: "https://api.github.com/repos/yuangy1995/QuotaLens/releases?per_page=20")!
        var relRequest = URLRequest(url: releasesURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 8)
        relRequest.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        relRequest.setValue("QuotaLens-App", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: relRequest)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                let parsed = parseGitHubReleases(data)
                if !parsed.isEmpty, L10n.language == requestedLanguage {
                    remoteChangelogs = parsed
                }
            }
        } catch {
            // 失败时保留 fallback
        }
    }

    @MainActor
    private func fetchRemoteLicense() async {
        isFetchingLicense = true
        defer { isFetchingLicense = false }

        let licenseURL = URL(string: "https://raw.githubusercontent.com/yuangy1995/QuotaLens/main/LICENSE")!
        var request = URLRequest(url: licenseURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 8)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let text = String(data: data, encoding: .utf8), !text.isEmpty {
                remoteLicenseText = text
            }
        } catch {
            // 失败时使用本地内置
        }
    }

    private func parseMarkdownChangelog(_ text: String) -> [ChangelogEntry] {
        var entries: [ChangelogEntry] = []
        let lines = text.components(separatedBy: .newlines)

        var currentVersion = ""
        var currentDate = ""
        var currentChanges: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                if !currentVersion.isEmpty && !currentChanges.isEmpty {
                    entries.append(ChangelogEntry(
                        id: currentVersion,
                        version: currentVersion,
                        date: currentDate,
                        changes: currentChanges
                    ))
                }
                currentChanges = []
                let headerContent = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                let parts = headerContent.components(separatedBy: " - ")
                if let vPart = parts.first {
                    currentVersion = vPart.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "").trimmingCharacters(in: .whitespaces)
                }
                currentDate = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                let change = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !change.isEmpty {
                    currentChanges.append(change)
                }
            }
        }

        if !currentVersion.isEmpty && !currentChanges.isEmpty {
            entries.append(ChangelogEntry(
                id: currentVersion,
                version: currentVersion,
                date: currentDate,
                changes: currentChanges
            ))
        }

        return entries
    }

    private struct GitHubReleaseDTO: Decodable {
        let tag_name: String
        let published_at: String?
        let body: String?
    }

    private func parseGitHubReleases(_ data: Data) -> [ChangelogEntry] {
        guard let items = try? JSONDecoder().decode([GitHubReleaseDTO].self, from: data) else { return [] }
        return items.compactMap { release in
            let version = release.tag_name
            let rawDate = release.published_at ?? ""
            let date = rawDate.prefix(10).isEmpty ? "" : String(rawDate.prefix(10))
            var changes: [String] = []

            if let body = release.body {
                let lines = body.components(separatedBy: .newlines)
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if (trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ")) && !trimmed.lowercased().contains("downloads") && !trimmed.lowercased().contains("check `sha256sums") {
                        let change = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                        if !change.isEmpty {
                            changes.append(change)
                        }
                    }
                }
            }

            if changes.isEmpty {
                changes.append(L10n.text("版本性能与稳定性优化", "Performance and stability improvements"))
            }

            return ChangelogEntry(
                id: version,
                version: version,
                date: date,
                changes: changes
            )
        }
    }

    private var apacheLicenseText: String {
        """
                                         Apache License
                                   Version 2.0, January 2004
                                http://www.apache.org/licenses/

        TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

        1. Definitions.

           "License" shall mean the terms and conditions for use, reproduction,
           and distribution as defined by Sections 1 through 9 of this document.

           "Licensor" shall mean the copyright owner or entity authorized by
           the copyright owner that is granting the License.

           "Entity" shall mean the union of the acting entity and all other
           entities that control, are controlled by, or are under common control
           with that entity. For the purposes of this definition,
           "control" means (i) the power, direct or indirect, to cause the
           direction or management of such entity, whether by contract or
           otherwise, or (ii) ownership of fifty percent (50%) or more of the
           outstanding shares, or (iii) beneficial ownership of such entity.

           "You" (or "Your") shall mean an individual or Legal Entity
           exercising permissions granted by this License.

           "Source" form shall mean the preferred form for making modifications,
           including but not limited to software source code, documentation
           source, and configuration files.

           "Object" form shall mean any form resulting from mechanical
           transformation or translation of a Source form, including but
           not limited to compiled object code, generated documentation,
           and conversions to other media types.

           "Work" shall mean the work of authorship, whether in Source or
           Object form, made available under the License, as indicated by a
           copyright notice that is included in or attached to the work.

           "Derivative Works" shall mean any work, whether in Source or
           Object form, that is based on (or derived from) the Work and for
           which the editorial revisions, annotations, elaborations, or other
           modifications represent, as a whole, an original work of authorship.

           "Contribution" shall mean any work of authorship, including
           the original version of the Work and any modifications or additions
           to that Work or Derivative Works thereof, that is intentionally
           submitted to Licensor for inclusion in the Work.

           "Contributor" shall mean Licensor and any individual or Legal Entity
           on behalf of whom a Contribution has been received by Licensor and
           subsequently incorporated within the Work.

        2. Grant of Copyright License. Subject to the terms and conditions of
           this License, each Contributor hereby grants to You a perpetual,
           worldwide, non-exclusive, no-charge, royalty-free, irrevocable
           copyright license to reproduce, prepare Derivative Works of,
           publicly display, publicly perform, sublicense, and distribute the
           Work and such Derivative Works in Source or Object form.

        3. Grant of Patent License. Subject to the terms and conditions of
           this License, each Contributor hereby grants to You a perpetual,
           worldwide, non-exclusive, no-charge, royalty-free, irrevocable
           patent license to make, have made, use, offer to sell, sell, import,
           and otherwise transfer the Work.

        4. Redistribution. You may reproduce and distribute copies of the
           Work or Derivative Works thereof in any medium, with or without
           modifications, and in Source or Object form, provided that You
           meet the conditions stated in this License.

        5. Submission of Contributions. Unless You explicitly state otherwise,
           any Contribution intentionally submitted for inclusion in the Work
           by You to the Licensor shall be under the terms and conditions of
           this License.

        6. Trademarks. This License does not grant permission to use the trade
           names, trademarks, service marks, or product names of the Licensor.

        7. Disclaimer of Warranty. Unless required by applicable law or
           agreed to in writing, Licensor provides the Work on an "AS IS" BASIS,
           WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND.

        8. Limitation of Liability. In no event shall any Contributor be
           liable to You for damages arising as a result of this License or
           out of the use or inability to use the Work.

        9. Accepting Warranty or Additional Liability. You may choose to offer
           support, warranty, indemnity, or other liability obligations and/or
           rights consistent with this License.

        END OF TERMS AND CONDITIONS
        """
    }
}
