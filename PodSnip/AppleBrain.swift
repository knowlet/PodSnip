import Foundation
import FoundationModels

/// One immutable route per provider. Apple requests never load API credentials or
/// switch providers. Every independent request owns a fresh model session.
struct AppleAIProvider: AIProvider {
    let route: AIRoute

    var availability: AIAvailability {
        switch route {
        case .onDevice:
            guard #available(iOS 26, *) else {
                return AIAvailability(isAvailable: false, reason: "端側模型需 iOS 26 以上")
            }
            return Self.onDeviceAvailability(SystemLanguageModel.default)
        case .appleCloud:
            guard #available(iOS 27, *) else {
                return AIAvailability(isAvailable: false, reason: "Apple 雲端模型需 iOS 27 以上")
            }
            return Self.cloudAvailability(PrivateCloudComputeLanguageModel())
        case .byok:
            return AIAvailability(isAvailable: false, reason: "Apple provider 不處理 OpenAI 相容 API")
        }
    }

    func text(_ request: AIRequest) async throws -> String {
        try validateBudget(request)
        guard #available(iOS 26, *) else { throw AIServiceError.unavailable(availability.reason) }
        do {
            let session = try makeSession(instructions: request.system)
            let response = try await session.respond(to: request.user,
                options: GenerationOptions(maximumResponseTokens: request.maximumOutputTokens))
            // Structural completeness is exposed by the SDK. A complete String
            // does not prove that an answer is semantically complete.
            try requireAI(response.rawContent.isComplete, "incomplete text output")
            try requireAI(nonblank(response.content), "empty text")
            return response.content
        } catch { throw Self.mapError(error) }
    }

    func structured(_ request: AIRequest, kind: AIOutputKind) async throws -> Data {
        try validateBudget(request)
        guard #available(iOS 26, *) else { throw AIServiceError.unavailable(availability.reason) }
        do {
            let schema = try Self.schema(for: kind)
            // The application budgets this many bytes for the actual encoded
            // schema, in addition to instructions, input, framing, and output.
            let schemaBytes = try JSONEncoder().encode(schema).count
            let reserve = AICapabilities.forRoute(route).schemaReserve
            guard schemaBytes <= reserve else {
                throw AIServiceError.context("\(kind.rawValue) schema 需 \(schemaBytes) bytes，預留僅 \(reserve) bytes")
            }
            let session = try makeSession(instructions: request.system)
            let response = try await session.respond(to: request.user, schema: schema,
                options: GenerationOptions(maximumResponseTokens: request.maximumOutputTokens))
            try requireAI(response.content.isComplete, "incomplete guided output")
            // Guided generation constrains shape, while shared validation checks
            // nonempty text, finite timestamps, and increasing chapters.
            return try Self.validatedData(Data(response.content.jsonString.utf8), kind: kind)
        } catch { throw Self.mapError(error) }
    }

    private func validateBudget(_ request: AIRequest) throws {
        let capabilities = AICapabilities.forRoute(route)
        guard request.maximumOutputTokens > 0,
              request.maximumOutputTokens <= capabilities.maximumOutputTokens else {
            throw AIServiceError.context("輸出 token 上限不在此路由的安全預算內")
        }
        guard request.system.utf8.count + request.user.utf8.count <= capabilities.inputByteBudget else {
            throw AIServiceError.context("指示及輸入超過保守 UTF-8 預算；請縮小片段")
        }
    }

    @available(iOS 26, *)
    private func makeSession(instructions: String) throws -> LanguageModelSession {
        switch route {
        case .onDevice:
            let model = SystemLanguageModel.default
            let state = Self.onDeviceAvailability(model)
            guard state.isAvailable else { throw AIServiceError.unavailable(state.reason) }
            return LanguageModelSession(model: model, instructions: instructions)
        case .appleCloud:
            guard #available(iOS 27, *) else { throw AIServiceError.unavailable("Apple 雲端模型需 iOS 27 以上") }
            let model = PrivateCloudComputeLanguageModel()
            // Check runtime eligibility on the same model used by this session.
            guard case .available = model.availability else {
                throw AIServiceError.unavailable(Self.cloudAvailability(model).reason)
            }
            let quota = model.quotaUsage
            guard !quota.isLimitReached else {
                throw AIServiceError.quota(Self.quotaMessage(resetDate: quota.resetDate,
                    hasSuggestion: quota.limitIncreaseSuggestion != nil))
            }
            return LanguageModelSession(model: model, instructions: instructions)
        case .byok:
            throw AIServiceError.unavailable("Apple provider 不處理 OpenAI 相容 API")
        }
    }

    @available(iOS 26, *)
    private static func onDeviceAvailability(_ model: SystemLanguageModel) -> AIAvailability {
        switch model.availability {
        case .available: return AIAvailability(isAvailable: true, reason: "端側模型回報可用")
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return AIAvailability(isAvailable: false, reason: "此裝置不支援 Apple Intelligence")
            case .appleIntelligenceNotEnabled: return AIAvailability(isAvailable: false, reason: "請在系統設定開啟 Apple Intelligence")
            case .modelNotReady: return AIAvailability(isAvailable: false, reason: "端側模型尚未就緒，可能仍在下載")
            @unknown default: return AIAvailability(isAvailable: false, reason: "端側模型暫不可用")
            }
        }
    }

    @available(iOS 27, *)
    private static func cloudAvailability(_ model: PrivateCloudComputeLanguageModel) -> AIAvailability {
        switch model.availability {
        case .available:
            let quota = model.quotaUsage
            if quota.isLimitReached {
                return AIAvailability(isAvailable: false, reason: quotaMessage(resetDate: quota.resetDate,
                    hasSuggestion: quota.limitIncreaseSuggestion != nil))
            }
            let status: String
            switch quota.status {
            case .belowLimit(let usage): status = usage.isApproachingLimit ? "接近配額上限" : "尚未達配額上限"
            case .limitReached: status = "已達配額上限"
            @unknown default: status = "配額狀態未知"
            }
            return AIAvailability(isAvailable: true, reason: "PCC 模型回報可用；\(status)。Apple 核准的 entitlement 及實際推論仍須驗證")
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return AIAvailability(isAvailable: false, reason: "此裝置或帳號目前不符合 PCC 資格；需 Apple 核准的 entitlement")
            case .systemNotReady:
                return AIAvailability(isAvailable: false, reason: "PCC 系統尚未就緒；需檢查 Apple 資格及核准的 entitlement")
            @unknown default: return AIAvailability(isAvailable: false, reason: "PCC 暫不可用；需 Apple 核准的 entitlement")
            }
        }
    }

    private static func quotaMessage(resetDate: Date?, hasSuggestion: Bool) -> String {
        var message = "Apple 回報配額已達上限"
        if let resetDate { message += "；Apple 提供的重置時間：\(ISO8601DateFormatter().string(from: resetDate))" }
        else { message += "；Apple 未提供重置時間" }
        if hasSuggestion { message += "；Apple 提供配額提升建議（此處不開啟申請）" }
        return message
    }

    /// iOS 27 moved common model failures out of the iOS 26 GenerationError.
    /// Preserve any unclassified error so the UI can show the actual failure.
    static func mapError(_ error: Error) -> Error {
        if #available(iOS 27, *) {
            if let cloud = error as? PrivateCloudComputeLanguageModel.Error {
                switch cloud {
                case .quotaLimitReached(let context):
                    return AIServiceError.quota(quotaMessage(resetDate: context.resetDate,
                        hasSuggestion: context.limitIncreaseSuggestion != nil))
                case .networkFailure(let context): return AIServiceError.network(context.debugDescription)
                case .serviceUnavailable(let context): return AIServiceError.service(context.debugDescription)
                @unknown default: return error
                }
            }
            if let model = error as? LanguageModelError {
                if case .contextSizeExceeded(let context) = model {
                    return AIServiceError.context("Apple 回報 \(context.tokenCount)/\(context.contextSize) tokens；請縮小片段")
                }
                return error
            }
        }
        if #available(iOS 26, *), let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .exceededContextWindowSize: return AIServiceError.context("Apple 回報超出上下文限制；請縮小片段")
            case .assetsUnavailable: return AIServiceError.unavailable(error.localizedDescription)
            case .decodingFailure: return AIServiceError.malformed(error.localizedDescription)
            default: return error
            }
        }
        return error
    }

    @available(iOS 26, *)
    static func schema(for kind: AIOutputKind) throws -> GenerationSchema {
        typealias Schema = DynamicGenerationSchema
        typealias Property = Schema.Property
        let string = Schema(type: String.self)
        let seconds = Schema(type: Double.self, guides: [.minimum(0)])
        func text(_ name: String) -> Property { Property(name: name, schema: string) }
        func array(_ name: String, of element: Schema, minimum: Int = 1, maximum: Int = 6) -> Property {
            Property(name: name, schema: Schema(arrayOf: element, minimumElements: minimum, maximumElements: maximum))
        }
        let root: Schema
        switch kind {
        case .overview:
            root = Schema(name: "Overview", properties: [text("summary"), text("guests"), array("topics", of: string)])
        case .takeaways:
            let item = Schema(name: "Takeaway", properties: [text("title"), text("detail"), Property(name: "at", schema: seconds)])
            root = Schema(name: "Takeaways", properties: [array("takeaways", of: item)])
        case .chapters:
            let item = Schema(name: "Chapter", properties: [Property(name: "start", schema: seconds), text("title"), text("summary")])
            root = Schema(name: "Chapters", properties: [array("chapters", of: item)])
        case .mindmap:
            let leaf = Schema(name: "Leaf", properties: [text("label")])
            let branch = Schema(name: "Branch", properties: [text("label"), array("children", of: leaf, maximum: 3)])
            root = Schema(name: "Mindmap", properties: [text("topic"), array("branches", of: branch, maximum: 4)])
        case .insights:
            let item = Schema(name: "Insight", properties: [text("title"), text("body")])
            root = Schema(name: "Insights", properties: [array("insights", of: item), array("open_questions", of: string, minimum: 0, maximum: 3)])
        case .note:
            root = Schema(name: "Note", properties: [text("note")])
        }
        return try GenerationSchema(root: root, dependencies: [])
    }

    private static func validatedData(_ data: Data, kind: AIOutputKind) throws -> Data {
        func validated<Output: AIOutput>(_ type: Output.Type) throws -> Data {
            let output: Output
            do { output = try JSONDecoder().decode(type, from: data) }
            catch { throw AIServiceError.malformed("\(kind.rawValue)：\(error.localizedDescription)") }
            try output.validate()
            return try JSONEncoder().encode(output)
        }
        switch kind {
        case .overview: return try validated(OverviewOutput.self)
        case .takeaways: return try validated(TakeawaysOutput.self)
        case .chapters: return try validated(ChaptersOutput.self)
        case .mindmap: return try validated(MindmapOutput.self)
        case .insights: return try validated(InsightsOutput.self)
        case .note: return try validated(NoteOutput.self)
        }
    }
}
