import XCTest
@testable import PodSnip

final class RegressionTests: XCTestCase {
    func testLaterChunkTimestampOffsetIsAppliedOnce() {
        let words = [
            TranscriptionWord(timestamp: 0.5, duration: 0.75, text: "合成"),
            TranscriptionWord(timestamp: 1.5, duration: 0.5, text: "逐字稿。"),
        ]

        let first = TranscriptSegmenter.segments(from: words, offset: 0)
        let second = TranscriptSegmenter.segments(from: words, offset: 240)
        let third = TranscriptSegmenter.segments(from: words, offset: 480)

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(third.count, 1)
        XCTAssertEqual(second[0].start, 240.5, accuracy: 0.001)
        XCTAssertEqual(second[0].end, 242, accuracy: 0.001)
        XCTAssertEqual(third[0].start, 480.5, accuracy: 0.001)
        XCTAssertEqual(third[0].end, 482, accuracy: 0.001)
        XCTAssertEqual(second[0].text, "合成逐字稿。")
    }

    func testSentenceAndDurationGroupingKeepAbsoluteBounds() {
        let words = [
            TranscriptionWord(timestamp: 0, duration: 4, text: "開始"),
            TranscriptionWord(timestamp: 4, duration: 5, text: "超過八秒"),
            TranscriptionWord(timestamp: 10, duration: 1, text: "下一句。"),
        ]
        let segments = TranscriptSegmenter.segments(from: words, offset: 240)
        XCTAssertEqual(segments.map(\.start), [240, 250])
        XCTAssertEqual(segments.map(\.end), [249, 251])
        XCTAssertEqual(segments.map(\.text), ["開始超過八秒", "下一句。"])
    }

    func testOverlappingTranscriptionsOwnSeparateChunkFilesAndCleanup() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("podsnip-synthetic-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }

        let first = try TranscriptionWorkingDirectory(parent: parent)
        let second = try TranscriptionWorkingDirectory(parent: parent)
        XCTAssertNotEqual(first.url, second.url)
        let firstChunk = first.url.appendingPathComponent("podsnip-chunk-0.m4a")
        let secondChunk = second.url.appendingPathComponent("podsnip-chunk-0.m4a")
        try Data("synthetic first chunk; not audio".utf8).write(to: firstChunk)
        try Data("synthetic second chunk; not audio".utf8).write(to: secondChunk)

        try first.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondChunk.path))
        XCTAssertEqual(try String(contentsOf: secondChunk, encoding: .utf8), "synthetic second chunk; not audio")
        try second.remove()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func testUsageAndBackgroundAudioDeclarationsAreInBuiltApp() {
        let speechUsage = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        XCTAssertFalse(speechUsage?.isEmpty ?? true)
        XCTAssertTrue(modes?.contains("audio") == true)
    }
}
