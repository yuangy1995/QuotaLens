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
    "Manage appearance, language, account, refresh, and local data.": [
        .traditionalChinese: "管理外觀、語言、帳號、刷新和本機資料。",
        .japanese: "外観、言語、アカウント、更新、ローカルデータを管理します。",
        .korean: "외관, 언어, 계정, 새로고침 및 로컬 데이터를 관리합니다.",
        .spanish: "Gestiona apariencia, idioma, cuenta, actualización y datos locales.",
        .german: "Darstellung, Sprache, Konto, Aktualisierung und lokale Daten verwalten.",
        .french: "Gérez l’apparence, la langue, le compte, l’actualisation et les données locales.",
        .portuguese: "Gira aspeto, idioma, conta, atualização e dados locais.",
        .portugueseBrazil: "Gerencie aparência, idioma, conta, atualização e dados locais."
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
    "Monitor quota usage and reset windows for the current account.": [
        .traditionalChinese: "監測目前帳號的額度使用與重置週期。",
        .japanese: "現在のアカウントのクォータ使用量とリセット周期を監視します。",
        .korean: "현재 계정의 할당량 사용량과 리셋 주기를 모니터링합니다.",
        .spanish: "Supervisa el uso de cuota y los periodos de reinicio de la cuenta actual.",
        .german: "Quota-Nutzung und Reset-Zeiträume für das aktuelle Konto überwachen.",
        .french: "Surveille l’utilisation du quota et les périodes de réinitialisation du compte actuel.",
        .portuguese: "Monitoriza a utilização da quota e os períodos de reinício da conta atual.",
        .portugueseBrazil: "Monitora o uso da cota e os períodos de reinício da conta atual."
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
