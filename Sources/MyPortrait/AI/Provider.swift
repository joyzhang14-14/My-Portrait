import Foundation

/// One AI provider Pi can talk to. Translates the user-facing tile
/// (`Integration.id`) into Pi's wire-protocol name + a default model.
///
/// The credential each one needs:
///   - .chatgpt     : OAuth token via ChatGPTOAuth (already implemented)
///   - .openaiBYOK  : API key stored in SecretStore under "apikey:openai"
///   - .anthropic   : API key stored in SecretStore under "apikey:anthropic"
///   - .ollama      : nothing — assumes a running localhost:11434
///   - .gemini      : API key stored in SecretStore under "apikey:gemini"
enum Provider: String, CaseIterable, Identifiable, Hashable {
    case chatgpt
    case openaiBYOK = "openai"
    case anthropic
    case ollama
    case gemini
    case perplexity
    /// Claude Code CLI(`claude` 二进制)—— 不走 Pi,用 ClaudeCodeAgent
    /// spawn 子进程,凭用户的 Pro/Max 订阅(`claude login`)用额度。
    case claudeCode = "claude-code"

    var id: String { rawValue }

    /// Map from `Integration.id` (the Connections tile identifier).
    static func from(integrationId: String) -> Provider? {
        switch integrationId {
        case "chatgpt":       return .chatgpt
        case "openai-byok":   return .openaiBYOK
        case "anthropic-api": return .anthropic
        case "gemini":        return .gemini
        case "ollama":        return .ollama
        case "perplexity":    return .perplexity
        case "claude-code":   return .claudeCode
        default:              return nil
        }
    }

    /// Pi 0.60+ `--provider` CLI value。Pi 0.60 起 provider 是内置 catalog
    /// (`@mariozechner/pi-ai/dist/models.generated.js`),老的 models.json
    /// 自定义命名(openai-chatgpt / anthropic-byok 等)已经废弃。
    /// claudeCode 不走 Pi,返回空串占位。
    var piName: String {
        switch self {
        case .chatgpt:        return "openai-codex"  // ChatGPT Plus/Pro OAuth
        case .openaiBYOK:     return "openai"        // 纯 OpenAI API key
        case .anthropic:      return "anthropic"
        case .ollama:         return "ollama"        // ⚠️ Pi 0.60 不内置,需 models.json 自定义
        case .gemini:         return "google"        // Pi 把 GEMINI_API_KEY 映射到 google
        case .perplexity:     return "perplexity"    // ⚠️ Pi 0.60 不内置
        case .claudeCode:     return ""              // 不走 Pi
        }
    }

    /// Default model id for the provider. User can override later via picker.
    var defaultModel: String { availableModels.first ?? "" }

    /// Models the picker offers per provider. First one is the default.
    /// Curated rather than fetched live — keeps the picker snappy and works
    /// offline. User can still type custom strings via the "other…" field.
    var availableModels: [String] {
        switch self {
        case .chatgpt:    return ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex", "gpt-5.2"]
        case .openaiBYOK: return ["gpt-4o", "gpt-4o-mini", "o1", "o3-mini", "gpt-4-turbo"]
        case .anthropic:  return ["claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5"]
        case .ollama:     return ["qwen2.5:14b-instruct", "llama3.2", "mistral", "deepseek-coder"]
        case .gemini:     return ["gemini-2.0-flash-exp", "gemini-1.5-pro", "gemini-1.5-flash"]
        case .perplexity: return ["sonar-pro", "sonar", "sonar-reasoning-pro", "sonar-reasoning", "sonar-deep-research"]
        // claude CLI 接受 alias(sonnet/opus/haiku 自动取最新)或完整 model id。
        case .claudeCode: return ["sonnet", "opus", "haiku"]
        }
    }

    /// Pi wire API for this provider. See pi-coding-agent's models.json schema.
    var wireApi: String {
        switch self {
        case .chatgpt:        return "openai-codex-responses"
        case .anthropic:      return "anthropic-messages"
        default:              return "openai-completions"
        }
    }

    var baseURL: String {
        switch self {
        case .chatgpt:        return "https://chatgpt.com/backend-api"
        case .openaiBYOK:     return "https://api.openai.com/v1"
        case .anthropic:      return "https://api.anthropic.com"
        case .ollama:         return "http://localhost:11434/v1"
        case .gemini:         return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .perplexity:     return "https://api.perplexity.ai"
        case .claudeCode:     return ""              // CLI 自己管理
        }
    }

    /// Env-var name Pi reads the credential from at runtime.
    var apiKeyEnv: String {
        switch self {
        case .chatgpt:        return "OPENAI_CHATGPT_TOKEN"
        case .openaiBYOK:     return "OPENAI_API_KEY"
        case .anthropic:      return "ANTHROPIC_API_KEY"
        case .ollama:         return ""         // none
        case .gemini:         return "GEMINI_API_KEY"
        case .perplexity:     return "PERPLEXITY_API_KEY"
        case .claudeCode:     return ""         // none (CLI 走 `claude login`)
        }
    }

    /// SecretStore key for the BYOK API key (if any).
    var secretKey: String? {
        switch self {
        case .anthropic:      return "apikey:anthropic"
        case .openaiBYOK:     return "apikey:openai"
        case .gemini:         return "apikey:gemini"
        case .perplexity:     return "apikey:perplexity"
        case .chatgpt, .ollama, .claudeCode: return nil
        }
    }

    /// 走 Pi 的 provider 才出现在 PiInstaller 的 models.json,claudeCode 跳过。
    var usesPi: Bool { self != .claudeCode }

    /// Whether this provider needs no setup beyond detection.
    var isLocal: Bool { self == .ollama || self == .claudeCode }

    /// Connections / AI Models 里对应的 Integration.id。跟
    /// `from(integrationId:)` 互为反函数。
    var integrationId: String {
        switch self {
        case .chatgpt:    return "chatgpt"
        case .openaiBYOK: return "openai-byok"
        case .anthropic:  return "anthropic-api"
        case .gemini:     return "gemini"
        case .ollama:     return "ollama"
        case .perplexity: return "perplexity"
        case .claudeCode: return "claude-code"
        }
    }

    /// 给用户看的展示名 —— 用在错误文案里(避免 "Codex not signed in"
    /// 一刀切到所有 provider)。跟 Connections 里的 tile 名保持一致。
    var displayName: String {
        switch self {
        case .chatgpt:    return "Codex"
        case .openaiBYOK: return "OpenAI API"
        case .anthropic:  return "Anthropic API"
        case .ollama:     return "Ollama"
        case .gemini:     return "Gemini"
        case .perplexity: return "Perplexity"
        case .claudeCode: return "Claude Code"
        }
    }
}

/// Helper that resolves the credential (token / API key) for a provider.
enum ProviderAuth {
    /// Returns the value to set in Pi's env at spawn time. Throws if missing.
    static func resolveEnvValue(for provider: Provider) async throws -> String {
        switch provider {
        case .chatgpt:
            return try await ChatGPTOAuth.validToken()
        case .ollama:
            return ""   // ignored
        default:
            guard let key = provider.secretKey,
                  let data = SecretStore.shared.get(key),
                  let s = String(data: data, encoding: .utf8), !s.isEmpty else {
                throw PiAgent.SpawnError.missingToken(provider: provider.displayName)
            }
            return s
        }
    }
}
