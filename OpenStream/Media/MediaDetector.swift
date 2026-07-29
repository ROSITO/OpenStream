import Foundation
import CoreGraphics

enum MediaClassification: String, Sendable {
    case progressive
    case hls
    case dash
    case segment
    case unknown
}

enum MediaDetector {
    static func classify(url: URL, mimeType: String?) -> MediaClassification {
        let ext = url.pathExtension.lowercased()
        let mime = mimeType?.lowercased() ?? ""
        let haystack = url.absoluteString.lowercased()

        if mime.contains("mpegurl") || mime.contains("application/vnd.apple.mpegurl") || ext == "m3u8" || haystack.contains(".m3u8") {
            return .hls
        }
        if mime.contains("dash+xml") || ext == "mpd" || haystack.contains(".mpd") {
            return .dash
        }
        if ["mp4", "m4v", "mov", "webm"].contains(ext) || mime.hasPrefix("video/") || mime.contains("application/mp4") {
            // Segments can also be video/mp2t — handled below
            if ext == "ts" || ext == "m4s" { return .segment }
            return .progressive
        }
        if ext == "ts" || ext == "m4s" || mime.contains("mp2t") {
            return .segment
        }
        if MediaURLHeuristics.looksLikeMedia(url, mimeType: mimeType) {
            return .unknown
        }
        return .unknown
    }

    /// Construit un DetectedMedia à partir d'un candidat déjà classifié (sans I/O réseau).
    static func makeProgressive(
        from candidate: NetworkMediaCandidate,
        contentLength: Int64? = nil,
        title: String? = nil
    ) -> DetectedMedia {
        let variant = MediaVariant(playlistURL: candidate.url)
        return DetectedMedia(
            sourceURL: candidate.url,
            kind: .progressive,
            protection: .none,
            suggestedTitle: title ?? candidate.url.lastPathComponent,
            pageURL: candidate.pageURL,
            variants: [variant],
            preferredVariantID: variant.id,
            isVOD: true,
            segmentCount: 1,
            contentLength: contentLength,
            observedAt: candidate.observedAt
        )
    }

    static func makeHLS(
        from candidate: NetworkMediaCandidate,
        playlist: HLSPlaylist,
        title: String? = nil
    ) -> DetectedMedia {
        let audioTracks: [MediaTrack] = playlist.renditions.compactMap { rendition in
            guard rendition.kind == .audio, let uri = rendition.uri else { return nil }
            return MediaTrack(
                kind: .audio,
                language: rendition.language,
                name: rendition.name,
                url: uri,
                isDefault: rendition.isDefault
            )
        }
        let subtitleTracks: [MediaTrack] = playlist.renditions.compactMap { rendition in
            guard rendition.kind == .subtitles || rendition.kind == .closedCaptions,
                  let uri = rendition.uri
            else { return nil }
            return MediaTrack(
                kind: .subtitle,
                language: rendition.language,
                name: rendition.name,
                url: uri,
                isDefault: rendition.isDefault
            )
        }

        switch playlist.kind {
        case .master:
            let variants = playlist.streams.map { stream in
                MediaVariant(
                    bandwidth: stream.bandwidth,
                    resolution: stream.resolution,
                    codecs: stream.codecs,
                    playlistURL: stream.uri,
                    averageBandwidth: stream.averageBandwidth
                )
            }
            return DetectedMedia(
                sourceURL: candidate.url,
                kind: .hls,
                protection: .none,
                suggestedTitle: title ?? candidate.url.lastPathComponent,
                pageURL: candidate.pageURL,
                variants: variants,
                audioTracks: audioTracks,
                subtitleTracks: subtitleTracks,
                isVOD: nil,
                segmentCount: nil,
                observedAt: candidate.observedAt
            )
        case .media:
            let variant = MediaVariant(playlistURL: candidate.url)
            let media = playlist.media
            return DetectedMedia(
                sourceURL: candidate.url,
                kind: .hls,
                protection: .none,
                suggestedTitle: title ?? candidate.url.lastPathComponent,
                pageURL: candidate.pageURL,
                variants: [variant],
                preferredVariantID: variant.id,
                audioTracks: audioTracks,
                subtitleTracks: subtitleTracks,
                isVOD: media?.hasEndList,
                segmentCount: media?.segments.count,
                durationSeconds: media.map(\.totalDuration),
                observedAt: candidate.observedAt
            )
        }
    }

    static func makeDASH(
        from candidate: NetworkMediaCandidate,
        manifest: DASHManifest,
        title: String? = nil
    ) -> DetectedMedia {
        let variants = manifest.videoRepresentations.map { rep in
            MediaVariant(
                bandwidth: rep.bandwidth,
                resolution: {
                    if let w = rep.width, let h = rep.height {
                        return CGSize(width: w, height: h)
                    }
                    return nil
                }(),
                codecs: rep.codecs,
                playlistURL: candidate.url,
                averageBandwidth: rep.bandwidth,
                dashRepresentationID: rep.id
            )
        }
        let audioTracks = manifest.audioRepresentations.enumerated().map { index, rep in
            MediaTrack(
                kind: .audio,
                language: rep.language,
                name: rep.label ?? rep.id,
                url: candidate.url,
                dashRepresentationID: rep.id,
                isDefault: index == 0,
                codecs: rep.codecs
            )
        }
        let subtitleTracks = manifest.textRepresentations.map { rep in
            // URL directe si un seul segment fichier, sinon MPD + rep id
            let url = rep.segments.count == 1 ? rep.segments[0].url : candidate.url
            return MediaTrack(
                kind: .subtitle,
                language: rep.language,
                name: rep.label ?? rep.id,
                url: url,
                dashRepresentationID: rep.id,
                isDefault: false,
                codecs: rep.codecs
            )
        }
        let preferred = variants.max { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) }
        let segmentCount = preferred.flatMap { v in
            manifest.videoRepresentations.first(where: { $0.id == v.dashRepresentationID })?.segments.count
        }

        return DetectedMedia(
            sourceURL: candidate.url,
            kind: .dash,
            protection: .none,
            suggestedTitle: title ?? candidate.url.lastPathComponent,
            pageURL: candidate.pageURL,
            variants: variants,
            preferredVariantID: preferred?.id,
            audioTracks: audioTracks,
            subtitleTracks: subtitleTracks,
            isVOD: true,
            segmentCount: segmentCount,
            durationSeconds: manifest.periodDurationSeconds,
            observedAt: candidate.observedAt
        )
    }
}
