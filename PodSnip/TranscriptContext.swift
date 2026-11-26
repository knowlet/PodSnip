import Foundation

struct TranscriptChunk {
    let text: String
    let start: Double
    let end: Double
}

enum TranscriptContext {
    static func stamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds <= Double(Int.max / 2) else { return "?:??" }
        let value = Int(seconds)
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    /// Every grapheme is retained, including in an oversized individual segment.
    /// Split pieces retain the original segment's episode time, never invented time.
    static func chunks(segments: [TranscriptSegment], inputByteBudget: Int) throws -> [TranscriptChunk] {
        guard inputByteBudget >= 128 else { throw AIServiceError.context("輸入預算不足") }
        var result: [TranscriptChunk] = []
        var lines = ""
        var start = 0.0, end = 0.0
        func flush() {
            if !lines.isEmpty { result.append(TranscriptChunk(text: lines, start: start, end: end)); lines = "" }
        }
        var previousStart = 0.0
        for segment in segments {
            guard segment.start.isFinite, segment.end.isFinite, segment.start >= previousStart,
                  segment.end >= segment.start, segment.end <= Double(Int.max / 2) else {
                throw AIServiceError.context("逐字稿時間戳無效")
            }
            previousStart = segment.start
            guard !segment.text.isEmpty else { continue }
            let prefix = "[\(stamp(segment.start))] (\(segment.start)s–\(segment.end)s) "
            guard prefix.utf8.count + 1 < inputByteBudget else { throw AIServiceError.context("時間戳超出輸入預算") }
            var piece = ""
            func appendPiece() {
                let line = prefix + piece + "\n"
                if lines.utf8.count + line.utf8.count > inputByteBudget { flush() }
                if lines.isEmpty { start = segment.start; end = segment.end }
                lines += line; end = max(end, segment.end); piece = ""
            }
            for character in segment.text {
                let size = String(character).utf8.count
                guard prefix.utf8.count + size + 1 <= inputByteBudget else { throw AIServiceError.context("單一文字單位超出預算") }
                if prefix.utf8.count + piece.utf8.count + size + 1 > inputByteBudget { appendPiece() }
                piece.append(character)
            }
            if !piece.isEmpty { appendPiece() }
        }
        flush()
        return result
    }

    struct Selection { let text: String; let disclosure: String }
    static func select(question: String, segments: [TranscriptSegment], byteBudget: Int) throws -> Selection {
        let all = try chunks(segments: segments, inputByteBudget: byteBudget)
        guard !all.isEmpty else { throw AIServiceError.context("沒有可供問答的逐字稿") }
        let lowered = question.lowercased()
        let characters = Array(lowered)
        var terms = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 }
        if characters.count > 1 { terms += (0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) } }
        let ranked = all.enumerated().sorted { a, b in
            func score(_ value: TranscriptChunk) -> Int {
                let text = value.text.lowercased()
                return terms.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
            }
            let sa = score(a.element), sb = score(b.element)
            return sa == sb ? a.offset < b.offset : sa > sb
        }
        var selected: [(offset: Int, element: TranscriptChunk)] = []
        var used = 0
        for item in ranked {
            if used + item.element.text.utf8.count <= byteBudget { selected.append(item); used += item.element.text.utf8.count }
        }
        let ordered = selected.sorted { $0.offset < $1.offset }
        let ranges = ordered.map { "\(stamp($0.element.start))–\(stamp($0.element.end))" }.joined(separator: "、")
        let coverage = selected.count == all.count ? "使用全部提供的逐字稿" : "依問題文字比對選取 \(selected.count)/\(all.count) 塊逐字稿；其他內容未納入，可能缺少相關證據"
        return Selection(text: ordered.map { $0.element.text }.joined(), disclosure: "\(coverage)（\(ranges)）。")
    }
}
