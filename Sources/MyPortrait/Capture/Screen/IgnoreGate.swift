import Foundation
import os

/// 用户配置的"屏蔽"闸门：app 名 + URL pattern。
///
/// 与 DRMGate 的区别：
///   - DRMGate：硬编码列表 + 系统级硬规则，命中 → 停整条流水线 + invalidate SCStream
///   - IgnoreGate：用户偏好（Settings UI 配置），命中 → 只跳本帧
///
/// URL 匹配：NSPredicate `LIKE[c]`，支持 `*` 通配。例：
///   - `*.bank.com/*`  → 匹配 `https://secure.bank.com/login` 等
///   - `*mail*`        → 匹配任何含 mail 的 URL
///   - `https://x.com/*` → 匹配 x.com 任意路径
final class IgnoreGate: @unchecked Sendable {

    private struct State {
        var appsLower: Set<String> = []
        var urlPatterns: [String] = []   // 小写 + LIKE 格式
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    init(initialApps: Set<String> = [], initialUrlPatterns: [String] = []) {
        state.withLock { s in
            s.appsLower = Set(initialApps.map { $0.lowercased() })
            s.urlPatterns = initialUrlPatterns.map { $0.lowercased() }
        }
    }

    /// Settings 变化时调（两组规则一起替换以保持原子性）。
    func setRules(apps: Set<String>, urlPatterns: [String]) {
        let normalizedApps = Set(apps.map { $0.lowercased() })
        let normalizedUrls = urlPatterns.map { $0.lowercased() }
        state.withLock { s in
            s.appsLower = normalizedApps
            s.urlPatterns = normalizedUrls
        }
    }

    func setIgnoredApps(_ apps: Set<String>) {
        let normalized = Set(apps.map { $0.lowercased() })
        state.withLock { $0.appsLower = normalized }
    }

    func setIgnoredUrlPatterns(_ patterns: [String]) {
        let normalized = patterns.map { $0.lowercased() }
        state.withLock { $0.urlPatterns = normalized }
    }

    /// 该帧是否应该跳过。app 匹配整名（不区分大小写），URL 走 glob。
    /// 命中 → 调用方应 return，但仍可记录焦点元数据。
    func shouldSkip(_ focus: FocusInfo) -> Bool {
        let snap = state.withLock { $0 }

        if snap.appsLower.contains(focus.appName.lowercased()) {
            return true
        }
        if let url = focus.browserUrl?.lowercased(), !snap.urlPatterns.isEmpty {
            for pattern in snap.urlPatterns {
                let pred = NSPredicate(format: "SELF LIKE[c] %@", pattern)
                if pred.evaluate(with: url) { return true }
            }
        }
        return false
    }

    /// 当前规则快照（调试 / 单测 / Settings UI 显示用）。
    var current: (apps: Set<String>, urlPatterns: [String]) {
        let s = state.withLock { $0 }
        return (s.appsLower, s.urlPatterns)
    }
}
