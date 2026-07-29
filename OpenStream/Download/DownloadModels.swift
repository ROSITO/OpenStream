import Foundation

enum DownloadState: Sendable, Hashable, Codable {
    case queued
    case preparing
    case downloading(progress: Double, completedUnits: Int, totalUnits: Int?)
    case assembling
    case completed(directoryURL: URL)
    case failed(message: String)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }

    var progressValue: Double {
        switch self {
        case .queued, .preparing: return 0
        case .downloading(let progress, _, _): return progress
        case .assembling: return 0.99
        case .completed: return 1
        case .failed, .cancelled: return 0
        }
    }

    var label: String {
        switch self {
        case .queued: return "En file"
        case .preparing: return "Préparation"
        case .downloading(let p, let done, let total):
            if let total {
                return String(format: "Téléchargement %.0f%% (%d/%d)", p * 100, done, total)
            }
            return String(format: "Téléchargement %.0f%%", p * 100)
        case .assembling: return "Assemblage MP4…"
        case .completed: return "Terminé"
        case .failed(let message): return "Échec: \(message)"
        case .cancelled: return "Annulé"
        }
    }
}

struct DownloadCredentials: Sendable, Hashable, Codable {
    var cookieHeader: String?
    var referer: String?
    var userAgent: String

    static let `default` = DownloadCredentials(
        cookieHeader: nil,
        referer: nil,
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X) OpenStream/0.1"
    )
}

struct DownloadJob: Identifiable, Sendable, Hashable, Codable {
    let id: UUID
    var title: String
    var kind: ManifestKind
    var sourceURL: URL
    var variantURL: URL
    var pageURL: URL?
    var credentials: DownloadCredentials
    var state: DownloadState
    var destinationDirectory: URL
    /// Dossier du MP4 final (souvent `~/Downloads/OpenStream`).
    var outputDirectory: URL?
    var exportURL: URL?
    /// Piste audio alternative (HLS media playlist / DASH rep).
    var selectedAudioTrackURL: URL?
    var selectedAudioDashRepresentationID: String?
    /// Sous-titres (playlist HLS, VTT direct, ou DASH).
    var selectedSubtitleTrackURL: URL?
    var selectedSubtitleDashRepresentationID: String?
    var selectedDashVideoRepresentationID: String?
    /// Métadonnées d’export (nomenclature Jellyfin / custom).
    var exportTitle: String?
    var exportYear: String?
    var exportShow: String?
    var exportSeason: String?
    var exportEpisode: String?
    var exportEpisodeTitle: String?
    var completedUnitIndices: [Int]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        kind: ManifestKind,
        sourceURL: URL,
        variantURL: URL,
        pageURL: URL? = nil,
        credentials: DownloadCredentials = .default,
        state: DownloadState = .queued,
        destinationDirectory: URL,
        outputDirectory: URL? = nil,
        exportURL: URL? = nil,
        selectedAudioTrackURL: URL? = nil,
        selectedAudioDashRepresentationID: String? = nil,
        selectedSubtitleTrackURL: URL? = nil,
        selectedSubtitleDashRepresentationID: String? = nil,
        selectedDashVideoRepresentationID: String? = nil,
        exportTitle: String? = nil,
        exportYear: String? = nil,
        exportShow: String? = nil,
        exportSeason: String? = nil,
        exportEpisode: String? = nil,
        exportEpisodeTitle: String? = nil,
        completedUnitIndices: [Int] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.sourceURL = sourceURL
        self.variantURL = variantURL
        self.pageURL = pageURL
        self.credentials = credentials
        self.state = state
        self.destinationDirectory = destinationDirectory
        self.outputDirectory = outputDirectory
        self.exportURL = exportURL
        self.selectedAudioTrackURL = selectedAudioTrackURL
        self.selectedAudioDashRepresentationID = selectedAudioDashRepresentationID
        self.selectedSubtitleTrackURL = selectedSubtitleTrackURL
        self.selectedSubtitleDashRepresentationID = selectedSubtitleDashRepresentationID
        self.selectedDashVideoRepresentationID = selectedDashVideoRepresentationID
        self.exportTitle = exportTitle
        self.exportYear = exportYear
        self.exportShow = exportShow
        self.exportSeason = exportSeason
        self.exportEpisode = exportEpisode
        self.exportEpisodeTitle = exportEpisodeTitle
        self.completedUnitIndices = completedUnitIndices
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var resolvedOutputDirectory: URL {
        outputDirectory ?? AppPreferences.exportRoot
    }

    var namingContext: ExportNamingContext {
        let rawTitle = (exportTitle?.isEmpty == false ? exportTitle! : title)
        let parsed = ExportNaming.parseTitleAndYear(from: rawTitle)
        let year: String? = {
            let explicit = exportYear?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let explicit, !explicit.isEmpty { return explicit }
            return parsed.year
        }()
        return ExportNamingContext(
            title: parsed.title,
            year: year,
            show: {
                let s = exportShow?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let s, !s.isEmpty { return s }
                return parsed.title
            }(),
            season: exportSeason,
            episode: exportEpisode,
            episodeTitle: exportEpisodeTitle,
            kind: kind,
            ext: "mp4"
        )
    }
}

enum DownloadError: Error, LocalizedError, Sendable {
    case cancelled
    case unsupportedKind
    case invalidPlaylist
    case emptyPlaylist
    case httpStatus(Int)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Téléchargement annulé"
        case .unsupportedKind: return "Type de média non supporté pour le téléchargement"
        case .invalidPlaylist: return "Playlist HLS invalide"
        case .emptyPlaylist: return "Playlist HLS sans segments"
        case .httpStatus(let code): return "HTTP \(code)"
        case .message(let text): return text
        }
    }
}

extension DownloadError: Equatable {
    static func == (lhs: DownloadError, rhs: DownloadError) -> Bool {
        switch (lhs, rhs) {
        case (.cancelled, .cancelled),
             (.unsupportedKind, .unsupportedKind),
             (.invalidPlaylist, .invalidPlaylist),
             (.emptyPlaylist, .emptyPlaylist):
            return true
        case (.httpStatus(let a), .httpStatus(let b)):
            return a == b
        case (.message(let a), .message(let b)):
            return a == b
        default:
            return false
        }
    }
}
