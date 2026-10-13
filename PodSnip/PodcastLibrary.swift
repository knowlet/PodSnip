import Foundation
import SwiftData

enum LibraryError: LocalizedError {
    case badURL, fetchFailed(String)
    var errorDescription: String? {
        switch self {
        case .badURL: return "RSS 連結格式錯誤。"
        case .fetchFailed(let s): return "抓取失敗：\(s)"
        }
    }
}

/// Feed fetching + audio downloading (pure on-device, no server).
@MainActor
final class PodcastLibrary: ObservableObject {
    @Published var downloads: [UUID: Double] = [:]

    func addFeed(urlString: String, context: ModelContext) async throws -> PodcastFeed {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LibraryError.badURL
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        let parsed = try RSSParser.parse(data: data)
        let feed = PodcastFeed(title: parsed.title, feedURL: urlString, artworkURL: parsed.artworkURL)
        for pe in parsed.episodes {
            feed.episodes.append(EpisodeItem(title: pe.title, audioURL: pe.audioURL,
                                             pubDate: pe.pubDate, duration: pe.duration))
        }
        context.insert(feed)
        try context.save()
        return feed
    }

    func download(_ ep: EpisodeItem) async throws {
        guard let url = URL(string: ep.audioURL) else { throw LibraryError.badURL }
        let dest = Self.localURL(for: ep)
        if FileManager.default.fileExists(atPath: dest.path) {
            ep.localAudioPath = dest.path
            return
        }
        downloads[ep.id] = 0
        defer { downloads.removeValue(forKey: ep.id) }
        let (tmp, _) = try await URLSession.shared.download(from: url)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        ep.localAudioPath = dest.path
    }

    func localAudioURL(for ep: EpisodeItem) -> URL? {
        if let p = ep.localAudioPath, FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        let d = Self.localURL(for: ep)
        if FileManager.default.fileExists(atPath: d.path) { return d }
        return nil
    }

    static func localURL(for ep: EpisodeItem) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("audio-\(ep.id.uuidString).mp3")
    }
}
