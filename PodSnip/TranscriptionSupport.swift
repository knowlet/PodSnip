import Foundation

/// Value-only input lets timestamp grouping be checked without Speech authorization or media.
struct TranscriptionWord {
    let timestamp: Double
    let duration: Double
    let text: String
}

enum TranscriptSegmenter {
    static func segments(from words: [TranscriptionWord], offset: Double) -> [TranscriptSegment] {
        var output: [TranscriptSegment] = []
        var text = ""
        var start = 0.0
        var end = 0.0

        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                output.append(TranscriptSegment(start: start, end: end, text: trimmed))
            }
            text = ""
        }

        for word in words {
            let absoluteStart = word.timestamp + offset
            let absoluteEnd = absoluteStart + word.duration
            if text.isEmpty { start = absoluteStart }
            text += word.text
            end = absoluteEnd
            if end - start > 8 {
                flush()
            } else if word.text.hasSuffix("。") || word.text.hasSuffix("！")
                || word.text.hasSuffix("？") || word.text.hasSuffix(".") {
                text += " "
                flush()
            }
        }
        flush()
        return output
    }
}

/// Each transcription invocation owns its directory, including identically named chunks.
struct TranscriptionWorkingDirectory {
    let url: URL

    init(parent: URL = FileManager.default.temporaryDirectory) throws {
        url = parent.appendingPathComponent("podsnip-transcription-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func remove() throws {
        try FileManager.default.removeItem(at: url)
    }
}
