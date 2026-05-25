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

/// Notion 走「Internal Integration Token」路径(不是 OAuth):用户去
/// https://notion.so/profile/integrations 新建 integration -> 拷 secret_xxx
/// token -> 粘进 Connections。原项目用 OAuth + 自己后端 proxy 转 client_secret,
/// My-Portrait 没那条后端,改这条更轻 + 不依赖外部基础设施。
///
/// 限制:integration token 只能访问用户**手动 share** 给 integration 的 page。
/// 这是 Notion 的设计,不是我们的限制。
enum NotionConfig {
    /// SecretStore key (一致跟 `apikey:openai` / `apikey:anthropic` 同一 prefix)。
    static let apiKeyRef = "apikey:notion"

    static var token: String? {
        guard let data = SecretStore.shared.get(apiKeyRef),
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    static func setToken(_ token: String) throws {
        try SecretStore.shared.set(apiKeyRef, value: Data(token.utf8))
    }

    static func deleteToken() {
        SecretStore.shared.delete(apiKeyRef)
    }
}

/// Extra Obsidian config that the `.localApp` probe doesn't capture — namely
/// the vault directory the user picked. Cron Jobs read this to know where the
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
