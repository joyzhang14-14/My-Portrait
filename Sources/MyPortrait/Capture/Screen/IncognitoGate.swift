import CoreGraphics
import Foundation
import os.log

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

    private static let logger = Logger(subsystem: "com.myportrait.capture", category: "incognito")

    // MARK: - 主入口

    /// 当前焦点是否在无痕窗口。`true` → 跳过这一帧。
    /// `enabled` = ConfigStore.privacy.ignoreIncognito,关时恒 false。
    func isPrivate(_ focus: FocusInfo, enabled: Bool) async -> Bool {
        guard enabled else { return false }

        // Tier 1:AXIdentifier(即时)
        if Self.axIdIsPrivate(focus.axIdentifier) { return true }

        // Tier 3:标题关键词(即时纯函数)
        if Self.isTitlePrivate(focus.windowTitle) { return true }

        // Tier 2:扫**采集显示器(主屏)内**所有可见浏览器窗口,任一命中即跳整帧:
        //   (a) 窗口标题含无痕关键词 → 覆盖 Safari/Firefox/Arc 等**非 Chromium**
        //       (靠 CGWindowList 的 kCGWindowName,本 app 有屏幕录制权限读得到)。
        //   (b) Chromium app → AppleScript 遍历窗口查 mode/incognito 兜底(标题常空)。
        //   只看落在主屏内的窗口:副屏/别的显示器的无痕窗不该拖累主屏这一帧
        //   (采集走 CGMainDisplayID,见 ScreenCaptureService.captureMainDisplay)。
        let scan = Self.scanVisibleBrowserWindows(onDisplay: CGDisplayBounds(CGMainDisplayID()))
        if scan.titleHit { return true }
        for app in scan.chromiumApps {
            if await appHasIncognitoWindow(forApp: app) { return true }
        }

        return false
    }

    /// 扫 CGWindowList 里落在 `bounds`(采集显示器)内、可见(layer 0、alpha>0)的窗口。
    /// 返回:(是否存在标题含无痕关键词的窗口, 在屏的 Chromium 浏览器 app 名集合)。
    nonisolated static func scanVisibleBrowserWindows(onDisplay bounds: CGRect)
        -> (titleHit: Bool, chromiumApps: Set<String>) {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return (false, []) }
        var apps: Set<String> = []
        var titleHit = false
        for w in infos {
            let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
            let alpha = (w[kCGWindowAlpha as String] as? Double) ?? 1
            guard layer == 0, alpha > 0.01 else { continue }   // 普通窗口层 + 可见
            // 只算与主屏相交的窗口 —— 跨屏的无痕窗不拖累主屏帧。
            if let bd = w[kCGWindowBounds as String] as? [String: Any],
               let r = CGRect(dictionaryRepresentation: bd as CFDictionary),
               !r.intersects(bounds) { continue }
            // (a) 标题关键词:覆盖任何浏览器(含非 Chromium)的无痕窗。
            if let title = w[kCGWindowName as String] as? String, Self.isTitlePrivate(title) {
                titleHit = true
            }
            // (b) Chromium app 收集,后面 AppleScript 查属性兜底。
            if let owner = w[kCGWindowOwnerName as String] as? String,
               Self.isChromiumBrowser(owner) { apps.insert(owner) }
        }
        return (titleHit, apps)
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
        // Process + resume-once 状态 + continuation 全装进 box,跨 watchdog 闭包
        // 并发安全传递(Process/NSLock/Continuation 均非 Sendable)。
        final class Ctx: @unchecked Sendable {
            let proc = Process()
            private let lock = NSLock()
            private var resumed = false
            private var cont: CheckedContinuation<Bool, Never>?
            func arm(_ c: CheckedContinuation<Bool, Never>) { cont = c }
            func finish(_ v: Bool) {
                lock.lock(); defer { lock.unlock() }
                if resumed { return }
                resumed = true
                cont?.resume(returning: v); cont = nil
            }
        }
        let ctx = Ctx()

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            ctx.arm(cont)
            DispatchQueue.global(qos: .utility).async {
                let p = ctx.proc
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", script]
                let outPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = Pipe()

                // 1.8s watchdog:osascript 卡死(首次授权 modal / 浏览器无响应)→
                //   kill + 降级放行,绝不让采集热路径(isPrivate)永久 await 挂死。
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.8) {
                    if ctx.proc.isRunning {
                        ctx.proc.terminate()
                        Self.logger.warning("osascript 查 \(appName, privacy: .public) 超时 1.8s,kill;本帧无痕检测降级放行")
                        ctx.finish(false)
                    }
                }

                do { try p.run() } catch {
                    Self.logger.warning("osascript 启动失败(\(appName, privacy: .public)):\(error.localizedDescription, privacy: .public)")
                    ctx.finish(false); return
                }
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let out = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // 非预期输出(自动化/Apple Events 权限被撤销等)WARN 一次,别静默失效。
                if out != "incognito", out != "normal", out != "not_running", out != "" {
                    Self.logger.warning("osascript(\(appName, privacy: .public)) 异常输出 '\(out, privacy: .public)';检查 自动化/Apple Events 权限")
                }
                ctx.finish(out == "incognito")
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
