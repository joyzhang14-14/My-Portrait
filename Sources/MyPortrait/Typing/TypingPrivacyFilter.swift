/// TypingPrivacyFilter —— 打字采集的隐私闸门。两道判据：
///
///   1. **App 黑名单**（按 bundle id）：密码管理器 / 机密类 app 整体不订阅 AX。
///      hardcode 一组默认值 ∪ 用户在 config 里加的
///      `privacy.typing_blacklist_bundle_ids`。
///   2. **secure field 检测**：focused 元素 role == `AXSecureTextField`
///      （密码输入框）—— 不快照、不 diff。
///
/// 纯数据 / 纯函数，不感知 AX、不感知 DB。
struct TypingPrivacyFilter {

    /// hardcode 的默认黑名单 —— 密码管理器 / 钥匙串。
    private static let hardcodedBlacklist: Set<String> = [
        "com.1password.1password",      // 1Password 8
        "com.agilebits.onepassword",    // 1Password 7
        "com.bitwarden.desktop",        // Bitwarden
        "org.keepassxc.keepassxc",      // KeePassXC
        "com.apple.keychainaccess",     // Keychain Access
        "com.joyzhang.myportrait",      // 自己 —— 循环采集自己没意义
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

    /// bundle id 是否命中黑名单。最终黑名单 = hardcode ∪ 用户配置。
    /// 读 ConfigStore.shared（@MainActor 隔离），故方法标 @MainActor。
    @MainActor
    static func isBlacklisted(bundleId: String) -> Bool {
        if hardcodedBlacklist.contains(bundleId) { return true }
        return ConfigStore.shared.privacy.typingBlacklistBundleIds.contains(bundleId)
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
}
