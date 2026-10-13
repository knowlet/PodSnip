import Foundation

enum AIError: LocalizedError {
    case notConfigured
    case badURL
    case http(Int, String)
    case emptyResponse
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "請先在設定裡填入 AI Base URL、API Key 和模型。"
        case .badURL: return "Base URL 格式錯誤。"
        case .http(let code, let body): return "AI 請求失敗 HTTP \(code)：\(body.prefix(200))"
        case .emptyResponse: return "AI 回傳為空。"
        case .decode(let s): return "AI 回傳解析失敗：\(s.prefix(160))"
        }
    }
}

/// OpenAI-compatible chat client (OpenAI / Anthropic-compat / Gemini-compat / OpenRouter).
struct AIClient {
    let config: AIConfig

    func chat(system: String, user: String, jsonMode: Bool = false, maxTokens: Int = 4096) async throws -> String {
        guard config.isConfigured else { throw AIError.notConfigured }
        let base = config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) : config.baseURL
        guard let url = URL(string: base + "/chat/completions") else { throw AIError.badURL }

        var body: [String: Any] = [
            "model": config.model,
            "messages": [["role": "system", "content": system],
                         ["role": "user", "content": user]],
            "max_tokens": maxTokens,
            "temperature": 0.3,
        ]
        if jsonMode { body["response_format"] = ["type": "json_object"] }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 180
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AIError.http(-1, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw AIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        struct Choice: Decodable { struct Msg: Decodable { var content: String? }; var message: Msg }
        struct Reply: Decodable { var choices: [Choice] }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
              let text = reply.choices.first?.message.content, !text.isEmpty else {
            throw AIError.decode(String(data: data, encoding: .utf8) ?? "")
        }
        return text
    }

    func testConnection() async throws -> String {
        try await chat(system: "Reply with exactly: OK", user: "ping", maxTokens: 16)
    }
}
