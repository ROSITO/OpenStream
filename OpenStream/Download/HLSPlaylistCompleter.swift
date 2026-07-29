import Foundation

/// Résout une playlist média HLS **complète** (VOD / événement terminé).
/// Sans ça, un snapshot unique d’un flux EVENT/DVR (~30–60 min) produit un MP4 tronqué.
enum HLSPlaylistCompleter {
    struct Options: Sendable {
        /// Attente max pour obtenir `#EXT-X-ENDLIST` ou une liste stable.
        var maxWaitNanoseconds: UInt64 = 10 * 60 * 1_000_000_000
        /// Polls sans nouveaux segments avant de considérer la playlist « stable » (sans ENDLIST).
        var stablePollsRequired: Int = 2
        var minPollIntervalNanoseconds: UInt64 = 1_000_000_000
        var maxPollIntervalNanoseconds: UInt64 = 6_000_000_000
    }

    /// Récupère la playlist média (suit le master si besoin) en fusionnant les segments jusqu’à fin / stabilité.
    static func resolveMediaPlaylist(
        playlistURL: URL,
        credentials: DownloadCredentials,
        downloader: SegmentFileDownloader,
        isCancelled: @Sendable () -> Bool = { false },
        options: Options = Options()
    ) async throws -> HLSPlaylist {
        let firstText = try await downloader.fetchText(url: playlistURL, credentials: credentials)
        var playlist = try HLSParser.parse(text: firstText, playlistURL: playlistURL)

        var mediaURL = playlistURL
        if playlist.kind == .master {
            guard let best = playlist.streams.max(by: { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) }) else {
                throw DownloadError.emptyPlaylist
            }
            mediaURL = best.uri
            let mediaText = try await downloader.fetchText(url: mediaURL, credentials: credentials)
            playlist = try HLSParser.parse(text: mediaText, playlistURL: mediaURL)
        }

        guard playlist.kind == .media, var media = playlist.media else {
            throw DownloadError.invalidPlaylist
        }

        if media.hasEndList {
            logPlan(media: media, note: "ENDLIST immédiat")
            return playlist
        }

        // EVENT / live : re-poll et fusionner jusqu’à ENDLIST ou stabilité
        var mergedByURI: [URL: HLSSegment] = [:]
        var order: [URL] = []
        func ingest(_ segments: [HLSSegment]) {
            for seg in segments {
                if mergedByURI[seg.uri] == nil {
                    order.append(seg.uri)
                }
                mergedByURI[seg.uri] = seg
            }
        }
        ingest(media.segments)

        var previousFirstURI = media.segments.first?.uri
        var previousSequence = media.mediaSequence
        var stablePolls = 0
        let started = ContinuousClock.now
        var poll = 0

        while !media.hasEndList {
            if isCancelled() { throw DownloadError.cancelled }

            let elapsed = ContinuousClock.now - started
            if elapsed >= .nanoseconds(Int64(clamping: options.maxWaitNanoseconds)) {
                break
            }

            let interval = pollIntervalNanoseconds(targetDuration: media.targetDuration, options: options)
            try await Task.sleep(nanoseconds: interval)
            if isCancelled() { throw DownloadError.cancelled }
            poll += 1

            let text = try await downloader.fetchText(url: mediaURL, credentials: credentials)
            let refreshed = try HLSParser.parse(text: text, playlistURL: mediaURL)
            guard refreshed.kind == .media, let next = refreshed.media else {
                throw DownloadError.invalidPlaylist
            }

            // Fenêtre glissante live : la tête avance et les vieux segments disparaissent
            if isSlidingWindow(
                previousSequence: previousSequence,
                previousFirstURI: previousFirstURI,
                next: next,
                mergedCount: order.count
            ) {
                throw DownloadError.message(
                    "Flux HLS live (fenêtre glissante) — impossible de récupérer le film entier. Attendez une version VOD (#EXT-X-ENDLIST)."
                )
            }

            let before = order.count
            ingest(next.segments)
            let grew = order.count > before
            media = HLSMediaPlaylist(
                targetDuration: next.targetDuration ?? media.targetDuration,
                mediaSequence: next.mediaSequence ?? media.mediaSequence,
                hasEndList: next.hasEndList,
                mapURI: next.mapURI ?? media.mapURI,
                segments: order.compactMap { mergedByURI[$0] }
            )
            previousFirstURI = next.segments.first?.uri ?? previousFirstURI
            previousSequence = next.mediaSequence ?? previousSequence

            if grew {
                stablePolls = 0
                AppLog.download.info(
                    "HLS poll \(poll, privacy: .public): +\(order.count - before, privacy: .public) seg total=\(order.count, privacy: .public)"
                )
            } else {
                stablePolls += 1
                if stablePolls >= options.stablePollsRequired {
                    AppLog.download.info(
                        "HLS playlist stable sans ENDLIST après \(poll, privacy: .public) polls (\(order.count, privacy: .public) seg)"
                    )
                    break
                }
            }

            if media.hasEndList { break }
        }

        if media.segments.isEmpty {
            throw DownloadError.emptyPlaylist
        }

        if !media.hasEndList {
            let duration = media.segments.reduce(0.0) { $0 + $1.duration }
            // Moins de ~2 min et pas d’ENDLIST → trop risqué
            if duration < 120 {
                throw DownloadError.message(
                    "Playlist HLS incomplète (pas de #EXT-X-ENDLIST, ~\(Int(duration))s). Réessayez quand le contenu est en VOD."
                )
            }
            AppLog.download.error(
                "HLS sans ENDLIST — export possible tronqué (~\(Int(duration), privacy: .public)s, \(media.segments.count, privacy: .public) seg)"
            )
        }

        logPlan(media: media, note: media.hasEndList ? "ENDLIST" : "stable sans ENDLIST")
        return HLSPlaylist(
            kind: .media,
            baseURL: mediaURL,
            streams: [],
            media: media,
            renditions: playlist.renditions
        )
    }

    private static func pollIntervalNanoseconds(targetDuration: Double?, options: Options) -> UInt64 {
        let fromTarget = UInt64(max(1, (targetDuration ?? 4)) * 1_000_000_000)
        return min(options.maxPollIntervalNanoseconds, max(options.minPollIntervalNanoseconds, fromTarget))
    }

    private static func isSlidingWindow(
        previousSequence: Int?,
        previousFirstURI: URL?,
        next: HLSMediaPlaylist,
        mergedCount: Int
    ) -> Bool {
        guard let prevSeq = previousSequence,
              let nextSeq = next.mediaSequence,
              nextSeq > prevSeq,
              let prevFirst = previousFirstURI,
              let nextFirst = next.segments.first?.uri
        else { return false }

        // Sequence avancée + premier segment changé + on a déjà fusionné plus que la fenêtre actuelle
        // → typique d’un live sliding (les vieux URI ne reviennent pas).
        if nextFirst != prevFirst, mergedCount > next.segments.count + 2 {
            // Si l’ancien premier a disparu de la nouvelle liste
            let stillHasOldHead = next.segments.contains(where: { $0.uri == prevFirst })
            return !stillHasOldHead
        }
        return false
    }

    private static func logPlan(media: HLSMediaPlaylist, note: String) {
        let duration = media.segments.reduce(0.0) { $0 + $1.duration }
        AppLog.download.info(
            "HLS plan \(note, privacy: .public): \(media.segments.count, privacy: .public) seg ~\(Int(duration), privacy: .public)s endlist=\(media.hasEndList, privacy: .public)"
        )
    }
}

private extension Duration {
    static func nanoseconds(_ value: Int64) -> Duration {
        Duration.nanoseconds(value)
    }
}
