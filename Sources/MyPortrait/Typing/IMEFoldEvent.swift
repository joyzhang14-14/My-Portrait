import Foundation

/// Typing Observer v2 — Layer 2 IME 折叠层的输出单元。
///
/// `IMEStateMachine` 把零散的 `RawEdit`（拼音逐键、候选替换、退格……）
/// 折叠成「一次提交」或「一次删除」这样的语义事件。
struct IMEFoldEvent: Equatable {
    enum Kind { case commit, delete }

    let kind: Kind
    let text: String
    let script: Script
    let ts: TimeInterval
    let pid: pid_t
    let elementHash: Int
    var traceTag: TraceTag?
}

/// 事件在 4 层流水线里走过哪条路径的追踪标签。
/// L1 由 Layer 1 打；L2 由 IMEStateMachine 打。
enum TraceTag: Equatable, CustomStringConvertible {
    // MARK: L1
    case l1Pass
    case l1Drop(reason: String)

    // MARK: L2 normalize
    case l2DropEmptyInsert
    case l2RewriteReplaceToDelete
    case l2RewriteReplaceToInsert

    // MARK: L2 state machine
    case l2Commit(text: String)                            // 规则 1, 5, 6, 9, 10, 11
    case l2EnterComposing(text: String)                    // 规则 2
    case l2AppendBuffer(text: String)                      // 规则 3
    case l2FlushAndOpen(flushed: String, opened: String)   // 规则 4
    case l2BufferShrink(remaining: String)                 // 规则 7（buffer 非空）
    case l2BufferEmptyExitComposing                        // 规则 7（buffer 空）
    case l2IdleDelete                                      // 规则 8

    var description: String {
        switch self {
        case .l1Pass: return "L1:pass"
        case .l1Drop(let r): return "L1:drop:\(r)"
        case .l2DropEmptyInsert: return "L2:drop:empty-insert"
        case .l2RewriteReplaceToDelete: return "L2:rewrite:replace→delete"
        case .l2RewriteReplaceToInsert: return "L2:rewrite:replace→insert"
        case .l2Commit(let t): return "L2:commit \"\(t)\""
        case .l2EnterComposing(let t): return "L2:enter-composing buf=\"\(t)\""
        case .l2AppendBuffer(let t): return "L2:append buf+=\"\(t)\""
        case .l2FlushAndOpen(let f, let o): return "L2:flush \"\(f)\" + open \"\(o)\""
        case .l2BufferShrink(let r): return "L2:shrink buf=\"\(r)\""
        case .l2BufferEmptyExitComposing: return "L2:buffer-empty→Idle"
        case .l2IdleDelete: return "L2:idle-delete"
        }
    }
}
