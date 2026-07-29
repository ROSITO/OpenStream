import Foundation
import CoreGraphics

enum ManifestKind: String, Sendable, Hashable, Codable {
    case progressive
    case hls
    case dash
}

enum MediaProtection: Sendable, Hashable {
    case none
    case drm(reason: String) // Phase 9 — stub en version test
}

enum MediaTrackKind: String, Sendable, Hashable, Codable {
    case audio
    case subtitle
}

struct MediaTrack: Identifiable, Sendable, Hashable, Codable {
    let id: UUID
    let kind: MediaTrackKind
    let language: String?
    let name: String?
    let url: URL
    /// Identifiant Representation DASH (si applicable).
    let dashRepresentationID: String?
    let isDefault: Bool
    let codecs: String?

    init(
        id: UUID = UUID(),
        kind: MediaTrackKind,
        language: String? = nil,
        name: String? = nil,
        url: URL,
        dashRepresentationID: String? = nil,
        isDefault: Bool = false,
        codecs: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.language = language
        self.name = name
        self.url = url
        self.dashRepresentationID = dashRepresentationID
        self.isDefault = isDefault
        self.codecs = codecs
    }

    var displayLabel: String {
        var parts: [String] = []
        if let name, !name.isEmpty { parts.append(name) }
        if let language, !language.isEmpty { parts.append(language.uppercased()) }
        if parts.isEmpty {
            parts.append(kind == .audio ? "Audio" : "Sous-titres")
        }
        if isDefault { parts.append("défaut") }
        return parts.joined(separator: " · ")
    }
}

struct MediaVariant: Identifiable, Sendable, Hashable {
    let id: UUID
    let bandwidth: Int?
    let resolution: CGSize?
    let codecs: String?
    let playlistURL: URL
    let averageBandwidth: Int?
    /// Representation @id DASH (vidéo).
    let dashRepresentationID: String?

    init(
        id: UUID = UUID(),
        bandwidth: Int? = nil,
        resolution: CGSize? = nil,
        codecs: String? = nil,
        playlistURL: URL,
        averageBandwidth: Int? = nil,
        dashRepresentationID: String? = nil
    ) {
        self.id = id
        self.bandwidth = bandwidth
        self.resolution = resolution
        self.codecs = codecs
        self.playlistURL = playlistURL
        self.averageBandwidth = averageBandwidth
        self.dashRepresentationID = dashRepresentationID
    }

    var displayLabel: String {
        var parts: [String] = []
        if let resolution, resolution.width > 0, resolution.height > 0 {
            parts.append("\(Int(resolution.width))×\(Int(resolution.height))")
        }
        if let bandwidth {
            parts.append(Self.formatBandwidth(bandwidth))
        }
        if parts.isEmpty {
            return playlistURL.lastPathComponent
        }
        return parts.joined(separator: " · ")
    }

    private static func formatBandwidth(_ bps: Int) -> String {
        if bps >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bps) / 1_000_000)
        }
        if bps >= 1_000 {
            return String(format: "%.0f kbps", Double(bps) / 1_000)
        }
        return "\(bps) bps"
    }
}

struct DetectedMedia: Identifiable, Sendable, Hashable {
    let id: UUID
    let sourceURL: URL
    let kind: ManifestKind
    let protection: MediaProtection
    let suggestedTitle: String?
    let pageURL: URL?
    let variants: [MediaVariant]
    let preferredVariantID: MediaVariant.ID?
    let audioTracks: [MediaTrack]
    let subtitleTracks: [MediaTrack]
    let isVOD: Bool?
    let segmentCount: Int?
    /// Durée estimée (somme EXTINF HLS, ou mediaPresentationDuration DASH).
    let durationSeconds: Double?
    let contentLength: Int64?
    let observedAt: Date

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        kind: ManifestKind,
        protection: MediaProtection = .none,
        suggestedTitle: String? = nil,
        pageURL: URL? = nil,
        variants: [MediaVariant],
        preferredVariantID: MediaVariant.ID? = nil,
        audioTracks: [MediaTrack] = [],
        subtitleTracks: [MediaTrack] = [],
        isVOD: Bool? = nil,
        segmentCount: Int? = nil,
        durationSeconds: Double? = nil,
        contentLength: Int64? = nil,
        observedAt: Date = Date()
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.kind = kind
        self.protection = protection
        self.suggestedTitle = suggestedTitle
        self.pageURL = pageURL
        self.variants = variants
        self.preferredVariantID = preferredVariantID ?? Self.bestVariantID(in: variants)
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.isVOD = isVOD
        self.segmentCount = segmentCount
        self.durationSeconds = durationSeconds
        self.contentLength = contentLength
        self.observedAt = observedAt
    }

    var preferredVariant: MediaVariant? {
        guard let preferredVariantID else { return variants.first }
        return variants.first { $0.id == preferredVariantID } ?? variants.first
    }

    var displayTitle: String {
        let host = pageURL?.host() ?? sourceURL.host()
        if let suggestedTitle, let useful = PageTitleResolver.usefulTitle(suggestedTitle, host: host) {
            return useful
        }
        if let fromPage = pageURL.flatMap({ PageTitleResolver.usefulTitle(fromURL: $0) }) {
            return fromPage
        }
        if let fromURL = PageTitleResolver.usefulTitle(fromURL: sourceURL) {
            return fromURL
        }
        let last = sourceURL.lastPathComponent
        if !last.isEmpty { return last }
        return sourceURL.host() ?? sourceURL.absoluteString
    }

    var kindLabel: String {
        switch kind {
        case .hls: return "HLS"
        case .progressive: return "MP4"
        case .dash: return "DASH"
        }
    }

    var hasSelectableTracks: Bool {
        audioTracks.count > 1 || !subtitleTracks.isEmpty
    }

    /// Affichage court : `1h 32m`, `45m 12s`, `1m 05s`.
    var formattedDuration: String? {
        Self.formatDuration(durationSeconds)
    }

    static func formatDuration(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%dh %02dm", h, m)
        }
        if m > 0 {
            return String(format: "%dm %02ds", m, s)
        }
        return String(format: "%ds", s)
    }

    func replacingSuggestedTitle(_ title: String) -> DetectedMedia {
        DetectedMedia(
            id: id,
            sourceURL: sourceURL,
            kind: kind,
            protection: protection,
            suggestedTitle: title,
            pageURL: pageURL,
            variants: variants,
            preferredVariantID: preferredVariantID,
            audioTracks: audioTracks,
            subtitleTracks: subtitleTracks,
            isVOD: isVOD,
            segmentCount: segmentCount,
            durationSeconds: durationSeconds,
            contentLength: contentLength,
            observedAt: observedAt
        )
    }

    func withPlaylistTiming(segmentCount: Int?, durationSeconds: Double?, isVOD: Bool?) -> DetectedMedia {
        DetectedMedia(
            id: id,
            sourceURL: sourceURL,
            kind: kind,
            protection: protection,
            suggestedTitle: suggestedTitle,
            pageURL: pageURL,
            variants: variants,
            preferredVariantID: preferredVariantID,
            audioTracks: audioTracks,
            subtitleTracks: subtitleTracks,
            isVOD: isVOD ?? self.isVOD,
            segmentCount: segmentCount ?? self.segmentCount,
            durationSeconds: durationSeconds ?? self.durationSeconds,
            contentLength: contentLength,
            observedAt: observedAt
        )
    }

    private static func bestVariantID(in variants: [MediaVariant]) -> MediaVariant.ID? {
        variants.max { lhs, rhs in
            let lb = lhs.bandwidth ?? lhs.averageBandwidth ?? 0
            let rb = rhs.bandwidth ?? rhs.averageBandwidth ?? 0
            if lb != rb { return lb < rb }
            let la = (lhs.resolution?.width ?? 0) * (lhs.resolution?.height ?? 0)
            let ra = (rhs.resolution?.width ?? 0) * (rhs.resolution?.height ?? 0)
            return la < ra
        }?.id
    }
}
