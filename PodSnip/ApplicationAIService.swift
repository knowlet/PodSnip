import Foundation

/// The application boundary for every AI operation. Configuration is copied once
/// at invocation; changing Settings cannot change provider mid-pipeline.
struct ApplicationAIService {
    let config: AIConfig
    private let provider: any AIProvider
    var route: AIRoute { config.route }
    var capabilities: AICapabilities { .forRoute(route) }
    var transcriptByteBudget: Int { capabilities.inputByteBudget - 640 }
    var availability: AIAvailability {
        guard AIRoute(rawValue: config.routeRaw) != nil else {
            return AIAvailability(isAvailable: false, reason: "未知 AI 來源；請在設定重新選擇，不會改送其他供應商")
        }
        guard provider.route == route else { return AIAvailability(isAvailable: false, reason: "Provider 與選定來源不一致") }
        return provider.availability
    }

    init(config: AIConfig, provider: (any AIProvider)? = nil) {
        self.config = config
        self.provider = provider ?? Self.makeProvider(config)
    }
    init(config: AIConfig, providerFactory: (AIConfig) -> any AIProvider) {
        self.config = config
        self.provider = providerFactory(config)
    }
    private static func makeProvider(_ config: AIConfig) -> any AIProvider {
        switch config.route {
        case .byok: return AIClient(config: config)
        case .onDevice, .appleCloud: return AppleAIProvider(route: config.route)
        }
    }

    private func request(_ operation: AIOperation, _ prompt: (String, String)) throws -> AIRequest {
        let state = availability
        guard state.isAvailable else { throw AIServiceError.unavailable(state.reason) }
        guard prompt.0.utf8.count + prompt.1.utf8.count <= capabilities.inputByteBudget else {
            throw AIServiceError.context("指示及輸入超過 \(route.title) 的保守預算；沒有送出請求")
        }
        return AIRequest(operation: operation, system: prompt.0, user: prompt.1,
                         maximumOutputTokens: capabilities.maximumOutputTokens)
    }
    private func structured<Output: AIOutput>(_ type: Output.Type, operation: AIOperation, prompt: (String, String)) async throws -> Output {
        let req = try request(operation, prompt)
        let data = try await provider.structured(req, kind: type.kind)
        let result: Output
        do { result = try JSONDecoder().decode(type, from: data) }
        catch { throw AIServiceError.malformed("\(type.kind.rawValue)：\(error.localizedDescription)") }
        try result.validate()
        return result
    }
    private func text(operation: AIOperation, prompt: (String, String)) async throws -> String {
        let result = try await provider.text(request(operation, prompt))
        try requireAI(nonblank(result), "empty text")
        return result
    }
    func overview(transcript: String) async throws -> OverviewOutput {
        try await structured(OverviewOutput.self, operation: .overview, prompt: Prompts.miniSummary(transcript: transcript))
    }
    func takeaways(transcript: String) async throws -> TakeawaysOutput {
        try await structured(TakeawaysOutput.self, operation: .takeaways, prompt: Prompts.takeaways(transcript: transcript))
    }
    func chapters(transcript: String, totalSeconds: Double) async throws -> ChaptersOutput {
        guard totalSeconds.isFinite, totalSeconds >= 0 else { throw AIServiceError.context("單集長度無效") }
        let result = try await structured(ChaptersOutput.self, operation: .chapters, prompt: Prompts.chapters(transcript: transcript, totalSeconds: totalSeconds))
        try requireAI(result.chapters.allSatisfy { $0.start <= totalSeconds }, "chapter outside episode")
        return result
    }
    func mindmap(transcript: String) async throws -> MindmapOutput {
        try await structured(MindmapOutput.self, operation: .mindmap, prompt: Prompts.mindmap(transcript: transcript))
    }
    func insights(transcript: String) async throws -> InsightsOutput {
        try await structured(InsightsOutput.self, operation: .insights, prompt: Prompts.insights(transcript: transcript))
    }
    func note(segment: String) async throws -> NoteOutput {
        guard nonblank(segment) else { throw AIServiceError.context("擷取片段為空") }
        if segment.utf8.count <= transcriptByteBudget {
            return try await structured(NoteOutput.self, operation: .note, prompt: Prompts.snipNote(segment: segment))
        }
        let chunks = try TranscriptContext.chunks(segments: [TranscriptSegment(start: 0, end: 0, text: segment)], inputByteBudget: transcriptByteBudget)
        var notes: [String] = []
        for chunk in chunks {
            let note = try await structured(NoteOutput.self, operation: .note, prompt: Prompts.snipNote(segment: chunk.text))
            notes.append(note.note)
        }
        return NoteOutput(note: "分 \(chunks.count) 段整理：\n" + notes.joined(separator: "\n"))
    }
    func answer(question: String, segments: [TranscriptSegment]) async throws -> String {
        guard nonblank(question) else { throw AIServiceError.context("問題為空") }
        let fixed = Prompts.ask(question: question, context: "")
        let budget = capabilities.inputByteBudget - fixed.0.utf8.count - fixed.1.utf8.count
        let selection = try TranscriptContext.select(question: question, segments: segments, byteBudget: budget)
        let answer = try await text(operation: .question, prompt: Prompts.ask(question: question, context: selection.text))
        return selection.disclosure + "\n\n" + answer
    }
    func testConnection() async throws -> String {
        try await text(operation: .connectionTest, prompt: ("Reply with exactly OK.", "ping"))
    }
}
