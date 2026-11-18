import CoreGraphics
import Foundation
import os

/// 用户配置的"屏蔽"闸门：决定哪些**窗口**要从截图里抹掉。
///
/// ⚠️ **命中永远不跳整帧,只抠掉那个窗口。** 帧就是时间轴本身 —— timeline、
/// 音频、打字三路都按帧的时间戳对齐,少一帧等于时间轴上凭空少一段。所以
/// 屏蔽固定是:帧照拍、命中的窗口从 SCK 捕获 buffer 里排除(那块渲染成
/// 不透明黑)。(08-05 试过"前台命中就跳整帧",因为上面这条耦合关系回退。)
///
/// 名单里两种条目:
///   - **app**(设置页从已装 app 里选的):app 名整名相等(不分大小写)才命中。
///   - **系统条目**(`systemEntries`:Wallpaper / Trash / .env …,不是 app):窗口标题
///     含这个词,或 app 名里有这个整词,就命中。桌面壁纸是 Dock 画的、标题形如
///     "Wallpaper-<UUID>";Wallpaper 这条另外把桌面层(普通窗口和桌面图标之下)的
///     窗口都抹掉 —— 动态壁纸 app 画的壁纸在那一层,它自己的设置窗口不在。
/// 网站名单只比主域名,而且只判最前面那个浏览器窗口(别的窗口拿不到网址)。
///
/// 与 DRMGate 的区别：DRMGate 是硬编码列表 + 系统级硬规则,命中 → 停整条
/// 流水线 + invalidate SCStream —— 那是没办法,受保护视频不停流会让用户
/// 自己正在看的播放黑屏。IgnoreGate 没有这个约束,所以不停。
///
/// 仿 My-Orphies `screenpipe-screen/.../capture_screenshot_by_window.rs`
/// 的 `WindowFilters::is_valid`：逐窗口判定,不通过的窗口排除出捕获。
final class IgnoreGate: @unchecked Sendable {

    /// 永远排除的系统进程（锁屏等）。仿 screenpipe `BUILTIN_IGNORED`。
    ///
    /// ⚠️ **别往这里加认证界面**(SecurityAgent / Touch ID / 密码 app)——
    /// 它们放在 `PrivacyConfig.ignoredApps` 的默认值里,用户在设置页看得见、
    /// 也能自己叉掉。硬编码在这儿等于偷偷替用户做决定,他还查不出来。
    private static let builtinIgnored: Set<String> = ["loginwindow", "logonui"]

    /// 不是 app 的系统条目,按窗口标题命中。设置页「Select app」里也列出这些供一键勾选。
    /// 改编自 screenpipe 的默认屏蔽名单(MIT):https://github.com/screenpipe/screenpipe
    static let systemEntries: [String] = [
        "Wallpaper", "Dock", "Control Center", "Settings",
        "Trash", "VPN", "Private", "Incognito", ".env",
        "Item-0", "App Icon Window", "Battery", "WiFi", "Clock",
    ]
    private static let systemLower = Set(systemEntries.map { $0.lowercased() })

    /// 桌面图标那一层;比它还低的是壁纸。
    private static let desktopIconLayer = Int(CGWindowLevelForKey(.desktopIconWindow))

    private struct State {
        var appsLower: Set<String> = []           // 小写,app 名整名相等
        var systemTerms: Set<String> = []         // 小写,系统条目:标题子串 / app 名整词
        var urlDomains: Set<String> = []          // 主域名(也收并进来的旧 ignoredWindowTitles)
        var categories: Set<String> = []          // 完整 LSApplicationCategoryType
        var maskingEnabled: Bool = true
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    init(
        initialApps: Set<String> = [],
        initialUrlPatterns: [String] = [],
        maskingEnabled: Bool = true
    ) {
        setIgnoredApps(initialApps)
        setIgnoredUrlPatterns(initialUrlPatterns)
        state.withLock { $0.maskingEnabled = maskingEnabled }
    }

    func setIgnoredApps(_ apps: Set<String>) {
        let lower = Set(apps.map { $0.lowercased() }.filter { !$0.isEmpty })
        state.withLock {
            $0.systemTerms = lower.intersection(Self.systemLower)
            $0.appsLower = lower.subtracting(Self.systemLower)
        }
    }

    /// 手输的网站,每条归到主域名再存(见 TypingPrivacyFilter.mainDomain)。
    func setIgnoredUrlPatterns(_ patterns: [String]) {
        let domains = Set(patterns.compactMap { TypingPrivacyFilter.mainDomain($0) })
        state.withLock { $0.urlDomains = domains }
    }

    /// 类别名单(完整 `LSApplicationCategoryType`)。命中的窗口按它 owning app
    /// 自报的类别遮 —— 见 `AppCategoryResolver`。
    func setIgnoredCategories(_ cats: [String]) {
        let normalized = Set(cats.filter { !$0.isEmpty })
        state.withLock { $0.categories = normalized }
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
        return !snap.appsLower.isEmpty || !snap.systemTerms.isEmpty
            || !snap.urlDomains.isEmpty || !snap.categories.isEmpty
    }

    /// 一个窗口是否应该从截图里抹掉(帧照拍,这块渲染成黑)：
    ///   - builtin 系统进程永远抹
    ///   - masking 关 → 永不抹
    ///   - owning app 自报的类别命中 ignoredCategories → 抹
    ///     (bundleId 为 nil 时这条判不了,跳过 —— 系统窗口常没有 bundle)
    ///   - app 名整名等于名单里的 app → 抹
    ///   - 系统条目:标题含这个词、或 app 名里有这个整词 → 抹;Wallpaper 另抹桌面层
    ///   - `url`(只有最前面的浏览器窗口传)主域名在网站名单里 → 抹
    /// `layer` = 窗口层级(SCWindow.windowLayer),不知道就传 nil。
    func shouldMaskWindow(appName: String, bundleId: String?, title: String?,
                          layer: Int? = nil, url: String? = nil) -> Bool {
        let app = appName.lowercased()
        if Self.builtinIgnored.contains(app) { return true }

        let snap = state.withLock { $0 }
        guard snap.maskingEnabled else { return false }

        // 类别放在字符串匹配之前:命中就直接抹,省掉下面的逐条子串扫描。
        // 结果有缓存(AppCategoryResolver),每帧逐窗口问不会读盘。
        if !snap.categories.isEmpty, let bundleId, !bundleId.isEmpty,
           AppCategoryResolver.shared.matches(bundleId: bundleId, selected: snap.categories) {
            return true
        }

        if snap.appsLower.contains(app) { return true }

        if !snap.systemTerms.isEmpty {
            let t = (title ?? "").lowercased()
            // app 名按整词比:"System Settings" 命中 Settings,"WallpaperMachine" 不命中 Wallpaper。
            let words = " " + app.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : " " }
                .reduce(into: "") { $0.append($1) } + " "
            for term in snap.systemTerms {
                if t.contains(term) || words.contains(" \(term) ") { return true }
            }
            if snap.systemTerms.contains("wallpaper"), let layer, layer < Self.desktopIconLayer {
                return true
            }
        }

        if let url, !snap.urlDomains.isEmpty,
           let d = TypingPrivacyFilter.mainDomain(url), snap.urlDomains.contains(d) {
            return true
        }
        return false
    }
}
