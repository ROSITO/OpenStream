import Foundation
import Observation

/// Enrichit les candidats réseau en `DetectedMedia` (fetch HLS + HEAD progressif).
@MainActor
@Observable
final class MediaCatalog {
    private(set) var detected: [DetectedMedia] = []
    private(set) var processingURLs: Set<String> = []
    private(set) var lastError: String?

    private var seenSourceKeys = Set<String>()
    private var session: URLSession
    private weak var cookieBridge: CookieBridge?
    /// Appelé quand un média est ajouté / enrichi (automation Phase 8).
    var onMediaDetected: ((DetectedMedia) -> Void)?

    init(session: URLSession = .shared, cookieBridge: CookieBridge? = nil) {
        self.session = session
        self.cookieBridge = cookieBridge
    }

    func attachCookieBridge(_ bridge: CookieBridge) {
        cookieBridge = bridge
    }

    func updateSession(_ session: URLSession) {
        self.session = session
    }

    func clear() {
        detected.removeAll()
        seenSourceKeys.removeAll()
        processingURLs.removeAll()
        lastError = nil
    }

    /// Met à jour les titres génériques / nom de site quand un vrai titre de contenu arrive.
    func refreshSuggestedTitles(using pageTitle: String) {
        guard let useful = PageTitleResolver.usefulTitle(pageTitle) else { return }
        for index in detected.indices {
            let current = detected[index]
            let host = current.pageURL?.host() ?? current.sourceURL.host()
            let existing = PageTitleResolver.usefulTitle(current.suggestedTitle, host: host)
            // Remplacer si absent, marque site, ou clairement plus court / générique
            let shouldReplace: Bool = {
                guard let existing else { return true }
                if PageTitleResolver.looksLikeSiteBrand(existing, host: host) { return true }
                if useful.count >= existing.count + 4 { return true }
                return false
            }()
            if shouldReplace, existing != useful {
                detected[index] = current.replacingSuggestedTitle(useful)
            }
        }
    }

    func ingest(_ candidate: NetworkMediaCandidate, pageTitle: String?) {
        let classification = MediaDetector.classify(url: candidate.url, mimeType: candidate.mimeType)

        switch classification {
        case .segment, .unknown:
            return
        case .progressive, .hls, .dash:
            break
        }

        let resolvedTitle = PageTitleResolver.title(
            pageTitle: pageTitle,
            pageURL: candidate.pageURL,
            mediaURL: candidate.url
        )

        let key = normalizedKey(for: candidate.url)
        guard !seenSourceKeys.contains(key), !processingURLs.contains(key) else { return }

        processingURLs.insert(key)
        Task {
            defer { processingURLs.remove(key) }
            do {
                let media: DetectedMedia?
                switch classification {
                case .hls:
                    media = try await enrichHLS(candidate, pageTitle: resolvedTitle)
                case .progressive:
                    media = try await enrichProgressive(candidate, pageTitle: resolvedTitle)
                case .dash:
                    media = try await enrichDASH(candidate, pageTitle: resolvedTitle)
                case .segment, .unknown:
                    media = nil
                }
                if let media {
                    seenSourceKeys.insert(key)
                    upsert(media)
                    AppLog.network.info(
                        "Detected \(media.kindLabel, privacy: .public) variants=\(media.variants.count, privacy: .public) \(media.sourceURL.absoluteString, privacy: .public)"
                    )
                }
            } catch {
                lastError = error.localizedDescription
                AppLog.network.error("Enrichment failed: \(error.localizedDescription, privacy: .public)")
                // Fallback: still surface HLS/progressive/DASH URL without full parse
                if classification == .hls || classification == .progressive || classification == .dash {
                    seenSourceKeys.insert(key)
                    let fallbackVariant = MediaVariant(playlistURL: candidate.url)
                    let kind: ManifestKind = {
                        switch classification {
                        case .hls: return .hls
                        case .dash: return .dash
                        default: return .progressive
                        }
                    }()
                    let fallback = DetectedMedia(
                        sourceURL: candidate.url,
                        kind: kind,
                        suggestedTitle: resolvedTitle,
                        pageURL: candidate.pageURL,
                        variants: [fallbackVariant],
                        preferredVariantID: fallbackVariant.id,
                        observedAt: candidate.observedAt
                    )
                    upsert(fallback)
                }
            }
        }
    }

    private func enrichDASH(_ candidate: NetworkMediaCandidate, pageTitle: String?) async throws -> DetectedMedia {
        var request = URLRequest(url: candidate.url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X) OpenStream/0.1", forHTTPHeaderField: "User-Agent")
        if let cookie = cookieBridge?.lastSnapshot.cookieHeader(for: candidate.url) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let page = candidate.pageURL?.absoluteString {
            request.setValue(page, forHTTPHeaderField: "Referer")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else {
            throw URLError(.cannotDecodeContentData)
        }
        let manifest = try DASHParser.parse(xml: text, manifestURL: candidate.url)
        return MediaDetector.makeDASH(from: candidate, manifest: manifest, title: pageTitle)
    }

    private func enrichHLS(_ candidate: NetworkMediaCandidate, pageTitle: String?) async throws -> DetectedMedia {
        var request = URLRequest(url: candidate.url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X) OpenStream/0.1", forHTTPHeaderField: "User-Agent")
        if let cookie = cookieBridge?.lastSnapshot.cookieHeader(for: candidate.url) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let page = candidate.pageURL?.absoluteString {
            request.setValue(page, forHTTPHeaderField: "Referer")
        }

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else {
            throw URLError(.cannotDecodeContentData)
        }

        let playlist = try HLSParser.parse(text: text, playlistURL: candidate.url)
        var media = MediaDetector.makeHLS(from: candidate, playlist: playlist, title: pageTitle)

        // Master : récupérer la variante préférée pour segments + durée
        if playlist.kind == .master,
           let best = playlist.streams.max(by: { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) })
        {
            do {
                var mediaRequest = URLRequest(url: best.uri)
                mediaRequest.setValue(
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X) OpenStream/0.1",
                    forHTTPHeaderField: "User-Agent"
                )
                if let cookie = cookieBridge?.lastSnapshot.cookieHeader(for: best.uri) {
                    mediaRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
                }
                if let page = candidate.pageURL?.absoluteString {
                    mediaRequest.setValue(page, forHTTPHeaderField: "Referer")
                }
                let (mediaData, mediaResponse) = try await session.data(for: mediaRequest)
                if let http = mediaResponse as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   let mediaText = String(data: mediaData, encoding: .utf8)
                    ?? String(data: mediaData, encoding: .isoLatin1)
                {
                    let mediaPlaylist = try HLSParser.parse(text: mediaText, playlistURL: best.uri)
                    if let m = mediaPlaylist.media {
                        media = media.withPlaylistTiming(
                            segmentCount: m.segments.count,
                            durationSeconds: m.totalDuration,
                            isVOD: m.hasEndList
                        )
                    }
                }
            } catch {
                AppLog.network.debug(
                    "HLS media timing fetch failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        return media
    }

    private func enrichProgressive(_ candidate: NetworkMediaCandidate, pageTitle: String?) async throws -> DetectedMedia {
        var length: Int64?
        var request = URLRequest(url: candidate.url)
        request.httpMethod = "HEAD"
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X) OpenStream/0.1", forHTTPHeaderField: "User-Agent")
        if let cookie = cookieBridge?.lastSnapshot.cookieHeader(for: candidate.url) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let page = candidate.pageURL?.absoluteString {
            request.setValue(page, forHTTPHeaderField: "Referer")
        }

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                if let cl = http.value(forHTTPHeaderField: "Content-Length"), let v = Int64(cl) {
                    length = v
                }
            }
        } catch {
            // HEAD may fail; still accept as progressive
            AppLog.network.debug("HEAD failed for progressive: \(error.localizedDescription, privacy: .public)")
        }

        return MediaDetector.makeProgressive(from: candidate, contentLength: length, title: pageTitle)
    }

    private func upsert(_ media: DetectedMedia) {
        var isNew = false
        if let index = detected.firstIndex(where: { normalizedKey(for: $0.sourceURL) == normalizedKey(for: media.sourceURL) }) {
            // Prefer richer metadata (more variants / segment info)
            let existing = detected[index]
            let existingScore = existing.variants.count + (existing.segmentCount ?? 0)
            let newScore = media.variants.count + (media.segmentCount ?? 0)
            if newScore >= existingScore {
                detected[index] = media
                isNew = true
            }
        } else {
            detected.insert(media, at: 0)
            isNew = true
        }
        if isNew {
            onMediaDetected?(media)
        }
    }

    private func normalizedKey(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }
}
