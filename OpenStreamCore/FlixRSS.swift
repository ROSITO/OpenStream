import Foundation

/// Scan RSS DLE (`/engine/rss.php`) des hubs favoris.
enum FlixRSS {
    struct Hub: Sendable, Hashable {
        var origin: URL
        var title: String
    }

    /// Origins hub (homepage) depuis favoris — ignore les pages `newsid=`.
    static func hubs(from bookmarks: [SeasonResolver.BookmarkEntry]) -> [Hub] {
        var byHost: [String: Hub] = [:]
        for bm in bookmarks {
            if EpisodeEnumerator.extractNewsID(from: bm.url) != nil { continue }
            guard let host = bm.url.host()?.lowercased(), !host.isEmpty else { continue }
            let scheme = bm.url.scheme ?? "https"
            guard let origin = URL(string: "\(scheme)://\(host)/") else { continue }
            if byHost[host] == nil {
                byHost[host] = Hub(origin: origin, title: bm.title)
            }
        }
        return byHost.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func rssURL(for origin: URL) -> URL? {
        guard let host = origin.host() else { return nil }
        let scheme = origin.scheme ?? "https"
        return URL(string: "\(scheme)://\(host)/engine/rss.php")
    }

    /// Réécrit le host du lien vers celui du favori (RSS miroir → hub bookmarqué).
    static func normalizeLink(_ link: String, hubOrigin: URL) -> URL? {
        guard var components = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              let hubHost = hubOrigin.host()
        else { return nil }
        let scheme = (hubOrigin.scheme ?? components.scheme ?? "https").lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        components.scheme = scheme
        components.host = hubHost
        return components.url
    }

    static func fetchItems(
        hub: Hub,
        session: URLSession = .shared
    ) async throws -> [FlixItem] {
        guard let rss = rssURL(for: hub.origin) else { return [] }
        var request = URLRequest(url: rss)
        request.timeoutInterval = 20
        request.setValue(DownloadCredentials.default.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
            throw FlixError.rssHTTP(hub: hub.title, status: http.statusCode)
        }
        let text = decodeRSSText(data)
        let raw = parseRSS(text)
        if raw.isEmpty {
            // 404 HTML / SPA → traité comme hub sans RSS
            if text.localizedCaseInsensitiveContains("<html") {
                throw FlixError.rssUnavailable(hub: hub.title)
            }
        }
        return raw.compactMap { entry -> FlixItem? in
            guard let url = normalizeLink(entry.link, hubOrigin: hub.origin) else { return nil }
            let id = normalizeLink(entry.guid.isEmpty ? entry.link : entry.guid, hubOrigin: hub.origin)?
                .absoluteString ?? url.absoluteString
            let parsed = FlixTitleParser.parse(entry.title)
            return FlixItem(
                id: id,
                url: url.absoluteString,
                title: entry.title,
                show: parsed.show,
                season: parsed.season,
                mode: parsed.mode,
                display: parsed.display,
                source: hub.title,
                pubDate: entry.pubDate.isEmpty ? nil : entry.pubDate
            )
        }
    }

    // MARK: - Parse

    struct RawEntry: Sendable {
        var title: String
        var link: String
        var guid: String
        var pubDate: String
    }

    static func decodeRSSText(_ data: Data) -> String {
        var bytes = data
        // BOM UTF-8
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            bytes = bytes.dropFirst(3)
        }
        return String(data: bytes, encoding: .utf8)
            ?? String(data: bytes, encoding: .isoLatin1)
            ?? ""
    }

    static func parseRSS(_ xml: String) -> [RawEntry] {
        let parser = RSSParser()
        return parser.parse(xml)
    }

    private final class RSSParser: NSObject, XMLParserDelegate {
        private var entries: [RawEntry] = []
        private var current: RawEntry?
        private var element = ""
        private var text = ""

        func parse(_ xml: String) -> [RawEntry] {
            guard let data = xml.data(using: .utf8) else { return [] }
            let p = XMLParser(data: data)
            p.delegate = self
            p.shouldProcessNamespaces = false
            _ = p.parse()
            return entries
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            element = elementName.lowercased()
            text = ""
            if element == "item" {
                current = RawEntry(title: "", link: "", guid: "", pubDate: "")
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let name = elementName.lowercased()
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { text = ""; element = "" }
            guard var cur = current else { return }
            switch name {
            case "title": cur.title = value
            case "link": cur.link = value
            case "guid": cur.guid = value
            case "pubdate": cur.pubDate = value
            case "item":
                if !cur.title.isEmpty, !cur.link.isEmpty {
                    entries.append(cur)
                }
                current = nil
                return
            default:
                return
            }
            current = cur
        }
    }
}

enum FlixError: LocalizedError {
    case usage(String)
    case rssHTTP(hub: String, status: Int)
    case rssUnavailable(hub: String)
    case noHubs
    case pickMissing(String)
    case digestEmpty

    var errorDescription: String? {
        switch self {
        case .usage(let s): return s
        case .rssHTTP(let hub, let status): return "Flix: RSS \(hub) HTTP \(status)"
        case .rssUnavailable(let hub): return "Flix: pas de RSS pour \(hub) (skip)"
        case .noHubs: return "Flix: aucun hub favori (homepage) trouvé"
        case .pickMissing(let s): return "Flix: entrée introuvable (\(s)) — lance `flix digest` d’abord"
        case .digestEmpty: return "Flix: digest vide"
        }
    }
}
