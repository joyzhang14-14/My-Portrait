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
        UserDefaults.standard.removeObject(forKey: dayKey)
    }

    // MARK: - 每天自动刷一次

    private static let dayKey = "claudeCode.signInExpiry.lastRefreshDay"

    /// 本地时间跨过 0 点之后刷一次,挂在 `MemoryScheduler.tick` 上(跟 memory
    /// pipeline 同一个节拍,不另起 timer)。
    ///
    /// **只在已经有缓存时才刷**:没有缓存 = 用户从没成功 Detect 过(没连、
    /// 或者当时拒了钥匙串授权),那半夜跑去弹一个授权框纯属打扰。
    ///
    /// 钥匙串读取放在 detached task 里:万一系统真弹授权框,`SecItemCopyMatching`
    /// 会**阻塞调用线程**直到用户点掉 —— 在主线程上就是转菊花假死。
    static func refreshDailyIfNeeded() async {
        guard cachedExpiry != nil else { return }
        let today = localDayString(Date())
        guard UserDefaults.standard.string(forKey: dayKey) != today else { return }
        // 先记日子再刷:读失败(用户点了"不允许")也不该今天反复重试弹框。
        UserDefaults.standard.set(today, forKey: dayKey)
        let d = await Task.detached(priority: .utility) {
            ClaudeCodeAgent.readSignInExpiry()
        }.value
        if let d {
            UserDefaults.standard.set(d.timeIntervalSince1970, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"      // 本地时区 —— 用户说的是本机 12am
        return f
    }()
    private static func localDayString(_ d: Date) -> String { dayFmt.string(from: d) }
}
