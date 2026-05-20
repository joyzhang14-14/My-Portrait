import Foundation

/// 云转录引擎。复刻 screenpipe 的 Deepgram + OpenAI 兼容两条路。
/// 上传无损 WAV（不做 MP3 压缩）。
enum CloudTranscriber {

    enum CloudError: Error, CustomStringConvertible {
        case missingConfig(String)
        case http(Int, String)
        case badResponse

        var description: String {
            switch self {
            case .missingConfig(let what): return "CloudTranscriber: missing \(what)"
            case .http(let code, let body): return "CloudTranscriber: HTTP \(code) — \(body)"
            case .badResponse: return "CloudTranscriber: unparseable response"
            }
        }
    }

    /// Deepgram：POST WAV 到 /v1/listen。
    static func deepgram(samples: [Float], apiKey: String, language: String?) async throws -> String {
        guard !apiKey.isEmpty else { throw CloudError.missingConfig("Deepgram API key") }
        var comps = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        var q = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "sample_rate", value: "16000"),
        ]
        if let language { q.append(URLQueryItem(name: "language", value: language)) }
        comps.queryItems = q

        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        req.httpBody = AudioWAV.encode(samples: samples)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkHTTP(resp, data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [String: Any],
              let channels = results["channels"] as? [[String: Any]],
              let alts = channels.first?["alternatives"] as? [[String: Any]],
              let transcript = alts.first?["transcript"] as? String
        else { throw CloudError.badResponse }
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// OpenAI 兼容：multipart POST 到 {endpoint}/v1/audio/transcriptions。
    /// 适配 mlx-audio、llama.cpp、vLLM 等任何 OpenAI 转录 API 格式的服务。
    static func openAICompatible(
        samples: [Float], endpoint: String, model: String,
        apiKey: String, language: String?, vocabulary: [String]
    ) async throws -> String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw CloudError.missingConfig("custom endpoint") }
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard let url = URL(string: "\(base)/v1/audio/transcriptions") else {
            throw CloudError.missingConfig("valid custom endpoint URL")
        }

        let boundary = "myportrait-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(contentsOf: "--\(boundary)\r\n".utf8)
            body.append(contentsOf: "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8)
            body.append(contentsOf: "\(value)\r\n".utf8)
        }
        field("model", model.isEmpty ? "whisper-1" : model)
        field("response_format", "json")
        if let language { field("language", language) }
        if !vocabulary.isEmpty {
            // OpenAI Whisper API 用 prompt 做 initial_prompt；mlx-audio 用 context。
            // 两个都发，谁认哪个都行。
            let prompt = vocabulary.joined(separator: ", ")
            field("prompt", prompt)
            field("context", prompt)
        }
        body.append(contentsOf: "--\(boundary)\r\n".utf8)
        body.append(contentsOf: "Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8)
        body.append(contentsOf: "Content-Type: audio/wav\r\n\r\n".utf8)
        body.append(AudioWAV.encode(samples: samples))
        body.append(contentsOf: "\r\n--\(boundary)--\r\n".utf8)
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkHTTP(resp, data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String
        else { throw CloudError.badResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func checkHTTP(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw CloudError.http(http.statusCode, body)
        }
    }
}
