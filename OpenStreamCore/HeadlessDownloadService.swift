import Foundation

/// Orchestration download/assemble sans UI (CLI / agent).
actor HeadlessDownloadService {
    private let store: DownloadJobStore
    private let queue: DownloadQueue
    private var updatesTask: Task<Void, Never>?

    init(storeDirectory: URL, settings: SettingsSnapshot) throws {
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: settings.downloadsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: settings.partsRoot, withIntermediateDirectories: true)
        AppPreferences.publish(settings)
        self.store = try DownloadJobStore(directory: storeDirectory)
        self.queue = DownloadQueue(
            store: store,
            downloader: SegmentFileDownloader(session: settings.makeURLSession()),
            maxConcurrentSegments: settings.maxConcurrentSegments
        )
    }

    func bootstrap() async throws -> [DownloadJob] {
        try await queue.bootstrap()
    }

    func list() async -> [DownloadJob] {
        await queue.jobsSnapshot()
    }

    func job(id: UUID) async -> DownloadJob? {
        await queue.jobsSnapshot().first { $0.id == id }
    }

    func cancel(id: UUID) async {
        await queue.cancel(id: id)
    }

    @discardableResult
    func enqueue(
        url: URL,
        kind: ManifestKind,
        title: String?,
        credentials: DownloadCredentials,
        outputDirectory: URL?,
        export: ExportMetadata? = nil
    ) async throws -> DownloadJob {
        let jobID = UUID()
        let snapshot = AppPreferences.current
        let destination = snapshot.partsDirectory(forJobID: jobID)
        let output = outputDirectory ?? snapshot.downloadsRoot
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let resolvedTitle = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? export?.title ?? url.deletingPathExtension().lastPathComponent

        let job = DownloadJob(
            id: jobID,
            title: resolvedTitle,
            kind: kind,
            sourceURL: url,
            variantURL: url,
            pageURL: credentials.referer.flatMap(URL.init(string:)),
            credentials: credentials,
            destinationDirectory: destination,
            outputDirectory: output,
            exportTitle: export?.title ?? resolvedTitle,
            exportYear: export?.year,
            exportShow: export?.show,
            exportSeason: export?.season,
            exportEpisode: export?.episode,
            exportEpisodeTitle: export?.episodeTitle,
            exportNamingPreset: export?.namingPreset ?? (export?.show != nil ? .jellyfinSeries : nil)
        )
        try await queue.enqueue(job)
        return job
    }

    /// Attend un état terminal ; émet des events progress si `onEvent` fourni.
    func wait(
        id: UUID,
        onEvent: (@Sendable (AgentEvent) -> Void)? = nil
    ) async throws -> DownloadJob {
        let stream = await queue.updates()
        if let current = await job(id: id) {
            onEvent?(Self.event(for: current))
            if current.state.isTerminal { return current }
        }

        for await update in stream {
            guard update.id == id else { continue }
            onEvent?(Self.event(for: update))
            if update.state.isTerminal {
                return update
            }
        }

        guard let final = await job(id: id) else {
            throw DownloadError.message("Job introuvable après wait")
        }
        return final
    }

    static func inferKind(from url: URL) -> ManifestKind {
        switch MediaDetector.classify(url: url, mimeType: nil) {
        case .hls: return .hls
        case .dash: return .dash
        default: return .progressive
        }
    }

    static func event(for job: DownloadJob) -> AgentEvent {
        switch job.state {
        case .queued:
            return AgentEvent(
                event: .queued,
                jobId: job.id.uuidString,
                title: job.title,
                kind: job.kind.rawValue,
                message: "queued"
            )
        case .preparing:
            return AgentEvent(
                event: .progress,
                jobId: job.id.uuidString,
                title: job.title,
                kind: job.kind.rawValue,
                progress: 0,
                message: "preparing"
            )
        case .downloading(let progress, let done, let total):
            return AgentEvent(
                event: .progress,
                jobId: job.id.uuidString,
                title: job.title,
                kind: job.kind.rawValue,
                progress: progress,
                completedUnits: done,
                totalUnits: total,
                message: job.state.label
            )
        case .assembling:
            return AgentEvent(
                event: .assembling,
                jobId: job.id.uuidString,
                title: job.title,
                kind: job.kind.rawValue,
                progress: 0.99,
                message: "assembling"
            )
        case .completed:
            return AgentEvent(
                event: .completed,
                jobId: job.id.uuidString,
                title: job.title,
                kind: job.kind.rawValue,
                progress: 1,
                path: job.exportURL?.path,
                message: "completed"
            )
        case .failed(let message):
            return AgentEvent(
                event: .failed,
                jobId: job.id.uuidString,
                title: job.title,
                kind: job.kind.rawValue,
                message: message
            )
        case .cancelled:
            return AgentEvent(
                event: .cancelled,
                jobId: job.id.uuidString,
                title: job.title,
                kind: job.kind.rawValue,
                message: "cancelled"
            )
        }
    }

    static func exitCode(for job: DownloadJob) -> Int32 {
        switch job.state {
        case .completed: return Int32(AgentExitCode.success)
        case .cancelled: return Int32(AgentExitCode.cancelled)
        case .failed(let message):
            let lower = message.lowercased()
            if lower.contains("ffmpeg") || lower.contains("assembl") {
                return Int32(AgentExitCode.assemble)
            }
            return Int32(AgentExitCode.network)
        default:
            return Int32(AgentExitCode.network)
        }
    }
}
