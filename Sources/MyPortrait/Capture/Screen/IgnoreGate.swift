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
        var appsLower: Set<String> = []           // 整名精确匹配
        var windowTitleSubstrings: [String] = []  // 小写,窗口标题子串
        var urlSubstrings: [String] = []          // 小写,URL / 标题子串
        var maskingEnabled: Bool = true
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    init(
        initialApps: Set<String> = [],
        initialUrlPatterns: [String] = [],
        initialWindowTitles: [String] = [],
        maskingEnabled: Bool = true
    ) {
        state.withLock { s in
            s.appsLower = Set(initialApps.map { $0.lowercased() })
            s.urlSubstrings = initialUrlPatterns.map { $0.lowercased() }
            s.windowTitleSubstrings = initialWindowTitles.map { $0.lowercased() }
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

    func setIgnoredWindowTitles(_ titles: [String]) {
        let normalized = titles.map { $0.lowercased() }
        state.withLock { $0.windowTitleSubstrings = normalized }
    }

    func setMaskingEnabled(_ enabled: Bool) {
        state.withLock { $0.maskingEnabled = enabled }
    }

    /// 一个窗口是否应该从截图里抹掉。仿 screenpipe `is_valid` 取反：
    ///   - builtin 系统进程永远抹
    ///   - masking 关 → 永不抹
    ///   - app 名精确命中 ignoredApps → 抹
    ///   - 窗口标题子串命中 ignoredWindowTitles / ignoredUrls → 抹
    func shouldMaskWindow(appName: String, title: String?) -> Bool {
        let app = appName.lowercased()
        if Self.builtinIgnored.contains(app) { return true }

        let snap = state.withLock { $0 }
        guard snap.maskingEnabled else { return false }

        if snap.appsLower.contains(app) { return true }

        if let t = title?.lowercased(), !t.isEmpty {
            for sub in snap.windowTitleSubstrings where !sub.isEmpty && t.contains(sub) {
                return true
            }
            for sub in snap.urlSubstrings where !sub.isEmpty && t.contains(sub) {
                return true
            }
        }
        return false
    }
}
