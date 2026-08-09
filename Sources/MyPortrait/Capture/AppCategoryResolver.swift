import AppKit
import Foundation
import os

/// bundle id → app 自报的 `LSApplicationCategoryType`,带缓存。
///
/// 三处黑名单共用:音频「暂停名单」、屏幕「Ignored apps」、打字「黑名单」。
/// 用户选一个类别(比如 Finance),我们就得能回答"这个 bundle 属不属于它"。
///
/// **查一次要开 Bundle 读 Info.plist**,所以必须缓存 —— 屏幕采集那条路每帧
/// 都会枚举窗口逐个问,不缓存等于每帧几十次磁盘 IO。
///
/// 线程安全:锁保护字典。调用方分布在 SCK 抓帧线程、CGEventTap 回调线程、
/// 音频轮询 actor 上,没有统一的隔离域。
final class AppCategoryResolver: @unchecked Sendable {

    static let shared = AppCategoryResolver()

    /// 空串 = 那个 app 没声明类别 / 查不到。**空串也缓存** —— 否则没声明类别
    /// 的 app(相当多)会每次都重新去开一遍 bundle。
    private let cache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    private init() {}

    func category(of bundleId: String) -> String {
        if let hit = cache.withLock({ $0[bundleId] }) { return hit }
        let category: String = {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
                  let bundle = Bundle(url: url),
                  let declared = bundle.infoDictionary?["LSApplicationCategoryType"] as? String
            else { return "" }
            return declared
        }()
        cache.withLock { $0[bundleId] = category }
        return category
    }

    /// 这个 bundle 命不命中用户选的类别。
    func matches(bundleId: String, selected: Set<String>) -> Bool {
        guard !selected.isEmpty else { return false }
        return Self.matches(declared: category(of: bundleId), selected: selected)
    }

    /// 命中判定:精确匹配,或选了 `games` 时匹配任意 `*-games` 子类
    /// (Apple 把游戏切成 action-games / puzzle-games 等十几个子类,
    /// 用户选"Games (all)"显然是要全部)。
    ///
    /// **规则只有这一份** —— 音频那条路也调它,别再各写一份,两份一定会漂。
    static func matches(declared: String, selected: Set<String>) -> Bool {
        guard !declared.isEmpty, !selected.isEmpty else { return false }
        if selected.contains(declared) { return true }
        if selected.contains("public.app-category.games"), declared.hasSuffix("-games") { return true }
        return false
    }
}
