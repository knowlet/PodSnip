import XCTest
import SwiftData
import CoreData
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

// MARK: - Persisted, unversioned legacy-store migration

// Kept in this already-compiled source so the tracked Xcode project and
// project.yml both run these tests without regeneration or target drift.
@MainActor
final class PersistenceMigrationTests: XCTestCase {
    func testPopulatedLegacyStorePreservesAllFieldsAndInitializesAIErrorToNil() throws {
        try withStoreDirectory { url in
            try writeLegacyStore(at: url)
            let before = try storeHashes(at: url)
            try withClosedContainer(at: url) { context in
                try assertMigratedContents(context)
            }
            try assertOnlySnipSchemaChanged(from: before, at: url)
        }
    }

    func testMigratedStoreReopensAndPersistsAndClearsAIError() throws {
        try withStoreDirectory { url in
            try writeLegacyStore(at: url)
            try withClosedContainer(at: url) { context in
                try assertMigratedContents(context)
                let snips = try context.fetch(FetchDescriptor<Snip>())
                let snip = try XCTUnwrap(snips.first { $0.id == LegacyFixture.noteIDs[0] })
                snip.aiError = "合成錯誤：暫時無法使用模型"
                try context.save()
            }
            try withClosedContainer(at: url) { context in
                try assertMigratedContents(context, firstError: "合成錯誤：暫時無法使用模型")
                let snips = try context.fetch(FetchDescriptor<Snip>())
                let snip = try XCTUnwrap(snips.first { $0.id == LegacyFixture.noteIDs[0] })
                snip.aiError = nil
                try context.save()
            }
            try withClosedContainer(at: url) { context in
                try assertMigratedContents(context)
            }
        }
    }

    func testEmptyLegacyStoreUpgradesAndAcceptsNewSnip() throws {
        try withStoreDirectory { url in
            try writeLegacyStore(at: url, populated: false)
            let before = try storeHashes(at: url)
            try withClosedContainer(at: url) { context in
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<PodcastFeed>()), 0)
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<EpisodeItem>()), 0)
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<Snip>()), 0)
                let snip = Snip(id: LegacyFixture.noteIDs[0], episodeTitle: "升級後的新筆記",
                                atTime: 0.25, text: "合成內容", aiNote: "合成 AI 筆記")
                XCTAssertNil(snip.aiError)
                context.insert(snip)
                try context.save()
            }
            try assertOnlySnipSchemaChanged(from: before, at: url)
            try withClosedContainer(at: url) { context in
                let snips = try context.fetch(FetchDescriptor<Snip>())
                XCTAssertEqual(snips.count, 1)
                let snip = try XCTUnwrap(snips.first)
                XCTAssertEqual(snip.id, LegacyFixture.noteIDs[0])
                XCTAssertNil(snip.episodeID)
                XCTAssertEqual(snip.episodeTitle, "升級後的新筆記")
                XCTAssertEqual(snip.atTime, 0.25)
                assertExact(snip.text, "合成內容")
                assertExact(snip.aiNote, "合成 AI 筆記")
                XCTAssertNil(snip.aiError)
            }
        }
    }

    func testInvalidExistingStoreThrowsWithoutReplacingItsBytes() throws {
        try withStoreDirectory { url in
            let original = Data("Authored invalid store; not a user's database.\n".utf8)
            try original.write(to: url)
            // Call the same throwing factory as app startup. There must be no
            // catch-and-delete, in-memory fallback, or silent fresh database.
            XCTAssertThrowsError(try autoreleasepool {
                try PodSnipPersistence.makeContainer(storeURL: url)
            })
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    private func withStoreDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "podsnip-legacy-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("default.store"))
    }

    // Never return live models/contexts from this scope, copy only values.
    // Separate contexts + autoreleasepool release the writer before reopening
    // this exact URL. The weak assertion catches an accidentally retained host.
    private func withClosedContainer(at url: URL, legacy: Bool = false,
                                     _ body: (ModelContext) throws -> Void) throws {
        weak var releasedContainer: ModelContainer?
        try autoreleasepool {
            let container: ModelContainer
            if legacy {
                let schema = Schema([LegacyPodSnipV1.PodcastFeed.self,
                                     LegacyPodSnipV1.EpisodeItem.self, LegacyPodSnipV1.Snip.self])
                let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
                container = try ModelContainer(for: schema, configurations: [config])
            } else {
                container = try PodSnipPersistence.makeContainer(storeURL: url)
            }
            releasedContainer = container
            let context = ModelContext(container)
            context.autosaveEnabled = false
            try body(context)
        }
        XCTAssertNil(releasedContainer, "Release the previous store before opening another schema")
    }

    private func writeLegacyStore(at url: URL, populated: Bool = true) throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try withClosedContainer(at: url, legacy: true) { context in
            if populated { LegacyFixture.insert(into: context) }
            try context.save()
        }
        // Establish that this is an actual SQLite fixture, not an in-memory
        // store or a newly-created destination being misreported as migration.
        XCTAssertEqual(try Data(contentsOf: url).prefix(16), Data("SQLite format 3\0".utf8))
        _ = try storeHashes(at: url)
        // Independently reopen under the old model before attempting upgrade.
        try withClosedContainer(at: url, legacy: true) { context in
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<LegacyPodSnipV1.PodcastFeed>()),
                           populated ? 2 : 0)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<LegacyPodSnipV1.EpisodeItem>()),
                           populated ? 3 : 0)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<LegacyPodSnipV1.Snip>()),
                           populated ? 4 : 0)
        }
    }

    private func storeHashes(at url: URL) throws -> [String: Data] {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType, at: url, options: [NSReadOnlyPersistentStoreOption: true])
        let hashes = try XCTUnwrap(metadata[NSStoreModelVersionHashesKey] as? [String: Data])
        XCTAssertEqual(Set(hashes.keys), Set(["PodcastFeed", "EpisodeItem", "Snip"]))
        return hashes
    }

    private func assertOnlySnipSchemaChanged(from before: [String: Data], at url: URL) throws {
        let after = try storeHashes(at: url)
        for name in ["PodcastFeed", "EpisodeItem"] {
            XCTAssertEqual(try XCTUnwrap(before[name]), try XCTUnwrap(after[name]), name)
        }
        XCTAssertNotEqual(try XCTUnwrap(before["Snip"]), try XCTUnwrap(after["Snip"]),
                          "The fixture must have the old Snip schema, without aiError")
    }

    private func assertExact(_ actual: String?, _ expected: String?,
                             file: StaticString = #filePath, line: UInt = #line) {
        // UTF-8 equality also catches whitespace/Unicode normalization changes.
        XCTAssertEqual(actual.map { Data($0.utf8) }, expected.map { Data($0.utf8) },
                       file: file, line: line)
    }

    private func assertMigratedContents(_ context: ModelContext, firstError: String? = nil) throws {
        let feeds = try context.fetch(FetchDescriptor<PodcastFeed>())
        let episodes = try context.fetch(FetchDescriptor<EpisodeItem>())
        let snips = try context.fetch(FetchDescriptor<Snip>())
        XCTAssertEqual(feeds.count, 2)
        XCTAssertEqual(episodes.count, 3)
        XCTAssertEqual(snips.count, 4)
        XCTAssertEqual(Set(feeds.map(\.id)), Set(LegacyFixture.feedIDs))
        XCTAssertEqual(Set(episodes.map(\.id)), Set(LegacyFixture.episodeIDs))
        XCTAssertEqual(Set(snips.map(\.id)), Set(LegacyFixture.noteIDs))

        for index in LegacyFixture.feedIDs.indices {
            let feed = try XCTUnwrap(feeds.first { $0.id == LegacyFixture.feedIDs[index] })
            assertExact(feed.title, LegacyFixture.feedTitles[index])
            assertExact(feed.feedURL, "https://example.invalid/feed-\(index).xml")
            assertExact(feed.artworkURL, index == 0 ? "https://example.invalid/art.png" : nil)
            XCTAssertEqual(feed.createdAt, LegacyFixture.date(index))
            // SwiftData to-many relationship order is not part of the contract.
            XCTAssertEqual(Set(feed.episodes.map(\.id)),
                           index == 0 ? Set(LegacyFixture.episodeIDs.prefix(2)) : Set<UUID>())
            XCTAssertEqual(feed.episodes.count, index == 0 ? 2 : 0)
        }

        for index in LegacyFixture.episodeIDs.indices {
            let episode = try XCTUnwrap(episodes.first { $0.id == LegacyFixture.episodeIDs[index] })
            assertExact(episode.title, LegacyFixture.episodeTitles[index])
            assertExact(episode.audioURL, "https://example.invalid/audio-\(index).m4a")
            XCTAssertEqual(episode.pubDate, index == 0 ? LegacyFixture.date(10) : nil)
            XCTAssertEqual(episode.duration, [7200.5, 0, 12.75][index])
            let fields = [episode.localAudioPath, episode.transcriptJSON, episode.summaryMarkdown,
                          episode.takeawaysJSON, episode.chaptersJSON, episode.mindmapJSON,
                          episode.insightsJSON]
            let expected = LegacyFixture.episodePayload(index)
            XCTAssertEqual(fields.count, expected.count)
            for (actual, original) in zip(fields, expected) { assertExact(actual, original) }
        }
        let rich = try XCTUnwrap(episodes.first { $0.id == LegacyFixture.episodeIDs[0] })
        XCTAssertEqual(rich.segments.map(\.start), [0.5, 480.25, 3600])
        XCTAssertEqual(rich.segments.map(\.end), [2.75, 482.5, 3601.25])
        XCTAssertEqual(rich.segments.map(\.text), ["合成開場", "第二段 👋", "e\u{301} 尾段\n保留換行"])
        // Do not compare TranscriptSegment.id: decoding intentionally regenerates it.

        for index in LegacyFixture.noteIDs.indices {
            let snip = try XCTUnwrap(snips.first { $0.id == LegacyFixture.noteIDs[index] })
            XCTAssertEqual(snip.episodeID, LegacyFixture.noteEpisodeIDs[index])
            assertExact(snip.episodeTitle, LegacyFixture.noteTitles[index])
            XCTAssertEqual(snip.atTime, LegacyFixture.noteTimes[index])
            assertExact(snip.text, LegacyFixture.noteTexts[index])
            assertExact(snip.aiNote, LegacyFixture.noteValues[index])
            assertExact(snip.aiError, index == 0 ? firstError : nil)
            XCTAssertEqual(snip.createdAt, LegacyFixture.date(20 + index))
        }
    }
}

// All values are authored. example.invalid URLs and localAudioPath are never opened.
private enum LegacyFixture {
    static let feedIDs = (1...2).map { id(100 + $0) }
    static let episodeIDs = (1...3).map { id(200 + $0) }
    static let noteIDs = (1...4).map { id(300 + $0) }
    static let feedTitles = ["合成 Podcast 🎙️", "沒有集數的合成節目"]
    static let episodeTitles = ["含完整逐字稿的集數", "尚未處理的集數", "未連結 Feed 的集數"]
    static let noteEpisodeIDs: [UUID?] = [episodeIDs[0], episodeIDs[0], nil, episodeIDs[2]]
    static let noteTitles = [episodeTitles[0], episodeTitles[0], "已移除的合成節目", episodeTitles[2]]
    static let noteTimes: [Double] = [480.25, 3600, 0, 12.75]
    static let noteTexts = ["第二段 👋", " 保留空白\n和換行 ", "", "合成空筆記"]
    static let noteValues: [String?] = [
        #"{"note":"既有 JSON 筆記","tags":["合成"]}"#,
        "既有純文字 AI 筆記\n第二行", nil, "",
    ]

    static func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    static func date(_ value: Int) -> Date {
        Date(timeIntervalSince1970: 1_600_000_000.25 + Double(value))
    }

    static func episodePayload(_ index: Int) -> [String?] {
        if index == 1 { return Array(repeating: nil, count: 7) }
        if index == 2 { return Array(repeating: "", count: 7) }
        return [
            "/synthetic-only/not-a-real-file/episode.m4a",
            #"[{"start":0.5,"end":2.75,"text":"合成開場"},{"start":480.25,"end":482.5,"text":"第二段 👋"},{"start":3600,"end":3601.25,"text":"e\u0301 尾段\n保留換行"}]"#,
            "# 合成摘要\n\n保留 Markdown 與原始空白。\n",
            #"["合成重點一","合成重點二"]"#,
            #"[{"start":480.25,"title":"合成章節","summary":"原始摘要"}]"#,
            #"{"label":"合成根節點","children":[{"label":"合成子節點"}]}"#,
            #"{"insights":["合成洞見"],"questions":["合成問題？"]}"#,
        ]
    }

    @MainActor
    static func insert(into context: ModelContext) {
        var episodes: [LegacyPodSnipV1.EpisodeItem] = []
        for index in episodeIDs.indices {
            let episode = LegacyPodSnipV1.EpisodeItem(
                id: episodeIDs[index], title: episodeTitles[index],
                audioURL: "https://example.invalid/audio-\(index).m4a",
                pubDate: index == 0 ? date(10) : nil, duration: [7200.5, 0, 12.75][index])
            let payload = episodePayload(index)
            episode.localAudioPath = payload[0]
            episode.transcriptJSON = payload[1]
            episode.summaryMarkdown = payload[2]
            episode.takeawaysJSON = payload[3]
            episode.chaptersJSON = payload[4]
            episode.mindmapJSON = payload[5]
            episode.insightsJSON = payload[6]
            context.insert(episode)
            episodes.append(episode)
        }
        for index in feedIDs.indices {
            let feed = LegacyPodSnipV1.PodcastFeed(
                id: feedIDs[index], title: feedTitles[index],
                feedURL: "https://example.invalid/feed-\(index).xml",
                artworkURL: index == 0 ? "https://example.invalid/art.png" : nil)
            feed.createdAt = date(index)
            feed.episodes = index == 0 ? Array(episodes.prefix(2)) : []
            context.insert(feed)
        }
        for index in noteIDs.indices {
            let snip = LegacyPodSnipV1.Snip(
                id: noteIDs[index], episodeID: noteEpisodeIDs[index], episodeTitle: noteTitles[index],
                atTime: noteTimes[index], text: noteTexts[index], aiNote: noteValues[index])
            snip.createdAt = date(20 + index)
            context.insert(snip)
        }
    }
}

// Historical source: 8d72603772330660f12638c75691656e597a5fc2/PodSnip/Models.swift.
// Git blob: 5bac94f227dfeddbcd40831335c1312ffb6c5284. Only enclosing scope differs.
// This is intentionally NOT VersionedSchema: the shipped source was unversioned.
// Do not alias current models or derive the legacy schema by removing aiError at runtime.
// scripts/check_legacy_schema.py verifies the frozen source and current additive diff.
enum LegacyPodSnipV1 {
// BEGIN FROZEN LEGACY MODELS
    // MARK: - Transcript

    struct TranscriptSegment: Codable, Identifiable, Hashable {
        var id = UUID()
        var start: Double
        var end: Double
        var text: String

        enum CodingKeys: String, CodingKey { case start, end, text }
    }

    // MARK: - Podcast feed

    @Model
    final class PodcastFeed {
        @Attribute(.unique) var id: UUID
        var title: String
        var feedURL: String
        var artworkURL: String?
        var createdAt: Date
        @Relationship(deleteRule: .cascade) var episodes: [EpisodeItem]

        init(id: UUID = UUID(), title: String, feedURL: String, artworkURL: String? = nil) {
            self.id = id
            self.title = title
            self.feedURL = feedURL
            self.artworkURL = artworkURL
            self.createdAt = Date()
            self.episodes = []
        }
    }

    // MARK: - Episode

    @Model
    final class EpisodeItem {
        @Attribute(.unique) var id: UUID
        var title: String
        var audioURL: String
        var pubDate: Date?
        var duration: Double
        var localAudioPath: String?
        // JSON-encoded [TranscriptSegment]
        var transcriptJSON: String?
        var summaryMarkdown: String?
        // JSON arrays/objects produced by AI
        var takeawaysJSON: String?
        var chaptersJSON: String?
        var mindmapJSON: String?
        var insightsJSON: String?

        init(id: UUID = UUID(), title: String, audioURL: String,
             pubDate: Date? = nil, duration: Double = 0) {
            self.id = id
            self.title = title
            self.audioURL = audioURL
            self.pubDate = pubDate
            self.duration = duration
        }

        var hasTranscript: Bool { transcriptJSON != nil }
        var hasSummary: Bool { summaryMarkdown != nil }

        var segments: [TranscriptSegment] {
            get {
                guard let s = transcriptJSON, let d = s.data(using: .utf8) else { return [] }
                return (try? JSONDecoder().decode([TranscriptSegment].self, from: d)) ?? []
            }
            set {
                transcriptJSON = (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) }
            }
        }
    }

    struct Chapter: Codable, Identifiable {
        var id = UUID()
        var start: Double
        var title: String
        var summary: String?
        enum CodingKeys: String, CodingKey { case start, title, summary }
    }

    struct MindNode: Codable, Identifiable {
        var id = UUID()
        var label: String
        var children: [MindNode]?
        enum CodingKeys: String, CodingKey { case label, children }
    }

    // MARK: - Snip (one-tap capture)

    @Model
    final class Snip {
        @Attribute(.unique) var id: UUID
        var episodeID: UUID?
        var episodeTitle: String
        var atTime: Double
        var text: String
        var aiNote: String?
        var createdAt: Date

        init(id: UUID = UUID(), episodeID: UUID? = nil, episodeTitle: String,
             atTime: Double, text: String, aiNote: String? = nil) {
            self.id = id
            self.episodeID = episodeID
            self.episodeTitle = episodeTitle
            self.atTime = atTime
            self.text = text
            self.aiNote = aiNote
            self.createdAt = Date()
        }
    }
// END FROZEN LEGACY MODELS
}
