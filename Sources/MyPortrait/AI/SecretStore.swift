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

    /// Fetch the 32-byte AES master key from Keychain, generating + storing
    /// one if missing. If the key is found in the LEGACY keychain but not in
    /// the data-protection one, migrate it over so the per-build ACL prompts
    /// stop firing on subsequent launches.
    private static func loadOrCreateMasterKey(service: String, account: String) -> SymmetricKey {
        if let fromDP = read(service: service, account: account, useDataProtection: true),
           fromDP.count == 32 {
            return SymmetricKey(data: fromDP)
        }
        if let legacy = read(service: service, account: account, useDataProtection: false),
           legacy.count == 32 {
            writeKeychain(service: service, account: account, data: legacy)
            // Best-effort: drop the legacy copy so it stops triggering prompts.
            let del: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(del as CFDictionary)
            return SymmetricKey(data: legacy)
        }
        let new = SymmetricKey(size: .bits256)
        let data = new.withUnsafeBytes { Data($0) }
        writeKeychain(service: service, account: account, data: data)
        return new
    }

    /// Read first via the data-protection keychain (no per-app ACL prompts).
    /// Fall back to the legacy keychain so we can still find a master key
    /// written by an older build.
    private static func readKeychain(service: String, account: String) -> Data? {
        if let d = read(service: service, account: account, useDataProtection: true) { return d }
        return read(service: service, account: account, useDataProtection: false)
    }

    private static func read(service: String, account: String, useDataProtection: Bool) -> Data? {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if useDataProtection {
            q[kSecUseDataProtectionKeychain as String] = true
        }
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return data
    }

    /// Write into the data-protection keychain when possible. Items there are
    /// not gated by per-app ACL prompts that fire on every code-signature
    /// change — which is what was making every rebuild pop a "MyPortrait
    /// wants to access your keychain" dialog.
    private static func writeKeychain(service: String, account: String, data: Data) {
        // Delete from BOTH keychain backends to avoid duplicates / shadowing.
        for useDP in [true, false] {
            var del: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            if useDP { del[kSecUseDataProtectionKeychain as String] = true }
            SecItemDelete(del as CFDictionary)
        }

        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecUseDataProtectionKeychain as String: true
        ]
        var status = SecItemAdd(add as CFDictionary, nil)

        // Some self-signed dev builds can't use the data-protection keychain
        // (no entitlements). Fall back to the legacy one in that case.
        if status != errSecSuccess {
            add.removeValue(forKey: kSecUseDataProtectionKeychain as String)
            status = SecItemAdd(add as CFDictionary, nil)
        }
        _ = status
    }

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

enum SecretError: Error {
    case dbUnavailable
    case sqlite(String)
}
