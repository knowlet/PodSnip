import Foundation
import SwiftData

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
    var aiError: String?
    var createdAt: Date

    init(id: UUID = UUID(), episodeID: UUID? = nil, episodeTitle: String,
         atTime: Double, text: String, aiNote: String? = nil) {
        self.id = id
        self.episodeID = episodeID
        self.episodeTitle = episodeTitle
        self.atTime = atTime
        self.text = text
        self.aiNote = aiNote
        self.aiError = nil
        self.createdAt = Date()
    }
}
