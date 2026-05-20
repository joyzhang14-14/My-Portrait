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
    ]

    /// secure text field 的 AX role。
    private static let secureFieldRole = "AXSecureTextField"

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
}
