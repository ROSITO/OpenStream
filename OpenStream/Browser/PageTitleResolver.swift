import Foundation

/// Nettoie / choisit un titre de **contenu** (film, série, épisode) — pas le nom du site.
enum PageTitleResolver {
    struct Candidate: Sendable, Hashable {
        var text: String
        var source: String
    }

    private static let junkExact: Set<String> = [
        "OpenStream",
        "about:blank",
        "Blank",
        "New Tab",
        "Untitled",
        "Sans titre",
        "Home",
        "Accueil",
        "Watch",
        "Streaming",
        "Voir",
        "Lecture"
    ]

    /// Priorité des sources DOM (plus haut = mieux).
    private static let sourceScore: [String: Int] = [
        "jsonld": 100,
        "og": 90,
        "twitter": 85,
        "itemprop": 80,
        "h1": 70,
        "player": 65,
        "video": 60,
        "document": 20,
        "url": 10
    ]

    static func usefulTitle(_ raw: String?, host: String? = nil) -> String? {
        guard let cleaned = clean(raw, host: host), !cleaned.isEmpty else { return nil }
        return cleaned
    }

    /// Meilleur titre parmi des candidats DOM + fallbacks URL.
    static func title(
        candidates: [Candidate] = [],
        pageTitle: String? = nil,
        pageURL: URL?,
        mediaURL: URL
    ) -> String {
        let host = pageURL?.host() ?? mediaURL.host()
        var pool = candidates
        if let pageTitle {
            pool.append(Candidate(text: pageTitle, source: "document"))
        }
        if let pageURL, let fromPage = usefulTitle(fromURL: pageURL) {
            pool.append(Candidate(text: fromPage, source: "url"))
        }
        if let fromMedia = usefulTitle(fromURL: mediaURL) {
            pool.append(Candidate(text: fromMedia, source: "url"))
        }

        let ranked = pool.compactMap { candidate -> (Candidate, Int)? in
            guard let text = clean(candidate.text, host: host) else { return nil }
            var score = sourceScore[candidate.source, default: 30]
            score += min(text.count, 80) // favorise un vrai intitulé
            if looksLikeSiteBrand(text, host: host) { return nil }
            if looksGenericWatchWord(text) { score -= 40 }
            return (Candidate(text: text, source: candidate.source), score)
        }
        .sorted { $0.1 > $1.1 }

        if let best = ranked.first?.0.text {
            return best
        }
        if let pageURL, let t = usefulTitle(fromURL: pageURL) { return t }
        if let t = usefulTitle(fromURL: mediaURL) { return t }
        return mediaURL.host() ?? "video"
    }

    /// Compat : ancien chemin (titre unique).
    static func title(
        pageTitle: String?,
        pageURL: URL?,
        mediaURL: URL
    ) -> String {
        title(candidates: [], pageTitle: pageTitle, pageURL: pageURL, mediaURL: mediaURL)
    }

    static func usefulTitle(fromURL url: URL) -> String? {
        let host = url.host()
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        // Préférer un segment de path “parlant” (watch/film/slug)
        for part in parts.reversed() {
            var name = part
            let mediaExt: Set<String> = [
                "m3u8", "mpd", "mp4", "m4v", "webm", "mov", "m4s", "ts", "aac", "mp3", "html", "php"
            ]
            let ext = (name as NSString).pathExtension.lowercased()
            if mediaExt.contains(ext) {
                name = (name as NSString).deletingPathExtension
            }
            if looksOpaque(name) { continue }
            if ["watch", "movie", "film", "video", "embed", "player", "stream", "episode", "saison", "season", "voir"].contains(name.lowercased()) {
                continue
            }
            name = name.replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "+", with: " ")
            name = name.removingPercentEncoding ?? name
            if let useful = usefulTitle(name, host: host), !looksLikeSiteBrand(useful, host: host) {
                return useful
            }
        }
        return nil
    }

    /// Le titre ressemble-t-il seulement au nom de domaine / marque du site ?
    static func looksLikeSiteBrand(_ title: String, host: String?) -> Bool {
        guard let host else { return false }
        let brandTokens = brandTokens(fromHost: host)
        let titleNorm = normalizeToken(title)
        if titleNorm.isEmpty { return true }
        for brand in brandTokens {
            if titleNorm == brand { return true }
            // "Voiranime Streaming" ≈ brand
            if titleNorm.hasPrefix(brand), titleNorm.count <= brand.count + 12 {
                return true
            }
            if brand.hasPrefix(titleNorm), titleNorm.count >= 4 {
                return true
            }
        }
        return false
    }

    // MARK: - Private

    private static func clean(_ raw: String?, host: String?) -> String? {
        guard var title = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if junkExact.contains(title) { return nil }
        if title.caseInsensitiveCompare("openstream") == .orderedSame { return nil }

        title = stripSiteDecorations(title, host: host)

        if junkExact.contains(title) { return nil }
        if looksLikeSiteBrand(title, host: host) { return nil }
        if title.count < 2 { return nil }
        return String(title.prefix(160))
    }

    /// "Film | Site" ou "Site - Film" → garder le côté contenu.
    private static func stripSiteDecorations(_ raw: String, host: String?) -> String {
        let separators = [" — ", " – ", " - ", " | ", " · ", " • ", " / "]
        for separator in separators {
            guard let range = raw.range(of: separator) else { continue }
            let left = String(raw[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let right = String(raw[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard left.count >= 2, right.count >= 2 else { continue }

            let leftBrand = looksLikeSiteBrand(left, host: host) || looksGenericWatchWord(left)
            let rightBrand = looksLikeSiteBrand(right, host: host) || looksGenericWatchWord(right)

            if leftBrand && !rightBrand { return right }
            if rightBrand && !leftBrand { return left }
            // Les deux OK : préférer le plus long (souvent le titre du film)
            return left.count >= right.count ? left : right
        }
        return raw
    }

    private static func looksGenericWatchWord(_ title: String) -> Bool {
        let t = title.lowercased()
        let generics = ["streaming", "watch online", "voir en streaming", "regarder", "free streaming"]
        return generics.contains(where: { t == $0 || t.hasPrefix($0) })
    }

    private static func brandTokens(fromHost host: String) -> [String] {
        var host = host.lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let labels = host.split(separator: ".").map(String.init)
        // drop tld
        let meaningful = labels.count >= 2 ? Array(labels.dropLast()) : labels
        var tokens: [String] = []
        for label in meaningful {
            let norm = normalizeToken(label)
            if norm.count >= 3 { tokens.append(norm) }
            // "voiranime" → aussi tenter sans préfixe courant
            for prefix in ["voir", "watch", "stream", "play", "my", "the"] {
                if norm.hasPrefix(prefix), norm.count - prefix.count >= 3 {
                    tokens.append(String(norm.dropFirst(prefix.count)))
                }
            }
        }
        return Array(Set(tokens))
    }

    private static func normalizeToken(_ value: String) -> String {
        value.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func looksOpaque(_ name: String) -> Bool {
        if name.count >= 24, name.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            return true
        }
        if name.count >= 20, name.rangeOfCharacter(from: .letters) == nil {
            return true
        }
        return false
    }
}
