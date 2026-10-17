import Foundation

enum SeasonResolveError: LocalizedError {
    case usage
    case notFound(show: String, season: Int, bookmarkTitles: String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: openstream-cli season <showName|pageURL> [--season N] [--show NAME]"
        case .notFound(let show, let season, let titles):
            return "Saison introuvable pour « \(show) » S\(season) dans les favoris [\(titles)]"
        }
    }
}

/// Résout une page saison à partir d’un titre + favoris OpenStream (sites ou pages).
enum SeasonResolver {
    struct Hit: Sendable, Hashable {
        var pageURL: URL
        var show: String
        var season: Int
        var source: String // "bookmark" | "search:<host>"
    }

    struct BookmarkEntry: Sendable, Hashable, Codable {
        var title: String
        var url: URL
    }

    /// Charge `Application Support/OpenStream/bookmarks.json` (ou `--shared-db` root).
    static func loadBookmarks(supportRoot: URL? = nil) -> [BookmarkEntry] {
        let root = supportRoot
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OpenStream", isDirectory: true)
        guard let root else { return [] }
        let file = root.appendingPathComponent("bookmarks.json")
        guard let data = try? Data(contentsOf: file),
              let rows = try? JSONDecoder().decode([BookmarkEntry].self, from: data)
        else {
            // Format SiteBookmark (id, dates…) — decoder souple
            return loadBookmarksLoose(from: file)
        }
        return rows
    }

    private static func loadBookmarksLoose(from file: URL) -> [BookmarkEntry] {
        guard let data = try? Data(contentsOf: file),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr.compactMap { row in
            guard let title = row["title"] as? String,
                  let urlString = row["url"] as? String,
                  let url = URL(string: urlString)
            else { return nil }
            return BookmarkEntry(title: title, url: url)
        }
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Favori dont le titre matche déjà la série (+ saison optionnelle).
    static func matchBookmark(
        show: String,
        season: Int,
        bookmarks: [BookmarkEntry]
    ) -> Hit? {
        let showN = normalize(show)
        guard !showN.isEmpty else { return nil }

        var best: (Hit, Int)?
        for bm in bookmarks {
            let titleN = normalize(bm.title)
            guard titleN.contains(showN) || showN.contains(titleN) else { continue }
            let seasonInTitle = firstInt(in: bm.title, pattern: #"saison\s*(\d+)"#)
                ?? firstInt(in: bm.title, pattern: #"\bs(\d{1,2})\b"#)
            // Page saison explicite
            if let s = seasonInTitle, s == season {
                let hit = Hit(pageURL: bm.url, show: show, season: season, source: "bookmark")
                let score = 100 + (titleN == "\(showN) - saison \(season)" ? 10 : 0)
                if best == nil || score > best!.1 { best = (hit, score) }
                continue
            }
            // Titre = nom série exact, URL déjà une page newsid (pas homepage)
            if seasonInTitle == nil,
               titleN == showN || titleN.hasPrefix(showN + " "),
               EpisodeEnumerator.extractNewsID(from: bm.url) != nil {
                let hit = Hit(pageURL: bm.url, show: show, season: season, source: "bookmark")
                if best == nil || 80 > best!.1 { best = (hit, 80) }
            }
        }
        return best?.0
    }

    /// Sites favoris « racines » (homepage) sur lesquels chercher.
    static func searchRoots(from bookmarks: [BookmarkEntry]) -> [URL] {
        bookmarks.compactMap { bm -> URL? in
            // Skip si déjà une page newsid ciblée
            if EpisodeEnumerator.extractNewsID(from: bm.url) != nil { return nil }
            guard let host = bm.url.host() else { return nil }
            let scheme = bm.url.scheme ?? "https"
            return URL(string: "\(scheme)://\(host)/")
        }
        // dédup par host
        .reduce(into: [String: URL]()) { acc, url in
            if let h = url.host() { acc[h] = url }
        }
        .values
        .sorted { ($0.host() ?? "") < ($1.host() ?? "") }
    }

    /// Parse résultats HTML type DLE / French Stream.
    static func parseSearchHTML(
        _ html: String,
        baseURL: URL,
        show: String,
        season: Int
    ) -> Hit? {
        let showN = normalize(show)
        let re = try? NSRegularExpression(
            pattern: #"newsid=(\d+)[\s\S]{0,600}?([A-Za-z0-9À-ÿ][^<>]{1,80}?)\s*[-–—]\s*Saison\s*(\d+)"#,
            options: [.caseInsensitive]
        )
        guard let re else { return nil }
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        var candidates: [(Hit, Int)] = []
        re.enumerateMatches(in: html, options: [], range: range) { match, _, _ in
            guard let match,
                  match.numberOfRanges >= 4,
                  let idR = Range(match.range(at: 1), in: html),
                  let titleR = Range(match.range(at: 2), in: html),
                  let seasonR = Range(match.range(at: 3), in: html),
                  let seasonNum = Int(html[seasonR]),
                  seasonNum == season
            else { return }
            let newsID = String(html[idR])
            var title = String(html[titleR])
            title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // strip noise prefixes from HTML crumbs
            if let last = title.components(separatedBy: ">").last {
                title = last.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let titleN = normalize(title)
            guard titleN.contains(showN) || showN.contains(titleN) else { return }
            guard let page = seasonPageURL(hostBase: baseURL, newsID: newsID) else { return }
            let score = titleN == "\(showN) - saison \(season)" ? 100 : (titleN.hasPrefix(showN) ? 80 : 50)
            let hit = Hit(
                pageURL: page,
                show: show,
                season: season,
                source: "search:\(baseURL.host() ?? "?")"
            )
            candidates.append((hit, score))
        }
        return candidates.max(by: { $0.1 < $1.1 })?.0
    }

    static func seasonPageURL(hostBase: URL, newsID: String) -> URL? {
        guard let host = hostBase.host() else { return nil }
        let scheme = hostBase.scheme ?? "https"
        return URL(string: "\(scheme)://\(host)/index.php?newsid=\(newsID)")
    }

    static func dleSearchURL(root: URL, query: String) -> URL? {
        guard let host = root.host() else { return nil }
        let scheme = root.scheme ?? "https"
        var components = URLComponents(string: "\(scheme)://\(host)/")
        components?.queryItems = [
            URLQueryItem(name: "do", value: "search"),
            URLQueryItem(name: "subaction", value: "search"),
            URLQueryItem(name: "story", value: query)
        ]
        return components?.url
    }

    /// Recherche sur un site favori (DLE/FS).
    static func searchOnSite(
        root: URL,
        show: String,
        season: Int,
        session: URLSession = .shared
    ) async -> Hit? {
        let queries = [
            "\(show) Saison \(season)",
            "\(show) - Saison \(season)",
            show
        ]
        for q in queries {
            guard let searchURL = dleSearchURL(root: root, query: q) else { continue }
            var request = URLRequest(url: searchURL)
            request.timeoutInterval = 15
            request.setValue(DownloadCredentials.default.userAgent, forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode),
                      let html = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1)
                else { continue }
                if let hit = parseSearchHTML(html, baseURL: root, show: show, season: season) {
                    return hit
                }
            } catch {
                continue
            }
        }
        return nil
    }

    /// Point d’entrée : favori page → sinon recherche sur sites favoris.
    static func resolve(
        show: String,
        season: Int,
        supportRoot: URL? = nil,
        session: URLSession = .shared
    ) async -> Hit? {
        let bookmarks = loadBookmarks(supportRoot: supportRoot)
        if let direct = matchBookmark(show: show, season: season, bookmarks: bookmarks) {
            return direct
        }
        let roots = searchRoots(from: bookmarks)
        for root in roots {
            if let hit = await searchOnSite(root: root, show: show, season: season, session: session) {
                return hit
            }
        }
        return nil
    }

    private static func firstInt(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let swiftRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return Int(text[swiftRange])
    }
}
