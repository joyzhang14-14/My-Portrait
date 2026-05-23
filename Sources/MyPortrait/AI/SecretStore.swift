import Foundation
import CryptoKit
import Security
import SQLite3
import Darwin

/// Encrypted key/value store:
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

    // MARK: - Master key (file-backed)
    //
    // Stored at ~/.portrait/master.key with
    // 0600 perms (owner read/write only). On a FileVault'd disk this is
    // adequate for a dev tool; for a production release we'd switch to a
    // properly-signed app + Keychain with kSecUseDataProtectionKeychain.
    //
    // One-time migration: if a master key exists in the legacy Keychain
    // (from a previous build) and no on-disk key exists yet, we copy it to
    // disk and drop the Keychain entry so the OS stops prompting.

    /// Fetch the 32-byte AES master key from disk (migrating from Keychain
    /// the first time after this version ships). Generate a new key if
    /// neither source has one.
    private static func loadOrCreateMasterKey(service: String, account: String) -> SymmetricKey {
        let url = masterKeyURL()

        if let data = try? Data(contentsOf: url), data.count == 32 {
            return SymmetricKey(data: data)
        }

        // Migration from a previous Keychain-backed build.
        if let legacy = readLegacyKeychain(service: service, account: account),
           legacy.count == 32 {
            writeMasterKey(legacy, to: url)
            deleteLegacyKeychain(service: service, account: account)
            return SymmetricKey(data: legacy)
        }

        let new = SymmetricKey(size: .bits256)
        let data = new.withUnsafeBytes { Data($0) }
        writeMasterKey(data, to: url)
        return new
    }

    private static func masterKeyURL() -> URL {
        try? AIPaths.ensureExists()
        return AIPaths.supportDir.appendingPathComponent("master.key")
    }

    /// Write the key with 0600 perms (owner-only RW).
    private static func writeMasterKey(_ data: Data, to url: URL) {
        try? data.write(to: url, options: [.atomic])
        // chmod 0600
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    // MARK: - Legacy Keychain (read-only, migration path)

    private static func readLegacyKeychain(service: String, account: String) -> Data? {
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

    private static func deleteLegacyKeychain(service: String, account: String) {
        let del: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(del as CFDictionary)
    }

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

enum SecretError: Error {
    case dbUnavailable
    case sqlite(String)
}
