import Foundation
import Observation

/// One-conversation chat session. Owns a `PiAgent` for the lifetime of the
/// conversation, appends/streams into `messages`, and exposes a single
/// `send(_:)` entrypoint the UI wires to its input bar.
///
/// This is a deliberately small surface so we can iterate the wire-up
/// without touching HomeView every time.
@MainActor
@Observable
final class ChatController {
    var messages: [ChatMessage] = []
    var isStreaming: Bool = false
    var lastError: String? = nil

    private var agent: PiAgent?
    private var assistantBuffer: String = ""
    private var assistantMessageID: UUID? = nil

    private let model: String

    init(model: String = "gpt-5.4") { self.model = model }

    /// Send a user prompt. Spawns the Pi agent on first call.
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard AISetup.shared.isReady else {
            lastError = "Setup not finished — Bun/Pi still installing."
            return
        }
        guard ChatGPTOAuth.isLoggedIn() else {
            lastError = "Sign in to ChatGPT from Connections first."
            return
        }

        messages.append(.init(role: .user, text: trimmed, time: Date()))
        lastError = nil

        Task { await deliver(trimmed) }
    }

    /// Tear down the Pi process when the user closes the conversation.
    func close() {
        agent?.stop()
        agent = nil
    }

    // MARK: - Internals

    private func deliver(_ text: String) async {
        do {
            try await ensureAgent()
            try agent?.sendPrompt(text)
            isStreaming = true
            // Prepare an empty assistant bubble we'll stream tokens into.
            let placeholder = ChatMessage(role: .assistant, text: "", time: Date())
            messages.append(placeholder)
            assistantMessageID = placeholder.id
            assistantBuffer = ""
        } catch {
            lastError = error.localizedDescription
            isStreaming = false
        }
    }

    private func ensureAgent() async throws {
        if agent != nil { return }
        let a = try PiAgent(model: model)
        try await a.start()
        agent = a
        // Spawn a long-lived consumer for this agent's event stream.
        Task { [weak self] in
            guard let stream = self?.agent?.events else { return }
            for await event in stream { await self?.handle(event) }
        }
    }

    private func handle(_ event: PiAgent.Event) async {
        switch event {
        case .textDelta(let delta):
            assistantBuffer += delta
            updateAssistantText(assistantBuffer)
        case .agentEnd:
            isStreaming = false
            assistantMessageID = nil
            assistantBuffer = ""
        case .error(let msg):
            lastError = msg
            isStreaming = false
        case .toolStart(_, let name, _):
            // Inline a one-line marker so the user sees activity until we build
            // a proper tool block. Will be replaced when toolEnd arrives.
            appendInlineSystem("⏳ \(name)…")
        case .toolEnd(_, let result, let isError):
            let prefix = isError ? "❌" : "✅"
            replaceLastSystemInline(with: "\(prefix) \(result.prefix(200))")
        default:
            break
        }
    }

    private func updateAssistantText(_ text: String) {
        guard let id = assistantMessageID,
              let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].text = text
    }

    private func appendInlineSystem(_ text: String) {
        // Reuse the assistant bubble: append a markdown-ish marker on its own line.
        guard !assistantBuffer.isEmpty else {
            assistantBuffer = text
            return
        }
        assistantBuffer += "\n\n" + text
        updateAssistantText(assistantBuffer)
    }

    private func replaceLastSystemInline(with text: String) {
        // Replace the last "⏳ …" line if present, else just append.
        var lines = assistantBuffer.split(separator: "\n", omittingEmptySubsequences: false)
        if let lastIdx = lines.lastIndex(where: { $0.hasPrefix("⏳") }) {
            lines[lastIdx] = Substring(text)
            assistantBuffer = lines.joined(separator: "\n")
        } else {
            assistantBuffer += "\n" + text
        }
        updateAssistantText(assistantBuffer)
    }
}

