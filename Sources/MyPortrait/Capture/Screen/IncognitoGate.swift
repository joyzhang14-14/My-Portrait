import Foundation

/// 无痕 / 隐身浏览窗口检测。命中则跳过该帧（不截图、不 OCR、不入库）。
///
/// 三层,端口自 screenpipe `screenpipe-a11y/src/incognito/`(verbatim):
///   - Tier 1:焦点窗口 AXIdentifier 含 "incognito"/"private"(Arc 等)
///   - Tier 2:Chromium 系浏览器走 AppleScript 查 `mode`/`incognito` 属性
///             (Chrome/Edge/Brave/Vivaldi/Opera/Comet),2s 缓存防每帧 osascript
///   - Tier 3:窗口标题多语言关键词匹配(全平台兜底,纯函数)
///
/// 任一层命中即判定无痕。Tier 3(即时)放 Tier 2(慢 osascript)前面优化性能,
/// 结果与 screenpipe 一致(任一命中即 true)。
actor IncognitoGate {

    // MARK: - 主入口

    /// 当前焦点是否在无痕窗口。`true` → 跳过这一帧。
    /// `enabled` = ConfigStore.privacy.ignoreIncognito,关时恒 false。
    func isPrivate(_ focus: FocusInfo, enabled: Bool) async -> Bool {
        guard enabled else { return false }

        // Tier 1:AXIdentifier(即时)
        if Self.axIdIsPrivate(focus.axIdentifier) { return true }

        // Tier 3:标题关键词(即时纯函数)
        if Self.isTitlePrivate(focus.windowTitle) { return true }

        // Tier 2:Chromium AppleScript(慢,带 2s 缓存)
        if Self.isChromiumBrowser(focus.appName), let title = focus.windowTitle {
            let privateTitles = await incognitoTitles(forApp: focus.appName)
            if privateTitles.contains(title) { return true }
        }

        return false
    }

    // MARK: - Tier 1:AXIdentifier

    nonisolated static func axIdIsPrivate(_ axId: String?) -> Bool {
        guard let lower = axId?.lowercased() else { return false }
        return lower.contains("incognito") || lower.contains("private")
    }

    // MARK: - Tier 2:Chromium AppleScript + 2s 缓存

    private struct CacheEntry { let titles: Set<String>; let at: Date }
    private var cache: [String: CacheEntry] = [:]
    private let cacheTTL: TimeInterval = 2.0

    /// 查某 Chromium app 当前所有无痕窗口的标题集合。2s 内同 app 走缓存,
    /// 避免每帧跑 osascript(单次 ~150-200ms)。
    private func incognitoTitles(forApp app: String) async -> Set<String> {
        let key = app.lowercased()
        if let e = cache[key], Date().timeIntervalSince(e.at) < cacheTTL {
            return e.titles
        }
        let titles = await Self.runAppleScript(appName: app)
        cache[key] = CacheEntry(titles: titles, at: Date())
        return titles
    }

    /// Chromium 系 app 名(小写)。只对这些跑 Tier 2。
    private static let chromiumBrowsers: Set<String> = [
        "google chrome", "chrome", "chromium", "microsoft edge", "edge",
        "brave browser", "brave", "vivaldi", "opera", "comet",
    ]

    nonisolated static func isChromiumBrowser(_ app: String) -> Bool {
        chromiumBrowsers.contains(app.lowercased())
    }

    /// app 名 → AppleScript `tell application` 目标名。
    private static func applescriptAppName(_ app: String) -> String {
        switch app.lowercased() {
        case "chrome": return "Google Chrome"
        case "edge":   return "Microsoft Edge"
        case "brave":  return "Brave Browser"
        default:       return app
        }
    }

    /// 跑 osascript 拿无痕窗口标题集合。脚本端口自 screenpipe(verbatim):
    /// 先试 `mode of w is "incognito"`(Chrome/Edge/Vivaldi/Opera),再 fallback
    /// `incognito of w`(Brave/Comet)。返回 "~~~" 分隔的标题串 / "none" /
    /// "not_running"。任何错误(权限拒绝/超时)→ 空集。
    nonisolated static func runAppleScript(appName: String) async -> Set<String> {
        let target = applescriptAppName(appName)
        let script = """
        if application "\(target)" is running then
            tell application "\(target)"
                set result_list to ""
                repeat with w in every window
                    set dominated to false
                    try
                        if mode of w is "incognito" then set dominated to true
                    end try
                    if not dominated then
                        try
                            if incognito of w then set dominated to true
                        end try
                    end if
                    if dominated then
                        if result_list is "" then
                            set result_list to name of w
                        else
                            set result_list to result_list & "~~~" & name of w
                        end if
                    end if
                end repeat
                if result_list is "" then return "none"
                return result_list
            end tell
        else
            return "not_running"
        end if
        """
        return await withCheckedContinuation { (cont: CheckedContinuation<Set<String>, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", script]
                let outPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = Pipe()
                do { try p.run() } catch { cont.resume(returning: []); return }
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let out = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if out.isEmpty || out == "none" || out == "not_running" {
                    cont.resume(returning: []); return
                }
                cont.resume(returning: Set(out.components(separatedBy: "~~~")))
            }
        }
    }

    // MARK: - Tier 3:标题关键词(端口自 screenpipe titles.rs,verbatim)

    /// 英文 + 多语言(小写比);CJK 原样比(大小写无意义)。命中即 true。
    nonisolated static func isTitlePrivate(_ windowTitle: String?) -> Bool {
        guard let title = windowTitle, !title.isEmpty else { return false }
        let lower = title.lowercased()
        for k in englishKeywords where lower.contains(k) { return true }
        for k in localizedKeywords where lower.contains(k) { return true }
        for k in cjkKeywords where title.contains(k) { return true }
        return false
    }

    /// 特定短语(`(private)` / `- private` / `private browsing`)而非裸 "private",
    /// 避免误伤 "Private API docs" 这类正常标题。
    private static let englishKeywords: [String] = [
        "incognito", "inprivate", "private browsing", "private window",
        "private mode", "- private", "(private)", "brave private",
    ]

    private static let localizedKeywords: [String] = [
        // German
        "inkognito", "privater modus", "privates fenster",
        // French
        "navigation privée", "navigation privee",
        // Spanish
        "incógnito", "navegación privada", "navegacion privada",
        // Portuguese
        "navegação privada", "navegacao privada", "anônima", "anonima",
        // Italian
        "navigazione anonima",
        // Dutch
        "incognitovenster", "privévenster", "privevenster",
        // Polish
        "przeglądanie prywatne", "przegladanie prywatne",
        // Turkish
        "gizli sekme", "gizli gezinme",
        // Russian
        "инкогнито", "приватное окно",
        // Ukrainian
        "інкогніто", "приватне вікно",
        // Arabic
        "تصفح متخفي", "تصفح خاص",
        // Hindi
        "गुप्त",
        // Thai
        "ไม่ระบุตัวตน",
        // Vietnamese
        "ẩn danh",
        // Czech
        "anonymní", "soukromé prohlížení",
        // Romanian
        "navigare privată",
        // Hungarian
        "inkognitó", "privát böngészés",
        // Swedish
        "inkognitofönster", "privat surfning",
        // Norwegian
        "inkognitovindu", "privat nettlesing",
        // Danish
        "inkognitovindue", "privat browsing",
        // Finnish
        "incognito-ikkuna", "yksityinen selaus",
        // Greek
        "ανώνυμη περιήγηση", "ιδιωτική περιήγηση",
        // Hebrew
        "גלישה בסתר", "גלישה פרטית",
    ]

    private static let cjkKeywords: [String] = [
        // Japanese
        "シークレット", "プライベートブラウジング",
        // Chinese Simplified
        "无痕", "隐身", "隐私浏览",
        // Chinese Traditional
        "無痕", "隱私瀏覽",
        // Korean
        "시크릿", "사생활 보호",
    ]
}
