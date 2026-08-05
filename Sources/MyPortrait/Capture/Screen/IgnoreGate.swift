import Foundation
import os

/// 用户配置的"屏蔽"闸门。**两套判据,别混**：
///
///   1. `shouldSkipFrame` —— 名单里的 app / 页面在**最前台**(你正在用它)
///      → 这一帧根本不拍。
///   2. `shouldMaskWindow` —— 名单里的窗口只是在**后台**露一角 → 帧照拍,
///      那个窗口从 SCK 捕获 buffer 里排除(渲染成黑)。
///
/// 也就是:「你正在用它」什么都不记,「它只是开着」只把它那块黑掉。
/// 桌面壁纸不在这套语义里 —— 它走独立开关 `setWallpaperTransparent`,
/// 只影响遮挡,永远不会让整帧跳过。
///
/// 与 DRMGate 的区别：DRMGate 是硬编码列表 + 系统级硬规则，命中 → 停整条
/// 流水线 + invalidate SCStream(受保护视频不停流会黑屏);IgnoreGate 只是
/// 不拍这一帧,流不动。
///
/// 逐窗口那部分仿 My-Orphies `screenpipe-screen/.../
/// capture_screenshot_by_window.rs` 的 `WindowFilters::is_valid`。
final class IgnoreGate: @unchecked Sendable {

    /// 永远排除的系统进程（锁屏等）。仿 screenpipe `BUILTIN_IGNORED`。
    private static let builtinIgnored: Set<String> = ["loginwindow", "logonui"]

    /// 壁纸窗口的识别关键字。壁纸窗口的 app 名 / 标题都含它
    /// （标题形如 "Wallpaper-<UUID>"）。
    private static let wallpaperTerm = "wallpaper"

    private struct State {
        var appsLower: Set<String> = []           // 小写,子串匹配（app 名 / 标题）
        var urlSubstrings: [String] = []          // 小写,URL / 标题子串(也收并进来的旧 ignoredWindowTitles)
        var maskingEnabled: Bool = true
        var wallpaperTransparent: Bool = true
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    init(
        initialApps: Set<String> = [],
        initialUrlPatterns: [String] = [],
        maskingEnabled: Bool = true
    ) {
        state.withLock { s in
            s.appsLower = Set(initialApps.map { $0.lowercased() })
            s.urlSubstrings = initialUrlPatterns.map { $0.lowercased() }
            s.maskingEnabled = maskingEnabled
        }
    }

    func setIgnoredApps(_ apps: Set<String>) {
        let normalized = Set(apps.map { $0.lowercased() })
        state.withLock { $0.appsLower = normalized }
    }

    /// URL pattern 当作窗口标题子串用：浏览器窗口标题通常含站点名
    /// （仿 screenpipe `is_title_suggesting_blocked_url`）。
    func setIgnoredUrlPatterns(_ patterns: [String]) {
        let normalized = patterns.map { $0.lowercased() }
        state.withLock { $0.urlSubstrings = normalized }
    }

    func setMaskingEnabled(_ enabled: Bool) {
        state.withLock { $0.maskingEnabled = enabled }
    }

    /// 桌面壁纸是否从截图里排除(那块渲染成黑)。独立开关,与 ignoredApps 无关。
    func setWallpaperTransparent(_ on: Bool) {
        state.withLock { $0.wallpaperTransparent = on }
    }

    /// 这一帧要不要做全量窗口枚举。枚举是到 replayd 的 XPC,抓帧热路径上
    /// 最大的单项开销 —— 结果用不上就别做。
    ///
    /// 用户遮罩规则 **或** 壁纸开关任一成立都得枚举。
    /// builtin(loginwindow)不算:它只在锁屏/登录界面在屏,为它每帧枚举
    /// 不值得 —— 代价是无规则用户的锁屏帧不再抹 loginwindow(锁屏画面本身
    /// 无敏感内容,密码框是圆点)。
    var needsWindowEnumeration: Bool {
        let snap = state.withLock { $0 }
        if snap.wallpaperTransparent { return true }
        guard snap.maskingEnabled else { return false }
        return snap.appsLower.contains { !$0.isEmpty }
            || snap.urlSubstrings.contains { !$0.isEmpty }
    }

    /// **整帧判据**:当前前台内容是否命中用户名单 → `true` = 这一帧不拍。
    ///
    /// 只看前台 app 名和当前页面 URL,**跟 CaptureLampState 的紫灯完全同口径**
    /// —— 两边各写一份判据必然走偏,而对一盏"用来自证没在记"的灯,
    /// 走偏就是最严重的错。
    func shouldSkipFrame(appName: String, browserUrl: String?) -> Bool {
        let snap = state.withLock { $0 }
        let app = appName.lowercased()
        if !app.isEmpty {
            for term in snap.appsLower where !term.isEmpty && app.contains(term) {
                return true
            }
        }
        if let url = browserUrl?.lowercased(), !url.isEmpty {
            for sub in snap.urlSubstrings where !sub.isEmpty && url.contains(sub) {
                return true
            }
        }
        return false
    }

    /// **逐窗口判据**:这个窗口要不要从捕获 buffer 里排除(渲染成黑)。
    /// 走到这里说明前台没命中(命中的话整帧已经跳了),处理的是后台露一角的窗口。
    ///   - builtin 系统进程永远抹
    ///   - 壁纸窗口:看 `wallpaperTransparent` 开关,与用户名单无关
    ///   - masking 关 → 用户规则不再抹
    ///   - ignoredApps 子串命中窗口 app 名**或**标题 → 抹
    ///   - 窗口标题子串命中 ignoredUrls → 抹
    func shouldMaskWindow(appName: String, title: String?) -> Bool {
        let app = appName.lowercased()
        if Self.builtinIgnored.contains(app) { return true }

        let snap = state.withLock { $0 }
        let t = (title ?? "").lowercased()

        if snap.wallpaperTransparent,
           app.contains(Self.wallpaperTerm) || t.contains(Self.wallpaperTerm) {
            return true
        }
        guard snap.maskingEnabled else { return false }

        // ignoredApps：子串匹配窗口 app 名 OR 标题（screenpipe is_valid 同款）。
        for term in snap.appsLower where !term.isEmpty {
            if app.contains(term) || t.contains(term) { return true }
        }
        // ignoredUrls(含并进来的旧 ignoredWindowTitles)：子串匹配窗口标题。
        if !t.isEmpty {
            for sub in snap.urlSubstrings where !sub.isEmpty && t.contains(sub) {
                return true
            }
        }
        return false
    }
}
