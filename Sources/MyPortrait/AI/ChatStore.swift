import Foundation
import SQLite3
import Observation

/// `ChatMessage` predates Swift concurrency annotations. The array is built
/// entirely on the background task, then handed to MainActor without sharing
/// mutable storage between the two.
private struct BackgroundChatMessages: @unchecked Sendable {
    let value: [ChatMessage]
}

/// Persistent store for conversations and their messages.
///
/// Schema:
///   conversations(id, title, pinned, created_at, updated_at)
///   messages(id, conv_id, role, text, parts_json, time)
///
/// `parts_json` carries the assistant's `[ContentPart]` (tool cards + text)
/// JSON-encoded; absent for user messages.
@MainActor
@Observable
final class ChatStore {
    static let shared = ChatStore()

    private(set) var conversations: [Conversation] = []

    private var db: OpaquePointer?
    nonisolated(unsafe) private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        try? AIPaths.ensureExists()
        openDB()
        createSchema()
        reloadConversations()
    }

    // No explicit deinit — SQLite handle leaks at app exit, which is fine for
    // a process-lifetime singleton. Adding deinit would require nonisolated
    // access to a MainActor-isolated property.

    // MARK: - Conversation CRUD

    @discardableResult
    func createConversation(title: String = "New chat") -> Conversation {
        let conv = Conversation(
            id: UUID(),
            title: title,
            pinned: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        execute(
            "INSERT INTO conversations(id,title,pinned,created_at,updated_at) VALUES(?,?,?,?,?)",
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, conv.id.uuidString, -1, Self.SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, conv.title,         -1, Self.SQLITE_TRANSIENT)
                sqlite3_bind_int (stmt, 3, conv.pinned ? 1 : 0)
                sqlite3_bind_double(stmt, 4, conv.createdAt.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 5, conv.updatedAt.timeIntervalSince1970)
            }
        )
        reloadConversations()
        return conv
    }

    func deleteConversation(_ id: UUID) {
        // Pi session 文件落在 ~/.portrait/agent_sessions/ —— 跟 conv 一起删,
        // 否则该目录越攒越多死文件。Claude Code 的 session 在 ~/.claude/
        // 内部托管,我们不动。
        if let path = conversations.first(where: { $0.id == id })?.piSessionPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        execute("DELETE FROM messages WHERE conv_id=?") { sqlite3_bind_text($0, 1, id.uuidString, -1, Self.SQLITE_TRANSIENT) }
        execute("DELETE FROM conversations WHERE id=?") { sqlite3_bind_text($0, 1, id.uuidString, -1, Self.SQLITE_TRANSIENT) }
        reloadConversations()
    }

    func renameConversation(_ id: UUID, to title: String) {
        execute("UPDATE conversations SET title=?, updated_at=? WHERE id=?") { stmt in
            sqlite3_bind_text(stmt, 1, title, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, id.uuidString, -1, Self.SQLITE_TRANSIENT)
        }
        reloadConversations()
    }

    func togglePinned(_ id: UUID) {
        execute("UPDATE conversations SET pinned = 1 - pinned WHERE id=?") {
            sqlite3_bind_text($0, 1, id.uuidString, -1, Self.SQLITE_TRANSIENT)
        }
        reloadConversations()
    }

    /// Bump 一个 conv 在 RECENTS 列表里的顺序到顶。**只在用户真发了一条
    /// 新消息时调** —— 切对话 / picker 改 model / 空对话保存这些"被动持久化"
    /// 不调,否则 RECENTS 会被无意义动作搅乱。
    /// ChatController.send() 等真发消息的路径显式调一次。
    func touchConversation(_ id: UUID) {
        execute("UPDATE conversations SET updated_at=? WHERE id=?") { stmt in
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, id.uuidString, -1, Self.SQLITE_TRANSIENT)
        }
        reloadConversations()
    }

    // MARK: - Message CRUD

    /// m.parts 编码器复用 —— saveMessages 每条消息都 encode 一次(流式 persist
    /// 反复调),别每次新建。
    private static let partsEncoder = JSONEncoder()

    /// Replace stored messages for `convId` with `messages`. Cheap because we
    /// expect modest message counts per conv (~hundreds at worst). Called from
    /// ChatController after each turn ends.
    func saveMessages(_ messages: [ChatMessage], for convId: UUID) {
        guard let db else { return }
        sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION", nil, nil, nil)
        defer { sqlite3_exec(db, "COMMIT", nil, nil, nil) }

        execute("DELETE FROM messages WHERE conv_id=?") {
            sqlite3_bind_text($0, 1, convId.uuidString, -1, Self.SQLITE_TRANSIENT)
        }
        for m in messages {
            let partsJSON: String? = m.parts.isEmpty ? nil :
                (try? Self.partsEncoder.encode(m.parts)).flatMap { String(data: $0, encoding: .utf8) }
            execute(
                "INSERT INTO messages(id,conv_id,role,text,parts_json,time) VALUES(?,?,?,?,?,?)"
            ) { stmt in
                sqlite3_bind_text(stmt, 1, m.id.uuidString, -1, Self.SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, convId.uuidString, -1, Self.SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, m.role.rawValue, -1, Self.SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, m.text, -1, Self.SQLITE_TRANSIENT)
                if let partsJSON {
                    sqlite3_bind_text(stmt, 5, partsJSON, -1, Self.SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 5)
                }
                sqlite3_bind_double(stmt, 6, m.time.timeIntervalSince1970)
            }
        }
        // **不在 saveMessages 里 touch** —— saveMessages 也被「切走 persist」
        // 路径调,如果 touch 就等于"切走时把刚才那个 conv 顶上去",RECENTS
        // 永远跟着用户切对话动。touch 改成由 ChatController.send() 在真发
        // 消息时显式调。
        // **也不 reload** —— saveMessages 不碰 conversations 表,sidebar 只读
        // conv 元数据(title/pinned/updatedAt),不显示消息内容;之前无条件
        // reloadConversations() 只是让侧栏每次 persist 白白 re-diff 一遍
        // (cron 流式期间 ~3Hz)。
    }

    /// 单条消息 upsert(messages.id 是 PRIMARY KEY → INSERT OR REPLACE 单行)。
    /// 流式高频落盘路径用:只重写正在变化的那条 assistant 消息,不像
    /// saveMessages 全量 DELETE+重插整个 conv(O(对话体积))。消息会被
    /// 删除的路径(regenerate / editAndResend)仍走 saveMessages 全量重写。
    func upsertMessage(_ m: ChatMessage, for convId: UUID) {
        let partsJSON: String? = m.parts.isEmpty ? nil :
            (try? Self.partsEncoder.encode(m.parts)).flatMap { String(data: $0, encoding: .utf8) }
        execute(
            "INSERT OR REPLACE INTO messages(id,conv_id,role,text,parts_json,time) VALUES(?,?,?,?,?,?)"
        ) { stmt in
            sqlite3_bind_text(stmt, 1, m.id.uuidString, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, convId.uuidString, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, m.role.rawValue, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, m.text, -1, Self.SQLITE_TRANSIENT)
            if let partsJSON {
                sqlite3_bind_text(stmt, 5, partsJSON, -1, Self.SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            sqlite3_bind_double(stmt, 6, m.time.timeIntervalSince1970)
        }
    }

    func loadMessages(for convId: UUID) -> [ChatMessage] {
        guard let db else { return [] }
        return Self.loadMessages(from: db, for: convId)
    }

    /// History payloads can contain megabytes of hidden tool output even when
    /// the visible conversation has only a few short messages. Read and decode
    /// them on a dedicated read-only connection so opening a conversation never
    /// blocks MainActor (and therefore the whole app UI).
    func loadMessagesInBackground(for convId: UUID) async -> [ChatMessage] {
        let dbPath = AIPaths.chatDB.path
        let loaded = await Task.detached(priority: .userInitiated) {
            BackgroundChatMessages(value: Self.loadMessages(at: dbPath, for: convId))
        }.value
        return loaded.value
    }

    nonisolated private static func loadMessages(at dbPath: String, for convId: UUID) -> [ChatMessage] {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbPath, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            return []
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 5_000)
        return loadMessages(from: handle, for: convId)
    }

    nonisolated private static func loadMessages(from db: OpaquePointer, for convId: UUID) -> [ChatMessage] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT id, role, text, parts_json, time FROM messages WHERE conv_id=? ORDER BY time ASC"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, convId.uuidString, -1, Self.SQLITE_TRANSIENT)

        var out: [ChatMessage] = []
        let decoder = JSONDecoder()
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let idCStr   = sqlite3_column_text(stmt, 0),
                let id       = UUID(uuidString: String(cString: idCStr)),
                let roleStr  = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                let role     = ChatRole(rawValue: roleStr)
            else { continue }
            let text = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            var parts: [ContentPart] = []
            if let pj = sqlite3_column_text(stmt, 3) {
                let json = String(cString: pj)
                if let data = json.data(using: .utf8),
                   let decoded = try? decoder.decode([ContentPart].self, from: data) {
                    parts = decoded
                }
            }
            let time = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            out.append(ChatMessage(id: id, role: role, text: text, parts: parts, time: time))
        }
        return out
    }

    // MARK: - Loading

    private func reloadConversations() {
        guard let db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            SELECT id, title, pinned, created_at, updated_at, provider_id, model, claude_session_id, pi_session_path
            FROM conversations
            ORDER BY pinned DESC, updated_at DESC
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

        var rows: [Conversation] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let idCStr = sqlite3_column_text(stmt, 0),
                let id = UUID(uuidString: String(cString: idCStr))
            else { continue }
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "New chat"
            let pinned = sqlite3_column_int(stmt, 2) != 0
            let created = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            let updated = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            // provider_id / model 是 v2 migration 加的列;NULL 时读不到 cString,
            // map 给个 nil(fallback 读全局 AppState)。
            let providerId = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            let model = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            let claudeSid = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
            let piPath = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
            rows.append(Conversation(
                id: id, title: title, pinned: pinned,
                createdAt: created, updatedAt: updated,
                providerId: providerId, model: model,
                claudeSessionId: claudeSid, piSessionPath: piPath
            ))
        }
        self.conversations = rows
    }

    /// Per-conv provider/model 锁定。HomeView 的 model picker 切换时调,把
    /// 当前选择写进这个 conv;切回时读出来用。NULL 表示"跟全局走"。
    ///
    /// **不动 updated_at** —— sidebar RECENTS 按 updated_at 排序,只 model
    /// lock 这种元数据更新不应该把 conv bump 到顶(用户切对话 → capture
    /// 触发 updateConversationModel → 列表大乱)。只有 saveMessages
    /// (真发消息)和 renameConversation 才动 updated_at。
    func updateConversationModel(_ id: UUID, providerId: String?, model: String?) {
        execute("UPDATE conversations SET provider_id=?, model=? WHERE id=?") { stmt in
            if let providerId {
                sqlite3_bind_text(stmt, 1, providerId, -1, Self.SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            if let model {
                sqlite3_bind_text(stmt, 2, model, -1, Self.SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            sqlite3_bind_text(stmt, 3, id.uuidString, -1, Self.SQLITE_TRANSIENT)
        }
        reloadConversations()
    }

    /// 查单条 conv 的 (providerId, model),给 ChatController 起 agent 时用。
    /// 缺省走 reload 后的内存 cache,不打 DB。
    func conversationModel(id: UUID) -> (providerId: String?, model: String?) {
        guard let conv = conversations.first(where: { $0.id == id }) else { return (nil, nil) }
        return (conv.providerId, conv.model)
    }

    /// Claude Code session id 持久化。每条 conv 一个 sid:第一次 sendPrompt
    /// 后 ClaudeCodeAgent 从响应里抓出 sid,通过 ChatController 调这个落盘;
    /// 切回该 conv 时 ChatController 把 sid 喂给新 spawn 的 agent,用
    /// `claude --print -r <sid>` 续上下文。
    ///
    /// **不动 updated_at** —— 跟 updateConversationModel 同样原因,session
    /// 元数据写入不应该把 conv bump 到 RECENTS 顶部。
    func updateClaudeSessionId(_ id: UUID, _ sid: String?) {
        execute("UPDATE conversations SET claude_session_id=? WHERE id=?") { stmt in
            if let sid {
                sqlite3_bind_text(stmt, 1, sid, -1, Self.SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            sqlite3_bind_text(stmt, 2, id.uuidString, -1, Self.SQLITE_TRANSIENT)
        }
        // **不 reload**:sidebar 的 conv list 不显示 sid,reload 没意义,反而
        // 让每个 token 抓到 sid 都触发 conversations 数组重建 → SwiftUI diff
        // 把整列重画一遍。手动改下内存 cache 里那一条就够。
        if let i = conversations.firstIndex(where: { $0.id == id }) {
            conversations[i].claudeSessionId = sid
        }
    }

    func claudeSessionId(for id: UUID) -> String? {
        conversations.first { $0.id == id }?.claudeSessionId
    }

    /// Pi session 文件路径持久化。空 → 该 conv 还没分配过 session,
    /// ChatController 起 PiAgent 时给它派一个 `~/.portrait/agent_sessions/<convId>.jsonl`
    /// 并写回这里。后续切走再切回直接复用,pi `--session <path>` 把整段
    /// jsonl replay 回上下文。
    ///
    /// **不动 updated_at**(同 updateClaudeSessionId 注释)。
    func updatePiSessionPath(_ id: UUID, _ path: String?) {
        execute("UPDATE conversations SET pi_session_path=? WHERE id=?") { stmt in
            if let path {
                sqlite3_bind_text(stmt, 1, path, -1, Self.SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            sqlite3_bind_text(stmt, 2, id.uuidString, -1, Self.SQLITE_TRANSIENT)
        }
        if let i = conversations.firstIndex(where: { $0.id == id }) {
            conversations[i].piSessionPath = path
        }
    }

    func piSessionPath(for id: UUID) -> String? {
        conversations.first { $0.id == id }?.piSessionPath
    }

    // MARK: - DB plumbing

    private func openDB() {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(AIPaths.chatDB.path, &handle, flags, nil) == SQLITE_OK {
            self.db = handle
            sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            sqlite3_exec(handle, "PRAGMA busy_timeout=5000;", nil, nil, nil)
            sqlite3_exec(handle, "PRAGMA foreign_keys=ON;", nil, nil, nil)
        }
    }

    private func createSchema() {
        guard let db else { return }
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS conversations (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                pinned INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                conv_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                role TEXT NOT NULL,
                text TEXT NOT NULL,
                parts_json TEXT,
                time REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS messages_conv_time ON messages(conv_id, time);
        """, nil, nil, nil)

        // v2 migration:per-conv provider/model 锁定。NULL → 读全局 appState
        // 默认(老 conv 行为不变;用户在 picker 改 model 时才填实值)。
        // ALTER TABLE 是 idempotent —— 列已经存在时 SQLite 报"duplicate column",
        // 我们忽略错误,跑不跑都得正确。
        sqlite3_exec(db, "ALTER TABLE conversations ADD COLUMN provider_id TEXT", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE conversations ADD COLUMN model TEXT",       nil, nil, nil)
        // v3:claude code session id。每条 conv 一个 sid,ClaudeCodeAgent
        // 用 `claude --print -r <sid>` 续上下文。不存的话切走再切回 AI
        // 不记得之前聊过什么(claude --print 默认起新 session)。
        sqlite3_exec(db, "ALTER TABLE conversations ADD COLUMN claude_session_id TEXT", nil, nil, nil)
        // v3.1:pi-coding-agent session 文件绝对路径。每条 conv 一个 jsonl,
        // PiAgent 启动时 `--session <path>` 加载,pi 内部把每轮 prompt /
        // assistant 消息 append 进去。同 conv 内多轮上下文 + 切走再切回
        // 都靠这条恢复。
        sqlite3_exec(db, "ALTER TABLE conversations ADD COLUMN pi_session_path TEXT", nil, nil, nil)
    }

    private func execute(_ sql: String, bind: ((OpaquePointer?) -> Void)? = nil) {
        guard let db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        bind?(stmt)
        _ = sqlite3_step(stmt)
    }
}

// MARK: - Models

struct Conversation: Identifiable, Hashable {
    let id: UUID
    var title: String
    var pinned: Bool
    let createdAt: Date
    var updatedAt: Date
    /// Per-conversation AI provider lock。Nil → fallback 读全局
    /// AppState.activeAIId(老 conv / 没在 picker 改过的 conv 走这条)。
    /// 非 nil → 这个 conv 锁定了 picker 选过的 provider,切走再切回不变。
    var providerId: String? = nil
    /// 同上,锁定 model 名(provider 的 availableModels 之一)。
    var model: String? = nil
    /// Claude Code 的 session id —— 让切走再切回不丢上下文。
    /// Pi / 其它 provider 用不到这条。
    var claudeSessionId: String? = nil
    /// Pi 的 session 文件绝对路径 —— 切走再切回时 PiAgent
    /// `--session <path>` 让 pi 把 jsonl replay 回上下文。
    /// Claude Code 用不到这条(它走自家 -r <sid>)。
    var piSessionPath: String? = nil
}
