import Foundation

struct ParsedEpisode {
    var title: String
    var audioURL: String
    var pubDate: Date?
    var duration: Double
}

struct ParsedFeed {
    var title: String
    var artworkURL: String?
    var episodes: [ParsedEpisode]
}

final class RSSParser: NSObject, XMLParserDelegate {
    private var feedTitle = ""
    private var artworkURL: String?
    private var episodes: [ParsedEpisode] = []

    private var inItem = false
    private var currentText = ""
    private var itemTitle = ""
    private var itemEnclosure = ""
    private var itemPubDate: String?
    private var itemDuration: String?

    private var inTitle = false
    private var inPubDate = false
    private var inDuration = false

    static func parse(data: Data) throws -> ParsedFeed {
        let p = RSSParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw NSError(domain: "RSSParser", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: parser.parserError?.localizedDescription ?? "parse failed"])
        }
        return ParsedFeed(title: p.feedTitle.isEmpty ? "Unknown Podcast" : p.feedTitle,
                          artworkURL: p.artworkURL,
                          episodes: p.episodes)
    }

    func parser(_ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attrs: [String: String] = [:]) {
        let local = name.components(separatedBy: ":").last ?? name
        switch local {
        case "item": inItem = true; itemTitle = ""; itemEnclosure = ""; itemPubDate = nil; itemDuration = nil
        case "title": inTitle = true; currentText = ""
        case "enclosure":
            if inItem, let url = attrs["url"], !url.isEmpty { itemEnclosure = url }
        case "pubDate": inPubDate = true; currentText = ""
        case "duration": inDuration = true; currentText = ""
        case "image":
            if !inItem, let href = attrs["href"] { artworkURL = href }
            else if let url = attrs["url"], artworkURL == nil, !inItem { artworkURL = url }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters s: String) {
        if inTitle || inPubDate || inDuration { currentText += s }
    }

    func parser(_ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let local = name.components(separatedBy: ":").last ?? name
        switch local {
        case "title":
            if inTitle {
                if inItem { itemTitle = currentText.trimmingCharacters(in: .whitespacesAndNewlines) }
                else if feedTitle.isEmpty { feedTitle = currentText.trimmingCharacters(in: .whitespacesAndNewlines) }
                inTitle = false
            }
        case "pubDate": if inPubDate { itemPubDate = currentText; inPubDate = false }
        case "duration": if inDuration { itemDuration = currentText; inDuration = false }
        case "item":
            inItem = false
            if !itemEnclosure.isEmpty {
                episodes.append(ParsedEpisode(
                    title: itemTitle.isEmpty ? "(untitled)" : itemTitle,
                    audioURL: itemEnclosure,
                    pubDate: Self.parseDate(itemPubDate),
                    duration: Self.parseDuration(itemDuration)))
            }
        default: break
        }
    }

    static func parseDate(_ s: String?) -> Date? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        let fmts = ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm:ss Z",
                    "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ssZ"]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for f in fmts { df.dateFormat = f; if let d = df.date(from: s) { return d } }
        return nil
    }

    static func parseDuration(_ s: String?) -> Double {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return 0 }
        if let v = Double(s) { return v }
        let parts = s.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        default: return 0
        }
    }
}
