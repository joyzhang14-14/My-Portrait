import Foundation
import os

/// 用户配置的"屏蔽"闸门：决定哪些**窗口**要从截图里抹掉。
///
/// 与 DRMGate 的区别：
///   - DRMGate：硬编码列表 + 系统级硬规则，命中 → 停整条流水线 + invalidate SCStream
///   - IgnoreGate：用户偏好（Settings UI 配置），命中 → 该窗口从 SCK 捕获 buffer
///     里排除（在帧里变透明），**帧本身永远照拍**
///
/// 仿 My-Orphies `screenpipe-screen/.../capture_screenshot_by_window.rs`
/// 的 `WindowFilters::is_valid`：逐窗口判定，不通过的窗口排除出捕获。
final class IgnoreGate: @unchecked Sendable {

    /// 永远排除的系统进程（锁屏等）。仿 screenpipe `BUILTIN_IGNORED`。
    private static let builtinIgnored: Set<String> = ["loginwindow", "logonui"]

    private struct State {
        var appsLower: Set<String> = []           // 小写,子串匹配（app 名 / 标题）
        var urlSubstrings: [String] = []          // 小写,URL / 标题子串(也收并进来的旧 ignoredWindowTitles)
        var maskingEnabled: Bool = true
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

    /// 当前是否存在任何**用户配置的**遮罩规则。ScreenCaptureService 用它决定
    /// 要不要每帧做全量窗口枚举(到 replayd 的 XPC,抓帧热路径最大单项开销):
    /// 没规则 → 枚举出来的窗口列表完全用不上,跳过。
    /// builtin(loginwindow)不算规则:它只在锁屏/登录界面在屏,为它每帧
    /// 枚举不值得 —— 代价是无规则用户的锁屏帧不再抹 loginwindow(锁屏画面
    /// 本身无敏感内容,密码框是圆点)。
    var hasUserRules: Bool {
        let snap = state.withLock { $0 }
        guard snap.maskingEnabled else { return false }
        return snap.appsLower.contains { !$0.isEmpty }
            || snap.urlSubstrings.contains { !$0.isEmpty }
    }

    /// 一个窗口是否应该从截图里抹掉。仿 screenpipe `is_valid` 取反——纯字符串
    /// 匹配，**只**排除名字命中的窗口，不按窗口层级扩大范围：
    ///   - builtin 系统进程永远抹
    ///   - masking 关 → 永不抹
    ///   - ignoredApps 子串命中窗口 app 名**或**标题 → 抹
    ///     （壁纸窗口标题是 "Wallpaper-<UUID>"，"wallpaper" 子串即命中它本身）
    ///   - 窗口标题子串命中 ignoredUrls → 抹
    func shouldMaskWindow(appName: String, title: String?) -> Bool {
        let app = appName.lowercased()
        if Self.builtinIgnored.contains(app) { return true }

        let snap = state.withLock { $0 }
        guard snap.maskingEnabled else { return false }

        let t = (title ?? "").lowercased()

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
