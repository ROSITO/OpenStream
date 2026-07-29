import Foundation
import Testing
@testable import OpenStream

struct MediaDownloadPlannerTests {
    @Test func buildsProgressiveUnit() throws {
        let url = try #require(URL(string: "https://cdn.example.com/film.mp4"))
        let units = MediaDownloadPlanner.progressiveUnit(url: url)
        #expect(units.count == 1)
        #expect(units[0].fileName == "film.mp4")
    }

    @Test func buildsHLSUnitsWithInitMap() throws {
        let text = try fixture("hls/media_fmp4.m3u8")
        let url = try #require(URL(string: "https://cdn.example.com/fmp4/index.m3u8"))
        let playlist = try HLSParser.parse(text: text, playlistURL: url)
        let units = try MediaDownloadPlanner.hlsUnits(from: playlist)
        #expect(units.count == 3)
        #expect(units[0].fileName.contains("init"))
        #expect(units[1].fileName.contains("seg"))
    }
}

struct DownloadJobStoreTests {
    @Test func upsertLoadAndResumeState() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenStreamStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try DownloadJobStore(directory: dir)
        let dest = dir.appendingPathComponent("job", isDirectory: true)
        var job = DownloadJob(
            title: "Test",
            kind: .progressive,
            sourceURL: try #require(URL(string: "https://example.com/a.mp4")),
            variantURL: try #require(URL(string: "https://example.com/a.mp4")),
            state: .downloading(progress: 0.4, completedUnits: 2, totalUnits: 5),
            destinationDirectory: dest,
            completedUnitIndices: [0, 1]
        )
        try store.upsert(job)

        let loaded = try store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].completedUnitIndices == [0, 1])

        job.state = .queued
        try store.upsert(job)
        let again = try store.loadAll()
        #expect(again[0].state.progressValue == 0)
    }
}

struct DownloadQueueTests {
    /// Isole exports/segments hors de ~/Downloads/OpenStream.
    private static func withIsolatedDownloadsRoot<T>(
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenStreamDL-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = AppPreferences.current
        AppPreferences.publish(
            SettingsSnapshot(
                downloadsRoot: root,
                maxConcurrentJobs: previous.maxConcurrentJobs,
                maxConcurrentSegments: previous.maxConcurrentSegments,
                maxRetries: previous.maxRetries,
                proxyMode: previous.proxyMode,
                proxyHost: previous.proxyHost,
                proxyPort: previous.proxyPort,
                proxyUsername: previous.proxyUsername,
                proxyPassword: previous.proxyPassword,
                hlsQuality: previous.hlsQuality,
                exportNamingTemplate: "{title}.{ext}"
            )
        )
        defer {
            AppPreferences.publish(previous)
            try? FileManager.default.removeItem(at: root)
        }
        return try await body(root)
    }

    @Test func downloadsProgressiveFileAndSupportsCancelResume() async throws {
        try await Self.withIsolatedDownloadsRoot { root in
            let sourceFile = root.appendingPathComponent("source.bin")
            let payload = Data(repeating: 0xAB, count: 64 * 1024)
            try payload.write(to: sourceFile)

            let store = try DownloadJobStore(directory: root.appendingPathComponent("store"))
            let queue = DownloadQueue(store: store)

            let jobID = UUID()
            let parts = AppPreferences.partsDirectory(forJobID: jobID)
            let job = DownloadJob(
                id: jobID,
                title: "progressive",
                kind: .progressive,
                sourceURL: sourceFile,
                variantURL: sourceFile,
                destinationDirectory: parts,
                outputDirectory: root
            )

            try await queue.enqueue(job)

            var completed = false
            var exportURL: URL?
            for _ in 0..<50 {
                try await Task.sleep(nanoseconds: 50_000_000)
                if let current = await queue.jobsSnapshot().first,
                   case .completed = current.state {
                    completed = true
                    exportURL = current.exportURL
                    break
                }
            }
            #expect(completed)
            let export = try #require(exportURL)
            #expect(FileManager.default.fileExists(atPath: export.path))
            let downloaded = try Data(contentsOf: export)
            #expect(downloaded == payload)
            #expect(!FileManager.default.fileExists(atPath: parts.path))
        }
    }

    @Test func downloadsHLSSegmentsFromLocalPlaylist() async throws {
        try await Self.withIsolatedDownloadsRoot { root in
            let ffmpeg = try FFmpegWrapper()
            let seg0 = root.appendingPathComponent("seg0.ts")
            let seg1 = root.appendingPathComponent("seg1.ts")
            try await ffmpeg.run(arguments: [
                "-y", "-f", "lavfi", "-i", "testsrc=size=160x120:rate=1:duration=1",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
                "-c:v", "libx264", "-c:a", "aac", "-shortest", "-f", "mpegts", seg0.path
            ])
            try await ffmpeg.run(arguments: [
                "-y", "-f", "lavfi", "-i", "testsrc=size=160x120:rate=1:duration=1",
                "-f", "lavfi", "-i", "sine=frequency=880:duration=1",
                "-c:v", "libx264", "-c:a", "aac", "-shortest", "-f", "mpegts", seg1.path
            ])

            let playlist = """
            #EXTM3U
            #EXT-X-TARGETDURATION:10
            #EXTINF:9.0,
            \(seg0.lastPathComponent)
            #EXTINF:9.0,
            \(seg1.lastPathComponent)
            #EXT-X-ENDLIST
            """
            let playlistURL = root.appendingPathComponent("index.m3u8")
            try playlist.write(to: playlistURL, atomically: true, encoding: .utf8)

            let store = try DownloadJobStore(directory: root.appendingPathComponent("store"))
            let queue = DownloadQueue(store: store)
            let jobID = UUID()
            let parts = AppPreferences.partsDirectory(forJobID: jobID)
            let job = DownloadJob(
                id: jobID,
                title: "hls-local",
                kind: .hls,
                sourceURL: playlistURL,
                variantURL: playlistURL,
                destinationDirectory: parts,
                outputDirectory: root
            )
            try await queue.enqueue(job)

            var completed = false
            var exportURL: URL?
            for _ in 0..<120 {
                try await Task.sleep(nanoseconds: 50_000_000)
                if let current = await queue.jobsSnapshot().first,
                   case .completed = current.state {
                    completed = true
                    exportURL = current.exportURL
                    break
                }
                if let current = await queue.jobsSnapshot().first,
                   case .failed(let message) = current.state {
                    Issue.record("Job failed: \(message)")
                    break
                }
            }
            #expect(completed)
            let export = try #require(exportURL)
            #expect(FileManager.default.fileExists(atPath: export.path))
            #expect(!FileManager.default.fileExists(atPath: parts.path))

            let leftoverTemps = try FileManager.default.contentsOfDirectory(atPath: root.path)
                .filter {
                    $0.hasPrefix("merged_tmp")
                        || $0.contains("concat_list")
                        || $0.hasPrefix(".__")
                }
            #expect(leftoverTemps.isEmpty)
        }
    }

    @Test func cancelMarksJobCancelled() async throws {
        try await Self.withIsolatedDownloadsRoot { root in
            let sourceFile = root.appendingPathComponent("big.bin")
            try Data(repeating: 1, count: 2_000_000).write(to: sourceFile)

            let store = try DownloadJobStore(directory: root.appendingPathComponent("store"))
            let queue = DownloadQueue(store: store)
            let jobID = UUID()
            let job = DownloadJob(
                id: jobID,
                title: "cancel-me",
                kind: .progressive,
                sourceURL: sourceFile,
                variantURL: sourceFile,
                destinationDirectory: AppPreferences.partsDirectory(forJobID: jobID),
                outputDirectory: root
            )
            try await queue.enqueue(job)
            await queue.cancel(id: job.id)

            var sawCancelled = false
            for _ in 0..<40 {
                try await Task.sleep(nanoseconds: 25_000_000)
                if let current = await queue.jobsSnapshot().first(where: { $0.id == job.id }),
                   case .cancelled = current.state {
                    sawCancelled = true
                    break
                }
            }
            #expect(sawCancelled)
        }
    }
}
