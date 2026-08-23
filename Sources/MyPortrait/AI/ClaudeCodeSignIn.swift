import Foundation

/// Claude Code CLI 登录有效期的缓存。
///
/// **为什么要缓存**:有效期只能从 Claude Code 自己写的钥匙串条目里读,而读
/// 别的 app 的条目会弹系统授权框。那个框只能出现在用户点 Detect 的那一刻,
/// 不能一进 Connections 页就弹。所以读到之后把**时间戳**(不是凭据)存进
/// UserDefaults,UI 之后一直读这份缓存。
///
/// 存的只是一个到期时刻,没有任何 token —— 不需要走 SecretStore 加密。
enum ClaudeCodeSignIn {

    private static let key = "claudeCode.signInExpiry"

    /// 上次 Detect 读到的到期时刻。nil = 从没读到过(没点过 Detect / 用户
    /// 拒了授权 / 那台机器上 Claude Code 没登录)。
    static var cachedExpiry: Date? {
        let t = UserDefaults.standard.double(forKey: key)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// 读一次钥匙串并更新缓存。**只能由用户动作触发**(见
    /// `ClaudeCodeAgent.readSignInExpiry` 的注释)。读不到就把缓存清掉 ——
    /// 宁可不显示,也不留一个可能早就不准的旧数字。
    @discardableResult
    static func refreshFromKeychain() -> Date? {
        let d = ClaudeCodeAgent.readSignInExpiry()
        if let d {
            UserDefaults.standard.set(d.timeIntervalSince1970, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        return d
    }

    /// 断开连接时清掉,别让 tile 上留着上一次登录的天数。
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    // 08-09 update 删掉了 refreshInBackground():定时重读钥匙串会隔三差五弹一次系统
    // 授权框,而且完全没必要 —— 存的是**绝对时间戳**,"还剩几天"自己会往下走。
    // 只有用户重新 `claude login` 之后那个值才变,那时他会去点 Detect,由
    // refreshFromKeychain() 刷新。**别再加回定时重读。**
}
