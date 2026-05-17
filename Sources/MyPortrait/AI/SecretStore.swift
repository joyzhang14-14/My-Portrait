import Foundation
import CryptoKit
import Security
import SQLite3

/// Encrypted key/value store. Mirrors the Rust `screenpipe_secrets::SecretStore`:
///   - 32-byte AES-256-GCM master key in macOS Keychain (one entry).
///   - SQLite table `secrets(key, nonce, ciphertext)` stores ciphertext per key.
///
/// Used to hold OAuth tokens, API keys, anything that must not sit in plaintext.
final class SecretStore: @unchecked Sendable {
    static let shared = SecretStore()

    private let dbPath: String
    private let keychainService = "com.joyzhang.MyPortrait.SecretStore"
    private let keychainAccount = "MasterKey"
    private var db: OpaquePointer?
    private let key: SymmetricKey
    private let lock = NSLock()

    private init() {
        try? AIPaths.ensureExists()
        self.dbPath = AIPaths.secretsDB.path
        self.key = Self.loadOrCreateMasterKey(service: keychainService, account: keychainAccount)
        openDB()
        createSchema()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Public API

    func get(_ key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT nonce, ciphertext FROM secrets WHERE key=?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, key, -1, Self.SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        guard let nonceBlob = sqlite3_column_blob(stmt, 0) else { return nil }
        let nonceLen = Int(sqlite3_column_bytes(stmt, 0))
        guard let cipherBlob = sqlite3_column_blob(stmt, 1) else { return nil }
        let cipherLen = Int(sqlite3_column_bytes(stmt, 1))

        let nonceData = Data(bytes: nonceBlob, count: nonceLen)
        let cipherData = Data(bytes: cipherBlob, count: cipherLen)

        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            // AES-GCM combined = ciphertext || tag (last 16 bytes are tag)
            guard cipherData.count >= 16 else { return nil }
            let tag = cipherData.suffix(16)
            let ct = cipherData.prefix(cipherData.count - 16)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
            return try AES.GCM.open(box, using: self.key)
        } catch {
            return nil
        }
    }

    func set(_ key: String, value: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard let db else { throw SecretError.dbUnavailable }
        let sealed = try AES.GCM.seal(value, using: self.key)
        let nonce = Data(sealed.nonce)
        let cipher = sealed.ciphertext + sealed.tag

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "INSERT INTO secrets(key, nonce, ciphertext) VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET nonce=excluded.nonce, ciphertext=excluded.ciphertext"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SecretError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(stmt, 1, key, -1, Self.SQLITE_TRANSIENT)
        _ = nonce.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32($0.count), Self.SQLITE_TRANSIENT) }
        _ = cipher.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32($0.count), Self.SQLITE_TRANSIENT) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SecretError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    func delete(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "DELETE FROM secrets WHERE key=?", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, key, -1, Self.SQLITE_TRANSIENT)
        _ = sqlite3_step(stmt)
    }

    // MARK: - JSON convenience

    func setJSON<T: Encodable>(_ key: String, _ value: T) throws {
        let data = try JSONEncoder().encode(value)
        try set(key, value: data)
    }

    func getJSON<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let data = get(key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - DB setup

    private func openDB() {
        var handle: OpaquePointer?
        if sqlite3_open_v2(dbPath, &handle,
                           SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                           nil) == SQLITE_OK {
            self.db = handle
            sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            sqlite3_exec(handle, "PRAGMA busy_timeout=10000;", nil, nil, nil)
        }
    }

    private func createSchema() {
        guard let db else { return }
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS secrets (
                key TEXT PRIMARY KEY,
                nonce BLOB NOT NULL,
                ciphertext BLOB NOT NULL
            );
        """, nil, nil, nil)
    }

    // MARK: - Keychain master key

    /// Fetch the 32-byte AES master key from Keychain, generating + storing one if missing.
    private static func loadOrCreateMasterKey(service: String, account: String) -> SymmetricKey {
        if let existing = readKeychain(service: service, account: account),
           existing.count == 32 {
            return SymmetricKey(data: existing)
        }
        let new = SymmetricKey(size: .bits256)
        let data = new.withUnsafeBytes { Data($0) }
        writeKeychain(service: service, account: account, data: data)
        return new
    }

    private static func readKeychain(service: String, account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return data
    }

    private static func writeKeychain(service: String, account: String, data: Data) {
        // Delete any stale entry first to avoid duplicate errors.
        let del: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(del as CFDictionary)

        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(add as CFDictionary, nil)
    }

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

enum SecretError: Error {
    case dbUnavailable
    case sqlite(String)
}
