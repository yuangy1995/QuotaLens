// 应用轻量级本地化辅助工具。

import Foundation

public enum AppLanguage: String, CaseIterable, Sendable, Hashable {
    case english
    case simplifiedChinese
    case traditionalChinese
    case japanese
    case korean
    case spanish
    case german
    case french
    case portuguese
    case portugueseBrazil

    public var locale: Locale {
        Locale(identifier: localeIdentifier)
    }

    public var localeIdentifier: String {
        switch self {
        case .english: return "en_US"
        case .simplifiedChinese: return "zh_Hans_CN"
        case .traditionalChinese: return "zh_Hant_TW"
        case .japanese: return "ja_JP"
        case .korean: return "ko_KR"
        case .spanish: return "es_ES"
        case .german: return "de_DE"
        case .french: return "fr_FR"
        case .portuguese: return "pt_PT"
        case .portugueseBrazil: return "pt_BR"
        }
    }

    public var nativeName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .spanish: return "Español"
        case .german: return "Deutsch"
        case .french: return "Français"
        case .portuguese: return "Português"
        case .portugueseBrazil: return "Português (Brasil)"
        }
    }
}

public enum AppLanguageMode: String, CaseIterable, Identifiable, Sendable, Hashable {
    case system
    case english
    case simplifiedChinese
    case traditionalChinese
    case japanese
    case korean
    case spanish
    case german
    case french
    case portuguese
    case portugueseBrazil

    public var id: String { rawValue }

    public var language: AppLanguage? {
        switch self {
        case .system: return nil
        case .english: return .english
        case .simplifiedChinese: return .simplifiedChinese
        case .traditionalChinese: return .traditionalChinese
        case .japanese: return .japanese
        case .korean: return .korean
        case .spanish: return .spanish
        case .german: return .german
        case .french: return .french
        case .portuguese: return .portuguese
        case .portugueseBrazil: return .portugueseBrazil
        }
    }

    public var title: String {
        switch self {
        case .system:
            return L10n.text("跟随系统", "Follow System")
        case .english:
            return AppLanguage.english.nativeName
        case .simplifiedChinese:
            return AppLanguage.simplifiedChinese.nativeName
        case .traditionalChinese:
            return AppLanguage.traditionalChinese.nativeName
        case .japanese:
            return AppLanguage.japanese.nativeName
        case .korean:
            return AppLanguage.korean.nativeName
        case .spanish:
            return AppLanguage.spanish.nativeName
        case .german:
            return AppLanguage.german.nativeName
        case .french:
            return AppLanguage.french.nativeName
        case .portuguese:
            return AppLanguage.portuguese.nativeName
        case .portugueseBrazil:
            return AppLanguage.portugueseBrazil.nativeName
        }
    }

    public var detail: String {
        switch self {
        case .system:
            return L10n.format("Using macOS language: %@", zhHans: "使用 macOS 语言：%@", L10n.systemLanguage.nativeName)
        case .english, .simplifiedChinese, .traditionalChinese, .japanese, .korean, .spanish, .german, .french, .portuguese, .portugueseBrazil:
            return L10n.format("Pinned to %@", zhHans: "固定为 %@", language?.nativeName ?? title)
        }
    }

    public var icon: String {
        "globe"
    }
}

public enum L10n {
    public static let languageModeDefaultsKey = "QuotaLens.languageMode"

    public static var languageMode: AppLanguageMode {
        let stored = UserDefaults.standard.string(forKey: languageModeDefaultsKey)
        return AppLanguageMode(rawValue: stored ?? "") ?? .system
    }

    public static var language: AppLanguage {
        languageMode.language ?? systemLanguage
    }

    public static var systemLanguage: AppLanguage {
        for identifier in Locale.preferredLanguages {
            let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            if normalized.hasPrefix("zh-hant")
                || normalized.hasPrefix("zh-tw")
                || normalized.hasPrefix("zh-hk")
                || normalized.hasPrefix("zh-mo") {
                return .traditionalChinese
            }
            if normalized.hasPrefix("zh") {
                return .simplifiedChinese
            }
            if normalized.hasPrefix("ja") { return .japanese }
            if normalized.hasPrefix("ko") { return .korean }
            if normalized.hasPrefix("es") { return .spanish }
            if normalized.hasPrefix("de") { return .german }
            if normalized.hasPrefix("fr") { return .french }
            if normalized.hasPrefix("pt-br") { return .portugueseBrazil }
            if normalized.hasPrefix("pt") { return .portuguese }
            if normalized.hasPrefix("en") { return .english }
        }

        switch Locale.autoupdatingCurrent.language.languageCode?.identifier.lowercased() {
        case "zh":
            return .simplifiedChinese
        case "ja":
            return .japanese
        case "ko":
            return .korean
        case "es":
            return .spanish
        case "de":
            return .german
        case "fr":
            return .french
        case "pt":
            return .portuguese
        default:
            return .english
        }
    }

    public static var isChinese: Bool {
        language == .simplifiedChinese || language == .traditionalChinese
    }

    public static var locale: Locale {
        language.locale
    }

    public static func text(_ zhHans: String, _ english: String) -> String {
        localized(english, zhHans: zhHans)
    }

    public static func localized(_ english: String, zhHans: String? = nil) -> String {
        switch language {
        case .english:
            return english
        case .simplifiedChinese:
            return zhHans ?? translations[.simplifiedChinese]?[english] ?? english
        default:
            return multiToolTranslations[language]?[english]
                ?? extendedTranslations[english]?[language]
                ?? keyedTranslations[english]?[language]
                ?? translations[language]?[english]
                ?? english
        }
    }

    public static func format(_ english: String, zhHans: String, _ arguments: CVarArg...) -> String {
        let pattern = localized(english, zhHans: zhHans)
        return String(format: pattern, locale: locale, arguments: arguments)
    }

    public static func duration(seconds totalSeconds: Int) -> String {
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes == 0 {
            return format("%d seconds short", zhHans: "%d 秒", totalSeconds)
        }
        if seconds == 0 {
            return format("%d minutes short", zhHans: "%d 分钟", minutes)
        }
        return format("%d minutes %d seconds short", zhHans: "%d 分 %d 秒", minutes, seconds)
    }

    public static func countdown(days: Int64, hours: Int64, minutes: Int64, seconds: Int64) -> String {
        if days > 0 {
            return format("%lldd %lldh %lldm %llds", zhHans: "%lld天 %lld小时 %lld分 %lld秒", days, hours, minutes, seconds)
        } else if hours > 0 {
            return format("%lldh %lldm %llds", zhHans: "%lld小时 %lld分 %lld秒", hours, minutes, seconds)
        } else if minutes > 0 {
            return format("%lldm %llds", zhHans: "%lld分 %lld秒", minutes, seconds)
        } else {
            return format("%llds", zhHans: "%lld秒", seconds)
        }
    }

    public static func countdown(days: Int64, hours: Int64, minutes: Int64) -> String {
        countdown(days: days, hours: hours, minutes: minutes, seconds: 0)
    }

    public static func compactHundredMillionUnit(_ value: String, sign: String) -> String {
        switch language {
        case .simplifiedChinese:
            return "\(sign)\(value)亿"
        case .traditionalChinese:
            return "\(sign)\(value)億"
        default:
            return "\(sign)\(value)M"
        }
    }

    public static func compactTenThousandUnit(_ value: String, sign: String) -> String {
        switch language {
        case .simplifiedChinese:
            return "\(sign)\(value)万"
        case .traditionalChinese:
            return "\(sign)\(value)萬"
        default:
            return "\(sign)\(value)K"
        }
    }

    public static let changelogZhToEnMap: [String: String] = [
        "重构 Codex 连接、重连与额度刷新状态，连接失败和缓存数据现在会准确显示": "Reworked Codex connection, reconnection, and quota refresh states so failures and cached data are shown accurately",
        "严格校验额度与重置卡响应，并将 Claude 登录凭据安全迁移至 macOS 钥匙串": "Added strict validation for quota and reset card responses, and moved Claude sign-in credentials to macOS Keychain",
        "优化大型历史记录导入、汇总查询和后台监听，显著降低启动、CPU 与内存占用": "Optimized large history imports, summary queries, and background monitoring to significantly reduce startup time, CPU use, and memory use",
        "改进本地多账号识别与跨架构安装包验证，提升 Apple Silicon、Intel 和 Universal 版本的发布可靠性": "Improved local multi-account identification and cross-architecture package checks for more reliable Apple Silicon, Intel, and Universal releases",
        "新增周度配额完全恢复（100%）智能气泡提醒，支持多工具额度满血通知与一键快捷交互": "Introduced weekly quota full recovery (100%) notification bubbles with cross-tool status alerts and quick interactions",
        "优化菜单栏状态图标与指示环排版，支持在状态栏直观切换已用与可用额度视角": "Optimized menu bar status item indicators and ring layout with intuitive toggling between used and available quota perspectives",
        "深度优化 Antigravity 与 Codex 全息悬浮挂件的吸附平滑度与窗口前台感知链路": "Deeply refined floating overlay snapping smoothness and foreground window awareness across Antigravity and Codex",
        "全面接入 Google Antigravity (AGY) 智能体编程工具生态，支持多周期模型配额与本机活跃度监控": "Full integration with Google Antigravity (AGY) agentic ecosystem with multi-window quota and local activity monitoring",
        "新增 Antigravity 专属全息悬浮挂件与自动吸附定位，支持随前台应用智能唤醒与模型余量一览": "Dedicated Antigravity floating overlay with smart window snapping, foreground auto-wake, and real-time model quota breakdown",
        "在菜单栏、总览看板与设置中深度集成 Antigravity 指标卡片、任务趋势与多空间无缝切换": "Deeply integrated Antigravity metric cards, task trends, and multi-workspace switching across menu bar, overview, and settings",
        "引入 Claude (Claude Code / Cursor) 多工具生态用量监控体系，支持 OAuth 授权与多周期配额轮询": "Introduced Claude (Claude Code / Cursor) multi-tool usage monitoring with OAuth authorization and multi-cycle quota polling",
        "全新升级统一「总览」看板与多工具导航中心，支持 Codex 与 Claude 跨工具配额一览与智能联动": "Upgraded unified Overview dashboard and multi-tool navigation hub for seamless cross-tool quota overview and smart linkage",
        "重构全息悬浮挂件多工具协同调度器，支持根据当前前台活跃的 AI 编程工具智能自动切换展示视角": "Restructured floating overlay multi-tool coordinator to intelligently auto-switch display perspectives based on the active foreground tool",
        "架构级重构 Codex 悬浮挂件定位与吸附感知引擎，模块化解耦辅助功能锚点读取与坐标计算": "Architectural refactor of Codex overlay positioning and snapping engine, decoupling accessibility anchor detection and geometry calculation",
        "升级精准锚定算法：直接定位 Codex 窗口与其内部 Help 按钮锚点，完全无需读取任何对话正文，彻底保障用户隐私": "Upgraded precision anchoring: directly targets Codex window and Help button anchors without reading any conversation text for total privacy",
        "优化悬浮挂件吸附与重置交互，支持一键恢复挂件在 Codex 窗口内的智能默认吸附位置": "Refined overlay snapping and reset interactions with one-click restoration to the intelligent default position inside the Codex window",
        "新增 Codex 会话正文按需解析与对话记录回放，支持在会话详情中直接浏览用户提示词与助手完整回复": "Introduced on-demand Codex conversation parsing and message history viewer in session details for user prompts and assistant replies",
        "支持会话标题与对话正文全文混合检索，秒级过滤历史对话内容并自动匹配相关工程上下文": "Full-text hybrid search across session titles and conversation bodies with instant filtering and project context matching",
        "优化会话明细卡片排版，支持「对话内容」与「用量统计」无缝分栏切换与附件标记识别": "Refined session detail layout with seamless switching between Conversation and Usage tabs along with attachment badges",
        "深度优化全界面异步数据加载机制，引入防抖过滤与按需刷新，大幅降低高频切换时的 CPU 与数据库 I/O 占用": "Deeply optimized asynchronous UI data loading with debouncing and on-demand refresh, reducing CPU and database I/O overhead",
        "重构用量看板预测引擎响应链路，实现轻量级额度变化即时计算与重度历史分析按需解耦": "Decoupled usage dashboard forecast calculations from heavy historical queries for instant rate limit updates and smoother interaction",
        "优化菜单栏常驻面板与悬浮挂件的生命周期交互，提升多屏协同与窗口切换时的响应流畅度": "Refined menu bar popover and floating overlay lifecycle interactions, enhancing smoothness during multi-display and window transitions",
        "引入 5 小时与周度双周期配额预算与建议节奏引擎，根据窗口类型自动按小时/天智能推算合理配额消耗": "Introduced dual-window quota pace budget engine for 5-hour and weekly cycles with window-aware hourly/daily consumption pace",
        "动态调整 5 小时短周期的预测门限与采样新鲜度，支持高频周度快照保留并提升预测覆盖率": "Dynamically adjusted forecast thresholds and sampling freshness for 5-hour windows with enhanced snapshot retention",
        "增强多账号额度同步与历史快照存储持久化，提升 JSON-RPC 传输容错与弱网恢复能力": "Hardened multi-account quota snapshot persistence and JSON-RPC transport resilience against network fluctuations",
        "优化菜单栏、全息悬浮窗与看板对 5 小时周期的环形指示与文案感知，全方位完善 10 种语言本地化": "Optimized 5-hour cycle ring indicators and contextual labels across menu bar, overlay, and dashboard with 10-language translations",
        "全新升级全息悬浮挂件交互与智能感知：支持「仅在目标应用前台时显示」自动防打扰，并新增一键重置吸附位置": "Upgraded floating overlay interactions: added auto-hide when target app is inactive and one-click position reset",
        "优化悬浮挂件视觉排版与隐私保护模式提示，增强已用/可用配额视角的平滑切换": "Refined overlay layout and privacy-preserved mode indicator with smooth view switching between used and available quota",
        "重构用量看板预测卡片布局，实现自适应等高对齐并提升多分辨率下的展示美观度": "Restructured usage dashboard forecast cards with adaptive equal-height alignment for enhanced layout aesthetics across displays",
        "全面完善 10 种语言的多语言本地化翻译字典与更新日志多语言映射": "Comprehensive localization dictionary refinements and changelog translation mapping across 10 supported languages",
        "全新升级 Codex 计费与定价目录引擎，支持模型历史分段价格、缓存命中折算与多周期计费回溯": "Upgraded Codex pricing and catalog engine with historical tiered pricing, prompt cache savings, and multi-cycle cost auditing",
        "重构数据索引与数据库重建机制，增强原子化写入、损坏文件自动隔离与跨时区自然日精确对齐": "Restructured data indexing and database rebuild pipeline with atomic commits, corrupted file quarantine, and timezone alignment",
        "强化重置卡明细持久化与容错解析能力，在多账号切换与同步中提供平滑兜底与状态占位": "Hardened reset card persistence and lossy decoding resilience across account switches and syncing gaps",
        "优化历史明细、用量看板与设置界面的高频刷新性能与内存占用": "Optimized memory footprint and high-frequency refresh performance across history, dashboard, and settings views",
        "优化 App 启动阶段菜单栏控制器初始化生命周期，确保冷启动时即刻可靠挂载菜单栏图标并响应交互": "Optimized menu bar controller initialization during app startup ensuring instant and reliable menu bar presence",
        "完善主窗口唤醒与数据刷新回调联动，提升菜单栏常驻模式下的响应速度与稳定性": "Refined main window focus and refresh callback bindings for enhanced menu bar responsiveness",
        "新增下载更新时实时显示下载进度条与百分比（从 0% 起始终保持滚动条展示）": "Enhanced in-app update downloading with persistent progress bar and percentage tracker from 0% onwards",
        "在设置「存储与诊断」新增「一键重置 App 与出厂设置」功能，支持安全清除本地数据、还原默认配置并自动重新索引": "Added one-click Factory Reset & Rescan in Settings storage pane with safety confirmation dialog",
        "彻底解决升级弹窗更新日志显示 HTML 标签乱码问题，并支持条目全语言多维度本地化翻译": "Fixed update dialog changelog HTML tag artifacts with automated multi-language localization",
        "全面完善 10 种语言的多语言本地化翻译字典": "Comprehensive localized translation coverage across 10 supported languages",
        "全新重构「本地索引与数据诊断」卡片排版为现代化自适应 4 列网格，重点突出 12 项关键诊断指标并强化健康度感知": "Redesigned local index & diagnostics layout into a modern adaptive 4-column grid highlighting 12 key health metrics",
        "优化升级弹窗视觉细节，移除弹窗顶部横条，呈现纯净圆角卡片质感": "Polished update dialog visual aesthetics by removing top gradient bar for a sleek border design",
        "修复更新日志在多语言环境下的刷新机制，所有非简体中文语言点击刷新均可拉取并自动本地化翻译": "Fixed changelog refresh for all supported non-Simplified-Chinese languages with instant localized translation",
        "加固重置卡数据解析与容错逻辑，兼容多种服务端命名格式并增加空明细智能兜底": "Hardened reset card decoding resilience against varied payload formats with smart empty-state fallbacks",
        "全新重构设置界面为 5 大分类 Tab 架构（常规外观、账号同步、悬浮挂件、Codex 环境、存储诊断），告别冗长滚动": "Restructured Settings view into a 5-tab layout (General, Account, Overlay, Codex, Storage) with persistent state and zero long-scrolling",
        "升级弹窗全新高颜值重构，支持版本跃迁对比、安装包体积展示（如 📦 7.3 MB）与更新日志独立滚动面板": "Redesigned software update dialog with version transition badges, download package size, and scrollable release notes panel",
        "新增模型推理级别（Reasoning Effort）深度解析，并在历史明细与会话详情中以高对比度渐变徽章醒目展示": "Parsed model reasoning effort levels from Codex sessions and displayed high-contrast reasoning badges in history and session views",
        "会话列表支持按项目（代码工作区）聚合分组与过滤筛选，支持一键折叠展开并统计项目消耗": "Added project-based session grouping, filtering chips, and expand/collapse support with aggregate tokens and cost analytics",
        "新增 Prompt 缓存命中率与节约效益分析，并在主看板增加配额耗尽与重置卡智能建议横幅": "Added prompt cache hit rate efficiency analysis and smart suggestion banners for quota exhaustion and reset cards",
        "优化当日无活动时的友好空状态展示，精简掉默认的 DEFAULT/STANDARD 服务层级标签": "Refined empty-day activity cards with user-friendly copy and removed redundant default service tier badges",
        "新增会话删除与安全清理能力，支持源文件移至废纸篓并自动级联清理本地索引与统计数据": "Session deletion with trash-move safety and automatic cascade cleanup of derived analytics",
        "新增配额耗尽（0% 配额）预警与专属状态展示，并在配额耗尽时智能静默预测": "Dedicated quota exhausted state handling and intelligent forecast suppression",
        "全面升级全息悬浮窗交互，支持磁吸贴边、自由拖拽定位与置顶固定状态记忆": "Enhanced floating HUD overlay with magnetic edge snapping, dragging, and pin persistence",
        "用量分析看板与年度热力图新增鼠标跟随悬浮详情卡片，并大幅优化历史全天汇总查询性能": "Pointer-following detail cards for usage charts and heatmap with faster compact summary queries",
        "优化 Dock 图标聚焦与菜单栏弹窗交互行为，关于页更新日志支持多语言自适应显示": "Refined Dock and menu bar activation behaviors, with localized changelog rendering",
        "新增 Codex 本地历史用量与 Rollout 审计日志实时追踪解析引擎，支持秒级流式索引": "Real-time parsing and streaming index for Codex local history & rollout audit logs",
        "新增配额消耗预测引擎（基于线性投影与历史会话特征预估周期耗尽时间与建议节奏）": "Quota consumption forecast engine with linear projection and runout estimation",
        "新增「会话明细」与「历史用量」分析看板，支持按会话、模型、分支多维度聚合统计": "Interactive session breakdown and usage analytics dashboard",
        "新增独立全息悬浮置顶窗与菜单栏交互增强，实时监控用量与重置倒计时": "Floating HUD overlay window and enhanced menu bar interactions",
        "修复在线检查更新源 URL 缓存问题，确保每次请求均拉取远端最新版本": "Fixed update feed cache-busting to ensure latest release metadata",
        "全面优化「确认使用重置卡」弹窗 Cyber 视觉质感，并严格按规则智能生成确认提示文案": "Refined reset card confirmation dialog visual aesthetics with smart rule-based copy",
        "顶栏左侧升级为动态展示当前菜单名称，并将 App 品牌整合至侧边栏底座": "Dynamic top bar title reflecting active tab and brand integration in sidebar footer",
        "全局清理各菜单页面内容顶部的冗余大标题，将概览页视图模式与同步状态下沉至 Hero 卡片": "Cleaned up redundant page titles and streamlined overview controls into Hero header",
        "倒计时与建议日均消耗全面升级为秒级精确度，接入 TimelineView 实现每秒实时平滑跳动": "Upgraded countdown and daily budget pace to real-time second-level precision",
        "全面覆盖 10 种语言的多语言本地化翻译": "Complete localized translations for 10 supported languages",
        "更新日志与开源协议升级为动态网络拉取，每次点开弹窗时自动获取最新发布内容": "Dynamic fetching and manual refresh for changelog & license",
        "修复当前版本高亮匹配逻辑，与当前运行应用版本实时保持一致": "Fixed current version matching algorithm to accurately highlight active release",
        "全局清理页面与侧边栏次级说明小字，提升界面清爽与精致度": "Cleaned up auxiliary subtitles and tags across pages and sidebar",
        "全面覆盖 10 种语言的多语言本地化翻译并清理冗余词条": "Complete 10-language localized translations and code cleanup",
        "移除构建次数显示，并去掉概览与设置页面的分块序号徽章": "Removed build count and section number tags across overview and settings",
        "更新日志与开源协议采用应用内可滚动弹窗展示，并支持一键复制": "In-app scrollable dialogs for changelog and license with one-click copy support",
        "进一步优化全息卡片间距与界面精致度": "Refined card spacing and visual aesthetics",
        "全新关于页面 UI 排版重构，引入 Hero 品牌中心与 2x3 核心特性矩阵": "Redesigned About view layout with Hero brand center and 2x3 feature grid",
        "优化在线升级交互与状态指示面板": "Polished online update interactions and status indicators",
        "修复 Sparkle 在线增量升级检测与版本比对流程": "Fixed Sparkle in-app delta update checking and version comparison",
        "统一语言与偏好设置图标": "Unified language and preference setting icons",
        "新增轻量菜单栏模式与 Dock 隐藏支持": "Added menu bar compact mode and optional hidden Dock icon",
        "优化 ChatGPT 与 Codex 额度快照解析器": "Improved ChatGPT and Codex quota snapshot parsers",
        "QuotaLens 正式发布！首发支持实时配额监控、重置卡追踪与周期推算": "Initial release of QuotaLens with real-time quota tracking, reset card alerts, and cycle detection"
    ]

    public static func localizeChangelogText(_ rawText: String) -> String {
        var prefix = ""
        var content = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.hasPrefix("- ") {
            prefix = "- "
            content = String(content.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if content.hasPrefix("* ") {
            prefix = "* "
            content = String(content.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if content.hasPrefix("• ") {
            prefix = "• "
            content = String(content.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if language == .simplifiedChinese {
            return rawText
        }
        if let englishKey = changelogZhToEnMap[content] {
            let translated = localized(englishKey, zhHans: content)
            return prefix.isEmpty ? translated : "\(prefix)\(translated)"
        }
        if let englishKey = changelogZhToEnMap[rawText] {
            return localized(englishKey, zhHans: rawText)
        }
        if keyedTranslations[content] != nil {
            let translated = localized(content)
            return prefix.isEmpty ? translated : "\(prefix)\(translated)"
        }
        if keyedTranslations[rawText] != nil {
            return localized(rawText)
        }
        return rawText
    }
}

private let multiToolTranslations: [AppLanguage: [String: String]] = [
    .traditionalChinese: [
        "Claude Usage Analytics": "Claude 用量分析",
        "Codex Usage Analytics": "Codex 用量分析",
        "Local usage · Activity heatmap · Model breakdown": "本機用量 · 活躍熱力圖 · 模型構成",
        "Local and cloud activity · Activity heatmap · Model breakdown": "本機與雲端活動 · 活躍熱力圖 · 模型構成",
        "Claude Quota Forecast": "Claude 額度預測",
        "Quota Overview": "額度概覽",
        "Usage Analytics": "用量分析",
        "Tool Settings": "工具設定",
        "App Settings": "App 設定",
        "Get Started": "開始使用",
        "Operations Overview": "營運總覽",
        "Set Up Monitoring": "設定監控工具",
        "Switch Tool Space": "切換工具空間",
        "All Monitored Tools": "所有監控工具",
        "%d tools enabled": "已啟用 %d 個工具",
        "Waiting for Sync": "等待同步",
        "Monitoring": "監控中",
        "Waiting for a Monitored Tool": "等待識別監控工具",
        "Open Codex, Claude, or Antigravity and its quota will appear here automatically.": "開啟 Codex、Claude 或 Antigravity 後，這裡會自動顯示對應的額度。",
        "Quota Monitoring": "額度監控",
        "Synced": "已同步",
        "Waiting": "等待中",
        "Claude Local Usage": "Claude 本機用量",
        "Last synced %@": "最後同步 %@",
        "Waiting for the first sync": "等待首次同步",
        "Choose AI Tools to Monitor": "選擇要監控的 AI 工具",
        "Enable Codex, Claude, or Antigravity to see its quota and local activity.": "啟用 Codex、Claude 或 Antigravity 後，即可查看對應的額度與本機活動。",
        "Open App Settings": "開啟 App 設定",
        "Open the tool space": "開啟工具專屬頁面",
        "Needs Attention": "需要處理",
        "Upcoming Resets": "即將重設",
        "No reset times are available yet": "暫時沒有可用的重設時間",
        "Local Usage Comparison": "本機用量比較",
        "Sync Health": "同步狀態",
        "Refresh All": "全部重新整理",
        "Healthy": "正常",
        "Plan Pending": "方案待同步",
        "Sync Healthy": "同步正常",
        "Waiting for Connection": "等待連線",
        "Updated %@": "%@更新",
        "Reset Unknown": "重設時間未知",
        "Codex is not connected. Check sign-in or its app environment.": "Codex 尚未連線，請檢查登入或程式環境。",
        "Codex available quota is running low.": "Codex 可用額度已經偏低。",
        "Claude available quota is running low.": "Claude 可用額度已經偏低。",
        "5-Hour Quota": "5 小時額度",
        "7-Day Quota": "7 天額度",
        "Monitored Tools": "監控工具",
        "Monitor %@": "監控 %@",
        "When multiple tools are enabled, switch between Overview and each tool from the top of the sidebar.": "啟用多個工具後，可以在側邊欄頂部切換總覽與各工具頁面。",
        "Monitor Codex quota, local usage, sessions, and reset cards": "監控 Codex 額度、本機用量、工作階段和重設卡",
        "Monitor Claude quota, local usage, and sessions": "監控 Claude 額度、本機用量和工作階段",
        "Monitor quota and usage for this tool": "監控此工具的額度與用量",
        "Claude Window Overlay": "Claude 視窗懸浮掛件",
        "Show current quota in Claude, terminal, or editor windows": "在 Claude、終端機或編輯器視窗中顯示目前額度",
        "Automatic App Detection": "自動識別使用情境",
        "The overlay appears automatically in Claude Desktop, or while Claude runs in Terminal, iTerm, or VS Code.": "使用 Claude 桌面版，或在終端機、iTerm、VS Code 中執行 Claude 時，掛件會自動顯示。",
        "Waiting for quota sync": "等待額度同步",
        "QuotaLens · Waiting for a tool": "QuotaLens · 等待識別工具"
    ],
    .japanese: [
        "Claude Usage Analytics": "Claude 使用量分析",
        "Codex Usage Analytics": "Codex 使用量分析",
        "Local usage · Activity heatmap · Model breakdown": "ローカル使用量 · アクティビティヒートマップ · モデル構成",
        "Local and cloud activity · Activity heatmap · Model breakdown": "ローカルとクラウドのアクティビティ · ヒートマップ · モデル構成",
        "Claude Quota Forecast": "Claude クォータ予測",
        "Quota Overview": "クォータ概要",
        "Usage Analytics": "使用量分析",
        "Tool Settings": "ツール設定",
        "App Settings": "アプリ設定",
        "Get Started": "はじめる",
        "Operations Overview": "運用概要",
        "Set Up Monitoring": "監視ツールを設定",
        "Switch Tool Space": "ツールスペースを切り替え",
        "All Monitored Tools": "すべての監視ツール",
        "%d tools enabled": "%d個のツールを有効化",
        "Waiting for Sync": "同期待ち",
        "Monitoring": "監視中",
        "Waiting for a Monitored Tool": "監視対象ツールを待機中",
        "Open Codex, Claude, or Antigravity and its quota will appear here automatically.": "Codex、Claude、Antigravity のいずれかを開くと、対応するクォータが自動的に表示されます。",
        "Quota Monitoring": "クォータ監視",
        "Synced": "同期済み",
        "Waiting": "待機中",
        "Claude Local Usage": "Claude のローカル使用量",
        "Last synced %@": "最終同期 %@",
        "Waiting for the first sync": "初回同期を待機中",
        "Choose AI Tools to Monitor": "監視する AI ツールを選択",
        "Enable Codex, Claude, or Antigravity to see its quota and local activity.": "Codex、Claude、Antigravity のいずれかを有効にすると、クォータとローカルアクティビティを確認できます。",
        "Open App Settings": "アプリ設定を開く",
        "Open the tool space": "ツール専用ページを開く",
        "Needs Attention": "対応が必要",
        "Upcoming Resets": "次回のリセット",
        "No reset times are available yet": "利用可能なリセット時刻はまだありません",
        "Local Usage Comparison": "ローカル使用量の比較",
        "Sync Health": "同期状態",
        "Refresh All": "すべて更新",
        "Healthy": "正常",
        "Plan Pending": "プラン同期待ち",
        "Sync Healthy": "同期は正常",
        "Waiting for Connection": "接続待ち",
        "Updated %@": "%@に更新",
        "Reset Unknown": "リセット時刻不明",
        "Codex is not connected. Check sign-in or its app environment.": "Codex に接続されていません。サインインまたはアプリ環境を確認してください。",
        "Codex available quota is running low.": "Codex の利用可能クォータが少なくなっています。",
        "Claude available quota is running low.": "Claude の利用可能クォータが少なくなっています。",
        "5-Hour Quota": "5時間クォータ",
        "7-Day Quota": "7日間クォータ",
        "Monitored Tools": "監視ツール",
        "Monitor %@": "%@を監視",
        "When multiple tools are enabled, switch between Overview and each tool from the top of the sidebar.": "複数のツールを有効にすると、サイドバー上部から概要と各ツールを切り替えられます。",
        "Monitor Codex quota, local usage, sessions, and reset cards": "Codex のクォータ、ローカル使用量、セッション、リセットカードを監視",
        "Monitor Claude quota, local usage, and sessions": "Claude のクォータ、ローカル使用量、セッションを監視",
        "Monitor quota and usage for this tool": "このツールのクォータと使用量を監視",
        "Claude Window Overlay": "Claude ウインドウオーバーレイ",
        "Show current quota in Claude, terminal, or editor windows": "Claude、ターミナル、エディタのウインドウに現在のクォータを表示",
        "Automatic App Detection": "アプリの自動検出",
        "The overlay appears automatically in Claude Desktop, or while Claude runs in Terminal, iTerm, or VS Code.": "Claude Desktop、または Terminal、iTerm、VS Code で Claude を実行している間、オーバーレイが自動的に表示されます。",
        "Waiting for quota sync": "クォータの同期待ち",
        "QuotaLens · Waiting for a tool": "QuotaLens · ツールを待機中"
    ],
    .korean: [
        "Claude Usage Analytics": "Claude 사용량 분석",
        "Codex Usage Analytics": "Codex 사용량 분석",
        "Local usage · Activity heatmap · Model breakdown": "로컬 사용량 · 활동 히트맵 · 모델 구성",
        "Local and cloud activity · Activity heatmap · Model breakdown": "로컬 및 클라우드 활동 · 히트맵 · 모델 구성",
        "Claude Quota Forecast": "Claude 할당량 예측",
        "Quota Overview": "할당량 개요",
        "Usage Analytics": "사용량 분석",
        "Tool Settings": "도구 설정",
        "App Settings": "앱 설정",
        "Get Started": "시작하기",
        "Operations Overview": "운영 개요",
        "Set Up Monitoring": "모니터링 도구 설정",
        "Switch Tool Space": "도구 공간 전환",
        "All Monitored Tools": "모든 모니터링 도구",
        "%d tools enabled": "도구 %d개 활성화됨",
        "Waiting for Sync": "동기화 대기 중",
        "Monitoring": "모니터링 중",
        "Waiting for a Monitored Tool": "모니터링 도구를 기다리는 중",
        "Open Codex, Claude, or Antigravity and its quota will appear here automatically.": "Codex, Claude 또는 Antigravity를 열면 해당 할당량이 자동으로 표시됩니다.",
        "Quota Monitoring": "할당량 모니터링",
        "Synced": "동기화됨",
        "Waiting": "대기 중",
        "Claude Local Usage": "Claude 로컬 사용량",
        "Last synced %@": "마지막 동기화 %@",
        "Waiting for the first sync": "첫 동기화 대기 중",
        "Choose AI Tools to Monitor": "모니터링할 AI 도구 선택",
        "Enable Codex, Claude, or Antigravity to see its quota and local activity.": "Codex, Claude 또는 Antigravity를 활성화하면 할당량과 로컬 활동을 볼 수 있습니다.",
        "Open App Settings": "앱 설정 열기",
        "Open the tool space": "도구 전용 페이지 열기",
        "Needs Attention": "확인 필요",
        "Upcoming Resets": "예정된 초기화",
        "No reset times are available yet": "아직 확인 가능한 초기화 시간이 없습니다",
        "Local Usage Comparison": "로컬 사용량 비교",
        "Sync Health": "동기화 상태",
        "Refresh All": "모두 새로고침",
        "Healthy": "정상",
        "Plan Pending": "요금제 동기화 대기",
        "Sync Healthy": "동기화 정상",
        "Waiting for Connection": "연결 대기 중",
        "Updated %@": "%@ 업데이트",
        "Reset Unknown": "초기화 시간 알 수 없음",
        "Codex is not connected. Check sign-in or its app environment.": "Codex가 연결되지 않았습니다. 로그인 또는 앱 환경을 확인하세요.",
        "Codex available quota is running low.": "Codex 사용 가능 할당량이 부족합니다.",
        "Claude available quota is running low.": "Claude 사용 가능 할당량이 부족합니다.",
        "5-Hour Quota": "5시간 할당량",
        "7-Day Quota": "7일 할당량",
        "Monitored Tools": "모니터링 도구",
        "Monitor %@": "%@ 모니터링",
        "When multiple tools are enabled, switch between Overview and each tool from the top of the sidebar.": "여러 도구를 활성화하면 사이드바 상단에서 개요와 각 도구를 전환할 수 있습니다.",
        "Monitor Codex quota, local usage, sessions, and reset cards": "Codex 할당량, 로컬 사용량, 세션 및 초기화 카드 모니터링",
        "Monitor Claude quota, local usage, and sessions": "Claude 할당량, 로컬 사용량 및 세션 모니터링",
        "Monitor quota and usage for this tool": "이 도구의 할당량과 사용량 모니터링",
        "Claude Window Overlay": "Claude 창 오버레이",
        "Show current quota in Claude, terminal, or editor windows": "Claude, 터미널 또는 편집기 창에 현재 할당량 표시",
        "Automatic App Detection": "자동 앱 감지",
        "The overlay appears automatically in Claude Desktop, or while Claude runs in Terminal, iTerm, or VS Code.": "Claude Desktop 또는 Terminal, iTerm, VS Code에서 Claude를 실행할 때 오버레이가 자동으로 표시됩니다.",
        "Waiting for quota sync": "할당량 동기화 대기 중",
        "QuotaLens · Waiting for a tool": "QuotaLens · 도구 대기 중"
    ],
    .spanish: [
        "Claude Usage Analytics": "Análisis de uso de Claude",
        "Codex Usage Analytics": "Análisis de uso de Codex",
        "Local usage · Activity heatmap · Model breakdown": "Uso local · Mapa de actividad · Distribución por modelo",
        "Local and cloud activity · Activity heatmap · Model breakdown": "Actividad local y en la nube · Mapa de actividad · Distribución por modelo",
        "Claude Quota Forecast": "Previsión de cuota de Claude",
        "Quota Overview": "Resumen de cuota",
        "Usage Analytics": "Análisis de uso",
        "Tool Settings": "Ajustes de la herramienta",
        "App Settings": "Ajustes de la app",
        "Get Started": "Comenzar",
        "Operations Overview": "Resumen operativo",
        "Set Up Monitoring": "Configurar monitorización",
        "Switch Tool Space": "Cambiar espacio de herramienta",
        "All Monitored Tools": "Todas las herramientas monitorizadas",
        "%d tools enabled": "%d herramientas activadas",
        "Waiting for Sync": "Esperando sincronización",
        "Monitoring": "Monitorizando",
        "Waiting for a Monitored Tool": "Esperando una herramienta monitorizada",
        "Open Codex, Claude, or Antigravity and its quota will appear here automatically.": "Abre Codex, Claude o Antigravity y su cuota aparecerá aquí automáticamente.",
        "Quota Monitoring": "Monitorización de cuota",
        "Synced": "Sincronizado",
        "Waiting": "En espera",
        "Claude Local Usage": "Uso local de Claude",
        "Last synced %@": "Última sincronización %@",
        "Waiting for the first sync": "Esperando la primera sincronización",
        "Choose AI Tools to Monitor": "Elige las herramientas de IA que quieres monitorizar",
        "Enable Codex, Claude, or Antigravity to see its quota and local activity.": "Activa Codex, Claude o Antigravity para ver su cuota y actividad local.",
        "Open App Settings": "Abrir ajustes de la app",
        "Open the tool space": "Abrir la página de la herramienta",
        "Needs Attention": "Requiere atención",
        "Upcoming Resets": "Próximos reinicios",
        "No reset times are available yet": "Aún no hay horas de reinicio disponibles",
        "Local Usage Comparison": "Comparación de uso local",
        "Sync Health": "Estado de sincronización",
        "Refresh All": "Actualizar todo",
        "Healthy": "Correcto",
        "Plan Pending": "Plan pendiente",
        "Sync Healthy": "Sincronización correcta",
        "Waiting for Connection": "Esperando conexión",
        "Updated %@": "Actualizado %@",
        "Reset Unknown": "Reinicio desconocido",
        "Codex is not connected. Check sign-in or its app environment.": "Codex no está conectado. Comprueba el inicio de sesión o su entorno.",
        "Codex available quota is running low.": "La cuota disponible de Codex se está agotando.",
        "Claude available quota is running low.": "La cuota disponible de Claude se está agotando.",
        "5-Hour Quota": "Cuota de 5 horas",
        "7-Day Quota": "Cuota de 7 días",
        "Monitored Tools": "Herramientas monitorizadas",
        "Monitor %@": "Monitorizar %@",
        "When multiple tools are enabled, switch between Overview and each tool from the top of the sidebar.": "Con varias herramientas activadas, cambia entre el resumen y cada herramienta desde la parte superior de la barra lateral.",
        "Monitor Codex quota, local usage, sessions, and reset cards": "Monitoriza la cuota, el uso local, las sesiones y las tarjetas de reinicio de Codex",
        "Monitor Claude quota, local usage, and sessions": "Monitoriza la cuota, el uso local y las sesiones de Claude",
        "Monitor quota and usage for this tool": "Monitoriza la cuota y el uso de esta herramienta",
        "Claude Window Overlay": "Widget de ventana de Claude",
        "Show current quota in Claude, terminal, or editor windows": "Muestra la cuota actual en ventanas de Claude, terminal o editor",
        "Automatic App Detection": "Detección automática de apps",
        "The overlay appears automatically in Claude Desktop, or while Claude runs in Terminal, iTerm, or VS Code.": "El widget aparece automáticamente en Claude Desktop o cuando Claude se ejecuta en Terminal, iTerm o VS Code.",
        "Waiting for quota sync": "Esperando sincronización de cuota",
        "QuotaLens · Waiting for a tool": "QuotaLens · Esperando una herramienta"
    ],
    .german: [
        "Claude Usage Analytics": "Claude-Nutzungsanalyse",
        "Codex Usage Analytics": "Codex-Nutzungsanalyse",
        "Local usage · Activity heatmap · Model breakdown": "Lokale Nutzung · Aktivitäts-Heatmap · Modellverteilung",
        "Local and cloud activity · Activity heatmap · Model breakdown": "Lokale und Cloud-Aktivität · Heatmap · Modellverteilung",
        "Claude Quota Forecast": "Claude-Kontingentprognose",
        "Quota Overview": "Kontingentübersicht",
        "Usage Analytics": "Nutzungsanalyse",
        "Tool Settings": "Tool-Einstellungen",
        "App Settings": "App-Einstellungen",
        "Get Started": "Erste Schritte",
        "Operations Overview": "Betriebsübersicht",
        "Set Up Monitoring": "Überwachung einrichten",
        "Switch Tool Space": "Tool-Bereich wechseln",
        "All Monitored Tools": "Alle überwachten Tools",
        "%d tools enabled": "%d Tools aktiviert",
        "Waiting for Sync": "Warten auf Synchronisierung",
        "Monitoring": "Überwachung aktiv",
        "Waiting for a Monitored Tool": "Warten auf ein überwachtes Tool",
        "Open Codex, Claude, or Antigravity and its quota will appear here automatically.": "Öffne Codex, Claude oder Antigravity; das zugehörige Kontingent erscheint hier automatisch.",
        "Quota Monitoring": "Kontingentüberwachung",
        "Synced": "Synchronisiert",
        "Waiting": "Warten",
        "Claude Local Usage": "Lokale Claude-Nutzung",
        "Last synced %@": "Zuletzt synchronisiert %@",
        "Waiting for the first sync": "Warten auf die erste Synchronisierung",
        "Choose AI Tools to Monitor": "Zu überwachende KI-Tools auswählen",
        "Enable Codex, Claude, or Antigravity to see its quota and local activity.": "Aktiviere Codex, Claude oder Antigravity, um Kontingent und lokale Aktivität zu sehen.",
        "Open App Settings": "App-Einstellungen öffnen",
        "Open the tool space": "Tool-Bereich öffnen",
        "Needs Attention": "Handlungsbedarf",
        "Upcoming Resets": "Bevorstehende Zurücksetzungen",
        "No reset times are available yet": "Noch keine Zurücksetzungszeiten verfügbar",
        "Local Usage Comparison": "Vergleich der lokalen Nutzung",
        "Sync Health": "Synchronisierungsstatus",
        "Refresh All": "Alle aktualisieren",
        "Healthy": "In Ordnung",
        "Plan Pending": "Tarif ausstehend",
        "Sync Healthy": "Synchronisierung in Ordnung",
        "Waiting for Connection": "Warten auf Verbindung",
        "Updated %@": "Aktualisiert %@",
        "Reset Unknown": "Zurücksetzung unbekannt",
        "Codex is not connected. Check sign-in or its app environment.": "Codex ist nicht verbunden. Prüfe Anmeldung oder App-Umgebung.",
        "Codex available quota is running low.": "Das verfügbare Codex-Kontingent wird knapp.",
        "Claude available quota is running low.": "Das verfügbare Claude-Kontingent wird knapp.",
        "5-Hour Quota": "5-Stunden-Kontingent",
        "7-Day Quota": "7-Tage-Kontingent",
        "Monitored Tools": "Überwachte Tools",
        "Monitor %@": "%@ überwachen",
        "When multiple tools are enabled, switch between Overview and each tool from the top of the sidebar.": "Bei mehreren aktivierten Tools kannst du oben in der Seitenleiste zwischen Übersicht und Tools wechseln.",
        "Monitor Codex quota, local usage, sessions, and reset cards": "Codex-Kontingent, lokale Nutzung, Sitzungen und Reset-Karten überwachen",
        "Monitor Claude quota, local usage, and sessions": "Claude-Kontingent, lokale Nutzung und Sitzungen überwachen",
        "Monitor quota and usage for this tool": "Kontingent und Nutzung dieses Tools überwachen",
        "Claude Window Overlay": "Claude-Fenster-Overlay",
        "Show current quota in Claude, terminal, or editor windows": "Aktuelles Kontingent in Claude-, Terminal- oder Editorfenstern anzeigen",
        "Automatic App Detection": "Automatische App-Erkennung",
        "The overlay appears automatically in Claude Desktop, or while Claude runs in Terminal, iTerm, or VS Code.": "Das Overlay erscheint automatisch in Claude Desktop oder wenn Claude in Terminal, iTerm oder VS Code läuft.",
        "Waiting for quota sync": "Warten auf Kontingentsynchronisierung",
        "QuotaLens · Waiting for a tool": "QuotaLens · Warten auf ein Tool"
    ],
    .french: [
        "Claude Usage Analytics": "Analyse d’utilisation de Claude",
        "Codex Usage Analytics": "Analyse d’utilisation de Codex",
        "Local usage · Activity heatmap · Model breakdown": "Utilisation locale · Carte d’activité · Répartition par modèle",
        "Local and cloud activity · Activity heatmap · Model breakdown": "Activité locale et cloud · Carte d’activité · Répartition par modèle",
        "Claude Quota Forecast": "Prévision du quota Claude",
        "Quota Overview": "Aperçu du quota",
        "Usage Analytics": "Analyse d’utilisation",
        "Tool Settings": "Réglages de l’outil",
        "App Settings": "Réglages de l’app",
        "Get Started": "Commencer",
        "Operations Overview": "Vue opérationnelle",
        "Set Up Monitoring": "Configurer le suivi",
        "Switch Tool Space": "Changer d’espace outil",
        "All Monitored Tools": "Tous les outils suivis",
        "%d tools enabled": "%d outils activés",
        "Waiting for Sync": "En attente de synchronisation",
        "Monitoring": "Suivi en cours",
        "Waiting for a Monitored Tool": "En attente d’un outil suivi",
        "Open Codex, Claude, or Antigravity and its quota will appear here automatically.": "Ouvrez Codex, Claude ou Antigravity et son quota apparaîtra automatiquement ici.",
        "Quota Monitoring": "Suivi du quota",
        "Synced": "Synchronisé",
        "Waiting": "En attente",
        "Claude Local Usage": "Utilisation locale de Claude",
        "Last synced %@": "Dernière synchronisation %@",
        "Waiting for the first sync": "En attente de la première synchronisation",
        "Choose AI Tools to Monitor": "Choisissez les outils d’IA à suivre",
        "Enable Codex, Claude, or Antigravity to see its quota and local activity.": "Activez Codex, Claude ou Antigravity pour voir son quota et son activité locale.",
        "Open App Settings": "Ouvrir les réglages de l’app",
        "Open the tool space": "Ouvrir la page de l’outil",
        "Needs Attention": "Action requise",
        "Upcoming Resets": "Réinitialisations à venir",
        "No reset times are available yet": "Aucune heure de réinitialisation n’est encore disponible",
        "Local Usage Comparison": "Comparaison de l’utilisation locale",
        "Sync Health": "État de synchronisation",
        "Refresh All": "Tout actualiser",
        "Healthy": "Normal",
        "Plan Pending": "Offre en attente",
        "Sync Healthy": "Synchronisation normale",
        "Waiting for Connection": "En attente de connexion",
        "Updated %@": "Actualisé %@",
        "Reset Unknown": "Réinitialisation inconnue",
        "Codex is not connected. Check sign-in or its app environment.": "Codex n’est pas connecté. Vérifiez la connexion ou l’environnement de l’app.",
        "Codex available quota is running low.": "Le quota disponible de Codex devient faible.",
        "Claude available quota is running low.": "Le quota disponible de Claude devient faible.",
        "5-Hour Quota": "Quota de 5 heures",
        "7-Day Quota": "Quota de 7 jours",
        "Monitored Tools": "Outils suivis",
        "Monitor %@": "Suivre %@",
        "When multiple tools are enabled, switch between Overview and each tool from the top of the sidebar.": "Quand plusieurs outils sont activés, passez de la vue d’ensemble à chaque outil en haut de la barre latérale.",
        "Monitor Codex quota, local usage, sessions, and reset cards": "Suivre le quota, l’utilisation locale, les sessions et les cartes de réinitialisation de Codex",
        "Monitor Claude quota, local usage, and sessions": "Suivre le quota, l’utilisation locale et les sessions de Claude",
        "Monitor quota and usage for this tool": "Suivre le quota et l’utilisation de cet outil",
        "Claude Window Overlay": "Widget de fenêtre Claude",
        "Show current quota in Claude, terminal, or editor windows": "Afficher le quota actuel dans les fenêtres Claude, du terminal ou de l’éditeur",
        "Automatic App Detection": "Détection automatique des apps",
        "The overlay appears automatically in Claude Desktop, or while Claude runs in Terminal, iTerm, or VS Code.": "Le widget apparaît automatiquement dans Claude Desktop ou lorsque Claude s’exécute dans Terminal, iTerm ou VS Code.",
        "Waiting for quota sync": "En attente de synchronisation du quota",
        "QuotaLens · Waiting for a tool": "QuotaLens · En attente d’un outil"
    ],
    .portuguese: [
        "Claude Usage Analytics": "Análise de utilização do Claude",
        "Codex Usage Analytics": "Análise de utilização do Codex",
        "Local usage · Activity heatmap · Model breakdown": "Utilização local · Mapa de atividade · Distribuição por modelo",
        "Local and cloud activity · Activity heatmap · Model breakdown": "Atividade local e na nuvem · Mapa de atividade · Distribuição por modelo",
        "Claude Quota Forecast": "Previsão da quota do Claude",
        "Quota Overview": "Visão geral da quota",
        "Usage Analytics": "Análise de utilização",
        "Tool Settings": "Definições da ferramenta",
        "App Settings": "Definições da aplicação",
        "Get Started": "Começar",
        "Operations Overview": "Visão operacional",
        "Set Up Monitoring": "Configurar monitorização",
        "Switch Tool Space": "Mudar de espaço da ferramenta",
        "All Monitored Tools": "Todas as ferramentas monitorizadas",
        "%d tools enabled": "%d ferramentas ativadas",
        "Waiting for Sync": "A aguardar sincronização",
        "Monitoring": "A monitorizar",
        "Waiting for a Monitored Tool": "A aguardar uma ferramenta monitorizada",
        "Open Codex, Claude, or Antigravity and its quota will appear here automatically.": "Abra o Codex, o Claude ou o Antigravity e a respetiva quota aparecerá aqui automaticamente.",
        "Quota Monitoring": "Monitorização de quota",
        "Synced": "Sincronizado",
        "Waiting": "A aguardar",
        "Claude Local Usage": "Utilização local do Claude",
        "Last synced %@": "Última sincronização %@",
        "Waiting for the first sync": "A aguardar a primeira sincronização",
        "Choose AI Tools to Monitor": "Escolha as ferramentas de IA a monitorizar",
        "Enable Codex, Claude, or Antigravity to see its quota and local activity.": "Ative o Codex, o Claude ou o Antigravity para ver a quota e a atividade local.",
        "Open App Settings": "Abrir definições da aplicação",
        "Open the tool space": "Abrir a página da ferramenta",
        "Needs Attention": "Requer atenção",
        "Upcoming Resets": "Reposições futuras",
        "No reset times are available yet": "Ainda não existem horas de reposição disponíveis",
        "Local Usage Comparison": "Comparação de utilização local",
        "Sync Health": "Estado da sincronização",
        "Refresh All": "Atualizar tudo",
        "Healthy": "Normal",
        "Plan Pending": "Plano pendente",
        "Sync Healthy": "Sincronização normal",
        "Waiting for Connection": "A aguardar ligação",
        "Updated %@": "Atualizado %@",
        "Reset Unknown": "Reposição desconhecida",
        "Codex is not connected. Check sign-in or its app environment.": "O Codex não está ligado. Verifique o início de sessão ou o ambiente da aplicação.",
        "Codex available quota is running low.": "A quota disponível do Codex está a ficar reduzida.",
        "Claude available quota is running low.": "A quota disponível do Claude está a ficar reduzida.",
        "5-Hour Quota": "Quota de 5 horas",
        "7-Day Quota": "Quota de 7 dias",
        "Monitored Tools": "Ferramentas monitorizadas",
        "Monitor %@": "Monitorizar %@",
        "When multiple tools are enabled, switch between Overview and each tool from the top of the sidebar.": "Com várias ferramentas ativadas, alterne entre a visão geral e cada ferramenta no topo da barra lateral.",
        "Monitor Codex quota, local usage, sessions, and reset cards": "Monitorizar quota, utilização local, sessões e cartões de reposição do Codex",
        "Monitor Claude quota, local usage, and sessions": "Monitorizar quota, utilização local e sessões do Claude",
        "Monitor quota and usage for this tool": "Monitorizar a quota e a utilização desta ferramenta",
        "Claude Window Overlay": "Widget da janela do Claude",
        "Show current quota in Claude, terminal, or editor windows": "Mostrar a quota atual nas janelas do Claude, terminal ou editor",
        "Automatic App Detection": "Deteção automática de aplicações",
        "The overlay appears automatically in Claude Desktop, or while Claude runs in Terminal, iTerm, or VS Code.": "O widget aparece automaticamente no Claude Desktop ou enquanto o Claude é executado no Terminal, iTerm ou VS Code.",
        "Waiting for quota sync": "A aguardar sincronização da quota",
        "QuotaLens · Waiting for a tool": "QuotaLens · A aguardar uma ferramenta"
    ],
    .portugueseBrazil: [
        "Claude Usage Analytics": "Análise de uso do Claude",
        "Codex Usage Analytics": "Análise de uso do Codex",
        "Local usage · Activity heatmap · Model breakdown": "Uso local · Mapa de atividade · Distribuição por modelo",
        "Local and cloud activity · Activity heatmap · Model breakdown": "Atividade local e na nuvem · Mapa de atividade · Distribuição por modelo",
        "Claude Quota Forecast": "Previsão da cota do Claude",
        "Quota Overview": "Visão geral da cota",
        "Usage Analytics": "Análise de uso",
        "Tool Settings": "Configurações da ferramenta",
        "App Settings": "Configurações do app",
        "Get Started": "Começar",
        "Operations Overview": "Visão operacional",
        "Set Up Monitoring": "Configurar monitoramento",
        "Switch Tool Space": "Alternar espaço da ferramenta",
        "All Monitored Tools": "Todas as ferramentas monitoradas",
        "%d tools enabled": "%d ferramentas ativadas",
        "Waiting for Sync": "Aguardando sincronização",
        "Monitoring": "Monitorando",
        "Waiting for a Monitored Tool": "Aguardando uma ferramenta monitorada",
        "Open Codex, Claude, or Antigravity and its quota will appear here automatically.": "Abra o Codex, o Claude ou o Antigravity e a cota correspondente aparecerá aqui automaticamente.",
        "Quota Monitoring": "Monitoramento de cota",
        "Synced": "Sincronizado",
        "Waiting": "Aguardando",
        "Claude Local Usage": "Uso local do Claude",
        "Last synced %@": "Última sincronização %@",
        "Waiting for the first sync": "Aguardando a primeira sincronização",
        "Choose AI Tools to Monitor": "Escolha as ferramentas de IA para monitorar",
        "Enable Codex, Claude, or Antigravity to see its quota and local activity.": "Ative o Codex, o Claude ou o Antigravity para ver a cota e a atividade local.",
        "Open App Settings": "Abrir configurações do app",
        "Open the tool space": "Abrir a página da ferramenta",
        "Needs Attention": "Requer atenção",
        "Upcoming Resets": "Próximas redefinições",
        "No reset times are available yet": "Ainda não há horários de redefinição disponíveis",
        "Local Usage Comparison": "Comparação de uso local",
        "Sync Health": "Status da sincronização",
        "Refresh All": "Atualizar tudo",
        "Healthy": "Normal",
        "Plan Pending": "Plano pendente",
        "Sync Healthy": "Sincronização normal",
        "Waiting for Connection": "Aguardando conexão",
        "Updated %@": "Atualizado %@",
        "Reset Unknown": "Redefinição desconhecida",
        "Codex is not connected. Check sign-in or its app environment.": "O Codex não está conectado. Verifique o login ou o ambiente do app.",
        "Codex available quota is running low.": "A cota disponível do Codex está acabando.",
        "Claude available quota is running low.": "A cota disponível do Claude está acabando.",
        "5-Hour Quota": "Cota de 5 horas",
        "7-Day Quota": "Cota de 7 dias",
        "Monitored Tools": "Ferramentas monitoradas",
        "Monitor %@": "Monitorar %@",
        "When multiple tools are enabled, switch between Overview and each tool from the top of the sidebar.": "Com várias ferramentas ativadas, alterne entre a visão geral e cada ferramenta no topo da barra lateral.",
        "Monitor Codex quota, local usage, sessions, and reset cards": "Monitorar cota, uso local, sessões e cartões de redefinição do Codex",
        "Monitor Claude quota, local usage, and sessions": "Monitorar cota, uso local e sessões do Claude",
        "Monitor quota and usage for this tool": "Monitorar a cota e o uso desta ferramenta",
        "Claude Window Overlay": "Widget da janela do Claude",
        "Show current quota in Claude, terminal, or editor windows": "Mostrar a cota atual nas janelas do Claude, terminal ou editor",
        "Automatic App Detection": "Detecção automática de apps",
        "The overlay appears automatically in Claude Desktop, or while Claude runs in Terminal, iTerm, or VS Code.": "O widget aparece automaticamente no Claude Desktop ou enquanto o Claude é executado no Terminal, iTerm ou VS Code.",
        "Waiting for quota sync": "Aguardando sincronização da cota",
        "QuotaLens · Waiting for a tool": "QuotaLens · Aguardando uma ferramenta"
    ]
]

private let keyedTranslations: [String: [AppLanguage: String]] = [
    "Tightest Pool": [
        .traditionalChinese: "最吃緊額度池", .japanese: "最も厳しいプール", .korean: "가장 여유가 적은 풀",
        .spanish: "Grupo más ajustado", .german: "Knappster Pool", .french: "Réserve la plus limitée",
        .portuguese: "Grupo mais limitado", .portugueseBrazil: "Grupo mais restrito"
    ],
    "Tight Pool": [
        .traditionalChinese: "吃緊池", .japanese: "厳しいプール", .korean: "여유 부족 풀",
        .spanish: "Grupo ajustado", .german: "Knapper Pool", .french: "Réserve limitée",
        .portuguese: "Grupo limitado", .portugueseBrazil: "Grupo restrito"
    ],
    "Current cycle · used quota percentage over time": [
        .traditionalChinese: "目前週期 · 已用額度百分比變化", .japanese: "現在のサイクル · 使用済みクォータの推移", .korean: "현재 주기 · 사용 할당량 백분율 변화",
        .spanish: "Ciclo actual · porcentaje de cuota usada a lo largo del tiempo", .german: "Aktueller Zyklus · genutztes Kontingent im Zeitverlauf", .french: "Cycle actuel · pourcentage de quota utilisé au fil du temps",
        .portuguese: "Ciclo atual · percentagem de quota utilizada ao longo do tempo", .portugueseBrazil: "Ciclo atual · porcentagem de cota usada ao longo do tempo"
    ],
    "Sample Progress: %d/%d": [
        .traditionalChinese: "採樣進度：%d/%d", .japanese: "サンプリング進捗：%d/%d", .korean: "샘플링 진행률: %d/%d",
        .spanish: "Progreso de muestreo: %d/%d", .german: "Abtastfortschritt: %d/%d", .french: "Progression de l'échantillonnage : %d/%d",
        .portuguese: "Progresso de amostragem: %d/%d", .portugueseBrazil: "Progresso de amostragem: %d/%d"
    ],
    "Pace:": [
        .traditionalChinese: "消耗速度:", .japanese: "消費ペース:", .korean: "소진 속도:",
        .spanish: "Ritmo:", .german: "Tempo:", .french: "Rythme :",
        .portuguese: "Ritmo:", .portugueseBrazil: "Ritmo:"
    ],
    "%@ · No activity in the last %d days": [
        .traditionalChinese: "%@ · 最近 %d 天沒有活動", .japanese: "%@ · 直近%d日間にアクティビティなし", .korean: "%@ · 최근 %d일 동안 활동 없음",
        .spanish: "%@ · Sin actividad en los últimos %d días", .german: "%@ · Keine Aktivität in den letzten %d Tagen", .french: "%@ · Aucune activité au cours des %d derniers jours",
        .portuguese: "%@ · Sem atividade nos últimos %d dias", .portugueseBrazil: "%@ · Nenhuma atividade nos últimos %d dias"
    ],
    "%+.0f%% vs prior period": [
        .traditionalChinese: "較上期 %+.0f%%",
        .japanese: "前期間比 %+.0f%%",
        .korean: "이전 기간 대비 %+.0f%%",
        .spanish: "%+.0f%% frente al periodo anterior",
        .german: "%+.0f%% gegenüber dem vorherigen Zeitraum",
        .french: "%+.0f%% par rapport à la période précédente",
        .portuguese: "%+.0f%% face ao período anterior",
        .portugueseBrazil: "%+.0f%% em relação ao período anterior"
    ],
    "%/day": [
        .traditionalChinese: "%/天", .japanese: "%/日", .korean: "%/일",
        .spanish: "%/día", .german: "%/Tag", .french: "%/jour",
        .portuguese: "%/dia", .portugueseBrazil: "%/dia"
    ],
    "%/hour": [
        .traditionalChinese: "%/小時", .japanese: "%/時", .korean: "%/시간",
        .spanish: "%/hora", .german: "%/Stunde", .french: "%/heure",
        .portuguese: "%/hora", .portugueseBrazil: "%/hora"
    ],
    "%d local sources": [
        .traditionalChinese: "%d 個本機來源", .japanese: "%d 個のローカルソース", .korean: "로컬 소스 %d개",
        .spanish: "%d fuentes locales", .german: "%d lokale Quellen", .french: "%d sources locales",
        .portuguese: "%d fontes locais", .portugueseBrazil: "%d fontes locais"
    ],
    "Activity source": [
        .traditionalChinese: "活動來源", .japanese: "アクティビティソース", .korean: "활동 소스",
        .spanish: "Fuente de actividad", .german: "Aktivitätsquelle", .french: "Source d’activité",
        .portuguese: "Fonte de atividade", .portugueseBrazil: "Fonte de atividade"
    ],
    "All sources (%d)": [
        .traditionalChinese: "全部來源（%d）", .japanese: "すべてのソース（%d）", .korean: "모든 소스(%d)",
        .spanish: "Todas las fuentes (%d)", .german: "Alle Quellen (%d)", .french: "Toutes les sources (%d)",
        .portuguese: "Todas as fontes (%d)", .portugueseBrazil: "Todas as fontes (%d)"
    ],
    "Read %d local sources · %d Antigravity tasks": [
        .traditionalChinese: "已從 %d 個本機來源讀取 %d 個 Antigravity 任務", .japanese: "%d 個のローカルソースから Antigravity タスクを %d 件読み取りました", .korean: "로컬 소스 %d개에서 Antigravity 작업 %d개를 읽었습니다",
        .spanish: "Se leyeron %d fuentes locales · %d tareas de Antigravity", .german: "%d lokale Quellen gelesen · %d Antigravity-Aufgaben", .french: "%d sources locales lues · %d tâches Antigravity",
        .portuguese: "%d fontes locais lidas · %d tarefas do Antigravity", .portugueseBrazil: "%d fontes locais lidas · %d tarefas do Antigravity"
    ],
    "%@ %@ quota, %@ available": [
        .traditionalChinese: "%@ %@ 額度，可用 %@",
        .japanese: "%@ %@ クォータ、利用可能 %@",
        .korean: "%@ %@ 할당량, %@ 사용 가능",
        .spanish: "Cuota %@ %@, %@ disponible",
        .german: "%@ %@-Kontingent, %@ verfügbar",
        .french: "Quota %@ %@, %@ disponible",
        .portuguese: "Quota %@ %@, %@ disponível",
        .portugueseBrazil: "Cota %@ %@, %@ disponível"
    ],
    "%@ at reset": [
        .traditionalChinese: "重設時 %@", .japanese: "リセット時 %@", .korean: "재설정 시 %@",
        .spanish: "%@ al restablecer", .german: "%@ beim Zurücksetzen", .french: "%@ à la réinitialisation",
        .portuguese: "%@ na reposição", .portugueseBrazil: "%@ na redefinição"
    ],
    "%@ available · %@": [
        .traditionalChinese: "可用 %@ · %@", .japanese: "利用可能 %@ · %@", .korean: "%@ 사용 가능 · %@",
        .spanish: "%@ disponible · %@", .german: "%@ verfügbar · %@", .french: "%@ disponible · %@",
        .portuguese: "%@ disponível · %@", .portugueseBrazil: "%@ disponível · %@"
    ],
    "%@ data is stale": [
        .traditionalChinese: "%@ 資料已過期", .japanese: "%@ のデータが古くなっています", .korean: "%@ 데이터가 오래되었습니다",
        .spanish: "Los datos de %@ están obsoletos", .german: "Die Daten von %@ sind veraltet", .french: "Les données de %@ sont obsolètes",
        .portuguese: "Os dados de %@ estão desatualizados", .portugueseBrazil: "Os dados de %@ estão desatualizados"
    ],
    "%@ has more room than %@. Use it for flexible work when appropriate.": [
        .traditionalChinese: "%@ 比 %@ 有更多餘量，適合時可優先用於彈性工作。",
        .japanese: "%@ は %@ より余裕があります。適切な場合は柔軟な作業に優先してください。",
        .korean: "%@에 %@보다 여유가 많습니다. 적절한 경우 유연한 작업에 우선 사용하세요.",
        .spanish: "%@ tiene más margen que %@. Úsalo para trabajo flexible cuando convenga.",
        .german: "%@ hat mehr Spielraum als %@. Nutzen Sie es bei Bedarf für flexible Aufgaben.",
        .french: "%@ offre plus de marge que %@. Utilisez-le pour les tâches flexibles lorsque cela convient.",
        .portuguese: "%@ tem mais margem do que %@. Utilize-o em trabalho flexível quando for adequado.",
        .portugueseBrazil: "%@ tem mais margem que %@. Use-o em trabalhos flexíveis quando for adequado."
    ],
    "%@ left at reset": [
        .traditionalChinese: "重設時剩餘 %@", .japanese: "リセット時に %@ 残存", .korean: "재설정 시 %@ 남음",
        .spanish: "Quedará %@ al restablecer", .german: "%@ beim Zurücksetzen übrig", .french: "%@ restant à la réinitialisation",
        .portuguese: "%@ restante na reposição", .portugueseBrazil: "%@ restante na redefinição"
    ],
    "%@ needs attention": [
        .traditionalChinese: "%@ 需要處理", .japanese: "%@ は確認が必要です", .korean: "%@에 주의가 필요합니다",
        .spanish: "%@ requiere atención", .german: "%@ erfordert Aufmerksamkeit", .french: "%@ nécessite votre attention",
        .portuguese: "%@ requer atenção", .portugueseBrazil: "%@ requer atenção"
    ],
    "%@ steps": [
        .traditionalChinese: "%@ 步", .japanese: "%@ ステップ", .korean: "%@단계",
        .spanish: "%@ pasos", .german: "%@ Schritte", .french: "%@ étapes",
        .portuguese: "%@ passos", .portugueseBrazil: "%@ etapas"
    ],
    "%@ · %@ is %.1fx the sustainable pace.": [
        .traditionalChinese: "%@ · %@ 目前是可持續速度的 %.1f 倍。",
        .japanese: "%@ · %@ は持続可能なペースの %.1f 倍です。",
        .korean: "%@ · %@은(는) 지속 가능한 속도의 %.1f배입니다.",
        .spanish: "%@ · %@ está a %.1f veces el ritmo sostenible.",
        .german: "%@ · %@ liegt beim %.1f-Fachen des nachhaltigen Tempos.",
        .french: "%@ · %@ atteint %.1f fois le rythme soutenable.",
        .portuguese: "%@ · %@ está a %.1f vezes o ritmo sustentável.",
        .portugueseBrazil: "%@ · %@ está em %.1f vezes o ritmo sustentável."
    ],
    "%@ · %@ is using quota faster than the sustainable pace.": [
        .traditionalChinese: "%@ · %@ 的額度消耗快於可持續速度。",
        .japanese: "%@ · %@ は持続可能なペースより速くクォータを消費しています。",
        .korean: "%@ · %@의 할당량 소모가 지속 가능한 속도보다 빠릅니다.",
        .spanish: "%@ · %@ consume la cuota más rápido que el ritmo sostenible.",
        .german: "%@ · %@ verbraucht das Kontingent schneller als nachhaltig.",
        .french: "%@ · %@ consomme le quota plus vite que le rythme soutenable.",
        .portuguese: "%@ · %@ está a consumir a quota acima do ritmo sustentável.",
        .portugueseBrazil: "%@ · %@ está consumindo a cota acima do ritmo sustentável."
    ],
    "%d active days": [
        .traditionalChinese: "%d 個活躍日", .japanese: "アクティブ日数 %d 日", .korean: "활동일 %d일",
        .spanish: "%d días activos", .german: "%d aktive Tage", .french: "%d jours actifs",
        .portuguese: "%d dias ativos", .portugueseBrazil: "%d dias ativos"
    ],
    "%d model groups": [
        .traditionalChinese: "%d 個模型群組", .japanese: "%d モデルグループ", .korean: "모델 그룹 %d개",
        .spanish: "%d grupos de modelos", .german: "%d Modellgruppen", .french: "%d groupes de modèles",
        .portuguese: "%d grupos de modelos", .portugueseBrazil: "%d grupos de modelos"
    ],
    "%d more quota pools": [
        .traditionalChinese: "另有 %d 個額度池", .japanese: "ほかに %d 個のクォータプール", .korean: "할당량 풀 %d개 더 있음",
        .spanish: "%d grupos de cuota más", .german: "%d weitere Kontingentpools", .french: "%d réserves de quota supplémentaires",
        .portuguese: "Mais %d grupos de quota", .portugueseBrazil: "Mais %d grupos de cota"
    ],
    "%d more quota pools are available in the main window": [
        .traditionalChinese: "主視窗中還有 %d 個額度池", .japanese: "メインウインドウにほかに %d 個のクォータプールがあります", .korean: "기본 창에 할당량 풀 %d개가 더 있습니다",
        .spanish: "Hay %d grupos de cuota más en la ventana principal", .german: "Im Hauptfenster sind %d weitere Kontingentpools verfügbar", .french: "%d réserves de quota supplémentaires sont disponibles dans la fenêtre principale",
        .portuguese: "Estão disponíveis mais %d grupos de quota na janela principal", .portugueseBrazil: "Há mais %d grupos de cota na janela principal"
    ],
    "%d samples collected. The chart appears after more refreshes.": [
        .traditionalChinese: "已收集 %d 個樣本，繼續重新整理後會顯示趨勢圖。",
        .japanese: "%d 件のサンプルを収集しました。更新を重ねるとグラフが表示されます。",
        .korean: "샘플 %d개를 수집했습니다. 몇 번 더 새로 고치면 차트가 표시됩니다.",
        .spanish: "Se han recopilado %d muestras. El gráfico aparecerá tras más actualizaciones.",
        .german: "%d Stichproben erfasst. Nach weiteren Aktualisierungen wird das Diagramm angezeigt.",
        .french: "%d échantillons collectés. Le graphique apparaîtra après d’autres actualisations.",
        .portuguese: "%d amostras recolhidas. O gráfico aparece após mais atualizações.",
        .portugueseBrazil: "%d amostras coletadas. O gráfico aparecerá após mais atualizações."
    ],
    "%d tasks": [
        .traditionalChinese: "%d 個任務", .japanese: "%d タスク", .korean: "작업 %d개",
        .spanish: "%d tareas", .german: "%d Aufgaben", .french: "%d tâches",
        .portuguese: "%d tarefas", .portugueseBrazil: "%d tarefas"
    ],
    "%d tasks across %d active days": [
        .traditionalChinese: "%d 個任務，分布於 %d 個活躍日", .japanese: "%d タスク、アクティブ日数 %d 日", .korean: "활동일 %d일 동안 작업 %d개",
        .spanish: "%d tareas en %d días activos", .german: "%d Aufgaben an %d aktiven Tagen", .french: "%d tâches sur %d jours actifs",
        .portuguese: "%d tarefas em %d dias ativos", .portugueseBrazil: "%d tarefas em %d dias ativos"
    ],
    "%d tasks · %@ steps": [
        .traditionalChinese: "%d 個任務 · %@ 步", .japanese: "%d タスク · %@ ステップ", .korean: "작업 %d개 · %@단계",
        .spanish: "%d tareas · %@ pasos", .german: "%d Aufgaben · %@ Schritte", .french: "%d tâches · %@ étapes",
        .portuguese: "%d tarefas · %@ passos", .portugueseBrazil: "%d tarefas · %@ etapas"
    ],
    "30 Days": [
        .traditionalChinese: "30 天", .japanese: "30日間", .korean: "30일",
        .spanish: "30 días", .german: "30 Tage", .french: "30 jours",
        .portuguese: "30 dias", .portugueseBrazil: "30 dias"
    ],
    "A task complexity indicator": [
        .traditionalChinese: "任務複雜度參考", .japanese: "タスクの複雑さの目安", .korean: "작업 복잡도 참고 지표",
        .spanish: "Un indicador de complejidad de tareas", .german: "Ein Hinweis auf die Aufgabenkomplexität", .french: "Un indicateur de complexité des tâches",
        .portuguese: "Um indicador da complexidade das tarefas", .portugueseBrazil: "Um indicador da complexidade das tarefas"
    ],
    "Active Days": [
        .traditionalChinese: "活躍天數", .japanese: "アクティブ日数", .korean: "활동일",
        .spanish: "Días activos", .german: "Aktive Tage", .french: "Jours actifs",
        .portuguese: "Dias ativos", .portugueseBrazil: "Dias ativos"
    ],
    "Activity time range": [
        .traditionalChinese: "活動時間範圍", .japanese: "アクティビティ期間", .korean: "활동 기간",
        .spanish: "Intervalo de actividad", .german: "Aktivitätszeitraum", .french: "Période d’activité",
        .portuguese: "Período de atividade", .portugueseBrazil: "Período de atividade"
    ],
    "Actual": [
        .traditionalChinese: "實際", .japanese: "実績", .korean: "실제",
        .spanish: "Real", .german: "Tatsächlich", .french: "Réel",
        .portuguese: "Real", .portugueseBrazil: "Real"
    ],
    "Antigravity Local Activity": [
        .traditionalChinese: "Antigravity 本機活動", .japanese: "Antigravity ローカルアクティビティ", .korean: "Antigravity 로컬 활동",
        .spanish: "Actividad local de Antigravity", .german: "Lokale Antigravity-Aktivität", .french: "Activité locale d’Antigravity",
        .portuguese: "Atividade local do Antigravity", .portugueseBrazil: "Atividade local do Antigravity"
    ],
    "Antigravity Refresh Rate": [
        .traditionalChinese: "Antigravity 重新整理頻率", .japanese: "Antigravity の更新頻度", .korean: "Antigravity 새로 고침 주기",
        .spanish: "Frecuencia de actualización de Antigravity", .german: "Antigravity-Aktualisierungsintervall", .french: "Fréquence d’actualisation d’Antigravity",
        .portuguese: "Frequência de atualização do Antigravity", .portugueseBrazil: "Frequência de atualização do Antigravity"
    ],
    "Claude Refresh Rate": [
        .traditionalChinese: "Claude 重新整理頻率", .japanese: "Claude の更新頻度", .korean: "Claude 새로 고침 주기",
        .spanish: "Frecuencia de actualización de Claude", .german: "Claude-Aktualisierungsintervall", .french: "Fréquence d’actualisation de Claude",
        .portuguese: "Frequência de atualização do Claude", .portugueseBrazil: "Frequência de atualização do Claude"
    ],
    "Antigravity activity increased from no tasks in the previous 7 days. Watch quota pace as activity grows.": [
        .traditionalChinese: "前 7 天沒有任務，本週 Antigravity 活動已恢復；活動增加時請留意額度速度。",
        .japanese: "前の7日間はタスクがありませんでしたが、Antigravity のアクティビティが増えました。増加に伴うクォータのペースに注意してください。",
        .korean: "이전 7일에는 작업이 없었지만 Antigravity 활동이 증가했습니다. 활동 증가에 따라 할당량 속도를 확인하세요.",
        .spanish: "La actividad de Antigravity aumentó desde cero tareas en los 7 días anteriores. Vigila el ritmo de la cuota al crecer la actividad.",
        .german: "Die Antigravity-Aktivität ist gegenüber null Aufgaben in den vorherigen 7 Tagen gestiegen. Behalten Sie das Kontingenttempo im Blick.",
        .french: "L’activité Antigravity a augmenté après une période de 7 jours sans tâche. Surveillez le rythme du quota à mesure que l’activité progresse.",
        .portuguese: "A atividade do Antigravity aumentou após 7 dias sem tarefas. Acompanhe o ritmo da quota à medida que a atividade cresce.",
        .portugueseBrazil: "A atividade do Antigravity aumentou após 7 dias sem tarefas. Acompanhe o ritmo da cota conforme a atividade cresce."
    ],
    "Antigravity daily task trend chart": [
        .traditionalChinese: "Antigravity 每日任務趨勢圖", .japanese: "Antigravity の日別タスク推移グラフ", .korean: "Antigravity 일별 작업 추세 차트",
        .spanish: "Gráfico de tendencia diaria de tareas de Antigravity", .german: "Diagramm des täglichen Antigravity-Aufgabentrends", .french: "Graphique de tendance quotidienne des tâches Antigravity",
        .portuguese: "Gráfico da tendência diária de tarefas do Antigravity", .portugueseBrazil: "Gráfico de tendência diária de tarefas do Antigravity"
    ],
    "Antigravity local activity is not available yet": [
        .traditionalChinese: "Antigravity 本機活動暫不可用", .japanese: "Antigravity のローカルアクティビティはまだ利用できません", .korean: "Antigravity 로컬 활동을 아직 사용할 수 없습니다",
        .spanish: "La actividad local de Antigravity aún no está disponible", .german: "Lokale Antigravity-Aktivität ist noch nicht verfügbar", .french: "L’activité locale d’Antigravity n’est pas encore disponible",
        .portuguese: "A atividade local do Antigravity ainda não está disponível", .portugueseBrazil: "A atividade local do Antigravity ainda não está disponível"
    ],
    "Antigravity quota is not available yet": [
        .traditionalChinese: "Antigravity 額度暫不可用", .japanese: "Antigravity のクォータはまだ利用できません", .korean: "Antigravity 할당량을 아직 사용할 수 없습니다",
        .spanish: "La cuota de Antigravity aún no está disponible", .german: "Das Antigravity-Kontingent ist noch nicht verfügbar", .french: "Le quota Antigravity n’est pas encore disponible",
        .portuguese: "A quota do Antigravity ainda não está disponível", .portugueseBrazil: "A cota do Antigravity ainda não está disponível"
    ],
    "Antigravity quota trend chart": [
        .traditionalChinese: "Antigravity 額度趨勢圖", .japanese: "Antigravity クォータ推移グラフ", .korean: "Antigravity 할당량 추세 차트",
        .spanish: "Gráfico de tendencia de cuota de Antigravity", .german: "Diagramm des Antigravity-Kontingenttrends", .french: "Graphique de tendance du quota Antigravity",
        .portuguese: "Gráfico da tendência da quota do Antigravity", .portugueseBrazil: "Gráfico de tendência da cota do Antigravity"
    ],
    "Antigravity tasks are down %.0f%% from the previous 7 days.": [
        .traditionalChinese: "Antigravity 任務數比前 7 天減少 %.0f%%。", .japanese: "Antigravity のタスク数は前の7日間から %.0f%% 減少しています。", .korean: "Antigravity 작업 수가 이전 7일보다 %.0f%% 감소했습니다.",
        .spanish: "Las tareas de Antigravity bajaron un %.0f%% respecto a los 7 días anteriores.", .german: "Antigravity-Aufgaben sind gegenüber den vorherigen 7 Tagen um %.0f%% gesunken.", .french: "Les tâches Antigravity ont diminué de %.0f%% par rapport aux 7 jours précédents.",
        .portuguese: "As tarefas do Antigravity diminuíram %.0f%% face aos 7 dias anteriores.", .portugueseBrazil: "As tarefas do Antigravity caíram %.0f%% em relação aos 7 dias anteriores."
    ],
    "Antigravity tasks are up %.0f%% from the previous 7 days. Watch quota pace as activity grows.": [
        .traditionalChinese: "Antigravity 任務數比前 7 天增加 %.0f%%，活動增加時請留意額度速度。",
        .japanese: "Antigravity のタスク数は前の7日間から %.0f%% 増加しています。アクティビティ増加に伴うクォータのペースに注意してください。",
        .korean: "Antigravity 작업 수가 이전 7일보다 %.0f%% 증가했습니다. 활동 증가에 따라 할당량 속도를 확인하세요.",
        .spanish: "Las tareas de Antigravity subieron un %.0f%% respecto a los 7 días anteriores. Vigila el ritmo de la cuota al crecer la actividad.",
        .german: "Antigravity-Aufgaben sind gegenüber den vorherigen 7 Tagen um %.0f%% gestiegen. Behalten Sie das Kontingenttempo bei wachsender Aktivität im Blick.",
        .french: "Les tâches Antigravity ont augmenté de %.0f%% par rapport aux 7 jours précédents. Surveillez le rythme du quota à mesure que l’activité progresse.",
        .portuguese: "As tarefas do Antigravity aumentaram %.0f%% face aos 7 dias anteriores. Acompanhe o ritmo da quota à medida que a atividade cresce.",
        .portugueseBrazil: "As tarefas do Antigravity aumentaram %.0f%% em relação aos 7 dias anteriores. Acompanhe o ritmo da cota conforme a atividade cresce."
    ],
    "At Reset": [
        .traditionalChinese: "重設時預計", .japanese: "リセット時の予測", .korean: "재설정 시 예상",
        .spanish: "Al restablecer", .german: "Beim Zurücksetzen", .french: "À la réinitialisation",
        .portuguese: "Na reposição", .portugueseBrazil: "Na redefinição"
    ],
    "Attempt %@ · Success %@": [
        .traditionalChinese: "嘗試 %@ · 成功 %@", .japanese: "試行 %@ · 成功 %@", .korean: "시도 %@ · 성공 %@",
        .spanish: "Intento %@ · Éxito %@", .german: "Versuch %@ · Erfolg %@", .french: "Tentative %@ · Réussite %@",
        .portuguese: "Tentativa %@ · Sucesso %@", .portugueseBrazil: "Tentativa %@ · Sucesso %@"
    ],
    "Attempt %@ · Success %@ · Next %@": [
        .traditionalChinese: "嘗試 %@ · 成功 %@ · 下次 %@", .japanese: "試行 %@ · 成功 %@ · 次回 %@", .korean: "시도 %@ · 성공 %@ · 다음 %@",
        .spanish: "Intento %@ · Éxito %@ · Próximo %@", .german: "Versuch %@ · Erfolg %@ · Nächster %@", .french: "Tentative %@ · Réussite %@ · Prochaine %@",
        .portuguese: "Tentativa %@ · Sucesso %@ · Próxima %@", .portugueseBrazil: "Tentativa %@ · Sucesso %@ · Próxima %@"
    ],
    "Attempt %@ · Success %@ · Retry %@": [
        .traditionalChinese: "嘗試 %@ · 成功 %@ · %@後重試", .japanese: "試行 %@ · 成功 %@ · %@ に再試行", .korean: "시도 %@ · 성공 %@ · %@ 재시도",
        .spanish: "Intento %@ · Éxito %@ · Reintento %@", .german: "Versuch %@ · Erfolg %@ · Erneuter Versuch %@", .french: "Tentative %@ · Réussite %@ · Nouvel essai %@",
        .portuguese: "Tentativa %@ · Sucesso %@ · Nova tentativa %@", .portugueseBrazil: "Tentativa %@ · Sucesso %@ · Nova tentativa %@"
    ],
    "Building a clearer usage picture": [
        .traditionalChinese: "正在完善用量判斷", .japanese: "使用状況の判断を整えています", .korean: "사용량 판단을 개선하는 중",
        .spanish: "Mejorando la visión del uso", .german: "Das Nutzungsbild wird vervollständigt", .french: "Affinement de l’analyse d’utilisation",
        .portuguese: "A aperfeiçoar a análise de utilização", .portugueseBrazil: "Aprimorando a análise de uso"
    ],
    "Collecting": [
        .traditionalChinese: "正在累積", .japanese: "収集中", .korean: "수집 중",
        .spanish: "Recopilando", .german: "Wird erfasst", .french: "Collecte en cours",
        .portuguese: "A recolher", .portugueseBrazil: "Coletando"
    ],
    "Collecting trend data": [
        .traditionalChinese: "正在累積趨勢資料", .japanese: "推移データを収集中", .korean: "추세 데이터 수집 중",
        .spanish: "Recopilando datos de tendencia", .german: "Trenddaten werden erfasst", .french: "Collecte des données de tendance",
        .portuguese: "A recolher dados de tendência", .portugueseBrazil: "Coletando dados de tendência"
    ],
    "Counts active days only": [
        .traditionalChinese: "僅計算有活動的日期", .japanese: "アクティブな日のみを集計", .korean: "활동이 있는 날짜만 계산",
        .spanish: "Solo cuenta los días activos", .german: "Nur aktive Tage werden gezählt", .french: "Compte uniquement les jours actifs",
        .portuguese: "Conta apenas os dias ativos", .portugueseBrazil: "Conta apenas os dias ativos"
    ],
    "Current Pace": [
        .traditionalChinese: "目前速度", .japanese: "現在のペース", .korean: "현재 속도",
        .spanish: "Ritmo actual", .german: "Aktuelles Tempo", .french: "Rythme actuel",
        .portuguese: "Ritmo atual", .portugueseBrazil: "Ritmo atual"
    ],
    "Current cycle · used quota percentage": [
        .traditionalChinese: "目前週期 · 已用額度百分比", .japanese: "現在のサイクル · 使用済みクォータの割合", .korean: "현재 주기 · 사용한 할당량 비율",
        .spanish: "Ciclo actual · porcentaje de cuota usado", .german: "Aktueller Zyklus · verwendetes Kontingent in Prozent", .french: "Cycle actuel · pourcentage de quota utilisé",
        .portuguese: "Ciclo atual · percentagem de quota utilizada", .portugueseBrazil: "Ciclo atual · percentual da cota usado"
    ],
    "Current usage pace is healthy": [
        .traditionalChinese: "目前使用節奏平穩", .japanese: "現在の使用ペースは良好です", .korean: "현재 사용 속도가 안정적입니다",
        .spanish: "El ritmo de uso actual es saludable", .german: "Das aktuelle Nutzungstempo ist unbedenklich", .french: "Le rythme d’utilisation actuel est sain",
        .portuguese: "O ritmo de utilização atual é saudável", .portugueseBrazil: "O ritmo de uso atual está saudável"
    ],
    "Current usage pace needs attention": [
        .traditionalChinese: "目前消耗速度需要關注", .japanese: "現在の使用ペースに注意が必要です", .korean: "현재 사용 속도에 주의가 필요합니다",
        .spanish: "El ritmo de uso actual requiere atención", .german: "Das aktuelle Nutzungstempo erfordert Aufmerksamkeit", .french: "Le rythme d’utilisation actuel nécessite votre attention",
        .portuguese: "O ritmo de utilização atual requer atenção", .portugueseBrazil: "O ritmo de uso atual requer atenção"
    ],
    "Current used quota is %@.": [
        .traditionalChinese: "目前已用額度為 %@。", .japanese: "現在の使用済みクォータは %@ です。", .korean: "현재 사용한 할당량은 %@입니다.",
        .spanish: "La cuota usada actualmente es %@.", .german: "Aktuell sind %@ des Kontingents verbraucht.", .french: "Le quota actuellement utilisé est de %@.",
        .portuguese: "A quota utilizada atualmente é %@.", .portugueseBrazil: "A cota usada atualmente é %@."
    ],
    "Daily Task Trend": [
        .traditionalChinese: "每日任務趨勢", .japanese: "日別タスク推移", .korean: "일별 작업 추세",
        .spanish: "Tendencia diaria de tareas", .german: "Täglicher Aufgabentrend", .french: "Tendance quotidienne des tâches",
        .portuguese: "Tendência diária de tarefas", .portugueseBrazil: "Tendência diária de tarefas"
    ],
    "Data is stale": [
        .traditionalChinese: "資料已過期", .japanese: "データが古くなっています", .korean: "데이터가 오래되었습니다",
        .spanish: "Los datos están obsoletos", .german: "Die Daten sind veraltet", .french: "Les données sont obsolètes",
        .portuguese: "Os dados estão desatualizados", .portugueseBrazil: "Os dados estão desatualizados"
    ],
    "Down %.0f%% vs previous period": [
        .traditionalChinese: "比上一週期減少 %.0f%%", .japanese: "前期間比 %.0f%% 減", .korean: "이전 기간 대비 %.0f%% 감소",
        .spanish: "Baja un %.0f%% frente al periodo anterior", .german: "%.0f%% weniger als im vorherigen Zeitraum", .french: "Baisse de %.0f%% par rapport à la période précédente",
        .portuguese: "Menos %.0f%% face ao período anterior", .portugueseBrazil: "Queda de %.0f%% em relação ao período anterior"
    ],
    "Each tool keeps its native units without cross-tool ranking.": [
        .traditionalChinese: "各工具保留各自的統計單位，不進行跨工具排名。",
        .japanese: "各ツールは固有の単位で表示し、ツール間の順位付けは行いません。",
        .korean: "각 도구는 고유한 단위를 유지하며 도구 간 순위를 매기지 않습니다.",
        .spanish: "Cada herramienta conserva sus unidades propias, sin clasificar herramientas entre sí.",
        .german: "Jedes Tool behält seine eigenen Einheiten; es gibt keine toolübergreifende Rangliste.",
        .french: "Chaque outil conserve ses propres unités, sans classement entre les outils.",
        .portuguese: "Cada ferramenta mantém as suas unidades, sem classificação entre ferramentas.",
        .portugueseBrazil: "Cada ferramenta mantém suas próprias unidades, sem classificação entre ferramentas."
    ],
    "Expected to run out before reset": [
        .traditionalChinese: "預計會在重設前耗盡", .japanese: "リセット前に使い切る見込みです", .korean: "재설정 전에 소진될 것으로 예상됩니다",
        .spanish: "Se espera que se agote antes del restablecimiento", .german: "Voraussichtlich vor dem Zurücksetzen aufgebraucht", .french: "Épuisement prévu avant la réinitialisation",
        .portuguese: "Prevê-se que esgote antes da reposição", .portugueseBrazil: "Previsão de esgotamento antes da redefinição"
    ],
    "Forecast": [
        .traditionalChinese: "預測", .japanese: "予測", .korean: "예측",
        .spanish: "Previsión", .german: "Prognose", .french: "Prévision",
        .portuguese: "Previsão", .portugueseBrazil: "Previsão"
    ],
    "Forecast paused": [
        .traditionalChinese: "預測已暫停", .japanese: "予測を一時停止しました", .korean: "예측 일시 중지됨",
        .spanish: "Previsión pausada", .german: "Prognose pausiert", .french: "Prévision suspendue",
        .portuguese: "Previsão em pausa", .portugueseBrazil: "Previsão pausada"
    ],
    "Forecast pending": [
        .traditionalChinese: "預測待累積", .japanese: "予測データを収集中", .korean: "예측 데이터 수집 중",
        .spanish: "Previsión pendiente", .german: "Prognose steht aus", .french: "Prévision en attente",
        .portuguese: "Previsão pendente", .portugueseBrazil: "Previsão pendente"
    ],
    "Forecasting is paused. Refresh quota before judging usage pace.": [
        .traditionalChinese: "預測已暫停，請重新整理額度後再判斷使用節奏。",
        .japanese: "予測は一時停止中です。使用ペースを判断する前にクォータを更新してください。",
        .korean: "예측이 일시 중지되었습니다. 사용 속도를 판단하기 전에 할당량을 새로 고치세요.",
        .spanish: "La previsión está pausada. Actualiza la cuota antes de valorar el ritmo de uso.",
        .german: "Die Prognose ist pausiert. Aktualisieren Sie das Kontingent, bevor Sie das Nutzungstempo beurteilen.",
        .french: "La prévision est suspendue. Actualisez le quota avant d’évaluer le rythme d’utilisation.",
        .portuguese: "A previsão está em pausa. Atualize a quota antes de avaliar o ritmo de utilização.",
        .portugueseBrazil: "A previsão está pausada. Atualize a cota antes de avaliar o ritmo de uso."
    ],
    "Highest-Risk Quota": [
        .traditionalChinese: "最高風險額度", .japanese: "最もリスクの高いクォータ", .korean: "가장 위험한 할당량",
        .spanish: "Cuota de mayor riesgo", .german: "Kontingent mit höchstem Risiko", .french: "Quota le plus à risque",
        .portuguese: "Quota de maior risco", .portugueseBrazil: "Cota de maior risco"
    ],
    "Last %@": [
        .traditionalChinese: "上次 %@", .japanese: "前回 %@", .korean: "마지막 %@",
        .spanish: "Último %@", .german: "Zuletzt %@", .french: "Dernière %@",
        .portuguese: "Última %@", .portugueseBrazil: "Última %@"
    ],
    "Last %d days · tasks per day": [
        .traditionalChinese: "最近 %d 天 · 每日任務數", .japanese: "直近%d日 · 1日あたりのタスク数", .korean: "최근 %d일 · 일별 작업 수",
        .spanish: "Últimos %d días · tareas por día", .german: "Letzte %d Tage · Aufgaben pro Tag", .french: "%d derniers jours · tâches par jour",
        .portuguese: "Últimos %d dias · tarefas por dia", .portugueseBrazil: "Últimos %d dias · tarefas por dia"
    ],
    "Last Sync": [
        .traditionalChinese: "上次同步", .japanese: "前回の同期", .korean: "마지막 동기화",
        .spanish: "Última sincronización", .german: "Letzte Synchronisierung", .french: "Dernière synchronisation",
        .portuguese: "Última sincronização", .portugueseBrazil: "Última sincronização"
    ],
    "Last activity %@": [
        .traditionalChinese: "最後活動 %@", .japanese: "最終アクティビティ %@", .korean: "마지막 활동 %@",
        .spanish: "Última actividad %@", .german: "Letzte Aktivität %@", .french: "Dernière activité %@",
        .portuguese: "Última atividade %@", .portugueseBrazil: "Última atividade %@"
    ],
    "Local data is syncing": [
        .traditionalChinese: "本機資料正在同步", .japanese: "ローカルデータを同期中", .korean: "로컬 데이터 동기화 중",
        .spanish: "Sincronizando datos locales", .german: "Lokale Daten werden synchronisiert", .french: "Synchronisation des données locales",
        .portuguese: "A sincronizar dados locais", .portugueseBrazil: "Sincronizando dados locais"
    ],
    "Model Availability": [
        .traditionalChinese: "模型餘量", .japanese: "モデルの利用可能量", .korean: "모델 사용 가능량",
        .spanish: "Disponibilidad de modelos", .german: "Modellverfügbarkeit", .french: "Disponibilité des modèles",
        .portuguese: "Disponibilidade dos modelos", .portugueseBrazil: "Disponibilidade dos modelos"
    ],
    "Next Refresh": [
        .traditionalChinese: "下次重新整理", .japanese: "次回の更新", .korean: "다음 새로 고침",
        .spanish: "Próxima actualización", .german: "Nächste Aktualisierung", .french: "Prochaine actualisation",
        .portuguese: "Próxima atualização", .portugueseBrazil: "Próxima atualização"
    ],
    "No Antigravity activity in the last %d days": [
        .traditionalChinese: "最近 %d 天沒有 Antigravity 活動", .japanese: "直近%d日間に Antigravity のアクティビティはありません", .korean: "최근 %d일 동안 Antigravity 활동이 없습니다",
        .spanish: "No hubo actividad de Antigravity en los últimos %d días", .german: "Keine Antigravity-Aktivität in den letzten %d Tagen", .french: "Aucune activité Antigravity au cours des %d derniers jours",
        .portuguese: "Sem atividade do Antigravity nos últimos %d dias", .portugueseBrazil: "Nenhuma atividade do Antigravity nos últimos %d dias"
    ],
    "No activity recorded yet": [
        .traditionalChinese: "尚無活動記錄", .japanese: "アクティビティはまだ記録されていません", .korean: "아직 기록된 활동이 없습니다",
        .spanish: "Aún no hay actividad registrada", .german: "Noch keine Aktivität erfasst", .french: "Aucune activité enregistrée pour le moment",
        .portuguese: "Ainda não há atividade registada", .portugueseBrazil: "Ainda não há atividade registrada"
    ],
    "No attempt yet": [
        .traditionalChinese: "尚未嘗試", .japanese: "まだ試行していません", .korean: "아직 시도하지 않음",
        .spanish: "Aún no se ha intentado", .german: "Noch kein Versuch", .french: "Aucune tentative pour le moment",
        .portuguese: "Ainda sem tentativa", .portugueseBrazil: "Ainda não houve tentativa"
    ],
    "No local activity found": [
        .traditionalChinese: "尚未發現本機活動", .japanese: "ローカルアクティビティが見つかりません", .korean: "로컬 활동을 찾지 못했습니다",
        .spanish: "No se encontró actividad local", .german: "Keine lokale Aktivität gefunden", .french: "Aucune activité locale détectée",
        .portuguese: "Não foi encontrada atividade local", .portugueseBrazil: "Nenhuma atividade local encontrada"
    ],
    "No prior baseline": [
        .traditionalChinese: "暫無上期基準", .japanese: "前期間の基準なし", .korean: "이전 기간 기준 없음",
        .spanish: "Sin referencia anterior", .german: "Keine vorherige Vergleichsbasis", .french: "Aucune référence antérieure",
        .portuguese: "Sem referência anterior", .portugueseBrazil: "Sem referência anterior"
    ],
    "No project activity is available": [
        .traditionalChinese: "暫無可統計的專案活動", .japanese: "集計できるプロジェクトアクティビティはありません", .korean: "집계할 수 있는 프로젝트 활동이 없습니다",
        .spanish: "No hay actividad de proyectos disponible", .german: "Keine Projektaktivität verfügbar", .french: "Aucune activité de projet disponible",
        .portuguese: "Não há atividade de projetos disponível", .portugueseBrazil: "Nenhuma atividade de projeto disponível"
    ],
    "No quota or sync issues need attention right now.": [
        .traditionalChinese: "目前沒有需要處理的額度或同步問題。", .japanese: "現在、対応が必要なクォータまたは同期の問題はありません。", .korean: "현재 확인이 필요한 할당량 또는 동기화 문제가 없습니다.",
        .spanish: "Ahora mismo no hay problemas de cuota o sincronización que requieran atención.", .german: "Derzeit gibt es keine Kontingent- oder Synchronisierungsprobleme, die Aufmerksamkeit erfordern.", .french: "Aucun problème de quota ou de synchronisation ne nécessite votre attention pour le moment.",
        .portuguese: "Neste momento, não há problemas de quota ou sincronização que exijam atenção.", .portugueseBrazil: "No momento, não há problemas de cota ou sincronização que exijam atenção."
    ],
    "No successful sync": [
        .traditionalChinese: "尚未成功", .japanese: "同期成功なし", .korean: "성공한 동기화 없음",
        .spanish: "Aún no hay sincronización correcta", .german: "Noch keine erfolgreiche Synchronisierung", .french: "Aucune synchronisation réussie",
        .portuguese: "Ainda sem sincronização bem-sucedida", .portugueseBrazil: "Ainda sem sincronização bem-sucedida"
    ],
    "No tasks in the previous period": [
        .traditionalChinese: "上一週期沒有任務", .japanese: "前期間にタスクなし", .korean: "이전 기간에 작업 없음",
        .spanish: "Sin tareas en el periodo anterior", .german: "Keine Aufgaben im vorherigen Zeitraum", .french: "Aucune tâche sur la période précédente",
        .portuguese: "Sem tarefas no período anterior", .portugueseBrazil: "Sem tarefas no período anterior"
    ],
    "Not scheduled": [
        .traditionalChinese: "等待安排", .japanese: "未定", .korean: "예약되지 않음",
        .spanish: "Sin programar", .german: "Nicht geplant", .french: "Non planifié",
        .portuguese: "Não agendado", .portugueseBrazil: "Não agendado"
    ],
    "Not selected": [
        .traditionalChinese: "未選取", .japanese: "未選択", .korean: "선택되지 않음",
        .spanish: "No seleccionado", .german: "Nicht ausgewählt", .french: "Non sélectionné",
        .portuguese: "Não selecionado", .portugueseBrazil: "Não selecionado"
    ],
    "Other models": [
        .traditionalChinese: "其他模型", .japanese: "その他のモデル", .korean: "기타 모델",
        .spanish: "Otros modelos", .german: "Weitere Modelle", .french: "Autres modèles",
        .portuguese: "Outros modelos", .portugueseBrazil: "Outros modelos"
    ],
    "Overall quota status is healthy": [
        .traditionalChinese: "整體額度狀態健康", .japanese: "全体のクォータ状態は良好です", .korean: "전체 할당량 상태가 양호합니다",
        .spanish: "El estado general de la cuota es saludable", .german: "Der allgemeine Kontingentstatus ist unbedenklich", .french: "L’état global des quotas est sain",
        .portuguese: "O estado geral das quotas é saudável", .portugueseBrazil: "O estado geral das cotas está saudável"
    ],
    "Overall status and recommendations": [
        .traditionalChinese: "整體狀態與建議", .japanese: "全体の状態と提案", .korean: "전체 상태 및 제안",
        .spanish: "Estado general y recomendaciones", .german: "Gesamtstatus und Empfehlungen", .french: "État global et recommandations",
        .portuguese: "Estado geral e recomendações", .portugueseBrazil: "Status geral e recomendações"
    ],
    "Project Activity · 30 Days": [
        .traditionalChinese: "最近 30 天專案活動", .japanese: "プロジェクトアクティビティ · 30日間", .korean: "프로젝트 활동 · 30일",
        .spanish: "Actividad de proyectos · 30 días", .german: "Projektaktivität · 30 Tage", .french: "Activité des projets · 30 jours",
        .portuguese: "Atividade de projetos · 30 dias", .portugueseBrazil: "Atividade de projetos · 30 dias"
    ],
    "Quota Reset": [
        .traditionalChinese: "額度重設", .japanese: "クォータのリセット", .korean: "할당량 재설정",
        .spanish: "Restablecimiento de cuota", .german: "Kontingent zurücksetzen", .french: "Réinitialisation du quota",
        .portuguese: "Reposição da quota", .portugueseBrazil: "Redefinição da cota"
    ],
    "Quota Trend": [
        .traditionalChinese: "額度趨勢", .japanese: "クォータの推移", .korean: "할당량 추세",
        .spanish: "Tendencia de cuota", .german: "Kontingenttrend", .french: "Tendance du quota",
        .portuguese: "Tendência da quota", .portugueseBrazil: "Tendência da cota"
    ],
    "Quota pools are imbalanced": [
        .traditionalChinese: "額度池餘量不均衡", .japanese: "クォータプールの残量に偏りがあります", .korean: "할당량 풀의 잔여량이 고르지 않습니다",
        .spanish: "Los grupos de cuota están desequilibrados", .german: "Die Kontingentpools sind unausgewogen", .french: "Les réserves de quota sont déséquilibrées",
        .portuguese: "Os grupos de quota estão desequilibrados", .portugueseBrazil: "Os grupos de cota estão desequilibrados"
    ],
    "Quota risk needs attention": [
        .traditionalChinese: "有額度風險需要處理", .japanese: "クォータのリスクに対応が必要です", .korean: "할당량 위험에 주의가 필요합니다",
        .spanish: "Un riesgo de cuota requiere atención", .german: "Ein Kontingentrisiko erfordert Aufmerksamkeit", .french: "Un risque de quota nécessite votre attention",
        .portuguese: "Um risco de quota requer atenção", .portugueseBrazil: "Um risco de cota requer atenção"
    ],
    "Quota risks and recommended actions will appear after the first sync.": [
        .traditionalChinese: "完成首次同步後，這裡會彙總額度風險和行動建議。",
        .japanese: "最初の同期後に、クォータのリスクと推奨アクションがここに表示されます。",
        .korean: "첫 동기화 후 할당량 위험과 권장 조치가 여기에 표시됩니다.",
        .spanish: "Los riesgos de cuota y las acciones recomendadas aparecerán tras la primera sincronización.",
        .german: "Kontingentrisiken und empfohlene Maßnahmen erscheinen nach der ersten Synchronisierung.",
        .french: "Les risques de quota et les actions recommandées apparaîtront après la première synchronisation.",
        .portuguese: "Os riscos de quota e as ações recomendadas aparecem após a primeira sincronização.",
        .portugueseBrazil: "Os riscos de cota e as ações recomendadas aparecerão após a primeira sincronização."
    ],
    "Quota usage is elevated": [
        .traditionalChinese: "額度消耗偏快", .japanese: "クォータ消費が速めです", .korean: "할당량 소모가 빠릅니다",
        .spanish: "El uso de cuota es elevado", .german: "Der Kontingentverbrauch ist erhöht", .french: "L’utilisation du quota est élevée",
        .portuguese: "A utilização da quota está elevada", .portugueseBrazil: "O uso da cota está elevado"
    ],
    "Recent activity decreased": [
        .traditionalChinese: "近期活動減少", .japanese: "最近のアクティビティが減少", .korean: "최근 활동 감소",
        .spanish: "La actividad reciente disminuyó", .german: "Die jüngste Aktivität ist gesunken", .french: "L’activité récente a diminué",
        .portuguese: "A atividade recente diminuiu", .portugueseBrazil: "A atividade recente diminuiu"
    ],
    "Recent activity increased": [
        .traditionalChinese: "近期活動增加", .japanese: "最近のアクティビティが増加", .korean: "최근 활동 증가",
        .spanish: "La actividad reciente aumentó", .german: "Die jüngste Aktivität ist gestiegen", .french: "L’activité récente a augmenté",
        .portuguese: "A atividade recente aumentou", .portugueseBrazil: "A atividade recente aumentou"
    ],
    "Refresh limited": [
        .traditionalChinese: "重新整理受限", .japanese: "更新が制限されています", .korean: "새로 고침 제한됨",
        .spanish: "Actualización limitada", .german: "Aktualisierung eingeschränkt", .french: "Actualisation limitée",
        .portuguese: "Atualização limitada", .portugueseBrazil: "Atualização limitada"
    ],
    "Refreshes Antigravity quota every %@.": [
        .traditionalChinese: "每 %@ 自動重新整理 Antigravity 額度。", .japanese: "%@ ごとに Antigravity のクォータを更新します。", .korean: "%@마다 Antigravity 할당량을 새로 고칩니다.",
        .spanish: "Actualiza la cuota de Antigravity cada %@.", .german: "Aktualisiert das Antigravity-Kontingent alle %@.", .french: "Actualise le quota Antigravity toutes les %@.",
        .portuguese: "Atualiza a quota do Antigravity a cada %@.", .portugueseBrazil: "Atualiza a cota do Antigravity a cada %@."
    ],
    "Refreshes Claude quota every %@.": [
        .traditionalChinese: "每 %@ 自動重新整理 Claude 額度。", .japanese: "%@ ごとに Claude のクォータを更新します。", .korean: "%@마다 Claude 할당량을 새로 고칩니다.",
        .spanish: "Actualiza la cuota de Claude cada %@.", .german: "Aktualisiert das Claude-Kontingent alle %@.", .french: "Actualise le quota Claude toutes les %@.",
        .portuguese: "Atualiza a quota do Claude a cada %@.", .portugueseBrazil: "Atualiza a cota do Claude a cada %@."
    ],
    "Reset %@": [
        .traditionalChinese: "%@ 重設", .japanese: "リセット %@", .korean: "재설정 %@",
        .spanish: "Restablecimiento %@", .german: "Zurücksetzen %@", .french: "Réinitialisation %@",
        .portuguese: "Reposição %@", .portugueseBrazil: "Redefinição %@"
    ],
    "Reset time unknown": [
        .traditionalChinese: "重設時間未知", .japanese: "リセット時刻不明", .korean: "재설정 시간 알 수 없음",
        .spanish: "Hora de restablecimiento desconocida", .german: "Zeitpunkt des Zurücksetzens unbekannt", .french: "Heure de réinitialisation inconnue",
        .portuguese: "Hora de reposição desconhecida", .portugueseBrazil: "Horário de redefinição desconhecido"
    ],
    "Reset unknown": [
        .traditionalChinese: "重設時間未知", .japanese: "リセット不明", .korean: "재설정 시간 알 수 없음",
        .spanish: "Restablecimiento desconocido", .german: "Zurücksetzen unbekannt", .french: "Réinitialisation inconnue",
        .portuguese: "Reposição desconhecida", .portugueseBrazil: "Redefinição desconhecida"
    ],
    "Runs out %@": [
        .traditionalChinese: "%@ 耗盡", .japanese: "%@ に使い切る見込み", .korean: "%@ 소진 예상",
        .spanish: "Se agota %@", .german: "Aufgebraucht %@", .french: "Épuisement %@",
        .portuguese: "Esgota %@", .portugueseBrazil: "Esgota %@"
    ],
    "Scanned %@": [
        .traditionalChinese: "%@ 完成掃描", .japanese: "%@ にスキャン", .korean: "%@ 스캔됨",
        .spanish: "Escaneado %@", .german: "Gescannt %@", .french: "Analyse %@",
        .portuguese: "Analisado %@", .portugueseBrazil: "Verificado %@"
    ],
    "Select to view this quota pool trend": [
        .traditionalChinese: "選取後查看此額度池趨勢", .japanese: "選択してこのクォータプールの推移を表示", .korean: "선택하여 이 할당량 풀 추세 보기",
        .spanish: "Selecciona para ver la tendencia de este grupo de cuota", .german: "Auswählen, um den Trend dieses Kontingentpools anzuzeigen", .french: "Sélectionnez pour afficher la tendance de cette réserve de quota",
        .portuguese: "Selecione para ver a tendência deste grupo de quota", .portugueseBrazil: "Selecione para ver a tendência deste grupo de cota"
    ],
    "Selected": [
        .traditionalChinese: "已選取", .japanese: "選択済み", .korean: "선택됨",
        .spanish: "Seleccionado", .german: "Ausgewählt", .french: "Sélectionné",
        .portuguese: "Selecionado", .portugueseBrazil: "Selecionado"
    ],
    "Show all %d model groups": [
        .traditionalChinese: "展開全部 %d 個模型群組", .japanese: "%d モデルグループをすべて表示", .korean: "모델 그룹 %d개 모두 표시",
        .spanish: "Mostrar los %d grupos de modelos", .german: "Alle %d Modellgruppen anzeigen", .french: "Afficher les %d groupes de modèles",
        .portuguese: "Mostrar todos os %d grupos de modelos", .portugueseBrazil: "Mostrar todos os %d grupos de modelos"
    ],
    "Show fewer models": [
        .traditionalChinese: "收起模型", .japanese: "表示するモデルを減らす", .korean: "모델 접기",
        .spanish: "Mostrar menos modelos", .german: "Weniger Modelle anzeigen", .french: "Afficher moins de modèles",
        .portuguese: "Mostrar menos modelos", .portugueseBrazil: "Mostrar menos modelos"
    ],
    "Steps": [
        .traditionalChinese: "步驟", .japanese: "ステップ", .korean: "단계",
        .spanish: "Pasos", .german: "Schritte", .french: "Étapes",
        .portuguese: "Passos", .portugueseBrazil: "Etapas"
    ],
    "Steps per Task": [
        .traditionalChinese: "平均每任務步驟", .japanese: "タスクあたりのステップ数", .korean: "작업당 단계 수",
        .spanish: "Pasos por tarea", .german: "Schritte pro Aufgabe", .french: "Étapes par tâche",
        .portuguese: "Passos por tarefa", .portugueseBrazil: "Etapas por tarefa"
    ],
    "Sustainable %.2f %@": [
        .traditionalChinese: "可持續 %.2f %@", .japanese: "持続可能 %.2f %@", .korean: "지속 가능 %.2f %@",
        .spanish: "Sostenible %.2f %@", .german: "Nachhaltig %.2f %@", .french: "Soutenable %.2f %@",
        .portuguese: "Sustentável %.2f %@", .portugueseBrazil: "Sustentável %.2f %@"
    ],
    "Sustainable limit": [
        .traditionalChinese: "可持續上限", .japanese: "持続可能な上限", .korean: "지속 가능한 상한",
        .spanish: "Límite sostenible", .german: "Nachhaltige Obergrenze", .french: "Limite soutenable",
        .portuguese: "Limite sustentável", .portugueseBrazil: "Limite sustentável"
    ],
    "Sync Status": [
        .traditionalChinese: "同步狀態", .japanese: "同期状態", .korean: "동기화 상태",
        .spanish: "Estado de sincronización", .german: "Synchronisierungsstatus", .french: "État de synchronisation",
        .portuguese: "Estado da sincronização", .portugueseBrazil: "Status da sincronização"
    ],
    "Sync issue": [
        .traditionalChinese: "同步異常", .japanese: "同期の問題", .korean: "동기화 문제",
        .spanish: "Problema de sincronización", .german: "Synchronisierungsproblem", .french: "Problème de synchronisation",
        .portuguese: "Problema de sincronização", .portugueseBrazil: "Problema de sincronização"
    ],
    "Syncing Antigravity quota...": [
        .traditionalChinese: "正在同步 Antigravity 額度…", .japanese: "Antigravity のクォータを同期中…", .korean: "Antigravity 할당량 동기화 중...",
        .spanish: "Sincronizando la cuota de Antigravity...", .german: "Antigravity-Kontingent wird synchronisiert...", .french: "Synchronisation du quota Antigravity...",
        .portuguese: "A sincronizar a quota do Antigravity...", .portugueseBrazil: "Sincronizando a cota do Antigravity..."
    ],
    "Tasks": [
        .traditionalChinese: "任務數", .japanese: "タスク", .korean: "작업",
        .spanish: "Tareas", .german: "Aufgaben", .french: "Tâches",
        .portuguese: "Tarefas", .portugueseBrazil: "Tarefas"
    ],
    "Tasks per Active Day": [
        .traditionalChinese: "每日活躍任務", .japanese: "アクティブ日あたりのタスク数", .korean: "활동일당 작업 수",
        .spanish: "Tareas por día activo", .german: "Aufgaben pro aktivem Tag", .french: "Tâches par jour actif",
        .portuguese: "Tarefas por dia ativo", .portugueseBrazil: "Tarefas por dia ativo"
    ],
    "Time unknown": [
        .traditionalChinese: "時間未知", .japanese: "時刻不明", .korean: "시간 알 수 없음",
        .spanish: "Hora desconocida", .german: "Zeit unbekannt", .french: "Heure inconnue",
        .portuguese: "Hora desconhecida", .portugueseBrazil: "Horário desconhecido"
    ],
    "Total for this period": [
        .traditionalChinese: "目前週期合計", .japanese: "現在の期間の合計", .korean: "현재 기간 합계",
        .spanish: "Total de este periodo", .german: "Summe für diesen Zeitraum", .french: "Total pour cette période",
        .portuguese: "Total deste período", .portugueseBrazil: "Total deste período"
    ],
    "Unchanged from previous period": [
        .traditionalChinese: "與上一週期持平", .japanese: "前期間から変化なし", .korean: "이전 기간과 동일",
        .spanish: "Sin cambios frente al periodo anterior", .german: "Unverändert gegenüber dem vorherigen Zeitraum", .french: "Stable par rapport à la période précédente",
        .portuguese: "Sem alterações face ao período anterior", .portugueseBrazil: "Sem alteração em relação ao período anterior"
    ],
    "Unchanged from prior": [
        .traditionalChinese: "與上期持平", .japanese: "前期間から変化なし", .korean: "이전 기간과 동일",
        .spanish: "Sin cambios respecto al anterior", .german: "Unverändert zum vorherigen Zeitraum", .french: "Stable par rapport à la période précédente",
        .portuguese: "Sem alterações face ao anterior", .portugueseBrazil: "Sem alteração em relação ao anterior"
    ],
    "Up %.0f%% vs previous period": [
        .traditionalChinese: "比上一週期增加 %.0f%%", .japanese: "前期間比 %.0f%% 増", .korean: "이전 기간 대비 %.0f%% 증가",
        .spanish: "Sube un %.0f%% frente al periodo anterior", .german: "%.0f%% mehr als im vorherigen Zeitraum", .french: "Hausse de %.0f%% par rapport à la période précédente",
        .portuguese: "Mais %.0f%% face ao período anterior", .portugueseBrazil: "Alta de %.0f%% em relação ao período anterior"
    ],
    "Up to date": [
        .traditionalChinese: "資料最新", .japanese: "最新", .korean: "최신 상태",
        .spanish: "Actualizado", .german: "Aktuell", .french: "À jour",
        .portuguese: "Atualizado", .portugueseBrazil: "Atualizado"
    ],
    "Update delayed": [
        .traditionalChinese: "更新延遲", .japanese: "更新が遅れています", .korean: "업데이트 지연",
        .spanish: "Actualización retrasada", .german: "Aktualisierung verzögert", .french: "Actualisation retardée",
        .portuguese: "Atualização atrasada", .portugueseBrazil: "Atualização atrasada"
    ],
    "Usage Pace": [
        .traditionalChinese: "消耗速度", .japanese: "使用ペース", .korean: "사용 속도",
        .spanish: "Ritmo de uso", .german: "Nutzungstempo", .french: "Rythme d’utilisation",
        .portuguese: "Ritmo de utilização", .portugueseBrazil: "Ritmo de uso"
    ],
    "Usage Pace & Forecast": [
        .traditionalChinese: "使用節奏與預測", .japanese: "使用ペースと予測", .korean: "사용 속도 및 예측",
        .spanish: "Ritmo de uso y previsión", .german: "Nutzungstempo und Prognose", .french: "Rythme d’utilisation et prévision",
        .portuguese: "Ritmo de utilização e previsão", .portugueseBrazil: "Ritmo de uso e previsão"
    ],
    "Usage may be too fast": [
        .traditionalChinese: "消耗可能偏快", .japanese: "使用ペースが速すぎる可能性があります", .korean: "사용 속도가 너무 빠를 수 있습니다",
        .spanish: "El uso puede ser demasiado rápido", .german: "Die Nutzung könnte zu schnell sein", .french: "L’utilisation est peut-être trop rapide",
        .portuguese: "A utilização pode estar demasiado rápida", .portugueseBrazil: "O uso pode estar rápido demais"
    ],
    "Usage pace and forecasts will appear after the first sync.": [
        .traditionalChinese: "首次同步完成後會顯示消耗速度和預測。", .japanese: "最初の同期後に使用ペースと予測が表示されます。", .korean: "첫 동기화 후 사용 속도와 예측이 표시됩니다.",
        .spanish: "El ritmo de uso y las previsiones aparecerán tras la primera sincronización.", .german: "Nutzungstempo und Prognosen erscheinen nach der ersten Synchronisierung.", .french: "Le rythme d’utilisation et les prévisions apparaîtront après la première synchronisation.",
        .portuguese: "O ritmo de utilização e as previsões aparecem após a primeira sincronização.", .portugueseBrazil: "O ritmo de uso e as previsões aparecerão após a primeira sincronização."
    ],
    "Waiting for %@ quota": [
        .traditionalChinese: "等待 %@ 額度", .japanese: "%@ のクォータを待機中", .korean: "%@ 할당량 대기 중",
        .spanish: "Esperando la cuota de %@", .german: "Warten auf das %@-Kontingent", .french: "En attente du quota %@",
        .portuguese: "A aguardar a quota de %@", .portugueseBrazil: "Aguardando a cota de %@"
    ],
    "Waiting for first sync": [
        .traditionalChinese: "等待首次同步", .japanese: "最初の同期を待機中", .korean: "첫 동기화 대기 중",
        .spanish: "Esperando la primera sincronización", .german: "Warten auf die erste Synchronisierung", .french: "En attente de la première synchronisation",
        .portuguese: "A aguardar a primeira sincronização", .portugueseBrazil: "Aguardando a primeira sincronização"
    ],
    "Waiting for synced data": [
        .traditionalChinese: "等待同步資料", .japanese: "同期データを待機中", .korean: "동기화된 데이터 대기 중",
        .spanish: "Esperando datos sincronizados", .german: "Warten auf synchronisierte Daten", .french: "En attente des données synchronisées",
        .portuguese: "A aguardar dados sincronizados", .portugueseBrazil: "Aguardando dados sincronizados"
    ],
    "available in the tightest pool": [
        .traditionalChinese: "最吃緊額度池可用", .japanese: "最も厳しいプールで利用可能", .korean: "가장 여유가 적은 풀에서 사용 가능",
        .spanish: "disponible en el grupo más ajustado", .german: "im knappsten Pool verfügbar", .french: "disponible dans la réserve la plus limitée",
        .portuguese: "disponível no grupo mais limitado", .portugueseBrazil: "disponível no grupo mais restrito"
    ],
    "of %d days": [
        .traditionalChinese: "共 %d 天", .japanese: "%d日中", .korean: "총 %d일",
        .spanish: "de %d días", .german: "von %d Tagen", .french: "sur %d jours",
        .portuguese: "de %d dias", .portugueseBrazil: "de %d dias"
    ],
    "All": [
        .traditionalChinese: "全部",
        .japanese: "すべて",
        .korean: "전체",
        .spanish: "Todo",
        .german: "Alle",
        .french: "Tout",
        .portuguese: "Tudo",
        .portugueseBrazil: "Tudo"
    ],
    "Usage source": [
        .traditionalChinese: "用量來源",
        .japanese: "使用量の提供元",
        .korean: "사용량 출처",
        .spanish: "Fuente de uso",
        .german: "Verbrauchsquelle",
        .french: "Source d’utilisation",
        .portuguese: "Fonte de utilização",
        .portugueseBrazil: "Fonte de uso"
    ],
    "5 Hours": [
        .traditionalChinese: "5 小時",
        .japanese: "5時間",
        .korean: "5시간",
        .spanish: "5 horas",
        .german: "5 Stunden",
        .french: "5 heures",
        .portuguese: "5 horas",
        .portugueseBrazil: "5 horas"
    ],
    "7 Days": [
        .traditionalChinese: "7 天",
        .japanese: "7日間",
        .korean: "7일",
        .spanish: "7 días",
        .german: "7 Tage",
        .french: "7 jours",
        .portuguese: "7 dias",
        .portugueseBrazil: "7 dias"
    ],
    "Reading Claude quota...": [
        .traditionalChinese: "正在讀取 Claude 額度…",
        .japanese: "Claude のクォータを読み込み中…",
        .korean: "Claude 할당량을 읽는 중…",
        .spanish: "Leyendo la cuota de Claude...",
        .german: "Claude-Kontingent wird gelesen...",
        .french: "Lecture du quota Claude...",
        .portuguese: "A ler a quota do Claude...",
        .portugueseBrazil: "Lendo a cota do Claude..."
    ],
    "Claude quota is not available yet": [
        .traditionalChinese: "尚未讀取到 Claude 額度",
        .japanese: "Claude のクォータはまだ取得できません",
        .korean: "아직 Claude 할당량을 확인할 수 없습니다",
        .spanish: "La cuota de Claude aún no está disponible",
        .german: "Das Claude-Kontingent ist noch nicht verfügbar",
        .french: "Le quota Claude n’est pas encore disponible",
        .portuguese: "A quota do Claude ainda não está disponível",
        .portugueseBrazil: "A cota do Claude ainda não está disponível"
    ],
    "Window reset; waiting for update": [
        .traditionalChinese: "視窗已重設，等待更新",
        .japanese: "期間がリセットされました。更新を待機中",
        .korean: "기간이 초기화되어 업데이트를 기다리는 중",
        .spanish: "El periodo se restableció; esperando actualización",
        .german: "Zeitraum zurückgesetzt; Aktualisierung ausstehend",
        .french: "Période réinitialisée ; mise à jour en attente",
        .portuguese: "Período reposto; a aguardar atualização",
        .portugueseBrazil: "Período redefinido; aguardando atualização"
    ],
    "Resets %@": [
        .traditionalChinese: "%@重設",
        .japanese: "%@にリセット",
        .korean: "%@에 초기화",
        .spanish: "Se restablece %@",
        .german: "Wird %@ zurückgesetzt",
        .french: "Réinitialisation %@",
        .portuguese: "Repõe %@",
        .portugueseBrazil: "Redefine %@"
    ],
    "Claude Tracking": [
        .traditionalChinese: "Claude 追蹤",
        .japanese: "Claude トラッキング",
        .korean: "Claude 추적",
        .spanish: "Seguimiento de Claude",
        .german: "Claude-Tracking",
        .french: "Suivi Claude",
        .portuguese: "Monitorização do Claude",
        .portugueseBrazil: "Acompanhamento do Claude"
    ],
    "Claude Code Usage Tracking": [
        .traditionalChinese: "Claude Code 用量追蹤",
        .japanese: "Claude Code 使用量トラッキング",
        .korean: "Claude Code 사용량 추적",
        .spanish: "Seguimiento de uso de Claude Code",
        .german: "Claude-Code-Verbrauchserfassung",
        .french: "Suivi de l’utilisation de Claude Code",
        .portuguese: "Monitorização da utilização do Claude Code",
        .portugueseBrazil: "Acompanhamento do uso do Claude Code"
    ],
    "Enable Claude Code Tracking": [
        .traditionalChinese: "啟用 Claude Code 追蹤",
        .japanese: "Claude Code のトラッキングを有効にする",
        .korean: "Claude Code 추적 사용",
        .spanish: "Activar seguimiento de Claude Code",
        .german: "Claude-Code-Tracking aktivieren",
        .french: "Activer le suivi de Claude Code",
        .portuguese: "Ativar monitorização do Claude Code",
        .portugueseBrazil: "Ativar acompanhamento do Claude Code"
    ],
    "When enabled, QuotaLens reads local Claude history and updates quota. Disabling stops further reads and network access.": [
        .traditionalChinese: "啟用後會讀取本機 Claude 記錄並更新額度；關閉時不會繼續讀取或連線。",
        .japanese: "有効にするとローカルの Claude 履歴を読み取り、クォータを更新します。無効にすると読み取りと通信を停止します。",
        .korean: "활성화하면 로컬 Claude 기록을 읽고 할당량을 업데이트합니다. 비활성화하면 추가 읽기와 네트워크 연결을 중지합니다.",
        .spanish: "Al activarlo, QuotaLens lee el historial local de Claude y actualiza la cuota. Al desactivarlo, detiene las lecturas y el acceso a la red.",
        .german: "Wenn aktiviert, liest QuotaLens den lokalen Claude-Verlauf und aktualisiert das Kontingent. Beim Deaktivieren werden weitere Lese- und Netzwerkzugriffe beendet.",
        .french: "Une fois activé, QuotaLens lit l’historique Claude local et actualise le quota. La désactivation arrête les lectures et l’accès réseau.",
        .portuguese: "Quando ativado, o QuotaLens lê o histórico local do Claude e atualiza a quota. Ao desativar, interrompe novas leituras e o acesso à rede.",
        .portugueseBrazil: "Quando ativado, o QuotaLens lê o histórico local do Claude e atualiza a cota. Ao desativar, interrompe novas leituras e o acesso à rede."
    ],
    "Current Status": [
        .traditionalChinese: "目前狀態",
        .japanese: "現在の状態",
        .korean: "현재 상태",
        .spanish: "Estado actual",
        .german: "Aktueller Status",
        .french: "État actuel",
        .portuguese: "Estado atual",
        .portugueseBrazil: "Status atual"
    ],
    "Refresh Quota": [
        .traditionalChinese: "重新整理額度",
        .japanese: "クォータを更新",
        .korean: "할당량 새로고침",
        .spanish: "Actualizar cuota",
        .german: "Kontingent aktualisieren",
        .french: "Actualiser le quota",
        .portuguese: "Atualizar quota",
        .portugueseBrazil: "Atualizar cota"
    ],
    "Read Local History": [
        .traditionalChinese: "讀取本機記錄",
        .japanese: "ローカル履歴を読み取る",
        .korean: "로컬 기록 읽기",
        .spanish: "Leer historial local",
        .german: "Lokalen Verlauf lesen",
        .french: "Lire l’historique local",
        .portuguese: "Ler histórico local",
        .portugueseBrazil: "Ler histórico local"
    ],
    "Read All Again": [
        .traditionalChinese: "重新讀取全部",
        .japanese: "すべて再読み込み",
        .korean: "전체 다시 읽기",
        .spanish: "Volver a leer todo",
        .german: "Alles erneut lesen",
        .french: "Tout relire",
        .portuguese: "Ler tudo novamente",
        .portugueseBrazil: "Ler tudo novamente"
    ],
    "Last read: %@": [
        .traditionalChinese: "上次讀取：%@",
        .japanese: "最終読み取り：%@",
        .korean: "마지막 읽기: %@",
        .spanish: "Última lectura: %@",
        .german: "Zuletzt gelesen: %@",
        .french: "Dernière lecture : %@",
        .portuguese: "Última leitura: %@",
        .portugueseBrazil: "Última leitura: %@"
    ],
    "Menu Bar Reading": [
        .traditionalChinese: "選單列讀數",
        .japanese: "メニューバー表示",
        .korean: "메뉴 막대 표시",
        .spanish: "Lectura en la barra de menús",
        .german: "Anzeige in der Menüleiste",
        .french: "Lecture dans la barre des menus",
        .portuguese: "Leitura na barra de menus",
        .portugueseBrazil: "Leitura na barra de menus"
    ],
    "Show one or both sources; at least one remains selected.": [
        .traditionalChinese: "可以顯示一個或兩個來源；至少保留一個。",
        .japanese: "1つまたは両方の提供元を表示できます。少なくとも1つは選択されます。",
        .korean: "하나 또는 두 출처를 표시할 수 있으며 최소 하나는 선택되어야 합니다.",
        .spanish: "Muestra una o ambas fuentes; al menos una permanecerá seleccionada.",
        .german: "Eine oder beide Quellen anzeigen; mindestens eine bleibt ausgewählt.",
        .french: "Affichez une source ou les deux ; au moins une reste sélectionnée.",
        .portuguese: "Mostre uma ou ambas as fontes; pelo menos uma permanece selecionada.",
        .portugueseBrazil: "Mostre uma ou ambas as fontes; pelo menos uma permanece selecionada."
    ],
    "Refreshed sign-in data stays in QuotaLens private storage and never modifies Claude Code's sign-in files.": [
        .traditionalChinese: "重新整理後的登入資料只保存在 QuotaLens 私有儲存空間，不會修改 Claude Code 的登入檔案。",
        .japanese: "更新されたサインイン情報は QuotaLens の非公開領域にのみ保存され、Claude Code のサインインファイルは変更しません。",
        .korean: "새로 고친 로그인 정보는 QuotaLens 전용 저장소에만 보관되며 Claude Code 로그인 파일은 수정하지 않습니다.",
        .spanish: "Los datos de inicio de sesión actualizados se guardan en el almacenamiento privado de QuotaLens y nunca modifican los archivos de inicio de sesión de Claude Code.",
        .german: "Aktualisierte Anmeldedaten bleiben im privaten QuotaLens-Speicher und ändern niemals die Anmeldedateien von Claude Code.",
        .french: "Les données de connexion actualisées restent dans le stockage privé de QuotaLens et ne modifient jamais les fichiers de connexion de Claude Code.",
        .portuguese: "Os dados de início de sessão atualizados ficam no armazenamento privado do QuotaLens e nunca alteram os ficheiros de início de sessão do Claude Code.",
        .portugueseBrazil: "Os dados de login atualizados ficam no armazenamento privado do QuotaLens e nunca alteram os arquivos de login do Claude Code."
    ],
    "Off": [
        .traditionalChinese: "已關閉",
        .japanese: "オフ",
        .korean: "꺼짐",
        .spanish: "Desactivado",
        .german: "Aus",
        .french: "Désactivé",
        .portuguese: "Desativado",
        .portugueseBrazil: "Desativado"
    ],
    "Reading": [
        .traditionalChinese: "正在讀取",
        .japanese: "読み取り中",
        .korean: "읽는 중",
        .spanish: "Leyendo",
        .german: "Wird gelesen",
        .french: "Lecture en cours",
        .portuguese: "A ler",
        .portugueseBrazil: "Lendo"
    ],
    "Quota available": [
        .traditionalChinese: "額度可用",
        .japanese: "クォータ利用可能",
        .korean: "할당량 사용 가능",
        .spanish: "Cuota disponible",
        .german: "Kontingent verfügbar",
        .french: "Quota disponible",
        .portuguese: "Quota disponível",
        .portugueseBrazil: "Cota disponível"
    ],
    "Sign-in needed": [
        .traditionalChinese: "需要登入",
        .japanese: "サインインが必要",
        .korean: "로그인 필요",
        .spanish: "Inicio de sesión necesario",
        .german: "Anmeldung erforderlich",
        .french: "Connexion requise",
        .portuguese: "É necessário iniciar sessão",
        .portugueseBrazil: "Login necessário"
    ],
    "Sign in again": [
        .traditionalChinese: "重新登入",
        .japanese: "再度サインイン",
        .korean: "다시 로그인",
        .spanish: "Volver a iniciar sesión",
        .german: "Erneut anmelden",
        .french: "Se reconnecter",
        .portuguese: "Iniciar sessão novamente",
        .portugueseBrazil: "Entrar novamente"
    ],
    "Retrying later": [
        .traditionalChinese: "稍後自動重試",
        .japanese: "後で再試行",
        .korean: "나중에 다시 시도",
        .spanish: "Se reintentará más tarde",
        .german: "Späterer Neuversuch",
        .french: "Nouvelle tentative ultérieure",
        .portuguese: "Nova tentativa mais tarde",
        .portugueseBrazil: "Nova tentativa mais tarde"
    ],
    "Unavailable": [
        .traditionalChinese: "暫時無法使用",
        .japanese: "利用不可",
        .korean: "사용할 수 없음",
        .spanish: "No disponible",
        .german: "Nicht verfügbar",
        .french: "Indisponible",
        .portuguese: "Indisponível",
        .portugueseBrazil: "Indisponível"
    ],
    "Codex Account Activity": [
        .traditionalChinese: "Codex 帳戶活動",
        .japanese: "Codex アカウントアクティビティ",
        .korean: "Codex 계정 활동",
        .spanish: "Actividad de la cuenta Codex",
        .german: "Codex-Kontoaktivität",
        .french: "Activité du compte Codex",
        .portuguese: "Atividade da conta Codex",
        .portugueseBrazil: "Atividade da conta Codex"
    ],
    "Codex Cloud Activity": [
        .traditionalChinese: "Codex 雲端活動",
        .japanese: "Codex クラウドアクティビティ",
        .korean: "Codex 클라우드 활동",
        .spanish: "Actividad de Codex en la nube",
        .german: "Codex-Cloud-Aktivität",
        .french: "Activité cloud de Codex",
        .portuguese: "Atividade do Codex na nuvem",
        .portugueseBrazil: "Atividade do Codex na nuvem"
    ],
    "Local Activity": [
        .traditionalChinese: "本機活動",
        .japanese: "ローカルアクティビティ",
        .korean: "로컬 활동",
        .spanish: "Actividad local",
        .german: "Lokale Aktivität",
        .french: "Activité locale",
        .portuguese: "Atividade local",
        .portugueseBrazil: "Atividade local"
    ],
    "Other Model Quotas": [
        .traditionalChinese: "其他模型額度",
        .japanese: "その他のモデルクォータ",
        .korean: "기타 모델 할당량",
        .spanish: "Cuotas de otros modelos",
        .german: "Kontingente anderer Modelle",
        .french: "Quotas des autres modèles",
        .portuguese: "Quotas de outros modelos",
        .portugueseBrazil: "Cotas de outros modelos"
    ],
    "Account totals": [
        .traditionalChinese: "雲端彙總",
        .japanese: "アカウント集計",
        .korean: "계정 합계",
        .spanish: "Totales de la cuenta",
        .german: "Kontosummen",
        .french: "Totaux du compte",
        .portuguese: "Totais da conta",
        .portugueseBrazil: "Totais da conta"
    ],
    "Lifetime Tokens": [
        .traditionalChinese: "累計 Token",
        .japanese: "累計トークン",
        .korean: "누적 토큰",
        .spanish: "Tokens acumulados",
        .german: "Token gesamt",
        .french: "Tokens cumulés",
        .portuguese: "Tokens acumulados",
        .portugueseBrazil: "Tokens acumulados"
    ],
    "Peak Day": [
        .traditionalChinese: "峰值日",
        .japanese: "ピーク日",
        .korean: "최고 사용일",
        .spanish: "Día máximo",
        .german: "Spitzentag",
        .french: "Jour de pointe",
        .portuguese: "Dia de pico",
        .portugueseBrazil: "Dia de pico"
    ],
    "Longest Turn": [
        .traditionalChinese: "最長任務",
        .japanese: "最長タスク",
        .korean: "최장 작업",
        .spanish: "Tarea más larga",
        .german: "Längste Aufgabe",
        .french: "Tâche la plus longue",
        .portuguese: "Tarefa mais longa",
        .portugueseBrazil: "Tarefa mais longa"
    ],
    "Current Streak": [
        .traditionalChinese: "目前連續",
        .japanese: "現在の連続日数",
        .korean: "현재 연속 일수",
        .spanish: "Racha actual",
        .german: "Aktuelle Serie",
        .french: "Série actuelle",
        .portuguese: "Sequência atual",
        .portugueseBrazil: "Sequência atual"
    ],
    "Longest Streak": [
        .traditionalChinese: "最長連續",
        .japanese: "最長連続日数",
        .korean: "최장 연속 일수",
        .spanish: "Racha más larga",
        .german: "Längste Serie",
        .french: "Plus longue série",
        .portuguese: "Maior sequência",
        .portugueseBrazil: "Maior sequência"
    ],
    "%lld days": [
        .traditionalChinese: "%lld 天",
        .japanese: "%lld日",
        .korean: "%lld일",
        .spanish: "%lld días",
        .german: "%lld Tage",
        .french: "%lld jours",
        .portuguese: "%lld dias",
        .portugueseBrazil: "%lld dias"
    ],
    "%.1f hr": [
        .traditionalChinese: "%.1f 小時",
        .japanese: "%.1f時間",
        .korean: "%.1f시간",
        .spanish: "%.1f h",
        .german: "%.1f Std.",
        .french: "%.1f h",
        .portuguese: "%.1f h",
        .portugueseBrazil: "%.1f h"
    ],
    "%lld min": [
        .traditionalChinese: "%lld 分鐘",
        .japanese: "%lld分",
        .korean: "%lld분",
        .spanish: "%lld min",
        .german: "%lld Min.",
        .french: "%lld min",
        .portuguese: "%lld min",
        .portugueseBrazil: "%lld min"
    ],
    "Reading Claude local history...": [
        .traditionalChinese: "正在讀取 Claude 本機記錄…",
        .japanese: "Claude のローカル履歴を読み込み中…",
        .korean: "Claude 로컬 기록을 읽는 중…",
        .spanish: "Leyendo el historial local de Claude...",
        .german: "Lokaler Claude-Verlauf wird gelesen...",
        .french: "Lecture de l’historique Claude local...",
        .portuguese: "A ler o histórico local do Claude...",
        .portugueseBrazil: "Lendo o histórico local do Claude..."
    ],
    "Read %d Claude files and updated %d records": [
        .traditionalChinese: "已讀取 %d 個 Claude 檔案，更新 %d 筆記錄",
        .japanese: "%d 件の Claude ファイルを読み取り、%d 件の記録を更新しました",
        .korean: "Claude 파일 %d개를 읽고 기록 %d개를 업데이트했습니다",
        .spanish: "Se leyeron %d archivos de Claude y se actualizaron %d registros",
        .german: "%d Claude-Dateien gelesen und %d Einträge aktualisiert",
        .french: "%d fichiers Claude lus et %d enregistrements mis à jour",
        .portuguese: "%d ficheiros do Claude lidos e %d registos atualizados",
        .portugueseBrazil: "%d arquivos do Claude lidos e %d registros atualizados"
    ],
    "Claude local history was partially updated": [
        .traditionalChinese: "Claude 本機記錄已部分更新",
        .japanese: "Claude のローカル履歴を一部更新しました",
        .korean: "Claude 로컬 기록이 일부 업데이트되었습니다",
        .spanish: "El historial local de Claude se actualizó parcialmente",
        .german: "Der lokale Claude-Verlauf wurde teilweise aktualisiert",
        .french: "L’historique Claude local a été partiellement mis à jour",
        .portuguese: "O histórico local do Claude foi parcialmente atualizado",
        .portugueseBrazil: "O histórico local do Claude foi parcialmente atualizado"
    ],
    "Some Claude records could not be read.": [
        .traditionalChinese: "部分 Claude 記錄暫時無法讀取。",
        .japanese: "一部の Claude 記録を読み取れませんでした。",
        .korean: "일부 Claude 기록을 읽을 수 없습니다.",
        .spanish: "No se pudieron leer algunos registros de Claude.",
        .german: "Einige Claude-Einträge konnten nicht gelesen werden.",
        .french: "Certains enregistrements Claude n’ont pas pu être lus.",
        .portuguese: "Não foi possível ler alguns registos do Claude.",
        .portugueseBrazil: "Não foi possível ler alguns registros do Claude."
    ],
    "Claude local history update failed": [
        .traditionalChinese: "Claude 本機記錄更新失敗",
        .japanese: "Claude のローカル履歴を更新できませんでした",
        .korean: "Claude 로컬 기록 업데이트 실패",
        .spanish: "No se pudo actualizar el historial local de Claude",
        .german: "Aktualisierung des lokalen Claude-Verlaufs fehlgeschlagen",
        .french: "Échec de la mise à jour de l’historique Claude local",
        .portuguese: "Falha ao atualizar o histórico local do Claude",
        .portugueseBrazil: "Falha ao atualizar o histórico local do Claude"
    ],
    "Claude local history could not be read. Try again later.": [
        .traditionalChinese: "暫時無法讀取 Claude 本機記錄，請稍後再試。",
        .japanese: "Claude のローカル履歴を読み取れませんでした。後でもう一度お試しください。",
        .korean: "Claude 로컬 기록을 읽을 수 없습니다. 나중에 다시 시도하세요.",
        .spanish: "No se pudo leer el historial local de Claude. Inténtalo de nuevo más tarde.",
        .german: "Der lokale Claude-Verlauf konnte nicht gelesen werden. Versuche es später erneut.",
        .french: "Impossible de lire l’historique Claude local. Réessayez plus tard.",
        .portuguese: "Não foi possível ler o histórico local do Claude. Tente novamente mais tarde.",
        .portugueseBrazil: "Não foi possível ler o histórico local do Claude. Tente novamente mais tarde."
    ],
    "Sign in to Claude Code first.": [
        .traditionalChinese: "請先在 Claude Code 中登入。",
        .japanese: "先に Claude Code へサインインしてください。",
        .korean: "먼저 Claude Code에 로그인하세요.",
        .spanish: "Primero inicia sesión en Claude Code.",
        .german: "Melde dich zuerst bei Claude Code an.",
        .french: "Connectez-vous d’abord à Claude Code.",
        .portuguese: "Inicie primeiro sessão no Claude Code.",
        .portugueseBrazil: "Entre primeiro no Claude Code."
    ],
    "Your Claude sign-in has expired. Sign in again.": [
        .traditionalChinese: "Claude 登入已失效，請重新登入。",
        .japanese: "Claude のサインイン情報が期限切れです。再度サインインしてください。",
        .korean: "Claude 로그인이 만료되었습니다. 다시 로그인하세요.",
        .spanish: "Tu inicio de sesión de Claude ha caducado. Inicia sesión de nuevo.",
        .german: "Deine Claude-Anmeldung ist abgelaufen. Melde dich erneut an.",
        .french: "Votre connexion Claude a expiré. Reconnectez-vous.",
        .portuguese: "A sessão do Claude expirou. Inicie sessão novamente.",
        .portugueseBrazil: "Seu login do Claude expirou. Entre novamente."
    ],
    "Claude refresh is temporarily delayed and will retry automatically.": [
        .traditionalChinese: "Claude 重新整理暫時延遲，稍後會自動重試。",
        .japanese: "Claude の更新は一時的に遅延しています。後で自動的に再試行します。",
        .korean: "Claude 새로고침이 일시적으로 지연되었으며 자동으로 다시 시도합니다.",
        .spanish: "La actualización de Claude se ha retrasado temporalmente y se reintentará automáticamente.",
        .german: "Die Claude-Aktualisierung ist vorübergehend verzögert und wird automatisch erneut versucht.",
        .french: "L’actualisation de Claude est temporairement retardée et sera réessayée automatiquement.",
        .portuguese: "A atualização do Claude está temporariamente atrasada e será repetida automaticamente.",
        .portugueseBrazil: "A atualização do Claude está temporariamente atrasada e será repetida automaticamente."
    ],
    "Claude quota could not be updated right now.": [
        .traditionalChinese: "目前無法更新 Claude 額度。",
        .japanese: "現在 Claude のクォータを更新できません。",
        .korean: "현재 Claude 할당량을 업데이트할 수 없습니다.",
        .spanish: "No se pudo actualizar la cuota de Claude en este momento.",
        .german: "Das Claude-Kontingent konnte gerade nicht aktualisiert werden.",
        .french: "Impossible d’actualiser le quota Claude pour le moment.",
        .portuguese: "Não foi possível atualizar agora a quota do Claude.",
        .portugueseBrazil: "Não foi possível atualizar a cota do Claude agora."
    ],
    "codex was not found in the login shell PATH.": [
        .traditionalChinese: "在登入 Shell 的 PATH 中找不到 codex。",
        .japanese: "ログインシェルの PATH に codex が見つかりません。",
        .korean: "로그인 셸 PATH에서 codex를 찾을 수 없습니다.",
        .spanish: "No se encontró codex en el PATH del shell de inicio de sesión.",
        .german: "codex wurde im PATH der Login-Shell nicht gefunden.",
        .french: "codex est introuvable dans le PATH du shell de connexion.",
        .portuguese: "O codex não foi encontrado no PATH da shell de início de sessão.",
        .portugueseBrazil: "O codex não foi encontrado no PATH do shell de login."
    ],
    "Login shell inspection timed out.": [
        .traditionalChinese: "登入 Shell 檢查逾時。",
        .japanese: "ログインシェルの確認がタイムアウトしました。",
        .korean: "로그인 셸 확인 시간이 초과되었습니다.",
        .spanish: "Se agotó el tiempo al comprobar el shell de inicio de sesión.",
        .german: "Zeitüberschreitung bei der Prüfung der Login-Shell.",
        .french: "La vérification du shell de connexion a expiré.",
        .portuguese: "A verificação da shell de início de sessão excedeu o tempo limite.",
        .portugueseBrazil: "A verificação do shell de login excedeu o tempo limite."
    ],
    "Unable to inspect the login shell PATH: %@": [
        .traditionalChinese: "無法檢查登入 Shell 的 PATH：%@",
        .japanese: "ログインシェルの PATH を確認できません：%@",
        .korean: "로그인 셸 PATH를 확인할 수 없습니다: %@",
        .spanish: "No se pudo comprobar el PATH del shell de inicio de sesión: %@",
        .german: "Der PATH der Login-Shell konnte nicht geprüft werden: %@",
        .french: "Impossible de vérifier le PATH du shell de connexion : %@",
        .portuguese: "Não foi possível verificar o PATH da shell de início de sessão: %@",
        .portugueseBrazil: "Não foi possível verificar o PATH do shell de login: %@"
    ],
    "Introduced weekly quota full recovery (100%) notification bubbles with cross-tool status alerts and quick interactions": [
        .traditionalChinese: "新增週度配額完全恢復（100%）智慧氣泡提醒，支援多工具額度滿血通知與一鍵快捷互動",
        .japanese: "週間クォータ完全回復（100%）のインテリジェントな通知バブルを追加し、マルチツールのクォータ満杯通知とワンクリック操作に対応",
        .korean: "주간 할당량 100% 완전 복구 스마트 알림 버블 추가: 멀티 툴 할당량 회복 알림 및 원클릭 간편 상호작용 지원",
        .spanish: "Burbujas de notificación inteligentes de recuperación total (100%) de cuota semanal con avisos multiherramienta e interacción rápida",
        .german: "Intelligente Benachrichtigungsblasen für vollständige Wiederherstellung (100%) des wöchentlichen Kontingents mit Schnellaktionen eingeführt",
        .french: "Bulles de notification intelligentes de rétablissement complet (100%) du quota hebdomadaire avec alertes multi-outils et interactions rapides",
        .portuguese: "Balões de notificação inteligentes de reposição total (100%) da quota semanal com alertas multiferramenta e interações rápidas",
        .portugueseBrazil: "Balões de notificação inteligentes de restauração total (100%) da cota semanal com alertas multiferramenta e interações rápidas"
    ],
    "Optimized menu bar status item indicators and ring layout with intuitive toggling between used and available quota perspectives": [
        .traditionalChinese: "優化選單列狀態圖示與指示環排版，支援在狀態列直觀切換已用與可用額度視角",
        .japanese: "メニューバーステータスアイコンとインジケーター配置を改善し、使用済み／利用可能クォータの視点を直感的に切り替え可能に",
        .korean: "메뉴 바 상태 아이콘 및 인디케이터 링 레이아웃을 개선하여 사용량 및 잔여량 보기를 직관적으로 전환 지원",
        .spanish: "Optimizados los indicadores de la barra de menús y el diseño de anillos con cambio intuitivo entre cuota usada y disponible",
        .german: "Menüleisten-Statusanzeigen und Ring-Layout optimiert mit intuitivem Umschalten zwischen verbrauchtem und verfügbarem Kontingent",
        .french: "Optimisation des indicateurs et de la disposition en anneau de la barre de menus avec basculement intuitif entre quota utilisé et disponible",
        .portuguese: "Otimizados os indicadores e disposição em anel da barra de menus com alternância intuitiva entre quota utilizada e disponível",
        .portugueseBrazil: "Otimizados os indicadores e disposição em anel da barra de menus com alternância intuitiva entre cota usada e disponível"
    ],
    "Deeply refined floating overlay snapping smoothness and foreground window awareness across Antigravity and Codex": [
        .traditionalChinese: "深度優化 Antigravity 與 Codex 全息懸浮掛件的吸附平滑度與視窗前台感知鏈路",
        .japanese: "Antigravity および Codex のフローティングウィジェットにおける吸着のスムーズさと前面ウインドウ認識パイプラインを大幅に向上",
        .korean: "Antigravity 및 Codex 플로팅 위젯의 부착 부드러움과 전면 창 감지 파이프라인 심층 개선",
        .spanish: "Suavidad de anclaje de la superposición flotante y detección de ventana en primer plano profundamente refinadas para Antigravity y Codex",
        .german: "Andock-Reibungslosigkeit und Vordergrund-Fenstererkennung der schwebenden Overlays für Antigravity und Codex tiefgreifend verbessert",
        .french: "Fluidité d'aimantation de la superposition flottante et détection de fenêtre au premier plan profondément améliorées pour Antigravity et Codex",
        .portuguese: "Suavidade de fixação da sobreposição flutuante e deteção de janela em primeiro plano profundamente aperfeiçoadas para Antigravity e Codex",
        .portugueseBrazil: "Suavidade de fixação da sobreposição flutuante e detecção de janela em primeiro plano profundamente aprimoradas para Antigravity e Codex"
    ],
    "Antigravity · 5-hour quota is not available": [
        .traditionalChinese: "Antigravity · 5 小時額度暫無資料",
        .japanese: "Antigravity · 5 時間クォータのデータがありません",
        .korean: "Antigravity · 5시간 할당량 데이터 없음",
        .spanish: "Antigravity · Cuota de 5 horas no disponible",
        .german: "Antigravity · 5-Stunden-Kontingent nicht verfügbar",
        .french: "Antigravity · Quota de 5 heures non disponible",
        .portuguese: "Antigravity · Quota de 5 horas indisponível",
        .portugueseBrazil: "Antigravity · Cota de 5 horas indisponível"
    ],
    "Antigravity 5-hour quota is not available": [
        .traditionalChinese: "Antigravity 5 小時額度暫無資料",
        .japanese: "Antigravity 5 時間クォータのデータがありません",
        .korean: "Antigravity 5시간 할당량 데이터 없음",
        .spanish: "Cuota de 5 horas de Antigravity no disponible",
        .german: "Antigravity 5-Stunden-Kontingent nicht verfügbar",
        .french: "Quota de 5 heures Antigravity non disponible",
        .portuguese: "Quota de 5 horas do Antigravity indisponível",
        .portugueseBrazil: "Cota de 5 horas do Antigravity indisponível"
    ],
    "Click to switch between used and available": [
        .traditionalChinese: "點擊切換已用與可用視角",
        .japanese: "クリックして使用済み／利用可能の表示を切り替え",
        .korean: "클릭하여 사용량/잔여량 보기 전환",
        .spanish: "Haz clic para alternar entre usado y disponible",
        .german: "Klicken zum Umschalten zwischen verbraucht und verfügbar",
        .french: "Cliquer pour basculer entre utilisé et disponible",
        .portuguese: "Clique para alternar entre utilizado e disponível",
        .portugueseBrazil: "Clique para alternar entre usado e disponível"
    ],
    "Click to close": [
        .traditionalChinese: "點擊關閉",
        .japanese: "クリックして閉じる",
        .korean: "클릭하여 닫기",
        .spanish: "Clic para cerrar",
        .german: "Klicken zum Schließen",
        .french: "Cliquer pour fermer",
        .portuguese: "Clique para fechar",
        .portugueseBrazil: "Clique para fechar"
    ],
    "Click to close all reminders": [
        .traditionalChinese: "點擊關閉全部提醒",
        .japanese: "クリックしてすべてのリマインダーを閉じる",
        .korean: "클릭하여 모든 알림 닫기",
        .spanish: "Clic para cerrar todos los recordatorios",
        .german: "Klicken, um alle Erinnerungen zu schließen",
        .french: "Cliquer pour fermer tous les rappels",
        .portuguese: "Clique para fechar todos os lembretes",
        .portugueseBrazil: "Clique para fechar todos os lembretes"
    ],
    "Click to close all weekly quota recovery reminders": [
        .traditionalChinese: "點擊關閉全部週額度恢復提醒",
        .japanese: "クリックして週間クォータ回復リマインダーをすべて閉じる",
        .korean: "클릭하여 모든 주간 할당량 복구 알림 닫기",
        .spanish: "Clic para cerrar todos los recordatorios de recuperación de cuota semanal",
        .german: "Klicken, um alle wöchentlichen Kontingent-Wiederherstellungserinnerungen zu schließen",
        .french: "Cliquer pour fermer tous les rappels de récupération de quota hebdomadaire",
        .portuguese: "Clique para fechar todos os lembretes de recuperação de quota semanal",
        .portugueseBrazil: "Clique para fechar todos os lembretes de recuperação de cota semanal"
    ],
    "Weekly quota restored to 100%": [
        .traditionalChinese: "週額度已恢復 100%",
        .japanese: "週間クォータが 100% 回復しました",
        .korean: "주간 할당량이 100% 복구되었습니다",
        .spanish: "Cuota semanal restaurada al 100%",
        .german: "Wöchentliches Kontingent wieder auf 100% hergestellt",
        .french: "Quota hebdomadaire rétabli à 100%",
        .portuguese: "Quota semanal reposta a 100%",
        .portugueseBrazil: "Cota semanal restaurada para 100%"
    ],
    "Weekly Quota Recovery Reminder": [
        .traditionalChinese: "週額度恢復提醒",
        .japanese: "週間クォータ回復リマインダー",
        .korean: "주간 할당량 복구 알림",
        .spanish: "Recordatorio de recuperación de cuota semanal",
        .german: "Erinnerung an wöchentliche Kontingent-Wiederherstellung",
        .french: "Rappel de récupération de quota hebdomadaire",
        .portuguese: "Lembrete de recuperação de quota semanal",
        .portugueseBrazil: "Lembrete de recuperação de cota semanal"
    ],
    "Weekly quota recovery reminder": [
        .traditionalChinese: "週額度恢復提醒",
        .japanese: "週間クォータ回復リマインダー",
        .korean: "주간 할당량 복구 알림",
        .spanish: "Recordatorio de recuperación de cuota semanal",
        .german: "Erinnerung an wöchentliche Kontingent-Wiederherstellung",
        .french: "Rappel de récupération de quota hebdomadaire",
        .portuguese: "Lembrete de recuperação de quota semanal",
        .portugueseBrazil: "Lembrete de recuperação de cota semanal"
    ],
    "Pop up a subtle recovery bubble when a tool reaches 100% weekly quota": [
        .traditionalChinese: "當工具週額度恢復至 100% 時快顯輕量提醒氣泡",
        .japanese: "ツールの週間クォータが 100% に回復した際に通知バブルを表示",
        .korean: "도구 주간 할당량이 100%로 복구될 때 가벼운 알림 버블 표시",
        .spanish: "Muestra una sutil burbuja de aviso cuando una herramienta recupera el 100% de la cuota semanal",
        .german: "Zeigt eine dezente Benachrichtigungsblase an, wenn ein Tool 100% des wöchentlichen Kontingents wiederherstellt",
        .french: "Affiche une bulle de notification subtile lorsqu'un outil récupère 100% de son quota hebdomadaire",
        .portuguese: "Mostra um balão discreto quando uma ferramenta recupera 100% da quota semanal",
        .portugueseBrazil: "Mostra um balão discreto quando uma ferramenta recupera 100% da cota semanal"
    ],
    "%d more": [
        .traditionalChinese: "還有 %d 項",
        .japanese: "他 %d 件",
        .korean: "%d개 더 보기",
        .spanish: "%d más",
        .german: "%d weitere",
        .french: "%d de plus",
        .portuguese: "Mais %d",
        .portugueseBrazil: "Mais %d"
    ],
    "Full integration with Google Antigravity (AGY) agentic ecosystem with multi-window quota and local activity monitoring": [
        .traditionalChinese: "全面接入 Google Antigravity (AGY) 智慧體編程工具生態，支援多週期模型配額與本機活躍度監控",
        .japanese: "Google Antigravity (AGY) エージェント開発ツールに対応し、マルチウィンドウモデルクォータおよびローカル活動状況の監視を統合",
        .korean: "Google Antigravity (AGY) 에이전트 개발 도구 생태계 완전 통합: 다중 윈도우 모델 할당량 및 로컬 활동 모니터링 지원",
        .spanish: "Integración completa con el ecosistema Google Antigravity (AGY) con monitoreo de cuotas por ventana y actividad local",
        .german: "Vollständige Integration in das Google Antigravity (AGY)-Ökosystem mit Multi-Fenster-Kontingent- und lokaler Aktivitätsüberwachung",
        .french: "Intégration complète de l'écosystème Google Antigravity (AGY) avec suivi des quotas multi-fenêtres et de l'activité locale",
        .portuguese: "Integração completa com o ecossistema Google Antigravity (AGY) com monitorização de quotas multi-janela e atividade local",
        .portugueseBrazil: "Integração completa com o ecossistema Google Antigravity (AGY) com monitoramento de cotas multi-janela e atividade local"
    ],
    "Dedicated Antigravity floating overlay with smart window snapping, foreground auto-wake, and real-time model quota breakdown": [
        .traditionalChinese: "新增 Antigravity 專屬全息懸浮掛件與自動吸附定位，支援隨前台應用智慧喚醒與模型餘量一覽",
        .japanese: "Antigravity 専用フローティングウィジェットと自動吸着機能を追加し、前面アプリ連動の自動起動とモデル残量一覧に対応",
        .korean: "Antigravity 전용 플로팅 위젯 및 자동 부착 위치 지정 추가: 전면 앱 스마트 연동 및 모델 잔여량 한눈에 확인",
        .spanish: "Superposición flotante dedicada para Antigravity con anclaje inteligente, activación automática en primer plano y desglose de cuotas",
        .german: "Dediziertes Antigravity-Schwebemenü mit intelligentem Andocken, Vordergrund-Auto-Aktivierung und Modellkontingent-Übersicht",
        .french: "Superposition flottante dédiée à Antigravity avec aimantation intelligente, réveil automatique au premier plan et solde de quotas",
        .portuguese: "Sobreposição flutuante dedicada para Antigravity com fixação inteligente, ativação em primeiro plano e detalhe de quotas",
        .portugueseBrazil: "Sobreposição flutuante dedicada para Antigravity com fixação inteligente, ativação em primeiro plano e detalhamento de cotas"
    ],
    "Deeply integrated Antigravity metric cards, task trends, and multi-workspace switching across menu bar, overview, and settings": [
        .traditionalChinese: "在選單列、總覽看板與設定中深度整合 Antigravity 指標卡片、任務趨勢與多空間無縫切換",
        .japanese: "メニューバー、概要ダッシュボード、設定画面において Antigravity の指標カード、タスク推移、複数ワークスペース切替を統合",
        .korean: "메뉴 바, 개요 대시보드 및 설정 전반에 걸쳐 Antigravity 지표 카드, 작업 추세 및 다중 워크스페이스 원활한 전환 통합",
        .spanish: "Tarjetas de métricas de Antigravity, tendencias de tareas y cambio de espacio de trabajo integrados en la barra de menús, resumen y ajustes",
        .german: "Tief integrierte Antigravity-Metrikkarten, Aufgabentrends und Workspace-Wechsel in Menüleiste, Übersicht und Einstellungen",
        .french: "Intégration approfondie des cartes de métriques Antigravity, des tendances de tâches et du basculement d'espace de travail",
        .portuguese: "Cartões de métricas Antigravity, tendências de tarefas e alternância de áreas de trabalho integrados na barra de menus, visão geral e definições",
        .portugueseBrazil: "Cartões de métricas Antigravity, tendências de tarefas e alternância de áreas de trabalho integrados na barra de menus, visão geral e ajustes"
    ],
    "Introduced Claude (Claude Code / Cursor) multi-tool usage monitoring with OAuth authorization and multi-cycle quota polling": [
        .traditionalChinese: "引入 Claude (Claude Code / Cursor) 多工具生態用量監控體系，支援 OAuth 授權與多週期配額輪詢",
        .japanese: "Claude (Claude Code / Cursor) マルチツール利用量監視システムを導入し、OAuth 認証と複数周期のクォータ自動取得に対応",
        .korean: "Claude (Claude Code / Cursor) 멀티 툴 사용량 모니터링 시스템 도입: OAuth 인증 및 다중 주기 할당량 폴링 지원",
        .spanish: "Introducido el sistema de monitoreo de uso multirremienta para Claude (Claude Code / Cursor) con autorización OAuth y sondeo de cuotas",
        .german: "Multi-Tool-Nutzungsüberwachung für Claude (Claude Code / Cursor) mit OAuth-Autorisierung und Multi-Zyklus-Kontingentabfrage eingeführt",
        .french: "Introduction du système de suivi de l'utilisation multi-outils pour Claude (Claude Code / Cursor) avec autorisation OAuth et interrogation des quotas",
        .portuguese: "Introduzido sistema de monitorização de utilização multiferramenta para Claude (Claude Code / Cursor) com autorização OAuth e consulta de quotas",
        .portugueseBrazil: "Introduzido sistema de monitoramento de uso multiferramenta para Claude (Claude Code / Cursor) com autorização OAuth e consulta de cotas"
    ],
    "Upgraded unified Overview dashboard and multi-tool navigation hub for seamless cross-tool quota overview and smart linkage": [
        .traditionalChinese: "全新升級統一「總覽」看板與多工具導覽中心，支援 Codex 與 Claude 跨工具配額一覽與智慧聯動",
        .japanese: "統合「概要」ダッシュボードとマルチツールナビゲーションハブを刷新し、Codex と Claude のクォータ一覧表示と連携に対応",
        .korean: "통합 「개요」 대시보드 및 멀티 툴 내비게이션 허브 업그레이드: Codex와 Claude의 도구 간 할당량 일괄 확인 및 스마트 연동 지원",
        .spanish: "Panel de descripción general unificado y centro de navegación multirremienta mejorados para vista general de cuotas y vinculación inteligente",
        .german: "Verbessertes einheitliches Übersichts-Dashboard und Multi-Tool-Navigationszentrum für nahtlose toolübergreifende Kontingentübersicht und Verknüpfung",
        .french: "Tableau de bord de vue d'ensemble unifié et hub de navigation multi-outils améliorés pour une vue d'ensemble des quotas et une liaison intelligente",
        .portuguese: "Painel de visão geral unificado e centro de navegação multiferramenta melhorados para visão geral de quotas e ligação inteligente",
        .portugueseBrazil: "Painel de visão geral unificado e central de navegação multiferramenta aprimorados para visão geral de cotas e vinculação inteligente"
    ],
    "Restructured floating overlay multi-tool coordinator to intelligently auto-switch display perspectives based on the active foreground tool": [
        .traditionalChinese: "重構全息懸浮掛件多工具協同調度器，支援根據當前前台活躍的 AI 編程工具智慧自動切換展示視角",
        .japanese: "フローティングウィジェットのマルチツール協調スケジューラを再構築し、前面でアクティブな AI ツールに応じて表示視点を自動切替",
        .korean: "플로팅 위젯 멀티 툴 협동 스케줄러를 재구성하여 전면에서 활성화된 AI 개발 도구에 따라 표시 관점을 스마트하게 자동 전환",
        .spanish: "Reestructurado el coordinador multirremienta de la superposición flotante para cambiar automáticamente según la herramienta activa en primer plano",
        .german: "Multi-Tool-Koordinator des schwebenden Overlays umstrukturiert für automatischen Wechsel der Ansicht basierend auf dem aktiven Vordergrund-Tool",
        .french: "Restructuration du coordinateur multi-outils de superposition flottante pour basculer automatiquement selon l'outil actif au premier plan",
        .portuguese: "Reestruturado o coordenador multiferramenta da sobreposição flutuante para alternar automaticamente com base na ferramenta ativa em primeiro plano",
        .portugueseBrazil: "Reestruturado o coordenador multiferramenta da sobreposição flutuante para alternar automaticamente com base na ferramenta ativa em primeiro plano"
    ],
    "Architectural refactor of Codex overlay positioning and snapping engine, decoupling accessibility anchor detection and geometry calculation": [
        .traditionalChinese: "架構級重構 Codex 懸浮掛件定位與吸附感知引擎，模組化解耦輔助功能錨點讀取與座標計算",
        .japanese: "Codex フローティングウィジェットの位置決め＆吸着認識エンジンをアーキテクチャ刷新し、アクセシビリティアンカー検出と座標計算をモジュール分離",
        .korean: "Codex 플로팅 위젯 위치 지정 및 부착 감지 엔진을 아키텍처 수준에서 리팩터링하여 접근성 앵커 감지 및 좌표 계산을 모듈화 분리",
        .spanish: "Refactorización arquitectónica del motor de posicionamiento y anclaje de la superposición de Codex, desacoplando detección de anclajes y cálculo geométrico",
        .german: "Architektur-Refactoring der Positionierungs- und Andock-Engine des Codex-Overlays durch Entkopplung von Accessibility-Ankererkennung und Geometrieberechnung",
        .french: "Refonte architecturale du moteur de positionnement et d'aimantation de la superposition Codex, découplant la détection des ancres et le calcul géométrique",
        .portuguese: "Refatoração arquitetural do motor de posicionamento e fixação da sobreposição do Codex, desacoplando a deteção de âncoras e o cálculo geométrico",
        .portugueseBrazil: "Refatoração arquitetural do motor de posicionamento e fixação da sobreposição do Codex, desacoplando a detecção de âncoras e o cálculo geométrico"
    ],
    "Upgraded precision anchoring: directly targets Codex window and Help button anchors without reading any conversation text for total privacy": [
        .traditionalChinese: "升級精準錨定演算法：直接定位 Codex 視窗與其內部 Help 按鈕錨點，完全無需讀取任何對話正文，徹底保障使用者隱私",
        .japanese: "高精度アンカー検出アルゴリズムを刷新：会話本文を一切読み取ることなく、Codex ウインドウと内部の Help ボタンを直接特定し完全なプライバシーを保護",
        .korean: "정밀 앵커링 알고리즘 업그레이드: 대화 내용을 일체 읽지 않고 Codex 창과 내부 Help 버튼 앵커를 직접 타겟팅하여 완벽한 개인정보 보호 실현",
        .spanish: "Algoritmo de anclaje de precisión mejorado: localiza la ventana de Codex y el botón de ayuda sin leer texto de conversación para total privacidad",
        .german: "Präzisions-Verankerungsalgorithmus aktualisiert: zielt direkt auf das Codex-Fenster und die Hilfe-Schaltfläche ab, ohne Konversationstexte zu lesen, für vollständigen Datenschutz",
        .french: "Mise à niveau de l'algorithme d'ancrage de précision : cible directement la fenêtre Codex et le bouton d'aide sans lire le texte des conversations pour une confidentialité totale",
        .portuguese: "Algoritmo de ancoragem de precisão melhorado: localiza a janela do Codex e o botão de ajuda sem ler texto de conversas para total privacidade",
        .portugueseBrazil: "Algoritmo de ancoragem de precisão aprimorado: localiza a janela do Codex e o botão de ajuda sem ler texto de conversas para total privacidade"
    ],
    "Refined overlay snapping and reset interactions with one-click restoration to the intelligent default position inside the Codex window": [
        .traditionalChinese: "優化懸浮掛件吸附與重設互動，支援一鍵恢復掛件在 Codex 視窗內的智慧預設吸附位置",
        .japanese: "フローティングウィジェットの吸着とリセット操作を改善し、Codex ウインドウ内のインテリジェントな初期吸着位置へワンクリック復帰に対応",
        .korean: "플로팅 위젯 부착 및 초기화 상호작용을 개선하여 Codex 창 내부의 스마트 기본 부착 위치로 원클릭 복원 지원",
        .spanish: "Interacciones de anclaje y restablecimiento refinadas con restauración en un clic a la posición predeterminada inteligente dentro de la ventana de Codex",
        .german: "Andock- und Zurücksetz-Interaktionen verfeinert mit Ein-Klick-Wiederherstellung der intelligenten Standardposition im Codex-Fenster",
        .french: "Interactions d'aimantation et de réinitialisation affinées avec restauration en un clic vers la position par défaut intelligente dans la fenêtre Codex",
        .portuguese: "Interações de fixação e reposição aperfeiçoadas com restauro num clique para a posição predefinida inteligente dentro da janela do Codex",
        .portugueseBrazil: "Interações de fixação e redefinição aprimoradas com restauração em um clique para a posição padrão inteligente dentro da janela do Codex"
    ],
    "Introduced on-demand Codex conversation parsing and message history viewer in session details for user prompts and assistant replies": [
        .traditionalChinese: "新增 Codex 會話正文按需解析與對話記錄回放，支援在會話詳情中直接瀏覽使用者提示詞與助理完整回覆",
        .japanese: "Codex 会話本文のオンデマンド解析と履歴閲覧機能を追加し、セッション詳細画面でユーザーの指示とアシスタントの返答を直接確認可能に",
        .korean: "Codex 세션 본문 온디맨드 파싱 및 대화 기록 뷰어 기능 추가: 세션 세부 정보에서 사용자 프롬프트와 어시스턴트 응답을 직접 확인 가능",
        .spanish: "Añadido análisis bajo demanda de conversaciones de Codex y visor de historial en el detalle de la sesión para ver prompts y respuestas",
        .german: "On-Demand-Analyse von Codex-Konversationen und Nachrichtenverlaufsanzeige in den Sitzungsdetails für Benutzer-Prompts und Assistenten-Antworten hinzugefügt",
        .french: "Ajout de l'analyse à la demande des conversations Codex et de la visualisation de l'historique dans les détails de session",
        .portuguese: "Adicionada análise a pedido de conversas do Codex e visualizador de histórico nos detalhes da sessão para mensagens do utilizador e do assistente",
        .portugueseBrazil: "Adicionada análise sob demanda de conversas do Codex e visualizador de histórico nos detalhes da sessão para mensagens do usuário e do assistente"
    ],
    "Full-text hybrid search across session titles and conversation bodies with instant filtering and project context matching": [
        .traditionalChinese: "支援會話標題與對話正文全文混合檢索，秒級過濾歷史對話內容並自動匹配相關工程上下文",
        .japanese: "セッションタイトルと会話本文のハイブリッド全文検索に対応し、過去の対話内容を瞬時に絞り込みプロジェクト文脈と自動照合",
        .korean: "세션 제목 및 대화 본문 통합 전체 텍스트 검색 지원으로 과거 대화 내용을 즉시 필터링하고 프로젝트 컨텍스트와 자동 매칭",
        .spanish: "Búsqueda híbrida de texto completo en títulos y cuerpo de conversaciones con filtrado instantáneo y coincidencia de contexto",
        .german: "Volltext-Hybridsuche über Sitzungstitel und Konversationstexte mit sofortiger Filterung und Projektkontext-Zuordnung",
        .french: "Recherche hybride en texte intégral sur les titres et le corps des conversations avec filtrage instantané et contexte de projet",
        .portuguese: "Pesquisa híbrida de texto integral em títulos e corpo de conversas com filtragem instantânea e correspondência de contexto",
        .portugueseBrazil: "Pesquisa híbrida de texto completo em títulos e corpo de conversas com filtragem instantânea e correspondência de contexto"
    ],
    "Refined session detail layout with seamless switching between Conversation and Usage tabs along with attachment badges": [
        .traditionalChinese: "優化會話明細卡片排版，支援「對話內容」與「用量統計」無縫分欄切換與附件標記識別",
        .japanese: "セッション詳細レイアウトを改善し、「会話内容」と「使用量統計」のスムーズなタブ切替および添付ファイル表示に対応",
        .korean: "세션 세부 정보 레이아웃을 개선하여 「대화 내용」과 「사용량 통계」 간의 부드러운 탭 전환 및 첨부파일 배지 표시 지원",
        .spanish: "Diseño de detalle de sesión mejorado con cambio fluido entre las pestañas de Conversación y Uso e identificación de adjuntos",
        .german: "Sitzungsdetail-Layout verbessert mit nahtlosem Wechsel zwischen Konversation und Verbrauch sowie Anhangsmarkierungen",
        .french: "Mise en page des détails de session affinée avec basculement fluide entre Conversation et Utilisation et badges de pièces jointes",
        .portuguese: "Esquema de detalhes da sessão aperfeiçoado com alternância suave entre os separadores Conversa e Utilização e identificação de anexos",
        .portugueseBrazil: "Layout de detalhes da sessão aprimorado com alternância suave entre as abas Conversa e Uso e identificação de anexos"
    ],
    "Conversation": [
        .traditionalChinese: "對話內容",
        .japanese: "会話内容",
        .korean: "대화 내용",
        .spanish: "Conversación",
        .german: "Konversation",
        .french: "Conversation",
        .portuguese: "Conversa",
        .portugueseBrazil: "Conversa"
    ],
    "Session detail type": [
        .traditionalChinese: "會話明細類型",
        .japanese: "セッション詳細タイプ",
        .korean: "세션 세부 정보 유형",
        .spanish: "Tipo de detalle de sesión",
        .german: "Sitzungsdetailtyp",
        .french: "Type de détail de session",
        .portuguese: "Tipo de detalhe da sessão",
        .portugueseBrazil: "Tipo de detalhe da sessão"
    ],
    "Loading conversation...": [
        .traditionalChinese: "正在讀取對話內容…",
        .japanese: "会話内容を読み込み中…",
        .korean: "대화 내용 읽는 중…",
        .spanish: "Cargando conversación...",
        .german: "Konversation wird geladen...",
        .french: "Chargement de la conversation...",
        .portuguese: "A carregar conversa...",
        .portugueseBrazil: "Carregando conversa..."
    ],
    "No user or assistant messages were found in this session": [
        .traditionalChinese: "這條記錄中沒有可顯示的使用者或助理訊息",
        .japanese: "このセッションには表示可能なユーザーまたはアシスタントのメッセージがありません",
        .korean: "이 세션에는 표시할 수 있는 사용자 또는 어시스턴트 메시지가 없습니다",
        .spanish: "No se encontraron mensajes de usuario ni de asistente en esta sesión",
        .german: "In dieser Sitzung wurden keine Benutzer- oder Assistentennachrichten gefunden",
        .french: "Aucun message utilisateur ou assistant trouvé dans cette session",
        .portuguese: "Não foram encontradas mensagens de utilizador ou assistente nesta sessão",
        .portugueseBrazil: "Não foram encontradas mensagens de usuário ou assistente nesta sessão"
    ],
    "Failed to read conversation: %@": [
        .traditionalChinese: "讀取對話失敗：%@",
        .japanese: "会話内容の取得に失敗しました：%@",
        .korean: "대화 내용을 읽지 못했습니다: %@",
        .spanish: "Error al leer la conversación: %@",
        .german: "Fehler beim Laden der Konversation: %@",
        .french: "Échec de lecture de la conversation : %@",
        .portuguese: "Falha ao ler a conversa: %@",
        .portugueseBrazil: "Falha ao ler a conversa: %@"
    ],
    "Search titles or conversation text...": [
        .traditionalChinese: "搜尋標題或對話內容…",
        .japanese: "タイトルまたは会話内容を検索…",
        .korean: "제목 또는 대화 내용 검색…",
        .spanish: "Buscar títulos o texto de conversación...",
        .german: "Titel oder Konversationstext suchen...",
        .french: "Rechercher des titres ou le texte de la conversation...",
        .portuguese: "Pesquisar títulos ou texto da conversa...",
        .portugueseBrazil: "Pesquisar títulos ou texto da conversa..."
    ],
    "No matching title or conversation text": [
        .traditionalChinese: "沒有相符的標題或對話內容",
        .japanese: "一致するタイトルまたは会話内容が見つかりません",
        .korean: "일치하는 제목 또는 대화 내용이 없습니다",
        .spanish: "No hay títulos ni texto de conversación coincidentes",
        .german: "Kein passender Titel oder Konversationstext gefunden",
        .french: "Aucun titre ni texte de conversation correspondant",
        .portuguese: "Nenhum título ou texto de conversa correspondente",
        .portugueseBrazil: "Nenhum título ou texto de conversa correspondente"
    ],
    "You": [
        .traditionalChinese: "使用者",
        .japanese: "ユーザー",
        .korean: "사용자",
        .spanish: "Tú",
        .german: "Du",
        .french: "Vous",
        .portuguese: "Você",
        .portugueseBrazil: "Você"
    ],
    "Assistant": [
        .traditionalChinese: "助理",
        .japanese: "アシスタント",
        .korean: "어시스턴트",
        .spanish: "Asistente",
        .german: "Assistent",
        .french: "Assistant",
        .portuguese: "Assistente",
        .portugueseBrazil: "Assistente"
    ],
    "%d messages": [
        .traditionalChinese: "%d 則訊息",
        .japanese: "%d 件のメッセージ",
        .korean: "%d개 메시지",
        .spanish: "%d mensajes",
        .german: "%d Nachrichten",
        .french: "%d messages",
        .portuguese: "%d mensagens",
        .portugueseBrazil: "%d mensagens"
    ],
    "%d attachments": [
        .traditionalChinese: "%d 個附件",
        .japanese: "%d 件の添付ファイル",
        .korean: "%d개 첨부파일",
        .spanish: "%d archivos adjuntos",
        .german: "%d Anhänge",
        .french: "%d pièces jointes",
        .portuguese: "%d anexos",
        .portugueseBrazil: "%d anexos"
    ],
    "Deeply optimized asynchronous UI data loading with debouncing and on-demand refresh, reducing CPU and database I/O overhead": [
        .traditionalChinese: "深度優化全介面非同步資料載入機制，引入防抖過濾與按需重新整理，大幅降低高頻切換時的 CPU 與資料庫 I/O 佔用",
        .japanese: "全画面の非同期データ読み込み機構を刷新し、デバウンス処理とオンデマンド更新によりタブ切替時の CPU および DB I/O 負荷を大幅に削減",
        .korean: "전체 화면의 비동기 데이터 로딩 메커니즘을 심층 최적화하고 디바운싱 및 온디맨드 새로고침을 도입하여 탭 전환 시 CPU 및 DB I/O 부하 대폭 감소",
        .spanish: "Carga de datos asíncrona de la interfaz optimizada con filtrado antirrebote y actualización bajo demanda, reduciendo el uso de CPU y E/S de base de datos",
        .german: "Asynchrones Laden von UI-Daten mit Debounce-Filterung und On-Demand-Aktualisierung optimiert, wodurch CPU- und Datenbank-I/O-Lasten deutlich gesenkt werden",
        .french: "Chargement asynchrone des données de l'interface optimisé avec filtrage anti-rebond et rafraîchissement à la demande, réduisant la charge CPU et E/S de la base de données",
        .portuguese: "Carregamento assíncrono de dados da interface otimizado com filtragem antirressalto e atualização a pedido, reduzindo a utilização de CPU e E/S da base de dados",
        .portugueseBrazil: "Carregamento assíncrono de dados da interface otimizado com filtragem antirruído e atualização sob demanda, reduzindo o uso de CPU e E/S do banco de dados"
    ],
    "Decoupled usage dashboard forecast calculations from heavy historical queries for instant rate limit updates and smoother interaction": [
        .traditionalChinese: "重構用量看板預測引擎響應鏈路，實現輕量級額度變化即時計算與重度歷史分析按需解耦",
        .japanese: "利用状況ダッシュボードの予測計算と重い履歴データ取得を分離し、クォータ変化時の即時反映とスムーズな操作性を実現",
        .korean: "사용량 대시보드의 예측 계산을 무거운 과거 데이터 쿼리와 분리하여 할당량 변동 시 즉각적인 계산 및 원활한 상호작용 구현",
        .spanish: "Desacoplados los cálculos de previsión del panel de uso de las consultas pesadas del historial para actualizaciones instantáneas y fluidas",
        .german: "Prognoseberechnungen im Verbrauchs-Dashboard von rechenintensiven Verlaufsabfragen entkoppelt für sofortige Aktualisierungen und flüssigere Bedienung",
        .french: "Découplage des calculs de prévision du tableau de bord d'utilisation des requêtes d'historique lourdes pour des mises à jour instantanées et fluides",
        .portuguese: "Desacoplados os cálculos de previsão do painel de utilização das consultas pesadas do histórico para atualizações instantâneas e maior fluidez",
        .portugueseBrazil: "Desacoplados os cálculos de previsão do painel de uso das consultas pesadas do histórico para atualizações instantâneas e maior fluidez"
    ],
    "Refined menu bar popover and floating overlay lifecycle interactions, enhancing smoothness during multi-display and window transitions": [
        .traditionalChinese: "優化選單列常駐面板與懸浮掛件的生命週期互動，提升多螢幕協同與視窗切換時的響應流暢度",
        .japanese: "メニューバーポップオーバーとフローティングウィジェットのライフサイクル連携を改善し、マルチディスプレイ環境やウィンドウ切替時の操作性を向上",
        .korean: "메뉴 바 팝오버 및 플로팅 위젯의 수명 주기 상호작용을 개선하여 다중 모니터 환경 및 창 전환 시 응답 유연성 향상",
        .spanish: "Mejoradas las interacciones del menú emergente de la barra y la superposición flotante para mayor fluidez en entornos multipantalla",
        .german: "Lebenszyklus-Interaktionen des Menüleisten-Popovers und schwebenden Overlays verbessert für flüssigere Übergänge bei mehreren Bildschirmen",
        .french: "Amélioration des interactions du popover de la barre de menus et de la superposition flottante pour une meilleure fluidité multi-écrans",
        .portuguese: "Aperfeiçoadas as interações do popover da barra de menus e da sobreposição flutuante para maior fluidez em ambientes de múltiplos ecrãs",
        .portugueseBrazil: "Aprimoradas as interações do popover da barra de menus e da sobreposição flutuante para maior fluidez em ambientes de várias telas"
    ],
    "Introduced dual-window quota pace budget engine for 5-hour and weekly cycles with window-aware hourly/daily consumption pace": [
        .traditionalChinese: "引入 5 小時與週度雙週期配額預算與建議節奏引擎，根據窗口類型自動按小時/天智能推算合理配額消耗",
        .japanese: "5時間および週間のデュアルウィンドウ配額予算＆推奨ペースエンジンを導入し、ウィンドウ種別に応じて時間/日単位の適正消費ペースを自動算出",
        .korean: "5시간 및 주간 듀얼 윈도우 할당량 예산 및 권장 페이스 엔진을 도입하여 창 유형에 따라 시간/일 단위의 적정 소비량을 스마트하게 추산",
        .spanish: "Introducido el motor de presupuesto de ritmo de cuota para ventanas de 5 horas y semanales con ritmo de consumo por hora o por día según el tipo de ventana",
        .german: "Dual-Fenster-Kontingent-Pace-Engine für 5-Stunden- und Wochenzyklen mit fensterabhängigem stündlichem/täglichem Verbrauchstempo eingeführt",
        .french: "Introduction du moteur de rythme de quota pour cycles de 5 heures et hebdomadaires avec calcul intelligent du rythme horaire/journalier",
        .portuguese: "Introduzido motor de ritmo de quota para ciclos de 5 horas e semanais com cálculo inteligente do ritmo de consumo horário/diário",
        .portugueseBrazil: "Introduzido motor de ritmo de cota para ciclos de 5 horas e semanais com cálculo inteligente do ritmo de consumo horário/diário"
    ],
    "Dynamically adjusted forecast thresholds and sampling freshness for 5-hour windows with enhanced snapshot retention": [
        .traditionalChinese: "動態調整 5 小時短週期的預測門檻與採樣新鮮度，支援高頻週度快照保留並提升預測覆蓋率",
        .japanese: "5時間の短い周期における予測しきい値とサンプリング鮮度を動的に調整し、高頻度なスナップショット保持と予測カバレッジを向上",
        .korean: "5시간 단기 주기의 예측 임계값 및 샘플 신선도를 동적으로 조정하여 고주파 스냅샷 보존 및 예측 커버리지 향상",
        .spanish: "Ajustados dinámicamente los umbrales de predicción y la frescura de muestreo para ventanas de 5 horas con mayor retención de instantáneas",
        .german: "Prognoseschwellen und Stichprobenaktualität für 5-Stunden-Fenster dynamisch angepasst mit verbesserter Snapshot-Speicherung",
        .french: "Ajustement dynamique des seuils de prévision et de la fraîcheur d'échantillonnage pour les fenêtres de 5 heures avec rétention accrue des instantanés",
        .portuguese: "Ajuste dinâmico dos limites de previsão e da frescura da amostragem para janelas de 5 horas com retenção aprimorada de instantâneos",
        .portugueseBrazil: "Ajuste dinâmico dos limites de previsão e do frescor da amostragem para janelas de 5 horas com retenção aprimorada de instantâneos"
    ],
    "Hardened multi-account quota snapshot persistence and JSON-RPC transport resilience against network fluctuations": [
        .traditionalChinese: "增強多帳號額度同步與歷史快照存儲持久化，提升 JSON-RPC 傳輸容錯與弱網恢復能力",
        .japanese: "マルチアカウントのクォータ同期と履歴スナップショットの永続化を強化し、JSON-RPC 転送のフォールトトレランスと不安定なネットワークからの復旧力を向上",
        .korean: "다중 계정 할당량 동기화 및 기록 스냅샷 영속성을 강화하여 JSON-RPC 전송 내결함성 및 네트워크 불안정 복원력 향상",
        .spanish: "Reforzada la persistencia de instantáneas de cuotas multicuenta y la resistencia del transporte JSON-RPC ante fluctuaciones de red",
        .german: "Dauerhaftigkeit von Multi-Konto-Kontingent-Snapshots und Ausfallsicherheit des JSON-RPC-Transports bei Netzwerkfluktuationen verstärkt",
        .french: "Renforcement de la persistance des instantanés de quotas multi-comptes et de la résilience du transport JSON-RPC face aux fluctuations réseau",
        .portuguese: "Reforçada a persistência de instantâneos de quotas multi-conta e a resiliência do transporte JSON-RPC contra oscilações de rede",
        .portugueseBrazil: "Reforçada a persistência de instantâneos de cotas multi-conta e a resiliência do transporte JSON-RPC contra oscilações de rede"
    ],
    "Optimized 5-hour cycle ring indicators and contextual labels across menu bar, overlay, and dashboard with 10-language translations": [
        .traditionalChinese: "優化選單列、全息懸浮窗與看板對 5 小時週期的環形指示與文案感知，全方位完善 10 種語言本地化",
        .japanese: "メニューバー、フローティングオーバーレイ、ダッシュボードにおける5時間周期のリングインジケーターと文脈ラベルを最適化し、10言語の翻訳を完備",
        .korean: "메뉴 바, 플로팅 오버레이, 대시보드에서 5시간 주기에 대한 원형 표시기 및 문맥 라벨을 최적화하고 10개 언어 번역 완비",
        .spanish: "Optimizados los indicadores de anillo y las etiquetas contextuales para ciclos de 5 horas en la barra de menús, overlay y panel con 10 idiomas",
        .german: "Ringanzeigen und Kontextbeschriftungen für 5-Stunden-Zyklen in Menüleiste, Overlay und Dashboard optimiert mit 10-Sprachen-Übersetzungen",
        .french: "Optimisation des indicateurs circulaires et libellés contextuels pour cycles de 5 heures dans la barre de menus, l'overlay et le tableau de bord en 10 langues",
        .portuguese: "Otimizados os indicadores circulares e etiquetas contextuais para ciclos de 5 horas na barra de menus, overlay e painel com 10 idiomas",
        .portugueseBrazil: "Otimizados os indicadores circulares e etiquetas contextuais para ciclos de 5 horas na barra de menus, overlay e painel com 10 idiomas"
    ],
    "Upgraded floating overlay interactions: added auto-hide when target app is inactive and one-click position reset": [
        .traditionalChinese: "全新升級全息懸浮掛件互動與智慧感知：支援「僅在目標應用前台時顯示」自動防打擾，並新增一鍵重設吸附位置",
        .japanese: "フローティングウィジェットの操作性と連携を刷新：「対象アプリが前面にある時のみ表示」の自動非表示と、位置リセット機能を追加",
        .korean: "플로팅 위젯 상호작용 및 지능형 감지 기능 업그레이드: 「대상 앱이 전면에 있을 때만 표시」 자동 숨김 및 부착 위치 원클릭 초기화 지원",
        .spanish: "Superposición flotante mejorada: ocultación automática cuando la aplicación no está activa y restablecimiento de posición con un clic",
        .german: "Schwebendes Overlay verbessert: Automatisches Ausblenden bei inaktiver Ziel-App und Zurücksetzen der Position mit einem Klick",
        .french: "Superposition flottante améliorée : masquage automatique lorsque l'application cible est inactive et réinitialisation de la position en un clic",
        .portuguese: "Sobreposição flutuante melhorada: ocultação automática quando a aplicação de destino está inativa e reposição da posição com um clique",
        .portugueseBrazil: "Sobreposição flutuante aprimorada: ocultação automática quando o aplicativo de destino está inativo e redefinição da posição com um clique"
    ],
    "Refined overlay layout and privacy-preserved mode indicator with smooth view switching between used and available quota": [
        .traditionalChinese: "優化懸浮掛件視覺排版與隱私保護模式提示，增強已用/可用配額視角的平滑切換",
        .japanese: "ウィジェットの視覚レイアウトとプライバシー保護モードの表示を改善し、使用量/残り配額の視点切り替えをスムーズに刷新",
        .korean: "위젯 시각적 레이아웃 및 개인정보 보호 모드 표시를 개선하고 사용량/잔여량 보기 전환을 부드럽게 강화",
        .spanish: "Diseño de superposición refinado e indicador de modo de privacidad con cambio fluido entre cuota usada y disponible",
        .german: "Overlay-Layout und Datenschutzmodus-Anzeige verfeinert mit flüssigem Wechsel zwischen verbrauchtem und verfügbarem Kontingent",
        .french: "Mise en page de la superposition et indicateur de confidentialité affinés avec basculement fluide entre quota utilisé et disponible",
        .portuguese: "Esquema da sobreposição e indicador do modo de privacidade aperfeiçoados com alternância suave entre quota usada e disponível",
        .portugueseBrazil: "Layout da sobreposição e indicador do modo de privacidade aprimorados com alternância suave entre cota usada e disponível"
    ],
    "Restructured usage dashboard forecast cards with adaptive equal-height alignment for enhanced layout aesthetics across displays": [
        .traditionalChinese: "重構用量看板預測卡片佈局，實現自適應等高對齊並提升多解析度下的展示美觀度",
        .japanese: "利用状況ダッシュボードの予測カードレイアウトを再構築し、適応型等高配置により様々な解像度での視認性と美しさを向上",
        .korean: "사용량 대시보드 예측 카드 레이아웃을 개편하여 반응형 균등 높이 정렬 및 다중 해상도 표시 완성도 향상",
        .spanish: "Tarjetas de previsión del panel de uso reestructuradas con alineación adaptativa de igual altura para mejor estética en distintas pantallas",
        .german: "Prognosekarten im Verbrauchs-Dashboard mit adaptiver Höhenausrichtung für eine ansprechendere Darstellung auf verschiedenen Displays überarbeitet",
        .french: "Cartes de prévision du tableau de bord d'utilisation restructurées avec alignement adaptatif de hauteur égale pour une meilleure lisibilité",
        .portuguese: "Cartões de previsão do painel de utilização reestruturados com alinhamento adaptativo de altura igual para melhor apresentação em vários ecrãs",
        .portugueseBrazil: "Cartões de previsão do painel de uso reestruturados com alinhamento adaptativo de altura igual para melhor apresentação em várias telas"
    ],
    "Comprehensive localization dictionary refinements and changelog translation mapping across 10 supported languages": [
        .traditionalChinese: "全面完善 10 種語言的多語言本地化翻譯字典與更新日誌多語言對應",
        .japanese: "サポートされる全 10 言語の翻訳辞書および更新履歴の多言語マッピングを網羅的に拡充",
        .korean: "10개 지원 언어에 대한 현지화 번역 사전 및 업데이트 로그 다국어 매핑 완벽 보강",
        .spanish: "Mejoras integrales en los diccionarios de localización y mapeo de traducciones del registro de cambios para los 10 idiomas compatibles",
        .german: "Umfassende Lokalisierungs-Wörterbucherweiterungen und Changelog-Übersetzungszuordnung für alle 10 unterstützten Sprachen",
        .french: "Enrichissement complet des dictionnaires de localisation et du mappage des traductions du journal des modifications pour les 10 langues",
        .portuguese: "Aperfeiçoamento abrangente dos dicionários de localização e mapeamento de traduções do registo de alterações para os 10 idiomas",
        .portugueseBrazil: "Aprimoramento abrangente dos dicionários de localização e mapeamento de traduções do registro de alterações para os 10 idiomas"
    ],
    "Upgraded Codex pricing and catalog engine with historical tiered pricing, prompt cache savings, and multi-cycle cost auditing": [
        .traditionalChinese: "全新升級 Codex 計費與定價目錄引擎，支援模型歷史分段價格、快取命中折算與多週期計費回溯",
        .japanese: "Codex の価格・料金カタログエンジンを刷新し、履歴価格（段階料金）、キャッシュ節約計算、複数サイクルのコスト監査に対応",
        .korean: "Codex 가격 및 요금 카탈로그 엔진을 개편하여 모델별 과거 단계별 요금, 캐시 절감액 계산, 다중 주기 비용 감사 지원",
        .spanish: "Actualizado el motor de precios y catálogo de Codex con tarifas históricas escalonadas, ahorro de caché y auditoría de costes multiciclo",
        .german: "Codex-Preis- und Katalog-Engine mit gestaffelten historischen Preisen, Cache-Einsparungen und Mehrzyklus-Kostenprüfung aktualisiert",
        .french: "Mise à niveau du moteur de tarification et catalogue Codex avec tarifs historiques échelonnés, économies de cache et audit multi-cycles",
        .portuguese: "Motor de preços e catálogo do Codex atualizado com tarifas históricas escalonadas, poupança de cache e auditoria de custos multiciclo",
        .portugueseBrazil: "Motor de preços e catálogo do Codex aprimorado com tarifas históricas escalonadas, economia de cache e auditoria de custos multiciclo"
    ],
    "Restructured data indexing and database rebuild pipeline with atomic commits, corrupted file quarantine, and timezone alignment": [
        .traditionalChinese: "重構資料索引與資料庫重建機制，增強原子化寫入、損壞檔案自動隔離與跨時區自然日精確對齊",
        .japanese: "データインデックスと DB 再構築パイプラインを再設計し、アトミック書き込み、破損ファイルの自動隔離、タイムゾーン境界の正確な整合を強化",
        .korean: "데이터 인덱싱 및 DB 재구축 파이프라인을 리팩터링하여 원자적 커밋, 손상된 파일 격리, 타임존 자연일 정렬 강화",
        .spanish: "Reestructurado el flujo de indexación y reconstrucción de la base de datos con escrituras atómicas, aislamiento de archivos dañados y alineación horaria",
        .german: "Datenindizierung und Datenbank-Neuerstellung mit atomaren Commits, Quarantäne beschädigter Dateien und Zeitzonenausrichtung neu strukturiert",
        .french: "Restructuration de l'indexation et de la reconstruction de base de données avec écritures atomiques, mise en quarantaine des fichiers corrompus et alignement des fuseaux horaires",
        .portuguese: "Reestruturado o fluxo de indexação e reconstrução da base de dados com escritas atómicas, quarentena de ficheiros corrompidos e alinhamento de fuso horário",
        .portugueseBrazil: "Reestruturado o pipeline de indexação e reconstrução do banco de dados com gravações atômicas, isolamento de arquivos corrompidos e alinhamento de fuso horário"
    ],
    "Hardened reset card persistence and lossy decoding resilience across account switches and syncing gaps": [
        .traditionalChinese: "強化重設卡明細持久化與容錯解析能力，在多帳號切換與同步中提供平滑兜底與狀態佔位",
        .japanese: "リセットカード詳細の永続化とフォールトトレラントなデコードを強化し、アカウント切替や同期遅延時のフォールバックとプレースホルダーを提供",
        .korean: "리셋 카드 세부 정보의 영속성 및 손실 허용 디코딩을 강화하여 계정 전환 및 동기화 지연 시 원활한 대체 상태 제공",
        .spanish: "Reforzada la persistencia y tolerancia a fallos en la decodificación de tarjetas de reinicio durante cambios de cuenta y sincronización",
        .german: "Dauerhaftigkeit und fehlertolerante Dekodierung von Reset-Karten bei Kontowechseln und Synchronisierungslücken verstärkt",
        .french: "Renforcement de la persistance et du décodage tolérant aux pannes des cartes de réinitialisation lors des changements de compte et de synchronisation",
        .portuguese: "Reforçada a persistência e tolerância a falhas na descodificação dos cartões de reposição durante mudanças de conta e sincronização",
        .portugueseBrazil: "Reforçada a persistência e tolerância a falhas na decodificação de cartões de redefinição durante trocas de conta e sincronização"
    ],
    "Optimized memory footprint and high-frequency refresh performance across history, dashboard, and settings views": [
        .traditionalChinese: "優化歷史明細、用量看板與設定介面的高頻重新整理效能與記憶體佔用",
        .japanese: "履歴明細、ダッシュボード、設定画面における高頻度リフレッシュの描画パフォーマンスとメモリ使用量を最適化",
        .korean: "사용 기록, 대시보드, 설정 화면의 고빈도 새로고침 성능 및 메모리 점유율 최적화",
        .spanish: "Optimizados el rendimiento de actualización frecuente y el consumo de memoria en historial, panel y ajustes",
        .german: "Aktualisierungsleistung bei hoher Frequenz und Speicherbedarf in Verlauf, Dashboard und Einstellungen optimiert",
        .french: "Optimisation des performances d'actualisation haute fréquence et de l'empreinte mémoire dans l'historique, le tableau de bord et les paramètres",
        .portuguese: "Otimizado o desempenho de atualização frequente e o consumo de memória no histórico, painel e definições",
        .portugueseBrazil: "Otimizado o desempenho de atualização frequente e o consumo de memória no histórico, painel e configurações"
    ],
    "Optimized menu bar controller initialization during app startup ensuring instant and reliable menu bar presence": [
        .traditionalChinese: "優化 App 啟動階段選單列控制器初始化生命週期，確保冷啟動時即刻可靠掛載選單列圖示並響應互動",
        .japanese: "App 起動時のメニューバーコントローラー初期化ライフサイクルを最適化し、コールドスタート時の即時かつ確実なメニューバーアイコン常駐と操作応答を確保",
        .korean: "앱 시작 시 메뉴 바 컨트롤러 초기화 수명 주기를 최적화하여 콜드 스타트 시 메뉴 바 아이콘의 즉각적인 상주 및 상호작용 보장",
        .spanish: "Optimizada la inicialización del controlador de la barra de menús en el inicio para una presencia inmediata y confiable",
        .german: "Initialisierung des Menüleisten-Controllers beim App-Start optimiert für sofortige und zuverlässige Menüleisten-Präsenz",
        .french: "Optimisation de l'initialisation du contrôleur de barre de menus au démarrage assurant une présence instantanée et fiable",
        .portuguese: "Otimizada a inicialização do controlador da barra de menus no arranque, garantindo presença imediata e fiável",
        .portugueseBrazil: "Otimizada a inicialização do controlador da barra de menus na inicialização, garantindo presença imediata e confiável"
    ],
    "Refined main window focus and refresh callback bindings for enhanced menu bar responsiveness": [
        .traditionalChinese: "完善主視窗喚醒與資料重新整理回調連動，提升選單列常駐模式下的響應速度與穩定性",
        .japanese: "メインウィンドウの復帰およびデータ更新コールの連携を改善し、メニューバー常駐モード時の応答性と安定性を向上",
        .korean: "메인 창 활성화 및 데이터 새로고침 콜백 연동을 개선하여 메뉴 바 상주 모드의 응답성과 안정성 향상",
        .spanish: "Perfeccionada la reactivación de la ventana principal y las llamadas de actualización para mayor capacidad de respuesta",
        .german: "Aktivierung des Hauptfensters und Aktualisierungs-Callbacks verbessert für höhere Reaktionsfähigkeit der Menüleiste",
        .french: "Amélioration du focus de la fenêtre principale et des rappels d'actualisation pour une meilleure réactivité de la barre de menus",
        .portuguese: "Aperfeiçoada a reativação da janela principal e as chamadas de atualização para maior rapidez de resposta",
        .portugueseBrazil: "Aprimorada a reativação da janela principal e as chamadas de atualização para maior rapidez de resposta"
    ],
    "Enhanced in-app update downloading with persistent progress bar and percentage tracker from 0% onwards": [
        .traditionalChinese: "新增下載更新時即時顯示下載進度條與百分比（從 0% 起始終保持滾動條展示）",
        .japanese: "アップデートダウンロード時に進捗バーとパーセンテージを常時表示（0% から表示）",
        .korean: "업데이트 다운로드 시 진행률 표시줄과 백분율을 0%부터 지속적으로 표시",
        .spanish: "Mejorada la descarga de actualizaciones con barra de progreso persistente y porcentaje desde el 0%",
        .german: "Download von Updates mit dauerhaftem Fortschrittsbalken und Prozentanzeige ab 0% verbessert",
        .french: "Amélioration du téléchargement des mises à jour avec barre de progression continue et pourcentage dès 0%",
        .portuguese: "Transferência de atualizações melhorada com barra de progresso persistente e percentagem a partir de 0%",
        .portugueseBrazil: "Download de atualizações aprimorado com barra de progresso persistente e porcentagem a partir de 0%"
    ],
    "Added one-click Factory Reset & Rescan in Settings storage pane with safety confirmation dialog": [
        .traditionalChinese: "在設定「存儲與診斷」新增「一鍵重設 App 與出廠設定」功能，支援安全清除本地資料、還原預設配置並自動重新索引",
        .japanese: "設定の「ストレージと診断」に「App 初期化と工場出荷時リセット」を追加。データの安全消去と再インデックスに対応",
        .korean: "설정 「스토리지 및 진단」에 「앱 초기화 및 기본값 복원」 기능을 추가하여 데이터 초기화 및 자동 재색인 지원",
        .spanish: "Añadido restablecimiento de fábrica y reindexación en el panel de almacenamiento con diálogo de confirmación",
        .german: "Werkseinstellungen und Neuindizierung im Speicher-Tab mit Sicherheitsabfrage hinzugefügt",
        .french: "Ajout de la réinitialisation d'usine et de la réindexation dans l'onglet stockage avec dialogue de confirmation",
        .portuguese: "Adicionada reposição de fábrica e reindexação no painel de armazenamento com diálogo de confirmação",
        .portugueseBrazil: "Adicionada redefinição de fábrica e reindexação no painel de armazenamento com diálogo de confirmação"
    ],
    "Fixed update dialog changelog HTML tag artifacts with automated multi-language localization": [
        .traditionalChinese: "徹底解決升級彈窗更新日誌顯示 HTML 標籤亂碼問題，並支援條目全語言多維度本地化翻譯",
        .japanese: "更新ダイアログにおける HTML タグ混入問題を修正し、各言語への自動翻訳をサポート",
        .korean: "업데이트 대화상자의 HTML 태그 오류를 완전히 해결하고 전 언어 자동 번역 지원",
        .spanish: "Solucionados los problemas de etiquetas HTML en el registro de cambios con localización multilingüe",
        .german: "HTML-Tag-Artefakte im Update-Changelog behoben mit automatisierter lokalisierter Übersetzung",
        .french: "Correction des balises HTML dans le journal des modifications avec localisation multilingue automatique",
        .portuguese: "Correção de etiquetas HTML no registo de alterações com localização multilingue automática",
        .portugueseBrazil: "Correção de tags HTML no registro de alterações com localização multilíngue automática"
    ],
    "Comprehensive localized translation coverage across 10 supported languages": [
        .traditionalChinese: "全面完善 10 種語言的多語言本地化翻譯字典",
        .japanese: "サポートされる全 10 言語の翻訳辞書を大幅に充実",
        .korean: "10개 지원 언어에 대한 현지화 번역 사전 완벽 보강",
        .spanish: "Diccionario de traducciones localizado mejorado para los 10 idiomas compatibles",
        .german: "Vollständiges lokalisierungslexikon für alle 10 unterstützten Sprachen",
        .french: "Dictionnaire de traductions localisées enrichi pour les 10 langues prises en charge",
        .portuguese: "Dicionário de traduções localizadas aperfeiçoado para os 10 idiomas suportados",
        .portugueseBrazil: "Dicionário de traduções localizadas aprimorado para os 10 idiomas suportados"
    ],
    "Reset App & Factory Defaults": [
        .traditionalChinese: "重設 App 與出廠設定",
        .japanese: "App を初期化して工場出荷時の設定に戻す",
        .korean: "앱 초기화 및 기본 설정 복원",
        .spanish: "Restablecer aplicación y valores de fábrica",
        .german: "App zurücksetzen und Werkseinstellungen",
        .french: "Réinitialiser l'application et les paramètres par défaut",
        .portuguese: "Repor aplicação e predefinições de fábrica",
        .portugueseBrazil: "Redefinir aplicativo e padrões de fábrica"
    ],
    "Clears local SQLite database index, resets all preferences, and rescans local data": [
        .traditionalChinese: "清除本地 SQLite 資料庫索引、重設偏好配置並重新開始掃描",
        .japanese: "ローカル SQLite データベースのインデックスを消去し、環境設定を初期化して再スキャンを開始します",
        .korean: "로컬 SQLite 데이터베이스 인덱스를 지우고 모든 환경설정을 초기화한 후 다시 스캔합니다",
        .spanish: "Borra el índice local de SQLite, restablece las preferencias y vuelve a escanear los datos locales",
        .german: "Löscht den lokalen SQLite-Index, setzt alle Einstellungen zurück und scannt lokale Daten neu",
        .french: "Efface l'index de la base SQLite locale, réinitialise les préférences et relance l'indexation",
        .portuguese: "Limpa o índice da base de dados SQLite local, repõe as preferências e volta a analisar os dados",
        .portugueseBrazil: "Limpa o índice do banco de dados SQLite local, redefine as preferências e volta a escanear os dados"
    ],
    "Reset All Data": [
        .traditionalChinese: "一鍵重設所有資料",
        .japanese: "すべてのデータを一括初期化",
        .korean: "모든 데이터 초기화",
        .spanish: "Restablecer todos los datos",
        .german: "Alle Daten zurücksetzen",
        .french: "Tout réinitialiser",
        .portuguese: "Repor todos os dados",
        .portugueseBrazil: "Redefinir todos os dados"
    ],
    "Resetting...": [
        .traditionalChinese: "正在重設...",
        .japanese: "初期化中...",
        .korean: "초기화 중...",
        .spanish: "Restableciendo...",
        .german: "Wird zurückgesetzt...",
        .french: "Réinitialisation...",
        .portuguese: "A repor...",
        .portugueseBrazil: "Redefinindo..."
    ],
    "Reset all data and preferences?": [
        .traditionalChinese: "確認重設所有資料與配置？",
        .japanese: "すべてのデータと設定を初期化しますか？",
        .korean: "모든 데이터와 설정을 초기화하시겠습니까?",
        .spanish: "¿Restablecer todos los datos y preferencias?",
        .german: "Alle Daten und Einstellungen zurücksetzen?",
        .french: "Réinitialiser toutes les données et préférences ?",
        .portuguese: "Repor todos os dados e preferências?",
        .portugueseBrazil: "Redefinir todos os dados e preferências?"
    ],
    "Reset and Rescan": [
        .traditionalChinese: "確認重設並重新索引",
        .japanese: "初期化して再インデックス",
        .korean: "초기화 및 다시 색인",
        .spanish: "Restablecer y volver a indexar",
        .german: "Zurücksetzen und neu indizieren",
        .french: "Réinitialiser et réindexer",
        .portuguese: "Repor e reindexar",
        .portugueseBrazil: "Redefinir e reindexar"
    ],
    "This will clear all local index data and personalized settings, and rescan local Codex history. This cannot be undone.": [
        .traditionalChinese: "此操作將清除所有本地索引與個性化設定，並重新掃描本地 Codex 資料。此操作不可撤銷。",
        .japanese: "この操作により、すべてのローカルインデックスデータと個別設定が消去され、ローカル Codex 履歴が再スキャンされます。この操作は取り消せません。",
        .korean: "이 작업은 모든 로컬 인덱스 데이터와 개인 설정을 삭제하고 로컬 Codex 기록을 다시 스캔합니다. 이 작업은 취소할 수 없습니다.",
        .spanish: "Esto borrará todos los datos de índice local y la configuración personalizada, y volverá a escanear el historial local. Esta acción no se puede deshacer.",
        .german: "Dadurch werden alle lokalen Indexdaten und individuellen Einstellungen gelöscht und der lokale Verlauf neu gescannt. Dies kann nicht rückgängig gemacht werden.",
        .french: "Cette action effacera toutes les données d'index local et les paramètres personnalisés, puis réindexera l'historique local. Cette action est irréversible.",
        .portuguese: "Esta ação limpará todos os dados de índice local e definições personalizadas, voltando a analisar o histórico local. Não pode ser anulada.",
        .portugueseBrazil: "Esta ação limpará todos os dados de índice local e configurações personalizadas, voltando a escanear o histórico local. Não pode ser desfeita."
    ],
    "Redesigned local index & diagnostics layout into a modern adaptive 4-column grid highlighting 12 key health metrics": [
        .traditionalChinese: "全新重構「本地索引與數據診斷」卡片排版為現代化自適應 4 列網格，重點突出 12 項關鍵診斷指標並強化健康度感知",
        .japanese: "「ローカルインデックスと診断」カードを 4 列の適応型グリッドに刷新し、12 の主要な健全性指標を強調表示",
        .korean: "「로컬 인덱스 및 데이터 진단」 카드를 현대적인 4열 적응형 그리드로 개편하여 12가지 핵심 지표를 강조",
        .spanish: "Diseño de diagnóstico e índice local rediseñado en una cuadrícula moderna de 4 columnas que destaca 12 métricas clave",
        .german: "Layout für lokalen Index und Datenprüfung in ein adaptives 4-Spalten-Raster mit 12 Schlüsselmetriken neu gestaltet",
        .french: "Mise en page de l'index local et des diagnostics repensée en une grille adaptative à 4 colonnes mettant en valeur 12 métriques",
        .portuguese: "Disposição do índice local e diagnósticos redesenhada numa grelha adaptável de 4 colunas com 12 métricas chave",
        .portugueseBrazil: "Layout do índice local e diagnósticos redesenhado em uma grade adaptável de 4 colunas com 12 métricas chave"
    ],
    "Polished update dialog visual aesthetics by removing top gradient bar for a sleek border design": [
        .traditionalChinese: "優化升級彈窗視覺細節，移除彈窗頂部橫條，呈現純淨圓角卡片質感",
        .japanese: "更新ダイアログ上部のグラデーションバーを削除し、洗練されたボーダーデザインに最適化",
        .korean: "업데이트 대화상자 상단 막대를 제거하여 깔끔하고 세련된 모서리 디자인으로 개선",
        .spanish: "Detalles visuales del diálogo de actualización optimizados al eliminar la barra superior para un diseño más limpio",
        .german: "Feinschliff am Update-Dialog durch Entfernen des oberen Farbstreifens für ein elegantes Kartendesign",
        .french: "Affinage visuel de la boîte de mise à jour en supprimant la barre supérieure pour un design épuré",
        .portuguese: "Detalhes visuais da janela de atualização otimizados ao remover a barra superior para um design limpo",
        .portugueseBrazil: "Detalhes visuais da janela de atualização otimizados ao remover a barra superior para um design limpo"
    ],
    "Fixed changelog refresh for all supported non-Simplified-Chinese languages with instant localized translation": [
        .traditionalChinese: "修復更新日誌在多語言環境下的刷新機制，所有非簡體中文語言點擊刷新均可獲取並自動本地化翻譯",
        .japanese: "多言語環境での更新履歴の更新処理を修正。簡体字以外の言語でも取得および自動翻訳に対応",
        .korean: "다국어 환경에서 변경 이력 새로고침 문제를 해결하여 모든 언어에서 최신 로그 자동 번역 지원",
        .spanish: "Corregida la actualización del registro de cambios en todos los idiomas con traducción automática instantánea",
        .german: "Changelog-Aktualisierung für alle unterstützten Sprachen repariert mit sofortiger lokalisierter Übersetzung",
        .french: "Correction de l'actualisation du journal des modifications pour toutes les langues avec traduction instantanée",
        .portuguese: "Correção da atualização do registo de alterações para todos os idiomas com tradução instantânea",
        .portugueseBrazil: "Correção da atualização do registro de alterações para todos os idiomas com tradução instantânea"
    ],
    "Hardened reset card decoding resilience against varied payload formats with smart empty-state fallbacks": [
        .traditionalChinese: "加固重置卡數據解析與容錯邏輯，相容多種服務端命名格式並增加空明細智能兜底",
        .japanese: "リセットカードのデコード処理を強化し、様々な命名形式に対応するとともにフォールバックを追加",
        .korean: "리셋 카드 데이터 디코딩의 안정성을 강화하여 다양한 서버 형식 지원 및 스마트 대체 표시 제공",
        .spanish: "Robustecida la decodificación de tarjetas de restablecimiento con compatibilidad de formatos y alternativas inteligentes",
        .german: "Dekodierung von Reset-Karten gegen verschiedene Datenformate gehärtet mit intelligenten Fallbacks",
        .french: "Renforcement du décodage des cartes de réinitialisation avec prise en charge de multiples formats et repli intelligent",
        .portuguese: "Descodificação de cartões de reposição reforçada contra vários formatos com recurso inteligente de reserva",
        .portugueseBrazil: "Decodificação de cartões de redefinição reforçada contra vários formatos com recurso inteligente de reserva"
    ],
    "Restructured Settings view into a 5-tab layout (General, Account, Overlay, Codex, Storage) with persistent state and zero long-scrolling": [
        .traditionalChinese: "全新重構設定介面為 5 大分類 Tab 架構（常規外觀、帳號同步、懸浮掛件、Codex 環境、存儲診斷），告別冗長滾動",
        .japanese: "設定画面を 5 つの分類タブ（一般・アカウント・オーバーレイ・Codex・ストレージ）に再構築し、長いスクロールを解消",
        .korean: "설정 화면을 5개 탭(일반, 계정, 오버레이, Codex, 스토리지) 구조로 전면 개편하여 긴 스크롤 제거",
        .spanish: "Interfaz de configuración reestructurada en 5 pestañas (General, Cuenta, Superposición, Codex, Almacenamiento) sin desplazamiento largo",
        .german: "Einstellungsansicht in ein 5-Registerkarten-Layout (Allgemein, Konto, Overlay, Codex, Speicher) mit dauerhaftem Status ohne langes Scrollen umstrukturiert",
        .french: "Interface de réglages restructurée en 5 onglets (Général, Compte, Superposition, Codex, Stockage) sans défilement interminable",
        .portuguese: "Interface de definições reestruturada em 5 separadores (Geral, Conta, Sobreposição, Codex, Armazenamento) sem deslocamento longo",
        .portugueseBrazil: "Interface de configurações reestruturada em 5 abas (Geral, Conta, Sobreposição, Codex, Armazenamento) sem rolagem longa"
    ],
    "Redesigned software update dialog with version transition badges, download package size, and scrollable release notes panel": [
        .traditionalChinese: "升級彈窗全新高顏值重構，支援版本躍遷對比、安裝包體積展示（如 📦 7.3 MB）與更新日誌獨立滾動面板",
        .japanese: "ソフトウェア更新ダイアログを刷新。バージョン比較、ダウンロードサイズ表示（📦 7.3 MB）、更新履歴パネルに対応",
        .korean: "소프트웨어 업데이트 대화상자 전면 개편: 버전 비교, 다운로드 크기(📦 7.3 MB), 스크롤 가능한 릴리스 정보 패널 지원",
        .spanish: "Diálogo de actualización de software rediseñado con insignias de versión, tamaño de descarga y panel de notas de versión desplazable",
        .german: "Neu gestalteter Software-Update-Dialog mit Versionsübergangs-Badges, Download-Paketgröße und scrollbarem Release-Notes-Panel",
        .french: "Boîte de dialogue de mise à jour logicielle repensée avec badges de version, taille du paquet et panneau de notes de version défilant",
        .portuguese: "Janela de atualização de software redesenhada com distintivos de versão, tamanho do pacote e painel de notas de versão com deslocamento",
        .portugueseBrazil: "Janela de atualização de software redesenhada com distintivos de versão, tamanho do pacote e painel de notas de versão com rolagem"
    ],
    "Parsed model reasoning effort levels from Codex sessions and displayed high-contrast reasoning badges in history and session views": [
        .traditionalChinese: "新增模型推理層級（Reasoning Effort）深度解析，並在歷史明細與會話詳情中以高對比度漸變徽章醒目展示",
        .japanese: "Codex セッションからの推論レベル解析に対応し、履歴とセッション詳細で高コントラストのバッジを表示",
        .korean: "Codex 세션의 추론 수준(Reasoning Effort)을 분석하여 기록 및 세션 상세에 고대비 배지로 표시",
        .spanish: "Niveles de esfuerzo de razonamiento analizados desde las sesiones de Codex y mostrados con insignias de alto contraste",
        .german: "Denkaufwandstufen aus Codex-Sitzungen analysiert und mit kontrastreichen Badges in Verlauf und Sitzungsdetails dargestellt",
        .french: "Niveaux d’effort de raisonnement analysés depuis les sessions Codex et affichés avec des badges à fort contraste",
        .portuguese: "Níveis de esforço de raciocínio analisados das sessões Codex e exibidos com distintivos de alto contraste",
        .portugueseBrazil: "Níveis de esforço de raciocínio analisados das sessões Codex e exibidos com distintivos de alto contraste"
    ],
    "Added project-based session grouping, filtering chips, and expand/collapse support with aggregate tokens and cost analytics": [
        .traditionalChinese: "會話列表支援按專案（代碼工作區）聚合分組與過濾篩選，支援一鍵折疊展開並統計專案消耗",
        .japanese: "セッション一覧をプロジェクト（ワークスペース）別にグループ化・フィルタリング可能にし、集計トークンとコストを表示",
        .korean: "세션 목록을 프로젝트(작업 영역)별로 그룹화 및 필터링하고 토큰 및 비용 총계를 표시하도록 지원",
        .spanish: "Agrupación de sesiones por proyecto, filtros y soporte de plegado/desplegado con estadísticas agregadas de tokens y costos",
        .german: "Projektbasierte Sitzungsgruppierung, Filterchips und Ein-/Ausklappunterstützung mit aggregierten Token- und Kostenanalysen hinzugefügt",
        .french: "Regroupement de sessions par projet, filtres et pliage/dépliage avec analyse agrégée des jetons et des coûts",
        .portuguese: "Agrupamento de sessões por projeto, filtros e suporte a recolher/expandir com análises agregadas de tokens e custos",
        .portugueseBrazil: "Agrupamento de sessões por projeto, filtros e suporte a recolher/expandir com análises agregadas de tokens e custos"
    ],
    "Added prompt cache hit rate efficiency analysis and smart suggestion banners for quota exhaustion and reset cards": [
        .traditionalChinese: "新增 Prompt 快取命中率與節約效益分析，並在主看板增加配額耗盡與重置卡智慧建議橫幅",
        .japanese: "Prompt キャッシュヒット率の効率分析と、クォータ枯渇・リセットカードに関するスマート提案バナーを追加",
        .korean: "프롬프트 캐시 적중률 효율 분석 및 할당량 소진과 리셋 카드에 대한 스마트 제안 배너 추가",
        .spanish: "Análisis de eficiencia de tasa de aciertos de caché de prompts y banners de sugerencias inteligentes para cuota agotada y tarjetas de reinicio",
        .german: "Effizienzanalyse der Prompt-Cache-Trefferquote und intelligente Vorschlagsbanner für aufgebrauchte Kontingente und Reset-Karten hinzugefügt",
        .french: "Analyse de l’efficacité du taux de réussite du cache d’invites et bannières de suggestions intelligentes pour quota épuisé et cartes de réinitialisation",
        .portuguese: "Análise de eficiência da taxa de acerto da cache de prompts e faixas de sugestões inteligentes para quota esgotada e cartões de reposição",
        .portugueseBrazil: "Análise de eficiência da taxa de acerto do cache de prompts e faixas de sugestões inteligentes para cota esgotada e cartões de redefinição"
    ],
    "Refined empty-day activity cards with user-friendly copy and removed redundant default service tier badges": [
        .traditionalChinese: "最佳化當日無活動時的友好空狀態展示，精簡掉預設的 DEFAULT/STANDARD 服務層級標籤",
        .japanese: "アクティビティのない日の表示をユーザーフレンドリーに改善し、不要な DEFAULT/STANDARD バッジを整理",
        .korean: "활동이 없는 날의 빈 상태 표시를 친화적으로 개선하고 기본 DEFAULT/STANDARD 서비스 계층 배지 제거",
        .spanish: "Tarjetas de actividad vacías mejoradas con texto más intuitivo y eliminación de insignias de nivel de servicio predeterminadas innecesarias",
        .german: "Verbesserte Leere-Tage-Aktivitätskarten mit benutzerfreundlichem Text und Entfernung redundanter Standard-Service-Tier-Badges",
        .french: "Cartes d’activité vide améliorées avec un texte convivial et suppression des badges de niveau de service par défaut inutiles",
        .portuguese: "Cartões de atividade vazia melhorados com texto amigável e remoção de distintivos de nível de serviço predefinidos redundantes",
        .portugueseBrazil: "Cartões de atividade vazia melhorados com texto amigável e remoção de distintivos de nível de serviço padrão redundantes"
    ],
    "Release Notes & Improvements": [
        .traditionalChinese: "更新內容與亮點",
        .japanese: "リリースノートと改善点",
        .korean: "릴리스 정보 및 개선 사항",
        .spanish: "Notas de la versión y mejoras",
        .german: "Versionshinweise und Verbesserungen",
        .french: "Notes de version et améliorations",
        .portuguese: "Notas de lançamento e melhorias",
        .portugueseBrazil: "Notas de lançamento e melhorias"
    ],
    "General": [
        .traditionalChinese: "常規外觀",
        .japanese: "一般・外観",
        .korean: "일반 및 모양",
        .spanish: "General y apariencia",
        .german: "Allgemein & Erscheinungsbild",
        .french: "Général et apparence",
        .portuguese: "Geral e aparência",
        .portugueseBrazil: "Geral e aparência"
    ],
    "Account & Sync": [
        .traditionalChinese: "帳號與同步",
        .japanese: "アカウントと同期",
        .korean: "계정 및 동기화",
        .spanish: "Cuenta y sincronización",
        .german: "Konto & Synchronisierung",
        .french: "Compte et synchronisation",
        .portuguese: "Conta e sincronização",
        .portugueseBrazil: "Conta e sincronização"
    ],
    "Overlay HUD": [
        .traditionalChinese: "懸浮窗掛件",
        .japanese: "オーバーレイウィジェット",
        .korean: "오버레이 위젯",
        .spanish: "Widget superpuesto",
        .german: "Overlay-Widget",
        .french: "Widget superposé",
        .portuguese: "Widget flutuante",
        .portugueseBrazil: "Widget flutuante"
    ],
    "Codex Environment": [
        .traditionalChinese: "Codex 環境",
        .japanese: "Codex 環境",
        .korean: "Codex 환경",
        .spanish: "Entorno de Codex",
        .german: "Codex-Umgebung",
        .french: "Environnement Codex",
        .portuguese: "Ambiente Codex",
        .portugueseBrazil: "Ambiente Codex"
    ],
    "Data & Diagnostics": [
        .traditionalChinese: "存儲與診斷",
        .japanese: "データと診断",
        .korean: "데이터 및 진단",
        .spanish: "Datos y diagnósticos",
        .german: "Daten & Diagnose",
        .french: "Données et diagnostics",
        .portuguese: "Dados e diagnósticos",
        .portugueseBrazil: "Dados e diagnósticos"
    ],
    "No session or activity details for this day": [
        .traditionalChinese: "當日暫無詳細會話與調用記錄",
        .japanese: "この日の詳細なセッションおよびアクティビティ履歴はありません",
        .korean: "해당 날짜에 대한 상세 세션 및 활동 기록이 없습니다",
        .spanish: "No hay detalles de sesión ni actividad para este día",
        .german: "Keine Sitzungs- oder Aktivitätsdetails für diesen Tag verfügbar",
        .french: "Aucun détail de session ou d’activité pour cette journée",
        .portuguese: "Sem detalhes de sessão ou atividade para este dia",
        .portugueseBrazil: "Sem detalhes de sessão ou atividade para este dia"
    ],
    "Reasoning Effort: %@": [
        .traditionalChinese: "推理層級：%@",
        .japanese: "推論レベル: %@",
        .korean: "추론 수준: %@",
        .spanish: "Nivel de razonamiento: %@",
        .german: "Denkaufwand: %@",
        .french: "Niveau de raisonnement : %@",
        .portuguese: "Nível de raciocínio: %@",
        .portugueseBrazil: "Nível de raciocínio: %@"
    ],
    "Low Reasoning": [
        .traditionalChinese: "低推理",
        .japanese: "低",
        .korean: "낮음",
        .spanish: "Bajo",
        .german: "Niedrig",
        .french: "Faible",
        .portuguese: "Baixo",
        .portugueseBrazil: "Baixo"
    ],
    "Medium Reasoning": [
        .traditionalChinese: "中推理",
        .japanese: "中",
        .korean: "중간",
        .spanish: "Medio",
        .german: "Mittel",
        .french: "Moyen",
        .portuguese: "Médio",
        .portugueseBrazil: "Médio"
    ],
    "High Reasoning": [
        .traditionalChinese: "高推理",
        .japanese: "高",
        .korean: "높음",
        .spanish: "Alto",
        .german: "Hoch",
        .french: "Élevé",
        .portuguese: "Alto",
        .portugueseBrazil: "Alto"
    ],
    "Extra High Reasoning": [
        .traditionalChinese: "極高推理",
        .japanese: "超高",
        .korean: "매우 높음",
        .spanish: "Muy alto",
        .german: "Sehr hoch",
        .french: "Très élevé",
        .portuguese: "Muito alto",
        .portugueseBrazil: "Muito alto"
    ],
    "Max Reasoning": [
        .traditionalChinese: "最大推理",
        .japanese: "最大",
        .korean: "최대",
        .spanish: "Máximo",
        .german: "Maximal",
        .french: "Maximal",
        .portuguese: "Máximo",
        .portugueseBrazil: "Máximo"
    ],
    "Ultra Reasoning": [
        .traditionalChinese: "超級推理",
        .japanese: "最高",
        .korean: "울트라",
        .spanish: "Ultra",
        .german: "Ultra",
        .french: "Ultra",
        .portuguese: "Ultra",
        .portugueseBrazil: "Ultra"
    ],
    "Back to Main Session": [
        .traditionalChinese: "返回主會話",
        .japanese: "メインセッションに戻る",
        .korean: "기본 세션으로 돌아가기",
        .spanish: "Volver a la sesión principal",
        .german: "Zur Hauptsitzung zurück",
        .french: "Retour à la session principale",
        .portuguese: "Voltar à sessão principal",
        .portugueseBrazil: "Voltar à sessão principal"
    ],
    "Filter and Sort": [
        .traditionalChinese: "篩選與排序",
        .japanese: "絞り込みと並べ替え",
        .korean: "필터 및 정렬",
        .spanish: "Filtrar y ordenar",
        .german: "Filtern und sortieren",
        .french: "Filtrer et trier",
        .portuguese: "Filtrar e ordenar",
        .portugueseBrazil: "Filtrar e ordenar"
    ],
    "Delete Session?": [
        .traditionalChinese: "刪除會話？",
        .japanese: "セッションを削除しますか？",
        .korean: "세션을 삭제할까요?",
        .spanish: "¿Eliminar la sesión?",
        .german: "Sitzung löschen?",
        .french: "Supprimer la session ?",
        .portuguese: "Eliminar sessão?",
        .portugueseBrazil: "Excluir sessão?"
    ],
    "Move to Trash": [
        .traditionalChinese: "移至垃圾桶",
        .japanese: "ゴミ箱に入れる",
        .korean: "휴지통으로 이동",
        .spanish: "Mover a la papelera",
        .german: "In den Papierkorb legen",
        .french: "Placer dans la corbeille",
        .portuguese: "Mover para o Lixo",
        .portugueseBrazil: "Mover para o Lixo"
    ],
    "Delete": [
        .traditionalChinese: "刪除",
        .japanese: "削除",
        .korean: "삭제",
        .spanish: "Eliminar",
        .german: "Löschen",
        .french: "Supprimer",
        .portuguese: "Eliminar",
        .portugueseBrazil: "Excluir"
    ],
    "Operation Failed": [
        .traditionalChinese: "操作失敗",
        .japanese: "操作に失敗しました",
        .korean: "작업 실패",
        .spanish: "Error en la operación",
        .german: "Vorgang fehlgeschlagen",
        .french: "Échec de l’opération",
        .portuguese: "Falha na operação",
        .portugueseBrazil: "Falha na operação"
    ],
    "The session no longer exists.": [
        .traditionalChinese: "該會話已不存在。",
        .japanese: "このセッションはもう存在しません。",
        .korean: "이 세션은 더 이상 존재하지 않습니다.",
        .spanish: "La sesión ya no existe.",
        .german: "Die Sitzung existiert nicht mehr.",
        .french: "Cette session n’existe plus.",
        .portuguese: "A sessão já não existe.",
        .portugueseBrazil: "A sessão não existe mais."
    ],
    "QuotaLens refused to delete a source outside the Codex session folders: %@": [
        .traditionalChinese: "QuotaLens 已拒絕刪除 Codex 會話目錄之外的檔案：%@",
        .japanese: "QuotaLens は Codex セッションフォルダ外のソースの削除を拒否しました: %@",
        .korean: "QuotaLens가 Codex 세션 폴더 외부의 소스 삭제를 거부했습니다: %@",
        .spanish: "QuotaLens rechazó eliminar una fuente fuera de las carpetas de sesiones de Codex: %@",
        .german: "QuotaLens hat das Löschen einer Quelle außerhalb der Codex-Sitzungsordner abgelehnt: %@",
        .french: "QuotaLens a refusé de supprimer une source hors des dossiers de sessions Codex : %@",
        .portuguese: "O QuotaLens recusou eliminar uma origem fora das pastas de sessões do Codex: %@",
        .portugueseBrazil: "O QuotaLens recusou excluir uma origem fora das pastas de sessões do Codex: %@"
    ],
    "The session source is not a regular file: %@": [
        .traditionalChinese: "會話來源不是一般檔案：%@",
        .japanese: "セッションソースは通常のファイルではありません: %@",
        .korean: "세션 소스가 일반 파일이 아닙니다: %@",
        .spanish: "La fuente de la sesión no es un archivo normal: %@",
        .german: "Die Sitzungsquelle ist keine reguläre Datei: %@",
        .french: "La source de la session n’est pas un fichier ordinaire : %@",
        .portuguese: "A origem da sessão não é um ficheiro normal: %@",
        .portugueseBrazil: "A origem da sessão não é um arquivo comum: %@"
    ],
    "The Codex source files for this session and its subagents will be moved to the macOS Trash, where they can be restored.": [
        .traditionalChinese: "此會話及其子代理的 Codex 來源檔案將移至 macOS 垃圾桶，可從垃圾桶還原。",
        .japanese: "このセッションとサブエージェントの Codex ソースファイルを macOS のゴミ箱に移動します。ゴミ箱から復元できます。",
        .korean: "이 세션과 하위 에이전트의 Codex 소스 파일을 macOS 휴지통으로 이동합니다. 휴지통에서 복원할 수 있습니다.",
        .spanish: "Los archivos fuente de Codex de esta sesión y sus subagentes se moverán a la papelera de macOS, desde donde podrán restaurarse.",
        .german: "Die Codex-Quelldateien dieser Sitzung und ihrer Subagenten werden in den macOS-Papierkorb gelegt und können dort wiederhergestellt werden.",
        .french: "Les fichiers source Codex de cette session et de ses sous-agents seront placés dans la corbeille macOS, d’où ils pourront être restaurés.",
        .portuguese: "Os ficheiros de origem do Codex desta sessão e dos respetivos subagentes serão movidos para o Lixo do macOS, de onde podem ser restaurados.",
        .portugueseBrazil: "Os arquivos de origem do Codex desta sessão e de seus subagentes serão movidos para o Lixo do macOS, de onde poderão ser restaurados."
    ],
    "No quota remaining · Waiting for reset": [
        .traditionalChinese: "本週期無可用額度 · 等待重置",
        .japanese: "利用可能なクォータなし · リセット待ち",
        .korean: "남은 할당량 없음 · 재설정 대기 중",
        .spanish: "Sin cuota restante · Esperando el reinicio",
        .german: "Kein Kontingent übrig · Warten auf Reset",
        .french: "Aucun quota restant · En attente de réinitialisation",
        .portuguese: "Sem quota restante · A aguardar reposição",
        .portugueseBrazil: "Sem cota restante · Aguardando redefinição"
    ],
    "Quota Exhausted": [
        .traditionalChinese: "額度已用盡",
        .japanese: "クォータを使い切りました",
        .korean: "할당량 소진",
        .spanish: "Cuota agotada",
        .german: "Kontingent aufgebraucht",
        .french: "Quota épuisé",
        .portuguese: "Quota esgotada",
        .portugueseBrazil: "Cota esgotada"
    ],
    "Waiting": [
        .traditionalChinese: "等待重置",
        .japanese: "待機中",
        .korean: "대기 중",
        .spanish: "Esperando",
        .german: "Warten",
        .french: "En attente",
        .portuguese: "A aguardar",
        .portugueseBrazil: "Aguardando"
    ],
    "No forecast": [
        .traditionalChinese: "無需預測",
        .japanese: "予測不要",
        .korean: "예측 불필요",
        .spanish: "Sin previsión",
        .german: "Keine Prognose",
        .french: "Aucune prévision",
        .portuguese: "Sem previsão",
        .portugueseBrazil: "Sem previsão"
    ],
    "Resets in %@": [
        .traditionalChinese: "%@ 後重置",
        .japanese: "%@ 後にリセット",
        .korean: "%@ 후 재설정",
        .spanish: "Se reinicia en %@",
        .german: "Reset in %@",
        .french: "Réinitialisation dans %@",
        .portuguese: "Repõe dentro de %@",
        .portugueseBrazil: "Redefine em %@"
    ],
    "Quota Status": [
        .traditionalChinese: "額度狀態",
        .japanese: "クォータ状態",
        .korean: "할당량 상태",
        .spanish: "Estado de la cuota",
        .german: "Kontingentstatus",
        .french: "État du quota",
        .portuguese: "Estado da quota",
        .portugueseBrazil: "Status da cota"
    ],
    "5-Hour Quota": [
        .traditionalChinese: "5 小時額度",
        .japanese: "5時間クォータ",
        .korean: "5시간 할당량",
        .spanish: "Cuota de 5 horas",
        .german: "5-Stunden-Kontingent",
        .french: "Quota de 5 heures",
        .portuguese: "Quota de 5 horas",
        .portugueseBrazil: "Quota de 5 horas"
    ],
    "Weekly Quota": [
        .traditionalChinese: "每週額度",
        .japanese: "週間クォータ",
        .korean: "주간 할당량",
        .spanish: "Cuota semanal",
        .german: "Wochenkontingent",
        .french: "Quota hebdomadaire",
        .portuguese: "Quota semanal",
        .portugueseBrazil: "Cota semanal"
    ],
    "Weekly quota exhausted": [
        .traditionalChinese: "每週額度已耗盡",
        .japanese: "週間クォータを使い切りました",
        .korean: "주간 할당량 소진",
        .spanish: "Cuota semanal agotada",
        .german: "Wochenkontingent ausgeschöpft",
        .french: "Quota hebdomadaire épuisé",
        .portuguese: "Quota semanal esgotada",
        .portugueseBrazil: "Cota semanal esgotada"
    ],
    "The 5-hour quota is unavailable until the weekly quota resets": [
        .traditionalChinese: "在每週額度重置前，5 小時額度無法使用",
        .japanese: "週間クォータがリセットされるまで、5時間クォータは利用できません",
        .korean: "주간 할당량이 재설정될 때까지 5시간 할당량을 사용할 수 없습니다",
        .spanish: "La cuota de 5 horas no está disponible hasta que se restablezca la cuota semanal",
        .german: "Das 5-Stunden-Kontingent ist nicht verfügbar, bis das Wochenkontingent zurückgesetzt wird",
        .french: "Le quota de 5 heures est indisponible jusqu'à la réinitialisation du quota hebdomadaire",
        .portuguese: "A quota de 5 horas fica indisponível até a reposição da quota semanal",
        .portugueseBrazil: "A cota de 5 horas fica indisponível até a redefinição da cota semanal"
    ],
    "Exhausted": [
        .traditionalChinese: "已用盡",
        .japanese: "使い切りました",
        .korean: "소진됨",
        .spanish: "Agotada",
        .german: "Aufgebraucht",
        .french: "Épuisé",
        .portuguese: "Esgotada",
        .portugueseBrazil: "Esgotada"
    ],
    "No quota remains in this cycle, so no forecast is needed": [
        .traditionalChinese: "本週期沒有可用額度，無需繼續預測",
        .japanese: "このサイクルに利用可能なクォータがないため、予測は不要です",
        .korean: "이번 주기에 남은 할당량이 없어 예측이 필요하지 않습니다",
        .spanish: "No queda cuota en este ciclo, por lo que no se necesita previsión",
        .german: "In diesem Zyklus ist kein Kontingent mehr verfügbar; eine Prognose ist nicht erforderlich",
        .french: "Il ne reste aucun quota pour ce cycle ; aucune prévision n’est nécessaire",
        .portuguese: "Não resta quota neste ciclo, por isso não é necessária uma previsão",
        .portugueseBrazil: "Não resta cota neste ciclo, portanto não é necessária uma previsão"
    ],
    "Quota exhausted for this cycle, waiting for reset": [
        .traditionalChinese: "本週期額度已用盡，等待重置後恢復",
        .japanese: "今サイクルのクォータを使い切りました。リセットをお待ちください",
        .korean: "이번 주기 할당량을 모두 소진했습니다. 재설정을 기다려주세요",
        .spanish: "Se ha agotado la cuota de este ciclo, esperando el reinicio",
        .german: "Kontingent für diesen Zyklus aufgebraucht, Warten auf Reset",
        .french: "Quota épuisé pour ce cycle, en attente de réinitialisation",
        .portuguese: "Quota deste ciclo esgotada, a aguardar reposição",
        .portugueseBrazil: "Cota deste ciclo esgotada, aguardando redefinição"
    ],
    "Will restore on next reset": [
        .traditionalChinese: "等待下週期重置恢復",
        .japanese: "次回のリセット後に回復します",
        .korean: "다음 주기 재설정 후 복구됩니다",
        .spanish: "Se restablecerá en el próximo ciclo",
        .german: "Wird im nächsten Zyklus zurückgesetzt",
        .french: "Sera restauré au prochain cycle",
        .portuguese: "Será restaurada no próximo ciclo",
        .portugueseBrazil: "Será restaurada no próximo ciclo"
    ],
    "Restore Quota with Reset Card": [
        .traditionalChinese: "建議使用重置卡恢復額度",
        .japanese: "リセットカードでクォータを回復することをお勧めします",
        .korean: "재설정 카드를 사용하여 할당량을 복구하는 것을 권장합니다",
        .spanish: "Se recomienda usar una tarjeta de reinicio para restaurar la cuota",
        .german: "Verwenden Sie eine Reset-Karte, um das Kontingent wiederherzustellen",
        .french: "Il est recommandé d'utiliser une carte de réinitialisation pour restaurer le quota",
        .portuguese: "Recomenda-se a utilização de um cartão de reset para restaurar a quota",
        .portugueseBrazil: "Recomenda-se o uso de um cartão de reset para restaurar a cota"
    ],
    "Current quota is exhausted. You have %d valid reset card (expires %@). Use it now to restore your quota.": [
        .traditionalChinese: "本週期可用額度已耗盡。偵測到您持有 %d 張有效重置卡（最近截止 %@），建議立即使用恢復可用額度。",
        .japanese: "今サイクルの利用可能クォータを使い切りました。有効なリセットカードが %d 枚あります（最短期限 %@）。今すぐ使用して回復することをお勧めします。",
        .korean: "이번 주기 사용 가능한 할당량이 소진되었습니다. 유효한 재설정 카드가 %d장 있습니다(가장 빠른 만료일: %@). 지금 사용하여 할당량을 복구해 보세요.",
        .spanish: "La cuota del ciclo actual se ha agotado. Tiene %d tarjeta de reinicio válida (vence el %@). Úsela ahora para restaurar su cuota.",
        .german: "Das Kontingent für den aktuellen Zyklus ist aufgebraucht. Sie haben %d gültige Reset-Karte (läuft ab am %@). Verwenden Sie sie jetzt, um Ihr Kontingent wiederherzustellen.",
        .french: "Le quota du cycle actuel est épuisé. Vous disposez de %d carte de réinitialisation valide (expire le %@). Utilisez-la dès maintenant pour restaurer votre quota.",
        .portuguese: "A quota do ciclo atual está esgotada. Tem %d cartão de reset válido (expira em %@). Utilize-o agora para restaurar a sua quota.",
        .portugueseBrazil: "A cota do ciclo atual está esgotada. Você tem %d cartão de reset válido (expira em %@). Use-o agora para restaurar sua cota."
    ],
    "Current quota is exhausted. You have %d valid reset card. Use it now to restore your quota.": [
        .traditionalChinese: "本週期可用額度已耗盡。偵測到您持有 %d 張有效重置卡，建議立即使用恢復可用額度。",
        .japanese: "今サイクルの利用可能クォータを使い切りました。有効なリセットカードが %d 枚あります。今すぐ使用して回復することをお勧めします。",
        .korean: "이번 주기 사용 가능한 할당량이 소진되었습니다. 유효한 재설정 카드가 %d장 있습니다. 지금 사용하여 할당량을 복구해 보세요.",
        .spanish: "La cuota del ciclo actual se ha agotado. Tiene %d tarjeta de reinicio válida. Úsela ahora para restaurar su cuota.",
        .german: "Das Kontingent für den aktuellen Zyklus ist aufgebraucht. Sie haben %d gültige Reset-Karte. Verwenden Sie sie jetzt, um Ihr Kontingent wiederherzustellen.",
        .french: "Le quota du cycle actuel est épuisé. Vous disposez de %d carte de réinitialisation valide. Utilisez-la dès maintenant pour restaurer votre quota.",
        .portuguese: "A quota do ciclo atual está esgotada. Tem %d cartão de reset válido. Utilize-o agora para restaurar a sua quota.",
        .portugueseBrazil: "A cota do ciclo atual está esgotada. Você tem %d cartão de reset válido. Use-o agora para restaurar sua cota."
    ],
    "Dismiss for this cycle": [
        .traditionalChinese: "本週期內忽略",
        .japanese: "今サイクルでは無視",
        .korean: "이번 주기 동안 닫기",
        .spanish: "Descartar en este ciclo",
        .german: "In diesem Zyklus ignorieren",
        .french: "Ignorer pour ce cycle",
        .portuguese: "Ignorar neste ciclo",
        .portugueseBrazil: "Ignorar neste ciclo"
    ],
    "Smart Suggestion": [
        .traditionalChinese: "智慧建議",
        .japanese: "スマートな提案",
        .korean: "스마트 제안",
        .spanish: "Sugerencia inteligente",
        .german: "Intelligenter Vorschlag",
        .french: "Suggestion intelligente",
        .portuguese: "Sugestão inteligente",
        .portugueseBrazil: "Sugestão inteligente"
    ],
    "Use Now": [
        .traditionalChinese: "立即使用",
        .japanese: "今すぐ使用",
        .korean: "지금 사용",
        .spanish: "Usar ahora",
        .german: "Jetzt verwenden",
        .french: "Utiliser maintenant",
        .portuguese: "Utilizar agora",
        .portugueseBrazil: "Usar agora"
    ],
    "View Mode": [
        .traditionalChinese: "檢視模式",
        .japanese: "表示モード",
        .korean: "보기 모드",
        .spanish: "Modo de vista",
        .german: "Ansichtsmodus",
        .french: "Mode d'affichage",
        .portuguese: "Modo de visualização",
        .portugueseBrazil: "Modo de exibição"
    ],
    "Timeline List": [
        .traditionalChinese: "時間流平鋪",
        .japanese: "タイムライン一覧",
        .korean: "타임라인 목록",
        .spanish: "Lista de cronología",
        .german: "Zeitleistenliste",
        .french: "Liste chronologique",
        .portuguese: "Lista cronológica",
        .portugueseBrazil: "Lista cronológica"
    ],
    "Group by Project": [
        .traditionalChinese: "按專案分組折疊",
        .japanese: "プロジェクト別に折りたたみ",
        .korean: "프로젝트별 그룹화 및 접기",
        .spanish: "Agrupar por proyecto",
        .german: "Nach Projekt gruppieren",
        .french: "Grouper par projet",
        .portuguese: "Agrupar por projeto",
        .portugueseBrazil: "Agrupar por projeto"
    ],
    "Project Filter": [
        .traditionalChinese: "專案篩選",
        .japanese: "プロジェクト絞り込み",
        .korean: "프로젝트 필터",
        .spanish: "Filtro de proyecto",
        .german: "Projektfilter",
        .french: "Filtre de projet",
        .portuguese: "Filtro de projeto",
        .portugueseBrazil: "Filtro de projeto"
    ],
    "All Projects": [
        .traditionalChinese: "全部專案",
        .japanese: "すべてのプロジェクト",
        .korean: "모든 프로젝트",
        .spanish: "Todos los proyectos",
        .german: "Alle Projekte",
        .french: "Tous les projets",
        .portuguese: "Todos os projetos",
        .portugueseBrazil: "Todos os projetos"
    ],
    "Default / Unnamed": [
        .traditionalChinese: "預設未命名專案",
        .japanese: "未分類プロジェクト",
        .korean: "기본 미분류 프로젝트",
        .spanish: "Sin proyecto / Predeterminado",
        .german: "Standard / Ohne Projekt",
        .french: "Sans projet / Par défaut",
        .portuguese: "Sem projeto / Predefinido",
        .portugueseBrazil: "Sem projeto / Padrão"
    ],
    "Collapse All": [
        .traditionalChinese: "全部折疊",
        .japanese: "すべて折りたたむ",
        .korean: "모두 접기",
        .spanish: "Contraer todo",
        .german: "Alle einklappen",
        .french: "Tout réduire",
        .portuguese: "Recolher tudo",
        .portugueseBrazil: "Recolher tudo"
    ],
    "Expand All": [
        .traditionalChinese: "全部展開",
        .japanese: "すべて展開",
        .korean: "모두 펼치기",
        .spanish: "Expandir todo",
        .german: "Alle ausklappen",
        .french: "Tout développer",
        .portuguese: "Expandir tudo",
        .portugueseBrazil: "Expandir tudo"
    ],
    "%d sessions": [
        .traditionalChinese: "%d 個會話",
        .japanese: "%d 件のセッション",
        .korean: "%d개 세션",
        .spanish: "%d sesiones",
        .german: "%d Sitzungen",
        .french: "%d sessions",
        .portuguese: "%d sessões",
        .portugueseBrazil: "%d sessões"
    ],
    "Project: %@": [
        .traditionalChinese: "專案: %@",
        .japanese: "プロジェクト: %@",
        .korean: "프로젝트: %@",
        .spanish: "Proyecto: %@",
        .german: "Projekt: %@",
        .french: "Projet : %@",
        .portuguese: "Projeto: %@",
        .portugueseBrazil: "Projeto: %@"
    ],
    "Cache Hit Rate Analysis": [
        .traditionalChinese: "快取命中率分析",
        .japanese: "キャッシュヒット率分析",
        .korean: "캐시 적중률 분석",
        .spanish: "Análisis de tasa de aciertos de caché",
        .german: "Cache-Trefferquoten-Analyse",
        .french: "Analyse du taux d'accès au cache",
        .portuguese: "Análise da taxa de acertos de cache",
        .portugueseBrazil: "Análise da taxa de acertos de cache"
    ],
    "Prompt Caching Efficiency": [
        .traditionalChinese: "Prompt 快取效率",
        .japanese: "Prompt キャッシュ効率",
        .korean: "프롬프트 캐싱 효율",
        .spanish: "Eficiencia de caché de prompt",
        .german: "Prompt-Caching-Effizienz",
        .french: "Efficacité de mise en cache des prompts",
        .portuguese: "Eficiência de cache de prompt",
        .portugueseBrazil: "Eficiência de cache de prompt"
    ],
    "%@ cached": [
        .traditionalChinese: "%@ 已快取",
        .japanese: "%@ キャッシュ済",
        .korean: "%@ 캐시됨",
        .spanish: "%@ en caché",
        .german: "%@ zwischengespeichert",
        .french: "%@ en cache",
        .portuguese: "%@ em cache",
        .portugueseBrazil: "%@ em cache"
    ],
    "No requests": [
        .traditionalChinese: "暫無請求",
        .japanese: "リクエストなし",
        .korean: "요청 없음",
        .spanish: "Sin solicitudes",
        .german: "Keine Anfragen",
        .french: "Aucune requête",
        .portuguese: "Sem pedidos",
        .portugueseBrazil: "Sem requisições"
    ],
    "Efficiency Comparison": [
        .traditionalChinese: "效率對比",
        .japanese: "効率比較",
        .korean: "효율 비교",
        .spanish: "Comparación de eficiencia",
        .german: "Effizienzvergleich",
        .french: "Comparaison d'efficacité",
        .portuguese: "Comparação de eficiência",
        .portugueseBrazil: "Comparação de eficiência"
    ],
    "Session deletion with trash-move safety and automatic cascade cleanup of derived analytics": [
        .traditionalChinese: "新增會話刪除與安全清理能力，支援原始檔移至垃圾桶並自動串聯清理本機索引與統計資料",
        .japanese: "セッションの安全なゴミ箱移動削除と派生解析データの自動カスケードクリーンアップ",
        .korean: "휴지통 이동을 통한 안전한 세션 삭제 및 파생 분석 데이터 자동 연쇄 정리",
        .spanish: "Eliminación segura de sesiones con envío a la papelera y limpieza automática en cascada de analíticas",
        .german: "Sicheres Löschen von Sitzungen mit Papierkorb-Verschiebung und automatischer Bereinigung abgeleiteter Analysen",
        .french: "Suppression sécurisée des sessions vers la corbeille et nettoyage automatique en cascade des analyses",
        .portuguese: "Eliminação segura de sessões com envio para o lixo e limpeza automática em cascata de análises",
        .portugueseBrazil: "Exclusão segura de sessões com envio para a lixeira e limpeza automática em cascata de análises"
    ],
    "Dedicated quota exhausted state handling and intelligent forecast suppression": [
        .traditionalChinese: "配額耗盡專屬狀態展示，並在配額耗盡時智慧靜默預測",
        .japanese: "クォータ枯渇専用ステータス表示と枯渇時のスマートな予測抑制",
        .korean: "할당량 소진 전용 상태 표시 및 소진 시 스마트 예측 억제",
        .spanish: "Gestión de estado dedicado para cuota agotada y supresión inteligente de predicciones",
        .german: "Spezielle Statusbehandlung für aufgebrauchte Kontingente und intelligente Prognoseunterdrückung",
        .french: "Gestion d’état dédiée pour quota épuisé et suppression intelligente des prévisions",
        .portuguese: "Tratamento de estado dedicado para quota esgotada e supressão inteligente de previsões",
        .portugueseBrazil: "Tratamento de estado dedicado para cota esgotada e supressão inteligente de previsões"
    ],
    "Enhanced floating HUD overlay with magnetic edge snapping, dragging, and pin persistence": [
        .traditionalChinese: "全面升級全像懸浮窗互動，支援磁吸貼邊、自由拖曳與置頂固定狀態記憶",
        .japanese: "吸着エッジスナップ、ドラッグ移動、固定状態の永続化に対応したフローティング HUD の強化",
        .korean: "자석 가장자리 스냅, 드래그 이동 및 고정 상태 유지를 지원하는 플로팅 HUD 개선",
        .spanish: "Superposición HUD flotante mejorada con ajuste magnético a los bordes, arrastre y persistencia de fijación",
        .german: "Verbessertes schwebendes HUD-Overlay mit magnetischem Randeinrasten, Ziehen und fixer Zustandsbeibehaltung",
        .french: "Superposition HUD flottante améliorée avec alignement magnétique aux bords, déplacement et maintien de fixation",
        .portuguese: "Sobreposição HUD flutuante melhorada com fixação magnética aos limites, arrasto e persistência de fixação",
        .portugueseBrazil: "Sobreposição HUD flutuante aprimorada com encaixe magnético nas bordas, arrasto e persistência de fixação"
    ],
    "Pointer-following detail cards for usage charts and heatmap with faster compact summary queries": [
        .traditionalChinese: "用量圖表與年度熱力圖支援滑鼠跟隨懸浮卡片，大幅最佳化歷史全天彙總查詢效能",
        .japanese: "利用状況グラフとヒートマップでのポインター追従詳細カードと日次集計クエリの高速化",
        .korean: "사용량 차트 및 히트맵 포인터 추적 상세 카드 추가와 일별 요약 쿼리 성능 대폭 개선",
        .spanish: "Tarjetas de detalle que siguen al puntero para gráficos de uso y mapa de calor con consultas de resumen más rápidas",
        .german: "Zeigerfolgende Detailkarten für Nutzungsdiagramme und Heatmap mit schnelleren Abfragen für Tageszusammenfassungen",
        .french: "Cartes de détail suivant le curseur pour les graphiques d’usage et la carte thermique avec requêtes de synthèse accélérées",
        .portuguese: "Cartões de detalhe com seguimento do cursor para gráficos de utilização e mapa térmico com consultas de resumo mais rápidas",
        .portugueseBrazil: "Cartões de detalhe com rastreamento do cursor para gráficos de uso e mapa de calor com consultas de resumo mais rápidas"
    ],
    "Refined Dock and menu bar activation behaviors, with localized changelog rendering": [
        .traditionalChinese: "最佳化 Dock 圖示聚焦與選單列彈窗互動，關於頁更新日誌支援多語言自適應顯示",
        .japanese: "Dock アイコンのアクティブ化とメニューバー操作の洗練、更新履歴の多言語表示対応",
        .korean: "Dock 아이콘 활성화 및 메뉴 막대 동작 개선, 업데이트 로그 다국어 렌더링 지원",
        .spanish: "Comportamiento refinado de activación de Dock y barra de menús, con registro de cambios localizado",
        .german: "Verfeinertes Verhalten beim Aktivieren von Dock und Menüleiste mit lokalisierter Changelog-Darstellung",
        .french: "Comportements d’activation affinés pour le Dock et la barre des menus, avec affichage localisé du journal des modifications",
        .portuguese: "Comportamentos de ativação refinados para o Dock e barra de menus, com apresentação localizada do registo de alterações",
        .portugueseBrazil: "Comportamentos de ativação aprimorados para o Dock e barra de menus, com exibição localizada do histórico de alterações"
    ],
    "Real-time parsing and streaming index for Codex local history & rollout audit logs": [
        .traditionalChinese: "即時解析 Codex 本機歷史用量與 Rollout 稽核日誌，並支援串流索引",
        .japanese: "Codex のローカル履歴と Rollout 監査ログをリアルタイム解析・ストリーミング索引",
        .korean: "Codex 로컬 기록 및 Rollout 감사 로그 실시간 분석과 스트리밍 인덱싱",
        .spanish: "Análisis en tiempo real e indexación continua del historial local y los registros de auditoría Rollout de Codex",
        .german: "Echtzeitanalyse und Streaming-Index für lokale Codex-Verläufe und Rollout-Auditprotokolle",
        .french: "Analyse en temps réel et indexation continue de l’historique local et des journaux d’audit Rollout de Codex",
        .portuguese: "Análise em tempo real e indexação contínua do histórico local e dos registos de auditoria Rollout do Codex",
        .portugueseBrazil: "Análise em tempo real e indexação contínua do histórico local e dos logs de auditoria Rollout do Codex"
    ],
    "Quota consumption forecast engine with linear projection and runout estimation": [
        .traditionalChinese: "配額消耗預測引擎，支援線性投影與耗盡時間估算",
        .japanese: "線形予測と枯渇時間推定に対応したクォータ消費予測エンジン",
        .korean: "선형 투영 및 소진 시점 추정 기반 할당량 소비 예측 엔진",
        .spanish: "Motor de previsión de consumo de cuota con proyección lineal y estimación del agotamiento",
        .german: "Prognose-Engine für den Kontingentverbrauch mit linearer Projektion und Aufbrauchschätzung",
        .french: "Moteur de prévision de consommation du quota avec projection linéaire et estimation de l’épuisement",
        .portuguese: "Motor de previsão de consumo da quota com projeção linear e estimativa de esgotamento",
        .portugueseBrazil: "Motor de previsão de consumo da cota com projeção linear e estimativa de esgotamento"
    ],
    "Interactive session breakdown and usage analytics dashboard": [
        .traditionalChinese: "互動式會話明細與用量分析儀表板",
        .japanese: "インタラクティブなセッション内訳と利用分析ダッシュボード",
        .korean: "대화형 세션 세부 정보 및 사용량 분석 대시보드",
        .spanish: "Desglose interactivo de sesiones y panel de análisis de uso",
        .german: "Interaktive Sitzungsaufschlüsselung und Nutzungsanalyse-Dashboard",
        .french: "Détail interactif des sessions et tableau de bord d’analyse de l’usage",
        .portuguese: "Detalhe interativo de sessões e painel de análise de utilização",
        .portugueseBrazil: "Detalhamento interativo de sessões e painel de análise de uso"
    ],
    "Floating HUD overlay window and enhanced menu bar interactions": [
        .traditionalChinese: "獨立懸浮 HUD 視窗與增強的選單列互動",
        .japanese: "フローティング HUD オーバーレイと強化されたメニューバー操作",
        .korean: "플로팅 HUD 오버레이 창 및 향상된 메뉴 막대 상호작용",
        .spanish: "Ventana HUD flotante e interacciones mejoradas en la barra de menús",
        .german: "Schwebendes HUD-Overlay und verbesserte Menüleisteninteraktionen",
        .french: "Fenêtre HUD flottante et interactions améliorées dans la barre des menus",
        .portuguese: "Janela HUD flutuante e interações melhoradas na barra de menus",
        .portugueseBrazil: "Janela HUD flutuante e interações aprimoradas na barra de menus"
    ],
    "Fixed update feed cache-busting to ensure latest release metadata": [
        .traditionalChinese: "修正更新來源快取，確保取得最新版本中繼資料",
        .japanese: "更新フィードのキャッシュ問題を修正し、最新リリース情報を確実に取得",
        .korean: "최신 릴리스 메타데이터를 가져오도록 업데이트 피드 캐시 문제 수정",
        .spanish: "Corregida la caché del canal de actualizaciones para obtener los metadatos más recientes",
        .german: "Cache-Umgehung des Update-Feeds korrigiert, damit stets die neuesten Release-Metadaten geladen werden",
        .french: "Correction du cache du flux de mise à jour afin de récupérer les dernières métadonnées de version",
        .portuguese: "Corrigida a cache do feed de atualizações para obter os metadados da versão mais recente",
        .portugueseBrazil: "Corrigido o cache do feed de atualizações para obter os metadados da versão mais recente"
    ],
    "Refined reset card confirmation dialog visual aesthetics with smart rule-based copy": [
        .traditionalChinese: "全面優化重置卡確認對話框的視覺質感與智慧規則文案",
        .japanese: "リセットカード確認ダイアログの外観を改善し、ルールベースのスマートな文言を追加",
        .korean: "재설정 카드 확인 대화상자의 시각적 완성도와 규칙 기반 안내 문구 개선",
        .spanish: "Mejoras visuales del diálogo de confirmación de tarjetas de reinicio con textos inteligentes basados en reglas",
        .german: "Bestätigungsdialog für Reset-Karten optisch verfeinert und mit regelbasierten Hinweisen ergänzt",
        .french: "Amélioration visuelle de la confirmation des cartes de réinitialisation avec des textes intelligents fondés sur des règles",
        .portuguese: "Melhoria visual da confirmação de cartões de reset com texto inteligente baseado em regras",
        .portugueseBrazil: "Aprimoramento visual da confirmação de cartões de reset com texto inteligente baseado em regras"
    ],
    "Dynamic top bar title reflecting active tab and brand integration in sidebar footer": [
        .traditionalChinese: "頂端列動態顯示目前分頁，並將品牌整合至側邊欄底部",
        .japanese: "選択中のタブを反映する動的トップバーと、サイドバー下部へのブランド統合",
        .korean: "현재 탭을 반영하는 동적 상단 제목과 사이드바 하단 브랜드 통합",
        .spanish: "Título dinámico en la barra superior según la pestaña activa e integración de la marca en el pie lateral",
        .german: "Dynamischer Titel in der oberen Leiste und Markenintegration im Seitenleistenfuß",
        .french: "Titre dynamique dans la barre supérieure et intégration de la marque au bas de la barre latérale",
        .portuguese: "Título dinâmico na barra superior e integração da marca no rodapé da barra lateral",
        .portugueseBrazil: "Título dinâmico na barra superior e integração da marca no rodapé da barra lateral"
    ],
    "Cleaned up redundant page titles and streamlined overview controls into Hero header": [
        .traditionalChinese: "移除重複頁面標題，並將概覽控制項整合至 Hero 標頭",
        .japanese: "重複するページ見出しを整理し、概要コントロールを Hero ヘッダーに統合",
        .korean: "중복 페이지 제목을 정리하고 개요 제어 기능을 Hero 헤더에 통합",
        .spanish: "Eliminados títulos redundantes e integrados los controles de resumen en la cabecera Hero",
        .german: "Redundante Seitentitel entfernt und Übersichtssteuerung in den Hero-Kopf integriert",
        .french: "Suppression des titres redondants et intégration des contrôles d’aperçu dans l’en-tête Hero",
        .portuguese: "Remoção de títulos redundantes e integração dos controlos de visão geral no cabeçalho Hero",
        .portugueseBrazil: "Remoção de títulos redundantes e integração dos controles de visão geral no cabeçalho Hero"
    ],
    "Upgraded countdown and daily budget pace to real-time second-level precision": [
        .traditionalChinese: "倒數計時與每日額度節奏升級為即時秒級精度",
        .japanese: "カウントダウンと日次クォータペースをリアルタイム秒精度に強化",
        .korean: "카운트다운과 일일 할당량 속도를 실시간 초 단위 정밀도로 개선",
        .spanish: "Cuenta atrás y ritmo diario de cuota actualizados con precisión en tiempo real al segundo",
        .german: "Countdown und tägliches Kontingenttempo auf Echtzeit-Sekundengenauigkeit erweitert",
        .french: "Compte à rebours et rythme quotidien du quota mis à jour en temps réel à la seconde",
        .portuguese: "Contagem decrescente e ritmo diário da quota atualizados em tempo real ao segundo",
        .portugueseBrazil: "Contagem regressiva e ritmo diário da cota atualizados em tempo real por segundo"
    ],
    "Complete localized translations for 10 supported languages": [
        .traditionalChinese: "完整支援 10 種語言的本地化翻譯",
        .japanese: "対応する10言語のローカライズを完備",
        .korean: "지원되는 10개 언어의 전체 현지화 번역",
        .spanish: "Traducción completa para los 10 idiomas compatibles",
        .german: "Vollständige Lokalisierung für 10 unterstützte Sprachen",
        .french: "Traductions complètes pour les 10 langues prises en charge",
        .portuguese: "Traduções completas para os 10 idiomas suportados",
        .portugueseBrazil: "Traduções completas para os 10 idiomas compatíveis"
    ],
    "Added daily budget pace module based on cycle remaining time and quota": [
        .traditionalChinese: "新增依週期剩餘時間與額度計算的每日建議節奏模組",
        .japanese: "サイクル残り時間とクォータに基づく日次利用ペースモジュールを追加",
        .korean: "주기 잔여 시간과 할당량 기반 일일 사용 속도 모듈 추가",
        .spanish: "Añadido el módulo de ritmo diario según el tiempo y la cuota restantes del ciclo",
        .german: "Modul für das tägliche Kontingenttempo anhand verbleibender Zykluszeit und Quote hinzugefügt",
        .french: "Ajout du rythme quotidien selon le temps et le quota restants du cycle",
        .portuguese: "Adicionado módulo de ritmo diário com base no tempo e na quota restantes do ciclo",
        .portugueseBrazil: "Adicionado módulo de ritmo diário com base no tempo e na cota restantes do ciclo"
    ],
    "Cleaned up auxiliary subtitles and tags across pages and sidebar": [
        .traditionalChinese: "清理各頁面與側邊欄的輔助副標題和標籤",
        .japanese: "各ページとサイドバーの補助字幕・タグを整理",
        .korean: "페이지와 사이드바의 보조 설명 및 태그 정리",
        .spanish: "Simplificados los subtítulos y etiquetas auxiliares de las páginas y la barra lateral",
        .german: "Zusätzliche Untertitel und Tags auf Seiten und in der Seitenleiste bereinigt",
        .french: "Nettoyage des sous-titres et étiquettes secondaires dans les pages et la barre latérale",
        .portuguese: "Limpeza de subtítulos e etiquetas auxiliares nas páginas e na barra lateral",
        .portugueseBrazil: "Limpeza de subtítulos e etiquetas auxiliares nas páginas e na barra lateral"
    ],
    "Complete 10-language localized translations and code cleanup": [
        .traditionalChinese: "完成 10 種語言本地化並清理程式碼",
        .japanese: "10言語の完全なローカライズとコード整理",
        .korean: "10개 언어 전체 현지화 및 코드 정리",
        .spanish: "Localización completa en 10 idiomas y limpieza de código",
        .german: "Vollständige Lokalisierung in 10 Sprachen und Codebereinigung",
        .french: "Localisation complète en 10 langues et nettoyage du code",
        .portuguese: "Localização completa em 10 idiomas e limpeza de código",
        .portugueseBrazil: "Localização completa em 10 idiomas e limpeza de código"
    ],
    "Redesigned About view layout with Hero brand center and 2x3 feature grid": [
        .traditionalChinese: "重新設計「關於」頁面，加入 Hero 品牌中心與 2×3 功能網格",
        .japanese: "Hero ブランドセンターと2×3機能グリッドで「このアプリについて」を刷新",
        .korean: "Hero 브랜드 영역과 2×3 기능 그리드로 정보 화면 재설계",
        .spanish: "Rediseñada la vista Acerca de con centro de marca Hero y cuadrícula de funciones 2×3",
        .german: "Info-Ansicht mit Hero-Markenbereich und 2×3-Funktionsraster neu gestaltet",
        .french: "Nouvelle mise en page À propos avec centre de marque Hero et grille de fonctions 2×3",
        .portuguese: "Vista Acerca redesenhada com centro de marca Hero e grelha de funcionalidades 2×3",
        .portugueseBrazil: "Tela Sobre redesenhada com centro de marca Hero e grade de recursos 2×3"
    ],
    "Polished online update interactions and status indicators": [
        .traditionalChinese: "優化線上更新互動與狀態指示",
        .japanese: "オンライン更新の操作とステータス表示を改善",
        .korean: "온라인 업데이트 상호작용 및 상태 표시 개선",
        .spanish: "Mejoradas las interacciones de actualización en línea y los indicadores de estado",
        .german: "Interaktionen und Statusanzeigen für Online-Updates verbessert",
        .french: "Amélioration des interactions de mise à jour en ligne et des indicateurs d’état",
        .portuguese: "Melhoria das interações de atualização online e dos indicadores de estado",
        .portugueseBrazil: "Aprimoramento das interações de atualização online e dos indicadores de status"
    ],
    "Fixed Sparkle in-app delta update checking and version comparison": [
        .traditionalChinese: "修正 Sparkle 應用程式內增量更新檢查與版本比較",
        .japanese: "Sparkle のアプリ内差分更新確認とバージョン比較を修正",
        .korean: "Sparkle 앱 내 증분 업데이트 확인 및 버전 비교 수정",
        .spanish: "Corregidas la comprobación de actualizaciones delta y la comparación de versiones con Sparkle",
        .german: "Sparkle-Prüfung auf Delta-Updates und Versionsvergleich korrigiert",
        .french: "Correction de la recherche de mises à jour delta et de la comparaison des versions avec Sparkle",
        .portuguese: "Corrigidas a verificação de atualizações delta e a comparação de versões com o Sparkle",
        .portugueseBrazil: "Corrigidas a verificação de atualizações delta e a comparação de versões com o Sparkle"
    ],
    "Unified language and preference setting icons": [
        .traditionalChinese: "統一語言與偏好設定圖示",
        .japanese: "言語と環境設定のアイコンを統一",
        .korean: "언어 및 환경설정 아이콘 통일",
        .spanish: "Unificados los iconos de idioma y preferencias",
        .german: "Symbole für Sprache und Einstellungen vereinheitlicht",
        .french: "Harmonisation des icônes de langue et de préférences",
        .portuguese: "Ícones de idioma e preferências uniformizados",
        .portugueseBrazil: "Ícones de idioma e preferências padronizados"
    ],
    "Added menu bar compact mode and optional hidden Dock icon": [
        .traditionalChinese: "新增精簡選單列模式與可選的 Dock 圖示隱藏功能",
        .japanese: "メニューバーコンパクトモードとDockアイコン非表示オプションを追加",
        .korean: "메뉴 막대 컴팩트 모드 및 Dock 아이콘 숨기기 옵션 추가",
        .spanish: "Añadidos el modo compacto de barra de menús y la opción de ocultar el icono del Dock",
        .german: "Kompakten Menüleistenmodus und optional ausgeblendetes Dock-Symbol hinzugefügt",
        .french: "Ajout du mode compact de barre des menus et du masquage facultatif de l’icône du Dock",
        .portuguese: "Adicionado modo compacto da barra de menus e opção para ocultar o ícone da Dock",
        .portugueseBrazil: "Adicionado modo compacto da barra de menus e opção para ocultar o ícone do Dock"
    ],
    "Improved ChatGPT and Codex quota snapshot parsers": [
        .traditionalChinese: "改進 ChatGPT 與 Codex 額度快照解析器",
        .japanese: "ChatGPT と Codex のクォータスナップショット解析を改善",
        .korean: "ChatGPT 및 Codex 할당량 스냅샷 파서 개선",
        .spanish: "Mejorados los analizadores de instantáneas de cuota de ChatGPT y Codex",
        .german: "Parser für ChatGPT- und Codex-Kontingent-Snapshots verbessert",
        .french: "Amélioration des analyseurs d’instantanés de quota ChatGPT et Codex",
        .portuguese: "Melhoria dos analisadores de instantâneos de quota do ChatGPT e Codex",
        .portugueseBrazil: "Melhoria dos analisadores de instantâneos de cota do ChatGPT e Codex"
    ],
    "Initial release of QuotaLens with real-time quota tracking, reset card alerts, and cycle detection": [
        .traditionalChinese: "QuotaLens 首次發布，支援即時額度追蹤、重置卡提醒與週期偵測",
        .japanese: "リアルタイムのクォータ追跡、リセットカード通知、サイクル検出を備えた QuotaLens 初回リリース",
        .korean: "실시간 할당량 추적, 재설정 카드 알림 및 주기 감지를 지원하는 QuotaLens 최초 출시",
        .spanish: "Primera versión de QuotaLens con seguimiento de cuota en tiempo real, alertas de tarjetas de reinicio y detección de ciclos",
        .german: "Erste QuotaLens-Version mit Echtzeit-Kontingentverfolgung, Reset-Karten-Warnungen und Zykluserkennung",
        .french: "Première version de QuotaLens avec suivi du quota en temps réel, alertes de cartes de réinitialisation et détection des cycles",
        .portuguese: "Primeira versão do QuotaLens com monitorização de quota em tempo real, alertas de cartões de reset e deteção de ciclos",
        .portugueseBrazil: "Primeira versão do QuotaLens com monitoramento de cota em tempo real, alertas de cartões de reset e detecção de ciclos"
    ],
    "API Equivalent Value · Beta": [
        .traditionalChinese: "API 等價價值 · Beta",
        .japanese: "API 換算価値 · Beta",
        .korean: "API 환산 가치 · Beta",
        .spanish: "Valor equivalente API · Beta",
        .german: "API-Gegenwert · Beta",
        .french: "Valeur équivalente API · bêta",
        .portuguese: "Valor equivalente da API · Beta",
        .portugueseBrazil: "Valor equivalente da API · Beta"
    ],
    "Day API Equivalent Value · Beta": [
        .traditionalChinese: "當日 API 等價價值 · Beta",
        .japanese: "当日 API 換算価値 · Beta",
        .korean: "일일 API 환산 가치 · Beta",
        .spanish: "Valor API del día · Beta",
        .german: "API-Tagesgegenwert · Beta",
        .french: "Valeur API du jour · bêta",
        .portuguese: "Valor API do dia · Beta",
        .portugueseBrazil: "Valor API do dia · Beta"
    ],
    "API Equivalent Value": [
        .traditionalChinese: "API 等價價值",
        .japanese: "API 換算価値",
        .korean: "API 환산 가치",
        .spanish: "Valor equivalente de API",
        .german: "API-Gegenwert",
        .french: "Équivalent API",
        .portuguese: "Valor equivalente da API",
        .portugueseBrazil: "Valor equivalente da API"
    ],
    "Daily API Equivalent Value": [
        .traditionalChinese: "當日 API 等價價值",
        .japanese: "当日の API 換算価値",
        .korean: "일일 API 환산 가치",
        .spanish: "Valor diario equivalente de API",
        .german: "Täglicher API-Gegenwert",
        .french: "Équivalent API du jour",
        .portuguese: "Valor diário equivalente da API",
        .portugueseBrazil: "Valor diário equivalente da API"
    ],
    "API Value": [
        .traditionalChinese: "API 價值",
        .japanese: "API 価値",
        .korean: "API 가치",
        .spanish: "Valor API",
        .german: "API-Wert",
        .french: "Valeur API",
        .portuguese: "Valor da API",
        .portugueseBrazil: "Valor da API"
    ],
    "API Value:": [
        .traditionalChinese: "API 價值：",
        .japanese: "API 価値:",
        .korean: "API 가치:",
        .spanish: "Valor API:",
        .german: "API-Wert:",
        .french: "Valeur API :",
        .portuguese: "Valor da API:",
        .portugueseBrazil: "Valor da API:"
    ],
    "Converted at API rates": [
        .traditionalChinese: "按 API 價格折算",
        .japanese: "API 料金で換算",
        .korean: "API 요금 기준 환산",
        .spanish: "Convertido según tarifas API",
        .german: "Nach API-Tarifen umgerechnet",
        .french: "Converti aux tarifs API",
        .portuguese: "Convertido pelas tarifas da API",
        .portugueseBrazil: "Convertido pelas tarifas da API"
    ],
    "Includes historical records": [
        .traditionalChinese: "包含歷史記錄",
        .japanese: "履歴を含む",
        .korean: "과거 기록 포함",
        .spanish: "Incluye registros históricos",
        .german: "Enthält historische Einträge",
        .french: "Inclut les historiques",
        .portuguese: "Inclui registos históricos",
        .portugueseBrazil: "Inclui registros históricos"
    ],
    "Some records are unpriced": [
        .traditionalChinese: "部分記錄未計價",
        .japanese: "一部の記録は未計価",
        .korean: "일부 기록은 가격이 책정되지 않음",
        .spanish: "Algunos registros no tienen precio",
        .german: "Einige Einträge sind nicht bepreist",
        .french: "Certains enregistrements ne sont pas tarifés",
        .portuguese: "Alguns registos não têm preço",
        .portugueseBrazil: "Alguns registros não têm preço"
    ],
    "Limited pricing data; showing token trend only": [
        .traditionalChinese: "計價資料不足，僅顯示 Token 趨勢",
        .japanese: "価格データ不足のため、Token の傾向のみ表示",
        .korean: "가격 데이터 부족으로 Token 추세만 표시",
        .spanish: "Datos de precios insuficientes; solo se muestra la tendencia de tokens",
        .german: "Unzureichende Preisdaten; nur der Token-Trend wird angezeigt",
        .french: "Données tarifaires insuffisantes ; seule la tendance des tokens est affichée",
        .portuguese: "Dados de preços insuficientes; apenas a tendência de tokens é mostrada",
        .portugueseBrazil: "Dados de preços insuficientes; apenas a tendência de tokens é mostrada"
    ],
    "Read local sessions for token and API value": [
        .traditionalChinese: "讀取本機會話記錄，統計 Token 與 API 價值",
        .japanese: "ローカルセッションから Token と API 価値を集計",
        .korean: "로컬 세션에서 Token과 API 가치를 집계",
        .spanish: "Lee sesiones locales para calcular tokens y valor API",
        .german: "Lokale Sitzungen für Token- und API-Wert auslesen",
        .french: "Lit les sessions locales pour calculer les tokens et la valeur API",
        .portuguese: "Lê sessões locais para calcular tokens e valor da API",
        .portugueseBrazil: "Lê sessões locais para calcular tokens e valor da API"
    ],
    "Local Usage & API Value": [
        .traditionalChinese: "本機用量與 API 價值",
        .japanese: "ローカル使用量と API 価値",
        .korean: "로컬 사용량 및 API 가치",
        .spanish: "Uso local y valor API",
        .german: "Lokale Nutzung & API-Wert",
        .french: "Usage local et valeur API",
        .portuguese: "Uso local e valor da API",
        .portugueseBrazil: "Uso local e valor da API"
    ],
    "Not a bill": [
        .traditionalChinese: "不是訂閱帳單金額",
        .japanese: "請求額ではありません",
        .korean: "청구 금액이 아닙니다",
        .spanish: "No es una factura",
        .german: "Kein Rechnungsbetrag",
        .french: "Ce n'est pas une facture",
        .portuguese: "Não é uma fatura",
        .portugueseBrazil: "Não é uma fatura"
    ],
    "Unknown model, no default pricing": [
        .traditionalChinese: "未知模型，未使用預設計價",
        .japanese: "不明なモデル、既定価格は未使用",
        .korean: "알 수 없는 모델, 기본 가격 미사용",
        .spanish: "Modelo desconocido, sin precio predeterminado",
        .german: "Unbekanntes Modell, keine Standardpreise",
        .french: "Modèle inconnu, aucun prix par défaut",
        .portuguese: "Modelo desconhecido, sem preço padrão",
        .portugueseBrazil: "Modelo desconhecido, sem preço padrão"
    ],
    "Missing timestamp": [
        .traditionalChinese: "缺少時間戳",
        .japanese: "タイムスタンプなし",
        .korean: "타임스탬프 없음",
        .spanish: "Falta marca de tiempo",
        .german: "Zeitstempel fehlt",
        .french: "Horodatage manquant",
        .portuguese: "Carimbo de data/hora ausente",
        .portugueseBrazil: "Carimbo de data/hora ausente"
    ],
    "Local Index Diagnostics": [
        .traditionalChinese: "本地索引診斷",
        .japanese: "ローカルインデックス診断",
        .korean: "로컬 인덱스 진단",
        .spanish: "Diagnóstico del índice local",
        .german: "Lokale Indexdiagnose",
        .french: "Diagnostics de l'index local",
        .portuguese: "Diagnóstico do índice local",
        .portugueseBrazil: "Diagnóstico do índice local"
    ],
    "Unpriced": [
        .traditionalChinese: "未計價",
        .japanese: "未価格",
        .korean: "미가격",
        .spanish: "Sin precio",
        .german: "Nicht bepreist",
        .french: "Non tarifé",
        .portuguese: "Sem preço",
        .portugueseBrazil: "Sem preço"
    ],
    "Unknown Models": [
        .traditionalChinese: "未知模型",
        .japanese: "不明なモデル",
        .korean: "알 수 없는 모델",
        .spanish: "Modelos desconocidos",
        .german: "Unbekannte Modelle",
        .french: "Modèles inconnus",
        .portuguese: "Modelos desconhecidos",
        .portugueseBrazil: "Modelos desconhecidos"
    ],
    "Timestamp Fallbacks": [
        .traditionalChinese: "時間兜底",
        .japanese: "時刻フォールバック",
        .korean: "타임스탬프 대체",
        .spanish: "Fechas estimadas",
        .german: "Zeit-Fallbacks",
        .french: "Horodatages de secours",
        .portuguese: "Datas estimadas",
        .portugueseBrazil: "Datas estimadas"
    ],
    "Active catalog: %@": [
        .traditionalChinese: "目前價格目錄：%@",
        .japanese: "有効な価格カタログ: %@",
        .korean: "활성 가격 카탈로그: %@",
        .spanish: "Catálogo activo: %@",
        .german: "Aktiver Katalog: %@",
        .french: "Catalogue actif : %@",
        .portuguese: "Catálogo ativo: %@",
        .portugueseBrazil: "Catálogo ativo: %@"
    ],
    "Usage Dashboard": [
        .traditionalChinese: "用量大盤",
        .japanese: "利用状況ダッシュボード",
        .korean: "사용량 대시보드",
        .spanish: "Panel de uso",
        .german: "Nutzungs-Dashboard",
        .french: "Tableau de bord d'usage",
        .portuguese: "Painel de uso",
        .portugueseBrazil: "Painel de uso"
    ],
    "History": [
        .traditionalChinese: "歷史記錄",
        .japanese: "利用履歴",
        .korean: "사용 내역",
        .spanish: "Historial",
        .german: "Verlauf",
        .french: "Historique",
        .portuguese: "Histórico",
        .portugueseBrazil: "Histórico"
    ],
    "Sessions": [
        .traditionalChinese: "會話明細",
        .japanese: "セッション一覧",
        .korean: "세션 목록",
        .spanish: "Sesiones",
        .german: "Sitzungen",
        .french: "Sessions",
        .portuguese: "Sessões",
        .portugueseBrazil: "Sessões"
    ],
    "Local Analytics & Overlay": [
        .traditionalChinese: "本地用量分析與掛件",
        .japanese: "ローカル分析とオーバーレイ",
        .korean: "로컬 사용량 분석 및 위젯",
        .spanish: "Analítica local y widget flotante",
        .german: "Lokale Analysen & Overlay",
        .french: "Analytique locale & Widget flottant",
        .portuguese: "Análise local e widget",
        .portugueseBrazil: "Análise local e widget"
    ],
    "Enable Local Codex Analytics": [
        .traditionalChinese: "啟用本地 Codex 用量分析",
        .japanese: "ローカル Codex 利用分析を有効化",
        .korean: "로컬 Codex 사용량 분석 활성화",
        .spanish: "Activar analítica local de Codex",
        .german: "Lokale Codex-Analyse aktivieren",
        .french: "Activer l'analytique locale Codex",
        .portuguese: "Ativar análise local do Codex",
        .portugueseBrazil: "Ativar análise local do Codex"
    ],
    "Codex Window Overlay": [
        .traditionalChinese: "Codex 視窗懸浮掛件",
        .japanese: "Codex ウインドウフローティングウィジェット",
        .korean: "Codex 창 플로팅 위젯",
        .spanish: "Widget flotante de Codex",
        .german: "Schwebendes Codex-Fenster-Overlay",
        .french: "Widget flottant de Codex",
        .portuguese: "Widget flutuante do Codex",
        .portugueseBrazil: "Widget flutuante do Codex"
    ],
    "Smart Forecast Engine": [
        .traditionalChinese: "智慧預測引擎",
        .japanese: "スマート予測エンジン",
        .korean: "스마트 예측 엔진",
        .spanish: "Motor de predicción inteligente",
        .german: "Intelligente Prognose-Engine",
        .french: "Moteur de prévision intelligent",
        .portuguese: "Motor de previsão inteligente",
        .portugueseBrazil: "Motor de previsão inteligente"
    ],
    "Scan Archived Sessions": [
        .traditionalChinese: "包含歸檔會話 (~/.codex/archived_sessions)",
        .japanese: "アーカイブされたセッションを含む",
        .korean: "아카이브된 세션 포함",
        .spanish: "Escanear sesiones archivadas",
        .german: "Archivierte Sitzungen einbeziehen",
        .french: "Inclure les sessions archivées",
        .portuguese: "Incluir sessões arquivadas",
        .portugueseBrazil: "Incluir sessões arquivadas"
    ],
    "Scan Now": [
        .traditionalChinese: "立即掃描",
        .japanese: "今すぐスキャン",
        .korean: "지금 스캔",
        .spanish: "Escanear ahora",
        .german: "Jetzt scannen",
        .french: "Scanner maintenant",
        .portuguese: "Examinar agora",
        .portugueseBrazil: "Escanear agora"
    ],
    "Re-index All": [
        .traditionalChinese: "重新建立索引",
        .japanese: "インデックスを再構築",
        .korean: "인덱스 재구축",
        .spanish: "Reindexar todo",
        .german: "Neu indizieren",
        .french: "Réindexer tout",
        .portuguese: "Reindexar tudo",
        .portugueseBrazil: "Reindexar tudo"
    ],
    "Official rates active": [
        .traditionalChinese: "官方列表價已激活",
        .japanese: "公式レート適用中",
        .korean: "공식 요율 활성화됨",
        .spanish: "Tarifas oficiales activas",
        .german: "Offizielle Tarife aktiv",
        .french: "Tarifs officiels actifs",
        .portuguese: "Taxas oficiais ativas",
        .portugueseBrazil: "Tarifas oficiais ativas"
    ],
    "Local Analytics": [
        .traditionalChinese: "本地用量分析",
        .japanese: "ローカル利用状況分析",
        .korean: "로컬 사용량 분석",
        .spanish: "Analítica local",
        .german: "Lokale Analysen",
        .french: "Analytique locale",
        .portuguese: "Análise local",
        .portugueseBrazil: "Análise local"
    ],
    "Scanning local history": [
        .traditionalChinese: "正在掃描本地記錄",
        .japanese: "ローカル履歴をスキャン中",
        .korean: "로컬 기록 스캔 중",
        .spanish: "Escaneando historial local",
        .german: "Lokalen Verlauf scannen",
        .french: "Analyse de l'historique local",
        .portuguese: "A examinar histórico local",
        .portugueseBrazil: "Escaneando histórico local"
    ],
    "Local analytics disabled": [
        .traditionalChinese: "本地用量分析已停用",
        .japanese: "ローカル分析は無効です",
        .korean: "로컬 분석이 꺼져 있습니다",
        .spanish: "Analítica local desactivada",
        .german: "Lokale Analysen deaktiviert",
        .french: "Analytique locale désactivée",
        .portuguese: "Análise local desativada",
        .portugueseBrazil: "Análise local desativada"
    ],
    "Preparing scan...": [
        .traditionalChinese: "準備掃描…",
        .japanese: "スキャンを準備中...",
        .korean: "스캔 준비 중...",
        .spanish: "Preparando escaneo...",
        .german: "Scan wird vorbereitet...",
        .french: "Préparation de l'analyse...",
        .portuguese: "A preparar análise...",
        .portugueseBrazil: "Preparando escaneamento..."
    ],
    "Scanning Codex session files...": [
        .traditionalChinese: "正在掃描 Codex 會話檔案…",
        .japanese: "Codex セッションファイルをスキャン中...",
        .korean: "Codex 세션 파일 스캔 중...",
        .spanish: "Escaneando archivos de sesión de Codex...",
        .german: "Codex-Sitzungsdateien werden gescannt...",
        .french: "Analyse des fichiers de session Codex...",
        .portuguese: "A examinar ficheiros de sessão Codex...",
        .portugueseBrazil: "Escaneando arquivos de sessão do Codex..."
    ],
    "Resolving session metadata and tree...": [
        .traditionalChinese: "正在解析會話中繼資料與父子關係…",
        .japanese: "セッションメタデータとツリーを解析中...",
        .korean: "세션 메타데이터와 트리 분석 중...",
        .spanish: "Resolviendo metadatos y árbol de sesiones...",
        .german: "Sitzungsmetadaten und Baum werden aufgelöst...",
        .french: "Résolution des métadonnées et de l'arborescence...",
        .portuguese: "A resolver metadados e árvore de sessões...",
        .portugueseBrazil: "Resolvendo metadados e árvore de sessões..."
    ],
    "Processing %d/%d: %@": [
        .traditionalChinese: "正在處理 %d/%d：%@",
        .japanese: "%d/%d を処理中: %@",
        .korean: "%d/%d 처리 중: %@",
        .spanish: "Procesando %d/%d: %@",
        .german: "Verarbeite %d/%d: %@",
        .french: "Traitement %d/%d : %@",
        .portuguese: "A processar %d/%d: %@",
        .portugueseBrazil: "Processando %d/%d: %@"
    ],
    "Import complete": [
        .traditionalChinese: "匯入完成",
        .japanese: "インポート完了",
        .korean: "가져오기 완료",
        .spanish: "Importación completa",
        .german: "Import abgeschlossen",
        .french: "Importation terminée",
        .portuguese: "Importação concluída",
        .portugueseBrazil: "Importação concluída"
    ],
    "Scan complete, indexed %d files, added %d records": [
        .traditionalChinese: "掃描完成，已索引 %d 個檔案，新增 %d 條記錄",
        .japanese: "スキャン完了: %d 件のファイルを索引化、%d 件を追加",
        .korean: "스캔 완료: 파일 %d개 색인, 기록 %d개 추가",
        .spanish: "Escaneo completo: %d archivos indexados, %d registros añadidos",
        .german: "Scan abgeschlossen: %d Dateien indiziert, %d Einträge hinzugefügt",
        .french: "Analyse terminée : %d fichiers indexés, %d enregistrements ajoutés",
        .portuguese: "Análise concluída: %d ficheiros indexados, %d registos adicionados",
        .portugueseBrazil: "Escaneamento concluído: %d arquivos indexados, %d registros adicionados"
    ],
    "Scan failed: %@": [
        .traditionalChinese: "掃描失敗：%@",
        .japanese: "スキャン失敗: %@",
        .korean: "스캔 실패: %@",
        .spanish: "Error de escaneo: %@",
        .german: "Scan fehlgeschlagen: %@",
        .french: "Échec de l'analyse : %@",
        .portuguese: "Falha na análise: %@",
        .portugueseBrazil: "Falha no escaneamento: %@"
    ],
    "Computing metrics...": [
        .traditionalChinese: "正在計算全域指標與趨勢…",
        .japanese: "全体指標とトレンドを計算中...",
        .korean: "전체 지표와 추세 계산 중...",
        .spanish: "Calculando métricas y tendencias...",
        .german: "Metriken und Trends werden berechnet...",
        .french: "Calcul des métriques et tendances...",
        .portuguese: "A calcular métricas e tendências...",
        .portugueseBrazil: "Calculando métricas e tendências..."
    ],
    "Quota Pace": [
        .traditionalChinese: "額度節奏",
        .japanese: "クォータペース",
        .korean: "할당량 속도",
        .spanish: "Ritmo de cuota",
        .german: "Quota-Tempo",
        .french: "Rythme du quota",
        .portuguese: "Ritmo da quota",
        .portugueseBrazil: "Ritmo da cota"
    ],
    "Quota Forecast": [
        .traditionalChinese: "額度預測",
        .japanese: "クォータ予測",
        .korean: "할당량 예측",
        .spanish: "Previsión de cuota",
        .german: "Quota-Prognose",
        .french: "Prévision du quota",
        .portuguese: "Previsão da quota",
        .portugueseBrazil: "Previsão da cota"
    ],
    "At current pace, lasts until reset": [
        .traditionalChinese: "按目前速度，可撐到重置",
        .japanese: "現在のペースならリセットまで持続",
        .korean: "현재 속도라면 재설정까지 지속",
        .spanish: "Al ritmo actual, dura hasta el reinicio",
        .german: "Beim aktuellen Tempo reicht es bis zum Reset",
        .french: "Au rythme actuel, tient jusqu'à la réinitialisation",
        .portuguese: "Ao ritmo atual, dura até repor",
        .portugueseBrazil: "No ritmo atual, dura até redefinir"
    ],
    "At current pace, exhausts in %@": [
        .traditionalChinese: "按目前速度，約 %@ 後耗盡",
        .japanese: "現在のペースでは約 %@ 後に消耗",
        .korean: "현재 속도라면 약 %@ 후 소진",
        .spanish: "Al ritmo actual, se agota en %@",
        .german: "Beim aktuellen Tempo erschöpft in %@",
        .french: "Au rythme actuel, épuisé dans %@",
        .portuguese: "Ao ritmo atual, esgota em %@",
        .portugueseBrazil: "No ritmo atual, esgota em %@"
    ],
    "Usage is high, still likely lasts until reset": [
        .traditionalChinese: "用量偏快，預計可撐到重置",
        .japanese: "使用量は多めですが、リセットまで持続見込み",
        .korean: "사용량이 빠르지만 재설정까지 지속 예상",
        .spanish: "Uso elevado, probablemente dura hasta el reinicio",
        .german: "Hohe Nutzung, reicht voraussichtlich bis zum Reset",
        .french: "Usage élevé, devrait tenir jusqu'à la réinitialisation",
        .portuguese: "Uso elevado, deve durar até repor",
        .portugueseBrazil: "Uso alto, deve durar até redefinir"
    ],
    "Today": [
        .traditionalChinese: "今日",
        .japanese: "今日",
        .korean: "오늘",
        .spanish: "Hoy",
        .german: "Heute",
        .french: "Aujourd'hui",
        .portuguese: "Hoje",
        .portugueseBrazil: "Hoje"
    ],
    "Last 30 Days": [
        .traditionalChinese: "近 30 天",
        .japanese: "過去 30 日",
        .korean: "최근 30일",
        .spanish: "Últimos 30 días",
        .german: "Letzte 30 Tage",
        .french: "30 derniers jours",
        .portuguese: "Últimos 30 dias",
        .portugueseBrazil: "Últimos 30 dias"
    ],
    "Used per Hour:": [
        .traditionalChinese: "每小時消耗：",
        .japanese: "1時間あたり:",
        .korean: "시간당 사용:",
        .spanish: "Uso por hora:",
        .german: "Pro Stunde:",
        .french: "Par heure :",
        .portuguese: "Por hora:",
        .portugueseBrazil: "Por hora:"
    ],
    "Current Speed:": [
        .traditionalChinese: "目前速度：",
        .japanese: "現在の速度:",
        .korean: "현재 속도:",
        .spanish: "Velocidad actual:",
        .german: "Aktuelles Tempo:",
        .french: "Vitesse actuelle :",
        .portuguese: "Velocidade atual:",
        .portugueseBrazil: "Velocidade atual:"
    ],
    "Will run out early": [
        .traditionalChinese: "會提前用盡",
        .japanese: "早めに使い切る見込み",
        .korean: "일찍 소진 예상",
        .spanish: "Se agotará antes",
        .german: "Wird vorzeitig aufgebraucht",
        .french: "S'épuisera avant",
        .portuguese: "Vai esgotar antes",
        .portugueseBrazil: "Vai acabar antes"
    ],
    "Usage is high": [
        .traditionalChinese: "用量偏快",
        .japanese: "使用量が多め",
        .korean: "사용량이 빠름",
        .spanish: "Uso elevado",
        .german: "Hohe Nutzung",
        .french: "Usage élevé",
        .portuguese: "Uso elevado",
        .portugueseBrazil: "Uso alto"
    ],
    "Lasts until reset": [
        .traditionalChinese: "可撐到重置",
        .japanese: "リセットまで持続",
        .korean: "재설정까지 지속",
        .spanish: "Dura hasta el reinicio",
        .german: "Reicht bis zum Reset",
        .french: "Tient jusqu'à la réinitialisation",
        .portuguese: "Dura até repor",
        .portugueseBrazil: "Dura até redefinir"
    ],
    "Usage is light": [
        .traditionalChinese: "用量平穩",
        .japanese: "使用量は軽め",
        .korean: "사용량이 안정적",
        .spanish: "Uso moderado",
        .german: "Geringe Nutzung",
        .french: "Usage modéré",
        .portuguese: "Uso moderado",
        .portugueseBrazil: "Uso leve"
    ],
    "Time Remaining:": [
        .traditionalChinese: "預計還可用：",
        .japanese: "残り時間:",
        .korean: "남은 시간:",
        .spanish: "Tiempo restante:",
        .german: "Verbleibende Zeit:",
        .french: "Temps restant :",
        .portuguese: "Tempo restante:",
        .portugueseBrazil: "Tempo restante:"
    ],
    "Remaining at Reset:": [
        .traditionalChinese: "重置時預計剩餘：",
        .japanese: "リセット時の残量:",
        .korean: "재설정 시 예상 잔여:",
        .spanish: "Restante al reinicio:",
        .german: "Rest beim Reset:",
        .french: "Restant à la réinitialisation :",
        .portuguese: "Restante ao repor:",
        .portugueseBrazil: "Restante ao redefinir:"
    ],
    "Forecast Status:": [
        .traditionalChinese: "預測狀態：",
        .japanese: "予測状態:",
        .korean: "예측 상태:",
        .spanish: "Estado previsto:",
        .german: "Prognosestatus:",
        .french: "État de prévision :",
        .portuguese: "Estado da previsão:",
        .portugueseBrazil: "Estado da previsão:"
    ],
    "About %d d %d h": [
        .traditionalChinese: "約 %d 天 %d 小時",
        .japanese: "約%d日%d時間",
        .korean: "약 %d일 %d시간",
        .spanish: "Unos %d d %d h",
        .german: "Ca. %d T %d Std.",
        .french: "Environ %d j %d h",
        .portuguese: "Cerca de %d d %d h",
        .portugueseBrazil: "Cerca de %d d %d h"
    ],
    "About %d h %d min": [
        .traditionalChinese: "約 %d 小時 %d 分鐘",
        .japanese: "約%d時間%d分",
        .korean: "약 %d시간 %d분",
        .spanish: "Unas %d h %d min",
        .german: "Ca. %d Std. %d Min.",
        .french: "Environ %d h %d min",
        .portuguese: "Cerca de %d h %d min",
        .portugueseBrazil: "Cerca de %d h %d min"
    ],
    "About %d min": [
        .traditionalChinese: "約 %d 分鐘",
        .japanese: "約%d分",
        .korean: "약 %d분",
        .spanish: "Unos %d min",
        .german: "Ca. %d Min.",
        .french: "Environ %d min",
        .portuguese: "Cerca de %d min",
        .portugueseBrazil: "Cerca de %d min"
    ],
    "%d days": [
        .traditionalChinese: "%d 天",
        .japanese: "%d日",
        .korean: "%d일",
        .spanish: "%d días",
        .german: "%d Tage",
        .french: "%d jours",
        .portuguese: "%d dias",
        .portugueseBrazil: "%d dias"
    ],
    "On pace 0% · lasts until reset": [
        .traditionalChinese: "節奏正常 0% · 可撐到重置",
        .japanese: "通常ペース 0% · リセットまで持続",
        .korean: "정상 속도 0% · 재설정까지 지속",
        .spanish: "Ritmo normal 0% · dura hasta el reinicio",
        .german: "Im Plan 0 % · reicht bis zum Reset",
        .french: "Rythme normal 0 % · tient jusqu'à la réinitialisation",
        .portuguese: "Ritmo normal 0% · dura até repor",
        .portugueseBrazil: "Ritmo normal 0% · dura até redefinir"
    ],
    "Over pace %d%% · exhausts in %@": [
        .traditionalChinese: "超出節奏 %d%% · 預計 %@後耗盡",
        .japanese: "ペース超過 %d%% · %@ 後に消耗予定",
        .korean: "속도 초과 %d%% · %@ 후 소진 예상",
        .spanish: "Sobre ritmo %d%% · se agota en %@",
        .german: "Über Tempo %d %% · erschöpft in %@",
        .french: "Au-dessus du rythme %d %% · épuisé dans %@",
        .portuguese: "Acima do ritmo %d%% · esgota em %@",
        .portugueseBrazil: "Acima do ritmo %d%% · esgota em %@"
    ],
    "Above pace %d%% · lasts until reset": [
        .traditionalChinese: "高於節奏 %d%% · 可撐到重置",
        .japanese: "やや速いペース %d%% · リセットまで持続",
        .korean: "다소 빠른 속도 %d%% · 재설정까지 지속",
        .spanish: "Ritmo alto %d%% · dura hasta el reinicio",
        .german: "Über Plan %d %% · reicht bis zum Reset",
        .french: "Rythme élevé %d %% · tient jusqu'à la réinitialisation",
        .portuguese: "Ritmo elevado %d%% · dura até repor",
        .portugueseBrazil: "Ritmo elevado %d%% · dura até redefinir"
    ],
    "On pace %d%% · lasts until reset": [
        .traditionalChinese: "節奏正常 %d%% · 可撐到重置",
        .japanese: "通常ペース %d%% · リセットまで持続",
        .korean: "정상 속도 %d%% · 재설정까지 지속",
        .spanish: "Ritmo normal %d%% · dura hasta el reinicio",
        .german: "Im Plan %d %% · reicht bis zum Reset",
        .french: "Rythme normal %d %% · tient jusqu'à la réinitialisation",
        .portuguese: "Ritmo normal %d%% · dura até repor",
        .portugueseBrazil: "Ritmo normal %d%% · dura até redefinir"
    ],
    "%dd %dh": [
        .traditionalChinese: "%d天%d小時",
        .japanese: "%d日%d時間",
        .korean: "%d일 %d시간",
        .spanish: "%d d %d h",
        .german: "%d T %d Std.",
        .french: "%d j %d h",
        .portuguese: "%d d %d h",
        .portugueseBrazil: "%d d %d h"
    ],
    "%dh %dm": [
        .traditionalChinese: "%d小時%d分",
        .japanese: "%d時間%d分",
        .korean: "%d시간 %d분",
        .spanish: "%d h %d min",
        .german: "%d Std. %d Min.",
        .french: "%d h %d min",
        .portuguese: "%d h %d min",
        .portugueseBrazil: "%d h %d min"
    ],
    "%dm": [
        .traditionalChinese: "%d分鐘",
        .japanese: "%d分",
        .korean: "%d분",
        .spanish: "%d min",
        .german: "%d Min.",
        .french: "%d min",
        .portuguese: "%d min",
        .portugueseBrazil: "%d min"
    ],
    "Ready · Open QuotaLens": [
        .traditionalChinese: "已就緒 · 點擊主視窗查看",
        .japanese: "準備完了 · メイン画面で確認",
        .korean: "준비됨 · 메인 창에서 확인",
        .spanish: "Listo · Abrir QuotaLens",
        .german: "Bereit · QuotaLens öffnen",
        .french: "Prêt · Ouvrir QuotaLens",
        .portuguese: "Pronto · Abrir QuotaLens",
        .portugueseBrazil: "Pronto · Abrir QuotaLens"
    ],
    "Total Tokens": [
        .traditionalChinese: "總消耗 Token",
        .japanese: "合計消費 Token",
        .korean: "총 소비 Token",
        .spanish: "Tokens totales",
        .german: "Tokens gesamt",
        .french: "Tokens totaux",
        .portuguese: "Tokens totais",
        .portugueseBrazil: "Tokens totais"
    ],
    "API Est. Value": [
        .traditionalChinese: "API 估算價值",
        .japanese: "API 換算推定額",
        .korean: "API 추정 가치",
        .spanish: "Valor est. API",
        .german: "Geschätzter API-Wert",
        .french: "Valeur est. API",
        .portuguese: "Valor est. da API",
        .portugueseBrazil: "Valor est. da API"
    ],
    "Cache Hit Rate": [
        .traditionalChinese: "快取命中率",
        .japanese: "キャッシュヒット率",
        .korean: "캐시 히트율",
        .spanish: "Tasa de aciertos de caché",
        .german: "Cache-Trefferquote",
        .french: "Taux de succès du cache",
        .portuguese: "Taxa de acertos na cache",
        .portugueseBrazil: "Taxa de acertos no cache"
    ],
    "Daily Usage": [
        .traditionalChinese: "每日用量",
        .japanese: "日別使用量",
        .korean: "일별 사용량",
        .spanish: "Uso diario",
        .german: "Tägliche Nutzung",
        .french: "Utilisation quotidienne",
        .portuguese: "Uso diário",
        .portugueseBrazil: "Uso diário"
    ],
    "Activity Details": [
        .traditionalChinese: "活躍明細",
        .japanese: "アクティビティ詳細",
        .korean: "활동 상세",
        .spanish: "Detalles de actividad",
        .german: "Aktivitätsdetails",
        .french: "Détails d'activité",
        .portuguese: "Detalhes de atividade",
        .portugueseBrazil: "Detalhes de atividade"
    ],
    "Cost": [
        .traditionalChinese: "費用",
        .japanese: "費用",
        .korean: "비용",
        .spanish: "Coste",
        .german: "Kosten",
        .french: "Coût",
        .portuguese: "Custo",
        .portugueseBrazil: "Custo"
    ],
    "Events": [
        .traditionalChinese: "呼叫",
        .japanese: "イベント",
        .korean: "이벤트",
        .spanish: "Eventos",
        .german: "Ereignisse",
        .french: "Événements",
        .portuguese: "Eventos",
        .portugueseBrazil: "Eventos"
    ],
    "Session Count": [
        .traditionalChinese: "會話",
        .japanese: "セッション",
        .korean: "세션",
        .spanish: "Sesiones",
        .german: "Sitzungen",
        .french: "Sessions",
        .portuguese: "Sessões",
        .portugueseBrazil: "Sessões"
    ],
    "Cache": [
        .traditionalChinese: "快取",
        .japanese: "キャッシュ",
        .korean: "캐시",
        .spanish: "Caché",
        .german: "Cache",
        .french: "Cache",
        .portuguese: "Cache",
        .portugueseBrazil: "Cache"
    ],
    "Tokens": [
        .traditionalChinese: "Token",
        .japanese: "Token",
        .korean: "Token",
        .spanish: "Tokens",
        .german: "Tokens",
        .french: "Tokens",
        .portuguese: "Tokens",
        .portugueseBrazil: "Tokens"
    ],
    "No usage": [
        .traditionalChinese: "暫無用量",
        .japanese: "使用量なし",
        .korean: "사용량 없음",
        .spanish: "Sin uso",
        .german: "Keine Nutzung",
        .french: "Aucune utilisation",
        .portuguese: "Sem uso",
        .portugueseBrazil: "Sem uso"
    ],
    "Total Events": [
        .traditionalChinese: "互動事件總數",
        .japanese: "総イベント数",
        .korean: "총 이벤트 수",
        .spanish: "Eventos totales",
        .german: "Ereignisse gesamt",
        .french: "Événements totaux",
        .portuguese: "Total de eventos",
        .portugueseBrazil: "Total de eventos"
    ],
    "Token Breakdown": [
        .traditionalChinese: "Token 構成比例",
        .japanese: "Token 内訳",
        .korean: "Token 세부 구성",
        .spanish: "Desglose de tokens",
        .german: "Token-Aufschlüsselung",
        .french: "Répartition des tokens",
        .portuguese: "Discriminação de tokens",
        .portugueseBrazil: "Detalhamento de tokens"
    ],
    "Uncached Input": [
        .traditionalChinese: "全新輸入",
        .japanese: "新規入力",
        .korean: "신규 입력",
        .spanish: "Entrada sin caché",
        .german: "Ungecachte Eingabe",
        .french: "Entrée non mise en cache",
        .portuguese: "Entrada sem cache",
        .portugueseBrazil: "Entrada sem cache"
    ],
    "Cached Input": [
        .traditionalChinese: "快取命中輸入",
        .japanese: "キャッシュ入力",
        .korean: "캐시된 입력",
        .spanish: "Entrada en caché",
        .german: "Gecachte Eingabe",
        .french: "Entrée en cache",
        .portuguese: "Entrada em cache",
        .portugueseBrazil: "Entrada em cache"
    ],
    "Standard Output": [
        .traditionalChinese: "常規輸出",
        .japanese: "標準出力",
        .korean: "표준 출력",
        .spanish: "Salida estándar",
        .german: "Standard-Ausgabe",
        .french: "Sortie standard",
        .portuguese: "Saída padrão",
        .portugueseBrazil: "Saída padrão"
    ],
    "Reasoning": [
        .traditionalChinese: "深度推理",
        .japanese: "推論処理",
        .korean: "추론 출력",
        .spanish: "Razonamiento",
        .german: "Schlussfolgerung",
        .french: "Raisonnement",
        .portuguese: "Raciocínio",
        .portugueseBrazil: "Raciocínio"
    ],
    "Model Distribution": [
        .traditionalChinese: "模型使用構成",
        .japanese: "モデル別利用分布",
        .korean: "모델별 사용 분포",
        .spanish: "Distribución por modelo",
        .german: "Modellverteilung",
        .french: "Distribution par modèle",
        .portuguese: "Distribuição por modelo",
        .portugueseBrazil: "Distribuição por modelo"
    ],
    "Show in Finder": [
        .traditionalChinese: "在 Finder 中顯示",
        .japanese: "Finder で表示",
        .korean: "Finder에서 보기",
        .spanish: "Mostrar en Finder",
        .german: "Im Finder anzeigen",
        .french: "Afficher dans le Finder",
        .portuguese: "Mostrar no Finder",
        .portugueseBrazil: "Mostrar no Finder"
    ],
    "Select a session to view details": [
        .traditionalChinese: "請在左側選擇一個會話查看明細",
        .japanese: "左側からセッションを選択して詳細を表示",
        .korean: "왼쪽에서 세션을 선택하여 세부 정보를 확인하세요",
        .spanish: "Selecciona una sesión a la izquierda para ver los detalles",
        .german: "Wählen Sie links eine Sitzung für Details aus",
        .french: "Sélectionnez une session à gauche pour voir les détails",
        .portuguese: "Selecione uma sessão à esquerda para ver os detalhes",
        .portugueseBrazil: "Selecione uma sessão à esquerda para ver os detalhes"
    ],
    "Loading sessions...": [
        .traditionalChinese: "正在載入會話…",
        .japanese: "セッションを読み込み中…",
        .korean: "세션 불러오는 중…",
        .spanish: "Cargando sesiones…",
        .german: "Sitzungen werden geladen…",
        .french: "Chargement des sessions…",
        .portuguese: "A carregar sessões…",
        .portugueseBrazil: "Carregando sessões…"
    ],
    "No sessions found": [
        .traditionalChinese: "未發現會話記錄",
        .japanese: "セッションが見つかりません",
        .korean: "세션 기록을 찾을 수 없습니다",
        .spanish: "No se encontraron sesiones",
        .german: "Keine Sitzungen gefunden",
        .french: "Aucune session trouvée",
        .portuguese: "Nenhuma sessão encontrada",
        .portugueseBrazil: "Nenhuma sessão encontrada"
    ],
    "Loading details...": [
        .traditionalChinese: "正在載入會話明細…",
        .japanese: "詳細を読み込み中…",
        .korean: "세부 정보를 불러오는 중…",
        .spanish: "Cargando detalles…",
        .german: "Details werden geladen…",
        .french: "Chargement des détails…",
        .portuguese: "A carregar detalhes…",
        .portugueseBrazil: "Carregando detalhes…"
    ],
    "Search sessions...": [
        .traditionalChinese: "搜尋會話 / 專案 / 路徑…",
        .japanese: "セッション / プロジェクト / パスを検索…",
        .korean: "세션 / 프로젝트 / 경로 검색…",
        .spanish: "Buscar sesiones / proyectos / rutas…",
        .german: "Sitzungen / Projekte / Pfade suchen…",
        .french: "Rechercher sessions / projets / chemins…",
        .portuguese: "Pesquisar sessões / projetos / caminhos…",
        .portugueseBrazil: "Buscar sessões / projetos / caminhos…"
    ],
    "Event Timeline": [
        .traditionalChinese: "事件明細時間線",
        .japanese: "イベントタイムライン",
        .korean: "이벤트 타임라인",
        .spanish: "Línea de tiempo de eventos",
        .german: "Ereignis-Timeline",
        .french: "Chronologie des événements",
        .portuguese: "Cronologia de eventos",
        .portugueseBrazil: "Linha do tempo de eventos"
    ],
    "Rate Limit Burn Forecast": [
        .traditionalChinese: "伺服器額度耗盡預測",
        .japanese: "クォータ枯渇予測",
        .korean: "할당량 소진 예측",
        .spanish: "Predicción de agotamiento de cuota",
        .german: "Prognose des Quota-Verbrauchs",
        .french: "Prévision d'épuisement du quota",
        .portuguese: "Previsão de esgotamento da quota",
        .portugueseBrazil: "Previsão de esgotamento da cota"
    ],
    "5-Hour Rate Limit Forecast": [
        .traditionalChinese: "5 小時額度預測",
        .japanese: "5時間クォータ予測",
        .korean: "5시간 할당량 예측",
        .spanish: "Predicción de cuota de 5 horas",
        .german: "Prognose des 5-Stunden-Kontingents",
        .french: "Prévision du quota de 5 heures",
        .portuguese: "Previsão da quota de 5 horas",
        .portugueseBrazil: "Previsão da cota de 5 horas"
    ],
    "Weekly Rate Limit Forecast": [
        .traditionalChinese: "每週額度預測",
        .japanese: "週間クォータ予測",
        .korean: "주간 할당량 예측",
        .spanish: "Predicción de cuota semanal",
        .german: "Prognose des Wochenkontingents",
        .french: "Prévision du quota hebdomadaire",
        .portuguese: "Previsão da quota semanal",
        .portugueseBrazil: "Previsão da cota semanal"
    ],
    "Local 7-Day Usage Projection": [
        .traditionalChinese: "本機未來 7 天趨勢估算",
        .japanese: "今後 7 日間のローカル利用予測",
        .korean: "향후 7일 로컬 사용량 추세 예측",
        .spanish: "Proyección local de uso a 7 días",
        .german: "Lokale 7-Tage-Nutzungsprognose",
        .french: "Projection d'usage local sur 7 jours",
        .portuguese: "Projeção local de uso para 7 dias",
        .portugueseBrazil: "Projeção local de uso para 7 dias"
    ],
    "Annual Activity Heatmap": [
        .traditionalChinese: "年度活躍熱力圖 (Activity Heatmap)",
        .japanese: "年間アクティビティヒートマップ",
        .korean: "연간 활동 히트맵",
        .spanish: "Mapa de calor de actividad anual",
        .german: "Jahres-Aktivitäts-Heatmap",
        .french: "Carte thermique d'activité annuelle",
        .portuguese: "Mapa de calor de atividade anual",
        .portugueseBrazil: "Mapa de calor de atividade anual"
    ],
    "Usage Trend": [
        .traditionalChinese: "歷史消耗趨勢",
        .japanese: "利用推移トレンド",
        .korean: "소비 추세",
        .spanish: "Tendencia de consumo",
        .german: "Verbrauchstrend",
        .french: "Tendance d'usage",
        .portuguese: "Tendência de consumo",
        .portugueseBrazil: "Tendência de consumo"
    ],
    "%lldd %lldh %lldm %llds": [
        .traditionalChinese: "%lld天 %lld小時 %lld分 %lld秒",
        .japanese: "%lld日 %lld時間 %lld分 %lld秒",
        .korean: "%lld일 %lld시간 %lld분 %lld초",
        .spanish: "%lldd %lldh %lldm %llds",
        .german: "%lldT %lldStd. %lldMin. %lldSek.",
        .french: "%lldj %lldh %lldmin %llds",
        .portuguese: "%lldd %lldh %lldm %llds",
        .portugueseBrazil: "%lldd %lldh %lldm %llds"
    ],
    "%lldh %lldm %llds": [
        .traditionalChinese: "%lld小時 %lld分 %lld秒",
        .japanese: "%lld時間 %lld分 %lld秒",
        .korean: "%lld시간 %lld분 %lld초",
        .spanish: "%lldh %lldm %llds",
        .german: "%lldStd. %lldMin. %lldSek.",
        .french: "%lldh %lldmin %llds",
        .portuguese: "%lldh %lldm %llds",
        .portugueseBrazil: "%lldh %lldm %llds"
    ],
    "%lldm %llds": [
        .traditionalChinese: "%lld分 %lld秒",
        .japanese: "%lld分 %lld秒",
        .korean: "%lld분 %lld초",
        .spanish: "%lldm %llds",
        .german: "%lldMin. %lldSek.",
        .french: "%lldmin %llds",
        .portuguese: "%lldm %llds",
        .portugueseBrazil: "%lldm %llds"
    ],
    "%llds": [
        .traditionalChinese: "%lld秒",
        .japanese: "%lld秒",
        .korean: "%lld초",
        .spanish: "%llds",
        .german: "%lldSek.",
        .french: "%llds",
        .portuguese: "%llds",
        .portugueseBrazil: "%llds"
    ],
    "Current remaining available quota is %@. Are you sure you want to use a reset card?": [
        .traditionalChinese: "目前剩餘可用額度還有 %@，你確定要使用重置卡嗎？",
        .japanese: "現在の利用可能クォータはまだ %@ 残っています。リセットカードを使用してもよろしいですか？",
        .korean: "현재 사용 가능한 남은 할당량이 %@ 있습니다. 리셋 카드를 사용하시겠습니까?",
        .spanish: "La cuota disponible restante es de %@. ¿Seguro que deseas usar una tarjeta de reinicio?",
        .german: "Die verbleibende verfügbare Quota beträgt %@. Möchten Sie wirklich eine Reset-Karte verwenden?",
        .french: "Le quota disponible restant est de %@. Êtes-vous sûr de vouloir utiliser un pass de réinitialisation ?",
        .portuguese: "A quota disponível restante é de %@. Tem a certeza de que pretende utilizar um cartão de reinício?",
        .portugueseBrazil: "A cota disponível restante é de %@. Tem certeza de que deseja usar um cartão de reinício?"
    ],
    "Natural reset is in %@. Continue using a reset card?": [
        .traditionalChinese: "距離自然重置還剩餘 %@，是否繼續使用重置卡？",
        .japanese: "自然リセットまであと %@ です。リセットカードの使用を続行しますか？",
        .korean: "자동 초기화까지 %@ 남았습니다. 리셋 카드를 계속 사용하시겠습니까?",
        .spanish: "El reinicio natural es en %@. ¿Continuar usando la tarjeta de reinicio?",
        .german: "Der reguläre Reset erfolgt in %@. Möchten Sie die Reset-Karte trotzdem nutzen?",
        .french: "La réinitialisation normale aura lieu dans %@. Continuer à utiliser le pass de réinitialisation ?",
        .portuguese: "O reinício natural é em %@. Pretende continuar a utilizar o cartão de reinício?",
        .portugueseBrazil: "A restauração natural ocorrerá em %@. Deseja continuar usando o cartão de reinício?"
    ],
    "Are you sure you want to use a reset card?": [
        .traditionalChinese: "你確定要使用重置卡嗎？",
        .japanese: "リセットカードを使用してもよろしいですか？",
        .korean: "리셋 카드를 사용하시겠습니까?",
        .spanish: "¿Seguro que deseas usar una tarjeta de reinicio?",
        .german: "Möchten Sie wirklich eine Reset-Karte verwenden?",
        .french: "Êtes-vous sûr de vouloir utiliser un pass de réinitialisation ?",
        .portuguese: "Tem a certeza de que pretende utilizar um cartão de reinício?",
        .portugueseBrazil: "Tem certeza de que deseja usar um cartão de reinício?"
    ],
    "Reset Card Consumption": [
        .traditionalChinese: "重置卡核銷與額度更新",
        .japanese: "リセットカードの適用とクォータ更新",
        .korean: "리셋 카드 사용 및 할당량 갱신",
        .spanish: "Consumo de tarjeta de reinicio y actualización de cuota",
        .german: "Reset-Karten-Verbrauch und Quota-Aktualisierung",
        .french: "Utilisation du pass de réinitialisation et mise à jour du quota",
        .portuguese: "Consumo do cartão de reinício e atualização de quota",
        .portugueseBrazil: "Consumo do cartão de reinício e atualização de cota"
    ],
    "Quota is Still Sufficient": [
        .traditionalChinese: "目前額度仍較充足",
        .japanese: "クォータにはまだ十分な余裕があります",
        .korean: "할당량이 아직 충분합니다",
        .spanish: "La cuota aún es suficiente",
        .german: "Quota ist noch ausreichend",
        .french: "Le quota est encore suffisant",
        .portuguese: "A quota ainda é suficiente",
        .portugueseBrazil: "A cota ainda é suficiente"
    ],
    "Recommend using when quota is low to maximize reset card value.": [
        .traditionalChinese: "建議在額度即將耗盡時使用，以最大化利用重置卡價值。",
        .japanese: "カードの価値を最大限に活かすため、残量が少なくなってからの使用を推奨します。",
        .korean: "리셋 카드의 가치를 극대화하기 위해 할당량이 거의 소진되었을 때 사용하는 것을 권장합니다.",
        .spanish: "Se recomienda usarla cuando la cuota esté baja para maximizar el valor de la tarjeta.",
        .german: "Es wird empfohlen, die Karte bei niedrigem Kontingent zu nutzen, um den maximalen Wert zu erzielen.",
        .french: "Il est conseillé de l'utiliser lorsque le quota est presque épuisé pour maximiser sa valeur.",
        .portuguese: "Recomenda-se utilizar quando a quota estiver baixa para maximizar o valor do cartão.",
        .portugueseBrazil: "Recomenda-se utilizar quando a cota estiver baixa para maximizar o valor do cartão."
    ],
    "Quota is Running Low": [
        .traditionalChinese: "目前額度即將耗盡",
        .japanese: "クォータが間もなく上限に達します",
        .korean: "할당량이 곧 소진됩니다",
        .spanish: "La cuota se está agotando",
        .german: "Quota ist fast aufgebraucht",
        .french: "Le quota est presque épuisé",
        .portuguese: "A quota está quase esgotada",
        .portugueseBrazil: "A cota está quase esgotada"
    ],
    "Using this card will instantly reset the current rate window to 100%.": [
        .traditionalChinese: "使用此重置卡將立即重置目前限制窗口並恢復全部額度。",
        .japanese: "このカードを使用すると、現在の制限ウィンドウが即座にリセットされ、全額利用可能になります。",
        .korean: "이 카드를 사용하면 현재 제한 창이 즉시 초기화되어 전체 할당량이 복구됩니다.",
        .spanish: "Usar esta tarjeta restablecerá instantáneamente la ventana actual al 100%.",
        .german: "Durch die Nutzung dieser Karte wird das aktuelle Zeitfenster sofort auf 100 % zurückgesetzt.",
        .french: "L'utilisation de cette carte réinitialisera instantanément la fenêtre actuelle à 100 %.",
        .portuguese: "Utilizar este cartão irá repor instantaneamente a janela atual a 100%.",
        .portugueseBrazil: "Usar este cartão restaurará instantaneamente a janela atual para 100%."
    ],
    "Dynamic fetching and manual refresh for changelog & license": [
        .traditionalChinese: "更新日誌與開源協議升級為動態網路拉取，每次點開彈窗時自動獲取最新發布內容",
        .japanese: "変更ログとライセンスを動的ネットワーク取得に対応、ダイアログ表示時に最新情報を自動更新",
        .korean: "변경 로그와 라이선스를 동적 네트워크 조회로 개선하여 팝업을 열 때마다 최신 내용을 자동 수신",
        .spanish: "Obtención dinámica del registro de cambios y la licencia en cada apertura con actualización manual.",
        .german: "Dynamisches Nachladen von Changelog und Lizenz beim Öffnen mit manueller Aktualisierung.",
        .french: "Chargement dynamique des notes de version et de la licence à chaque ouverture avec actualisation manuelle.",
        .portuguese: "Obtenção dinâmica do registo de alterações e licença a cada abertura com atualização manual.",
        .portugueseBrazil: "Obtenção dinâmica do histórico de alterações e licença a cada abertura com atualização manual."
    ],
    "Fixed current version matching algorithm to accurately highlight active release": [
        .traditionalChinese: "修復目前版本反白比對邏輯，與目前執行應用程式版本即時保持一致",
        .japanese: "現在のバージョン判定ロジックを修正し、実行中アプリのバージョンを正確に強調表示",
        .korean: "현재 버전 하이라이트 매칭 로직을 수정하여 실행 중인 앱 버전과 실시간 동기화",
        .spanish: "Lógica de coincidencia de versión actual corregida para resaltar con precisión la versión activa.",
        .german: "Versionsabgleich korrigiert, um die aktuell ausgeführte Version präzise hervorzuheben.",
        .french: "Correction de la détection de la version actuelle pour mettre en valeur la version active.",
        .portuguese: "Lógica de correspondência da versão atual corrigida para destacar com precisão a versão ativa.",
        .portugueseBrazil: "Lógica de correspondência da versão atual corrigida para destacar com precisão a versão ativa."
    ],
    "Fetching latest updates...": [
        .traditionalChinese: "正在獲取最新內容...",
        .japanese: "最新情報を取得中...",
        .korean: "최신 정보를 가져오는 중...",
        .spanish: "Obteniendo las últimas actualizaciones...",
        .german: "Neueste Updates werden geladen...",
        .french: "Récupération des dernières mises à jour...",
        .portuguese: "A obter as atualizações mais recentes...",
        .portugueseBrazil: "Obtendo as atualizações mais recentes..."
    ],
    "Performance and stability improvements": [
        .traditionalChinese: "版本效能與穩定性優化",
        .japanese: "パフォーマンスと安定性の向上",
        .korean: "성능 및 안정성 향상",
        .spanish: "Mejoras de rendimiento y estabilidad",
        .german: "Leistungs- und Stabilitätsverbesserungen",
        .french: "Améliorations des performances et de la stabilité",
        .portuguese: "Melhorias de desempenho e estabilidade",
        .portugueseBrazil: "Melhorias de desempenho e estabilidade"
    ],
    "Daily Budget Pace": [
        .traditionalChinese: "建議日均消耗",
        .japanese: "推奨日別消費ペース",
        .korean: "일일 권장 소비량",
        .spanish: "Ritmo diario recomendado",
        .german: "Empfohlenes Tagesbudget",
        .french: "Rythme quotidien conseillé",
        .portuguese: "Ritmo diário recomendado",
        .portugueseBrazil: "Ritmo diário recomendado"
    ],
    "Hourly Budget Pace": [
        .traditionalChinese: "建議每小時消耗",
        .japanese: "推奨毎時消費ペース",
        .korean: "시간당 권장 소비량",
        .spanish: "Ritmo por hora recomendado",
        .german: "Empfohlenes Stundenbudget",
        .french: "Rythme horaire conseillé",
        .portuguese: "Ritmo horário recomendado",
        .portugueseBrazil: "Ritmo horário recomendado"
    ],
    "hour": [
        .traditionalChinese: "小時",
        .japanese: "時間",
        .korean: "시간",
        .spanish: "hora",
        .german: "Std.",
        .french: "h",
        .portuguese: "hora",
        .portugueseBrazil: "hora"
    ],
    "Used in 5 Hours": [
        .traditionalChinese: "5 小時已用",
        .japanese: "5時間の使用量",
        .korean: "5시간 사용됨",
        .spanish: "Usado en 5 horas",
        .german: "In 5 Std. verwendet",
        .french: "Utilisé sur 5 h",
        .portuguese: "Usado em 5 horas",
        .portugueseBrazil: "Usado em 5 horas"
    ],
    "Available in 5 Hours": [
        .traditionalChinese: "5 小時可用",
        .japanese: "5時間の利用可能分",
        .korean: "5시간 사용 가능",
        .spanish: "Disponible en 5 horas",
        .german: "In 5 Std. verfügbar",
        .french: "Disponible sur 5 h",
        .portuguese: "Disponível em 5 horas",
        .portugueseBrazil: "Disponível em 5 horas"
    ],
    "About %d minutes remaining · Even pace": [
        .traditionalChinese: "剩餘約 %d 分鐘 · 勻速可用",
        .japanese: "残り約 %d 分 · 均等配分",
        .korean: "약 %d분 남음 · 균등",
        .spanish: "Quedan aprox. %d minutos · ritmo uniforme",
        .german: "Noch ca. %d Min. · gleichmäßig",
        .french: "Env. %d min restantes · rythme stable",
        .portuguese: "Restam cerca de %d min · ritmo uniforme",
        .portugueseBrazil: "Restam cerca de %d min · ritmo uniforme"
    ],
    "About %.1f hours remaining · Even pace": [
        .traditionalChinese: "剩餘約 %.1f 小時 · 勻速可用",
        .japanese: "残り約 %.1f 時間 · 均等配分",
        .korean: "약 %.1f시간 남음 · 균등",
        .spanish: "Quedan aprox. %.1f horas · ritmo uniforme",
        .german: "Noch ca. %.1f Std. · gleichmäßig",
        .french: "Env. %.1f h restantes · rythme stable",
        .portuguese: "Restam cerca de %.1f horas · ritmo uniforme",
        .portugueseBrazil: "Restam cerca de %.1f horas · ritmo uniforme"
    ],
    "Paced": [
        .traditionalChinese: "勻速",
        .japanese: "均等",
        .korean: "균등",
        .spanish: "Pausado",
        .german: "Gleichmäßig",
        .french: "Régulier",
        .portuguese: "Uniforme",
        .portugueseBrazil: "Uniforme"
    ],
    "day": [
        .traditionalChinese: "天",
        .japanese: "日",
        .korean: "일",
        .spanish: "día",
        .german: "Tag",
        .french: "j",
        .portuguese: "dia",
        .portugueseBrazil: "dia"
    ],
    "Consume at this pace to fully utilize by reset": [
        .traditionalChinese: "按此速率消耗至週期結束剛好用完",
        .japanese: "このペースで消費すればリセット時に使い切れます",
        .korean: "이 속도로 소비하면 리셋 시점에 딱 맞게 소진됩니다",
        .spanish: "Consumir a este ritmo para agotar justo al reiniciar",
        .german: "In diesem Tempo verbrauchen, um bis zum Reset fertig zu sein",
        .french: "Consommer à ce rythme pour terminer pile au renouvellement",
        .portuguese: "Consumir a este ritmo para terminar no momento do reinício",
        .portugueseBrazil: "Consumir a este ritmo para terminar no momento do reinício"
    ],
    "Cycle ending soon": [
        .traditionalChinese: "週期即將結束",
        .japanese: "サイクル終了間近",
        .korean: "주기 곧 종료",
        .spanish: "Ciclo finalizando",
        .german: "Zyklus endet bald",
        .french: "Fin de cycle imminente",
        .portuguese: "Ciclo a terminar",
        .portugueseBrazil: "Ciclo terminando em breve"
    ],
    "Remaining %.1f days · Even pace": [
        .traditionalChinese: "剩餘 %.1f 天 · 勻速可用",
        .japanese: "残り %.1f 日 · 均等配分",
        .korean: "잔여 %.1f 일 · 균등 가용",
        .spanish: "Restan %.1f días · ritmo uniforme",
        .german: "Noch %.1f Tage · gleichmäßig",
        .french: "%.1f jours restants · rythme stable",
        .portuguese: "Restam %.1f dias · ritmo uniforme",
        .portugueseBrazil: "Restam %.1f dias · ritmo uniforme"
    ],
    "Remaining %d hours · Even pace": [
        .traditionalChinese: "剩餘約 %d 小時 · 勻速可用",
        .japanese: "残り約 %d 時間 · 均等配分",
        .korean: "잔여 약 %d 시간 · 균등 가용",
        .spanish: "Restan aprox. %d horas · ritmo uniforme",
        .german: "Noch ca. %d Std. · gleichmäßig",
        .french: "Env. %d heures restantes · rythme stable",
        .portuguese: "Restam cerca de %d horas · ritmo uniforme",
        .portugueseBrazil: "Restam cerca de %d horas · ritmo uniforme"
    ],
    "Removed build count and section number tags across overview and settings": [
        .traditionalChinese: "移除組建次數顯示，並去除概覽與設定頁面的分塊序號徽章",
        .japanese: "ビルド回数の表示を削除し、概要と設定画面のセクション番号バッジを非表示化",
        .korean: "빌드 횟수 표시를 제거하고 개요 및 설정 페이지의 섹션 번호 배지 삭제",
        .spanish: "Eliminación del número de compilación y las etiquetas numeradas de secciones.",
        .german: "Build-Nummer und Abschnittsnummern in Übersicht und Einstellungen entfernt.",
        .french: "Suppression du numéro de build et des badges de section dans Aperçu et Réglages.",
        .portuguese: "Remoção do número de build e das etiquetas de secção no resumo e definições.",
        .portugueseBrazil: "Remoção do número de build e das etiquetas de seção no resumo e ajustes."
    ],
    "In-app scrollable dialogs for changelog and license with one-click copy support": [
        .traditionalChinese: "更新日誌與開源協議採用應用內可滾動彈窗展示，並支援一鍵複製",
        .japanese: "更新履歴とライセンスをアプリ内スクロールダイアログで表示、ワンクリックコピー対応",
        .korean: "변경 로그와 라이선스를 앱 내 스크롤 가능한 대화상자로 표시하고 원클릭 복사 지원",
        .spanish: "Cuadros de diálogo desplazables para el registro de cambios y la licencia con copia rápida.",
        .german: "Scrollbare In-App-Dialoge für Changelog und Lizenz mit Ein-Klick-Kopieren.",
        .french: "Fenêtres modales défilables pour le changelog et la licence avec copie en un clic.",
        .portuguese: "Janelas modais deslocáveis para o registo de alterações e licença com cópia rápida.",
        .portugueseBrazil: "Janelas modais roláveis para o histórico de alterações e licença com cópia rápida."
    ],
    "Refined card spacing and visual aesthetics": [
        .traditionalChinese: "進一步優化全息卡片間距與介面精緻度",
        .japanese: "カードの余白と全体的な視覚デザインをさらに洗練",
        .korean: "카드 간격 및 전반적인 인터페이스 디자인 완성도 개선",
        .spanish: "Espaciado de tarjetas y estética visual mejorados.",
        .german: "Kartenabstände und visuelle Ästhetik weiter verfeinert.",
        .french: "Espacement des cartes et esthétique visuelle affinés.",
        .portuguese: "Espaçamento de cartões e estética visual aprimorados.",
        .portugueseBrazil: "Espaçamento de cartões e estética visual aprimorados."
    ],
    "Close": [
        .traditionalChinese: "關閉",
        .japanese: "閉じる",
        .korean: "닫기",
        .spanish: "Cerrar",
        .german: "Schließen",
        .french: "Fermer",
        .portuguese: "Fechar",
        .portugueseBrazil: "Fechar"
    ],
    "Copy License": [
        .traditionalChinese: "複製協議",
        .japanese: "ライセンスをコピー",
        .korean: "라이선스 복사",
        .spanish: "Copiar licencia",
        .german: "Lizenz kopieren",
        .french: "Copier la licence",
        .portuguese: "Copiar licença",
        .portugueseBrazil: "Copiar licença"
    ],
    "Release history and changelog": [
        .traditionalChinese: "版本發布歷史與更新日誌",
        .japanese: "リリース履歴と変更ログ",
        .korean: "릴리스 내역 및 변경 로그",
        .spanish: "Historial de versiones y registro de cambios",
        .german: "Versionsverlauf und Änderungsprotokoll",
        .french: "Historique des versions et notes de version",
        .portuguese: "Histórico de versões e registo de alterações",
        .portugueseBrazil: "Histórico de versões e histórico de alterações"
    ],
    "Open Source License (Apache License 2.0)": [
        .traditionalChinese: "開源許可證 (Apache License 2.0)",
        .japanese: "オープンソースライセンス (Apache License 2.0)",
        .korean: "오픈 소스 라이선스 (Apache License 2.0)",
        .spanish: "Licencia de código abierto (Apache License 2.0)",
        .german: "Open-Source-Lizenz (Apache License 2.0)",
        .french: "Licence open source (Apache License 2.0)",
        .portuguese: "Licença de código aberto (Apache License 2.0)",
        .portugueseBrazil: "Licença de código aberto (Apache License 2.0)"
    ],
    "Current Version": [
        .traditionalChinese: "目前版本",
        .japanese: "現在のバージョン",
        .korean: "현재 버전",
        .spanish: "Versión actual",
        .german: "Aktuelle Version",
        .french: "Version actuelle",
        .portuguese: "Versão atual",
        .portugueseBrazil: "Versão atual"
    ],
    "About QuotaLens": [
        .traditionalChinese: "關於 QuotaLens",
        .japanese: "QuotaLens について",
        .korean: "QuotaLens 정보",
        .spanish: "Acerca de QuotaLens",
        .german: "Über QuotaLens",
        .french: "À propos de QuotaLens",
        .portuguese: "Sobre o QuotaLens",
        .portugueseBrazil: "Sobre o QuotaLens"
    ],
    "Quota and usage insights for Codex, Claude, and Antigravity on macOS.": [
        .traditionalChinese: "在 macOS 上統一掌握 Codex、Claude 與 Antigravity 的額度和用量",
        .japanese: "macOS で Codex、Claude、Antigravity のクォータと使用状況をまとめて把握",
        .korean: "macOS에서 Codex, Claude 및 Antigravity 할당량과 사용량을 한눈에 확인",
        .spanish: "Cuotas y uso de Codex, Claude y Antigravity en macOS.",
        .german: "Kontingente und Nutzung von Codex, Claude und Antigravity auf macOS.",
        .french: "Quotas et utilisation de Codex, Claude et Antigravity sur macOS.",
        .portuguese: "Quotas e utilização do Codex, Claude e Antigravity no macOS.",
        .portugueseBrazil: "Cotas e uso do Codex, Claude e Antigravity no macOS."
    ],
    "Build": [
        .traditionalChinese: "組建",
        .japanese: "ビルド",
        .korean: "빌드",
        .spanish: "Compilación",
        .german: "Build",
        .french: "Build",
        .portuguese: "Build",
        .portugueseBrazil: "Build"
    ],
    "Changelog": [
        .traditionalChinese: "更新日誌",
        .japanese: "更新履歴",
        .korean: "변경 로그",
        .spanish: "Registro de cambios",
        .german: "Änderungsprotokoll",
        .french: "Notes de version",
        .portuguese: "Registo de alterações",
        .portugueseBrazil: "Histórico de alterações"
    ],
    "Feedback": [
        .traditionalChinese: "問題反饋",
        .japanese: "フィードバック",
        .korean: "피드백",
        .spanish: "Comentarios",
        .german: "Feedback",
        .french: "Commentaires",
        .portuguese: "Comentários",
        .portugueseBrazil: "Feedback"
    ],
    "License": [
        .traditionalChinese: "開源協議",
        .japanese: "ライセンス",
        .korean: "라이선스",
        .spanish: "Licencia",
        .german: "Lizenz",
        .french: "Licence",
        .portuguese: "Licença",
        .portugueseBrazil: "Licença"
    ],
    "Updates & Maintenance": [
        .traditionalChinese: "線上升級與維護",
        .japanese: "オンライン更新と保守",
        .korean: "온라인 업데이트 및 유지 관리",
        .spanish: "Actualizaciones y mantenimiento",
        .german: "Online-Updates & Wartung",
        .french: "Mises à jour et maintenance",
        .portuguese: "Atualizações e manutenção",
        .portugueseBrazil: "Atualizações e manutenção"
    ],
    "Checking": [
        .traditionalChinese: "檢查中",
        .japanese: "確認中",
        .korean: "확인 중",
        .spanish: "Comprobando",
        .german: "Wird geprüft",
        .french: "Vérification",
        .portuguese: "A verificar",
        .portugueseBrazil: "Verificando"
    ],
    "Last Checked": [
        .traditionalChinese: "上次檢查時間",
        .japanese: "最終確認日時",
        .korean: "마지막 확인 시간",
        .spanish: "Última comprobación",
        .german: "Zuletzt gesucht",
        .french: "Dernière vérification",
        .portuguese: "Última verificação",
        .portugueseBrazil: "Última verificação"
    ],
    "Automatic Check": [
        .traditionalChinese: "自動檢查更新",
        .japanese: "自動更新確認",
        .korean: "자동 업데이트 확인",
        .spanish: "Comprobación automática",
        .german: "Automatisch suchen",
        .french: "Recherche automatique",
        .portuguese: "Verificação automática",
        .portugueseBrazil: "Verificação automática"
    ],
    "Check for updates periodically in background": [
        .traditionalChinese: "背景定期檢查新版本並提醒",
        .japanese: "バックグラウンドで定期的にアップデートを確認",
        .korean: "백그라운드에서 주기적으로 업데이트를 확인하고 알림",
        .spanish: "Buscar actualizaciones periódicamente en segundo plano",
        .german: "Regelmäßig im Hintergrund nach Updates suchen",
        .french: "Rechercher régulièrement des mises à jour en arrière-plan",
        .portuguese: "Verificar atualizações periodicamente em segundo plano",
        .portugueseBrazil: "Verificar atualizações periodicamente em segundo plano"
    ],
    "Automatic Download": [
        .traditionalChinese: "自動下載更新",
        .japanese: "自動ダウンロード",
        .korean: "자동 다운로드",
        .spanish: "Descarga automática",
        .german: "Automatisch laden",
        .french: "Téléchargement automatique",
        .portuguese: "Transferência automática",
        .portugueseBrazil: "Download automático"
    ],
    "Download new versions automatically in background": [
        .traditionalChinese: "發現新版本時在背景靜默下載",
        .japanese: "新しいバージョンをバックグラウンドで自動取得",
        .korean: "새 버전 발견 시 백그라운드에서 자동 다운로드",
        .spanish: "Descargar nuevas versiones automáticamente en segundo plano",
        .german: "Neue Versionen automatisch im Hintergrund laden",
        .french: "Télécharger automatiquement les versions en arrière-plan",
        .portuguese: "Transferir novas versões automaticamente em segundo plano",
        .portugueseBrazil: "Baixar novas versões automaticamente em segundo plano"
    ],
    "Key Features": [
        .traditionalChinese: "核心特性",
        .japanese: "主な機能",
        .korean: "핵심 기능",
        .spanish: "Funciones principales",
        .german: "Hauptfunktionen",
        .french: "Fonctionnalités clés",
        .portuguese: "Principais funcionalidades",
        .portugueseBrazil: "Principais recursos"
    ],
    "Cross-Tool Quota Overview": [
        .traditionalChinese: "跨工具額度總覽",
        .japanese: "ツール横断クォータ概要",
        .korean: "도구 통합 할당량 개요",
        .spanish: "Resumen de cuotas entre herramientas",
        .german: "Toolübergreifende Kontingentübersicht",
        .french: "Vue d’ensemble des quotas",
        .portuguese: "Visão geral de quotas entre ferramentas",
        .portugueseBrazil: "Visão geral de cotas entre ferramentas"
    ],
    "See multi-window and model quotas for Codex, Claude, and Antigravity.": [
        .traditionalChinese: "統一查看 Codex、Claude 與 Antigravity 的多週期及模型額度",
        .japanese: "Codex、Claude、Antigravity の複数期間とモデル別クォータをまとめて確認。",
        .korean: "Codex, Claude 및 Antigravity의 다중 주기 및 모델별 할당량을 한눈에 확인하세요.",
        .spanish: "Consulta cuotas por periodo y modelo de Codex, Claude y Antigravity.",
        .german: "Kontingente nach Zeitraum und Modell für Codex, Claude und Antigravity anzeigen.",
        .french: "Consultez les quotas par période et par modèle de Codex, Claude et Antigravity.",
        .portuguese: "Consulte quotas por período e modelo do Codex, Claude e Antigravity.",
        .portugueseBrazil: "Veja cotas por período e modelo do Codex, Claude e Antigravity."
    ],
    "Usage & Activity Analytics": [
        .traditionalChinese: "用量與活動分析",
        .japanese: "使用量とアクティビティ分析",
        .korean: "사용량 및 활동 분석",
        .spanish: "Análisis de uso y actividad",
        .german: "Nutzungs- und Aktivitätsanalyse",
        .french: "Analyse de l’utilisation et de l’activité",
        .portuguese: "Análise de utilização e atividade",
        .portugueseBrazil: "Análise de uso e atividade"
    ],
    "Explore sessions, tokens, model mix, task trends, and project activity.": [
        .traditionalChinese: "彙整工作階段、Token、模型構成、任務趨勢與專案活動",
        .japanese: "セッション、トークン、モデル構成、タスク傾向、プロジェクト活動を分析。",
        .korean: "세션, 토큰, 모델 구성, 작업 추세 및 프로젝트 활동을 분석하세요.",
        .spanish: "Analiza sesiones, tokens, modelos, tendencias de tareas y actividad de proyectos.",
        .german: "Sessions, Token, Modellmix, Aufgabentrends und Projektaktivität auswerten.",
        .french: "Analysez les sessions, tokens, modèles, tendances des tâches et activités des projets.",
        .portuguese: "Analise sessões, tokens, modelos, tendências de tarefas e atividade de projetos.",
        .portugueseBrazil: "Analise sessões, tokens, modelos, tendências de tarefas e atividade de projetos."
    ],
    "Pace & Recovery Forecasts": [
        .traditionalChinese: "節奏與恢復預測",
        .japanese: "ペースと回復予測",
        .korean: "사용 속도 및 회복 예측",
        .spanish: "Ritmo y previsiones de recuperación",
        .german: "Tempo- und Erholungsprognosen",
        .french: "Rythme et prévisions de récupération",
        .portuguese: "Ritmo e previsões de recuperação",
        .portugueseBrazil: "Ritmo e previsões de recuperação"
    ],
    "Forecast quota runout and resets from recent trends, with practical pace guidance.": [
        .traditionalChinese: "根據近期趨勢預測額度耗盡與重置，並提供實用的節奏建議",
        .japanese: "最近の傾向からクォータの使い切りとリセットを予測し、実用的なペースの目安を提示。",
        .korean: "최근 추세로 할당량 소진과 재설정을 예측하고 실용적인 사용 속도 지침을 제공합니다.",
        .spanish: "Prevé el agotamiento y los reinicios según tendencias recientes y ofrece una guía de ritmo.",
        .german: "Prognostiziert Verbrauch und Zurücksetzungen aus aktuellen Trends und gibt Tempoempfehlungen.",
        .french: "Prévoyez l’épuisement et les réinitialisations selon les tendances récentes, avec des conseils de rythme.",
        .portuguese: "Preveja o esgotamento e as reposições com base nas tendências recentes e receba orientações de ritmo.",
        .portugueseBrazil: "Preveja o esgotamento e as redefinições com base nas tendências recentes e receba orientações de ritmo."
    ],
    "Context-Aware Overlays": [
        .traditionalChinese: "智慧視窗掛件",
        .japanese: "状況連動オーバーレイ",
        .korean: "상황 인식 창 오버레이",
        .spanish: "Superposiciones sensibles al contexto",
        .german: "Kontextabhängige Overlays",
        .french: "Superpositions adaptées au contexte",
        .portuguese: "Sobreposições sensíveis ao contexto",
        .portugueseBrazil: "Sobreposições sensíveis ao contexto"
    ],
    "Follow the foreground Codex, Claude, or Antigravity window automatically.": [
        .traditionalChinese: "隨前台 Codex、Claude 或 Antigravity 自動切換並貼靠視窗",
        .japanese: "前面にある Codex、Claude、Antigravity のウインドウへ自動的に追従。",
        .korean: "전면의 Codex, Claude 또는 Antigravity 창을 자동으로 따라갑니다.",
        .spanish: "Sigue automáticamente la ventana activa de Codex, Claude o Antigravity.",
        .german: "Folgt automatisch dem aktiven Fenster von Codex, Claude oder Antigravity.",
        .french: "Suit automatiquement la fenêtre active de Codex, Claude ou Antigravity.",
        .portuguese: "Acompanha automaticamente a janela ativa do Codex, Claude ou Antigravity.",
        .portugueseBrazil: "Acompanha automaticamente a janela ativa do Codex, Claude ou Antigravity."
    ],
    "Menu Bar Monitoring": [
        .traditionalChinese: "選單列即時監控",
        .japanese: "メニューバー監視",
        .korean: "메뉴 막대 모니터링",
        .spanish: "Supervisión en la barra de menús",
        .german: "Menüleisten-Monitoring",
        .french: "Suivi dans la barre des menus",
        .portuguese: "Monitorização na barra de menus",
        .portugueseBrazil: "Monitoramento na barra de menus"
    ],
    "Keep used or available quota, reset timing, and sync status at a glance.": [
        .traditionalChinese: "常駐顯示已用或可用額度、重置倒數與同步狀態",
        .japanese: "使用済みまたは利用可能なクォータ、リセット時刻、同期状態を常に確認。",
        .korean: "사용 또는 남은 할당량, 재설정 시간 및 동기화 상태를 한눈에 확인하세요.",
        .spanish: "Consulta de un vistazo la cuota usada o disponible, el reinicio y la sincronización.",
        .german: "Verbrauchtes oder verfügbares Kontingent, Resetzeit und Syncstatus auf einen Blick.",
        .french: "Consultez en un coup d’œil le quota utilisé ou disponible, la réinitialisation et la synchronisation.",
        .portuguese: "Consulte rapidamente a quota utilizada ou disponível, a reposição e a sincronização.",
        .portugueseBrazil: "Veja rapidamente a cota usada ou disponível, a redefinição e a sincronização."
    ],
    "Local-First Privacy": [
        .traditionalChinese: "本機優先與隱私",
        .japanese: "ローカル優先のプライバシー",
        .korean: "로컬 우선 개인정보 보호",
        .spanish: "Privacidad local primero",
        .german: "Lokaler Datenschutz",
        .french: "Confidentialité locale",
        .portuguese: "Privacidade com prioridade local",
        .portugueseBrazil: "Privacidade com prioridade local"
    ],
    "Read only enabled tool data and keep analytics on your Mac.": [
        .traditionalChinese: "只讀取已啟用工具的資料，分析結果保存在 Mac 上",
        .japanese: "有効にしたツールのデータだけを読み取り、分析結果は Mac に保存。",
        .korean: "활성화한 도구의 데이터만 읽고 분석 결과는 Mac에 보관합니다.",
        .spanish: "Lee solo los datos de las herramientas activadas y guarda el análisis en tu Mac.",
        .german: "Liest nur Daten aktivierter Tools und speichert Analysen auf deinem Mac.",
        .french: "Lit uniquement les données des outils activés et conserve les analyses sur votre Mac.",
        .portuguese: "Lê apenas os dados das ferramentas ativadas e mantém as análises no Mac.",
        .portugueseBrazil: "Lê apenas os dados das ferramentas ativadas e mantém as análises no Mac."
    ],
    "Designed for macOS · Powered by SwiftUI": [
        .traditionalChinese: "專為 macOS 打造 · 基於 SwiftUI 構建",
        .japanese: "macOS のために設計 · SwiftUI で構築",
        .korean: "macOS 전용 디자인 · SwiftUI 기반 빌드",
        .spanish: "Diseñado para macOS · Creado con SwiftUI",
        .german: "Entwickelt für macOS · Erstellt mit SwiftUI",
        .french: "Conçu pour macOS · Développé avec SwiftUI",
        .portuguese: "Concebido para macOS · Criado com SwiftUI",
        .portugueseBrazil: "Desenvolvido para macOS · Criado com SwiftUI"
    ],
    "Open source under Apache-2.0 License": [
        .traditionalChinese: "遵循 Apache-2.0 開源協議",
        .japanese: "Apache-2.0 ライセンスに基づくオープンソース",
        .korean: "Apache-2.0 라이선스 기반 오픈 소스",
        .spanish: "Código abierto bajo licencia Apache-2.0",
        .german: "Open Source unter der Apache-2.0-Lizenz",
        .french: "Open source sous licence Apache-2.0",
        .portuguese: "Código aberto sob licença Apache-2.0",
        .portugueseBrazil: "Código aberto sob licença Apache-2.0"
    ],
    "%d%% downloaded": [
        .traditionalChinese: "已下載 %d%%",
        .japanese: "%d%% ダウンロード済み",
        .korean: "%d%% 다운로드됨",
        .spanish: "%d%% descargado",
        .german: "%d%% geladen",
        .french: "%d%% téléchargé",
        .portuguese: "%d%% transferido",
        .portugueseBrazil: "%d%% baixado"
    ],
    "%d%% extracted": [
        .traditionalChinese: "已解壓 %d%%",
        .japanese: "%d%% 展開済み",
        .korean: "%d%% 압축 해제됨",
        .spanish: "%d%% extraído",
        .german: "%d%% entpackt",
        .french: "%d%% extrait",
        .portuguese: "%d%% extraído",
        .portugueseBrazil: "%d%% extraído"
    ],
    "Account": [
        .traditionalChinese: "帳號",
        .japanese: "アカウント",
        .korean: "계정",
        .spanish: "Cuenta",
        .german: "Konto",
        .french: "Compte",
        .portuguese: "Conta",
        .portugueseBrazil: "Conta"
    ],
    "A newer QuotaLens is available, but this Mac cannot install it.": [
        .traditionalChinese: "發現新版本，但這台 Mac 無法安裝。",
        .japanese: "新しい QuotaLens がありますが、この Mac にはインストールできません。",
        .korean: "새 QuotaLens 버전이 있지만 이 Mac에는 설치할 수 없습니다.",
        .spanish: "Hay una versión más reciente de QuotaLens, pero este Mac no puede instalarla.",
        .german: "Eine neuere QuotaLens-Version ist verfügbar, kann auf diesem Mac aber nicht installiert werden.",
        .french: "Une version plus récente de QuotaLens est disponible, mais ce Mac ne peut pas l’installer.",
        .portuguese: "Está disponível uma versão mais recente do QuotaLens, mas este Mac não a pode instalar.",
        .portugueseBrazil: "Há uma versão mais recente do QuotaLens, mas este Mac não pode instalá-la."
    ],
    "A new version is available to download and install.": [
        .traditionalChinese: "發現新版本，可以下載並安裝。",
        .japanese: "新しいバージョンをダウンロードしてインストールできます。",
        .korean: "새 버전을 다운로드하여 설치할 수 있습니다.",
        .spanish: "Hay una versión nueva para descargar e instalar.",
        .german: "Eine neue Version kann geladen und installiert werden.",
        .french: "Une nouvelle version peut être téléchargée et installée.",
        .portuguese: "Está disponível uma nova versão para transferir e instalar.",
        .portugueseBrazil: "Há uma nova versão para baixar e instalar."
    ],
    "Appearance & Language": [
        .traditionalChinese: "外觀與語言",
        .japanese: "外観と言語",
        .korean: "외관 및 언어",
        .spanish: "Apariencia e idioma",
        .german: "Darstellung und Sprache",
        .french: "Apparence et langue",
        .portuguese: "Aspeto e idioma",
        .portugueseBrazil: "Aparência e idioma"
    ],
    "Auto-check": [
        .traditionalChinese: "自動檢查",
        .japanese: "自動確認",
        .korean: "자동 확인",
        .spanish: "Comprobación automática",
        .german: "Automatisch suchen",
        .french: "Recherche auto",
        .portuguese: "Verificação automática",
        .portugueseBrazil: "Verificação automática"
    ],
    "Auto-detect Codex": [
        .traditionalChinese: "自動偵測 Codex",
        .japanese: "Codex を自動検出",
        .korean: "Codex 자동 감지",
        .spanish: "Detectar Codex automáticamente",
        .german: "Codex automatisch erkennen",
        .french: "Détecter Codex automatiquement",
        .portuguese: "Detetar Codex automaticamente",
        .portugueseBrazil: "Detectar Codex automaticamente"
    ],
    "Auto-download": [
        .traditionalChinese: "自動下載",
        .japanese: "自動ダウンロード",
        .korean: "자동 다운로드",
        .spanish: "Descarga automática",
        .german: "Automatisch laden",
        .french: "Téléchargement auto",
        .portuguese: "Transferência automática",
        .portugueseBrazil: "Download automático"
    ],
    "Automatic and manual quota refresh": [
        .traditionalChinese: "自動刷新與手動同步額度",
        .japanese: "クォータの自動更新と手動同期",
        .korean: "할당량 자동 새로고침 및 수동 동기화",
        .spanish: "Actualización automática y manual de cuota",
        .german: "Automatische und manuelle Quota-Aktualisierung",
        .french: "Actualisation automatique et manuelle du quota",
        .portuguese: "Atualização automática e manual da quota",
        .portugueseBrazil: "Atualização automática e manual da cota"
    ],
    "Automatic background refresh": [
        .traditionalChinese: "背景自動刷新",
        .japanese: "バックグラウンド自動更新",
        .korean: "백그라운드 자동 새로고침",
        .spanish: "Actualización automática en segundo plano",
        .german: "Automatische Aktualisierung im Hintergrund",
        .french: "Actualisation automatique en arrière-plan",
        .portuguese: "Atualização automática em segundo plano",
        .portugueseBrazil: "Atualização automática em segundo plano"
    ],
    "Checking...": [
        .traditionalChinese: "正在檢查...",
        .japanese: "確認中...",
        .korean: "확인 중...",
        .spanish: "Comprobando...",
        .german: "Suche läuft...",
        .french: "Recherche...",
        .portuguese: "A verificar...",
        .portugueseBrazil: "Verificando..."
    ],
    "Checking for updates": [
        .traditionalChinese: "正在檢查更新",
        .japanese: "アップデートを確認中",
        .korean: "업데이트 확인 중",
        .spanish: "Buscando actualizaciones",
        .german: "Suche nach Updates",
        .french: "Recherche de mises à jour",
        .portuguese: "A verificar atualizações",
        .portugueseBrazil: "Verificando atualizações"
    ],
    "Check for Updates": [
        .traditionalChinese: "檢查更新",
        .japanese: "アップデートを確認",
        .korean: "업데이트 확인",
        .spanish: "Buscar actualizaciones",
        .german: "Nach Updates suchen",
        .french: "Rechercher les mises à jour",
        .portuguese: "Verificar atualizações",
        .portugueseBrazil: "Verificar atualizações"
    ],
    "Check for Updates...": [
        .traditionalChinese: "檢查更新...",
        .japanese: "アップデートを確認...",
        .korean: "업데이트 확인...",
        .spanish: "Buscar actualizaciones...",
        .german: "Nach Updates suchen...",
        .french: "Rechercher les mises à jour...",
        .portuguese: "Verificar atualizações...",
        .portugueseBrazil: "Verificar atualizações..."
    ],
    "Check manually or keep automatic checks enabled.": [
        .traditionalChinese: "可手動檢查新版本，也可以保持自動檢查。",
        .japanese: "手動で確認するか、自動確認を有効のままにできます。",
        .korean: "수동으로 새 버전을 확인하거나 자동 확인을 유지할 수 있습니다.",
        .spanish: "Puedes comprobar manualmente o mantener las comprobaciones automáticas activadas.",
        .german: "Du kannst manuell suchen oder automatische Suchen aktiviert lassen.",
        .french: "Vous pouvez vérifier manuellement ou garder la recherche automatique activée.",
        .portuguese: "Pode verificar manualmente ou manter as verificações automáticas ativadas.",
        .portugueseBrazil: "Você pode verificar manualmente ou manter as verificações automáticas ativadas."
    ],
    "Check that Codex is installed and signed in.": [
        .traditionalChinese: "請檢查 Codex 是否已安裝並登入。",
        .japanese: "Codex がインストールされ、サインイン済みであることを確認してください。",
        .korean: "Codex가 설치되어 있고 로그인되어 있는지 확인하세요.",
        .spanish: "Comprueba que Codex esté instalado y con sesión iniciada.",
        .german: "Prüfe, ob Codex installiert und angemeldet ist.",
        .french: "Vérifiez que Codex est installé et connecté.",
        .portuguese: "Verifique se o Codex está instalado e com sessão iniciada.",
        .portugueseBrazil: "Verifique se o Codex está instalado e conectado."
    ],
    "Choose Codex": [
        .traditionalChinese: "選擇 Codex",
        .japanese: "Codex を選択",
        .korean: "Codex 선택",
        .spanish: "Elegir Codex",
        .german: "Codex wählen",
        .french: "Choisir Codex",
        .portuguese: "Escolher Codex",
        .portugueseBrazil: "Escolher Codex"
    ],
    "Choose Codex Path": [
        .traditionalChinese: "選擇 Codex 路徑",
        .japanese: "Codex のパスを選択",
        .korean: "Codex 경로 선택",
        .spanish: "Elegir ruta de Codex",
        .german: "Codex-Pfad wählen",
        .french: "Choisir le chemin de Codex",
        .portuguese: "Escolher caminho do Codex",
        .portugueseBrazil: "Escolher caminho do Codex"
    ],
    "Choose the Codex executable.": [
        .traditionalChinese: "請選擇 Codex 可執行檔。",
        .japanese: "Codex 実行ファイルを選択してください。",
        .korean: "Codex 실행 파일을 선택하세요.",
        .spanish: "Elige el ejecutable de Codex.",
        .german: "Wähle die Codex-Datei aus.",
        .french: "Choisissez l’exécutable Codex.",
        .portuguese: "Escolha o executável do Codex.",
        .portugueseBrazil: "Escolha o executável do Codex."
    ],
    "Choose where Codex is installed, or keep auto-detection enabled.": [
        .traditionalChinese: "選擇 Codex 的位置，或保持自動偵測。",
        .japanese: "Codex の場所を選択するか、自動検出を使用します。",
        .korean: "Codex 설치 위치를 선택하거나 자동 감지를 유지하세요.",
        .spanish: "Elige dónde está instalado Codex o conserva la detección automática.",
        .german: "Wähle den Codex-Speicherort oder behalte die automatische Erkennung bei.",
        .french: "Choisissez l’emplacement de Codex ou gardez la détection automatique.",
        .portuguese: "Escolha onde o Codex está instalado ou mantenha a deteção automática.",
        .portugueseBrazil: "Escolha onde o Codex está instalado ou mantenha a detecção automática."
    ],
    "Codex exited unexpectedly (code %d)": [
        .traditionalChinese: "Codex 意外結束（代碼 %d）",
        .japanese: "Codex が予期せず終了しました（コード %d）",
        .korean: "Codex가 예기치 않게 종료되었습니다(코드 %d).",
        .spanish: "Codex se cerró inesperadamente (código %d)",
        .german: "Codex wurde unerwartet beendet (Code %d)",
        .french: "Codex s’est fermé de façon inattendue (code %d)",
        .portuguese: "O Codex fechou inesperadamente (código %d)",
        .portugueseBrazil: "O Codex fechou inesperadamente (código %d)"
    ],
    "Codex Path": [
        .traditionalChinese: "Codex 路徑",
        .japanese: "Codex パス",
        .korean: "Codex 경로",
        .spanish: "Ruta de Codex",
        .german: "Codex-Pfad",
        .french: "Chemin de Codex",
        .portuguese: "Caminho do Codex",
        .portugueseBrazil: "Caminho do Codex"
    ],
    "Codex not found": [
        .traditionalChinese: "未找到 Codex",
        .japanese: "Codex が見つかりません",
        .korean: "Codex를 찾을 수 없음",
        .spanish: "Codex no encontrado",
        .german: "Codex nicht gefunden",
        .french: "Codex introuvable",
        .portuguese: "Codex não encontrado",
        .portugueseBrazil: "Codex não encontrado"
    ],
    "Codex was not found": [
        .traditionalChinese: "未找到 Codex",
        .japanese: "Codex が見つかりません",
        .korean: "Codex를 찾을 수 없습니다",
        .spanish: "No se encontró Codex",
        .german: "Codex wurde nicht gefunden",
        .french: "Codex est introuvable",
        .portuguese: "O Codex não foi encontrado",
        .portugueseBrazil: "O Codex não foi encontrado"
    ],
    "Codex was not found. Choose its location in Settings or install Codex.": [
        .traditionalChinese: "未找到 Codex，請在設定中選擇位置或安裝 Codex。",
        .japanese: "Codex が見つかりません。設定で場所を選択するか、Codex をインストールしてください。",
        .korean: "Codex를 찾을 수 없습니다. 설정에서 위치를 선택하거나 Codex를 설치하세요.",
        .spanish: "No se encontró Codex. Elige su ubicación en Ajustes o instala Codex.",
        .german: "Codex wurde nicht gefunden. Wähle den Speicherort in den Einstellungen oder installiere Codex.",
        .french: "Codex est introuvable. Choisissez son emplacement dans les réglages ou installez Codex.",
        .portuguese: "O Codex não foi encontrado. Escolha a localização nas Definições ou instale o Codex.",
        .portugueseBrazil: "O Codex não foi encontrado. Escolha o local nos Ajustes ou instale o Codex."
    ],
    "Connection disconnected": [
        .traditionalChinese: "連接已斷開",
        .japanese: "接続が切断されました",
        .korean: "연결이 끊어졌습니다",
        .spanish: "Conexión desconectada",
        .german: "Verbindung getrennt",
        .french: "Connexion interrompue",
        .portuguese: "Ligação desligada",
        .portugueseBrazil: "Conexão desconectada"
    ],
    "Connection is not running or has disconnected": [
        .traditionalChinese: "連接未啟動或已斷開",
        .japanese: "接続が開始されていないか切断されています",
        .korean: "연결이 시작되지 않았거나 끊어졌습니다",
        .spanish: "La conexión no está activa o se ha desconectado",
        .german: "Die Verbindung läuft nicht oder wurde getrennt",
        .french: "La connexion n’est pas active ou a été interrompue",
        .portuguese: "A ligação não está ativa ou foi desligada",
        .portugueseBrazil: "A conexão não está ativa ou foi desconectada"
    ],
    "Connecting to the update service and comparing versions.": [
        .traditionalChinese: "正在連接更新服務並比較版本。",
        .japanese: "アップデートサービスに接続し、バージョンを比較しています。",
        .korean: "업데이트 서비스에 연결하고 버전을 비교하는 중입니다.",
        .spanish: "Conectando con el servicio de actualizaciones y comparando versiones.",
        .german: "Verbindung zum Updatedienst wird hergestellt und Versionen werden verglichen.",
        .french: "Connexion au service de mise à jour et comparaison des versions.",
        .portuguese: "A ligar ao serviço de atualizações e a comparar versões.",
        .portugueseBrazil: "Conectando ao serviço de atualizações e comparando versões."
    ],
    "Dark": [
        .traditionalChinese: "深色",
        .japanese: "ダーク",
        .korean: "다크",
        .spanish: "Oscuro",
        .german: "Dunkel",
        .french: "Sombre",
        .portuguese: "Escuro",
        .portugueseBrazil: "Escuro"
    ],
    "Data location:": [
        .traditionalChinese: "資料位置：",
        .japanese: "データの場所:",
        .korean: "데이터 위치:",
        .spanish: "Ubicación de datos:",
        .german: "Datenspeicherort:",
        .french: "Emplacement des données :",
        .portuguese: "Localização dos dados:",
        .portugueseBrazil: "Local dos dados:"
    ],
    "Install and sign in to Codex to show quota data.": [
        .traditionalChinese: "安裝並登入 Codex 後會顯示額度。",
        .japanese: "クォータを表示するには Codex をインストールしてサインインしてください。",
        .korean: "할당량을 표시하려면 Codex를 설치하고 로그인하세요.",
        .spanish: "Instala Codex e inicia sesión para mostrar la cuota.",
        .german: "Installiere Codex und melde dich an, um Quota-Daten anzuzeigen.",
        .french: "Installez Codex et connectez-vous pour afficher le quota.",
        .portuguese: "Instale o Codex e inicie sessão para mostrar a quota.",
        .portugueseBrazil: "Instale o Codex e faça login para mostrar a cota."
    ],
    "Download and Install": [
        .traditionalChinese: "下載並安裝",
        .japanese: "ダウンロードしてインストール",
        .korean: "다운로드 및 설치",
        .spanish: "Descargar e instalar",
        .german: "Laden und installieren",
        .french: "Télécharger et installer",
        .portuguese: "Transferir e instalar",
        .portugueseBrazil: "Baixar e instalar"
    ],
    "Downloading the new version. Please wait.": [
        .traditionalChinese: "正在下載新版本，請稍候。",
        .japanese: "新しいバージョンをダウンロードしています。お待ちください。",
        .korean: "새 버전을 다운로드하는 중입니다. 잠시 기다려 주세요.",
        .spanish: "Descargando la nueva versión. Espera un momento.",
        .german: "Die neue Version wird geladen. Bitte warten.",
        .french: "Téléchargement de la nouvelle version. Veuillez patienter.",
        .portuguese: "A transferir a nova versão. Aguarde.",
        .portugueseBrazil: "Baixando a nova versão. Aguarde."
    ],
    "Downloading update": [
        .traditionalChinese: "正在下載更新",
        .japanese: "アップデートをダウンロード中",
        .korean: "업데이트 다운로드 중",
        .spanish: "Descargando actualización",
        .german: "Update wird geladen",
        .french: "Téléchargement de la mise à jour",
        .portuguese: "A transferir atualização",
        .portugueseBrazil: "Baixando atualização"
    ],
    "Enabled": [
        .traditionalChinese: "已啟用",
        .japanese: "有効",
        .korean: "사용 중",
        .spanish: "Activado",
        .german: "Aktiviert",
        .french: "Activé",
        .portuguese: "Ativado",
        .portugueseBrazil: "Ativado"
    ],
    "Enable": [
        .traditionalChinese: "啟用",
        .japanese: "有効にする",
        .korean: "사용",
        .spanish: "Activar",
        .german: "Aktivieren",
        .french: "Activer",
        .portuguese: "Ativar",
        .portugueseBrazil: "Ativar"
    ],
    "Enable automatic updates": [
        .traditionalChinese: "啟用自動更新",
        .japanese: "自動アップデートを有効にする",
        .korean: "자동 업데이트 사용",
        .spanish: "Activar actualizaciones automáticas",
        .german: "Automatische Updates aktivieren",
        .french: "Activer les mises à jour automatiques",
        .portuguese: "Ativar atualizações automáticas",
        .portugueseBrazil: "Ativar atualizações automáticas"
    ],
    "Extracting update": [
        .traditionalChinese: "正在解壓更新",
        .japanese: "アップデートを展開中",
        .korean: "업데이트 압축 해제 중",
        .spanish: "Extrayendo actualización",
        .german: "Update wird entpackt",
        .french: "Extraction de la mise à jour",
        .portuguese: "A extrair atualização",
        .portugueseBrazil: "Extraindo atualização"
    ],
    "Expired": [
        .traditionalChinese: "已過期",
        .japanese: "期限切れ",
        .korean: "만료됨",
        .spanish: "Caducado",
        .german: "Abgelaufen",
        .french: "Expiré",
        .portuguese: "Expirado",
        .portugueseBrazil: "Expirado"
    ],
    "Follow the system by default, or choose a fixed language.": [
        .traditionalChinese: "預設跟隨系統，也可以選擇固定語言。",
        .japanese: "既定ではシステムに従い、固定言語も選択できます。",
        .korean: "기본값은 시스템을 따르며, 고정 언어도 선택할 수 있습니다.",
        .spanish: "Sigue el sistema por defecto o elige un idioma fijo.",
        .german: "Standardmäßig dem System folgen oder eine feste Sprache wählen.",
        .french: "Suit le système par défaut, ou choisissez une langue fixe.",
        .portuguese: "Segue o sistema por predefinição, ou escolha um idioma fixo.",
        .portugueseBrazil: "Segue o sistema por padrão, ou escolha um idioma fixo."
    ],
    "Follow the prompts to download and install.": [
        .traditionalChinese: "請按提示完成下載與安裝。",
        .japanese: "案内に従ってダウンロードとインストールを完了してください。",
        .korean: "안내에 따라 다운로드와 설치를 완료하세요.",
        .spanish: "Sigue las indicaciones para descargar e instalar.",
        .german: "Folge den Anweisungen zum Laden und Installieren.",
        .french: "Suivez les instructions pour télécharger et installer.",
        .portuguese: "Siga as instruções para transferir e instalar.",
        .portugueseBrazil: "Siga as instruções para baixar e instalar."
    ],
    "In-app online updates": [
        .traditionalChinese: "應用程式內線上升級",
        .japanese: "アプリ内オンラインアップデート",
        .korean: "앱 내 온라인 업데이트",
        .spanish: "Actualizaciones dentro de la app",
        .german: "Updates in der App",
        .french: "Mises à jour dans l’app",
        .portuguese: "Atualizações dentro da app",
        .portugueseBrazil: "Atualizações dentro do app"
    ],
    "Install and Relaunch": [
        .traditionalChinese: "安裝並重新啟動",
        .japanese: "インストールして再起動",
        .korean: "설치 후 다시 실행",
        .spanish: "Instalar y reiniciar",
        .german: "Installieren und neu starten",
        .french: "Installer et relancer",
        .portuguese: "Instalar e reiniciar",
        .portugueseBrazil: "Instalar e reiniciar"
    ],
    "Install Update": [
        .traditionalChinese: "安裝更新",
        .japanese: "アップデートをインストール",
        .korean: "업데이트 설치",
        .spanish: "Instalar actualización",
        .german: "Update installieren",
        .french: "Installer la mise à jour",
        .portuguese: "Instalar atualização",
        .portugueseBrazil: "Instalar atualização"
    ],
    "Installing the update. The app will relaunch if needed.": [
        .traditionalChinese: "正在安裝更新，必要時會自動重新啟動應用程式。",
        .japanese: "アップデートをインストールしています。必要に応じてアプリを再起動します。",
        .korean: "업데이트를 설치하는 중입니다. 필요하면 앱이 다시 실행됩니다.",
        .spanish: "Instalando la actualización. La app se reiniciará si es necesario.",
        .german: "Das Update wird installiert. Die App startet bei Bedarf neu.",
        .french: "Installation de la mise à jour. L’app se relancera si nécessaire.",
        .portuguese: "A instalar a atualização. A app será reiniciada se necessário.",
        .portugueseBrazil: "Instalando a atualização. O app será reiniciado se necessário."
    ],
    "Installing Update": [
        .traditionalChinese: "正在安裝更新",
        .japanese: "アップデートをインストール中",
        .korean: "업데이트 설치 중",
        .spanish: "Instalando actualización",
        .german: "Update wird installiert",
        .french: "Installation de la mise à jour",
        .portuguese: "A instalar atualização",
        .portugueseBrazil: "Instalando atualização"
    ],
    "Open QuotaLens": [
        .traditionalChinese: "打開 QuotaLens",
        .japanese: "QuotaLens を開く",
        .korean: "QuotaLens 열기",
        .spanish: "Abrir QuotaLens",
        .german: "QuotaLens öffnen",
        .french: "Ouvrir QuotaLens",
        .portuguese: "Abrir QuotaLens",
        .portugueseBrazil: "Abrir QuotaLens"
    ],
    "Later": [
        .traditionalChinese: "稍後",
        .japanese: "後で",
        .korean: "나중에",
        .spanish: "Más tarde",
        .german: "Später",
        .french: "Plus tard",
        .portuguese: "Mais tarde",
        .portugueseBrazil: "Mais tarde"
    ],
    "Last check": [
        .traditionalChinese: "上次檢查",
        .japanese: "前回の確認",
        .korean: "마지막 확인",
        .spanish: "Última comprobación",
        .german: "Letzte Suche",
        .french: "Dernière recherche",
        .portuguese: "Última verificação",
        .portugueseBrazil: "Última verificação"
    ],
    "Local Data": [
        .traditionalChinese: "本機資料",
        .japanese: "ローカルデータ",
        .korean: "로컬 데이터",
        .spanish: "Datos locales",
        .german: "Lokale Daten",
        .french: "Données locales",
        .portuguese: "Dados locais",
        .portugueseBrazil: "Dados locais"
    ],
    "Menu bar mode with optional hidden Dock icon": [
        .traditionalChinese: "選單列常駐模式與隱藏 Dock 圖示",
        .japanese: "Dock アイコン非表示に対応したメニューバーモード",
        .korean: "Dock 아이콘 숨김 옵션이 있는 메뉴 막대 모드",
        .spanish: "Modo de barra de menús con icono del Dock opcional",
        .german: "Menüleistenmodus mit optional ausgeblendetem Dock-Symbol",
        .french: "Mode barre de menus avec icône Dock masquable",
        .portuguese: "Modo de barra de menus com ícone da Dock opcional",
        .portugueseBrazil: "Modo de barra de menus com ícone do Dock opcional"
    ],
    "Never checked": [
        .traditionalChinese: "尚未檢查",
        .japanese: "未確認",
        .korean: "확인한 적 없음",
        .spanish: "Nunca comprobado",
        .german: "Noch nie gesucht",
        .french: "Jamais vérifié",
        .portuguese: "Nunca verificado",
        .portugueseBrazil: "Nunca verificado"
    ],
    "%d reset cards": [
        .traditionalChinese: "%d 張重置卡",
        .japanese: "リセットカード %d枚",
        .korean: "리셋 카드 %d장",
        .spanish: "%d tarjetas de reinicio",
        .german: "%d Reset-Karten",
        .french: "%d cartes de réinitialisation",
        .portuguese: "%d cartões de reposição",
        .portugueseBrazil: "%d cartões de reset"
    ],
    "Availability confirmed; card details are syncing": [
        .traditionalChinese: "後台已確認可用，卡片明細正在同步",
        .japanese: "利用可能であることを確認済みです。カードの詳細を同期中です",
        .korean: "사용 가능 여부가 확인되었습니다. 카드 세부 정보를 동기화하는 중입니다",
        .spanish: "Disponibilidad confirmada; sincronizando los detalles de la tarjeta",
        .german: "Verfügbarkeit bestätigt; Kartendetails werden synchronisiert",
        .french: "Disponibilité confirmée ; synchronisation des détails de la carte",
        .portuguese: "Disponibilidade confirmada; a sincronizar os detalhes do cartão",
        .portugueseBrazil: "Disponibilidade confirmada; sincronizando os detalhes do cartão"
    ],
    "No reset cards reported yet.": [
        .traditionalChinese: "暫無可用重置卡。",
        .japanese: "利用可能なリセットカードはまだありません。",
        .korean: "아직 사용 가능한 리셋 카드가 없습니다.",
        .spanish: "Aún no hay tarjetas de reinicio disponibles.",
        .german: "Noch keine Reset-Karten verfügbar.",
        .french: "Aucune carte de réinitialisation disponible pour le moment.",
        .portuguese: "Ainda não há cartões de reposição disponíveis.",
        .portugueseBrazil: "Ainda não há cartões de redefinição disponíveis."
    ],
    "No update found": [
        .traditionalChinese: "未發現可用更新",
        .japanese: "利用可能なアップデートはありません",
        .korean: "사용 가능한 업데이트 없음",
        .spanish: "No se encontraron actualizaciones",
        .german: "Kein Update gefunden",
        .french: "Aucune mise à jour trouvée",
        .portuguese: "Nenhuma atualização encontrada",
        .portugueseBrazil: "Nenhuma atualização encontrada"
    ],
    "Online updates enabled": [
        .traditionalChinese: "線上升級已啟用",
        .japanese: "オンラインアップデートは有効です",
        .korean: "온라인 업데이트 사용 중",
        .spanish: "Actualizaciones en línea activadas",
        .german: "Online-Updates aktiviert",
        .french: "Mises à jour en ligne activées",
        .portuguese: "Atualizações online ativadas",
        .portugueseBrazil: "Atualizações online ativadas"
    ],
    "Online updates unavailable": [
        .traditionalChinese: "線上升級不可用",
        .japanese: "オンラインアップデートは利用できません",
        .korean: "온라인 업데이트를 사용할 수 없음",
        .spanish: "Actualizaciones en línea no disponibles",
        .german: "Online-Updates nicht verfügbar",
        .french: "Mises à jour en ligne indisponibles",
        .portuguese: "Atualizações online indisponíveis",
        .portugueseBrazil: "Atualizações online indisponíveis"
    ],
    "Plan": [
        .traditionalChinese: "方案",
        .japanese: "プラン",
        .korean: "플랜",
        .spanish: "Plan",
        .german: "Plan",
        .french: "Offre",
        .portuguese: "Plano",
        .portugueseBrazil: "Plano"
    ],
    "Plan:": [
        .traditionalChinese: "方案：",
        .japanese: "プラン:",
        .korean: "플랜:",
        .spanish: "Plan:",
        .german: "Plan:",
        .french: "Offre :",
        .portuguese: "Plano:",
        .portugueseBrazil: "Plano:"
    ],
    "Please wait": [
        .traditionalChinese: "請稍候",
        .japanese: "お待ちください",
        .korean: "잠시만 기다려 주세요",
        .spanish: "Espera",
        .german: "Bitte warten",
        .french: "Veuillez patienter",
        .portuguese: "Aguarde",
        .portugueseBrazil: "Aguarde"
    ],
    "Preferences": [
        .traditionalChinese: "偏好",
        .japanese: "設定",
        .korean: "환경설정",
        .spanish: "Preferencias",
        .german: "Einstellungen",
        .french: "Préférences",
        .portuguese: "Preferências",
        .portugueseBrazil: "Preferências"
    ],
    "Quota": [
        .traditionalChinese: "額度",
        .japanese: "クォータ",
        .korean: "할당량",
        .spanish: "Cuota",
        .german: "Quota",
        .french: "Quota",
        .portuguese: "Quota",
        .portugueseBrazil: "Cota"
    ],
    "Quota data was not available yet": [
        .traditionalChinese: "暫時沒有取得額度資料",
        .japanese: "クォータデータはまだ利用できません",
        .korean: "아직 할당량 데이터를 사용할 수 없습니다",
        .spanish: "Los datos de cuota aún no están disponibles",
        .german: "Quota-Daten sind noch nicht verfügbar",
        .french: "Les données de quota ne sont pas encore disponibles",
        .portuguese: "Os dados de quota ainda não estão disponíveis",
        .portugueseBrazil: "Os dados de cota ainda não estão disponíveis"
    ],
    "Quota data was not available yet. Retrying automatically.": [
        .traditionalChinese: "暫時沒有取得額度，正在自動重試。",
        .japanese: "クォータデータはまだ利用できません。自動で再試行します。",
        .korean: "아직 할당량 데이터를 사용할 수 없습니다. 자동으로 다시 시도합니다.",
        .spanish: "Los datos de cuota aún no están disponibles. Reintentando automáticamente.",
        .german: "Quota-Daten sind noch nicht verfügbar. Automatischer erneuter Versuch läuft.",
        .french: "Les données de quota ne sont pas encore disponibles. Nouvelle tentative automatique.",
        .portuguese: "Os dados de quota ainda não estão disponíveis. A tentar novamente automaticamente.",
        .portugueseBrazil: "Os dados de cota ainda não estão disponíveis. Tentando novamente automaticamente."
    ],
    "Quota Overview": [
        .traditionalChinese: "額度概覽",
        .japanese: "クォータ概要",
        .korean: "할당량 개요",
        .spanish: "Resumen de cuota",
        .german: "Quota-Überblick",
        .french: "Aperçu du quota",
        .portuguese: "Resumo da quota",
        .portugueseBrazil: "Resumo da cota"
    ],
    "Quota usage and remaining quota": [
        .traditionalChinese: "額度使用與剩餘額度",
        .japanese: "クォータ使用量と残量",
        .korean: "할당량 사용량 및 남은 할당량",
        .spanish: "Uso de cuota y cuota restante",
        .german: "Quota-Nutzung und verbleibende Quota",
        .french: "Utilisation et quota restant",
        .portuguese: "Utilização e quota restante",
        .portugueseBrazil: "Uso e cota restante"
    ],
    "QuotaLens can automatically check for and download future updates.": [
        .traditionalChinese: "QuotaLens 可以自動檢查並下載後續更新。",
        .japanese: "QuotaLens は今後のアップデートを自動で確認してダウンロードできます。",
        .korean: "QuotaLens가 향후 업데이트를 자동으로 확인하고 다운로드할 수 있습니다.",
        .spanish: "QuotaLens puede buscar y descargar futuras actualizaciones automáticamente.",
        .german: "QuotaLens kann künftige Updates automatisch suchen und laden.",
        .french: "QuotaLens peut rechercher et télécharger automatiquement les prochaines mises à jour.",
        .portuguese: "O QuotaLens pode verificar e transferir futuras atualizações automaticamente.",
        .portugueseBrazil: "O QuotaLens pode verificar e baixar futuras atualizações automaticamente."
    ],
    "QuotaLens %@ is available.": [
        .traditionalChinese: "QuotaLens %@ 已可下載。",
        .japanese: "QuotaLens %@ が利用可能です。",
        .korean: "QuotaLens %@을 사용할 수 있습니다.",
        .spanish: "QuotaLens %@ está disponible.",
        .german: "QuotaLens %@ ist verfügbar.",
        .french: "QuotaLens %@ est disponible.",
        .portuguese: "QuotaLens %@ está disponível.",
        .portugueseBrazil: "QuotaLens %@ está disponível."
    ],
    "QuotaLens %@ is currently the newest version available.": [
        .traditionalChinese: "QuotaLens %@ 是目前可用的最新版本。",
        .japanese: "QuotaLens %@ は現在利用可能な最新バージョンです。",
        .korean: "QuotaLens %@은 현재 사용 가능한 최신 버전입니다.",
        .spanish: "QuotaLens %@ es actualmente la versión más reciente disponible.",
        .german: "QuotaLens %@ ist derzeit die neueste verfügbare Version.",
        .french: "QuotaLens %@ est actuellement la dernière version disponible.",
        .portuguese: "QuotaLens %@ é atualmente a versão mais recente disponível.",
        .portugueseBrazil: "QuotaLens %@ é atualmente a versão mais recente disponível."
    ],
    "QuotaLens %@ was found, but it was not selected for installation on this Mac.": [
        .traditionalChinese: "檢測到 QuotaLens %@，但這台 Mac 目前無法安裝。",
        .japanese: "QuotaLens %@ が見つかりましたが、この Mac ではインストール対象として選択されませんでした。",
        .korean: "QuotaLens %@이 발견되었지만 이 Mac에서는 설치 대상으로 선택되지 않았습니다.",
        .spanish: "Se encontró QuotaLens %@, pero no se seleccionó para instalarlo en este Mac.",
        .german: "QuotaLens %@ wurde gefunden, aber auf diesem Mac nicht zur Installation ausgewählt.",
        .french: "QuotaLens %@ a été trouvé, mais n’a pas été sélectionné pour l’installation sur ce Mac.",
        .portuguese: "O QuotaLens %@ foi encontrado, mas não foi selecionado para instalação neste Mac.",
        .portugueseBrazil: "O QuotaLens %@ foi encontrado, mas não foi selecionado para instalação neste Mac."
    ],
    "QuotaLens has finished updating.": [
        .traditionalChinese: "QuotaLens 已完成更新。",
        .japanese: "QuotaLens のアップデートが完了しました。",
        .korean: "QuotaLens 업데이트가 완료되었습니다.",
        .spanish: "QuotaLens terminó de actualizarse.",
        .german: "QuotaLens wurde fertig aktualisiert.",
        .french: "QuotaLens a terminé la mise à jour.",
        .portuguese: "O QuotaLens terminou a atualização.",
        .portugueseBrazil: "O QuotaLens terminou a atualização."
    ],
    "QuotaLens has quit and the update is being installed.": [
        .traditionalChinese: "QuotaLens 已退出，正在完成安裝。",
        .japanese: "QuotaLens は終了し、アップデートをインストールしています。",
        .korean: "QuotaLens가 종료되었고 업데이트를 설치하는 중입니다.",
        .spanish: "QuotaLens se cerró y la actualización se está instalando.",
        .german: "QuotaLens wurde beendet und das Update wird installiert.",
        .french: "QuotaLens a quitté et la mise à jour est en cours d’installation.",
        .portuguese: "O QuotaLens foi encerrado e a atualização está a ser instalada.",
        .portugueseBrazil: "O QuotaLens foi encerrado e a atualização está sendo instalada."
    ],
    "QuotaLens has updated and relaunched.": [
        .traditionalChinese: "QuotaLens 已更新並重新啟動。",
        .japanese: "QuotaLens は更新され、再起動しました。",
        .korean: "QuotaLens가 업데이트되고 다시 실행되었습니다.",
        .spanish: "QuotaLens se actualizó y se reinició.",
        .german: "QuotaLens wurde aktualisiert und neu gestartet.",
        .french: "QuotaLens a été mis à jour et relancé.",
        .portuguese: "O QuotaLens foi atualizado e reiniciado.",
        .portugueseBrazil: "O QuotaLens foi atualizado e reiniciado."
    ],
    "Quota refresh failed: %@": [
        .traditionalChinese: "額度刷新失敗：%@",
        .japanese: "クォータの更新に失敗しました: %@",
        .korean: "할당량 새로고침 실패: %@",
        .spanish: "No se pudo actualizar la cuota: %@",
        .german: "Quota-Aktualisierung fehlgeschlagen: %@",
        .french: "Échec de l’actualisation du quota : %@",
        .portuguese: "Falha ao atualizar a quota: %@",
        .portugueseBrazil: "Falha ao atualizar a cota: %@"
    ],
    "Recorded": [
        .traditionalChinese: "已記錄",
        .japanese: "記録済み",
        .korean: "기록됨",
        .spanish: "Registrado",
        .german: "Erfasst",
        .french: "Enregistré",
        .portuguese: "Registado",
        .portugueseBrazil: "Registrado"
    ],
    "Preparing update": [
        .traditionalChinese: "正在準備更新",
        .japanese: "アップデートを準備中",
        .korean: "업데이트 준비 중",
        .spanish: "Preparando actualización",
        .german: "Update wird vorbereitet",
        .french: "Préparation de la mise à jour",
        .portuguese: "A preparar atualização",
        .portugueseBrazil: "Preparando atualização"
    ],
    "Refreshes quota every %@.": [
        .traditionalChinese: "每 %@ 自動刷新額度。",
        .japanese: "%@ ごとにクォータを更新します。",
        .korean: "%@마다 할당량을 새로고침합니다.",
        .spanish: "Actualiza la cuota cada %@.",
        .german: "Aktualisiert die Quota alle %@.",
        .french: "Actualise le quota toutes les %@.",
        .portuguese: "Atualiza a quota a cada %@.",
        .portugueseBrazil: "Atualiza a cota a cada %@."
    ],
    "Resync Data": [
        .traditionalChinese: "重新同步資料",
        .japanese: "データを再同期",
        .korean: "데이터 다시 동기화",
        .spanish: "Resincronizar datos",
        .german: "Daten erneut synchronisieren",
        .french: "Resynchroniser les données",
        .portuguese: "Ressincronizar dados",
        .portugueseBrazil: "Ressincronizar dados"
    ],
    "Show in Menu Bar Only": [
        .traditionalChinese: "僅顯示選單列圖示",
        .japanese: "メニューバーのみに表示",
        .korean: "메뉴 막대에만 표시",
        .spanish: "Mostrar solo en la barra de menús",
        .german: "Nur in der Menüleiste anzeigen",
        .french: "Afficher uniquement dans la barre de menus",
        .portuguese: "Mostrar apenas na barra de menus",
        .portugueseBrazil: "Mostrar apenas na barra de menus"
    ],
    "Sparkle is preparing to download or install the update.": [
        .traditionalChinese: "Sparkle 正在準備下載或安裝更新。",
        .japanese: "Sparkle がアップデートのダウンロードまたはインストールを準備しています。",
        .korean: "Sparkle이 업데이트 다운로드 또는 설치를 준비하고 있습니다.",
        .spanish: "Sparkle está preparando la descarga o instalación de la actualización.",
        .german: "Sparkle bereitet das Laden oder Installieren des Updates vor.",
        .french: "Sparkle prépare le téléchargement ou l’installation de la mise à jour.",
        .portuguese: "O Sparkle está a preparar a transferência ou instalação da atualização.",
        .portugueseBrazil: "O Sparkle está preparando o download ou a instalação da atualização."
    ],
    "Status": [
        .traditionalChinese: "狀態",
        .japanese: "状態",
        .korean: "상태",
        .spanish: "Estado",
        .german: "Status",
        .french: "État",
        .portuguese: "Estado",
        .portugueseBrazil: "Status"
    ],
    "Status: %@": [
        .traditionalChinese: "狀態：%@",
        .japanese: "状態: %@",
        .korean: "상태: %@",
        .spanish: "Estado: %@",
        .german: "Status: %@",
        .french: "État : %@",
        .portuguese: "Estado: %@",
        .portugueseBrazil: "Status: %@"
    ],
    "Sync & Refresh": [
        .traditionalChinese: "同步與刷新",
        .japanese: "同期と更新",
        .korean: "동기화 및 새로고침",
        .spanish: "Sincronización y actualización",
        .german: "Sync und Aktualisierung",
        .french: "Synchronisation et actualisation",
        .portuguese: "Sincronização e atualização",
        .portugueseBrazil: "Sincronização e atualização"
    ],
    "The selected file is not executable. Choose another file.": [
        .traditionalChinese: "所選檔案不可執行，請重新選擇。",
        .japanese: "選択したファイルは実行できません。別のファイルを選択してください。",
        .korean: "선택한 파일을 실행할 수 없습니다. 다른 파일을 선택하세요.",
        .spanish: "El archivo seleccionado no es ejecutable. Elige otro archivo.",
        .german: "Die ausgewählte Datei ist nicht ausführbar. Wähle eine andere Datei.",
        .french: "Le fichier sélectionné n’est pas exécutable. Choisissez un autre fichier.",
        .portuguese: "O ficheiro selecionado não é executável. Escolha outro ficheiro.",
        .portugueseBrazil: "O arquivo selecionado não é executável. Escolha outro arquivo."
    ],
    "This build is not configured for online updates.": [
        .traditionalChinese: "目前版本未設定線上升級。",
        .japanese: "このビルドはオンラインアップデートに対応していません。",
        .korean: "이 빌드는 온라인 업데이트가 설정되어 있지 않습니다.",
        .spanish: "Esta compilación no está configurada para actualizaciones en línea.",
        .german: "Dieser Build ist nicht für Online-Updates konfiguriert.",
        .french: "Cette version n’est pas configurée pour les mises à jour en ligne.",
        .portuguese: "Esta compilação não está configurada para atualizações online.",
        .portugueseBrazil: "Esta compilação não está configurada para atualizações online."
    ],
    "The update has downloaded and is being extracted.": [
        .traditionalChinese: "更新已下載完成，正在解壓。",
        .japanese: "アップデートのダウンロードが完了し、展開しています。",
        .korean: "업데이트 다운로드가 완료되어 압축을 해제하는 중입니다.",
        .spanish: "La actualización se descargó y se está extrayendo.",
        .german: "Das Update wurde geladen und wird entpackt.",
        .french: "La mise à jour est téléchargée et en cours d’extraction.",
        .portuguese: "A atualização foi transferida e está a ser extraída.",
        .portugueseBrazil: "A atualização foi baixada e está sendo extraída."
    ],
    "The update has finished downloading and is ready to install and relaunch QuotaLens.": [
        .traditionalChinese: "更新已下載完成，可以安裝並重新啟動 QuotaLens。",
        .japanese: "アップデートのダウンロードが完了し、QuotaLens をインストールして再起動できます。",
        .korean: "업데이트 다운로드가 완료되어 QuotaLens를 설치하고 다시 실행할 수 있습니다.",
        .spanish: "La actualización terminó de descargarse y está lista para instalarse y reiniciar QuotaLens.",
        .german: "Das Update wurde fertig geladen und kann QuotaLens installieren und neu starten.",
        .french: "La mise à jour est téléchargée et prête à installer puis relancer QuotaLens.",
        .portuguese: "A atualização terminou de ser transferida e está pronta para instalar e reiniciar o QuotaLens.",
        .portugueseBrazil: "A atualização terminou de baixar e está pronta para instalar e reiniciar o QuotaLens."
    ],
    "Subscription details are temporarily unavailable": [
        .traditionalChinese: "暫時無法取得訂閱資訊",
        .japanese: "サブスクリプション情報は一時的に利用できません",
        .korean: "구독 정보를 일시적으로 사용할 수 없습니다",
        .spanish: "Los detalles de la suscripción no están disponibles temporalmente",
        .german: "Abonnementdetails sind vorübergehend nicht verfügbar",
        .french: "Les détails de l’abonnement sont temporairement indisponibles",
        .portuguese: "Os detalhes da subscrição estão temporariamente indisponíveis",
        .portugueseBrazil: "Os detalhes da assinatura estão temporariamente indisponíveis"
    ],
    "Subscription details could not be read": [
        .traditionalChinese: "無法讀取訂閱資訊",
        .japanese: "サブスクリプション情報を読み取れませんでした",
        .korean: "구독 정보를 읽을 수 없습니다",
        .spanish: "No se pudieron leer los detalles de la suscripción",
        .german: "Abonnementdetails konnten nicht gelesen werden",
        .french: "Impossible de lire les détails de l’abonnement",
        .portuguese: "Não foi possível ler os detalhes da subscrição",
        .portugueseBrazil: "Não foi possível ler os detalhes da assinatura"
    ],
    "Timed out while reading quota data": [
        .traditionalChinese: "讀取額度逾時",
        .japanese: "クォータデータの読み取りがタイムアウトしました",
        .korean: "할당량 데이터 읽기 시간이 초과되었습니다",
        .spanish: "Se agotó el tiempo al leer los datos de cuota",
        .german: "Zeitüberschreitung beim Lesen der Quota-Daten",
        .french: "Délai dépassé lors de la lecture du quota",
        .portuguese: "Excedeu o tempo ao ler os dados de quota",
        .portugueseBrazil: "Tempo esgotado ao ler os dados de cota"
    ],
    "Using the current signed-in account": [
        .traditionalChinese: "使用目前登入帳號",
        .japanese: "現在サインイン中のアカウントを使用",
        .korean: "현재 로그인된 계정 사용",
        .spanish: "Usando la cuenta con sesión iniciada",
        .german: "Aktuell angemeldetes Konto verwenden",
        .french: "Utilise le compte actuellement connecté",
        .portuguese: "A utilizar a conta com sessão iniciada",
        .portugueseBrazil: "Usando a conta conectada atual"
    ],
    "Version": [
        .traditionalChinese: "版本",
        .japanese: "バージョン",
        .korean: "버전",
        .spanish: "Versión",
        .german: "Version",
        .french: "Version",
        .portuguese: "Versão",
        .portugueseBrazil: "Versão"
    ],
    "Version information": [
        .traditionalChinese: "版本資訊",
        .japanese: "バージョン情報",
        .korean: "버전 정보",
        .spanish: "Información de versión",
        .german: "Versionsinformationen",
        .french: "Informations de version",
        .portuguese: "Informação da versão",
        .portugueseBrazil: "Informações da versão"
    ],
    "When enabled, QuotaLens only appears in the menu bar.": [
        .traditionalChinese: "開啟後，QuotaLens 只顯示在選單列中。",
        .japanese: "有効にすると、QuotaLens はメニューバーのみに表示されます。",
        .korean: "활성화하면 QuotaLens가 메뉴 막대에만 표시됩니다.",
        .spanish: "Cuando está activado, QuotaLens solo aparece en la barra de menús.",
        .german: "Wenn aktiviert, erscheint QuotaLens nur in der Menüleiste.",
        .french: "Lorsque cette option est activée, QuotaLens apparaît uniquement dans la barre de menus.",
        .portuguese: "Quando ativado, o QuotaLens aparece apenas na barra de menus.",
        .portugueseBrazil: "Quando ativado, o QuotaLens aparece apenas na barra de menus."
    ],
    "QuotaLens could not complete the update check. Try again later.": [
        .traditionalChinese: "QuotaLens 未能完成更新檢查，請稍後再試。",
        .japanese: "QuotaLens はアップデート確認を完了できませんでした。後でもう一度お試しください。",
        .korean: "QuotaLens가 업데이트 확인을 완료하지 못했습니다. 나중에 다시 시도하세요.",
        .spanish: "QuotaLens no pudo completar la comprobación de actualizaciones. Inténtalo de nuevo más tarde.",
        .german: "QuotaLens konnte die Suche nach Updates nicht abschließen. Versuche es später erneut.",
        .french: "QuotaLens n’a pas pu terminer la recherche de mises à jour. Réessayez plus tard.",
        .portuguese: "O QuotaLens não conseguiu concluir a verificação de atualizações. Tente novamente mais tarde.",
        .portugueseBrazil: "O QuotaLens não conseguiu concluir a verificação de atualizações. Tente novamente mais tarde."
    ],
    "The available update does not match this Mac's macOS or hardware requirements.": [
        .traditionalChinese: "可用更新不符合這台 Mac 的 macOS 或硬體要求。",
        .japanese: "利用可能なアップデートは、この Mac の macOS またはハードウェア要件に一致しません。",
        .korean: "사용 가능한 업데이트가 이 Mac의 macOS 또는 하드웨어 요구 사항과 맞지 않습니다.",
        .spanish: "La actualización disponible no coincide con los requisitos de macOS o hardware de este Mac.",
        .german: "Das verfügbare Update passt nicht zu den macOS- oder Hardwareanforderungen dieses Mac.",
        .french: "La mise à jour disponible ne correspond pas aux exigences macOS ou matérielles de ce Mac.",
        .portuguese: "A atualização disponível não corresponde aos requisitos de macOS ou hardware deste Mac.",
        .portugueseBrazil: "A atualização disponível não corresponde aos requisitos de macOS ou hardware deste Mac."
    ],
    "Unable to Check for Updates": [
        .traditionalChinese: "無法檢查更新",
        .japanese: "アップデートを確認できません",
        .korean: "업데이트를 확인할 수 없음",
        .spanish: "No se pueden buscar actualizaciones",
        .german: "Updates konnten nicht gesucht werden",
        .french: "Impossible de rechercher des mises à jour",
        .portuguese: "Não foi possível verificar atualizações",
        .portugueseBrazil: "Não foi possível verificar atualizações"
    ],
    "Unable to start Codex: %@": [
        .traditionalChinese: "無法啟動 Codex：%@",
        .japanese: "Codex を起動できません: %@",
        .korean: "Codex를 시작할 수 없음: %@",
        .spanish: "No se pudo iniciar Codex: %@",
        .german: "Codex konnte nicht gestartet werden: %@",
        .french: "Impossible de démarrer Codex : %@",
        .portuguese: "Não foi possível iniciar o Codex: %@",
        .portugueseBrazil: "Não foi possível iniciar o Codex: %@"
    ],
    "Update available": [
        .traditionalChinese: "發現可用更新",
        .japanese: "アップデートがあります",
        .korean: "업데이트 사용 가능",
        .spanish: "Actualización disponible",
        .german: "Update verfügbar",
        .french: "Mise à jour disponible",
        .portuguese: "Atualização disponível",
        .portugueseBrazil: "Atualização disponível"
    ],
    "Update check failed": [
        .traditionalChinese: "檢查更新失敗",
        .japanese: "アップデート確認に失敗しました",
        .korean: "업데이트 확인 실패",
        .spanish: "No se pudo comprobar la actualización",
        .german: "Updateprüfung fehlgeschlagen",
        .french: "Échec de la recherche de mise à jour",
        .portuguese: "Falha ao verificar atualizações",
        .portugueseBrazil: "Falha ao verificar atualizações"
    ],
    "Update information could not be loaded. Check the network and try again.": [
        .traditionalChinese: "無法讀取更新資訊，請檢查網路後重試。",
        .japanese: "アップデート情報を読み込めませんでした。ネットワークを確認して再試行してください。",
        .korean: "업데이트 정보를 불러올 수 없습니다. 네트워크를 확인한 후 다시 시도하세요.",
        .spanish: "No se pudo cargar la información de actualización. Comprueba la red e inténtalo de nuevo.",
        .german: "Updateinformationen konnten nicht geladen werden. Prüfe das Netzwerk und versuche es erneut.",
        .french: "Impossible de charger les informations de mise à jour. Vérifiez le réseau et réessayez.",
        .portuguese: "Não foi possível carregar as informações de atualização. Verifique a rede e tente novamente.",
        .portugueseBrazil: "Não foi possível carregar as informações de atualização. Verifique a rede e tente novamente."
    ],
    "Update Installed": [
        .traditionalChinese: "更新已安裝",
        .japanese: "アップデートをインストールしました",
        .korean: "업데이트 설치됨",
        .spanish: "Actualización instalada",
        .german: "Update installiert",
        .french: "Mise à jour installée",
        .portuguese: "Atualização instalada",
        .portugueseBrazil: "Atualização instalada"
    ],
    "Update Ready": [
        .traditionalChinese: "更新已準備好",
        .japanese: "アップデートの準備完了",
        .korean: "업데이트 준비 완료",
        .spanish: "Actualización lista",
        .german: "Update bereit",
        .french: "Mise à jour prête",
        .portuguese: "Atualização pronta",
        .portugueseBrazil: "Atualização pronta"
    ],
    "You're up to date!": [
        .traditionalChinese: "您使用的就是最新版本！",
        .japanese: "最新版を使用しています！",
        .korean: "최신 버전을 사용 중입니다!",
        .spanish: "¡Ya tienes la versión más reciente!",
        .german: "Du verwendest die neueste Version!",
        .french: "Vous utilisez la dernière version !",
        .portuguese: "Está a usar a versão mais recente!",
        .portugueseBrazil: "Você está usando a versão mais recente!"
    ],
    "To %@": [
        .traditionalChinese: "變更到 %@",
        .japanese: "%@ へ",
        .korean: "%@로",
        .spanish: "A %@",
        .german: "Zu %@",
        .french: "Vers %@",
        .portuguese: "Para %@",
        .portugueseBrazil: "Para %@"
    ],
    "Local account %@": [
        .traditionalChinese: "本機帳號 %@",
        .japanese: "ローカルアカウント %@",
        .korean: "로컬 계정 %@",
        .spanish: "Cuenta local %@",
        .german: "Lokales Konto %@",
        .french: "Compte local %@",
        .portuguese: "Conta local %@",
        .portugueseBrazil: "Conta local %@"
    ],
    "RPC request timed out: %@": [
        .traditionalChinese: "RPC 請求逾時：%@",
        .japanese: "RPC リクエストがタイムアウトしました: %@",
        .korean: "RPC 요청 시간 초과: %@",
        .spanish: "La solicitud RPC agotó el tiempo: %@",
        .german: "RPC-Anfrage Zeitüberschreitung: %@",
        .french: "Délai RPC dépassé : %@",
        .portuguese: "Pedido RPC excedeu o tempo: %@",
        .portugueseBrazil: "Solicitação RPC expirou: %@"
    ],
    "Failed to start subprocess: %@": [
        .traditionalChinese: "啟動子程序失敗：%@",
        .japanese: "サブプロセスの起動に失敗しました: %@",
        .korean: "하위 프로세스 시작 실패: %@",
        .spanish: "No se pudo iniciar el subproceso: %@",
        .german: "Unterprozess konnte nicht gestartet werden: %@",
        .french: "Échec du lancement du sous-processus : %@",
        .portuguese: "Falha ao iniciar subprocesso: %@",
        .portugueseBrazil: "Falha ao iniciar subprocesso: %@"
    ],
    "codex app-server exited with code %d": [
        .traditionalChinese: "codex app-server 已退出，退出碼 %d",
        .japanese: "codex app-server が終了しました。終了コード %d",
        .korean: "codex app-server가 종료되었습니다. 종료 코드 %d",
        .spanish: "codex app-server salió con código %d",
        .german: "codex app-server wurde mit Code %d beendet",
        .french: "codex app-server s'est arrêté avec le code %d",
        .portuguese: "codex app-server saiu com código %d",
        .portugueseBrazil: "codex app-server saiu com código %d"
    ],
    "Pinned to %@": [
        .traditionalChinese: "固定為 %@",
        .japanese: "%@ に固定",
        .korean: "%@로 고정",
        .spanish: "Fijado a %@",
        .german: "Festgelegt auf %@",
        .french: "Fixé sur %@",
        .portuguese: "Fixado em %@",
        .portugueseBrazil: "Fixado em %@"
    ],
    "Reset Overlay Position": [
        .traditionalChinese: "重設掛件吸附位置",
        .japanese: "ウィジェットの吸着位置をリセット",
        .korean: "위젯 부착 위치 초기화",
        .spanish: "Restablecer posición de superposición",
        .german: "Overlay-Position zurücksetzen",
        .french: "Réinitialiser la position de la superposition",
        .portuguese: "Repor posição da sobreposição",
        .portugueseBrazil: "Redefinir posição da sobreposição"
    ],
    "Locates the Codex window and Help button without reading conversations": [
        .traditionalChinese: "用於識別 Codex 視窗和說明按鈕的位置，不讀取對話內容",
        .japanese: "会話内容を読み取らずに、Codexウインドウとヘルプボタンの位置を特定します",
        .korean: "대화 내용을 읽지 않고 Codex 창과 도움말 버튼의 위치를 찾습니다",
        .spanish: "Localiza la ventana de Codex y el botón de ayuda sin leer las conversaciones",
        .german: "Ermittelt die Position des Codex-Fensters und der Hilfe-Schaltfläche, ohne Unterhaltungen zu lesen",
        .french: "Repère la fenêtre Codex et le bouton d'aide sans lire les conversations",
        .portuguese: "Localiza a janela do Codex e o botão de ajuda sem ler as conversas",
        .portugueseBrazil: "Localiza a janela do Codex e o botão de ajuda sem ler as conversas"
    ],
    "Restore automatic placement inside the Codex window": [
        .traditionalChinese: "恢復掛件在 Codex 視窗中的自動吸附位置",
        .japanese: "Codexウインドウ内の自動配置に戻します",
        .korean: "Codex 창 안의 자동 배치 위치로 복원합니다",
        .spanish: "Restaura la posición automática dentro de la ventana de Codex",
        .german: "Stellt die automatische Position im Codex-Fenster wieder her",
        .french: "Rétablit le placement automatique dans la fenêtre Codex",
        .portuguese: "Restaura a posição automática dentro da janela do Codex",
        .portugueseBrazil: "Restaura a posição automática dentro da janela do Codex"
    ],
    "Reset": [
        .traditionalChinese: "重設",
        .japanese: "リセット",
        .korean: "초기화",
        .spanish: "Restablecer",
        .german: "Zurücksetzen",
        .french: "Réinitialiser",
        .portuguese: "Repor",
        .portugueseBrazil: "Redefinir"
    ],
    "Click to toggle used/available view": [
        .traditionalChinese: "點擊切換已用/可用視角",
        .japanese: "クリックで使用量/残り表示を切り替え",
        .korean: "클릭하여 사용량/잔여량 보기 전환",
        .spanish: "Haz clic para alternar vista de usado/disponible",
        .german: "Klicken, um zwischen Verbraucht/Verfügbar zu wechseln",
        .french: "Cliquer pour basculer la vue utilisé/disponible",
        .portuguese: "Clique para alternar entre usado e disponível",
        .portugueseBrazil: "Clique para alternar entre usado e disponível"
    ]
]

private let translations: [AppLanguage: [String: String]] = [
    .traditionalChinese: [
        "%d seconds short": "%d 秒",
        "%d minutes short": "%d 分鐘",
        "%d minutes %d seconds short": "%d 分 %d 秒",
        "%lld days %lld hours short": "%lld天 %lld小時",
        "%lld hours %lld minutes short": "%lld小時 %lld分鐘",
        "%d available": "%d 張可用",
        "%d available reset card": "%d 張可用重置卡",
        "%d available reset cards": "%d 張可用重置卡",
        "%d days left": "剩餘 %d 天",
        "%@ remaining": "剩餘可用 %@",
        "Auto-detect · %@": "自動偵測 · %@",
        "Changes to %@": "到期變更為 %@",
        "Expires %@": "截止 %@",
        "Every %@": "每 %@",
        "Failed: %@": "設定失敗：%@",
        "Granted %@  ~  Expires %@": "取得 %@  ~  截止 %@",
        "Login item status: %@": "系統登入狀態：%@",
        "Nearest deadline: %@": "最近截止：%@",
        "Next %@": "下次 %@",
        "Reads server quota snapshots every %@.": "每 %@ 讀取一次伺服器額度快照",
        "Server read failed: %@": "伺服器讀取失敗：%@",
        "Sync: %@": "同步：%@",
        "The nearest %@ expires %@": "最近一張 %@ 截止 %@",
        "The nearest %@ expires %@; the subscription ends or changes on %@.": "最近一張 %@ 截止 %@，訂閱將在 %@ 終止或變更。",
        "%@ expires %@. Use it soon.": "%@ 將在 %@ 到期，請及時使用。",
        "%@ expires %@, but the subscription ends or changes on %@. Use it soon.": "%@ 截止 %@，但訂閱將在 %@ 終止或變更，請及時使用。",
        "Using macOS language: %@": "使用 macOS 語言：%@",
        "A reminder will be scheduled automatically after an available reset card is detected.": "讀取到可用重置卡後，將自動安排到期前提醒。",
        "Acknowledged": "已確認",
        "App Server is not running or has disconnected": "App Server 未啟動或已斷開",
        "Appearance & Theme": "外觀與主題偏好",
        "Auto": "自動",
        "Auto-detect codex": "自動偵測 codex",
        "Auto-detect · Search environment for codex": "自動偵測 · 按環境查找 codex",
        "Auto-renews": "自動續費",
        "Auto-resets next cycle": "下周期自動重置",
        "Available This Week": "本週可用",
        "Available:": "可用：",
        "Background auto-refresh monitoring": "背景自動刷新監測",
        "Bound to the current session and live sign-in state": "當前會話綁定 · 始終跟隨真實登入狀態",
        "CLI Binary Path": "命令列程式執行路徑",
        "CLI not installed": "未安裝命令列工具",
        "Cancel": "取消",
        "Cannot choose target": "無法選擇目標",
        "Cannot connect": "無法連接",
        "Changing": "到期變更",
        "Check that the CLI is installed and signed in.": "請檢查命令列工具是否已安裝並登入。",
        "Choose": "選擇",
        "Choose CLI binary target": "選擇命令列程式目標",
        "Choose Codex CLI Executable": "選擇 Codex CLI 可執行檔",
        "Choose a codex CLI executable, or keep auto-detection enabled.": "選擇 codex CLI 可執行檔，或保持自動偵測。",
        "Choose from File...": "從檔案中選擇…",
        "Choose light, dark, or follow the macOS appearance.": "選擇淺色、深色，或跟隨 macOS 外觀。",
        "Choose the codex CLI executable to use for the connection.": "請選擇用於連接的 codex CLI 可執行檔。",
        "Click to toggle used/available view": "點擊切換已用/可用視角",
        "Codex executable not found": "未找到 codex 可執行檔",
        "Codex executable not found. Specify a path in Settings or install Codex CLI.": "未找到 codex 可執行檔，請在設定中指定路徑或安裝 Codex CLI。",
        "Confirm you are signed in, then refresh again shortly.": "請確認已登入帳號，稍後再刷新。",
        "Connected": "已連接",
        "Connecting": "連接中",
        "Copied": "已複製",
        "Copy Path": "複製路徑",
        "Critical": "嚴重告急",
        "Current period:": "當前訂閱週期：",
        "Daily Usage Trend": "每日總用量趨勢",
        "Dark HUD": "深色科技",
        "Dark mode active (click for light)": "當前深色模式（點擊切換為淺色）",
        "Date": "日期",
        "Disconnected": "連接斷開",
        "Ending": "到期終止",
        "Ends at period close": "到期終止訂閱",
        "Engine Dispatch": "引擎調度與通信鏈路",
        "Follow System": "跟隨系統",
        "Follow the system by default, or pin the interface to Chinese or English.": "預設跟隨系統，也可固定為指定語言。",
        "Free": "可用",
        "Healthy reserve": "儲備充沛",
        "Identity Gateway": "帳號與身份閘道",
        "Install and sign in to the Codex CLI to show quota data.": "安裝並登入命令列工具後會顯示額度。",
        "Interface Language": "介面語言",
        "Interface Theme": "介面視覺皮膚",
        "Last 7 Days": "最近 7 日",
        "Launch at Login": "開機自動啟動",
        "Light": "淺色",
        "Light mode active (click for dark)": "當前淺色模式（點擊切換為深色）",
        "Local sign-in credentials not found": "未找到本機登入憑據",
        "Low reserve": "餘量偏低",
        "Manage appearance, account identity, background scheduling, and local data storage.": "管理目前外觀主題、身份閘道、守護程式調度與本機資料核心參數",
        "Menu Bar Mode (Hide Dock Icon)": "常駐選單列模式（隱藏 Dock 圖示）",
        "Missing": "未安裝",
        "Monitor quota usage, reset windows, and model telemetry for the current account.": "即時監測目前帳號額度消耗、重置週期與模型遙測",
        "Nearest reset card is expiring soon": "最近一張重置卡即將到期",
        "Needs action": "等待處理",
        "No account selected": "未選擇帳號",
        "No card to remind": "暫無可提醒重置卡",
        "No cards": "無可用卡",
        "No quota yet": "還沒讀到額度",
        "No trend data": "暫無趨勢資料",
        "Not supported by this app bundle": "目前應用程式包不支援",
        "OK": "知道了",
        "Off": "已關閉",
        "Offline": "未連接",
        "On": "已開啟",
        "Open Console": "打開主控制台",
        "Overview": "概覽",
        "Pending": "待同步",
        "Plan changes at period close": "到期變更訂閱",
        "Primary Quota Channel": "核心額度通道",
        "Quit QuotaLens": "退出 QuotaLens",
        "Quota Health": "額度健康狀態",
        "Quota for the current account appears after connecting.": "連接後會顯示目前帳號額度。",
        "Quota for the current account appears after connection succeeds.": "連接成功後會顯示目前帳號額度。",
        "Quota is pending for the current account": "目前帳號額度待读取",
        "Ready": "隨時可用",
        "Reconnect": "重連通道",
        "Refresh Account": "刷新帳號",
        "Refresh Data": "刷新資料",
        "Refresh Rate": "刷新頻率",
        "Refresh data now": "立即刷新資料",
        "Refresh server quota data now": "立即刷新伺服器額度資料",
        "Remaining": "剩餘可用",
        "Remind in 1 hour": "1 小時後提醒",
        "Remind in 2 hours": "2 小時後提醒",
        "Renewal status pending": "續費狀態待同步",
        "Renewal status unknown": "續費狀態未知",
        "Requires approval in System Settings": "需要在系統設定中確認",
        "Reserve available for the full cycle": "全週期備用儲備",
        "Reset Card Expiry Reminder": "重置卡到期提醒",
        "Reset Card Reserve": "重置卡儲備",
        "Reset Cards": "重置卡儲備",
        "Reset Countdown": "重置倒計時",
        "Reset Credits Hangar": "重置卡配額機庫",
        "Reset card": "重置卡",
        "Reset in:": "重置倒計時：",
        "Resetting soon": "即將重置",
        "Retrying": "重試中",
        "Retrying quota read": "正在重新讀取額度",
        "Run Full Server Re-Probe": "執行全量資料重探",
        "SQLite database endpoint:": "SQLite 資料庫端點：",
        "Server returned no data yet": "伺服器暫未返回資料",
        "Settings": "設定",
        "Storage Core": "本機持久化核心",
        "Subscription": "訂閱有效期",
        "Subscription API is temporarily unavailable": "訂閱介面暫不可用",
        "Subscription API returned an unrecognized response": "訂閱介面返回結構無法識別",
        "System": "跟隨系統",
        "The selected file is not executable. Choose a codex CLI binary.": "所選檔案不可執行，請選擇 codex CLI 二進位檔。",
        "The server did not return quota data yet. Retrying automatically.": "伺服器剛才沒有返回額度，正在自動重試。",
        "The server has not reported any reset card quota.": "伺服器目前未登記可用重置卡配額。",
        "Timed out while reading Codex App Server": "讀取 Codex App Server 逾時",
        "Transport disconnected": "通信傳輸已斷開",
        "Unknown": "未知",
        "Unknown Plan": "未知套餐",
        "Unknown end": "未知結束",
        "Unknown start": "未知開始",
        "Used": "已用",
        "Used This Week": "本週已用",
        "Used:": "已用：",
        "Waiting for sync": "等待同步",
        "When enabled, QuotaLens reminds you during the week before the nearest available reset card expires.": "開啟後會在最近一張可用重置卡到期前一週提醒。",
        "When enabled, QuotaLens stays in the menu bar and opens from the status item.": "開啟後僅在頂部選單列駐留，點擊選單列即可呼出控制面板。",
        "Within active period": "有效週期內"
    ],
    .japanese: [
        "%d seconds short": "%d秒",
        "%d minutes short": "%d分",
        "%d minutes %d seconds short": "%d分 %d秒",
        "%lld days %lld hours short": "%lld日 %lld時間",
        "%lld hours %lld minutes short": "%lld時間 %lld分",
        "%d available": "%d枚利用可能",
        "%d available reset card": "利用可能なリセットカード %d枚",
        "%d available reset cards": "利用可能なリセットカード %d枚",
        "%d days left": "残り%d日",
        "%@ remaining": "残り %@",
        "Auto-detect · %@": "自動検出 · %@",
        "Changes to %@": "%@ に変更予定",
        "Expires %@": "期限 %@",
        "Every %@": "%@ ごと",
        "Failed: %@": "失敗: %@",
        "Granted %@  ~  Expires %@": "付与 %@  ~  期限 %@",
        "Login item status: %@": "ログイン項目の状態: %@",
        "Nearest deadline: %@": "最も近い期限: %@",
        "Next %@": "次回 %@",
        "Reads server quota snapshots every %@.": "%@ ごとにサーバーのクォータスナップショットを読み取ります。",
        "Server read failed: %@": "サーバー読み取り失敗: %@",
        "Sync: %@": "同期: %@",
        "The nearest %@ expires %@": "最も近い %@ の期限は %@ です",
        "The nearest %@ expires %@; the subscription ends or changes on %@.": "最も近い %@ の期限は %@ ですが、サブスクリプションは %@ に終了または変更されます。",
        "%@ expires %@. Use it soon.": "%@ は %@ に期限切れになります。早めに使用してください。",
        "%@ expires %@, but the subscription ends or changes on %@. Use it soon.": "%@ は %@ に期限切れになりますが、サブスクリプションは %@ に終了または変更されます。早めに使用してください。",
        "Using macOS language: %@": "macOS の言語を使用: %@",
        "Acknowledged": "確認済み",
        "Appearance & Theme": "外観とテーマ",
        "Auto": "自動",
        "Auto-detect codex": "codex を自動検出",
        "Auto-detect · Search environment for codex": "自動検出 · 環境から codex を検索",
        "Auto-renews": "自動更新",
        "Auto-resets next cycle": "次のサイクルで自動リセット",
        "Available This Week": "今週の利用可能分",
        "Available:": "利用可能:",
        "Background auto-refresh monitoring": "バックグラウンドで自動更新監視",
        "Bound to the current session and live sign-in state": "現在のセッションと実際のサインイン状態に連動",
        "CLI Binary Path": "CLI 実行ファイルのパス",
        "CLI not installed": "CLI 未インストール",
        "Cancel": "キャンセル",
        "Cannot choose target": "対象を選択できません",
        "Cannot connect": "接続できません",
        "Changing": "変更予定",
        "Check that the CLI is installed and signed in.": "CLI がインストールされ、サインイン済みであることを確認してください。",
        "Choose": "選択",
        "Choose CLI binary target": "CLI 実行ファイルを選択",
        "Choose Codex CLI Executable": "Codex CLI 実行ファイルを選択",
        "Choose a codex CLI executable, or keep auto-detection enabled.": "codex CLI 実行ファイルを選択するか、自動検出を使用します。",
        "Choose from File...": "ファイルから選択…",
        "Choose light, dark, or follow the macOS appearance.": "ライト、ダーク、または macOS の外観に従います。",
        "Click to toggle used/available view": "クリックして使用済み/利用可能を切り替え",
        "Codex executable not found": "codex 実行ファイルが見つかりません",
        "Connected": "接続済み",
        "Connecting": "接続中",
        "Copied": "コピー済み",
        "Copy Path": "パスをコピー",
        "Critical": "緊急",
        "Current period:": "現在の期間:",
        "Daily Usage Trend": "日次使用量の推移",
        "Dark HUD": "ダーク HUD",
        "Dark mode active (click for light)": "ダークモード中（クリックでライトへ）",
        "Date": "日付",
        "Disconnected": "切断",
        "Ending": "終了予定",
        "Ends at period close": "期間終了時に終了",
        "Engine Dispatch": "エンジン実行管理",
        "Follow System": "システムに従う",
        "Follow the system by default, or pin the interface to a language.": "既定ではシステムに従い、必要に応じて言語を固定できます。",
        "Free": "利用可能",
        "Healthy reserve": "十分な残量",
        "Identity Gateway": "ID ゲートウェイ",
        "Install and sign in to the Codex CLI to show quota data.": "クォータを表示するには Codex CLI をインストールしてサインインしてください。",
        "Interface Language": "表示言語",
        "Interface Theme": "インターフェイスのテーマ",
        "Last 7 Days": "過去 7 日",
        "Launch at Login": "ログイン時に起動",
        "Light": "ライト",
        "Light mode active (click for dark)": "ライトモード中（クリックでダークへ）",
        "Low reserve": "残量少なめ",
        "Manage appearance, account identity, background scheduling, and local data storage.": "外観、アカウント ID、バックグラウンド実行、ローカルデータ保存を管理します。",
        "Menu Bar Mode (Hide Dock Icon)": "メニューバーモード（Dock アイコンを非表示）",
        "Missing": "未インストール",
        "Monitor quota usage, reset windows, and model telemetry for the current account.": "現在のアカウントのクォータ使用量、リセット周期、モデルテレメトリを監視します。",
        "Nearest reset card is expiring soon": "最も近いリセットカードの期限が近づいています",
        "Needs action": "対応が必要",
        "No account selected": "アカウント未選択",
        "No card to remind": "通知対象のカードなし",
        "No cards": "カードなし",
        "No quota yet": "クォータ未取得",
        "No trend data": "トレンドデータなし",
        "OK": "OK",
        "Off": "オフ",
        "Offline": "オフライン",
        "On": "オン",
        "Open Console": "コンソールを開く",
        "Overview": "概要",
        "Pending": "保留中",
        "Plan changes at period close": "期間終了時にプラン変更",
        "Primary Quota Channel": "主要クォータチャンネル",
        "Quit QuotaLens": "QuotaLens を終了",
        "Quota Health": "クォータ状態",
        "Quota is pending for the current account": "現在のアカウントのクォータを読み取り中",
        "Ready": "使用可能",
        "Reconnect": "再接続",
        "Refresh Account": "アカウントを更新",
        "Refresh Data": "データを更新",
        "Refresh Rate": "更新頻度",
        "Refresh data now": "今すぐ更新",
        "Refresh server quota data now": "サーバークォータを今すぐ更新",
        "Remaining": "残り",
        "Remind in 1 hour": "1 時間後に通知",
        "Remind in 2 hours": "2 時間後に通知",
        "Renewal status pending": "更新状態を同期中",
        "Renewal status unknown": "更新状態不明",
        "Requires approval in System Settings": "システム設定で承認が必要",
        "Reserve available for the full cycle": "サイクル全体の予備",
        "Reset Card Expiry Reminder": "リセットカード期限通知",
        "Reset Card Reserve": "リセットカード予備",
        "Reset Cards": "リセットカード",
        "Reset Countdown": "リセットまで",
        "Reset Credits Hangar": "リセットカード格納庫",
        "Reset card": "リセットカード",
        "Reset in:": "リセットまで:",
        "Resetting soon": "まもなくリセット",
        "Retrying": "再試行中",
        "Retrying quota read": "クォータを再読み取り中",
        "Run Full Server Re-Probe": "サーバーを再スキャン",
        "SQLite database endpoint:": "SQLite データベース:",
        "Server returned no data yet": "サーバーはまだデータを返していません",
        "Settings": "設定",
        "Storage Core": "ストレージ",
        "Subscription": "サブスクリプション",
        "System": "システム",
        "The server did not return quota data yet. Retrying automatically.": "サーバーがまだクォータデータを返していません。自動で再試行します。",
        "The server has not reported any reset card quota.": "サーバーにリセットカードのクォータは記録されていません。",
        "Unknown": "不明",
        "Unknown Plan": "不明なプラン",
        "Unknown end": "終了不明",
        "Unknown start": "開始不明",
        "Used": "使用済み",
        "Used This Week": "今週の使用量",
        "Used:": "使用済み:",
        "Waiting for sync": "同期待ち",
        "When enabled, QuotaLens reminds you during the week before the nearest available reset card expires.": "有効にすると、最も近いリセットカードの期限 1 週間前から通知します。",
        "When enabled, QuotaLens stays in the menu bar and opens from the status item.": "有効にすると、QuotaLens はメニューバーに常駐します。",
        "Within active period": "有効期間内"
    ],
    .korean: [
        "%d seconds short": "%d초",
        "%d minutes short": "%d분",
        "%d minutes %d seconds short": "%d분 %d초",
        "%lld days %lld hours short": "%lld일 %lld시간",
        "%lld hours %lld minutes short": "%lld시간 %lld분",
        "%d available": "%d장 사용 가능",
        "%d available reset card": "리셋 카드 %d장 사용 가능",
        "%d available reset cards": "리셋 카드 %d장 사용 가능",
        "%d days left": "%d일 남음",
        "%@ remaining": "%@ 남음",
        "Auto-detect · %@": "자동 감지 · %@",
        "Changes to %@": "%@로 변경 예정",
        "Expires %@": "만료 %@",
        "Every %@": "%@마다",
        "Failed: %@": "실패: %@",
        "Granted %@  ~  Expires %@": "지급 %@  ~  만료 %@",
        "Login item status: %@": "로그인 항목 상태: %@",
        "Nearest deadline: %@": "가장 가까운 마감: %@",
        "Next %@": "다음 %@",
        "Reads server quota snapshots every %@.": "%@마다 서버 할당량 스냅샷을 읽습니다.",
        "Server read failed: %@": "서버 읽기 실패: %@",
        "Sync: %@": "동기화: %@",
        "The nearest %@ expires %@": "가장 가까운 %@ 만료일은 %@입니다",
        "The nearest %@ expires %@; the subscription ends or changes on %@.": "가장 가까운 %@ 만료일은 %@이며, 구독은 %@에 종료되거나 변경됩니다.",
        "%@ expires %@. Use it soon.": "%@이 %@에 만료됩니다. 곧 사용하세요.",
        "%@ expires %@, but the subscription ends or changes on %@. Use it soon.": "%@이 %@에 만료되지만 구독은 %@에 종료되거나 변경됩니다. 곧 사용하세요.",
        "Using macOS language: %@": "macOS 언어 사용: %@",
        "Acknowledged": "확인됨",
        "Appearance & Theme": "외관 및 테마",
        "Auto": "자동",
        "Auto-renews": "자동 갱신",
        "Auto-resets next cycle": "다음 주기에 자동 리셋",
        "Available This Week": "이번 주 사용 가능",
        "Available:": "사용 가능:",
        "Background auto-refresh monitoring": "백그라운드 자동 새로고침 모니터링",
        "Bound to the current session and live sign-in state": "현재 세션 및 실제 로그인 상태와 연동",
        "CLI Binary Path": "CLI 실행 파일 경로",
        "CLI not installed": "CLI 미설치",
        "Cancel": "취소",
        "Cannot choose target": "대상을 선택할 수 없음",
        "Cannot connect": "연결할 수 없음",
        "Changing": "변경 예정",
        "Check that the CLI is installed and signed in.": "CLI가 설치되어 있고 로그인되어 있는지 확인하세요.",
        "Choose": "선택",
        "Choose CLI binary target": "CLI 실행 파일 선택",
        "Choose Codex CLI Executable": "Codex CLI 실행 파일 선택",
        "Choose a codex CLI executable, or keep auto-detection enabled.": "codex CLI 실행 파일을 선택하거나 자동 감지를 유지하세요.",
        "Choose from File...": "파일에서 선택…",
        "Choose light, dark, or follow the macOS appearance.": "라이트, 다크 또는 macOS 외관을 따르도록 선택합니다.",
        "Click to toggle used/available view": "클릭하여 사용됨/사용 가능 보기 전환",
        "Codex executable not found": "codex 실행 파일을 찾을 수 없음",
        "Connected": "연결됨",
        "Connecting": "연결 중",
        "Copied": "복사됨",
        "Copy Path": "경로 복사",
        "Critical": "위험",
        "Current period:": "현재 기간:",
        "Daily Usage Trend": "일별 사용량 추이",
        "Dark HUD": "다크 HUD",
        "Date": "날짜",
        "Disconnected": "연결 끊김",
        "Ending": "종료 예정",
        "Ends at period close": "기간 종료 시 종료",
        "Engine Dispatch": "엔진 디스패치",
        "Follow System": "시스템 따르기",
        "Follow the system by default, or pin the interface to a language.": "기본값은 시스템을 따르며, 원하는 언어로 고정할 수 있습니다.",
        "Free": "사용 가능",
        "Healthy reserve": "여유 충분",
        "Identity Gateway": "계정 및 ID 게이트웨이",
        "Interface Language": "인터페이스 언어",
        "Interface Theme": "인터페이스 테마",
        "Last 7 Days": "최근 7일",
        "Launch at Login": "로그인 시 실행",
        "Light": "라이트",
        "Low reserve": "여유 부족",
        "Manage appearance, account identity, background scheduling, and local data storage.": "외관, 계정 ID, 백그라운드 일정 및 로컬 데이터 저장소를 관리합니다.",
        "Menu Bar Mode (Hide Dock Icon)": "메뉴 막대 모드(Dock 아이콘 숨김)",
        "Missing": "없음",
        "Monitor quota usage, reset windows, and model telemetry for the current account.": "현재 계정의 할당량 사용량, 리셋 주기 및 모델 텔레메트리를 모니터링합니다.",
        "Nearest reset card is expiring soon": "가장 가까운 리셋 카드가 곧 만료됩니다",
        "Needs action": "처리 필요",
        "No account selected": "선택된 계정 없음",
        "No card to remind": "알림 대상 카드 없음",
        "No cards": "카드 없음",
        "No quota yet": "할당량 없음",
        "No trend data": "추이 데이터 없음",
        "OK": "확인",
        "Off": "꺼짐",
        "Offline": "오프라인",
        "On": "켜짐",
        "Open Console": "콘솔 열기",
        "Overview": "개요",
        "Pending": "대기 중",
        "Primary Quota Channel": "기본 할당량 채널",
        "Quit QuotaLens": "QuotaLens 종료",
        "Quota Health": "할당량 상태",
        "Ready": "준비됨",
        "Reconnect": "다시 연결",
        "Refresh Account": "계정 새로고침",
        "Refresh Data": "데이터 새로고침",
        "Refresh Rate": "새로고침 빈도",
        "Refresh data now": "지금 새로고침",
        "Refresh server quota data now": "서버 할당량 지금 새로고침",
        "Remaining": "남음",
        "Remind in 1 hour": "1시간 후 알림",
        "Remind in 2 hours": "2시간 후 알림",
        "Reserve available for the full cycle": "전체 주기 예비분",
        "Reset Card Expiry Reminder": "리셋 카드 만료 알림",
        "Reset Card Reserve": "리셋 카드 예비",
        "Reset Cards": "리셋 카드",
        "Reset Countdown": "리셋 카운트다운",
        "Reset Credits Hangar": "리셋 카드 보관함",
        "Reset card": "리셋 카드",
        "Reset in:": "리셋까지:",
        "Resetting soon": "곧 리셋",
        "Retrying": "재시도 중",
        "Run Full Server Re-Probe": "전체 서버 재탐색 실행",
        "SQLite database endpoint:": "SQLite 데이터베이스 엔드포인트:",
        "Settings": "설정",
        "Storage Core": "저장소 코어",
        "Subscription": "구독",
        "System": "시스템",
        "Unknown": "알 수 없음",
        "Unknown Plan": "알 수 없는 플랜",
        "Used": "사용됨",
        "Used This Week": "이번 주 사용됨",
        "Used:": "사용됨:",
        "Waiting for sync": "동기화 대기 중",
        "Within active period": "유효 기간 내"
    ],
    .spanish: [
        "%d seconds short": "%d s",
        "%d minutes short": "%d min",
        "%d minutes %d seconds short": "%d min %d s",
        "%lld days %lld hours short": "%lld d %lld h",
        "%lld hours %lld minutes short": "%lld h %lld min",
        "%d available": "%d disponibles",
        "%d available reset card": "%d tarjeta de reinicio disponible",
        "%d available reset cards": "%d tarjetas de reinicio disponibles",
        "%d days left": "quedan %d d",
        "%@ remaining": "%@ restante",
        "Auto-detect · %@": "Detectado automáticamente · %@",
        "Changes to %@": "Cambia a %@",
        "Expires %@": "Vence %@",
        "Every %@": "Cada %@",
        "Failed: %@": "Error: %@",
        "Granted %@  ~  Expires %@": "Otorgada %@  ~  Vence %@",
        "Login item status: %@": "Estado de inicio: %@",
        "Nearest deadline: %@": "Vencimiento más cercano: %@",
        "Next %@": "Próximo %@",
        "Reads server quota snapshots every %@.": "Lee instantáneas de cuota del servidor cada %@.",
        "Server read failed: %@": "Error al leer el servidor: %@",
        "Sync: %@": "Sincronizado: %@",
        "The nearest %@ expires %@": "La %@ más cercana vence %@",
        "The nearest %@ expires %@; the subscription ends or changes on %@.": "La %@ más cercana vence %@; la suscripción termina o cambia el %@.",
        "%@ expires %@. Use it soon.": "%@ vence %@. Úsala pronto.",
        "%@ expires %@, but the subscription ends or changes on %@. Use it soon.": "%@ vence %@, pero la suscripción termina o cambia el %@. Úsala pronto.",
        "Using macOS language: %@": "Usando el idioma de macOS: %@",
        "Acknowledged": "Confirmado",
        "Appearance & Theme": "Apariencia y tema",
        "Auto": "Auto",
        "Auto-renews": "Renovación automática",
        "Available This Week": "Disponible esta semana",
        "Available:": "Disponible:",
        "Background auto-refresh monitoring": "Supervisión con actualización automática",
        "CLI Binary Path": "Ruta del binario CLI",
        "CLI not installed": "CLI no instalada",
        "Cancel": "Cancelar",
        "Cannot choose target": "No se puede elegir el destino",
        "Cannot connect": "No se puede conectar",
        "Changing": "Cambiando",
        "Choose": "Elegir",
        "Choose CLI binary target": "Elegir binario CLI",
        "Choose Codex CLI Executable": "Elegir ejecutable de Codex CLI",
        "Choose from File...": "Elegir desde archivo…",
        "Choose light, dark, or follow the macOS appearance.": "Elige claro, oscuro o seguir la apariencia de macOS.",
        "Click to toggle used/available view": "Haz clic para alternar usado/disponible",
        "Connected": "Conectado",
        "Connecting": "Conectando",
        "Copied": "Copiado",
        "Copy Path": "Copiar ruta",
        "Critical": "Crítico",
        "Current period:": "Periodo actual:",
        "Daily Usage Trend": "Tendencia de uso diario",
        "Dark HUD": "HUD oscuro",
        "Date": "Fecha",
        "Disconnected": "Desconectado",
        "Ending": "Finalizando",
        "Ends at period close": "Termina al cierre del periodo",
        "Engine Dispatch": "Motor y comunicación",
        "Follow System": "Seguir sistema",
        "Follow the system by default, or pin the interface to a language.": "Sigue el sistema por defecto o fija un idioma para la interfaz.",
        "Free": "Libre",
        "Healthy reserve": "Reserva saludable",
        "Identity Gateway": "Identidad de cuenta",
        "Interface Language": "Idioma de la interfaz",
        "Interface Theme": "Tema de interfaz",
        "Last 7 Days": "Últimos 7 días",
        "Launch at Login": "Abrir al iniciar sesión",
        "Light": "Claro",
        "Low reserve": "Reserva baja",
        "Manage appearance, account identity, background scheduling, and local data storage.": "Gestiona apariencia, identidad, programación en segundo plano y almacenamiento local.",
        "Menu Bar Mode (Hide Dock Icon)": "Modo barra de menús (ocultar Dock)",
        "Missing": "Falta",
        "Monitor quota usage, reset windows, and model telemetry for the current account.": "Supervisa cuota, reinicios y telemetría de modelos de la cuenta actual.",
        "Nearest reset card is expiring soon": "La tarjeta de reinicio más cercana está por vencer",
        "Needs action": "Requiere acción",
        "No account selected": "Ninguna cuenta seleccionada",
        "No card to remind": "Sin tarjeta para recordar",
        "No cards": "Sin tarjetas",
        "No quota yet": "Sin cuota aún",
        "No trend data": "Sin datos de tendencia",
        "OK": "Aceptar",
        "Off": "Desactivado",
        "Offline": "Sin conexión",
        "On": "Activado",
        "Open Console": "Abrir consola",
        "Overview": "Resumen",
        "Pending": "Pendiente",
        "Plan changes at period close": "El plan cambia al cierre del periodo",
        "Primary Quota Channel": "Canal principal de cuota",
        "Quit QuotaLens": "Salir de QuotaLens",
        "Quota Health": "Estado de cuota",
        "Ready": "Listo",
        "Reconnect": "Reconectar",
        "Refresh Account": "Actualizar cuenta",
        "Refresh Data": "Actualizar datos",
        "Refresh Rate": "Frecuencia",
        "Refresh data now": "Actualizar ahora",
        "Refresh server quota data now": "Actualizar cuota del servidor",
        "Remaining": "Restante",
        "Remind in 1 hour": "Recordar en 1 hora",
        "Remind in 2 hours": "Recordar en 2 horas",
        "Reserve available for the full cycle": "Reserva disponible para todo el ciclo",
        "Reset Card Expiry Reminder": "Recordatorio de vencimiento",
        "Reset Card Reserve": "Reserva de tarjetas",
        "Reset Cards": "Tarjetas de reinicio",
        "Reset Countdown": "Cuenta atrás",
        "Reset Credits Hangar": "Hangar de tarjetas de reinicio",
        "Reset card": "Tarjeta de reinicio",
        "Reset in:": "Reinicio en:",
        "Resetting soon": "Reinicio inminente",
        "Retrying": "Reintentando",
        "Retrying quota read": "Releyendo cuota",
        "Run Full Server Re-Probe": "Reexplorar servidor",
        "SQLite database endpoint:": "Base de datos SQLite:",
        "Settings": "Ajustes",
        "Storage Core": "Almacenamiento",
        "Subscription": "Suscripción",
        "System": "Sistema",
        "Unknown": "Desconocido",
        "Unknown Plan": "Plan desconocido",
        "Used": "Usado",
        "Used This Week": "Usado esta semana",
        "Used:": "Usado:",
        "Waiting for sync": "Esperando sincronización",
        "Within active period": "Dentro del periodo activo"
    ],
    .german: [
        "%d seconds short": "%d s",
        "%d minutes short": "%d Min.",
        "%d minutes %d seconds short": "%d Min. %d s",
        "%lld days %lld hours short": "%lld T %lld Std.",
        "%lld hours %lld minutes short": "%lld Std. %lld Min.",
        "%d available": "%d verfügbar",
        "%d available reset card": "%d Reset-Karte verfügbar",
        "%d available reset cards": "%d Reset-Karten verfügbar",
        "%d days left": "noch %d T",
        "%@ remaining": "%@ verbleibend",
        "Auto-detect · %@": "Automatisch erkannt · %@",
        "Changes to %@": "Wechselt zu %@",
        "Expires %@": "Läuft ab %@",
        "Every %@": "Alle %@",
        "Failed: %@": "Fehlgeschlagen: %@",
        "Granted %@  ~  Expires %@": "Erhalten %@  ~  Läuft ab %@",
        "Login item status: %@": "Anmeldestatus: %@",
        "Nearest deadline: %@": "Nächste Frist: %@",
        "Next %@": "Nächstes %@",
        "Reads server quota snapshots every %@.": "Liest alle %@ Server-Quota-Snapshots.",
        "Server read failed: %@": "Server-Lesen fehlgeschlagen: %@",
        "Sync: %@": "Sync: %@",
        "The nearest %@ expires %@": "Die nächste %@ läuft %@ ab",
        "The nearest %@ expires %@; the subscription ends or changes on %@.": "Die nächste %@ läuft %@ ab; das Abo endet oder ändert sich am %@.",
        "%@ expires %@. Use it soon.": "%@ läuft %@ ab. Bald verwenden.",
        "%@ expires %@, but the subscription ends or changes on %@. Use it soon.": "%@ läuft %@ ab, aber das Abo endet oder ändert sich am %@. Bald verwenden.",
        "Using macOS language: %@": "macOS-Sprache verwenden: %@",
        "Acknowledged": "Bestätigt",
        "Appearance & Theme": "Darstellung und Design",
        "Auto": "Auto",
        "Auto-renews": "Automatische Verlängerung",
        "Available This Week": "Diese Woche verfügbar",
        "Available:": "Verfügbar:",
        "Background auto-refresh monitoring": "Automatische Aktualisierung im Hintergrund",
        "CLI Binary Path": "CLI-Binärpfad",
        "CLI not installed": "CLI nicht installiert",
        "Cancel": "Abbrechen",
        "Cannot choose target": "Ziel kann nicht gewählt werden",
        "Cannot connect": "Keine Verbindung",
        "Changing": "Änderung",
        "Choose": "Wählen",
        "Choose CLI binary target": "CLI-Binärdatei wählen",
        "Choose Codex CLI Executable": "Codex-CLI wählen",
        "Choose from File...": "Aus Datei wählen…",
        "Choose light, dark, or follow the macOS appearance.": "Hell, dunkel oder macOS-Darstellung verwenden.",
        "Click to toggle used/available view": "Klicken, um verwendet/verfügbar umzuschalten",
        "Connected": "Verbunden",
        "Connecting": "Verbinden",
        "Copied": "Kopiert",
        "Copy Path": "Pfad kopieren",
        "Critical": "Kritisch",
        "Current period:": "Aktueller Zeitraum:",
        "Daily Usage Trend": "Täglicher Nutzungstrend",
        "Dark HUD": "Dunkles HUD",
        "Date": "Datum",
        "Disconnected": "Getrennt",
        "Ending": "Endet",
        "Ends at period close": "Endet zum Periodenende",
        "Engine Dispatch": "Engine-Steuerung",
        "Follow System": "System folgen",
        "Follow the system by default, or pin the interface to a language.": "Standardmäßig dem System folgen oder eine Sprache festlegen.",
        "Free": "Frei",
        "Healthy reserve": "Gute Reserve",
        "Identity Gateway": "Identität",
        "Interface Language": "Oberflächensprache",
        "Interface Theme": "Oberflächendesign",
        "Last 7 Days": "Letzte 7 Tage",
        "Launch at Login": "Beim Anmelden starten",
        "Light": "Hell",
        "Low reserve": "Niedrige Reserve",
        "Manage appearance, account identity, background scheduling, and local data storage.": "Darstellung, Kontoidentität, Hintergrundplanung und lokale Daten verwalten.",
        "Menu Bar Mode (Hide Dock Icon)": "Menüleistenmodus (Dock ausblenden)",
        "Missing": "Fehlt",
        "Monitor quota usage, reset windows, and model telemetry for the current account.": "Quota-Nutzung, Reset-Zeiträume und Modell-Telemetrie überwachen.",
        "Nearest reset card is expiring soon": "Die nächste Reset-Karte läuft bald ab",
        "Needs action": "Aktion erforderlich",
        "No account selected": "Kein Konto ausgewählt",
        "No card to remind": "Keine Karte für Erinnerung",
        "No cards": "Keine Karten",
        "No quota yet": "Noch keine Quota",
        "No trend data": "Keine Trenddaten",
        "OK": "OK",
        "Off": "Aus",
        "Offline": "Offline",
        "On": "Ein",
        "Open Console": "Konsole öffnen",
        "Overview": "Übersicht",
        "Pending": "Ausstehend",
        "Plan changes at period close": "Plan ändert sich zum Periodenende",
        "Primary Quota Channel": "Primärer Quota-Kanal",
        "Quit QuotaLens": "QuotaLens beenden",
        "Quota Health": "Quota-Status",
        "Ready": "Bereit",
        "Reconnect": "Neu verbinden",
        "Refresh Account": "Konto aktualisieren",
        "Refresh Data": "Daten aktualisieren",
        "Refresh Rate": "Aktualisierung",
        "Refresh data now": "Jetzt aktualisieren",
        "Refresh server quota data now": "Server-Quota aktualisieren",
        "Remaining": "Verbleibend",
        "Remind in 1 hour": "In 1 Stunde erinnern",
        "Remind in 2 hours": "In 2 Stunden erinnern",
        "Reserve available for the full cycle": "Reserve für den gesamten Zyklus",
        "Reset Card Expiry Reminder": "Ablauferinnerung",
        "Reset Card Reserve": "Reset-Kartenreserve",
        "Reset Cards": "Reset-Karten",
        "Reset Countdown": "Reset-Countdown",
        "Reset Credits Hangar": "Reset-Karten-Hangar",
        "Reset card": "Reset-Karte",
        "Reset in:": "Reset in:",
        "Resetting soon": "Reset bald",
        "Retrying": "Erneut versuchen",
        "Retrying quota read": "Quota wird erneut gelesen",
        "Run Full Server Re-Probe": "Server neu prüfen",
        "SQLite database endpoint:": "SQLite-Datenbank:",
        "Settings": "Einstellungen",
        "Storage Core": "Speicher",
        "Subscription": "Abo",
        "System": "System",
        "Unknown": "Unbekannt",
        "Unknown Plan": "Unbekannter Plan",
        "Used": "Verwendet",
        "Used This Week": "Diese Woche verwendet",
        "Used:": "Verwendet:",
        "Waiting for sync": "Warten auf Sync",
        "Within active period": "Im aktiven Zeitraum"
    ],
    .french: [
        "%d seconds short": "%d s",
        "%d minutes short": "%d min",
        "%d minutes %d seconds short": "%d min %d s",
        "%lld days %lld hours short": "%lld j %lld h",
        "%lld hours %lld minutes short": "%lld h %lld min",
        "%d available": "%d disponible(s)",
        "%d available reset card": "%d carte de réinitialisation disponible",
        "%d available reset cards": "%d cartes de réinitialisation disponibles",
        "%d days left": "%d j restants",
        "%@ remaining": "%@ restant",
        "Auto-detect · %@": "Détection auto · %@",
        "Changes to %@": "Passera à %@",
        "Expires %@": "Expire %@",
        "Every %@": "Toutes les %@",
        "Failed: %@": "Échec : %@",
        "Granted %@  ~  Expires %@": "Obtenue %@  ~  Expire %@",
        "Login item status: %@": "État au démarrage : %@",
        "Nearest deadline: %@": "Échéance la plus proche : %@",
        "Next %@": "Prochain %@",
        "Reads server quota snapshots every %@.": "Lit les instantanés de quota serveur toutes les %@.",
        "Server read failed: %@": "Lecture serveur échouée : %@",
        "Sync: %@": "Synchro : %@",
        "The nearest %@ expires %@": "La %@ la plus proche expire %@",
        "The nearest %@ expires %@; the subscription ends or changes on %@.": "La %@ la plus proche expire %@ ; l'abonnement se termine ou change le %@.",
        "%@ expires %@. Use it soon.": "%@ expire %@. Utilisez-la bientôt.",
        "%@ expires %@, but the subscription ends or changes on %@. Use it soon.": "%@ expire %@, mais l'abonnement se termine ou change le %@. Utilisez-la bientôt.",
        "Using macOS language: %@": "Langue macOS utilisée : %@",
        "Acknowledged": "Confirmé",
        "Appearance & Theme": "Apparence et thème",
        "Auto": "Auto",
        "Auto-renews": "Renouvellement auto",
        "Available This Week": "Disponible cette semaine",
        "Available:": "Disponible :",
        "Background auto-refresh monitoring": "Surveillance avec actualisation automatique",
        "CLI Binary Path": "Chemin du binaire CLI",
        "CLI not installed": "CLI non installé",
        "Cancel": "Annuler",
        "Cannot choose target": "Impossible de choisir la cible",
        "Cannot connect": "Connexion impossible",
        "Changing": "Changement",
        "Choose": "Choisir",
        "Choose CLI binary target": "Choisir le binaire CLI",
        "Choose Codex CLI Executable": "Choisir l'exécutable Codex CLI",
        "Choose from File...": "Choisir un fichier…",
        "Choose light, dark, or follow the macOS appearance.": "Choisissez clair, sombre ou l'apparence macOS.",
        "Click to toggle used/available view": "Cliquer pour basculer utilisé/disponible",
        "Connected": "Connecté",
        "Connecting": "Connexion",
        "Copied": "Copié",
        "Copy Path": "Copier le chemin",
        "Critical": "Critique",
        "Current period:": "Période actuelle :",
        "Daily Usage Trend": "Tendance d'utilisation quotidienne",
        "Dark HUD": "HUD sombre",
        "Date": "Date",
        "Disconnected": "Déconnecté",
        "Ending": "Fin",
        "Ends at period close": "Se termine à la fin de période",
        "Engine Dispatch": "Pilotage du moteur",
        "Follow System": "Suivre le système",
        "Follow the system by default, or pin the interface to a language.": "Suit le système par défaut, ou fixe une langue pour l'interface.",
        "Free": "Libre",
        "Healthy reserve": "Réserve confortable",
        "Identity Gateway": "Identité",
        "Interface Language": "Langue de l'interface",
        "Interface Theme": "Thème de l'interface",
        "Last 7 Days": "7 derniers jours",
        "Launch at Login": "Lancer à l'ouverture de session",
        "Light": "Clair",
        "Low reserve": "Réserve faible",
        "Manage appearance, account identity, background scheduling, and local data storage.": "Gérez l'apparence, l'identité, la planification et le stockage local.",
        "Menu Bar Mode (Hide Dock Icon)": "Mode barre de menus (masquer le Dock)",
        "Missing": "Manquant",
        "Monitor quota usage, reset windows, and model telemetry for the current account.": "Surveille le quota, les fenêtres de réinitialisation et la télémétrie du compte.",
        "Nearest reset card is expiring soon": "La carte de réinitialisation la plus proche expire bientôt",
        "Needs action": "Action requise",
        "No account selected": "Aucun compte sélectionné",
        "No card to remind": "Aucune carte à rappeler",
        "No cards": "Aucune carte",
        "No quota yet": "Aucun quota pour l'instant",
        "No trend data": "Aucune donnée de tendance",
        "OK": "OK",
        "Off": "Désactivé",
        "Offline": "Hors ligne",
        "On": "Activé",
        "Open Console": "Ouvrir la console",
        "Overview": "Vue d'ensemble",
        "Pending": "En attente",
        "Plan changes at period close": "Le forfait change en fin de période",
        "Primary Quota Channel": "Canal de quota principal",
        "Quit QuotaLens": "Quitter QuotaLens",
        "Quota Health": "Santé du quota",
        "Ready": "Prêt",
        "Reconnect": "Reconnecter",
        "Refresh Account": "Actualiser le compte",
        "Refresh Data": "Actualiser les données",
        "Refresh Rate": "Fréquence",
        "Refresh data now": "Actualiser maintenant",
        "Refresh server quota data now": "Actualiser le quota serveur",
        "Remaining": "Restant",
        "Remind in 1 hour": "Rappeler dans 1 heure",
        "Remind in 2 hours": "Rappeler dans 2 heures",
        "Reserve available for the full cycle": "Réserve disponible pour tout le cycle",
        "Reset Card Expiry Reminder": "Rappel d'expiration",
        "Reset Card Reserve": "Réserve de cartes",
        "Reset Cards": "Cartes de réinitialisation",
        "Reset Countdown": "Compte à rebours",
        "Reset Credits Hangar": "Hangar des cartes de réinitialisation",
        "Reset card": "Carte de réinitialisation",
        "Reset in:": "Réinitialisation dans :",
        "Resetting soon": "Réinitialisation imminente",
        "Retrying": "Nouvelle tentative",
        "Retrying quota read": "Nouvelle lecture du quota",
        "Run Full Server Re-Probe": "Relancer l'analyse serveur",
        "SQLite database endpoint:": "Base SQLite :",
        "Settings": "Réglages",
        "Storage Core": "Stockage",
        "Subscription": "Abonnement",
        "System": "Système",
        "Unknown": "Inconnu",
        "Unknown Plan": "Forfait inconnu",
        "Used": "Utilisé",
        "Used This Week": "Utilisé cette semaine",
        "Used:": "Utilisé :",
        "Waiting for sync": "En attente de synchro",
        "Within active period": "Dans la période active"
    ],
    .portuguese: [
        "%d seconds short": "%d s",
        "%d minutes short": "%d min",
        "%d minutes %d seconds short": "%d min %d s",
        "%lld days %lld hours short": "%lld d %lld h",
        "%lld hours %lld minutes short": "%lld h %lld min",
        "%d available": "%d disponíveis",
        "%d available reset card": "%d cartão de reposição disponível",
        "%d available reset cards": "%d cartões de reposição disponíveis",
        "%d days left": "restam %d d",
        "%@ remaining": "%@ restante",
        "Auto-detect · %@": "Deteção automática · %@",
        "Changes to %@": "Muda para %@",
        "Expires %@": "Expira %@",
        "Every %@": "A cada %@",
        "Failed: %@": "Falhou: %@",
        "Granted %@  ~  Expires %@": "Obtido %@  ~  Expira %@",
        "Login item status: %@": "Estado de arranque: %@",
        "Nearest deadline: %@": "Prazo mais próximo: %@",
        "Next %@": "Próximo %@",
        "Reads server quota snapshots every %@.": "Lê instantâneos de quota do servidor a cada %@.",
        "Server read failed: %@": "Falha ao ler o servidor: %@",
        "Sync: %@": "Sincronização: %@",
        "The nearest %@ expires %@": "O %@ mais próximo expira %@",
        "The nearest %@ expires %@; the subscription ends or changes on %@.": "O %@ mais próximo expira %@; a subscrição termina ou muda em %@.",
        "%@ expires %@. Use it soon.": "%@ expira %@. Use-o em breve.",
        "%@ expires %@, but the subscription ends or changes on %@. Use it soon.": "%@ expira %@, mas a subscrição termina ou muda em %@. Use-o em breve.",
        "Using macOS language: %@": "A usar o idioma do macOS: %@",
        "Acknowledged": "Confirmado",
        "Appearance & Theme": "Aspeto e tema",
        "Auto": "Auto",
        "Auto-renews": "Renovação automática",
        "Available This Week": "Disponível esta semana",
        "Available:": "Disponível:",
        "Background auto-refresh monitoring": "Monitorização com atualização automática",
        "CLI Binary Path": "Caminho do binário CLI",
        "CLI not installed": "CLI não instalado",
        "Cancel": "Cancelar",
        "Cannot choose target": "Não é possível escolher o destino",
        "Cannot connect": "Não é possível ligar",
        "Changing": "A mudar",
        "Choose": "Escolher",
        "Choose CLI binary target": "Escolher binário CLI",
        "Choose Codex CLI Executable": "Escolher executável Codex CLI",
        "Choose from File...": "Escolher de ficheiro…",
        "Choose light, dark, or follow the macOS appearance.": "Escolha claro, escuro ou seguir o aspeto do macOS.",
        "Connected": "Ligado",
        "Connecting": "A ligar",
        "Copied": "Copiado",
        "Copy Path": "Copiar caminho",
        "Critical": "Crítico",
        "Current period:": "Período atual:",
        "Daily Usage Trend": "Tendência diária de utilização",
        "Dark HUD": "HUD escuro",
        "Date": "Data",
        "Disconnected": "Desligado",
        "Ending": "A terminar",
        "Engine Dispatch": "Gestão do motor",
        "Follow System": "Seguir sistema",
        "Follow the system by default, or pin the interface to a language.": "Segue o sistema por predefinição, ou fixa o idioma da interface.",
        "Free": "Livre",
        "Healthy reserve": "Reserva saudável",
        "Identity Gateway": "Identidade",
        "Interface Language": "Idioma da interface",
        "Interface Theme": "Tema da interface",
        "Last 7 Days": "Últimos 7 dias",
        "Launch at Login": "Iniciar ao iniciar sessão",
        "Light": "Claro",
        "Low reserve": "Reserva baixa",
        "Manage appearance, account identity, background scheduling, and local data storage.": "Gira aspeto, identidade, agendamento em segundo plano e dados locais.",
        "Menu Bar Mode (Hide Dock Icon)": "Modo barra de menus (ocultar Dock)",
        "Missing": "Em falta",
        "Monitor quota usage, reset windows, and model telemetry for the current account.": "Monitoriza quota, reinícios e telemetria da conta atual.",
        "Nearest reset card is expiring soon": "O cartão de reposição mais próximo expira em breve",
        "Needs action": "Requer ação",
        "No account selected": "Nenhuma conta selecionada",
        "No card to remind": "Sem cartão para lembrar",
        "No cards": "Sem cartões",
        "No quota yet": "Sem quota ainda",
        "OK": "OK",
        "Off": "Desligado",
        "Offline": "Offline",
        "On": "Ligado",
        "Open Console": "Abrir consola",
        "Overview": "Visão geral",
        "Pending": "Pendente",
        "Primary Quota Channel": "Canal principal de quota",
        "Quit QuotaLens": "Sair do QuotaLens",
        "Quota Health": "Estado da quota",
        "Ready": "Pronto",
        "Reconnect": "Religar",
        "Refresh Account": "Atualizar conta",
        "Refresh Data": "Atualizar dados",
        "Refresh Rate": "Frequência",
        "Refresh data now": "Atualizar agora",
        "Refresh server quota data now": "Atualizar quota do servidor",
        "Remaining": "Restante",
        "Remind in 1 hour": "Lembrar em 1 hora",
        "Remind in 2 hours": "Lembrar em 2 horas",
        "Reset Card Reserve": "Reserva de cartões",
        "Reset Cards": "Cartões de reposição",
        "Reset Countdown": "Contagem para reposição",
        "Reset Credits Hangar": "Hangar de cartões de reposição",
        "Reset card": "Cartão de reposição",
        "Reset in:": "Reposição em:",
        "Retrying": "A tentar novamente",
        "Run Full Server Re-Probe": "Reanalisar servidor",
        "SQLite database endpoint:": "Base de dados SQLite:",
        "Settings": "Definições",
        "Storage Core": "Armazenamento",
        "Subscription": "Subscrição",
        "System": "Sistema",
        "Unknown": "Desconhecido",
        "Unknown Plan": "Plano desconhecido",
        "Used": "Usado",
        "Used This Week": "Usado esta semana",
        "Used:": "Usado:",
        "Waiting for sync": "À espera de sincronização",
        "Within active period": "Dentro do período ativo"
    ],
    .portugueseBrazil: [
        "%d seconds short": "%d s",
        "%d minutes short": "%d min",
        "%d minutes %d seconds short": "%d min %d s",
        "%lld days %lld hours short": "%lld d %lld h",
        "%lld hours %lld minutes short": "%lld h %lld min",
        "%d available": "%d disponíveis",
        "%d available reset card": "%d cartão de reset disponível",
        "%d available reset cards": "%d cartões de reset disponíveis",
        "%d days left": "faltam %d d",
        "%@ remaining": "%@ restante",
        "Auto-detect · %@": "Detecção automática · %@",
        "Changes to %@": "Muda para %@",
        "Expires %@": "Expira %@",
        "Every %@": "A cada %@",
        "Failed: %@": "Falha: %@",
        "Granted %@  ~  Expires %@": "Recebido %@  ~  Expira %@",
        "Login item status: %@": "Status de inicialização: %@",
        "Nearest deadline: %@": "Prazo mais próximo: %@",
        "Next %@": "Próximo %@",
        "Reads server quota snapshots every %@.": "Lê snapshots de cota do servidor a cada %@.",
        "Server read failed: %@": "Falha ao ler o servidor: %@",
        "Sync: %@": "Sincronização: %@",
        "The nearest %@ expires %@": "O %@ mais próximo expira %@",
        "The nearest %@ expires %@; the subscription ends or changes on %@.": "O %@ mais próximo expira %@; a assinatura termina ou muda em %@.",
        "%@ expires %@. Use it soon.": "%@ expira %@. Use em breve.",
        "%@ expires %@, but the subscription ends or changes on %@. Use it soon.": "%@ expira %@, mas a assinatura termina ou muda em %@. Use em breve.",
        "Using macOS language: %@": "Usando o idioma do macOS: %@",
        "Acknowledged": "Confirmado",
        "Appearance & Theme": "Aparência e tema",
        "Auto": "Auto",
        "Auto-renews": "Renovação automática",
        "Available This Week": "Disponível esta semana",
        "Available:": "Disponível:",
        "Background auto-refresh monitoring": "Monitoramento com atualização automática",
        "CLI Binary Path": "Caminho do binário CLI",
        "CLI not installed": "CLI não instalada",
        "Cancel": "Cancelar",
        "Cannot choose target": "Não foi possível escolher o destino",
        "Cannot connect": "Não foi possível conectar",
        "Changing": "Mudando",
        "Choose": "Escolher",
        "Choose CLI binary target": "Escolher binário CLI",
        "Choose Codex CLI Executable": "Escolher executável do Codex CLI",
        "Choose from File...": "Escolher de arquivo…",
        "Choose light, dark, or follow the macOS appearance.": "Escolha claro, escuro ou seguir a aparência do macOS.",
        "Connected": "Conectado",
        "Connecting": "Conectando",
        "Copied": "Copiado",
        "Copy Path": "Copiar caminho",
        "Critical": "Crítico",
        "Current period:": "Período atual:",
        "Daily Usage Trend": "Tendência diária de uso",
        "Dark HUD": "HUD escuro",
        "Date": "Data",
        "Disconnected": "Desconectado",
        "Ending": "Encerrando",
        "Engine Dispatch": "Controle do motor",
        "Follow System": "Seguir sistema",
        "Follow the system by default, or pin the interface to a language.": "Segue o sistema por padrão, ou fixa um idioma para a interface.",
        "Free": "Livre",
        "Healthy reserve": "Reserva saudável",
        "Identity Gateway": "Identidade",
        "Interface Language": "Idioma da interface",
        "Interface Theme": "Tema da interface",
        "Last 7 Days": "Últimos 7 dias",
        "Launch at Login": "Iniciar ao entrar",
        "Light": "Claro",
        "Low reserve": "Reserva baixa",
        "Manage appearance, account identity, background scheduling, and local data storage.": "Gerencie aparência, identidade, agendamento em segundo plano e dados locais.",
        "Menu Bar Mode (Hide Dock Icon)": "Modo barra de menus (ocultar Dock)",
        "Missing": "Ausente",
        "Monitor quota usage, reset windows, and model telemetry for the current account.": "Monitora cota, reinícios e telemetria da conta atual.",
        "Nearest reset card is expiring soon": "O cartão de reset mais próximo expira em breve",
        "Needs action": "Requer ação",
        "No account selected": "Nenhuma conta selecionada",
        "No card to remind": "Sem cartão para lembrar",
        "No cards": "Sem cartões",
        "No quota yet": "Sem cota ainda",
        "OK": "OK",
        "Off": "Desativado",
        "Offline": "Offline",
        "On": "Ativado",
        "Open Console": "Abrir console",
        "Overview": "Visão geral",
        "Pending": "Pendente",
        "Primary Quota Channel": "Canal principal de cota",
        "Quit QuotaLens": "Sair do QuotaLens",
        "Quota Health": "Saúde da cota",
        "Ready": "Pronto",
        "Reconnect": "Reconectar",
        "Refresh Account": "Atualizar conta",
        "Refresh Data": "Atualizar dados",
        "Refresh Rate": "Frequência",
        "Refresh data now": "Atualizar agora",
        "Refresh server quota data now": "Atualizar cota do servidor",
        "Remaining": "Restante",
        "Remind in 1 hour": "Lembrar em 1 hora",
        "Remind in 2 hours": "Lembrar em 2 horas",
        "Reset Card Reserve": "Reserva de cartões",
        "Reset Cards": "Cartões de reset",
        "Reset Countdown": "Contagem para reset",
        "Reset Credits Hangar": "Hangar de cartões de reset",
        "Reset card": "Cartão de reset",
        "Reset in:": "Reset em:",
        "Retrying": "Tentando novamente",
        "Run Full Server Re-Probe": "Reanalisar servidor",
        "SQLite database endpoint:": "Banco SQLite:",
        "Settings": "Configurações",
        "Storage Core": "Armazenamento",
        "Subscription": "Assinatura",
        "System": "Sistema",
        "Unknown": "Desconhecido",
        "Unknown Plan": "Plano desconhecido",
        "Used": "Usado",
        "Used This Week": "Usado esta semana",
        "Used:": "Usado:",
        "Waiting for sync": "Aguardando sincronização",
        "Within active period": "Dentro do período ativo"
    ]
]
