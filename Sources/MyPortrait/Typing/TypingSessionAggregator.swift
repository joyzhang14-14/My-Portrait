import Foundation

/// Typing Observer v2 — Layer 3「会话聚合层」。
///
/// Layer 2 输出的 `IMEFoldEvent` 是逐次 commit / delete 的语义事件。
/// Layer 3 把同一个 (pid, AX element) 上的一串 event 攒成一次「输入会话」：
/// 累加 editLog / commitCount / deleteCount，关闭时产出一条 `TypingEvent`
/// 写库。
///
/// **纯数据 / 纯逻辑** —— 不碰 AX、不碰 DB store。AX 读取（finalText 来源）
/// 与 DB 写入由 `TypingObserver` 负责，本类只做内存里的聚合与产出。
///
/// 不做线程同步 —— 调用方（TypingObserver）全程在 MainActor 上跑。

/// 会话路由键 = (进程, AX 元素 hash)。
struct SessionKey: Hashable {
    let pid: pid_t
    let elementHash: Int
}

/// 建会话时由 `TypingObserver` 提供的上下文（仅建 session 那一刻用）。
struct SessionContext {
    let bundleId: String
    let appName: String?
    let windowTitle: String?
    let elementRole: String?
    let threadId: String
}

final class TypingSessionAggregator {

    /// 单个输入会话的累积状态。
    private struct Session {
        /// 会话开始的真实时间（产出 TypingEvent 的 startedAtMs 来源）。
        let startedAt: Date
        /// 第一条 IMEFoldEvent 的 `ts`（CACurrentMediaTime）——editLog 相对时间基准。
        let sessionStartTs: TimeInterval
        /// 最近一条 event 的 `ts` —— idle 判定用。
        var lastTs: TimeInterval
        var commitCount: Int
        var deleteCount: Int
        var editLog: [EditEntry]
        /// 累计 commit 文本字符数 —— max_chars 触发的代理指标。
        var committedChars: Int
        let ctx: SessionContext
    }

    /// 累计 commit 字符数超过这个值 → feed 返回 true，触发 max_chars 关闭。
    private static let maxChars = 10_000

    private var sessions: [SessionKey: Session] = [:]

    init() {}

    // MARK: - feed

    /// 喂一条 Layer 2 输出。无 session 则用 `ctx` 新建。
    /// 累加 editLog / commitCount / deleteCount / committedChars。
    /// - Returns: 该 session 累计 commit 字符数是否已超 `maxChars`（供 max_chars 触发）。
    @discardableResult
    func feed(_ event: IMEFoldEvent, key: SessionKey, ctx: SessionContext) -> Bool {
        var session: Session
        if let existing = sessions[key] {
            session = existing
        } else {
            session = Session(
                startedAt: Date(),
                sessionStartTs: event.ts,
                lastTs: event.ts,
                commitCount: 0,
                deleteCount: 0,
                editLog: [],
                committedChars: 0,
                ctx: ctx
            )
        }

        let kind: EditEntry.Kind = (event.kind == .commit) ? .commit : .delete
        session.editLog.append(EditEntry(
            ts: event.ts - session.sessionStartTs,
            kind: kind,
            text: event.text
        ))
        if event.kind == .commit {
            session.commitCount += 1
            session.committedChars += event.text.count
        } else {
            session.deleteCount += 1
        }
        session.lastTs = event.ts

        sessions[key] = session
        return session.committedChars > Self.maxChars
    }

    // MARK: - close

    /// 关闭会话并产出 `TypingEvent`。
    /// `finalText.count >= 3` → 产出；`< 3` → 返回 nil（丢弃）。
    /// 无论产出与否，都从字典移除该 key。
    func close(key: SessionKey, finalText: String, reason: String) -> TypingEvent? {
        guard let session = sessions[key] else { return nil }
        sessions[key] = nil

        guard finalText.count >= 3 else { return nil }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let startedMs = Int64(session.startedAt.timeIntervalSince1970 * 1000)
        let ctx = session.ctx
        return TypingEvent(
            id: nil,
            startedAtMs: startedMs,
            endedAtMs: now,
            bundleId: ctx.bundleId,
            appName: ctx.appName,
            windowTitle: ctx.windowTitle,
            url: nil,
            elementRole: ctx.elementRole,
            threadId: ctx.threadId,
            text: finalText,
            charCount: finalText.count,
            languageHint: Self.languageHint(for: finalText),
            createdAtMs: now,
            editLog: session.editLog,
            closeReason: reason
        )
    }

    // MARK: - 查询

    /// 所有 `now - lastTs > idleSeconds` 的 session key（供 idle_close 用）。
    func idleKeys(now: TimeInterval, idleSeconds: TimeInterval) -> [SessionKey] {
        sessions.compactMap { key, session in
            (now - session.lastTs > idleSeconds) ? key : nil
        }
    }

    func hasSession(_ key: SessionKey) -> Bool {
        sessions[key] != nil
    }

    func allKeys() -> [SessionKey] {
        Array(sessions.keys)
    }

    // MARK: - 私有

    /// `Script.classify` → languageHint 字符串（cjk / latin / mixed / other）。
    private static func languageHint(for text: String) -> String {
        switch Script.classify(text) {
        case .cjk:   return "cjk"
        case .latin: return "latin"
        case .mixed: return "mixed"
        case .other: return "other"
        }
    }
}
