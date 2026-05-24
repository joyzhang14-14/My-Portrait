import Foundation
import AppKit

/// localized app name(`frames.app_name`,如 "Claude")→ bundle id
/// (`typing_events.bundle_id`,如 "com.anthropic.claudefordesktop")的翻译。
///
/// 为什么需要:typing_events / keystroke_log 用 bundle_id,frames 用 localized
/// name。Step 0 / Worker 合并 session 时按 app 字段相等做匹配,如果不归一,
/// 同物理 app 被切成两条 session(Claude / com.anthropic.claudefordesktop)。
///
/// 翻译来源:
/// 1. `hardcoded` —— 常用 app 写死,历史数据(app 已退出时)也能翻
/// 2. `runtime` —— NSWorkspace.runningApplications 当前活着的 app,
///    覆盖 hardcoded 之外的
/// 3. **查不到 fallback 原 localized name** —— 不抛错,保 best effort
struct AppIdentifierNormalizer {

    /// 用户常用 app 的 localized name → bundle id 硬编码映射。
    /// 历史数据(app 退出 / 卸载)走不了 runtime 时这里 fallback。
    private static let hardcoded: [String: String] = [
        "Claude":            "com.anthropic.claudefordesktop",
        "Safari":            "com.apple.Safari",
        "Obsidian":          "md.obsidian",
        "Discord":           "com.hnc.Discord",
        "Notes":             "com.apple.Notes",
        "Terminal":          "com.apple.Terminal",
        "iTerm2":            "com.googlecode.iterm2",
        "Xcode":             "com.apple.dt.Xcode",
        "Finder":            "com.apple.finder",
        "Spotify":           "com.spotify.client",
        "System Settings":   "com.apple.systempreferences",
        "微信":              "com.tencent.xinWeChat",
        "WeChat":            "com.tencent.xinWeChat",
        "Google Chrome":     "com.google.Chrome",
        "Microsoft Edge":    "com.microsoft.edgemac",
        "Arc":               "company.thebrowser.Browser",
        "Firefox":           "org.mozilla.firefox",
        "Slack":             "com.tinyspeck.slackmacgap",
        "Mail":              "com.apple.mail",
        "Calendar":          "com.apple.iCal",
        "Reminders":         "com.apple.reminders",
        "Messages":          "com.apple.MobileSMS",
        "FaceTime":          "com.apple.FaceTime",
        "Preview":           "com.apple.Preview",
        "TextEdit":          "com.apple.TextEdit",
        "Pages":             "com.apple.iWork.Pages",
        "Numbers":           "com.apple.iWork.Numbers",
        "Keynote":           "com.apple.iWork.Keynote",
        "Snipaste":          "net.snipaste.Snipaste",
        "My Portrait":       "com.joyzhang.myportrait",
        "loginwindow":       "com.apple.loginwindow",
    ]

    private let runtime: [String: String]

    /// 拍一份 NSWorkspace 当前运行 app 的 localized → bundle 映射(只读,
    /// thread-safe)。在 worker 入口建一次,整个 Pass 共用。
    static func snapshot() -> AppIdentifierNormalizer {
        let runtime = Dictionary(
            NSWorkspace.shared.runningApplications.compactMap {
                app -> (String, String)? in
                guard let name = app.localizedName,
                      let bid = app.bundleIdentifier else { return nil }
                return (name, bid)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return AppIdentifierNormalizer(runtime: runtime)
    }

    private init(runtime: [String: String]) {
        self.runtime = runtime
    }

    /// 翻译:localized name → bundle id。
    /// 如果输入已经像 bundle id(含 ".")或者查不到,原样返回。
    func bundleId(forLocalizedName name: String) -> String {
        // 已经是 bundle id 风格 → 不动
        if name.contains(".") { return name }
        if let bid = Self.hardcoded[name] { return bid }
        if let bid = runtime[name] { return bid }
        return name   // best effort fallback
    }
}
