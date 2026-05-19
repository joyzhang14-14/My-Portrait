import Foundation
import Observation

/// Generates dynamic "Based on your activity" chips by asking the AI to
/// look at the user's recent screen activity and propose 4-6 short
/// follow-up questions. Spawns a fresh one-shot PiAgent each refresh so it
/// doesn't poison the active conversation.
@MainActor
@Observable
final class SuggestionEngine {
    static let shared = SuggestionEngine()

    enum State: Equatable {
        case idle, loading, ready, error(String)
    }

    private(set) var items: [String] = []
    private(set) var state: State = .idle
    private(set) var lastRefreshed: Date? = nil

    /// Override at app boot — supplies the same provider+model as the chat.
    var providerResolver: () -> (Provider, String, String?) = {
        (.chatgpt, Provider.chatgpt.defaultModel, nil)
    }

    private var inFlight: Task<Void, Never>?

    private init() {
        loadCached()
    }

    var isStale: Bool {
        guard let t = lastRefreshed else { return true }
        let raw = ConfigStore.shared.notifications.pipeSuggestionInterval
        let window = SuggestionInterval(rawValue: raw)?.seconds ?? (3 * 3600)
        return Date().timeIntervalSince(t) > window
    }

    /// Pull fresh suggestions. Cheap-fail: if Pi can't spawn / parse, we keep
    /// whatever we had.
    func refresh() {
        guard inFlight == nil else { return }
        guard AISetup.shared.isReady, ChatGPTOAuth.isLoggedIn() || hasAnyAPIKey() else { return }
        state = .loading
        inFlight = Task { [weak self] in
            await self?.run()
        }
    }

    private func hasAnyAPIKey() -> Bool {
        for p in Provider.allCases {
            if let key = p.secretKey, SecretStore.shared.get(key) != nil { return true }
        }
        return false
    }

    // MARK: - Run

    private func run() async {
        defer { inFlight = nil }

        // Build a small context from the last 30 minutes — enough to give the
        // model something to riff on without blowing token budgets.
        let context = await Task.detached(priority: .userInitiated) {
            ScreenpipeContextBuilder.build(
                chips: [ContextChip(spec: .lastMinutes(30))],
                maxChars: 6000
            )
        }.value

        let prompt: String
        if context.markdown.isEmpty {
            // Cold start (no screenpipe) — ask for generic productivity prompts.
            prompt = """
            Suggest 5 short prompts a user might type into an AI assistant \
            running on their Mac. Return ONLY a JSON array of 5 strings, no \
            prose, no markdown. Each string ≤ 60 chars.
            """
        } else {
            prompt = """
            \(context.markdown)

            Based ONLY on the screen activity above, suggest 5 short prompts \
            the user might want to ask. Return ONLY a JSON array of 5 \
            strings, no prose, no markdown. Each string ≤ 60 chars. Phrase \
            in lowercase casual English.
            """
        }

        let (provider, model, refOverride) = providerResolver()
        do {
            let agent = try PiAgent(provider: provider, model: model, apiKeyRefOverride: refOverride)
            try await agent.start()
            try agent.sendPrompt(prompt)

            var accumulated = ""
            iter: for await event in agent.events {
                switch event {
                case .textDelta(let d):              accumulated += d
                case .assistantFinalText(let t):     accumulated = t
                case .agentEnd:                      break iter
                case .error(let m):
                    state = .error(m)
                    agent.stop()
                    return
                default: break
                }
            }
            agent.stop()

            if let parsed = Self.parseStringArray(accumulated) {
                items = parsed
                lastRefreshed = Date()
                cache()
                state = .ready
            } else {
                state = .error("Couldn't parse suggestions")
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - JSON parse (lenient)

    /// Extract `[ "...", "..." ]` from possibly-fenced LLM output. We try
    /// strict JSON first; on failure, scrape the first array-of-strings
    /// shape we can find.
    static func parseStringArray(_ raw: String) -> [String]? {
        // Strip fenced code blocks if any.
        var s = raw
        if let r = s.range(of: "```", options: .literal) {
            s.removeSubrange(s.startIndex..<r.upperBound)
            // drop language line + leading newline if present
            if let nl = s.firstIndex(of: "\n") { s.removeSubrange(s.startIndex...nl) }
            if let r2 = s.range(of: "```", options: .literal) {
                s.removeSubrange(r2.lowerBound..<s.endIndex)
            }
        }
        // Find the first '[' through matching ']'.
        guard let lb = s.firstIndex(of: "["),
              let rb = s.lastIndex(of: "]"),
              lb < rb else { return nil }
        let slice = String(s[lb...rb])
        if let data = slice.data(using: .utf8),
           let arr = (try? JSONSerialization.jsonObject(with: data)) as? [String] {
            let cleaned = arr
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return cleaned.isEmpty ? nil : cleaned
        }
        return nil
    }

    // MARK: - Caching (UserDefaults)

    private let cacheKey = "MyPortrait.suggestions.v1"
    private let cacheStampKey = "MyPortrait.suggestions.v1.stamp"

    private func cache() {
        UserDefaults.standard.set(items, forKey: cacheKey)
        if let t = lastRefreshed {
            UserDefaults.standard.set(t.timeIntervalSince1970, forKey: cacheStampKey)
        }
    }

    private func loadCached() {
        if let arr = UserDefaults.standard.stringArray(forKey: cacheKey) {
            items = arr
            state = .ready
        }
        let stamp = UserDefaults.standard.double(forKey: cacheStampKey)
        if stamp > 0 { lastRefreshed = Date(timeIntervalSince1970: stamp) }
    }
}
