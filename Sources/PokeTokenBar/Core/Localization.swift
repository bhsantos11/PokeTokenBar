import Foundation

/// 앱 전체 UI 문자열 — 언어별. 단일 소스(AppLanguage)에서 파생한다.
/// 뷰는 `companion.l.<key>` 로 접근하며, language 변경 시 @Observable 로 자동 재렌더된다.
/// 포켓몬 이름은 PokéAPI 다국어 데이터(EvoLine.localizedName)에서 별도로 온다.
struct L {
    let lang: AppLanguage
    init(_ lang: AppLanguage) { self.lang = lang }

    private func t(_ ko: String, _ en: String, _ ja: String, _ es: String) -> String {
        switch lang {
        case .ko: return ko
        case .en: return en
        case .ja: return ja
        case .es: return es
        }
    }

    // MARK: 탭
    var home: String { t("홈", "Home", "ホーム", "Inicio") }
    /// 상위 탭 이름 — 안에서 도감/포획 로그를 세그먼트로 전환하므로 둘을 아우르는 말이어야 한다.
    /// (ko 가 "도감"이면 탭과 세그먼트가 같은 이름이 돼 en/ja 의 Collection/コレクション 과도 어긋난다.)
    var collection: String { t("컬렉션", "Collection", "コレクション", "Colección") }

    // MARK: 헤더 (오늘/주/월)
    var todayTokens: String { t("오늘 사용한 토큰", "Today's tokens", "本日のトークン", "Tokens de hoy") }
    var thisWeek: String { t("이번 주", "This week", "今週", "Esta semana") }
    var thisMonth: String { t("이번 달", "This month", "今月", "Este mes") }

    // MARK: 한도 섹션
    var limitsOfficial: String { t("한도 (공식)", "Limits (official)", "上限（公式）", "Límites (oficial)") }
    var fiveHourSession: String { t("5시간 세션", "5-hour session", "5時間セッション", "Sesión de 5 horas") }
    var weekly: String { t("주간", "Weekly", "週間", "Semanal") }
    var weeklyOpus: String { t("주간 Opus", "Weekly Opus", "週間 Opus", "Opus semanal") }
    var weeklySonnet: String { t("주간 Sonnet", "Weekly Sonnet", "週間 Sonnet", "Sonnet semanal") }
    var claudeCurrentBlock: String { t("Claude 현재 5h 블록", "Claude current 5h block", "Claude 現在の5hブロック", "Bloque actual de 5h de Claude") }
    var reset: String { t("리셋", "Reset", "リセット", "Reinicio") }
    var limitReached: String { t("한도 도달", "Limit reached", "上限到達", "Límite alcanzado") }
    var personalSpendLimit: String { t("개인 사용 한도", "Personal spend limit", "個人利用上限", "Límite de gasto personal") }
    var staleLimits: String { t("갱신 지연", "Stale", "更新遅延", "Desactualizado") }
    var refresh: String { t("갱신", "Refresh", "更新", "Actualizar") }
    var limitsTapToLoad: String { t("공식 한도 불러오기", "Load official limits", "公式上限を読み込む", "Cargar límites oficiales") }
    /// 값 없이 한도 카드를 그릴 때(첫 폴 전). macOS 의 "불러오기" 버튼과 달리 Linux 는 Keychain
    /// 프롬프트가 없어 자동 폴이 그대로 읽으므로, 누를 것이 아니라 기다리면 된다는 것만 알린다.
    var limitsLoading: String { t("공식 한도를 불러오는 중이에요…", "Loading official limits…", "公式上限を読み込み中…", "Cargando límites oficiales…") }

    /// 프로바이더 상태 페이지 인시던트 지표 → 현지화 라벨(표시 전용).
    func providerStatusLabel(_ indicator: ProviderStatusIndicator) -> String {
        switch indicator {
        case .operational: return t("정상", "Operational", "正常", "Operativo")
        case .minor:       return t("일부 장애", "Minor issues", "一部障害", "Problemas menores")
        case .major:       return t("장애", "Major outage", "障害", "Interrupción grave")
        case .critical:    return t("심각한 장애", "Critical outage", "重大障害", "Interrupción crítica")
        case .maintenance: return t("점검 중", "Maintenance", "メンテナンス", "Mantenimiento")
        case .unknown:     return t("상태 불명", "Status unknown", "状態不明", "Estado desconocido")
        }
    }
    func plan(_ p: String) -> String { t("플랜 \(p)", "Plan \(p)", "プラン \(p)", "Plan \(p)") }
    func forecastReach(_ time: String) -> String {
        t("현재 속도면 \(time) 한도 도달", "At current rate, limit hit at \(time)", "現在のペースで \(time) に上限到達", "Al ritmo actual, límite alcanzado a las \(time)")
    }
    var forecastNoReach: String {
        t("현재 속도로는 리셋 전 한도 도달 없음", "Won't hit limit before reset at current rate", "現在のペースではリセット前に上限到達なし", "Al ritmo actual, no alcanzarás el límite antes del reinicio")
    }

    /// Claude oauth/usage 신형 limits[] 엔트리 이름 — kind + 모델 스코프 기반.
    func claudeLimitEntry(kind: String?, model: String?) -> String {
        switch kind {
        case "session": return fiveHourSession
        case "weekly_all": return weekly
        case "weekly_scoped":
            // 모델명이 없으면 레거시 "주간" 행과 이름이 겹치므로 scoped 임을 구분 표기
            guard let model else { return t("주간 (모델별)", "Weekly (scoped)", "週間（モデル別）", "Semanal (por modelo)") }
            return t("주간 \(model)", "Weekly \(model)", "週間 \(model)", "Semanal \(model)")
        default:
            let base = kind ?? "limit"
            let name = model.map { " \($0)" } ?? ""
            return base.replacingOccurrences(of: "_", with: " ") + name
        }
    }

    /// Codex 한도 윈도우 이름 (windowDurationMins 기반). 알림·팝오버 공통.
    func codexWindow(_ mins: Int?) -> String {
        switch mins {
        case 300: return fiveHourSession
        case 10_080: return weekly
        case let m? where m >= 60 && m % 60 == 0:
            let h = m / 60
            return t("\(h)시간", "\(h)h", "\(h)時間", "\(h)h")
        case let m?: return t("\(m)분", "\(m)m", "\(m)分", "\(m)m")
        case nil: return t("한도", "Limit", "上限", "Límite")
        }
    }

    // MARK: 푸터
    var refreshNow: String { t("지금 새로고침", "Refresh now", "今すぐ更新", "Actualizar ahora") }
    /// Tray menu item that opens the main window. macOS opens the popover by clicking the status
    /// item; a StatusNotifierItem click opens the menu instead, so Linux needs an explicit entry.
    var openWindow: String { t("열기", "Open", "開く", "Abrir") }
    /// First state of the tray menu summary row, before any usage has been read.
    var loading: String { t("불러오는 중…", "Loading…", "読み込み中…", "Cargando…") }
    var updated: String { t("갱신", "Updated", "更新", "Actualizado") }
    var settings: String { t("설정", "Settings", "設定", "Ajustes") }
    var back: String { t("뒤로", "Back", "戻る", "Atrás") }
    var generalSectionTitle: String { t("일반", "General", "一般", "General") }
    var menuBarSectionTitle: String { t("메뉴바에 표시", "Show in menu bar", "メニューバーに表示", "Mostrar en la barra de menús") }
    var advancedSectionTitle: String { t("고급", "Advanced", "詳細", "Avanzado") }
    var advancedDisclosureLabel: String { t("고급 설정 · 진단", "Advanced · diagnostics", "詳細設定・診断", "Avanzado · diagnóstico") }
    var aboutSupportSectionTitle: String { t("정보 & 지원", "About & Support", "情報とサポート", "Acerca de y soporte") }
    var quit: String { t("종료", "Quit", "終了", "Salir") }

    // MARK: 설정
    var refreshInterval: String { t("새로고침 간격", "Refresh interval", "更新間隔", "Intervalo de actualización") }
    var language: String { t("언어", "Language", "言語", "Idioma") }
    var menuBarItems: String { t("메뉴바 표시 항목 (복수 선택)", "Menu bar items (multi-select)", "メニューバー表示項目（複数選択）", "Elementos de la barra de menús (selección múltiple)") }
    var todayTokensShort: String { t("오늘 토큰", "Today's tokens", "本日のトークン", "Tokens de hoy") }
    var todayCost: String { t("오늘 비용 ($)", "Today's cost ($)", "本日のコスト ($)", "Coste de hoy ($)") }
    var limitPercent: String { t("한도 %", "Limit %", "上限 %", "Límite %") }
    var limitDisplayModeLabel: String { t("한도 표시 방식", "Limit display", "上限の表示", "Visualización del límite") }
    var limitDisplayUsed: String { t("사용량", "Used", "使用量", "Usado") }
    var limitDisplayRemaining: String { t("남은 양", "Remaining", "残量", "Restante") }
    /// 팝오버 한도 행의 remaining 모드 표시 — %에 자기설명 접미사를 붙인다.
    func percentRemaining(_ percent: String) -> String {
        t("\(percent) 남음", "\(percent) left", "残り\(percent)", "\(percent) restante")
    }
    var allOffHint: String { t("전부 끄면 캐릭터만 표시됩니다", "All off shows only the character", "すべてオフにするとキャラクターのみ表示", "Si desactivas todo, solo se mostrará el personaje") }
    // MARK: 플로팅 펫
    var floatingPetSectionTitle: String { t("플로팅 펫", "Floating Pet", "フローティングペット", "Mascota flotante") }
    var floatingPetEnableLabel: String { t("플로팅 펫 표시", "Show floating pet", "フローティングペットを表示", "Mostrar mascota flotante") }
    var floatingPetHint: String {
        t("포켓몬이 화면 위에 떠 있어요 — 드래그로 위치를 옮길 수 있어요",
          "Your Pokémon floats over the screen — drag to reposition",
          "ポケモンが画面の上に浮かびます — ドラッグで移動できます",
          "Tu Pokémon flota sobre la pantalla — arrástralo para moverlo")
    }
    var floatingPetSizeLabel: String { t("크기", "Size", "サイズ", "Tamaño") }
    /// 지금은 한도 알림만 말풍선으로 뜨지만, 알림 종류가 늘어도 이 라벨은 그대로 쓴다.
    var floatingPetBubbleAlertsLabel: String {
        t("말풍선으로 알림 받기", "Show notifications as bubbles", "通知を吹き出しで表示", "Mostrar notificaciones como globos")
    }
    var floatingPetMenuOpen: String { t("토큰 바 열기", "Open Token Bar", "トークンバーを開く", "Abrir Token Bar") }
    var floatingPetMenuHide: String {
        t("플로팅 펫 끄기", "Turn off floating pet", "フローティングペットをオフ", "Desactivar mascota flotante")
    }
    func floatingPetHoverTokensOnly(_ tokens: String) -> String {
        t("오늘 \(tokens) 토큰", "Today: \(tokens) tokens", "今日: \(tokens) トークン", "Hoy: \(tokens) tokens")
    }
    func floatingPetHoverWithLimit(_ tokens: String, _ percent: String) -> String {
        t("오늘 \(tokens) 토큰 (한도 \(percent))",
          "Today: \(tokens) tokens (limit \(percent))",
          "今日: \(tokens) トークン（上限 \(percent)）",
          "Hoy: \(tokens) tokens (límite \(percent))")
    }

    var disableKeychain: String { t("Keychain 접근 끄기", "Disable Keychain access", "Keychainアクセスを無効化", "Desactivar acceso a Keychain") }
    var disableKeychainHint: String { t("켜면 Keychain 접근 허용 팝업이 더 안 뜹니다 — 공식 한도(%)만 숨겨지고 토큰·비용은 그대로", "When on, no more Keychain permission pop-ups — only official limits (%) are hidden; tokens/cost stay", "オンにするとKeychain許可のポップアップが出なくなります — 公式上限(%)のみ非表示、トークン・費用はそのまま", "Al activarlo, ya no aparecerán los avisos de permiso de Keychain — solo se ocultan los límites oficiales (%), los tokens y el coste se mantienen") }
    /// Shown under the Keychain toggle on Linux, where there is no Keychain at all — the app reads
    /// `~/.claude/.credentials.json` directly. The setting still exists and is still honoured by the
    /// shared code, so saying so beats a switch that appears to do nothing.
    var disableKeychainLinuxNote: String {
        t("Linux 에는 Keychain 이 없어 이 설정은 동작에 영향이 없습니다 — 자격증명은 ~/.claude/.credentials.json 에서 읽습니다.",
          "Linux has no Keychain, so this setting changes nothing here — credentials are read from ~/.claude/.credentials.json.",
          "Linux には Keychain がないため、この設定は動作に影響しません — 認証情報は ~/.claude/.credentials.json から読み取ります。",
          "Linux no tiene Keychain, así que este ajuste no cambia nada aquí — las credenciales se leen de ~/.claude/.credentials.json.")
    }

    var refreshLimitToken: String { t("한도 토큰 캐시 갱신", "Refresh limit token cache", "上限トークンキャッシュを更新", "Actualizar caché del token de límite") }
    var onlyOnPress: String { t("누를 때만 Keychain 을 읽어요 — 자동 폴링은 안 읽어 팝업이 안 떠요. 토큰 만료 후 이 버튼으로 한도 갱신", "Reads Keychain only when pressed — auto-polling never does, so no pop-ups. Refresh limits here after the token expires", "押した時のみKeychainを読みます — 自動更新では読まずポップアップも出ません。トークン期限切れ後はこのボタンで上限を更新", "Solo lee Keychain al pulsar — el sondeo automático nunca lo hace, así que no aparecen avisos. Usa este botón para actualizar los límites tras la expiración del token") }
    var launchAtLogin: String { t("로그인 시 자동 시작", "Launch at login", "ログイン時に自動起動", "Iniciar al arrancar sesión") }
    var bundledOnly: String { t(".app 번들로 설치된 경우에만 사용 가능 (scripts/build-app.sh)", "Available only when installed as an .app bundle (scripts/build-app.sh)", ".appバンドルでインストールした場合のみ利用可能 (scripts/build-app.sh)", "Disponible solo si se instaló como paquete .app (scripts/build-app.sh)") }
    var notificationsSection: String { t("알림", "Notifications", "通知", "Notificaciones") }
    var limitNotificationsLabel: String { t("한도 알림", "Limit alerts", "上限通知", "Alertas de límite") }
    var companionNotificationsLabel: String { t("Companion 이벤트 (부화·진화·졸업)", "Companion events (hatch / evolve / graduate)", "コンパニオンイベント（孵化・進化・卒業）", "Eventos del compañero (eclosión / evolución / graduación)") }
    var statusChecksLabel: String { t("프로바이더 상태 확인", "Provider status checks", "プロバイダー状態チェック", "Comprobación de estado de proveedores") }
    var statusChecksHint: String { t("Claude·OpenAI 장애를 팝오버에 표시 (알림 아님)", "Show Claude / OpenAI incidents in the popover (not a notification)", "Claude・OpenAIの障害をポップオーバーに表示（通知ではない）", "Muestra incidentes de Claude/OpenAI en el popover (no es una notificación)") }
    var warning: String { t("경고", "Warning", "警告", "Aviso") }
    var critical: String { t("임박", "Critical", "切迫", "Crítico") }
    var aggregationNote: String { t("토큰 집계 기준: totalTokens (input + output + cache, 로컬 날짜)", "Token basis: totalTokens (input + output + cache, local date)", "集計基準: totalTokens (input + output + cache, ローカル日付)", "Base de cálculo: totalTokens (input + output + cache, fecha local)") }
    var close: String { t("닫기", "Close", "閉じる", "Cerrar") }

    // MARK: 세이브 이전 (설정 → 백업 & 이전)
    var transferSectionTitle: String { t("백업 & 이전", "Backup & Transfer", "バックアップと移行", "Copia de seguridad y transferencia") }
    var exportSaveLabel: String { t("세이브 내보내기", "Export save", "セーブを書き出す", "Exportar partida") }
    var exportSaveHint: String {
        t("도감·누적 토큰·가방·현재 포켓몬을 파일 하나로 저장해요",
          "Saves your Pokédex, lifetime tokens, Bag, and current Pokémon as one file",
          "図鑑・累計トークン・バッグ・現在のポケモンを1つのファイルに保存します",
          "Guarda tu Pokédex, tokens acumulados, Bolsa y Pokémon actual en un solo archivo")
    }
    var exportSaveButton: String { t("내보내기…", "Export…", "書き出す…", "Exportar…") }
    var importSaveLabel: String { t("세이브 불러오기", "Import save", "セーブを読み込む", "Importar partida") }
    var importSaveHint: String {
        t("다른 Mac에서 내보낸 파일을 골라 이 Mac으로 이어서 키워요",
          "Pick a file exported from another Mac and continue here",
          "他のMacから書き出したファイルを選んでこのMacで続けます",
          "Elige un archivo exportado desde otro Mac y continúa aquí")
    }
    var importSaveButton: String { t("불러오기…", "Import…", "読み込む…", "Importar…") }
    var importConfirmTitle: String {
        t("이 Mac의 진행을 대체할까요?", "Replace this Mac's progress?", "このMacの進行を置き換えますか？", "¿Reemplazar el progreso de este Mac?")
    }
    /// 무엇이 사라지는지 수치로 적는다 — 일반적인 "정말 진행할까요?" 보다 판단에 실제로 쓸모 있다.
    /// 내보낸 시각·출처 기기를 함께 보여주는 이유: 도감 수가 같으면 3주 전 세이브도 문구가 똑같아,
    /// 오래된 파일을 되돌리는 상황을 사용자가 알아챌 단서가 없다.
    func importConfirmBody(incomingDex: Int, incomingTokens: String,
                           exportedAt: String, sourceDevice: String,
                           currentDex: Int, currentTokens: String) -> String {
        t("""
          불러올 세이브: 도감 \(incomingDex)마리 · 누적 \(incomingTokens)
          내보낸 시각: \(exportedAt) · \(sourceDevice)
          현재 이 Mac: 도감 \(currentDex)마리 · 누적 \(currentTokens)

          이 Mac의 현재 진행은 대체됩니다. 직전 상태는 상태 폴더에 백업으로 남습니다(최근 5개).
          """,
          """
          Incoming save: \(incomingDex) in Pokédex · \(incomingTokens) lifetime
          Exported: \(exportedAt) · \(sourceDevice)
          This Mac now: \(currentDex) in Pokédex · \(currentTokens) lifetime

          This Mac's current progress is replaced. The previous state is kept as a backup in the state folder (last 5).
          """,
          """
          読み込むセーブ: 図鑑 \(incomingDex)匹 · 累計 \(incomingTokens)
          書き出し日時: \(exportedAt) · \(sourceDevice)
          現在のこのMac: 図鑑 \(currentDex)匹 · 累計 \(currentTokens)

          このMacの現在の進行は置き換えられます。直前の状態は状態フォルダにバックアップとして残ります（最新5件）。
          """,
          """
          Partida a importar: Pokédex \(incomingDex) · \(incomingTokens) acumulados
          Exportada: \(exportedAt) · \(sourceDevice)
          Este Mac ahora: Pokédex \(currentDex) · \(currentTokens) acumulados

          El progreso actual de este Mac será reemplazado. El estado anterior se guarda como copia de seguridad en la carpeta de estado (últimas 5).
          """)
    }
    var importConfirmReplace: String { t("대체", "Replace", "置き換える", "Reemplazar") }
    func importSaveDone(dex: Int, tokens: String) -> String {
        t("불러왔어요 — 도감 \(dex)마리 · 누적 \(tokens)",
          "Imported — \(dex) in Pokédex · \(tokens) lifetime",
          "読み込みました — 図鑑 \(dex)匹 · 累計 \(tokens)",
          "Importado — Pokédex \(dex) · \(tokens) acumulados")
    }
    var importErrorNotSaveFile: String {
        t("PokeTokenBar 세이브 파일이 아니에요.",
          "That isn't a PokeTokenBar save file.",
          "PokeTokenBar のセーブファイルではありません。",
          "Ese no es un archivo de partida de PokeTokenBar.")
    }
    var importErrorNewerSchema: String {
        t("더 새로운 버전에서 만든 세이브예요 — 앱을 업데이트한 뒤 다시 시도해 주세요.",
          "This save was made by a newer version — update the app and try again.",
          "より新しいバージョンで作成されたセーブです — アプリを更新してから再試行してください。",
          "Esta partida se creó con una versión más reciente — actualiza la app e inténtalo de nuevo.")
    }
    /// 불러오기 실패 사유 → 사용자 문구. 뷰가 아니라 여기 두는 이유는 이 매핑이 테스트 가능해야 하기
    /// 때문이다 — 매핑이 어긋나면 `SaveTransferError` 는 LocalizedError 가 아니라서 "The operation
    /// couldn't be completed…" 같은 원문이 그대로 노출된다(조용한 품질 저하).
    func importErrorMessage(_ error: Error) -> String {
        switch error {
        case SaveTransferError.notASaveFile:  return importErrorNotSaveFile
        case SaveTransferError.newerSchema:   return importErrorNewerSchema
        case SaveTransferError.fileTooLarge:  return importErrorTooLarge
        case SaveTransferError.backupFailed:  return importErrorBackupFailed
        default: return error.localizedDescription
        }
    }
    var importErrorTooLarge: String {
        t("세이브 파일이라기엔 너무 커요 — 다른 파일을 고른 것 같아요.",
          "That file is too large to be a save — it looks like the wrong file.",
          "セーブファイルにしては大きすぎます — 別のファイルを選んだようです。",
          "Ese archivo es demasiado grande para ser una partida — parece que elegiste el archivo equivocado.")
    }
    /// 백업을 못 남기면 불러오기를 중단한다 — 되돌릴 수단 없이 진행을 대체하지 않기 위해서다.
    var importErrorBackupFailed: String {
        t("현재 상태를 백업하지 못해 불러오기를 중단했어요 — 진행은 그대로예요. 디스크 여유 공간을 확인해 주세요.",
          "Import stopped because the current state couldn't be backed up — your progress is untouched. Check free disk space.",
          "現在の状態をバックアップできなかったため読み込みを中止しました — 進行はそのままです。ディスクの空き容量を確認してください。",
          "Se detuvo la importación porque no se pudo hacer una copia de seguridad del estado actual — tu progreso no se ha tocado. Comprueba el espacio libre en disco.")
    }

    // MARK: 문제점 알리기 (설정 → 메일 리포트)
    var reportProblem: String { t("문제점 알리기", "Report a problem", "問題を報告", "Reportar un problema") }
    var showLogFile: String { t("로그 파일 보기", "Show log file", "ログファイルを表示", "Mostrar archivo de registro") }
    var reportAttachHint: String {
        t("메일에 로그 파일을 첨부해 주시면 원인 파악에 큰 도움이 돼요.",
          "Attaching the log file to the email helps a lot with diagnosis.",
          "メールにログファイルを添付していただくと原因の特定に役立ちます。",
          "Adjuntar el archivo de registro al correo ayuda mucho a diagnosticar el problema.")
    }
    func reportMailFallback(_ address: String) -> String {
        t("메일 앱을 열 수 없어요. \(address) 로 직접 보내주세요.",
          "Couldn't open a mail app. Please email \(address) directly.",
          "メールアプリを開けません。\(address) 宛に直接お送りください。",
          "No se pudo abrir una app de correo. Escribe directamente a \(address).")
    }
    func reportMailSubject(_ version: String) -> String {
        t("[PokeTokenBar] 문제 리포트 (v\(version))",
          "[PokeTokenBar] Problem report (v\(version))",
          "[PokeTokenBar] 問題レポート (v\(version))",
          "[PokeTokenBar] Reporte de problema (v\(version))")
    }
    func reportMailBody(version: String, os: String) -> String {
        t("""
        문제 내용:
        (겪으신 문제를 적어주세요 — 언제, 어떤 화면에서, 어떻게 되었는지)


        ---
        앱 버전: v\(version)
        macOS: \(os)
        로그 파일(첨부 권장): ~/Library/Logs/PokeTokenBar.log
        """,
        """
        What happened:
        (Describe the problem — when, on which screen, and what you saw)


        ---
        App version: v\(version)
        macOS: \(os)
        Log file (please attach): ~/Library/Logs/PokeTokenBar.log
        """,
        """
        問題の内容:
        （いつ・どの画面で・どうなったかをご記入ください）


        ---
        アプリのバージョン: v\(version)
        macOS: \(os)
        ログファイル（添付推奨）: ~/Library/Logs/PokeTokenBar.log
        """,
        """
        Descripción del problema:
        (Describe lo que ocurrió — cuándo, en qué pantalla y qué viste)


        ---
        Versión de la app: v\(version)
        macOS: \(os)
        Archivo de registro (se recomienda adjuntar): ~/Library/Logs/PokeTokenBar.log
        """)
    }

    /// 새로고침 간격 라벨 (초 단위 값 → 표시). 0 = 수동.
    func intervalLabel(_ seconds: TimeInterval) -> String {
        if seconds == 0 { return t("수동", "Manual", "手動", "Manual") }
        let m = Int(seconds / 60)
        return t("\(m)분", "\(m) min", "\(m)分", "\(m) min")
    }

    // MARK: 컴패니언
    var finalForm: String { t("최종 진화체", "Final form", "最終進化", "Forma final") }
    func stage(_ i: Int, _ k: Int) -> String { t("진화 단계 \(i) / \(k)", "Stage \(i) / \(k)", "進化段階 \(i) / \(k)", "Etapa \(i) / \(k)") }
    var unknownNextEvolution: String { t("알 수 없는 다음 진화", "Unknown next evolution", "次の進化先は不明", "Próxima evolución desconocida") }
    var eggIncubating: String { t("🥚 부화 준비 중", "🥚 Incubating", "🥚 孵化の準備中", "🥚 Incubando") }
    func eggToHatch(_ amount: String) -> String { t("부화까지 \(amount)", "\(amount) to hatch", "孵化まで \(amount)", "\(amount) para eclosionar") }
    func toNextEvolution(_ amount: String) -> String { t("다음 진화까지 \(amount)", "\(amount) to next evolution", "次の進化まで \(amount)", "\(amount) para la siguiente evolución") }
    func toGraduation(_ amount: String) -> String { t("졸업까지 \(amount)", "\(amount) to graduation", "卒業まで \(amount)", "\(amount) para graduarse") }
    func graduated(_ name: String) -> String {
        t("\(name) 졸업 → 도감에 보존. 새 Token Egg가 도착했어요!",
          "\(name) graduated → saved to the dex. A new Token Egg has arrived!",
          "\(name) 卒業 → 図鑑に保存。新しいToken Eggが届きました！",
          "\(name) se graduó → guardado en la Pokédex. ¡Ha llegado un nuevo Token Egg!")
    }
    var dexEmptyTitle: String { t("아직 잡은 포켓몬이 없어요!", "No Pokémon caught yet!", "まだ捕まえたポケモンがいません！", "¡Todavía no has capturado ningún Pokémon!") }
    var dexEmptyHint: String { t("토큰을 써서 첫 포켓몬을 부화시켜 보세요.", "Spend tokens to hatch your first Pokémon.", "トークンを使って最初のポケモンを孵化させましょう。", "Usa tokens para eclosionar tu primer Pokémon.") }

    // MARK: 도감 요약 헤더
    var dexTitle: String { t("도감", "Pokédex", "図鑑", "Pokédex") }
    func dexTotal(_ n: Int) -> String { t("총 \(n)마리", "\(n) total", "全\(n)匹", "\(n) en total") }
    /// 포획 로그 = 개체 단위 기록(같은 라인 중복이 정상). 도감 = 종 단위 집계.
    var catchLogTitle: String { t("포획 로그", "Catch log", "捕獲ログ", "Registro de capturas") }

    // MARK: 박스(PC) — 알 구매로 물러난 개체들이 사는 곳
    var boxTitle: String { t("박스", "Box", "ボックス", "Caja") }
    var boxEmptyTitle: String { t("박스가 비어 있어요", "Your Box is empty", "ボックスは空です", "Tu Caja está vacía") }
    var boxEmptyHint: String {
        t("알을 사면 지금 포켓몬이 여기로 들어와요. 언제든 다시 꺼낼 수 있어요.",
          "Buy an egg and your current Pokémon moves here. You can bring it back any time.",
          "タマゴを買うと今のポケモンがここに入ります。いつでも戻せます。",
          "Compra un huevo y tu Pokémon actual vendrá aquí. Puedes recuperarlo cuando quieras.")
    }
    var boxWithdraw: String { t("데리고 나가기", "Take out", "つれていく", "Sacar") }
    var boxRelease: String { t("놓아주기", "Release", "にがす", "Soltar") }
    func boxReleaseConfirm(_ name: String) -> String {
        t("\(name)을(를) 놓아줄까요? 되돌릴 수 없어요.",
          "Release \(name)? This cannot be undone.",
          "\(name) をにがしますか？ 取り消せません。",
          "¿Soltar a \(name)? No se puede deshacer.")
    }
    /// 교대라는 점을 버튼 옆에서 알린다 — 누르면 지금 개체가 박스로 들어간다.
    func boxSwapHint(_ name: String) -> String {
        t("\(name)은(는) 박스로 들어가요", "\(name) goes into the Box", "\(name) はボックスに入ります",
          "\(name) irá a la Caja")
    }
    var boxHeldEggTitle: String { t("보관 중인 알", "Egg on hold", "預けているタマゴ", "Huevo en espera") }
    var boxHeldEggHint: String {
        t("품던 알을 옆에 두었어요. 돌아가면 그대로 이어서 품어요.",
          "Your egg is set aside. Go back to it and incubation continues where it left off.",
          "タマゴを横に置いています。戻ればそのまま孵化を続けます。",
          "Tu huevo está apartado. Vuelve a él y la incubación continuará donde lo dejaste.")
    }
    var boxReturnToEgg: String { t("알로 돌아가기", "Back to the egg", "タマゴに戻る", "Volver al huevo") }
    /// 상점에서 알 구매가 막힌 이유 — 보류된 알이 있으면 새 알을 팔지 않는다.
    var boxHeldEggBlocksPurchase: String {
        t("보관 중인 알이 있어요 — 먼저 그 알로 돌아가세요.",
          "You already have an egg on hold — go back to it first.",
          "預けているタマゴがあります — 先にそちらへ戻ってください。",
          "Ya tienes un huevo en espera — vuelve a él primero.")
    }
    var boxGrowth: String { t("성장", "Growth", "成長", "Crecimiento") }

    // MARK: 쓰다듬기 반응 (클릭) — 상태마다 다른 말. 자는 애가 응원하면 화면이 스스로 모순된다.
    func petReactions(state: CompanionStateKind, name: String) -> [String] {
        switch state {
        case .sleep:
            return [t("\(name)은(는) 새근새근 자고 있어요.", "\(name) is fast asleep.",
                      "\(name) はぐっすり眠っています。", "\(name) está profundamente dormido."),
                    t("…zzZ", "…zzZ", "…zzZ", "…zzZ"),
                    t("\(name)이(가) 뒤척였어요.", "\(name) stirs a little.",
                      "\(name) が寝返りをうちました。", "\(name) se remueve un poco.")]
        case .tired:
            return [t("\(name)이(가) 좀 지쳐 보여요.", "\(name) looks worn out.",
                      "\(name) は少し疲れているようです。", "\(name) parece agotado."),
                    t("\(name)이(가) 하품을 했어요.", "\(name) yawns.",
                      "\(name) があくびをしました。", "\(name) bosteza."),
                    t("슬슬 쉬어 갈까요?", "Maybe time for a break?",
                      "そろそろ休憩しませんか？", "¿Quizá es hora de un descanso?")]
        case .focus:
            return [t("\(name)이(가) 잔뜩 신이 났어요!", "\(name) is fired up!",
                      "\(name) はやる気まんまんです！", "¡\(name) está a tope!"),
                    t("\(name)이(가) 빙글빙글 돌았어요!", "\(name) spins around!",
                      "\(name) がくるくる回りました！", "¡\(name) da vueltas!"),
                    t("좋은 흐름이에요!", "You two are on a roll!",
                      "いい調子です！", "¡Vais a buen ritmo!")]
        case .egg:
            return [t("알이 살짝 흔들렸어요.", "The egg wobbles a little.",
                      "タマゴが少し揺れました。", "El huevo se mueve un poco."),
                    t("안에서 무언가 움직여요…", "Something moves inside…",
                      "中で何かが動いています…", "Algo se mueve dentro…"),
                    t("조금만 더 기다려요.", "Just a little longer.",
                      "もう少しの辛抱です。", "Solo un poco más.")]
        default:
            return [t("\(name)이(가) 당신을 올려다봤어요.", "\(name) looks up at you.",
                      "\(name) があなたを見上げました。", "\(name) te mira."),
                    t("\(name)이(가) 기분 좋아 보여요.", "\(name) seems happy.",
                      "\(name) はごきげんです。", "\(name) parece contento."),
                    t("\(name)이(가) 폴짝 뛰었어요!", "\(name) gives a little hop!",
                      "\(name) がぴょんと跳ねました！", "¡\(name) da un saltito!"),
                    t("\(name)이(가) 코를 비볐어요.", "\(name) nuzzles your cursor.",
                      "\(name) が鼻をすり寄せました。", "\(name) se acurruca en tu cursor.")]
        }
    }
    func petReactionFallback(_ name: String) -> String {
        t("\(name)이(가) 반응했어요.", "\(name) reacts.", "\(name) が反応しました。", "\(name) reacciona.")
    }

    // MARK: 이름 바꾸기
    var nicknameTitle: String { t("이름 바꾸기", "Rename", "ニックネーム", "Cambiar nombre") }
    var nicknameHint: String {
        t("비워 두면 종 이름으로 돌아가요.", "Leave empty to use the species name.",
          "空にすると種の名前に戻ります。", "Déjalo vacío para usar el nombre de la especie.")
    }
    var save: String { t("저장", "Save", "保存", "Guardar") }
    var renameTooltip: String { t("눌러서 이름 바꾸기", "Click to rename", "クリックで名前を変更", "Clic para renombrar") }
    var petTooltip: String { t("눌러서 쓰다듬기", "Click to pet", "クリックでなでる", "Clic para acariciar") }
    var floatingPetMenuPet: String { t("쓰다듬기", "Pet", "なでる", "Acariciar") }
    // MARK: 일지(Chronicle) — 사건을 문장으로. 저장은 사건만 하고 문장은 읽을 때 만든다.
    var chronicleTitle: String { t("일지", "Chronicle", "日誌", "Crónica") }

    // MARK: 없는 동안 있었던 일
    var awayTitle: String { t("그동안 있었던 일", "While you were away", "留守のあいだに", "Mientras no estabas") }
    /// 셋을 한 줄로. 0인 항목은 아예 빼서 "0마리 부화" 같은 말을 만들지 않는다.
    func awayCounts(hatched: Int, evolved: Int, graduated: Int, shinies: Int) -> String {
        var parts: [String] = []
        if hatched > 0 {
            parts.append(t("부화 \(hatched)", "\(hatched) hatched", "孵化 \(hatched)", "\(hatched) eclosionados"))
        }
        if evolved > 0 {
            parts.append(t("진화 \(evolved)", "\(evolved) evolved", "進化 \(evolved)", "\(evolved) evolucionados"))
        }
        if graduated > 0 {
            parts.append(t("졸업 \(graduated)", "\(graduated) graduated", "卒業 \(graduated)", "\(graduated) graduados"))
        }
        if shinies > 0 {
            parts.append(t("이로치 \(shinies)", "\(shinies) shiny", "色違い \(shinies)", "\(shinies) variocolor"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 트레이너 카드
    var trainerTab: String { t("트레이너", "Trainer", "トレーナー", "Entrenador") }
    var trainerCardTitle: String { t("트레이너 카드", "Trainer Card", "トレーナーカード", "Tarjeta de entrenador") }
    var trainerNoName: String { t("이름을 정해 주세요", "Choose a name", "名前を決めましょう", "Elige un nombre") }
    var trainerNameTooltip: String { t("눌러서 이름 정하기", "Click to set your name", "クリックで名前を設定", "Clic para poner tu nombre") }
    /// 트레이너 이름 편집의 안내. 애칭 안내("비우면 종 이름")를 재사용하면 안 된다 — 트레이너에겐
    /// 돌아갈 종 이름이 없다. 같은 위젯을 공유해도 문구는 각자의 것이어야 한다.
    var trainerNameHint: String {
        t("카드와 내보낸 이미지에 표시돼요.", "Shown on your card and any image you export.",
          "カードと書き出した画像に表示されます。", "Aparece en tu tarjeta y en las imágenes que exportes.")
    }
    var trainerSpecies: String { t("도감", "Pokédex", "図鑑", "Pokédex") }
    var trainerShiny: String { t("이로치", "Shiny", "色違い", "Variocolor") }
    var trainerGraduations: String { t("졸업", "Graduated", "卒業", "Graduados") }
    var trainerParty: String { t("동행", "With you", "手持ち", "Contigo") }
    var trainerBox: String { t("박스", "In the Box", "ボックス", "En la Caja") }
    var trainerLifetime: String { t("누적 토큰", "Lifetime tokens", "累計トークン", "Tokens acumulados") }
    var trainerSpent: String { t("상점 지출", "Spent in the shop", "ショップ支出", "Gastado en la tienda") }
    var trainerFavourite: String { t("가장 많이 키운", "Raised most", "いちばん育てた", "El más criado") }
    var trainerRarest: String { t("최고 등급", "Rarest", "最高レア", "Más raro") }
    func trainerDays(_ days: Int) -> String {
        t("여정 \(days)일째", "Day \(days) of the journey", "旅立って \(days) 日目", "Día \(days) del viaje")
    }
    func trainerSeen(_ graduated: Int, _ seen: Int) -> String {
        t("\(graduated) / \(seen) 종", "\(graduated) of \(seen) species",
          "\(graduated) / \(seen) 種", "\(graduated) de \(seen) especies")
    }
    // MARK: 업적
    var achievementsTitle: String { t("업적", "Achievements", "実績", "Logros") }
    func achievementsEarned(_ count: Int, _ total: Int) -> String {
        t("\(count) / \(total) 달성", "\(count) of \(total)", "\(count) / \(total) 達成", "\(count) de \(total)")
    }
    func achievementName(_ a: Achievement) -> String {
        switch a {
        case .firstHatch:      return t("첫 만남", "First Meeting", "はじめての出会い", "Primer encuentro")
        case .firstGraduate:   return t("첫 졸업", "First Graduate", "はじめての卒業", "Primer graduado")
        case .shinyFound:      return t("반짝임", "A Certain Sparkle", "きらめき", "Un cierto brillo")
        case .legendaryRaised: return t("전설의 곁", "Beside a Legend", "伝説とともに", "Junto a una leyenda")
        case .nightOwl:        return t("밤의 사람", "Night Owl", "夜ふかし", "Ave nocturna")
        case .earlyBird:       return t("새벽의 사람", "Early Riser", "早起き", "Madrugador")
        case .collector:       return t("수집가", "Collector", "コレクター", "Coleccionista")
        case .dedicated:       return t("한결같이", "Steadfast", "ひとすじ", "Constante")
        case .secondChance:    return t("다시 곁으로", "Second Chance", "もう一度そばに", "Segunda oportunidad")
        case .namer:           return t("이름을 지어", "The Naming", "名づけ", "El bautizo")
        case .transformed:     return t("정체", "True Form", "正体", "Forma real")
        case .bigSpender:      return t("큰손", "Big Spender", "大盤振る舞い", "Manirroto")
        }
    }
    func achievementDetail(_ a: Achievement) -> String {
        switch a {
        case .firstHatch:      return t("알에서 첫 포켓몬을 맞이했어요.", "Welcomed your first Pokémon out of its egg.", "はじめてのポケモンをタマゴから迎えました。", "Recibiste a tu primer Pokémon.")
        case .firstGraduate:   return t("한 마리를 끝까지 키워 도감에 올렸어요.", "Raised one all the way into the Pokédex.", "一匹を最後まで育てて図鑑に載せました。", "Criaste a uno hasta la Pokédex.")
        case .shinyFound:      return t("이로치를 만났어요.", "Met a shiny Pokémon.", "色違いに出会いました。", "Conociste a un Pokémon variocolor.")
        case .legendaryRaised: return t("전설급을 졸업시켰어요.", "Graduated a legendary.", "伝説級を卒業させました。", "Graduaste a un legendario.")
        case .nightOwl:        return t("늦은 밤에도 무언가 일어났어요.", "Something happened late at night.", "夜遅くにも何かが起きました。", "Algo ocurrió bien entrada la noche.")
        case .earlyBird:       return t("이른 아침에도 무언가 일어났어요.", "Something happened early in the morning.", "早朝にも何かが起きました。", "Algo ocurrió de madrugada.")
        case .collector:       return t("10종을 만났어요.", "Met ten different species.", "10種に出会いました。", "Conociste diez especies.")
        case .dedicated:       return t("다섯 마리를 졸업시켰어요.", "Graduated five Pokémon.", "五匹を卒業させました。", "Graduaste a cinco Pokémon.")
        case .secondChance:    return t("박스에서 다시 데리고 나왔어요.", "Brought someone back out of the Box.", "ボックスから連れ戻しました。", "Sacaste a alguien de la Caja.")
        case .namer:           return t("포켓몬에게 이름을 지어 주었어요.", "Gave a Pokémon a name of your own.", "ポケモンに名前をつけました。", "Le pusiste tu propio nombre.")
        case .transformed:     return t("메타몽의 정체를 마주했어요.", "Saw a Ditto drop its disguise.", "メタモンの正体を見ました。", "Viste a un Ditto revelarse.")
        case .bigSpender:      return t("상점에서 5B를 썼어요.", "Spent 5B in the shop.", "ショップで5B使いました。", "Gastaste 5B en la tienda.")
        }
    }

    var trainerExport: String { t("이미지로 저장", "Save as image", "画像として保存", "Guardar como imagen") }
    func trainerExported(_ path: String) -> String {
        t("저장했어요: \(path)", "Saved to \(path)", "保存しました: \(path)", "Guardado en \(path)")
    }
    var trainerExportFailed: String { t("저장하지 못했어요.", "Could not save the image.", "保存できませんでした。", "No se pudo guardar la imagen.") }
    var chronicleEmptyTitle: String { t("아직 쓸 이야기가 없어요", "Nothing to tell yet", "まだ物語がありません", "Todavía no hay historia") }
    var chronicleEmptyHint: String {
        t("알이 깨고 포켓몬이 자라면 여기에 하나씩 적혀요.",
          "Once your egg hatches and your Pokémon grows, it gets written down here.",
          "タマゴが孵り、ポケモンが育つとここに書き留められます。",
          "Cuando tu huevo eclosione y tu Pokémon crezca, se anotará aquí.")
    }

    /// 하루 중 언제 — 일지가 로그가 아니라 일기처럼 읽히게 하는 도입부.
    func dayPart(_ part: DayPart) -> String {
        switch part {
        case .earlyMorning: return t("이른 아침", "early one morning", "早朝に", "de madrugada")
        case .morning:      return t("오전", "one morning", "午前中に", "una mañana")
        case .afternoon:    return t("오후", "one afternoon", "午後に", "una tarde")
        case .evening:      return t("저녁", "one evening", "夕方に", "al anochecer")
        case .night:        return t("늦은 밤", "late one night", "夜遅くに", "bien entrada la noche")
        }
    }

    /// 사건 한 줄. `when` 은 위 `dayPart`, `name` 은 그때의 이름.
    func chronicleLine(_ kind: ChronicleEntry.Kind, when: String, name: String,
                       to: String?, shiny: Bool) -> String {
        switch kind {
        case .hatched:
            return shiny
                ? t("\(when), 알에서 \(name)이(가) 나왔어요 — 이로치였어요!",
                    "\(when), \(name) hatched — and came out shiny!",
                    "\(when)、タマゴから \(name) が生まれました — 色違いでした！",
                    "\(when), \(name) eclosionó — ¡y salió variocolor!")
                : t("\(when), 알에서 \(name)이(가) 나왔어요.",
                    "\(when), \(name) hatched from the egg.",
                    "\(when)、タマゴから \(name) が生まれました。",
                    "\(when), \(name) salió del huevo.")
        case .evolved:
            return t("\(when), \(name)이(가) \(to ?? "")(으)로 진화했어요.",
                     "\(when), \(name) evolved into \(to ?? "").",
                     "\(when)、\(name) が \(to ?? "") に進化しました。",
                     "\(when), \(name) evolucionó a \(to ?? "").")
        case .graduated:
            return t("\(when), \(name)이(가) 여정을 마치고 도감에 올랐어요.",
                     "\(when), \(name) finished its journey and joined the Pokédex.",
                     "\(when)、\(name) が旅を終えて図鑑に載りました。",
                     "\(when), \(name) terminó su viaje y entró en la Pokédex.")
        case .boxed:
            return t("\(when), \(name)이(가) 박스에서 쉬러 갔어요.",
                     "\(when), \(name) went to rest in the Box.",
                     "\(when)、\(name) はボックスで休むことになりました。",
                     "\(when), \(name) se fue a descansar a la Caja.")
        case .withdrawn:
            return t("\(when), \(name)이(가) 다시 곁으로 돌아왔어요.",
                     "\(when), \(name) came back to your side.",
                     "\(when)、\(name) が再びそばに戻りました。",
                     "\(when), \(name) volvió a tu lado.")
        case .renamed:
            return t("\(when), 이름을 \(name)(으)로 지어 주었어요.",
                     "\(when), you named it \(name).",
                     "\(when)、\(name) と名づけました。",
                     "\(when), le pusiste el nombre \(name).")
        case .released:
            return t("\(when), \(name)을(를) 놓아주었어요.",
                     "\(when), you released \(name).",
                     "\(when)、\(name) をにがしました。",
                     "\(when), soltaste a \(name).")
        case .dittoRevealed:
            return t("\(when), \(name)의 정체가 드러났어요 — 메타몽이었어요!",
                     "\(when), \(name) revealed itself — it was a Ditto all along!",
                     "\(when)、\(name) の正体が明らかに — メタモンでした！",
                     "\(when), \(name) se reveló — ¡era un Ditto!")
        }
    }

    var dexCellTooltip: String { t("눌러서 자세히 보기", "Click for details", "クリックで詳細", "Clic para ver detalles") }
    var dexBackToGrid: String { t("닫기", "Close", "閉じる", "Cerrar") }
    var dexIndividualUnnamed: String { t("이름 없음", "Unnamed", "名前なし", "Sin nombre") }
    func dexIndividualsOwned(_ count: Int) -> String {
        t("이 종으로 \(count)마리", "\(count) individual\(count == 1 ? "" : "s")",
          "この種で \(count) 匹", "\(count) ejemplar\(count == 1 ? "" : "es")")
    }

    // MARK: 성격 효과 (G3) — 보이지 않는 성장 속도 차이는 결함으로 읽힌다
    /// 성격이 성장 속도에 주는 효과. 1.0 배(17종)면 nil — 붙일 말이 없다.
    func natureGrowthEffect(_ nature: PokemonNature?) -> String? {
        guard let nature else { return nil }
        switch nature.growthMultiplier {
        case let m where m > 1: return t("빨리 자람 +10%", "Fast grower +10%", "成長が速い +10%", "Crece rápido +10%")
        case let m where m < 1: return t("천천히 자람 −10%", "Slow grower −10%", "成長が遅い −10%", "Crece despacio −10%")
        default: return nil
        }
    }
    /// 도감 총계는 개체가 아니라 종 수 — 로그의 dexTotal("총 N마리")과 단위가 다르다.
    func dexSpeciesTotal(_ n: Int) -> String { t("\(n)종", "\(n) species", "\(n)種", "\(n) especies") }
    func dexPageLabel(_ page: Int, _ total: Int) -> String {
        t("\(total)페이지 중 \(page)페이지", "Page \(page) of \(total)", "\(total)ページ中 \(page)ページ", "Página \(page) de \(total)")
    }
    var dexPagePrev: String { t("이전 페이지", "Previous page", "前のページ", "Página anterior") }
    var dexPageNext: String { t("다음 페이지", "Next page", "次のページ", "Página siguiente") }
    var dexRaising: String { t("키우는 중", "Raising", "育成中", "Criando") }
    var rarityCommon: String { t("일반", "Common", "ノーマル", "Común") }
    var rarityUncommon: String { t("고급", "Uncommon", "アンコモン", "Poco común") }
    var rarityRare: String { t("희귀", "Rare", "レア", "Raro") }
    var rarityLegendary: String { t("전설", "Legendary", "伝説", "Legendario") }
    var dexFilterHint: String { t("탭하면 이 희귀도만 보기 · 다시 탭하면 전체", "Tap to show only this rarity · tap again to clear", "タップでこの希少度のみ表示・再タップで全体", "Toca para ver solo esta rareza · toca de nuevo para ver todo") }
    /// 도감 칸의 ✨ 를 읽어주는 명사 — 이모지는 스크린리더가 일관되게 읽지 못한다.
    var dexShinyLabel: String { t("이로치", "Shiny", "色違い", "Variocolor") }
    func rarityLabel(_ r: Rarity) -> String {
        switch r {
        case .common:    return rarityCommon
        case .uncommon:  return rarityUncommon
        case .rare:      return rarityRare
        case .legendary: return rarityLegendary
        }
    }

    // 상태 한 줄
    var statusEgg: String { t("곧 깨어나요.", "Hatching soon.", "もうすぐ孵化します。", "Está a punto de eclosionar.") }
    var statusIdle: String { t("오늘은 조용히 자리를 지켜요.", "Keeping quiet today.", "今日は静かにしています。", "Hoy se mantiene tranquilo.") }
    var statusWorking: String { t("오늘의 작업 흔적이 쌓이고 있어요.", "Today's work is piling up.", "本日の作業が積み重なっています。", "El trabajo de hoy se va acumulando.") }
    var statusFocus: String { t("지금은 집중 모드예요.", "In focus mode now.", "今は集中モードです。", "Ahora está en modo concentración.") }
    var statusTired: String { t("한도에 가까워요. 잠깐 쉬어도 괜찮아요.", "Close to the limit. A short break is fine.", "上限が近いです。少し休んでも大丈夫。", "Está cerca del límite. Un pequeño descanso no vendría mal.") }
    var statusSleep: String { t("지금은 자고 있어요.", "Sleeping now.", "今は眠っています。", "Ahora está durmiendo.") }
    func statusEvolved(_ name: String) -> String { t("\(name)(으)로 진화했어요!", "Evolved into \(name)!", "\(name) に進化しました！", "¡Evolucionó a \(name)!") }
    var statusGrew: String { t("성장했어요!", "It grew!", "成長しました！", "¡Ha crecido!") }

    // MARK: companion 이벤트 시스템 알림
    var notifHatchTitle: String { t("🥚 부화!", "🥚 Hatched!", "🥚 孵化！", "🥚 ¡Eclosionó!") }
    func notifHatchBody(_ name: String) -> String { t("알에서 \(name)이(가) 나왔어요!", "\(name) hatched from the egg!", "タマゴから \(name) が生まれました！", "¡\(name) salió del huevo!") }
    var notifShinyHatchTitle: String { t("✨ 이로치 포켓몬!", "✨ Shiny Pokémon!", "✨ 色違いポケモン！", "✨ ¡Pokémon variocolor!") }
    func notifShinyHatchBody(_ name: String) -> String { t("이로치 \(name)이(가) 태어났어요! (1/64)", "A shiny \(name) hatched! (1 in 64)", "色違いの \(name) が生まれました！(1/64)", "¡Nació un \(name) variocolor! (1 entre 64)") }
    var eggImminent: String { t("곧 부화해요!", "About to hatch!", "もうすぐ孵化！", "¡Está a punto de eclosionar!") }
    /// 첫 실행(아직 토큰 적립 0) 안내 — "왜 아무 일도 안 일어나지"를 방지.
    var eggFirstRunHint: String {
        t("로컬 AI 코딩 도구의 사용량으로 자라요. 약 5M 토큰을 쓰면 알이 부화해요.",
          "Grows from your local AI coding usage. Your egg hatches after ~5M tokens.",
          "ローカルの AI コーディング使用量で育ちます。約5Mトークンでタマゴが孵化します。",
          "Crece con el uso de tus herramientas locales de programación con IA. Tu huevo eclosiona tras unos 5M de tokens.") }
    var notifEvolveTitle: String { t("✨ 진화!", "✨ Evolved!", "✨ 進化！", "✨ ¡Evolucionó!") }
    func notifEvolveBody(_ name: String) -> String { t("\(name)(으)로 진화했어요!", "Evolved into \(name)!", "\(name) に進化しました！", "¡Evolucionó a \(name)!") }
    // 메타몽 위장 리빌 — 진화 못 하는 메타몽이 첫 진화 순간 정체를 드러낸다.
    var notifDittoRevealTitle: String { t("🎭 어라? 메타몽!", "🎭 Huh? It's Ditto!", "🎭 あれ？メタモン！", "🎭 ¿Eh? ¡Es Ditto!") }
    func notifDittoRevealBody(_ disguise: String) -> String { t("\(disguise)인 줄 알았는데 — 사실은 메타몽이었어요!", "You thought it was \(disguise) — it was Ditto all along!", "\(disguise) だと思ってた… 実はメタモンでした！", "Pensabas que era \(disguise) — ¡en realidad era Ditto!") }
    var notifShinyDittoRevealTitle: String { t("🎭✨ 어라? 이로치 메타몽!", "🎭✨ Huh? A shiny Ditto!", "🎭✨ あれ？色違いメタモン！", "🎭✨ ¿Eh? ¡Un Ditto variocolor!") }
    func notifShinyDittoRevealBody(_ disguise: String) -> String { t("\(disguise)인 줄 알았는데 — 이로치 메타몽이었어요! (1/64)", "You thought it was \(disguise) — it was a shiny Ditto! (1 in 64)", "\(disguise) だと思ってた… 色違いのメタモンでした！(1/64)", "Pensabas que era \(disguise) — ¡era un Ditto variocolor! (1 entre 64)") }
    var notifGraduateTitle: String { t("🎓 졸업!", "🎓 Graduated!", "🎓 卒業！", "🎓 ¡Graduado!") }
    func notifGraduateBody(_ name: String) -> String { t("\(name) — 도감에 보존! 새 알이 도착했어요.", "\(name) — saved to your Pokédex! A new egg has arrived.", "\(name) — 図鑑に保存！新しいタマゴが届きました。", "\(name) — ¡guardado en tu Pokédex! Ha llegado un nuevo huevo.") }

    // MARK: Claude 한도 토큰 갱신 오류 (친절 안내)
    func limitRefreshHTTPError(_ status: Int) -> String {
        if status == 401 || status == 403 {
            return t(
                "Claude 자격증명이 만료됐거나 권한이 없어요 (\(status)). Claude Code 로그인을 확인하세요. Codex만 쓴다면 무시해도 됩니다 — Codex 한도는 따로 표시돼요.",
                "Claude credential is expired or unauthorized (\(status)). Check that you're signed in to Claude Code. If you only use Codex you can ignore this — Codex limits show separately.",
                "Claude の認証情報が期限切れか権限がありません (\(status))。Claude Code にサインインしているか確認してください。Codex のみ使用する場合は無視できます — Codex の上限は別に表示されます。",
                "La credencial de Claude expiró o no tiene permisos (\(status)). Comprueba que has iniciado sesión en Claude Code. Si solo usas Codex, puedes ignorar esto — los límites de Codex se muestran aparte.")
        }
        return t("Claude 한도 조회 실패 (\(status)).", "Failed to fetch Claude limits (\(status)).", "Claude の上限取得に失敗しました (\(status))。", "No se pudieron obtener los límites de Claude (\(status)).")
    }
    var limitRefreshNoCredential: String {
        t("Claude 자격증명을 찾지 못했어요. Claude Code 에 로그인하면 한도가 표시됩니다. Codex만 쓴다면 무시해도 돼요.",
          "No Claude credential found. Sign in to Claude Code to see limits. If you only use Codex you can ignore this.",
          "Claude の認証情報が見つかりません。Claude Code にサインインすると上限が表示されます。Codex のみなら無視して構いません。",
          "No se encontró ninguna credencial de Claude. Inicia sesión en Claude Code para ver los límites. Si solo usas Codex, puedes ignorar esto.")
    }
    var limitRefreshReauthNeeded: String {
        t("Claude 자격증명에 계정 로그인 정보가 없어요. Claude Code 에서 `/login` 으로 다시 로그인하면 한도가 표시됩니다.",
          "Your Claude credential has no account sign-in. Run `/login` in Claude Code to sign in again and limits will appear.",
          "Claude の認証情報にアカウントのサインインが含まれていません。Claude Code で `/login` を実行して再度サインインすると上限が表示されます。",
          "Tu credencial de Claude no tiene una sesión de cuenta asociada. Ejecuta `/login` en Claude Code para volver a iniciar sesión y ver los límites.")
    }
    var limitRefreshGeneric: String {
        t("Claude 한도 조회에 실패했어요. 잠시 후 다시 시도하세요.",
          "Couldn't fetch Claude limits. Please try again shortly.",
          "Claude の上限取得に失敗しました。しばらくして再試行してください。",
          "No se pudieron obtener los límites de Claude. Inténtalo de nuevo en unos momentos.")
    }
    var limitRefreshRateLimited: String {
        t("Claude 한도 조회가 일시 제한됐어요 (429). 잠시 쉬었다가 자동으로 재시도합니다.",
          "Claude limit checks are temporarily rate-limited (429). Backing off and retrying automatically.",
          "Claude の上限取得が一時的に制限されています (429)。少し待って自動的に再試行します。",
          "Las comprobaciones de límites de Claude están temporalmente limitadas (429). Se reintentará automáticamente en breve.")
    }

    // MARK: Claude 세션 만료(401) 안내
    var claudeAuthExpiredTitle: String {
        t("Claude 세션 만료 — 한도가 갱신 안 돼요",
          "Claude session expired — limits can't refresh",
          "Claude セッション期限切れ — 上限を更新できません",
          "Sesión de Claude expirada — los límites no se pueden actualizar")
    }
    var claudeAuthExpiredHint: String {
        t("표시된 값은 만료 전 기준이에요. 다시 시도하거나, Claude Code 를 한 번 실행하면 자동 갱신됩니다.",
          "Values shown are from before expiry. Retry, or run Claude Code once to refresh automatically.",
          "表示値は期限切れ前のものです。再試行するか、Claude Code を一度実行すると自動更新されます。",
          "Los valores mostrados son de antes de la expiración. Reinténtalo, o ejecuta Claude Code una vez para actualizarlos automáticamente.")
    }
    var retry: String { t("다시 시도", "Retry", "再試行", "Reintentar") }

    // MARK: 업데이트 알림
    func updateAvailable(_ version: String, current: String) -> String {
        t("🆕 v\(version) 사용 가능 (현재 \(current))",
          "🆕 v\(version) available (you have \(current))",
          "🆕 v\(version) が利用可能（現在 \(current)）",
          "🆕 v\(version) disponible (tienes \(current))")
    }
    var updateButton: String { t("업데이트", "Update", "更新", "Actualizar") }
    var updateLater: String { t("나중에", "Later", "後で", "Más tarde") }
    var updating: String { t("업데이트 중…", "Updating…", "更新中…", "Actualizando…") }
    var updateSectionTitle: String { t("업데이트", "Updates", "アップデート", "Actualizaciones") }
    var updateNotificationsLabel: String { t("업데이트 알림", "Update notifications", "アップデート通知", "Notificaciones de actualización") }
    var checkForUpdatesLabel: String { t("업데이트 확인", "Check for updates", "アップデートを確認", "Buscar actualizaciones") }
    var checkNowButton: String { t("지금 확인", "Check now", "今すぐ確認", "Comprobar ahora") }
    func updateFound(_ version: String) -> String { t("새 버전 v\(version) 있어요", "Version \(version) is available", "バージョン \(version) が利用可能です", "La versión \(version) está disponible") }
    func upToDate(_ version: String) -> String { t("최신 버전이에요 (v\(version))", "You're on the latest (v\(version))", "最新です (v\(version))", "Tienes la última versión (v\(version))") }

    // MARK: 알림
    var notifCritical: String { t("한도 임박", "Limit imminent", "上限切迫", "Límite inminente") }
    var notifWarning: String { t("한도 경고", "Limit warning", "上限警告", "Aviso de límite") }
    func notifBody(_ name: String, _ percent: String) -> String {
        t("\(name) 한도 \(percent) 사용", "\(name) at \(percent)", "\(name) 上限 \(percent) 使用", "\(name) al \(percent)")
    }
    var claudeFiveHour: String { t("Claude 5시간 세션", "Claude 5-hour session", "Claude 5時間セッション", "Sesión de 5 horas de Claude") }
    var claudeWeekly: String { t("Claude 주간", "Claude weekly", "Claude 週間", "Semanal de Claude") }
    var codexPersonalLimit: String { t("Codex 개인 한도", "Codex personal limit", "Codex 個人上限", "Límite personal de Codex") }

    // MARK: 가방 / 아이템
    var bag: String { t("가방", "Bag", "バッグ", "Bolsa") }
    var bagEmptyTitle: String { t("아직 가방이 비어있어요!", "Your bag is empty!", "バッグはまだ空っぽです！", "¡Tu bolsa todavía está vacía!") }
    var bagEmptyHint: String {
        t("한도를 다 쓰면 이상한 사탕을 받고, 상점에서도 살 수 있어요.",
          "You earn Rare Candy by using up a limit window, and the Shop sells items too.",
          "上限を使い切るとふしぎなアメがもらえ、ショップでも購入できます。",
          "Ganas Caramelos Raros al agotar un límite, y la Tienda también vende objetos.")
    }
    /// 가방이 "누구에게 쓰는지" 를 보여 주는 머리글. 대상 없이 놓인 사용 버튼은 무엇에 쓰이는지 알 수 없다.
    var bagUsingOn: String { t("사용 대상", "Using on", "使う相手", "Usar en") }
    var bagNoTarget: String {
        t("알이 깨면 아이템을 쓸 수 있어요.", "Items become usable once your egg hatches.",
          "タマゴが孵るとアイテムを使えます。", "Podrás usar objetos cuando eclosione el huevo.")
    }
    /// 소지품의 효과 한 줄 — 상점에는 있는데 가방에는 없던 정보다. 산 뒤에 무슨 물건인지 알 수 없으면
    /// 그 아이템은 목록의 이름표일 뿐이다.
    func itemEffect(_ kind: ItemKind, currentNature: PokemonNature?, _ lang: AppLanguage) -> String {
        switch kind {
        case .rareCandy:
            return "+\(TokenFormatter.compact(RareCandy.xp)) XP"
        case .mint:
            guard let currentNature else { return mintEffectHint }
            return t("지금 성격: \(currentNature.name(lang))", "Now: \(currentNature.name(lang))",
                     "いまの性格: \(currentNature.name(lang))", "Ahora: \(currentNature.name(lang))")
        case .shinyCharm:
            return shinyCharmEffectHint
        }
    }
    var useItem: String { t("사용하기", "Use", "つかう", "Usar") }
    var use: String { t("사용", "Use", "つかう", "Usar") }
    var cancel: String { t("취소", "Cancel", "キャンセル", "Cancelar") }
    func useOnCurrent(_ name: String) -> String {
        t("\(name)에게 사용할까요?", "Use on \(name)?", "\(name) に使いますか？", "¿Usar en \(name)?")
    }
    var useAfterHatch: String { t("부화 후 사용할 수 있어요", "Usable after hatching", "孵化後に使えます", "Se puede usar después de eclosionar") }
    var useNeedsPokemon: String { t("사용할 포켓몬이 없어요", "No Pokémon to use it on", "使えるポケモンがいません", "No hay ningún Pokémon en quien usarlo") }

    /// 아이템 표시명 — species 처럼 공식 현지명.
    func itemName(_ kind: ItemKind) -> String {
        switch kind {
        case .rareCandy: return t("이상한 사탕", "Rare Candy", "ふしぎなアメ", "Caramelo Raro")
        case .mint:      return t("민트", "Mint", "ミント", "Menta")
        case .shinyCharm: return t("이로치 부적", "Shiny Charm", "ひかるおまもり", "Amuleto Iris")
        }
    }
    func itemDescription(_ kind: ItemKind) -> String {
        switch kind {
        case .rareCandy:
            let xp = TokenFormatter.compact(RareCandy.xp)   // 상수에서 파생(하드코딩 드리프트 방지)
            return t("현재 포켓몬의 경험치를 \(xp) 올려줘요.",
                     "Raises your Pokémon's EXP by \(xp).",
                     "ポケモンの経験値を\(xp)上げます。",
                     "Aumenta la experiencia de tu Pokémon en \(xp).")
        case .mint:
            return t("현재 포켓몬의 성격을 랜덤으로 바꿔줘요.",
                     "Randomly changes your Pokémon's nature.",
                     "ポケモンのせいかくをランダムに変えます。",
                     "Cambia aleatoriamente la naturaleza de tu Pokémon.")
        case .shinyCharm:
            return t("보유하면 이로치 포켓몬이 태어날 확률이 올라가요.",
                     "While owned, raises the chance of hatching a shiny.",
                     "持っていると色違いが生まれる確率が上がります。",
                     "Mientras lo tengas, aumenta la probabilidad de que nazca un Pokémon variocolor.")
        }
    }
    /// 가방 사용 컨트롤의 효과 힌트 — 민트("성격 랜덤 변경", 사탕의 "+XP" 자리).
    var mintEffectHint: String { t("성격 랜덤 변경", "Random nature", "せいかくランダム変更", "Naturaleza aleatoria") }

    // MARK: 상점 (재화 = 사용한 토큰)
    var shop: String { t("상점", "Shop", "ショップ", "Tienda") }
    var spendableTokens: String { t("쓸 수 있는 토큰", "Spendable tokens", "使えるトークン", "Tokens disponibles") }
    var shopHint: String { t("사용한 토큰으로 아이템을 살 수 있어요.", "Spend the tokens you've used on items.", "使ったトークンでアイテムを購入できます。", "Usa los tokens que has consumido para comprar objetos.") }
    var buy: String { t("구매", "Buy", "購入", "Comprar") }
    func buyConfirm(_ name: String) -> String { t("\(name) 구매할까요?", "Buy \(name)?", "\(name) を購入しますか？", "¿Comprar \(name)?") }
    var notEnoughTokens: String { t("토큰이 부족해요", "Not enough tokens", "トークンが足りません", "No tienes suficientes tokens") }
    func ownedCount(_ n: Int) -> String { t("보유 ×\(n)", "Owned ×\(n)", "所持 ×\(n)", "En posesión ×\(n)") }
    var shopPriceLabel: String { t("가격", "Price", "価格", "Precio") }
    var walletAvailable: String { t("쓸 수 있는 토큰", "Available to spend", "使えるトークン", "Disponible para gastar") }
    /// 잔액의 출처를 한 줄로. 구매해도 성장 미터는 안 줄어든다는 점이 여기서 읽혀야 한다.
    func walletBreakdown(_ earned: String, _ spent: String) -> String {
        t("누적 \(earned) · 사용 \(spent)", "\(earned) earned · \(spent) spent",
          "累計 \(earned) · 使用 \(spent)", "\(earned) ganados · \(spent) gastados")
    }
    func walletCanAfford(_ item: String) -> String {
        t("지금 \(item)까지 살 수 있어요", "You can afford the \(item)",
          "いま \(item) まで買えます", "Puedes permitirte \(item)")
    }
    func walletNextGoal(_ item: String, _ remaining: String) -> String {
        t("\(item)까지 \(remaining) 남았어요", "\(remaining) to go for the \(item)",
          "\(item) まであと \(remaining)", "Faltan \(remaining) para \(item)")
    }
    func shopEntryName(_ entry: ShopEntry) -> String {
        switch entry {
        case .item(let kind): return itemName(kind)
        case .egg(let tier):  return eggName(tier)
        }
    }
    var ownedAlready: String { t("보유 중", "Owned", "所持済み", "En posesión") }
    var shinyCharmEffectHint: String { t("이로치 확률 ↑ · 적용 중", "Shiny rate ↑ · active", "色違い率↑ · 適用中", "Prob. variocolor ↑ · activo") }
    // 알 (리롤) — tier = 보증 등급 하한(nil = 보증 없는 기본 알).
    // 이름은 `rarityLabel(r) + " 알"` 식 조합으로 만들지 않는다: 한국어·영어는 맞아떨어져도 일본어에서
    // 조사가 어긋난다(レアのタマゴ vs 자연스러운 レアなタマゴ). 세 언어를 명시 트리플로 적는다.
    func eggName(_ tier: Rarity?) -> String {
        switch tier {
        case nil, .common?: return t("포켓몬 알", "Pokémon Egg", "ポケモンのタマゴ", "Huevo Pokémon")
        case .uncommon?:  return t("고급 알", "Uncommon Egg", "アンコモンのタマゴ", "Huevo poco común")
        case .rare?:      return t("희귀 알", "Rare Egg", "レアのタマゴ", "Huevo raro")
        case .legendary?: return t("전설 알", "Legendary Egg", "でんせつのタマゴ", "Huevo legendario")   // 미판매(FreshEgg.shopTiers)
        }
    }
    func eggDescription(_ tier: Rarity?) -> String {
        guard let tier, tier != .common else {
            return t("지금 포켓몬은 박스로 보내고 새 알로 다시 시작해요. 언제든 다시 꺼낼 수 있어요.",
                     "Your current Pokémon moves to the Box and a new egg starts. You can take it back out any time.",
                     "いまのポケモンはボックスへ移り、新しいタマゴが始まります。いつでも戻せます。",
                     "Tu Pokémon actual pasa a la Caja y empieza un huevo nuevo. Puedes sacarlo cuando quieras.")
        }
        let r = rarityLabel(tier)
        return t("지금 포켓몬은 박스로 보내고 \(r) 이상이 확정으로 나오는 알을 받아요.",
                 "Your current Pokémon moves to the Box and you get an egg guaranteed to hatch \(r) or better.",
                 "いまのポケモンはボックスへ移り、\(r) 以上が確定で孵るタマゴをもらいます。",
                 "Tu Pokémon actual pasa a la Caja y consigues un huevo garantizado de \(r) o superior.")
    }
    /// 인큐베이션 중 표시하는 보증 배지 — 어떤 알을 품고 있는지 한 줄로.
    func eggGuaranteeHint(_ tier: Rarity) -> String {
        let r = rarityLabel(tier)
        return t("\(r) 이상 확정", "\(r) or better", "\(r) 以上確定", "\(r) o superior garantizado")
    }
    func eggConfirm(_ monName: String, _ eggName: String) -> String {
        t("\(monName)을(를) 박스로 보내고 \(eggName)(으)로 바꿀까요?",
          "Move \(monName) to the Box and start the \(eggName)?",
          "\(monName) をボックスに入れて \(eggName) にしますか？",
          "¿Mover a \(monName) a la Caja y empezar el \(eggName)?")
    }
    var freshEggShinyWarning: String { t("⚠️ 이로치 포켓몬이에요! 정말 놓아줄까요?", "⚠️ This one is shiny! Really send it off?", "⚠️ 色違いです！本当に手放しますか？", "⚠️ ¡Este es variocolor! ¿Seguro que quieres soltarlo?") }
    var freshEggDiscardShiny: String { t("이로치 놓아주기", "Send shiny off", "手放す", "Soltar variocolor") }

    // MARK: 사탕 획득 알림 ("왜 받는지" = 토큰 한도를 다 채운 수고에 대한 보상)
    func notifCandyTitle(item: String, count: Int) -> String {
        t("🍬 \(item) \(count)개를 받았어요!",
          "🍬 You got \(count)× \(item)!",
          "🍬 \(item)を\(count)個もらいました！",
          "🍬 ¡Has recibido \(count)× \(item)!")
    }
    func notifCandyBody(window: String) -> String {
        t("\(window) 토큰 한도를 다 채웠어요. 열심히 쓴 만큼 사탕을 드려요 — 포켓몬에게 써서 진화시켜 보세요!",
          "You maxed out your \(window) token limit. A treat for the effort — use it to evolve your Pokémon!",
          "\(window)のトークン上限を使い切りました。がんばったごほうびです — ポケモンに使って進化させよう！",
          "Has agotado tu límite de tokens \(window). Un premio por el esfuerzo — ¡úsalo para evolucionar a tu Pokémon!")
    }
}
