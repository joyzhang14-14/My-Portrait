import Foundation

/// One-shot LLM call that proposes a short label for each unidentified
/// voice cluster. Reads sample transcripts from the timeline DB, batches
/// them into a single prompt, spawns a throwaway PiAgent, asks for JSON
/// back, and surfaces a `(speakerId → label)` map.
///
/// Pure read on the DB side — the caller decides whether to write back
/// (today the speakers table is read-only from `TimelineDB`, so the names
/// are surfaced into the SwiftUI state only).
@MainActor
enum SpeakerOrganizer {

    struct Proposal: Sendable {
        let speakerId: String   // string-ified Int64
        let label: String       // "" when the model couldn't tell
    }

    enum OrganizeError: LocalizedError {
        case noUnidentified
        case noProvider
        case agentFailed(String)
        case noJSON
        var errorDescription: String? {
            switch self {
            case .noUnidentified: return "Nothing to organize."
            case .noProvider:     return "No AI provider configured."
            case .agentFailed(let m): return "AI agent error: \(m)"
            case .noJSON:         return "Couldn't parse the AI's response."
            }
        }
    }

    /// `unidentifiedIds` is the list of `speakers.id` (as strings) we want
    /// labels for. Returns one Proposal per id; missing ids → label "".
    static func run(unidentifiedIds: [String]) async throws -> [Proposal] {
        guard !unidentifiedIds.isEmpty else { throw OrganizeError.noUnidentified }

        // 1. Resolve provider from the default preset (same as chat).
        let pres = ConfigStore.shared.aiModels.presets.first(where: { $0.isDefault })
        let provider: Provider
        let model: String
        let refOverride: String?
        if let p = pres, let prov = Provider(rawValue: p.provider) {
            provider = prov
            model = p.model
            refOverride = p.apiKeyRef.isEmpty ? nil : p.apiKeyRef
        } else {
            throw OrganizeError.noProvider
        }

        // 2. Collect samples per speaker off the main actor (SQLite reads).
        let samples = await Task.detached(priority: .userInitiated) {
            unidentifiedIds.compactMap { sid -> (String, [String])? in
                guard let id64 = Int64(sid) else { return nil }
                let transcripts = TimelineDB().sampleTranscripts(forSpeakerId: id64, limit: 4)
                return (sid, transcripts)
            }
        }.value

        // 3. Build a single prompt asking for JSON back.
        var promptLines: [String] = [
            "You will receive several speaker clusters with example transcripts.",
            "For each cluster, propose a short label (1–3 words) describing the speaker — a role, relationship, or topic they discuss (e.g. \"Coworker\", \"Mom\", \"Project Manager\").",
            "If a cluster has no usable signal, return an empty string for that id.",
            "Respond with JSON only, no prose:",
            "[{\"id\":\"<cluster id>\",\"label\":\"<short label>\"}]",
            "",
            "Clusters:"
        ]
        for (sid, transcripts) in samples {
            promptLines.append("- id: \(sid)")
            if transcripts.isEmpty {
                promptLines.append("  (no transcripts)")
            } else {
                for t in transcripts.prefix(3) {
                    let line = t.replacingOccurrences(of: "\n", with: " ").prefix(180)
                    promptLines.append("  • \(line)")
                }
            }
        }
        let prompt = promptLines.joined(separator: "\n")

        // 4. One-shot PiAgent call. Accumulate text deltas until agentEnd.
        let buffer: String
        do {
            let agent = try PiAgent(provider: provider, model: model, apiKeyRefOverride: refOverride)
            try await agent.start()
            try agent.sendPrompt(prompt)
            var acc = ""
            iter: for await event in agent.events {
                switch event {
                case .textDelta(let d):          acc += d
                case .assistantFinalText(let t): if acc.isEmpty { acc = t }
                case .agentEnd:                  break iter
                case .error(let m):              throw OrganizeError.agentFailed(m)
                default: break
                }
            }
            agent.stop()
            buffer = acc
        } catch let e as OrganizeError {
            throw e
        } catch {
            throw OrganizeError.agentFailed(error.localizedDescription)
        }

        // 5. Extract the first JSON array from the buffer (LLMs sometimes
        //    wrap it in code fences). Naive but works in practice.
        guard let start = buffer.firstIndex(of: "["),
              let end   = buffer.lastIndex(of: "]"),
              end > start else {
            throw OrganizeError.noJSON
        }
        let jsonSlice = String(buffer[start...end])
        guard let data = jsonSlice.data(using: .utf8),
              let arr  = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw OrganizeError.noJSON
        }

        // 6. Map → Proposals; fill in missing ids with "".
        var byId: [String: String] = [:]
        for obj in arr {
            if let id = obj["id"] as? String,
               let label = obj["label"] as? String {
                byId[id] = label.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let idNum = obj["id"] as? NSNumber,
                      let label = obj["label"] as? String {
                byId[idNum.stringValue] = label.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return unidentifiedIds.map { Proposal(speakerId: $0, label: byId[$0] ?? "") }
    }
}
