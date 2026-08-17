import Foundation

/// Presets de nomenclature d’export (Film / Série / plat / custom).
enum ExportNamingPreset: String, CaseIterable, Identifiable, Sendable, Codable {
    case flat
    case jellyfinMovie
    case jellyfinSeries
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flat: return "Fichier plat"
        case .jellyfinMovie: return "Film"
        case .jellyfinSeries: return "Série"
        case .custom: return "Personnalisé"
        }
    }

    var template: String {
        switch self {
        case .flat:
            return "{title}.{ext}"
        case .jellyfinMovie:
            // Film (2020)/Film.mp4
            return "{title} ({year})/{title}.{ext}"
        case .jellyfinSeries:
            // MaSerie/Saison 01/S01E01.mp4
            return "{show}/Saison {season}/S{season}E{episode}.{ext}"
        case .custom:
            return "{title} ({year})/{title}.{ext}"
        }
    }

    var hint: String {
        switch self {
        case .flat:
            return "Un seul fichier : Titre.mp4 dans le dossier d’export."
        case .jellyfinMovie:
            return "Film (2020)/Film.mp4 — dossier = nom + année, fichier = nom."
        case .jellyfinSeries:
            return "Série/Saison 01/S01E01.mp4 — renseignez série, saison et épisode."
        case .custom:
            return "Tokens : {title} {year} {show} {season} {episode} {episode_title} {kind} {ext}"
        }
    }

    /// Présets proposés au téléchargement (hors custom global).
    static var downloadChoices: [ExportNamingPreset] {
        [.jellyfinMovie, .jellyfinSeries, .flat]
    }
}

struct ExportMetadata: Sendable, Hashable {
    var title: String?
    var year: String?
    var show: String?
    var season: String?
    var episode: String?
    var episodeTitle: String?
    /// Surcharge le modèle global (Film / Série / plat) pour ce téléchargement.
    var namingPreset: ExportNamingPreset?

    static func inferred(from displayTitle: String) -> ExportMetadata {
        let parsed = ExportNaming.parseTitleAndYear(from: displayTitle)
        return ExportMetadata(title: parsed.title, year: parsed.year)
    }
}

struct ExportNamingContext: Sendable, Hashable {
    var title: String
    var year: String?
    var show: String?
    var season: String?
    var episode: String?
    var episodeTitle: String?
    var kind: String
    var ext: String

    init(
        title: String,
        year: String? = nil,
        show: String? = nil,
        season: String? = nil,
        episode: String? = nil,
        episodeTitle: String? = nil,
        kind: ManifestKind = .progressive,
        ext: String = "mp4"
    ) {
        self.title = title
        self.year = year
        self.show = show
        self.season = season
        self.episode = episode
        self.episodeTitle = episodeTitle
        self.kind = {
            switch kind {
            case .hls: return "hls"
            case .dash: return "dash"
            case .progressive: return "mp4"
            }
        }()
        self.ext = ext
    }
}

enum ExportNaming {
    /// Résout un modèle relatif (ex. `Film (2020)/Film (2020).mp4`).
    static func relativePath(template: String, context: ExportNamingContext) -> String {
        let values: [String: String] = [
            "title": sanitizeSegment(context.title),
            "year": sanitizeSegment(context.year ?? "", allowEmpty: true),
            "show": sanitizeSegment(context.show ?? context.title),
            "season": sanitizeSegment(paddedSeasonEpisode(context.season), allowEmpty: true),
            "episode": sanitizeSegment(paddedSeasonEpisode(context.episode), allowEmpty: true),
            "episode_title": sanitizeSegment(context.episodeTitle ?? "", allowEmpty: true),
            "kind": sanitizeSegment(context.kind),
            "ext": sanitizeExtension(context.ext)
        ]

        var result = template
        for (key, value) in values {
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }

        result = cleanupEmptyTokens(result)
        result = result
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .joined(separator: "/")

        if result.isEmpty {
            return "\(sanitizeSegment(context.title)).\(sanitizeExtension(context.ext))"
        }
        // Si le modèle n’a pas d’extension, ajouter .{ext}
        if (result as NSString).pathExtension.isEmpty {
            result += ".\(sanitizeExtension(context.ext))"
        }
        return result
    }

    static func resolveURL(root: URL, template: String, context: ExportNamingContext) -> URL {
        let relative = relativePath(template: template, context: context)
        let parts = relative.split(separator: "/").map(String.init)
        guard let fileName = parts.last else {
            return uniqueURL(in: root, preferredName: "export.mp4")
        }
        let directory = parts.dropLast().reduce(root) { partial, name in
            partial.appendingPathComponent(name, isDirectory: true)
        }
        return uniqueURL(in: directory, preferredName: fileName)
    }

    /// Extrait titre + année depuis un titre de page / fichier.
    static func parseTitleAndYear(from raw: String) -> (title: String, year: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("video", nil) }

        // "Title (2010)" ou "Title (2010) - Watch"
        if let regex = try? NSRegularExpression(pattern: #"^(.*?)[\s\-_]*\((\d{4})\)(.*)$"#) {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if let match = regex.firstMatch(in: trimmed, range: range),
               let titleRange = Range(match.range(at: 1), in: trimmed),
               let yearRange = Range(match.range(at: 2), in: trimmed)
            {
                var title = String(trimmed[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                title = title.trimmingCharacters(in: CharacterSet(charactersIn: "-–—|_"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let year = String(trimmed[yearRange])
                if title.isEmpty { title = "video" }
                return (title, year)
            }
        }

        // "Title 2010"
        if let regex = try? NSRegularExpression(pattern: #"^(.*?)[\s\-_]*((?:19|20)\d{2})\s*$"#) {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if let match = regex.firstMatch(in: trimmed, range: range),
               let titleRange = Range(match.range(at: 1), in: trimmed),
               let yearRange = Range(match.range(at: 2), in: trimmed)
            {
                var title = String(trimmed[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                title = title.trimmingCharacters(in: CharacterSet(charactersIn: "-–—|_"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let year = String(trimmed[yearRange])
                if title.isEmpty { title = "video" }
                return (title, year)
            }
        }

        return (trimmed, nil)
    }

    static func sanitizeSegment(_ name: String, allowEmpty: Bool = false) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            return allowEmpty ? "" : "video"
        }
        return String(cleaned.prefix(120))
    }

    private static func sanitizeExtension(_ ext: String) -> String {
        let cleaned = ext.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).lowercased()
        return cleaned.isEmpty ? "mp4" : cleaned
    }

    private static func paddedSeasonEpisode(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        if let n = Int(value) {
            return String(format: "%02d", n)
        }
        return value
    }

    private static func cleanupEmptyTokens(_ path: String) -> String {
        var result = path
        // "Title ()" → "Title"
        result = result.replacingOccurrences(of: " ()", with: "")
        result = result.replacingOccurrences(of: "()", with: "")
        // Saison vide : "Season /" ou "Season  /"
        result = result.replacingOccurrences(of: "Season /", with: "")
        // Épisode vide : " - SE" / " - S E"
        result = result.replacingOccurrences(of: " - SE", with: "")
        result = result.replacingOccurrences(of: " - S E", with: "")
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result
    }

    private static func uniqueURL(in directory: URL, preferredName: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory.appendingPathComponent(preferredName)
        if !FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let base = (preferredName as NSString).deletingPathExtension
        let ext = (preferredName as NSString).pathExtension
        for i in 2...99 {
            let candidate = directory.appendingPathComponent("\(base)-\(i).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            url = candidate
        }
        return directory.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(6)).\(ext)")
    }
}
