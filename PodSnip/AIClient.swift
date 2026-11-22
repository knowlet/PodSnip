import Foundation

enum AIError: LocalizedError {
    case notConfigured
    case badURL
    case http(Int, String)
    case emptyResponse
    case decode(String)

    /// User-facing text. The associated HTTP/decode payloads stay on the error
    /// for transport diagnostics and are never copied into this string.
    var safeDescription: String {
        switch self {
        case .notConfigured: return "請先在設定裡填入 AI Base URL、API Key 和模型。"
        case .badURL: return "Base URL 格式錯誤。"
        case .http(let code, _): return "AI 請求失敗 HTTP \(code)。"
        case .emptyResponse: return "AI 回傳為空。"
        case .decode: return "AI 回傳解析失敗。"
        }
    }

    var errorDescription: String? { safeDescription }
}

/// Messages that can be stored on a Snip or placed in share text.
enum UserFacingAIError {
    static func message(for error: Error) -> String {
        if let ai = error as? AIError { return ai.safeDescription }
        if error is AIServiceError { return error.localizedDescription }
        return "AI 筆記失敗。"
    }

    static func saveFailure() -> String { "AI 筆記儲存失敗。" }

    /// Share text is limited to messages this app generates. A stored provider
    /// body, including an older `HTTP n：<raw body>` string, becomes a fixed line.
    static func shareLine(stored: String?) -> String {
        guard let stored else { return "" }
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard isSafeSummary(trimmed) else { return "AI 筆記失敗。" }
        return "AI 筆記失敗：\(trimmed)"
    }

    private static func isSafeSummary(_ text: String) -> Bool {
        if text.contains("{") || text.contains("}") || text.contains("<") || text.contains(">") { return false }
        if text.localizedCaseInsensitiveContains("bearer ") || text.contains("sk-") { return false }
        let range = NSRange(text.startIndex..., in: text)
        return safePatterns.contains { $0.firstMatch(in: text, options: [], range: range) != nil }
    }

    private static let safePatterns: [NSRegularExpression] = [
        #"^請先在設定裡填入 AI Base URL、API Key 和模型。$"#,
        #"^Base URL 格式錯誤。$"#,
        #"^AI 請求失敗 HTTP \d+。$"#,
        #"^AI 回傳為空。$"#,
        #"^AI 回傳解析失敗。$"#,
        #"^AI 暫不可用：.+$"#,
        #"^AI 上下文超出限制：.+$"#,
        #"^AI 輸出格式錯誤：.+$"#,
        #"^Apple 雲端配額已達上限：.+$"#,
        #"^Apple 雲端網路失敗：.+$"#,
        #"^Apple 雲端服務暫不可用：.+$"#,
        #"^AI 筆記儲存失敗。$"#,
        #"^儲存失敗。$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }
}

/// OpenAI-compatible chat client (OpenAI / Anthropic-compat / Gemini-compat / OpenRouter).
struct AIClient: AIProvider {
    let config: AIConfig
    private let session: URLSession
    init(config: AIConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }
    var route: AIRoute { .byok }
    var availability: AIAvailability {
        AIAvailability(isAvailable: config.isConfigured, reason: config.isConfigured ? "端點設定完整；連線及模型支援待測試" : "請填入有效的 Base URL、Key、模型")
    }

    func text(_ request: AIRequest) async throws -> String {
        try await chat(system: request.system, user: request.user, maxTokens: request.maximumOutputTokens)
    }
    func structured(_ request: AIRequest, kind: AIOutputKind) async throws -> Data {
        // JSON object mode is a transport request, not schema enforcement. The
        // service decodes and validates the same Codable shapes as Apple output.
        let result = try await chat(system: request.system, user: request.user, jsonMode: true, maxTokens: request.maximumOutputTokens)
        return Data(result.utf8)
    }

    private func chat(system: String, user: String, jsonMode: Bool = false, maxTokens: Int = 4096) async throws -> String {
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

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AIError.http(-1, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw AIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        struct Choice: Decodable {
            struct Msg: Decodable { var content: String? }
            var message: Msg
            var finish_reason: String?
        }
        struct Reply: Decodable { var choices: [Choice] }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
              let choice = reply.choices.first,
              let text = choice.message.content, !text.isEmpty else {
            throw AIError.decode(String(data: data, encoding: .utf8) ?? "")
        }
        if choice.finish_reason == "length" { throw AIServiceError.context("供應商達到輸出上限；未儲存不完整回應") }
        if let reason = choice.finish_reason, reason != "stop" {
            throw AIServiceError.malformed("供應商未完成文字回應（\(reason)）")
        }
        return text
    }

}
