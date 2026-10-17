import Foundation

/// Référence à une page épisode (pas l’URL média).
struct EpisodeRef: Sendable, Hashable {
    var url: URL
    var show: String?
    var season: Int
    var episode: Int
    var title: String?

    /// Ex. `Friends S01E04`.
    var displayTitle: String {
        let showPart: String = {
            if let show, !show.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return show.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return "Show"
        }()
        return String(format: "%@ S%02dE%02d", showPart, season, episode)
    }

    var paddedSeason: String { String(format: "%02d", season) }
    var paddedEpisode: String { String(format: "%02d", episode) }
}

/// Énumère les pages épisode d’une saison (pattern URL type MOVIX + liens DOM).
enum EpisodeEnumerator {
    static let defaultMaxEpisodes = 40
    static let consecutiveMissLimit = 2

    /// Match `.../tv/{id}/s/{season}/e/{episode}` ou sans `/e/`.
    struct PathMatch: Sendable, Hashable {
        var showId: String
        var season: Int
        var episode: Int?
    }

    static func parseWatchPath(_ url: URL) -> PathMatch? {
        let parts = url.pathComponents.filter { $0 != "/" }
        // … tv <id> s <season> [e <episode>]
        guard let tvIdx = parts.firstIndex(where: { $0.lowercased() == "tv" }),
              tvIdx + 3 < parts.count,
              parts[tvIdx + 2].lowercased() == "s",
              let season = Int(parts[tvIdx + 3]), season > 0
        else { return nil }

        let showId = parts[tvIdx + 1]
        guard !showId.isEmpty else { return nil }

        var episode: Int?
        if tvIdx + 5 < parts.count, parts[tvIdx + 4].lowercased() == "e",
           let ep = Int(parts[tvIdx + 5]), ep > 0 {
            episode = ep
        }
        return PathMatch(showId: showId, season: season, episode: episode)
    }

    /// Construit l’URL épisode en remplaçant / ajoutant `/e/{n}`.
    static func episodeURL(from pageURL: URL, season: Int, episode: Int) -> URL? {
        guard parseWatchPath(pageURL) != nil else { return nil }
        var parts = pageURL.pathComponents.filter { $0 != "/" }
        guard let tvIdx = parts.firstIndex(where: { $0.lowercased() == "tv" }),
              tvIdx + 3 < parts.count
        else { return nil }

        // Tronquer après s/<season>
        parts = Array(parts.prefix(tvIdx + 4))
        parts[tvIdx + 3] = String(season)
        parts.append("e")
        parts.append(String(episode))

        var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)
        components?.path = "/" + parts.joined(separator: "/")
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }

    /// Génère des candidats e=1…max sans sonder le réseau.
    static func expandWatchCandidates(
        pageURL: URL,
        season: Int,
        show: String?,
        maxEpisodes: Int = defaultMaxEpisodes
    ) -> [EpisodeRef] {
        (1...max(1, maxEpisodes)).compactMap { ep in
            guard let url = episodeURL(from: pageURL, season: season, episode: ep) else { return nil }
            return EpisodeRef(url: url, show: show, season: season, episode: ep, title: nil)
        }
    }

    /// Sonde HEAD/GET léger jusqu’à `consecutiveMissLimit` échecs d’affilée.
    static func probeWatchSeason(
        pageURL: URL,
        season: Int,
        show: String?,
        maxEpisodes: Int = defaultMaxEpisodes,
        consecutiveMissLimit: Int = consecutiveMissLimit,
        session: URLSession = .shared
    ) async -> [EpisodeRef] {
        let candidates = expandWatchCandidates(
            pageURL: pageURL,
            season: season,
            show: show,
            maxEpisodes: maxEpisodes
        )
        var found: [EpisodeRef] = []
        var misses = 0
        for ref in candidates {
            let ok = await isReachableEpisodePage(ref.url, session: session)
            if ok {
                found.append(ref)
                misses = 0
            } else {
                misses += 1
                if misses >= consecutiveMissLimit, !found.isEmpty { break }
                // Si rien encore trouvé et miss au début, continuer un peu
                if found.isEmpty, ref.episode >= 5 { break }
            }
        }
        return found
    }

    private static func isReachableEpisodePage(_ url: URL, session: URLSession) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        request.setValue(DownloadCredentials.default.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            if http.statusCode == 405 || http.statusCode == 501 {
                return await isReachableViaGET(url, session: session)
            }
            return (200..<400).contains(http.statusCode)
        } catch {
            return await isReachableViaGET(url, session: session)
        }
    }

    private static func isReachableViaGET(_ url: URL, session: URLSession) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue(DownloadCredentials.default.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<400).contains(http.statusCode)
        } catch {
            return false
        }
    }

    /// Parse le résultat JS `{ links: [{ href, text }] }`.
    static func parseDOMLinks(
        baseURL: URL,
        links: [(href: String, text: String)],
        defaultSeason: Int?,
        showHint: String?
    ) -> [EpisodeRef] {
        var byEpisode: [Int: EpisodeRef] = [:]
        let fallbackSeason = defaultSeason ?? parseWatchPath(baseURL)?.season ?? 1

        for link in links {
            guard let absolute = URL(string: link.href, relativeTo: baseURL)?.absoluteURL else { continue }
            guard absolute.host() == baseURL.host() else { continue }

            let blob = (link.text + " " + absolute.path).lowercased()
            guard looksLikeEpisodeLink(blob, path: absolute.path) else { continue }

            let season = extractSeason(from: absolute, text: link.text) ?? fallbackSeason
            guard let episode = extractEpisode(from: absolute, text: link.text), episode > 0 else { continue }

            let ref = EpisodeRef(
                url: absolute,
                show: showHint,
                season: season,
                episode: episode,
                title: link.text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            )
            // Garde le premier (souvent le plus propre) ; écrase si URL plus « watch »
            if byEpisode[episode] == nil || absolute.path.contains("/e/") || absolute.path.contains("/watch/") {
                byEpisode[episode] = ref
            }
        }

        return byEpisode.keys.sorted().compactMap { byEpisode[$0] }
    }

    static func looksLikeEpisodeLink(_ blob: String, path: String) -> Bool {
        if path.range(of: #"/e/\d+"#, options: .regularExpression) != nil { return true }
        if path.range(of: #"/episode/\d+"#, options: .regularExpression) != nil { return true }
        if blob.range(of: #"s\d{1,2}e\d{1,3}"#, options: .regularExpression) != nil { return true }
        if blob.range(of: #"épisode\s*\d+"#, options: .regularExpression) != nil { return true }
        if blob.range(of: #"episode\s*\d+"#, options: .regularExpression) != nil { return true }
        if blob.range(of: #"ep\.?\s*\d+"#, options: .regularExpression) != nil { return true }
        return false
    }

    static func extractSeason(from url: URL, text: String) -> Int? {
        if let m = parseWatchPath(url)?.season { return m }
        let blob = text + " " + url.path
        return firstInt(in: blob, pattern: #"s(?:aison)?[\s._-]*(\d{1,2})"#)
    }

    static func extractEpisode(from url: URL, text: String) -> Int? {
        if let ep = parseWatchPath(url)?.episode { return ep }
        let path = url.path
        if let n = firstInt(in: path, pattern: #"/e/(\d+)"#) { return n }
        if let n = firstInt(in: path, pattern: #"/episode/(\d+)"#) { return n }
        let blob = text + " " + path
        if let n = firstInt(in: blob, pattern: #"s\d{1,2}e(\d{1,3})"#) { return n }
        for pattern in [#"épisode\s*(\d+)"#, #"episode\s*(\d+)"#, #"ep\.?\s*(\d+)"#] {
            if let n = firstInt(in: blob, pattern: pattern) { return n }
        }
        return nil
    }

    /// Premier groupe de capture numérique d’un pattern (case insensitive).
    static func firstInt(in text: String, pattern: String) -> Int? {
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

    /// Fusionne listes (par numéro d’épisode), préférant les URLs watch path.
    static func merge(_ primary: [EpisodeRef], _ secondary: [EpisodeRef]) -> [EpisodeRef] {
        var map: [Int: EpisodeRef] = [:]
        for ref in secondary + primary {
            if let existing = map[ref.episode] {
                let preferNew = ref.url.path.contains("/e/") && !existing.url.path.contains("/e/")
                if preferNew { map[ref.episode] = ref }
            } else {
                map[ref.episode] = ref
            }
        }
        return map.keys.sorted().compactMap { map[$0] }
    }

    // MARK: - French Stream (`/data/eps_{newsid}.txt`)

    /// `newsid` depuis `?newsid=` ou chemin numérique.
    static func extractNewsID(from url: URL) -> String? {
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in items where item.name.lowercased() == "newsid" {
                if let v = item.value, v.range(of: #"^\d+$"#, options: .regularExpression) != nil {
                    return v
                }
            }
        }
        if let m = url.path.range(of: #"(\d{5,})"#, options: .regularExpression) {
            return String(url.path[m])
        }
        return nil
    }

    /// URLs catalogue épisodes FS (même contenu sous plusieurs chemins).
    static func frenchStreamCatalogURLs(pageURL: URL, newsID: String) -> [URL] {
        guard let host = pageURL.host() else { return [] }
        let scheme = pageURL.scheme ?? "https"
        let root = "\(scheme)://\(host)"
        return [
            URL(string: "\(root)/data/eps_\(newsID).txt"),
            URL(string: "\(root)/static/series/\(newsID).js"),
            URL(string: "\(root)/ep-data.php?id=\(newsID)&format=js"),
            URL(string: "\(root)/data/eps_\(newsID).txt?v=1")
        ].compactMap { $0 }
    }

    /// Ordre de préférence des lecteurs embed (vidzy détecte mieux en headless que fsvid/premium).
    static let frenchStreamPlayerPreference = [
        "vidzy", "premium", "uqload", "voe", "netu", "dood", "filemoon", "upstream"
    ]

    /// Parse le JSON FS `{ "vf": { "1": { "vidzy": "https://…" } }, … }`.
    static func parseFrenchStreamCatalog(
        data: Data,
        season: Int,
        show: String?,
        preferredVersion: String = "vf"
    ) -> [EpisodeRef] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let versionKeys = [preferredVersion, "vf", "vostfr", "vo"].uniqued()
        var versionMap: [String: Any]?
        for key in versionKeys {
            if let map = root[key] as? [String: Any], !map.isEmpty {
                versionMap = map
                break
            }
        }
        guard let versionMap else { return [] }

        var refs: [EpisodeRef] = []
        let sortedKeys = versionMap.keys.compactMap { Int($0) }.sorted()
        for epNum in sortedKeys {
            guard let players = versionMap[String(epNum)] as? [String: Any] else { continue }
            guard let embed = pickFrenchStreamPlayer(players) else { continue }
            refs.append(
                EpisodeRef(
                    url: embed,
                    show: show,
                    season: season,
                    episode: epNum,
                    title: nil
                )
            )
        }
        return refs
    }

    static func pickFrenchStreamPlayer(_ players: [String: Any]) -> URL? {
        for key in frenchStreamPlayerPreference {
            if let raw = players[key] as? String,
               let url = URL(string: raw),
               let scheme = url.scheme?.lowercased(),
               ["http", "https"].contains(scheme) {
                return url
            }
        }
        for (_, value) in players {
            guard let raw = value as? String,
                  let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme)
            else { continue }
            return url
        }
        return nil
    }

    /// Télécharge le premier catalogue FS joignable.
    static func fetchFrenchStreamEpisodes(
        pageURL: URL,
        season: Int,
        show: String?,
        preferredVersion: String = "vf",
        session: URLSession = .shared
    ) async -> [EpisodeRef] {
        guard let newsID = extractNewsID(from: pageURL) else { return [] }
        let candidates = frenchStreamCatalogURLs(pageURL: pageURL, newsID: newsID)
        for catalogURL in candidates {
            var request = URLRequest(url: catalogURL)
            request.timeoutInterval = 12
            request.setValue(DownloadCredentials.default.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    continue
                }
                let refs = parseFrenchStreamCatalog(
                    data: data,
                    season: season,
                    show: show,
                    preferredVersion: preferredVersion
                )
                if !refs.isEmpty { return refs }
            } catch {
                continue
            }
        }
        return []
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
