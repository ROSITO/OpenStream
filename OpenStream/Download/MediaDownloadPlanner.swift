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
        var name = url.lastPathComponent
        if name.isEmpty || name == "/" {
            name = "video.mp4"
        }
        name = sanitize(name)
        // URL sans extension (CDN opaque) → forcer .mp4 pour l’assembleur.
        if (name as NSString).pathExtension.isEmpty {
            name += ".mp4"
        }
        return [
            DownloadUnit(
                index: indexOffset,
                url: url,
                fileName: directoryPrefix + name
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

    /// Playlist locale pointant vers les fichiers déjà téléchargés (EXTINF conservés).
    static func writeLocalMediaPlaylist(
        media: HLSMediaPlaylist,
        units: [DownloadUnit],
        to directory: URL
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-PLAYLIST-TYPE:VOD"
        ]
        if let target = media.targetDuration {
            lines.append("#EXT-X-TARGETDURATION:\(Int(ceil(target)))")
        }
        if let seq = media.mediaSequence {
            lines.append("#EXT-X-MEDIA-SEQUENCE:\(seq)")
        }

        let segmentUnits = units.filter { !$0.fileName.contains("_init") }
        // Aligner unités ↔ segments playlist (même ordre).
        let count = min(segmentUnits.count, media.segments.count)
        for i in 0..<count {
            let duration = media.segments[i].duration
            let fileName = URL(fileURLWithPath: segmentUnits[i].fileName).lastPathComponent
            lines.append(String(format: "#EXTINF:%.3f,", duration))
            lines.append(fileName)
        }
        if media.hasEndList {
            lines.append("#EXT-X-ENDLIST")
        }

        let playlistURL = directory.appendingPathComponent("playlist.m3u8")
        try lines.joined(separator: "\n").write(to: playlistURL, atomically: true, encoding: .utf8)
    }

    private static func extensionFor(_ url: URL, fallback: String) -> String {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return fallback }
        // CDN TikTok / proxies : extension leurre devant du MPEG-TS réel.
        let decoys: Set<String> = ["image", "png", "jpg", "jpeg", "gif", "webp", "bin", "dat", "img"]
        if decoys.contains(ext) {
            return ".ts"
        }
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
        maxRetries: Int = 3,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> SegmentDownloadResult {
        if isCancelled() { throw DownloadError.cancelled }

        let destination = directory.appendingPathComponent(unit.fileName)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Accepte aussi un rename .image → .ts déjà fait.
        if let existing = existingNonEmptyFile(at: destination)
            ?? existingAlternate(for: destination)
        {
            return existing
        }

        var lastError: Error = DownloadError.message("Échec téléchargement")
        // 429/503 : plus de tentatives + backoff long (CDN TikTok etc.).
        let baseAttempts = max(1, maxRetries + 1)
        let attempts = max(baseAttempts, 10)
        for attempt in 1...attempts {
            if isCancelled() { throw DownloadError.cancelled }
            do {
                return try await downloadOnce(
                    unit: unit,
                    to: destination,
                    credentials: credentials,
                    isCancelled: isCancelled,
                    onProgress: onProgress
                )
            } catch let error as DownloadError where error == .cancelled {
                throw error
            } catch let error as DownloadError {
                lastError = error
                guard attempt < attempts else { break }
                let delayNs = retryDelayNanoseconds(for: error, attempt: attempt)
                AppLog.download.debug(
                    "Retry \(attempt, privacy: .public)/\(attempts, privacy: .public) \(unit.fileName, privacy: .public) after \(error.localizedDescription, privacy: .public) sleep=\(delayNs / 1_000_000_000, privacy: .public)s"
                )
                try? await Task.sleep(nanoseconds: delayNs)
            } catch {
                lastError = error
                guard attempt < attempts else { break }
                let delayNs = UInt64(min(8, attempt * 2)) * 200_000_000
                try? await Task.sleep(nanoseconds: delayNs)
            }
        }
        throw lastError
    }

    private func retryDelayNanoseconds(for error: DownloadError, attempt: Int) -> UInt64 {
        if case .httpStatus(let code, let retryAfter) = error, code == 429 || code == 503 || code == 502 || code == 504 {
            if let retryAfter, retryAfter > 0 {
                return UInt64(min(120, retryAfter)) * 1_000_000_000
            }
            // 2s, 4s, 8s… plafonné à 60s
            let seconds = min(60.0, pow(2.0, Double(attempt)))
            return UInt64(seconds * 1_000_000_000)
        }
        return UInt64(min(8, attempt * 2)) * 200_000_000
    }

    private func existingAlternate(for destination: URL) -> SegmentDownloadResult? {
        let stem = destination.deletingPathExtension().lastPathComponent
        let dir = destination.deletingLastPathComponent()
        for ext in ["ts", "m4s", "mp4", "image"] {
            let candidate = dir.appendingPathComponent("\(stem).\(ext)")
            if candidate.path == destination.path { continue }
            if let hit = existingNonEmptyFile(at: candidate) { return hit }
        }
        return nil
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
        isCancelled: @Sendable () -> Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> SegmentDownloadResult {
        var request = URLRequest(url: unit.url)
        request.setValue(credentials.userAgent, forHTTPHeaderField: "User-Agent")
        if let cookie = credentials.cookieHeader {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let referer = credentials.referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }

        // Gros fichiers (MP4) : delegate avec progression. Petits segments : download async simple.
        let wantsProgress = onProgress != nil
            || !Self.shouldNormalizeOnDisk(destination: destination, byteCount: 1)

        let tempURL: URL
        let response: URLResponse
        if wantsProgress {
            let streamed = try await Self.streamDownload(
                request: request,
                sessionConfig: session.configuration,
                isCancelled: isCancelled,
                onProgress: onProgress
            )
            tempURL = streamed.fileURL
            response = streamed.response
        } else {
            let pair = try await session.download(for: request)
            tempURL = pair.0
            response = pair.1
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        if isCancelled() { throw DownloadError.cancelled }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw DownloadError.httpStatus(http.statusCode, retryAfterSeconds: retryAfter)
        }

        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: tempURL.path)
        let byteCount = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount > 0 else {
            throw DownloadError.message("Segment vide (\(unit.fileName))")
        }

        // Normalisation leurre PNG→TS uniquement sur petits segments HLS/CDN.
        if Self.shouldNormalizeOnDisk(destination: destination, byteCount: byteCount) {
            let data = try Data(contentsOf: tempURL, options: [.mappedIfSafe])
            let normalized = MediaSegmentNormalizer.normalize(data)
            if normalized.strippedBytes > 0 {
                AppLog.download.debug(
                    "Stripped \(normalized.strippedBytes, privacy: .public)B decoy from \(unit.fileName, privacy: .public) → \(normalized.kind.rawValue, privacy: .public)"
                )
            }

            var finalDestination = destination
            let currentExt = destination.pathExtension
            let preferred = MediaSegmentNormalizer.preferredExtension(
                for: normalized.kind,
                currentExtension: currentExt
            )
            if normalized.kind != .unknown,
               !currentExt.isEmpty,
               preferred != currentExt.lowercased(),
               ["image", "png", "jpg", "jpeg", "gif", "webp", "bin", "dat"].contains(currentExt.lowercased())
            {
                finalDestination = destination.deletingPathExtension().appendingPathExtension(preferred)
            }

            try Self.commitFile(data: normalized.data, to: finalDestination, replacing: destination)
            return SegmentDownloadResult(url: finalDestination, byteCount: Int64(normalized.data.count))
        }

        try Self.commitDownloadedFile(from: tempURL, to: destination)
        return SegmentDownloadResult(url: destination, byteCount: byteCount)
    }

    /// Télécharge vers un fichier temp avec callbacks de progression (MP4 progressifs).
    private static func streamDownload(
        request: URLRequest,
        sessionConfig: URLSessionConfiguration,
        isCancelled: @Sendable () -> Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> (fileURL: URL, response: URLResponse) {
        let bridge = StreamDownloadBridge(onProgress: onProgress)
        let config = sessionConfig.copy() as! URLSessionConfiguration
        let session = URLSession(configuration: config, delegate: bridge, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let task = session.downloadTask(with: request)
        bridge.attach(task)
        task.resume()

        let outcome = try await withTaskCancellationHandler {
            while !Task.isCancelled {
                if isCancelled() {
                    task.cancel()
                    throw DownloadError.cancelled
                }
                if let result = bridge.pollResult() {
                    switch result {
                    case .success(let value):
                        return value
                    case .failure(let error):
                        throw error
                    }
                }
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
            task.cancel()
            throw DownloadError.cancelled
        } onCancel: {
            task.cancel()
        }
        return outcome
    }

    /// Heuristique : segments HLS / leurres CDN seulement — pas les MP4 progressifs volumineux.
    private static func shouldNormalizeOnDisk(destination: URL, byteCount: Int64) -> Bool {
        let maxNormalizeBytes: Int64 = 32 * 1024 * 1024
        guard byteCount <= maxNormalizeBytes else { return false }
        let ext = destination.pathExtension.lowercased()
        let segmentLike: Set<String> = [
            "ts", "m4s", "m4a", "aac", "cmfv", "cmfa",
            "image", "png", "jpg", "jpeg", "gif", "webp", "bin", "dat", "img"
        ]
        return segmentLike.contains(ext)
    }

    private static func commitDownloadedFile(from tempURL: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let partial = destination.appendingPathExtension("partial")
        if fm.fileExists(atPath: partial.path) {
            try? fm.removeItem(at: partial)
        }
        // Copie puis rename atomique (le temp URLSession peut être sur un autre volume).
        try fm.copyItem(at: tempURL, to: partial)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: partial, to: destination)
    }

    private static func commitFile(data: Data, to finalDestination: URL, replacing legacy: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: finalDestination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let partial = finalDestination.appendingPathExtension("partial")
        if fm.fileExists(atPath: partial.path) {
            try? fm.removeItem(at: partial)
        }
        try data.write(to: partial, options: .atomic)
        if finalDestination.path != legacy.path, fm.fileExists(atPath: legacy.path) {
            try? fm.removeItem(at: legacy)
        }
        if fm.fileExists(atPath: finalDestination.path) {
            try fm.removeItem(at: finalDestination)
        }
        try fm.moveItem(at: partial, to: finalDestination)
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
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw DownloadError.httpStatus(http.statusCode, retryAfterSeconds: retryAfter)
        }
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            return text
        }
        throw DownloadError.message("Impossible de décoder la playlist")
    }
}

/// Pont delegate → async pour un seul downloadTask (progression octects).
private final class StreamDownloadBridge: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let onProgress: (@Sendable (Int64, Int64) -> Void)?
    private var result: Result<(fileURL: URL, response: URLResponse), Error>?
    private var task: URLSessionDownloadTask?
    private var copiedFile: URL?

    init(onProgress: (@Sendable (Int64, Int64) -> Void)?) {
        self.onProgress = onProgress
    }

    func attach(_ task: URLSessionDownloadTask) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func pollResult() -> Result<(fileURL: URL, response: URLResponse), Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Le fichier temp disparaît à la sortie de cette méthode → copie immédiate.
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("os-dl-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: location, to: copy)
            lock.lock()
            copiedFile = copy
            lock.unlock()
        } catch {
            lock.lock()
            result = .failure(error)
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        if result != nil { return }
        if let error {
            if let copiedFile {
                try? FileManager.default.removeItem(at: copiedFile)
            }
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled {
                result = .failure(DownloadError.cancelled)
            } else {
                result = .failure(error)
            }
            return
        }
        guard let copiedFile,
              let response = task.response
        else {
            result = .failure(DownloadError.message("Téléchargement incomplet"))
            return
        }
        result = .success((copiedFile, response))
    }
}
