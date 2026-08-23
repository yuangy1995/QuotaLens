// Lightweight app localization helper.

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
        switch self {
        case .system:
            return "globe"
        case .english:
            return "textformat.abc"
        case .simplifiedChinese, .traditionalChinese:
            return "character.book.closed.fill"
        case .japanese:
            return "character.phonetic"
        case .korean:
            return "textformat"
        case .spanish, .german, .french, .portuguese, .portugueseBrazil:
            return "text.book.closed.fill"
        }
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
            return keyedTranslations[english]?[language] ?? translations[language]?[english] ?? english
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

    public static func countdown(days: Int64, hours: Int64, minutes: Int64) -> String {
        if days > 0 {
            return format("%lld days %lld hours short", zhHans: "%lld天 %lld小时", days, hours)
        }
        return format("%lld hours %lld minutes short", zhHans: "%lld小时 %lld分钟", hours, minutes)
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
}

private let keyedTranslations: [String: [AppLanguage: String]] = [
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
