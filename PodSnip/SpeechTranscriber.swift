import Foundation
import Speech
import AVFoundation

enum TranscribeError: LocalizedError {
    case notAuthorized
    case noRecognizer
    case exportFailed
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "尚未授權語音辨識，請到設定開啟。"
        case .noRecognizer: return "此語言不支援語音辨識。"
        case .exportFailed: return "音檔切段失敗。"
        case .failed(let s): return "轉寫失敗：\(s)"
        }
    }
}

/// On-device (when available) speech-to-text with chunking for long episodes.
final class SpeechTranscriber: NSObject {
    static let shared = SpeechTranscriber()

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    func transcribe(audioFileURL: URL, locale: Locale = Locale(identifier: "zh-TW"),
                    progress: @escaping (Double) -> Void = { _ in }) async throws -> [TranscriptSegment] {
        guard await requestAuthorization() else { throw TranscribeError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { throw TranscribeError.noRecognizer }

        let asset = AVURLAsset(url: audioFileURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 1 else { throw TranscribeError.failed("音檔太短或無法讀取") }

        // Split into ~4-minute chunks for reliability.
        let chunkLen: Double = 240
        let nChunks = max(1, Int(ceil(duration / chunkLen)))
        var all: [TranscriptSegment] = []
        for i in 0..<nChunks {
            let start = Double(i) * chunkLen
            let len = min(chunkLen, duration - start)
            let chunkURL = try await exportChunk(asset: asset, start: start, length: len, index: i)
            defer { try? FileManager.default.removeItem(at: chunkURL) }
            let segs = try await transcribeOne(url: chunkURL, recognizer: recognizer, offset: start)
            all.append(contentsOf: segs)
            progress(Double(i + 1) / Double(nChunks))
        }
        return all
    }

    private func exportChunk(asset: AVURLAsset, start: Double, length: Double, index: Int) async throws -> URL {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscribeError.exportFailed
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("podsnip-chunk-\(index).m4a")
        try? FileManager.default.removeItem(at: out)
        session.outputURL = out
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                        duration: CMTime(seconds: length, preferredTimescale: 600))
        await session.export()
        guard session.status == .completed else { throw TranscribeError.exportFailed }
        return out
    }

    private func transcribeOne(url: URL, recognizer: SFSpeechRecognizer, offset: Double) async throws -> [TranscriptSegment] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[TranscriptSegment], Error>) in
            let req = SFSpeechURLRecognitionRequest(url: url)
            req.shouldReportPartialResults = false
            if recognizer.supportsOnDeviceRecognition {
                req.requiresOnDeviceRecognition = true
            }
            var finished = false
            let task = recognizer.recognitionTask(with: req) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    cont.resume(returning: Self.segments(from: result, offset: offset))
                } else if let error {
                    finished = true
                    cont.resume(throwing: TranscribeError.failed(error.localizedDescription))
                } else if result == nil && error == nil {
                    // No result at all (silence?) — treat as empty.
                    finished = true
                    cont.resume(returning: [])
                }
            }
            _ = task
        }
    }

    private static func segments(from result: SFSpeechRecognitionResult, offset: Double) -> [TranscriptSegment] {
        let trans = result.bestTranscription
        // Group word-level segments into ~8s sentences.
        var out: [TranscriptSegment] = []
        var cur = ""
        var curStart = 0.0
        var curEnd = 0.0
        func flush() {
            let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(TranscriptSegment(start: curStart, end: curEnd, text: t)) }
            cur = ""
        }
        for seg in trans.segments {
            let s = seg.timestamp + offset, e = s + seg.duration
            if cur.isEmpty { curStart = s }
            cur += (cur.isEmpty ? "" : "") + seg.substring
            curEnd = e
            if e - curStart > 8 { flush() }
            else if seg.substring.hasSuffix("。") || seg.substring.hasSuffix("！") || seg.substring.hasSuffix("？")
                        || seg.substring.hasSuffix(".") { cur += " "; flush() }
        }
        flush()
        return out
    }
}
