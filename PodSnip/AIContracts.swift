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

/// Persisted summary documents.
///
/// Version 2 is the strict contract written by the current pipeline. Version 1
/// and documents with no `schemaVersion` are the unversioned JSON saved before
/// that contract: missing detail, timestamp, summary, body, topic, and
/// `open_questions` still decode, using the same defaults as the previous
/// lenient reader. Provider ingestion does not use this path.
enum SummaryArchive {
    static let currentVersion = 2
    static let legacyVersion = 1
    private static let versionKey = "schemaVersion"

    static func persist<T: Encodable>(_ value: T) throws -> String {
        let encoded = try JSONEncoder().encode(value)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw AIServiceError.malformed("無法儲存版本化摘要")
        }
        object[versionKey] = currentVersion
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AIServiceError.malformed("無法儲存 UTF-8 輸出")
        }
        return text
    }

    static func takeaways(from json: String?) -> [TakeawayOutput]? {
        guard let object = object(from: json) else { return nil }
        switch generation(of: object) {
        case .legacy:
            return legacyTakeaways(object)
        case .current:
            return strict(TakeawaysOutput.self, json: json)?.takeaways
        case .unsupported:
            return nil
        }
    }

    static func chapters(from json: String?) -> [Chapter]? {
        guard let object = object(from: json) else { return nil }
        switch generation(of: object) {
        case .legacy:
            return legacyChapters(object)
        case .current:
            return strict(ChaptersOutput.self, json: json)?.chapters.map {
                Chapter(start: $0.start, title: $0.title, summary: $0.summary)
            }
        case .unsupported:
            return nil
        }
    }

    static func mindmap(from json: String?) -> MindNode? {
        guard let object = object(from: json) else { return nil }
        switch generation(of: object) {
        case .legacy:
            return legacyMindmap(object)
        case .current:
            guard let map = strict(MindmapOutput.self, json: json) else { return nil }
            return MindNode(label: map.topic, children: map.branches.map { branch in
                MindNode(label: branch.label, children: branch.children.map {
                    MindNode(label: $0.label, children: nil)
                })
            })
        case .unsupported:
            return nil
        }
    }

    static func insights(from json: String?) -> [(String, String)]? {
        guard let object = object(from: json) else { return nil }
        switch generation(of: object) {
        case .legacy:
            return legacyInsights(object)
        case .current:
            return strict(InsightsOutput.self, json: json)?.insights.map { ($0.title, $0.body) }
        case .unsupported:
            return nil
        }
    }

    private enum DocumentGeneration { case legacy, current, unsupported }

    private static func generation(of object: [String: Any]) -> DocumentGeneration {
        switch schemaVersion(in: object) {
        case .absent:
            return .legacy
        case .number(let version) where version == legacyVersion:
            return .legacy
        case .number(let version) where version == currentVersion:
            return .current
        case .invalid, .number:
            return .unsupported
        }
    }

    private static func strict<T: Decodable>(_ type: T.Type, json: String?) -> T? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func object(from json: String?) -> [String: Any]? {
        guard let data = json?.data(using: .utf8), !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private enum VersionToken {
        case absent
        case invalid
        case number(Int)
    }

    /// Missing `schemaVersion` is the historical document. A present value must be
    /// an integer; booleans, fractions, and strings are not coerced into v1 or v2.
    private static func schemaVersion(in object: [String: Any]) -> VersionToken {
        guard object.keys.contains(versionKey) else { return .absent }
        guard let number = object[versionKey] as? NSNumber, !isJSONBoolean(number) else { return .invalid }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value <= Double(Int.max), value.rounded(.towardZero) == value else {
            return .invalid
        }
        return .number(Int(value))
    }

    private static func legacyTakeaways(_ object: [String: Any]) -> [TakeawayOutput]? {
        guard let rows = object["takeaways"] as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let title = row["title"] as? String else { return nil }
            return TakeawayOutput(title: title, detail: (row["detail"] as? String) ?? "", at: seconds(row["at"]) ?? 0)
        }
    }

    private static func legacyChapters(_ object: [String: Any]) -> [Chapter]? {
        guard let rows = object["chapters"] as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let title = row["title"] as? String else { return nil }
            return Chapter(start: seconds(row["start"]) ?? 0, title: title, summary: row["summary"] as? String)
        }
    }

    private static func legacyMindmap(_ object: [String: Any]) -> MindNode {
        func node(_ row: [String: Any]) -> MindNode {
            let children = (row["children"] as? [[String: Any]])?.map(node)
            return MindNode(label: (row["label"] as? String) ?? "", children: children)
        }
        let topic = (object["topic"] as? String).flatMap { nonblank($0) ? $0 : nil } ?? "主題"
        let branches = (object["branches"] as? [[String: Any]])?.map(node) ?? []
        return MindNode(label: topic, children: branches)
    }

    private static func legacyInsights(_ object: [String: Any]) -> [(String, String)]? {
        guard let rows = object["insights"] as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let title = row["title"] as? String else { return nil }
            return (title, (row["body"] as? String) ?? "")
        }
    }

    private static func seconds(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, !isJSONBoolean(number) {
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        if let text = value as? String {
            let double = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
            return double?.isFinite == true ? double : nil
        }
        return nil
    }

    private static func isJSONBoolean(_ number: NSNumber) -> Bool {
        // JSON true/false use the boolean Objective-C type code. JSON 0 and 1 do not.
        let code = String(cString: number.objCType)
        return code == "c" || code == "B"
    }
}
