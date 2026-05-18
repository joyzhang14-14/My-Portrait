import Foundation
import os

/// 用户配置的"屏蔽 app 名"闸门。
///
/// 与 DRMGate 的区别：
///   - DRMGate：硬编码列表 + 系统级硬规则，命中 → 停整条流水线 + invalidate SCStream
///   - IgnoreGate：用户偏好列表（Settings UI 配置），命中 → 只跳本帧的截图 / OCR
///
/// 实现：`final class @unchecked Sendable + OSAllocatedUnfairLock`，
/// 因为 Coordinator (actor) 持有引用 + Services (MainActor) 设置规则，
/// 跨 actor 共享可变状态用锁是性能最优解。
final class IgnoreGate: @unchecked Sendable {

    /// 当前忽略集合。所有匹配大小写不敏感、整名匹配（不做 substring 防误伤）。
    /// 例：用户加 "Mail"，"MailMate" 不会被屏蔽。
    private let state = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    init(initial: Set<String> = []) {
        state.withLock { $0 = Set(initial.map { $0.lowercased() }) }
    }

    /// 替换当前规则（Settings 变化时调）。
    func setIgnoredApps(_ apps: Set<String>) {
        let normalized = Set(apps.map { $0.lowercased() })
        state.withLock { $0 = normalized }
    }

    /// 该帧是否应该跳过（仅按 app 名比对）。
    /// 命中 → 调用方应该 return，但仍可记录焦点元数据。
    func shouldSkip(_ focus: FocusInfo) -> Bool {
        state.withLock { ignored in
            ignored.contains(focus.appName.lowercased())
        }
    }

    /// 当前忽略集合（拷贝，调用方可只读用）。主要供调试 / 单测。
    var current: Set<String> {
        state.withLock { $0 }
    }
}
