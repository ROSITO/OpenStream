import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class DownloadManager {
    private(set) var jobs: [DownloadJob] = []
    private(set) var lastError: String?
    private(set) var lastInfo: String?
    private(set) var isRepairingSync = false

    private let queue: DownloadQueue
    private var updatesTask: Task<Void, Never>?
    var historyStore: DownloadHistoryStore?

    init(queue: DownloadQueue? = nil) throws {
        if let queue {
            self.queue = queue
        } else {
            let store = try DownloadJobStore()
            self.queue = DownloadQueue(store: store)
        }
    }

    /// Enfile un job à partir d’une URL média déjà classifiée (batch / CLI / historique).
    func enqueueDirectURL(
        _ url: URL,
        kind: ManifestKind,
        title: String? = nil,
        pageURL: URL? = nil,
        credentials: DownloadCredentials,
        outputDirectory: URL? = nil
    ) {
        let variant = MediaVariant(playlistURL: url)
        let media = DetectedMedia(
            sourceURL: url,
            kind: kind,
            suggestedTitle: title ?? url.lastPathComponent,
            pageURL: pageURL,
            variants: [variant],
            preferredVariantID: variant.id,
            isVOD: true
        )
        enqueue(
            media: media,
            variant: variant,
            credentials: credentials,
            outputDirectory: outputDirectory
        )
    }

    func enqueue(
        media: DetectedMedia,
        variant: MediaVariant? = nil,
        audioTrack: MediaTrack? = nil,
        subtitleTrack: MediaTrack? = nil,
        credentials: DownloadCredentials,
        outputDirectory: URL? = nil,
        metadata: ExportMetadata? = nil
    ) {
        let selected = variant ?? media.preferredVariant
        guard let selected else {
            lastError = "Aucune variante disponible"
            return
        }

        let jobID = UUID()
        let snapshot = AppPreferences.current
        let destination = snapshot.partsDirectory(forJobID: jobID)
        let output = outputDirectory ?? snapshot.downloadsRoot
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let inferred = ExportMetadata.inferred(from: media.displayTitle)
        let meta = metadata ?? inferred
        let titleSource: String = {
            if let t = meta.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                return t
            }
            return media.displayTitle
        }()
        let title = Self.sanitizedTitle(titleSource)

        let resolvedAudio = audioTrack ?? Self.defaultAudioTrack(for: media)
        let resolvedSubtitle = subtitleTrack

        let job = DownloadJob(
            id: jobID,
            title: title,
            kind: media.kind,
            sourceURL: media.sourceURL,
            variantURL: selected.playlistURL,
            pageURL: media.pageURL,
            credentials: credentials,
            destinationDirectory: destination,
            outputDirectory: output,
            selectedAudioTrackURL: resolvedAudio?.url,
            selectedAudioDashRepresentationID: resolvedAudio?.dashRepresentationID,
            selectedSubtitleTrackURL: resolvedSubtitle?.url,
            selectedSubtitleDashRepresentationID: resolvedSubtitle?.dashRepresentationID,
            selectedDashVideoRepresentationID: selected.dashRepresentationID,
            exportTitle: meta.title ?? title,
            exportYear: meta.year ?? inferred.year,
            exportShow: meta.show,
            exportSeason: meta.season,
            exportEpisode: meta.episode,
            exportEpisodeTitle: meta.episodeTitle,
            exportNamingPreset: meta.namingPreset
        )

        Task {
            do {
                try await queue.enqueue(job)
                upsertLocal(job)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Inclut une piste audio externe si le flux en a (DASH toujours ; HLS démuxé type Lanterns).
    /// Préférence : français (`fr`/`fra`/`fre`) > piste `DEFAULT` > première piste.
    static func defaultAudioTrack(for media: DetectedMedia) -> MediaTrack? {
        guard !media.audioTracks.isEmpty else { return nil }
        if media.kind == .dash || media.kind == .hls {
            return MediaTrack.preferredAudio(from: media.audioTracks)
        }
        return nil
    }

    func cancel(_ id: UUID) {
        Task { await queue.cancel(id: id) }
    }

    func resume(_ id: UUID) {
        Task {
            do {
                try await queue.resume(id: id)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func remove(_ id: UUID) {
        Task {
            do {
                // Supprimer aussi le MP4 exporté si présent (pas les autres films du dossier)
                if let job = jobs.first(where: { $0.id == id }), let exportURL = job.exportURL {
                    try? FileManager.default.removeItem(at: exportURL)
                }
                try await queue.remove(id: id)
                jobs.removeAll { $0.id == id }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func reveal(_ job: DownloadJob) {
        if let exportURL = job.exportURL {
            NSWorkspace.shared.activateFileViewerSelecting([exportURL])
            return
        }
        let url: URL
        if case .completed(let directory) = job.state {
            url = directory
        } else {
            url = job.destinationDirectory
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func assembleExisting(_ job: DownloadJob) {
        Task {
            do {
                try await queue.assembleExisting(id: job.id)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Corrige le décalage son/image d’un MP4 déjà exporté (bouton UI).
    func repairAVSync(at url: URL) {
        guard !isRepairingSync else { return }
        isRepairingSync = true
        lastError = nil
        lastInfo = "Réparation sync…"
        Task {
            defer { isRepairingSync = false }
            do {
                let assembler = try MediaAssembler()
                let result = try await assembler.repairAVSync(at: url)
                lastInfo = result.userMessage
                AppLog.ffmpeg.info("AV sync repair: \(result.userMessage, privacy: .public)")
            } catch {
                lastInfo = nil
                lastError = error.localizedDescription
            }
        }
    }

    func repairAVSync(_ job: DownloadJob) {
        guard let exportURL = job.exportURL,
              FileManager.default.fileExists(atPath: exportURL.path)
        else {
            lastError = "MP4 introuvable pour ce téléchargement"
            return
        }
        repairAVSync(at: exportURL)
    }

    /// Applique un décalage audio manuel (secondes ; + = retarder l’audio).
    func applyManualAudioShift(at url: URL, audioShiftSeconds: Double) async throws -> AVSyncRepairResult {
        isRepairingSync = true
        lastError = nil
        lastInfo = "Ajustement sync…"
        defer { isRepairingSync = false }
        do {
            let assembler = try MediaAssembler()
            let result = try await assembler.applyManualAudioShift(
                at: url,
                audioShiftSeconds: audioShiftSeconds
            )
            lastInfo = result.userMessage
            AppLog.ffmpeg.info("AV sync manual: \(result.userMessage, privacy: .public)")
            return result
        } catch {
            lastInfo = nil
            lastError = error.localizedDescription
            throw error
        }
    }

    func start() {
        updatesTask?.cancel()
        updatesTask = Task { [weak self] in
            guard let self else { return }
            do {
                let initial = try await self.queue.bootstrap()
                await MainActor.run {
                    self.jobs = initial
                }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                }
            }

            for await job in await self.queue.updates() {
                await MainActor.run {
                    self.upsertLocal(job)
                }
            }
        }
    }

    private func upsertLocal(_ job: DownloadJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.insert(job, at: 0)
        }
        switch job.state {
        case .completed, .failed:
            historyStore?.record(from: job)
        default:
            break
        }
    }

    static func sanitizedTitle(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = trimmed.components(separatedBy: invalid).joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
        let result = cleaned.isEmpty ? "video" : cleaned
        return String(result.prefix(120))
    }
}
