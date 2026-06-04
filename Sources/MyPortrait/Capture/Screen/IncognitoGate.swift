import CoreGraphics
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

        // Tier 2:屏幕上**任何可见的** Chromium 浏览器有无痕窗口 → 跳整帧。
        //   不再只看焦点窗口 —— 覆盖"无痕小窗摆一边、人在别的 app 工作"的场景:
        //   焦点窗非无痕,但屏上有可见无痕窗,整屏截图照样把它拍进去。
        //   不靠 title 比对(macOS 26 上 Chrome AX window title 常空),AppleScript
        //   直接遍历各浏览器窗口查 mode/incognito。per-app 2s 缓存防每帧 osascript。
        for app in Self.visibleChromiumApps() {
            if await appHasIncognitoWindow(forApp: app) { return true }
        }

        return false
    }

    /// CGWindowList 枚举**在屏可见**(layer 0 普通窗口层、alpha>0)的 Chromium
    /// 浏览器 app 名(去重,原始大小写,供 AppleScript)。决定 Tier 2 要查哪些。
    nonisolated static func visibleChromiumApps() -> Set<String> {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var apps: Set<String> = []
        for w in infos {
            guard let owner = w[kCGWindowOwnerName as String] as? String,
                  Self.isChromiumBrowser(owner) else { continue }
            let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
            let alpha = (w[kCGWindowAlpha as String] as? Double) ?? 1
            guard layer == 0, alpha > 0.01 else { continue }   // 普通窗口层 + 可见
            apps.insert(owner)
        }
        return apps
    }

    // MARK: - Tier 1:AXIdentifier

    nonisolated static func axIdIsPrivate(_ axId: String?) -> Bool {
        guard let lower = axId?.lowercased() else { return false }
        return lower.contains("incognito") || lower.contains("private")
    }

    // MARK: - Tier 2:Chromium AppleScript + 2s 缓存

    private struct CacheEntry { let incognito: Bool; let at: Date }
    private var cache: [String: CacheEntry] = [:]
    private let cacheTTL: TimeInterval = 2.0

    /// 查某 Chromium app 是否**存在(非最小化的)无痕窗口**。2s 内同 app 走缓存,
    /// 避免每帧跑 osascript(单次 ~150-200ms)。
    private func appHasIncognitoWindow(forApp app: String) async -> Bool {
        let key = app.lowercased()
        if let e = cache[key], Date().timeIntervalSince(e.at) < cacheTTL {
            return e.incognito
        }
        let incog = await Self.runAppleScript(appName: app)
        cache[key] = CacheEntry(incognito: incog, at: Date())
        return incog
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

    /// 跑 osascript 遍历某 app **所有非最小化窗口**,任一无痕即命中。先试
    /// `mode of w is "incognito"`(Chrome/Edge/Vivaldi/Opera),再 fallback
    /// `incognito of w`(Brave/Comet)。返回 "incognito" / "normal" /
    /// "not_running"。任何错误(权限拒绝/超时)→ false。
    nonisolated static func runAppleScript(appName: String) async -> Bool {
        let target = applescriptAppName(appName)
        let script = """
        if application "\(target)" is running then
            tell application "\(target)"
                set n to count of windows
                if n is 0 then return "normal"
                repeat with i from 1 to n
                    set w to window i
                    try
                        if miniaturized of w is false then
                            set is_incog to false
                            try
                                if mode of w is "incognito" then set is_incog to true
                            end try
                            if not is_incog then
                                try
                                    if incognito of w then set is_incog to true
                                end try
                            end if
                            if is_incog then return "incognito"
                        end if
                    end try
                end repeat
                return "normal"
            end tell
        else
            return "not_running"
        end if
        """
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", script]
                let outPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = Pipe()
                do { try p.run() } catch { cont.resume(returning: false); return }
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let out = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                cont.resume(returning: out == "incognito")
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
