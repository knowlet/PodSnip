import Foundation

enum AIRoute: String, CaseIterable, Identifiable {
    case onDevice = "apple-ondevice", appleCloud = "apple-cloud", byok = "byok"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .onDevice: return "Apple 端側"
        case .appleCloud: return "Apple 雲端（PCC）"
        case .byok: return "自帶 Key（OpenAI 相容）"
        }
    }
    var subtitle: String {
        switch self {
        case .onDevice: return "iOS 26＋Apple Intelligence；內容在裝置處理"
        case .appleCloud: return "iOS 27＋Apple 核准的 PCC entitlement；資格及配額由 Apple 決定"
        case .byok: return "內容送至指定端點；費用由供應商決定"
        }
    }
}

struct AIAvailability {
    let isAvailable: Bool
    let reason: String
}

struct AICapabilities {
    let contextTokens: Int
    let maximumOutputTokens: Int
    // Conservative UTF-8 input budgeting. Reserve space for the largest schema,
    // session framing, and output; this is not a provider tokenizer guarantee.
    let schemaReserve = 1536
    let framingReserve = 256
    var inputByteBudget: Int { contextTokens - maximumOutputTokens - schemaReserve - framingReserve }
    static func forRoute(_ route: AIRoute) -> Self {
        switch route {
        case .onDevice: return Self(contextTokens: 4096, maximumOutputTokens: 768)
        case .appleCloud: return Self(contextTokens: 32768, maximumOutputTokens: 1024)
        case .byok: return Self(contextTokens: 8192, maximumOutputTokens: 1024)
        }
    }
}

enum AIOutputKind: String, CaseIterable { case overview, takeaways, chapters, mindmap, insights, note }
enum AIOperation: String, CaseIterable { case overview, takeaways, chapters, mindmap, insights, question, note, connectionTest }
struct AIRequest {
    let operation: AIOperation
    let system: String
    let user: String
    let maximumOutputTokens: Int
}

protocol AIProvider {
    var route: AIRoute { get }
    var availability: AIAvailability { get }
    func text(_ request: AIRequest) async throws -> String
    func structured(_ request: AIRequest, kind: AIOutputKind) async throws -> Data
}

enum AIServiceError: LocalizedError {
    case unavailable(String), context(String), malformed(String), quota(String), network(String), service(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let s): return "AI 暫不可用：\(s)"
        case .context(let s): return "AI 上下文超出限制：\(s)"
        case .malformed(let s): return "AI 輸出格式錯誤：\(s)"
        case .quota(let s): return "Apple 雲端配額已達上限：\(s)"
        case .network(let s): return "Apple 雲端網路失敗：\(s)"
        case .service(let s): return "Apple 雲端服務暫不可用：\(s)"
        }
    }
}

protocol AIOutput: Codable {
    static var kind: AIOutputKind { get }
    func validate() throws
}
func requireAI(_ condition: Bool, _ reason: String) throws {
    if !condition { throw AIServiceError.malformed(reason) }
}
func nonblank(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
func validAITime(_ value: Double) -> Bool { value.isFinite && value >= 0 && value <= Double(Int.max / 2) }

struct OverviewOutput: AIOutput {
    static let kind = AIOutputKind.overview
    var summary: String; var guests: String; var topics: [String]
    func validate() throws { try requireAI(nonblank(summary) && !topics.isEmpty && topics.allSatisfy(nonblank), "summary/topics") }
}
struct TakeawayOutput: Codable { var title: String; var detail: String; var at: Double }
struct TakeawaysOutput: AIOutput {
    static let kind = AIOutputKind.takeaways
    var takeaways: [TakeawayOutput]
    func validate() throws {
        try requireAI(!takeaways.isEmpty && takeaways.allSatisfy { nonblank($0.title) && nonblank($0.detail) && validAITime($0.at) }, "takeaways")
    }
}
struct ChapterOutput: Codable { var start: Double; var title: String; var summary: String }
struct ChaptersOutput: AIOutput {
    static let kind = AIOutputKind.chapters
    var chapters: [ChapterOutput]
    func validate() throws {
        try requireAI(!chapters.isEmpty && chapters.allSatisfy { validAITime($0.start) && nonblank($0.title) && nonblank($0.summary) }, "chapters")
        try requireAI(zip(chapters, chapters.dropFirst()).allSatisfy { $0.start < $1.start }, "chapters must increase")
    }
}
struct MindLeafOutput: Codable { var label: String }
struct MindBranchOutput: Codable { var label: String; var children: [MindLeafOutput] }
struct MindmapOutput: AIOutput {
    static let kind = AIOutputKind.mindmap
    var topic: String; var branches: [MindBranchOutput]
    func validate() throws {
        try requireAI(nonblank(topic) && !branches.isEmpty && branches.allSatisfy { nonblank($0.label) && !$0.children.isEmpty && $0.children.allSatisfy { nonblank($0.label) } }, "mindmap")
    }
}
struct InsightOutput: Codable { var title: String; var body: String }
struct InsightsOutput: AIOutput {
    static let kind = AIOutputKind.insights
    var insights: [InsightOutput]; var open_questions: [String]
    func validate() throws {
        try requireAI(!insights.isEmpty && insights.allSatisfy { nonblank($0.title) && nonblank($0.body) } && open_questions.allSatisfy(nonblank), "insights")
    }
}
struct NoteOutput: AIOutput {
    static let kind = AIOutputKind.note
    var note: String
    func validate() throws { try requireAI(nonblank(note), "note") }
}
