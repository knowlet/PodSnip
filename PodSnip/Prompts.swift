import Foundation

/// Prompt builders. Transcript is pre-truncated by callers.
enum Prompts {
    static let localeHint = "請用跟逐字稿相同的主要語言回覆（中文逐字稿就用繁體中文）。"

    static func miniSummary(transcript: String) -> (String, String) {
        ("你是一個 podcast 摘要助手。只回傳 JSON：{\"summary\": \"3-5句總覽\", \"guests\": \"來賓（若有）\", \"topics\": [\"主題1\", \"主題2\"]}。" + localeHint,
         "逐字稿（已截斷）：\n" + transcript)
    }

    static func takeaways(transcript: String) -> (String, String) {
        ("你是一個 podcast 摘要助手。只回傳 JSON：{\"takeaways\": [{\"title\": \"要點標題\", \"detail\": \"1-2句說明\", \"at\": 秒數（數字，可估）}]}，5-10 個要點。" + localeHint,
         "逐字稿（已截斷）：\n" + transcript)
    }

    static func chapters(transcript: String, totalSeconds: Double) -> (String, String) {
        ("你是 podcast 章節編輯。只回傳 JSON：{\"chapters\": [{\"start\": 起始秒數數字, \"title\": \"章節標題\", \"summary\": \"一句說明\"}]}，覆蓋全集，8-20 章，start 遞增且小於 \(Int(totalSeconds))。" + localeHint,
         "逐字稿（含 [mm:ss] 時間戳）：\n" + transcript)
    }

    static func mindmap(transcript: String) -> (String, String) {
        ("你是知識結構化助手。只回傳 JSON：{\"topic\": \"本集主題\", \"branches\": [{\"label\": \"分支\", \"children\": [{\"label\": \"葉節點\"}]}]}，3-6 個分支，每分支 2-5 葉。" + localeHint,
         "逐字稿（已截斷）：\n" + transcript)
    }

    static func insights(transcript: String) -> (String, String) {
        ("你是深度分析師。只回傳 JSON：{\"insights\": [{\"title\": \"洞見\", \"body\": \"2-3句含原文依據\"}], \"open_questions\": [\"值得追問的問題\"]}。" + localeHint,
         "逐字稿（已截斷）：\n" + transcript)
    }

    static func snipNote(segment: String) -> (String, String) {
        ("你是擷取筆記助手。只回傳 JSON：{\"note\": \"一句話：為什麼這段值得記\"}。" + localeHint,
         "擷取片段：\n" + segment)
    }

    static func ask(question: String, context: String) -> (String, String) {
        ("你是這集 podcast 的問答助手，只能依據提供的逐字稿回答；不知道就說不知道，並附上 [mm:ss] 時間引用。" + localeHint,
         "逐字稿：\n" + context + "\n\n問題：" + question)
    }

    /// Keep payloads small: head + tail keep the gist for long episodes.
    static func compact(_ text: String, limit: Int = 12000) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit * 2 / 3)
        let tail = text.suffix(limit / 3)
        return head + "\n…[中間省略]…\n" + tail
    }

    static func timestamped(_ segments: [TranscriptSegment], limit: Int = 12000) -> String {
        var out = ""
        for s in segments {
            let m = Int(s.start) / 60, sec = Int(s.start) % 60
            let line = String(format: "[%02d:%02d] %@", m, sec, s.text)
            if out.count + line.count > limit { out += "\n…[後略]…"; break }
            out += line + "\n"
        }
        return out
    }
}
