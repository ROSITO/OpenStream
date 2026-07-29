import Foundation

struct DownloadUnit: Sendable {
    let index: Int
    let url: URL
    let fileName: String
}

enum DownloadUnitOffset {
    static let audio = 1_000_000
    static let subtitle = 2_000_000
}

enum MediaDownloadPlanner {
    static func progressiveUnit(url: URL, directoryPrefix: String = "", indexOffset: Int = 0) -> [DownloadUnit] {
        let name = url.lastPathComponent.isEmpty ? "video.mp4" : url.lastPathComponent
        return [
            DownloadUnit(
                index: indexOffset,
                url: url,
                fileName: directoryPrefix + sanitize(name)
            )
        ]
    }

    static func hlsUnits(
        from playlist: HLSPlaylist,
        directoryPrefix: String = "",
        indexOffset: Int = 0
    ) throws -> [DownloadUnit] {
        guard playlist.kind == .media, let media = playlist.media else {
            throw DownloadError.invalidPlaylist
        }
        var units: [DownloadUnit] = []
        if let map = media.mapURI {
            units.append(
                DownloadUnit(
                    index: indexOffset,
                    url: map,
                    fileName: directoryPrefix + "00000_init" + extensionFor(map, fallback: ".mp4")
                )
            )
        }
        let baseIndex = units.isEmpty ? 0 : 1
        guard !media.segments.isEmpty else { throw DownloadError.emptyPlaylist }
        for (offset, segment) in media.segments.enumerated() {
            let index = baseIndex + offset
            let ext = extensionFor(segment.uri, fallback: ".ts")
            let name = String(format: "%05d_seg%@", index, ext)
            units.append(
                DownloadUnit(
                    index: indexOffset + index,
                    url: segment.uri,
                    fileName: directoryPrefix + name
                )
            )
        }
        return units
    }

    private static func extensionFor(_ url: URL, fallback: String) -> String {
        let ext = url.pathExtension
        if ext.isEmpty { return fallback }
        return ".\(ext)"
    }

    private static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return name.components(separatedBy: invalid).joined(separator: "_")
    }
}

struct SegmentDownloadResult: Sendable {
    let url: URL
    let byteCount: Int64
}

struct SegmentFileDownloader: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func download(
        unit: DownloadUnit,
        to directory: URL,
        credentials: DownloadCredentials,
        isCancelled: @Sendable () -> Bool,
        maxRetries: Int = 3
    ) async throws -> SegmentDownloadResult {
        if isCancelled() { throw DownloadError.cancelled }

        let destination = directory.appendingPathComponent(unit.fileName)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let existing = existingNonEmptyFile(at: destination) {
            return existing
        }

        var lastError: Error = DownloadError.message("Échec téléchargement")
        let attempts = max(1, maxRetries + 1)
        for attempt in 1...attempts {
            if isCancelled() { throw DownloadError.cancelled }
            do {
                return try await downloadOnce(unit: unit, to: destination, credentials: credentials, isCancelled: isCancelled)
            } catch let error as DownloadError where error == .cancelled {
                throw error
            } catch {
                lastError = error
                if attempt < attempts {
                    let delay = UInt64(min(8, attempt * 2)) * 200_000_000
                    try? await Task.sleep(nanoseconds: delay)
                    AppLog.download.debug("Retry \(attempt, privacy: .public)/\(attempts, privacy: .public) \(unit.fileName, privacy: .public)")
                }
            }
        }
        throw lastError
    }

    private func existingNonEmptyFile(at destination: URL) -> SegmentDownloadResult? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path) else { return nil }
        guard let attrs = try? fm.attributesOfItem(atPath: destination.path),
              let size = attrs[.size] as? NSNumber,
              size.int64Value > 0
        else {
            try? fm.removeItem(at: destination)
            return nil
        }
        return SegmentDownloadResult(url: destination, byteCount: size.int64Value)
    }

    private func downloadOnce(
        unit: DownloadUnit,
        to destination: URL,
        credentials: DownloadCredentials,
        isCancelled: @Sendable () -> Bool
    ) async throws -> SegmentDownloadResult {
        var request = URLRequest(url: unit.url)
        request.setValue(credentials.userAgent, forHTTPHeaderField: "User-Agent")
        if let cookie = credentials.cookieHeader {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let referer = credentials.referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }

        let (data, response) = try await session.data(for: request)
        if isCancelled() { throw DownloadError.cancelled }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DownloadError.httpStatus(http.statusCode)
        }
        guard !data.isEmpty else {
            throw DownloadError.message("Segment vide (\(unit.fileName))")
        }

        let partial = destination.appendingPathExtension("partial")
        let fm = FileManager.default
        if fm.fileExists(atPath: partial.path) {
            try? fm.removeItem(at: partial)
        }
        try data.write(to: partial, options: .atomic)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: partial, to: destination)
        return SegmentDownloadResult(url: destination, byteCount: Int64(data.count))
    }

    func fetchText(url: URL, credentials: DownloadCredentials) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(credentials.userAgent, forHTTPHeaderField: "User-Agent")
        if let cookie = credentials.cookieHeader {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let referer = credentials.referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DownloadError.httpStatus(http.statusCode)
        }
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            return text
        }
        throw DownloadError.message("Impossible de décoder la playlist")
    }
}
