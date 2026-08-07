import Foundation

/// 连接的 AI 账号快到期时提醒。
///
/// 每天**本地时间**跨过 0 点后的第一次 tick 跑一遍(挂在
/// `MemoryScheduler.tick` 上,跟 memory pipeline 同一个节拍,不另起 timer):
///   1. 把各家的到期时间刷新一遍
///   2. 剩 ≤ 2 天的,发一条通知
///
/// **不做"同一次到期只提醒一次"的去重**:每天查一次、符合条件就提醒,所以
/// 最多连发 3 次(2 天 → 1 天 → 当天),而且越来越急。少发一次的代价是
/// pipeline 整条停摆,多发两次的代价只是多两张卡片。
@MainActor
enum CredentialExpiryWatcher {

    /// 剩这么多天以内就提醒。
    static let warnWithinDays = 2

    private static let dayKey = "credentialExpiry.lastCheckDay"

    /// 每 tick 调都安全 —— 内部按本地日期去重。
    static func runDailyIfNeeded() async {
        let today = localDayString(Date())
        guard UserDefaults.standard.string(forKey: dayKey) != today else { return }
        // 先记日子:中途失败(比如用户点了"不允许"读钥匙串)也不该今天反复重试。
        UserDefaults.standard.set(today, forKey: dayKey)

        await ClaudeCodeSignIn.refreshInBackground()

        await checkCodex()
        // Claude Code 的 refreshTokenExpiresAt 到了就是到了,我们续不了 ——
        // 只能提醒用户去跑 `claude login`。
        warnIfExpiringSoon(provider: "Claude Code CLI", expiry: ClaudeCodeSignIn.cachedExpiry)
    }

    /// Codex 跟 Claude Code 不是一回事:它那个到期时间是 **access token** 的
    /// (OpenAI 给 10 天),而 refresh_token 只要还在用就一直有效 —— 换句话说
    /// 快到期**不代表**用户要做什么,我们自己续上就行。
    ///
    /// 所以顺序是「先试着续,续不上才报警」:
    ///   - 续成功 → 到期时间跳回 10 天后,一声不吭
    ///   - 续失败 → 这才是真的 refresh_token 也不行了,必须重新登录
    /// 直接按 access token 剩余天数报警会天天误报"快过期了"而其实啥事没有。
    private static func checkCodex() async {
        guard let expiry = ChatGPTOAuth.accessTokenExpiry() else { return }
        guard expiry.timeIntervalSinceNow <= Double(warnWithinDays) * 86400 else { return }
        do {
            try await ChatGPTOAuth.forceRefresh()
        } catch {
            // 续不上 = 用户真得重新连一次。这里不看剩几天(可能已经过期),
            // 直接按当前到期时间报,过期就是 0 天。
            let days = max(0, Int(ChatGPTOAuth.accessTokenExpiry()?
                .timeIntervalSinceNow ?? 0) / 86400)
            NotificationCenterService.shared.post(
                .credentialExpiring(provider: "Codex", daysLeft: days))
        }
    }

    /// 已经过期的**不提醒** —— 那时候用户早就在别处撞到报错了,再补一张
    /// "快到期了"的卡片只是马后炮。这里只管"还来得及处理"的窗口。
    private static func warnIfExpiringSoon(provider: String, expiry: Date?) {
        guard let expiry else { return }
        let secs = expiry.timeIntervalSinceNow
        guard secs > 0 else { return }
        let days = Int(secs / 86400)          // 向下取整:剩 1.9 天算 1 天
        guard days <= warnWithinDays else { return }
        NotificationCenterService.shared.post(
            .credentialExpiring(provider: provider, daysLeft: days))
    }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"      // 本地时区 —— 用户要的是本机 12am
        return f
    }()
    private static func localDayString(_ d: Date) -> String { dayFmt.string(from: d) }
}
