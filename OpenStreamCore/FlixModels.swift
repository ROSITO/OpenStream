import Foundation

enum FlixMode: String, Codable, Sendable {
    case season
    case fetch
}

struct FlixItem: Sendable, Hashable, Codable {
    var id: String
    var url: String
    var title: String
    var show: String?
    var season: Int?
    var mode: FlixMode
    var display: String
    var source: String
    var pubDate: String?

    enum CodingKeys: String, CodingKey {
        case id, url, title, show, season, mode, display, source
        case pubDate = "pub_date"
    }
}

struct FlixDigest: Sendable, Codable {
    var updated: String
    var count: Int
    var items: [String: FlixDigestEntry]

    struct FlixDigestEntry: Sendable, Codable {
        var n: Int
        var id: String
        var url: String
        var title: String
        var show: String?
        var season: Int?
        var mode: FlixMode
        var display: String
        var source: String
        var pubDate: String?

        enum CodingKeys: String, CodingKey {
            case n, id, url, title, show, season, mode, display, source
            case pubDate = "pub_date"
        }

        init(from item: FlixItem, n: Int) {
            self.n = n
            self.id = item.id
            self.url = item.url
            self.title = item.title
            self.show = item.show
            self.season = item.season
            self.mode = item.mode
            self.display = item.display
            self.source = item.source
            self.pubDate = item.pubDate
        }

        var asItem: FlixItem {
            FlixItem(
                id: id,
                url: url,
                title: title,
                show: show,
                season: season,
                mode: mode,
                display: display,
                source: source,
                pubDate: pubDate
            )
        }
    }
}

enum FlixTitleParser {
    /// `Show - Saison N` → season mode ; sinon fetch.
    static func parse(_ title: String) -> (show: String?, season: Int?, mode: FlixMode, display: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(.+?)\s*[-–—:]\s*Saison\s*(\d{1,2})\s*$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return (nil, nil, .fetch, trimmed)
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = re.firstMatch(in: trimmed, options: [], range: range),
              match.numberOfRanges >= 3,
              let showR = Range(match.range(at: 1), in: trimmed),
              let seasonR = Range(match.range(at: 2), in: trimmed),
              let season = Int(trimmed[seasonR]),
              season > 0
        else {
            return (nil, nil, .fetch, trimmed)
        }
        let show = String(trimmed[showR]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (show, season, .season, "\(show) — S\(season)")
    }
}
