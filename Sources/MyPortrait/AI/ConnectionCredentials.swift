import Foundation

/// SMTP credentials for the `email-smtp` integration. Stored as one encrypted
/// JSON blob in SecretStore — the password never lands in UserDefaults/TOML.
struct SMTPCredentials: Codable, Hashable {
    var host: String
    var port: String
    var username: String
    var password: String
    /// Address the verification test email is sent to. The `from` address is
    /// always `username`. Defaults to `username` (send-to-self) when blank.
    var testRecipient: String = ""

    /// SecretStore key for a given integration id (e.g. `smtp:email-smtp`).
    static func ref(for integrationId: String) -> String { "smtp:\(integrationId)" }
}

/// Extra Obsidian config that the `.localApp` probe doesn't capture — namely
/// the vault directory the user picked. Pipes read this to know where the
/// git repo lives.
enum ObsidianConfig {
    /// SecretStore key holding the absolute vault path (plain UTF-8).
    static let vaultPathRef = "obsidian:vault-path"

    static var vaultPath: String? {
        guard let data = SecretStore.shared.get(vaultPathRef),
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    static func setVaultPath(_ path: String) throws {
        try SecretStore.shared.set(vaultPathRef, value: Data(path.utf8))
    }
}
