import Foundation
import QuartzCore
import os.log

/// Typing Observer v2 — Layer 2 「IME 折叠层」。
///
/// 每个实例对应一个 AX element（M2 阶段单实例，M3 加 Registry 多实例）。
///
/// 职责：把 Layer 1 喂进来的零散 `RawEdit` 折叠成语义化的 `IMEFoldEvent`。
/// 典型场景：拼音输入「z h o n g」5 次 latin insert 攒成 buffer，
/// 候选框落字时一条 replace 覆盖 buffer → 输出 1 条 cjk commit「中」。
///
/// 状态机 11 条规则 + 入口 normalize 3 条，详见 `feed` 实现。
/// M2 阶段不接 KeystrokeLedger 也不接 AX。
final class IMEStateMachine {

    // MARK: - 状态

    enum State {
        case idle
        /// 拉丁逐键拼写中：buffer 是已攒的字符；anchor 是 buffer 在文档里
        /// 占据的 UTF-16 范围；`anchorLength` 始终 == `buffer.utf16.count`。
        case composing(buffer: String, anchorLocation: Int, anchorLength: Int, openedAt: TimeInterval)
    }

    private var state: State = .idle

    /// normalize 阶段的 trace tag —— normalize 不输出事件，无处可挂，
    /// 单测断言此 var。每次 `feed` 顶部重置。
    private(set) var lastTraceTag: TraceTag?

    private let log = Logger(subsystem: "com.joyzhang.myportrait", category: "typing.ime")

    init() {}

    // MARK: - 主入口

    /// 喂一条 `RawEdit`，返回这条产生的 `IMEFoldEvent` 序列（0 或 1 条）。
    ///
    /// - 0 条：规则 3（追加 buffer，不输出）、规则 7 buffer 砍后非空、
    ///   规则 2（进 Composing 不输出）、normalize 丢弃空 insert。
    /// - 1 条：规则 1 / 4 / 5 / 6 / 7(buffer 空) / 8 / 11。
    func feed(_ raw: RawEdit) -> [IMEFoldEvent] {
        lastTraceTag = nil

        // ── 入口 normalize（spec 之外加的 3 条）────────────────────
        let edit: RawEdit
        switch raw.kind {
        case .insert where raw.text.isEmpty:
            // 空 insert：无意义，丢弃。
            lastTraceTag = .l2DropEmptyInsert
            log.debug("\(TraceTag.l2DropEmptyInsert.description)")
            return []

        case .replace where raw.text.isEmpty && raw.range.length > 0:
            // 「替换成空」== 删除：重写为 delete。
            lastTraceTag = .l2RewriteReplaceToDelete
            log.debug("\(TraceTag.l2RewriteReplaceToDelete.description)")
            edit = RawEdit(kind: .delete, text: "", script: raw.script,
                           range: raw.range, ts: raw.ts, pid: raw.pid,
                           elementHash: raw.elementHash, traceTag: raw.traceTag)

        case .replace where raw.range.length == 0:
            // 「替换 0 长度范围」== 插入：重写为 insert。
            lastTraceTag = .l2RewriteReplaceToInsert
            log.debug("\(TraceTag.l2RewriteReplaceToInsert.description)")
            edit = RawEdit(kind: .insert, text: raw.text, script: raw.script,
                           range: raw.range, ts: raw.ts, pid: raw.pid,
                           elementHash: raw.elementHash, traceTag: raw.traceTag)

        default:
            edit = raw
        }

        // ── 11 条规则，从上往下，命中第一条停 ───────────────────
        let cjkPath = edit.script.usesCJKPath(edit.text)

        switch (state, edit.kind) {

        // 规则 1：Idle + insert(cjk path) → 直接 commit，留 Idle。
        case (.idle, .insert) where cjkPath:
            return [emitCommit(text: edit.text, from: edit)]

        // 规则 2：Idle + insert(latin path) → 进 Composing，不输出。
        case (.idle, .insert):
            state = .composing(buffer: edit.text,
                               anchorLocation: edit.range.location,
                               anchorLength: edit.text.utf16.count,
                               openedAt: edit.ts)
            trace(.l2EnterComposing(text: edit.text))
            return []

        // 规则 8：Idle + delete → 输出一条 delete 信号，text 带被删内容。
        case (.idle, .delete):
            trace(.l2IdleDelete)
            return [IMEFoldEvent(kind: .delete, text: edit.text,
                                 script: Script.classify(edit.text),
                                 ts: edit.ts, pid: edit.pid,
                                 elementHash: edit.elementHash,
                                 traceTag: .l2IdleDelete)]

        // Composing 状态下的 insert：规则 3 / 4。
        case (.composing(let buffer, let anchorLoc, let anchorLen, _), .insert)
        where !cjkPath:
            if edit.range.location == anchorLoc + anchorLen {
                // 规则 3：连续插入 → 追加 buffer，不输出。
                let newBuffer = buffer + edit.text
                state = .composing(buffer: newBuffer,
                                   anchorLocation: anchorLoc,
                                   anchorLength: newBuffer.utf16.count,
                                   openedAt: edit.ts)
                trace(.l2AppendBuffer(text: edit.text))
                return []
            } else {
                // 规则 4：非连续插入 → flush 旧 buffer，开新 Composing。
                let flushed = emitCommit(text: buffer, from: edit,
                                         tag: .l2FlushAndOpen(flushed: buffer,
                                                              opened: edit.text))
                state = .composing(buffer: edit.text,
                                   anchorLocation: edit.range.location,
                                   anchorLength: edit.text.utf16.count,
                                   openedAt: edit.ts)
                return [flushed]
            }

        // Composing 状态下的 replace：规则 5 / 6（range 覆盖 anchor）。
        case (.composing(_, let anchorLoc, let anchorLen, _), .replace)
        where edit.range.location <= anchorLoc
            && edit.range.location + edit.range.length >= anchorLoc + anchorLen:
            // 候选框落字：replace 覆盖整个 anchor → commit 落字文本，回 Idle。
            // script 由 classify(text) 决定（cjk path → cjk，否则 latin）。
            state = .idle
            return [emitCommit(text: edit.text, from: edit)]

        // Composing 状态下的 delete：规则 7。
        case (.composing(let buffer, let anchorLoc, _, let openedAt), .delete):
            let newBuffer = String(buffer.dropLast())
            if newBuffer.isEmpty {
                state = .idle
                trace(.l2BufferEmptyExitComposing)
                return []
            } else {
                state = .composing(buffer: newBuffer,
                                   anchorLocation: anchorLoc,
                                   anchorLength: newBuffer.utf16.count,
                                   openedAt: openedAt)
                trace(.l2BufferShrink(remaining: newBuffer))
                return []
            }

        // 规则 11：其他未识别组合 → 直接 commit，不改状态。
        default:
            return [emitCommit(text: edit.text, from: edit)]
        }
    }

    // MARK: - 超时驱动（规则 9）

    /// 调用方每 N ms tick 一次。Composing 状态下 `now - openedAt > timeoutMs`
    /// → flush buffer 为 latin commit，回 Idle。
    func tick(now: TimeInterval, timeoutMs: Int = 350) -> [IMEFoldEvent] {
        guard case .composing(let buffer, _, _, let openedAt) = state else {
            return []
        }
        guard (now - openedAt) * 1000.0 > Double(timeoutMs) else {
            return []
        }
        state = .idle
        let event = IMEFoldEvent(kind: .commit, text: buffer,
                                 script: Script.classify(buffer),
                                 ts: now, pid: 0, elementHash: 0,
                                 traceTag: .l2Commit(text: buffer))
        trace(.l2Commit(text: buffer))
        return [event]
    }

    // MARK: - 焦点切换（规则 10）

    /// 焦点切换：强制 flush 任何 Composing buffer，回 Idle。
    func handleFocusChange() -> [IMEFoldEvent] {
        guard case .composing(let buffer, _, _, let openedAt) = state else {
            return []
        }
        state = .idle
        let event = IMEFoldEvent(kind: .commit, text: buffer,
                                 script: Script.classify(buffer),
                                 ts: openedAt, pid: 0, elementHash: 0,
                                 traceTag: .l2Commit(text: buffer))
        trace(.l2Commit(text: buffer))
        return [event]
    }

    // MARK: - 私有辅助

    /// 构造一条 commit 事件。`script` 一律由 `Script.classify(text)` 重算
    /// （flush buffer 时 text 是 buffer 不是原 raw.text，不能直接搬 raw.script）。
    private func emitCommit(text: String, from edit: RawEdit,
                            tag: TraceTag? = nil) -> IMEFoldEvent {
        let traceTag = tag ?? .l2Commit(text: text)
        trace(traceTag)
        return IMEFoldEvent(kind: .commit, text: text,
                            script: Script.classify(text),
                            ts: edit.ts, pid: edit.pid,
                            elementHash: edit.elementHash,
                            traceTag: traceTag)
    }

    private func trace(_ tag: TraceTag) {
        log.debug("\(tag.description)")
    }
}
