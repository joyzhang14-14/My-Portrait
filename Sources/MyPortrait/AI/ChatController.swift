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
    private var assistantMessageID: UUID? = nil
    /// id of the trailing `.text` ContentPart that text_delta events should
    /// accumulate into. Reset every time a tool block lands.
    private var activeTextPartID: UUID? = nil

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
            // Prepare an empty assistant bubble we'll stream parts into.
            let placeholder = ChatMessage(role: .assistant, text: "", parts: [], time: Date())
            messages.append(placeholder)
            assistantMessageID = placeholder.id
            activeTextPartID = nil
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
            appendText(delta)
        case .assistantFinalText(let text):
            // Fallback: only used when no streaming happened.
            if currentTextLength() == 0 { appendText(text) }
        case .agentEnd:
            isStreaming = false
            assistantMessageID = nil
            activeTextPartID = nil
        case .error(let msg):
            lastError = msg
            appendText("⚠️ \(msg)")
            isStreaming = false
        case .toolStart(let id, let name, let args):
            startTool(callId: id, name: name, args: args)
        case .toolEnd(let id, let result, let isError):
            finishTool(callId: id, result: result, isError: isError)
        default:
            break
        }
    }

    // MARK: - Parts mutation

    private func appendText(_ delta: String) {
        guard let msgID = assistantMessageID,
              let mIdx = messages.firstIndex(where: { $0.id == msgID }) else { return }

        // If the trailing part is the active text part, append to it.
        // Otherwise create a new text part — happens after a tool block.
        if let activeID = activeTextPartID,
           let pIdx = messages[mIdx].parts.lastIndex(where: { $0.id == activeID }),
           case .text(let id, let value) = messages[mIdx].parts[pIdx] {
            messages[mIdx].parts[pIdx] = .text(id: id, value: value + delta)
        } else {
            let newID = UUID()
            messages[mIdx].parts.append(.text(id: newID, value: delta))
            activeTextPartID = newID
        }
        // Keep `text` mirror in sync — used for things like Recents preview.
        messages[mIdx].text = messages[mIdx].parts.compactMap {
            if case .text(_, let v) = $0 { return v } else { return nil }
        }.joined(separator: "\n\n")
    }

    private func currentTextLength() -> Int {
        guard let msgID = assistantMessageID,
              let m = messages.first(where: { $0.id == msgID }) else { return 0 }
        return m.parts.reduce(0) { acc, part in
            if case .text(_, let v) = part { return acc + v.count }
            return acc
        }
    }

    private func startTool(callId: String, name: String, args: [String: Any]) {
        guard let msgID = assistantMessageID,
              let mIdx = messages.firstIndex(where: { $0.id == msgID }) else { return }
        let block = ToolBlock(
            id: UUID(),
            toolCallId: callId,
            name: name,
            command: Self.summarizeArgs(name: name, args: args),
            output: "",
            isRunning: true,
            isError: false
        )
        messages[mIdx].parts.append(.tool(block))
        // Next text_delta should start a fresh text part below the tool.
        activeTextPartID = nil
    }

    private func finishTool(callId: String, result: String, isError: Bool) {
        guard let msgID = assistantMessageID,
              let mIdx = messages.firstIndex(where: { $0.id == msgID }) else { return }
        // Find the matching running block (latest one for this callId).
        for pIdx in messages[mIdx].parts.indices.reversed() {
            if case .tool(var b) = messages[mIdx].parts[pIdx], b.toolCallId == callId {
                b.output = result
                b.isRunning = false
                b.isError = isError
                messages[mIdx].parts[pIdx] = .tool(b)
                return
            }
        }
    }

    /// Build a short human-readable summary of a tool's args. For bash that's
    /// the command itself; for everything else we just JSON-encode.
    private static func summarizeArgs(name: String, args: [String: Any]) -> String {
        if name == "bash", let cmd = args["command"] as? String { return cmd }
        if name == "read", let path = args["path"] as? String { return path }
        if let json = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]),
           let s = String(data: json, encoding: .utf8) {
            return s
        }
        return ""
    }
}

