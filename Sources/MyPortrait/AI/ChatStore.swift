import Foundation
import SQLite3
import Observation

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

    private func touchConversation(_ id: UUID) {
        execute("UPDATE conversations SET updated_at=? WHERE id=?") { stmt in
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, id.uuidString, -1, Self.SQLITE_TRANSIENT)
        }
        reloadConversations()
    }

    // MARK: - Message CRUD

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
                (try? JSONEncoder().encode(m.parts)).flatMap { String(data: $0, encoding: .utf8) }
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
        touchConversation(convId)
    }

    func loadMessages(for convId: UUID) -> [ChatMessage] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT id, role, text, parts_json, time FROM messages WHERE conv_id=? ORDER BY time ASC"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, convId.uuidString, -1, Self.SQLITE_TRANSIENT)

        var out: [ChatMessage] = []
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
                   let decoded = try? JSONDecoder().decode([ContentPart].self, from: data) {
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
            SELECT id, title, pinned, created_at, updated_at
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
            rows.append(Conversation(id: id, title: title, pinned: pinned, createdAt: created, updatedAt: updated))
        }
        self.conversations = rows
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
}
