/// TypingPrivacyFilter —— 打字采集的隐私闸门。两道判据：
///
///   1. **App 黑名单**（按 bundle id）：密码管理器 / 机密类 app 整体不订阅 AX。
///      hardcode 一组默认值 ∪ 用户在 config 里加的
///      `privacy.typing_blacklist_apps`。
///   1b. **URL 黑名单**（`privacy.typing_blacklist_urls`，小写子串，不分 app）：
///      命中的页面上打的字不落库。跟屏幕采集的 ignoredUrls 同一套语义。
///   2. **secure field 检测**：focused 元素 role == `AXSecureTextField`
///      （密码输入框）—— 不快照、不 diff。
///
/// 纯数据 / 纯函数，不感知 AX、不感知 DB。
struct TypingPrivacyFilter {

    /// hardcode 的默认黑名单 —— 密码管理器 / 钥匙串 / 登录窗。
    private static let hardcodedBlacklist: Set<String> = [
        "com.1password.1password",      // 1Password 8
        "com.agilebits.onepassword",    // 1Password 7
        "com.bitwarden.desktop",        // Bitwarden
        "org.keepassxc.keepassxc",      // KeePassXC
        "com.apple.keychainaccess",     // Keychain Access
        // 登录窗 / 锁屏 —— 这里打的字就是开机密码本身。
        "com.apple.loginwindow",        // Login Window
        // 认证界面(08-09 update)。跟屏幕采集那边不同,**这三个上锁不可删** ——
        // 屏幕侧记下的是"出现过一个授权框",打字侧记下的是你在框里敲的
        // **那串密码本身**,没有任何让用户关掉它的理由。
        "com.apple.SecurityAgent",                  // "xxx 想要进行更改"授权弹窗
        "com.apple.LocalAuthentication.UIAgent",    // Touch ID / 本地认证弹窗
        "com.apple.Passwords",                      // macOS 15「密码」app
    ]

    /// 终端类 app 的 bundle id。**算法限制**，非用户隐私选择 —— 终端的
    /// 输入区和输出区共享同一个 AX text 元素，stdout（ls / cat / git 输出）
    /// 会在 keyDown 后 120ms 内到达，被 Layer 1 心跳误判为用户输入。AX 不
    /// 暴露"输入区 vs 输出区"，无法区分，故终端整段不订阅 AX。
    /// 与 ConfigStore.privacy.ignoredApps（用户可配）是两个独立机制。
    /// FocusProbe.terminalBundleIds 有一份平行列表（用途不同，各自维护）。
    private static let terminalBundleIds: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "co.zeit.hyper",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.github.wez.wezterm",
        "dev.warp.Warp-Stable",
    ]

    /// secure text field 的 AX role。
    private static let secureFieldRole = "AXSecureTextField"

    /// 终端黑名单 app 数量 —— TypingObserver 启动 banner 用。
    static var terminalBlocklistCount: Int { terminalBundleIds.count }

    /// 硬编码「永远黑名单」（密码管理器 + 终端）的 bundle id —— 设置页
    /// 灰显展示用，不可移除。
    static let defaultBlacklist: [String] =
        hardcodedBlacklist.sorted() + terminalBundleIds.sorted()

    /// bundle id 是否整 app 屏蔽。给 TypingObserver.attach 用(没 URL 信息,
    /// 只能判 app 级)。读 ConfigStore.shared(@MainActor 隔离),故标 @MainActor。
    @MainActor
    static func isBlacklisted(bundleId: String) -> Bool {
        if hardcodedBlacklist.contains(bundleId) { return true }
        let privacy = ConfigStore.shared.privacy
        if privacy.typingBlacklistApps.contains(bundleId) { return true }
        // 类别名单:选了 Finance 就等于把所有自报财务类的 app 加进名单。
        return AppCategoryResolver.shared.matches(
            bundleId: bundleId, selected: Set(privacy.typingBlacklistCategories))
    }

    /// (bundle, url) 是否命中黑名单 —— 整 app 屏蔽,或 URL 命中 URL 名单里的
    /// 任一**小写子串**(不分 app,跟屏幕采集 ignoredUrls 同口径)。
    /// 给 TypingRecordWriter.persist 用(已知具体 URL)。
    @MainActor
    static func isBlacklisted(bundleId: String, url: String) -> Bool {
        if isBlacklisted(bundleId: bundleId) { return true }
        let u = url.lowercased()
        guard !u.isEmpty else { return false }
        return ConfigStore.shared.privacy.typingBlacklistUrls.contains {
            !$0.isEmpty && u.contains($0.lowercased())
        }
    }

    /// 给后台批读用 —— 把两张名单 snapshot 一份,在 dbPool 线程上比对
    /// `(bundle_id, url)`。nonisolated,可以脱离 MainActor 用。
    static func matches(
        apps: Set<String>, urls: [String], hardcoded: Set<String>,
        categories: Set<String> = [],
        bundleId: String, url: String
    ) -> Bool {
        if hardcoded.contains(bundleId) || apps.contains(bundleId) { return true }
        if AppCategoryResolver.shared.matches(bundleId: bundleId, selected: categories) {
            return true
        }
        let u = url.lowercased()
        guard !u.isEmpty else { return false }
        return urls.contains { !$0.isEmpty && u.contains($0.lowercased()) }
    }

    /// hardcoded 黑名单 snapshot —— `matches(...)` 用。
    static var hardcodedSnapshot: Set<String> { hardcodedBlacklist }

    /// 把类别名单摊平成 bundle id 集合。
    ///
    /// 给**只能按 bundle_id 比对的写入路径**用 —— keystroke_log / mouse_log
    /// 是 CGEventTap 全局 tap 写的,行级没有 app 上下文,只能靠一份预先算好的
    /// id 集合过滤;不能每敲一下去查一次类别。
    ///
    /// ⚠️ **快照**:采集启动时算一次。之后新装的 app 落进选中类别,要重启
    /// 采集才生效。AX 那条路(`isBlacklisted`)是实时查的,不受这个限制。
    ///
    /// 扫盘 + 读 Info.plist,**放后台调**。
    nonisolated static func bundleIds(forCategories categories: [String]) -> Set<String> {
        let selected = Set(categories.filter { !$0.isEmpty })
        guard !selected.isEmpty else { return [] }
        let resolver = AppCategoryResolver.shared
        return Set(InstalledApps.scan()
            .map(\.id)
            .filter { resolver.matches(bundleId: $0, selected: selected) })
    }

    /// role 是否为密码输入框。
    static func isSecureRole(_ role: String?) -> Bool {
        role == secureFieldRole
    }

    /// bundle id 是否为终端类 app。命中则整段不订阅 AX（算法限制，见
    /// `terminalBundleIds` 注释）。
    static func isTerminalApp(bundleId: String) -> Bool {
        terminalBundleIds.contains(bundleId)
    }

    /// 这个 app 为什么不采打字 —— nil = 会采。
    ///
    /// **`TypingObserver.attach` 的完整判据就是这个函数**,菜单栏采集灯也读它。
    /// 两边各写一份必然走偏(08-01 灯只查了黑名单、漏了终端那道闸,导致在终端
    /// 里打字蓝灯还亮着)。以后再加屏蔽条件,**只改这里**。
    @MainActor
    static func exclusionReason(bundleId: String) -> ExclusionReason? {
        if isTerminalApp(bundleId: bundleId) { return .terminal }
        if isBlacklisted(bundleId: bundleId) { return .blacklisted }
        return nil
    }

    enum ExclusionReason {
        /// 终端:输入区和输出区共享同一个 AX 元素,分不开,整段不订阅。
        case terminal
        /// 硬编码黑名单(密码管理器 / 钥匙串 / 登录窗)或用户自己加的条目。
        case blacklisted
    }
}
