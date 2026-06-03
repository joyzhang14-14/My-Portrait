import Foundation

/// LLM pipeline 失败原因的二分类系统。MemoryScheduler.runStep 的 catch block
/// 把 raw Swift Error 喂给 `ErrorClassifier.classify(_:)`,得到一个 LLMFailureKind,
/// 写进 ProcessingLog.checkpoint(JSON 序列化),供后续 NeedAttention UI / 通知
/// 决定:
///   - 桶 A(`isUserRequired=false`)→ scheduler 自动按 backoff 重试,UI 安静
///     提示"auto-recovering",通知里说"retrying in Xh"
///   - 桶 B(`isUserRequired=true`)→ NeedAttention 行加红 banner + "Problem
///     solved" 按钮,通知里写"action required: <reason>"。用户点 Problem
///     solved 才清 retry_count → 立即重试;不点的话仍按 backoff cap 24h 自动试
///
/// 设计原则:
///   - 永不放弃 —— commit 1 删了 dead_letter,所有失败都会重试,只是频率受
///     backoff 控制
///   - 不跨 provider 切 —— repair / fallback 只在用户当前 parameter 配的 provider
///     里完成
///   - 分类规则**保守**:不确定就归 .unknownTransient(默认桶 A,继续重试),
///     宁可吵一点也不要假装"已修复"骗用户

enum LLMFailureKind: Sendable, Codable, Equatable {
    // ─── 桶 A — auto-recovering(不需要用户介入) ───
    /// 网络层瞬态:DNS / TLS handshake / connection reset / socket timeout。
    /// 网回来就好。
    case transientNetwork(reason: String)
    /// 429 / overloaded / provider 限流,通常有 Retry-After。
    case rateLimitThrottle(retryAfterMs: Int64?)
    /// SSE 中途断 / stopReason=length 截断 / pi 子进程异常退。重跑可能 OK。
    case streamTruncated(reason: String)
    /// 单 prompt 超模型 ctx。pipeline 内可能要 chunking,但先按 transient 重试
    /// (有时是数据日异常大)。
    case contextOverflow(reason: String)
    /// SQLITE_BUSY / IOERR 短暂性 — busyTimeout + 退避就过。
    case dbBusy
    /// JSON 解析失败 / schema 不匹配 / 模型 refusal。LLMJSON 的 repair pass
    /// 会先试一次,仍失败才到这。
    case schemaViolation(reason: String)
    /// 没分到具体类的瞬态错。fallback 桶,默认重试。
    case unknownTransient(reason: String)

    // ─── 桶 B — user-required(NeedAttention 加 Problem solved 按钮) ───
    /// 真额度用完(billing 欠费 / 月度 quota 烧光)。需要用户充值 / 升级 tier
    /// 后点 Problem solved。
    case quotaExhausted(provider: String, reason: String)
    /// 401 / API key 失效 / OAuth refresh 失败 / 账户被 banned。用户得
    /// Settings → Connections 重新连。
    case authRevoked(provider: String, reason: String)
    /// 404 model not found / 模型被供应商下线。用户得 Settings → AI models 换。
    case modelDeprecated(model: String, reason: String)
    /// SQLITE_CORRUPT / DB 文件被外部改坏。用户确认后才走 quarantine + 重建
    /// (可能花几小时 LLM token)。
    case dbCorrupt(reason: String)
    /// pi-coding-agent / claude CLI 自身没装好 / 找不到 / 跑不起来。
    /// 用户需要重装 AI runtime。
    case agentSpawnFailed(reason: String)

    /// 桶 B 的统一判定。
    var isUserRequired: Bool {
        switch self {
        case .quotaExhausted, .authRevoked, .modelDeprecated, .dbCorrupt, .agentSpawnFailed:
            return true
        default: return false
        }
    }

    /// 给 NeedAttention banner / 通知用的英文短句(用户视角,不带 stack)。
    var userMessage: String {
        switch self {
        case .transientNetwork(let r):    return "Network hiccup (\(r))"
        case .rateLimitThrottle(let ms):
            if let ms { return "Rate-limited (retry after \(ms / 1000)s)" }
            return "Rate-limited"
        case .streamTruncated(let r):     return "Response cut off (\(r))"
        case .contextOverflow(let r):     return "Prompt too long for model context (\(r))"
        case .dbBusy:                     return "Local DB busy"
        case .schemaViolation(let r):     return "Model output couldn't be parsed (\(r))"
        case .unknownTransient(let r):    return "Transient error (\(r))"
        case .quotaExhausted(let p, _):   return "Provider quota exhausted — top up \(p) and click Problem solved"
        case .authRevoked(let p, _):      return "Auth failed — reconnect \(p) in Settings → Connections"
        case .modelDeprecated(let m, _):  return "Model \(m) unavailable — pick another in Settings → AI models"
        case .dbCorrupt:                  return "Local DB looks corrupt — click Problem solved to quarantine + rebuild"
        case .agentSpawnFailed(let r):    return "AI runtime didn't start (\(r)) — re-install from Settings → AI"
        }
    }

    /// 简短分类标签,用在 attention row 的角标 / 通知 emoji。
    var shortLabel: String {
        switch self {
        case .transientNetwork:           return "network"
        case .rateLimitThrottle:          return "rate-limit"
        case .streamTruncated:            return "truncated"
        case .contextOverflow:            return "ctx-overflow"
        case .dbBusy:                     return "db-busy"
        case .schemaViolation:            return "schema"
        case .unknownTransient:           return "transient"
        case .quotaExhausted:             return "quota"
        case .authRevoked:                return "auth"
        case .modelDeprecated:            return "model-gone"
        case .dbCorrupt:                  return "db-corrupt"
        case .agentSpawnFailed:           return "spawn"
        }
    }
}

enum ErrorClassifier {

    /// 把任意 Swift Error 翻成 LLMFailureKind。**保守** —— 没匹配上 user-required
    /// 模式时一律 .unknownTransient,宁可吵一点也别假装"已修复"骗用户。
    static func classify(_ error: Error) -> LLMFailureKind {
        // 1. Budget signal:已有 BudgetExhaustedError(MemoryScheduler 也在外面单独
        //    catch 一次走 budget_deferred 分支,这里走到说明走到通用 catch 了)。
        if let be = error as? BudgetExhaustedError {
            let msg = be.message.lowercased()
            // billing / 永久 quota → 桶 B
            if msg.contains("billing") || msg.contains("insufficient_quota") || msg.contains("usage limit") {
                return .quotaExhausted(provider: be.processor, reason: be.message)
            }
            // 429 / rate limit → 桶 A(transient)。Retry-After 暂未透传,留 nil。
            return .rateLimitThrottle(retryAfterMs: nil)
        }

        // 2. URLError(networking 层)
        if let ue = error as? URLError {
            switch ue.code {
            case .notConnectedToInternet, .networkConnectionLost, .dnsLookupFailed,
                 .cannotConnectToHost, .cannotFindHost, .timedOut:
                return .transientNetwork(reason: "\(ue.code.rawValue) \(ue.localizedDescription)")
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .clientCertificateRejected:
                // TLS issues 多是环境问题(代理 / 证书),但归 transient — 用户可能没法
                // 立刻修,scheduler 继续 backoff 就行。
                return .transientNetwork(reason: "TLS error \(ue.code.rawValue)")
            case .userAuthenticationRequired:
                return .authRevoked(provider: "url-session", reason: ue.localizedDescription)
            default:
                return .transientNetwork(reason: "URLError \(ue.code.rawValue)")
            }
        }

        // 3. localizedDescription 模式匹配(pi-coding-agent stderr / NSError messages)
        let msg = error.localizedDescription.lowercased()

        // ── 桶 B 匹配优先(用户必须知道) ──
        // billing / 永久 quota
        if msg.contains("billing") || msg.contains("insufficient_quota")
            || msg.contains("usage limit") || msg.contains("payment required") {
            let provider = extractProvider(from: msg) ?? "provider"
            return .quotaExhausted(provider: provider, reason: error.localizedDescription)
        }
        // 401 / auth
        if msg.contains("401") || msg.contains("unauthorized") || msg.contains("invalid api key")
            || msg.contains("api key not found") || msg.contains("authentication") {
            let provider = extractProvider(from: msg) ?? "provider"
            return .authRevoked(provider: provider, reason: error.localizedDescription)
        }
        // 404 model not found
        if (msg.contains("404") && (msg.contains("model") || msg.contains("does not exist")))
            || msg.contains("model_not_found")
            || msg.contains("model not found")
            || msg.contains("the model") && msg.contains("does not exist") {
            return .modelDeprecated(model: extractModel(from: msg) ?? "?", reason: error.localizedDescription)
        }
        // SQLite corruption
        if msg.contains("database disk image is malformed") || msg.contains("sqlite_corrupt") {
            return .dbCorrupt(reason: error.localizedDescription)
        }
        // agent spawn failures
        if msg.contains("enoent") || msg.contains("no such file") || msg.contains("command not found")
            || msg.contains("posix_spawn") || msg.contains("eaccess") {
            return .agentSpawnFailed(reason: error.localizedDescription)
        }

        // ── 桶 A 匹配 ──
        if msg.contains("429") || msg.contains("rate limit") || msg.contains("ratelimit")
            || msg.contains("too many requests") || msg.contains("overloaded") {
            return .rateLimitThrottle(retryAfterMs: nil)
        }
        if msg.contains("ecconnreset") || msg.contains("econnreset") || msg.contains("connection reset")
            || msg.contains("socket hang up") || msg.contains("etimedout") || msg.contains("getaddrinfo")
            || msg.contains("enotfound") || msg.contains("network") {
            return .transientNetwork(reason: error.localizedDescription)
        }
        if msg.contains("context_length") || msg.contains("context length")
            || msg.contains("token limit") || msg.contains("maximum context") {
            return .contextOverflow(reason: error.localizedDescription)
        }
        if msg.contains("stoppedreason: length") || msg.contains("stop_reason\": \"length")
            || msg.contains("output truncated") || msg.contains("incomplete response") {
            return .streamTruncated(reason: error.localizedDescription)
        }
        if msg.contains("sqlite_busy") || msg.contains("database is locked") {
            return .dbBusy
        }
        if msg.contains("decoding") || msg.contains("decoder") || msg.contains("not a json")
            || msg.contains("invalid json") || msg.contains("could not parse") {
            return .schemaViolation(reason: error.localizedDescription)
        }

        // 4. fallback
        return .unknownTransient(reason: error.localizedDescription)
    }

    // MARK: - Provider/model 字符串提取(尽力,失败 nil)

    private static func extractProvider(from msg: String) -> String? {
        // 给 quotaExhausted/authRevoked 的 user-facing 字符串提供具体 provider 名。
        let knowns = ["openai", "anthropic", "deepseek", "chatgpt", "claude"]
        for k in knowns where msg.contains(k) {
            return k.capitalized
        }
        return nil
    }

    private static func extractModel(from msg: String) -> String? {
        // 找 "model X does not exist" / "model_not_found: X" 中的 X。粗糙但够用。
        let patterns = [
            #"the model `([^`]+)`"#,
            #"model[: ]+`?([\w\-.]+)`?"#,
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p),
               let m = re.firstMatch(in: msg, range: NSRange(msg.startIndex..., in: msg)),
               let r = Range(m.range(at: 1), in: msg) {
                return String(msg[r])
            }
        }
        return nil
    }
}
