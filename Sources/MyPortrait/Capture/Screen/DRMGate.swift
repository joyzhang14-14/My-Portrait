import Foundation

/// DRM 内容黑名单。命中则跳过该帧（P1）。
///
/// P5 升级：检测到 DRM 时停整条 SCStream（macOS 会主动黑掉受保护内容，
/// 不及时停 stream 会导致 Netflix 等播放黑屏）。
///
/// 名单抄 My-Orphies drm_detector.rs。所有比较小写化 + substring。
/// "max" 必须精确匹配，避免误伤"max headroom"之类的窗口标题。
struct DRMGate: Sendable {

    private static let blockedAppNames: Set<String> = [
        "netflix", "disney+", "hulu", "prime video", "apple tv",
        "peacock", "paramount+", "hbo max", "crunchyroll", "dazn",
        "horizon client"
    ]

    /// 精确匹配（不做 substring），避免 false positive。
    private static let blockedAppNamesExact: Set<String> = ["max"]

    private static let blockedUrlDomains: Set<String> = [
        "netflix.com", "disneyplus.com", "hulu.com", "primevideo.com",
        "tv.apple.com", "peacocktv.com", "paramountplus.com",
        "play.max.com", "crunchyroll.com", "dazn.com"
    ]

    /// 当前焦点是否在 DRM 内容上。`true` → 跳过这一帧（P1）。
    func isBlocked(_ focus: FocusInfo) -> Bool {
        let app = focus.appName.lowercased()

        if Self.blockedAppNamesExact.contains(app) { return true }
        for name in Self.blockedAppNames where app.contains(name) { return true }

        if let url = focus.browserUrl?.lowercased() {
            for domain in Self.blockedUrlDomains where url.contains(domain) {
                return true
            }
            // Amazon Prime Video 走特殊路径
            if url.contains("amazon.com/gp/video/") { return true }
        }

        return false
    }
}
