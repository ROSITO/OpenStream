import Foundation

actor DownloadQueue {
    private let store: DownloadJobStore
    private var downloader: SegmentFileDownloader
    /// Override optionnel (tests) ; sinon lit `AppPreferences.current.maxConcurrentSegments`.
    private let maxConcurrentSegmentsOverride: Int?

    private var jobs: [UUID: DownloadJob] = [:]
    private var jobOrder: [UUID] = []
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var cancellationFlags: [UUID: Bool] = [:]
    private var runningCount = 0
    /// Reprises auto après 429/503 (par job).
    private var autoRetryCounts: [UUID: Int] = [:]
    /// Jobs en cooldown : `pump` ne les reprend pas avant cette date.
    private var retryAvailableAt: [UUID: Date] = [:]
    private static let maxAutoRetries = 12

    private var continuations: [UUID: AsyncStream<DownloadJob>.Continuation] = [:]

    init(
        store: DownloadJobStore,
        downloader: SegmentFileDownloader = SegmentFileDownloader(),
        maxConcurrentSegments: Int? = nil
    ) {
        self.store = store
        self.downloader = downloader
        self.maxConcurrentSegmentsOverride = maxConcurrentSegments.map { max(1, $0) }
    }

    private var segmentConcurrency: Int {
        if let maxConcurrentSegmentsOverride { return maxConcurrentSegmentsOverride }
        return max(1, AppPreferences.current.maxConcurrentSegments)
    }

    func bootstrap() async throws -> [DownloadJob] {
        let loaded = try store.loadAll()
        for var job in loaded {
            switch job.state {
            case .downloading, .preparing, .assembling:
                // Reprendre : si segments déjà là, repasser en queued pour re-télécharger manquants puis assembler
                job.state = .queued
                job.updatedAt = Date()
                try store.upsert(job)
            case .failed(let message):
                // Relance auto au démarrage si l’échec ressemble à du rate-limit / réseau.
                if Self.looksTransientFailure(message) {
                    AppLog.download.info("Bootstrap auto-retry for \(job.title, privacy: .public)")
                    job.state = .queued
                    job.updatedAt = Date()
                    try store.upsert(job)
                }
            default:
                break
            }
            jobs[job.id] = job
            if !jobOrder.contains(job.id) {
                jobOrder.append(job.id)
            }
        }
        pump()
        return jobOrder.compactMap { jobs[$0] }
    }

    private static func looksTransientFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("429")
            || lower.contains("503")
            || lower.contains("502")
            || lower.contains("504")
            || lower.contains("timed out")
            || lower.contains("timeout")
            || lower.contains("segment(s) en échec")
            || lower.contains("reprends le téléchargement")
    }

    func jobsSnapshot() -> [DownloadJob] {
        jobOrder.compactMap { jobs[$0] }
    }

    func enqueue(_ job: DownloadJob) async throws {
        var job = job
        job.state = .queued
        job.updatedAt = Date()
        jobs[job.id] = job
        if let existing = jobOrder.firstIndex(of: job.id) {
            jobOrder.remove(at: existing)
        }
        jobOrder.insert(job.id, at: 0)
        cancellationFlags[job.id] = false
        try store.upsert(job)
        publish(job)
        pump()
    }

    func cancel(id: UUID) async {
        cancellationFlags[id] = true
        retryAvailableAt[id] = nil
        autoRetryCounts[id] = 0
        runningTasks[id]?.cancel()
        if var job = jobs[id], !job.state.isTerminal {
            job.state = .cancelled
            job.updatedAt = Date()
            jobs[id] = job
            try? store.upsert(job)
            publish(job)
        }
        if runningTasks[id] != nil {
            runningTasks[id] = nil
            if runningCount > 0 { runningCount -= 1 }
        }
        pump()
    }

    func resume(id: UUID) async throws {
        guard var job = jobs[id] else { return }
        switch job.state {
        case .cancelled, .failed, .queued:
            break
        default:
            return
        }
        cancellationFlags[id] = false
        retryAvailableAt[id] = nil
        job.state = .queued
        job.updatedAt = Date()
        jobs[id] = job
        try store.upsert(job)
        publish(job)
        pump()
    }

    func remove(id: UUID) async throws {
        let partsDir = AppPreferences.partsDirectory(forJobID: id)
        let destination = jobs[id]?.destinationDirectory
        cancellationFlags[id] = true
        retryAvailableAt[id] = nil
        autoRetryCounts[id] = 0
        runningTasks[id]?.cancel()
        if runningTasks[id] != nil {
            runningTasks[id] = nil
            if runningCount > 0 { runningCount -= 1 }
        }
        jobs[id] = nil
        jobOrder.removeAll { $0 == id }
        try store.delete(id: id)
        // Segments / temporaires — jamais le MP4 d’export
        Self.cleanupSegmentsDirectory(partsDir)
        if let destination {
            Self.cleanupSegmentsDirectory(destination)
        }
    }

    /// Assemble un dossier de segments déjà téléchargé (sans re-download).
    func assembleExisting(id: UUID) async throws {
        guard var job = jobs[id] else {
            throw DownloadError.message("Job introuvable")
        }
        cancellationFlags[id] = false
        job.state = .assembling
        job.updatedAt = Date()
        jobs[id] = job
        try store.upsert(job)
        publish(job)

        do {
            try await finalizeWithAssembly(jobID: id)
        } catch {
            if var failed = jobs[id] {
                failed.state = .failed(message: error.localizedDescription)
                failed.updatedAt = Date()
                jobs[id] = failed
                try? store.upsert(failed)
                publish(failed)
            }
            throw error
        }
    }

    func updates() -> AsyncStream<DownloadJob> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func publish(_ job: DownloadJob) {
        for continuation in continuations.values {
            continuation.yield(job)
        }
    }

    private func pump() {
        let now = Date()
        let maxJobs = max(1, AppPreferences.current.maxConcurrentJobs)
        while runningCount < maxJobs {
            guard let nextID = jobOrder.first(where: { id in
                guard let job = jobs[id], runningTasks[id] == nil else { return false }
                if let until = retryAvailableAt[id], until > now { return false }
                if case .queued = job.state { return true }
                return false
            }) else {
                return
            }

            retryAvailableAt[nextID] = nil
            runningCount += 1
            let task = Task { [weak self] in
                await self?.runJob(id: nextID)
                return
            }
            runningTasks[nextID] = task
        }
    }

    private func runJob(id: UUID) async {
        defer {
            runningTasks[id] = nil
            if runningCount > 0 { runningCount -= 1 }
            pump()
        }

        guard var job = jobs[id] else { return }
        if cancellationFlags[id] == true {
            await markCancelled(id: id)
            return
        }
        cancellationFlags[id] = false

        do {
            if Task.isCancelled || cancellationFlags[id] == true {
                throw DownloadError.cancelled
            }
            // Appliquer proxy / session à jour
            downloader = SegmentFileDownloader(session: AppPreferences.current.makeURLSession())

            job.state = .preparing
            job.updatedAt = Date()
            jobs[id] = job
            try store.upsert(job)
            publish(job)

            try FileManager.default.createDirectory(at: job.destinationDirectory, withIntermediateDirectories: true)

            let units = try await planUnits(for: job)
            var alreadyDone = Set(job.completedUnitIndices)
            // Indices « complétés » mais fichiers absents (échec assemble précédent) → re-télécharger.
            if !alreadyDone.isEmpty {
                let missing = units.filter { unit in
                    alreadyDone.contains(unit.index)
                        && !segmentFileExists(unit: unit, in: job.destinationDirectory)
                }
                if !missing.isEmpty {
                    AppLog.download.info(
                        "Re-download \(missing.count, privacy: .public) missing segment(s) before assemble"
                    )
                    for unit in missing {
                        alreadyDone.remove(unit.index)
                    }
                    job.completedUnitIndices = alreadyDone.sorted()
                    jobs[id] = job
                    try? store.upsert(job)
                }
            }
            let pending = units.filter { !alreadyDone.contains($0.index) }

            if pending.isEmpty, !units.isEmpty {
                job.completedUnitIndices = units.map(\.index)
                jobs[id] = job
                try await finalizeWithAssembly(jobID: id)
                return
            }

            try await downloadUnits(allUnits: units, pending: pending, jobID: id)

            if cancellationFlags[id] == true || Task.isCancelled {
                throw DownloadError.cancelled
            }

            guard var finished = jobs[id] else { return }
            finished.completedUnitIndices = units.map(\.index)
            jobs[id] = finished
            try await finalizeWithAssembly(jobID: id)
            AppLog.download.info("Job completed \(finished.title, privacy: .public)")
            autoRetryCounts[id] = 0
        } catch is CancellationError {
            await markCancelled(id: id)
        } catch let error as DownloadError where error == .cancelled {
            await markCancelled(id: id)
        } catch {
            if cancellationFlags[id] == true {
                await markCancelled(id: id)
                return
            }

            let desc = error.localizedDescription
            let transient: Bool
            if let downloadError = error as? DownloadError {
                transient = downloadError.isTransientNetworkFailure
            } else {
                transient = Self.looksTransientFailure(desc)
            }
            let attempt = (autoRetryCounts[id] ?? 0) + 1

            if transient, attempt <= Self.maxAutoRetries {
                autoRetryCounts[id] = attempt
                // Backoff job : 15s, 30s, 45s… max 3 min
                let delaySeconds = min(180, 15 * attempt)
                let availableAt = Date().addingTimeInterval(TimeInterval(delaySeconds))
                retryAvailableAt[id] = availableAt
                guard var waiting = jobs[id] else { return }
                waiting.state = .queued
                waiting.updatedAt = Date()
                jobs[id] = waiting
                try? store.upsert(waiting)
                publish(waiting)
                AppLog.download.info(
                    "Auto-retry \(attempt, privacy: .public)/\(Self.maxAutoRetries, privacy: .public) in \(delaySeconds, privacy: .public)s — \(desc, privacy: .public)"
                )
                let jobID = id
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
                    guard let self else { return }
                    await self.resumeAfterTransientFailure(id: jobID)
                }
                return
            }

            autoRetryCounts[id] = 0
            retryAvailableAt[id] = nil
            guard var failed = jobs[id] else { return }
            failed.state = .failed(message: desc)
            failed.updatedAt = Date()
            jobs[id] = failed
            try? store.upsert(failed)
            publish(failed)
            AppLog.download.error("Job failed: \(desc, privacy: .public)")
        }
    }

    private func resumeAfterTransientFailure(id: UUID) async {
        guard cancellationFlags[id] != true else { return }
        guard var job = jobs[id] else { return }
        guard case .queued = job.state else { return }
        retryAvailableAt[id] = nil
        // Remettre en tête pour reprise rapide des segments manquants.
        jobOrder.removeAll { $0 == id }
        jobOrder.insert(id, at: 0)
        job.updatedAt = Date()
        jobs[id] = job
        try? store.upsert(job)
        publish(job)
        pump()
    }

    private func finalizeWithAssembly(jobID: UUID) async throws {
        guard var job = jobs[jobID] else { return }
        job.state = .assembling
        job.updatedAt = Date()
        jobs[jobID] = job
        try store.upsert(job)
        publish(job)

        let assembler = try MediaAssembler()
        let exportRoot = job.resolvedOutputDirectory
        let segmentsDir = job.destinationDirectory
        let template = job.resolvedNamingTemplate
        let result = try await assembler.assemble(
            jobTitle: job.title,
            kind: job.kind,
            segmentsDirectory: segmentsDir,
            outputDirectory: exportRoot,
            namingTemplate: template,
            namingContext: job.namingContext
        )

        // Ne garder que le MP4 final (+ sidecars sous-titres) : virer .parts du job
        Self.cleanupSegmentsDirectory(segmentsDir)
        Self.cleanupSegmentsDirectory(AppPreferences.partsDirectory(forJobID: jobID))
        MediaAssembler.scrubTransientFiles(in: result.outputURL.deletingLastPathComponent())

        guard var done = jobs[jobID] else { return }
        done.exportURL = result.outputURL
        // Garder le dossier parent du fichier (ex. Film (2020)/) comme destination visible
        done.destinationDirectory = result.outputURL.deletingLastPathComponent()
        done.outputDirectory = exportRoot
        done.state = .completed(directoryURL: result.outputURL.deletingLastPathComponent())
        done.updatedAt = Date()
        jobs[jobID] = done
        try store.upsert(done)
        publish(done)
        AppLog.ffmpeg.info("Export ready \(result.outputURL.path, privacy: .public)")
    }

    /// Supprime uniquement un dossier de segments sous `downloadsRoot/.parts/<uuid>/`.
    private static func cleanupSegmentsDirectory(_ directory: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }

        let standardized = directory.standardizedFileURL
        guard isSafePartsJobDirectory(standardized) else {
            AppLog.download.error("Refuse cleanup path: \(directory.path, privacy: .public)")
            return
        }

        do {
            try fm.removeItem(at: directory)
            AppLog.download.info("Segments supprimés \(directory.lastPathComponent, privacy: .public)")

            let partsRoot = AppPreferences.partsRoot.standardizedFileURL
            if fm.fileExists(atPath: partsRoot.path),
               let children = try? fm.contentsOfDirectory(atPath: partsRoot.path),
               children.isEmpty
            {
                try? fm.removeItem(at: partsRoot)
            }
        } catch {
            AppLog.download.error("Cleanup segments failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Autorise seulement `…/<downloadsRoot>/.parts/<UUID>/` (jamais un dossier d’export).
    private static func isSafePartsJobDirectory(_ directory: URL) -> Bool {
        guard UUID(uuidString: directory.lastPathComponent) != nil else { return false }
        let parent = directory.deletingLastPathComponent().standardizedFileURL
        guard parent.lastPathComponent == ".parts" else { return false }
        let downloadsRoot = AppPreferences.downloadsRoot.standardizedFileURL
        let grand = parent.deletingLastPathComponent().standardizedFileURL
        return grand.path == downloadsRoot.path
    }

    private func markCancelled(id: UUID) async {
        guard var job = jobs[id] else { return }
        if case .cancelled = job.state { return }
        job.state = .cancelled
        job.updatedAt = Date()
        jobs[id] = job
        try? store.upsert(job)
        publish(job)
    }

    private func planUnits(for job: DownloadJob) async throws -> [DownloadUnit] {
        var units = try await planPrimaryUnits(for: job)
        if let audioUnits = try await planAudioUnits(for: job) {
            units.append(contentsOf: audioUnits)
        }
        if let subtitleUnits = try await planSubtitleUnits(for: job) {
            units.append(contentsOf: subtitleUnits)
        }
        return units
    }

    private func planPrimaryUnits(for job: DownloadJob) async throws -> [DownloadUnit] {
        switch job.kind {
        case .progressive:
            return MediaDownloadPlanner.progressiveUnit(url: job.variantURL)
        case .hls:
            return try await planHLSMediaUnits(
                playlistURL: job.variantURL,
                credentials: job.credentials,
                destinationDirectory: job.destinationDirectory
            )
        case .dash:
            let text = try await downloader.fetchText(url: job.sourceURL, credentials: job.credentials)
            let manifest = try DASHParser.parse(xml: text, manifestURL: job.sourceURL)
            let representation: DASHRepresentation
            if let id = job.selectedDashVideoRepresentationID,
               let match = manifest.videoRepresentations.first(where: { $0.id == id })
            {
                representation = match
            } else if let best = manifest.videoRepresentations.max(by: { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) }) {
                representation = best
            } else {
                throw DownloadError.emptyPlaylist
            }
            return try DASHParser.units(for: representation)
        }
    }

    private func planHLSMediaUnits(
        playlistURL: URL,
        credentials: DownloadCredentials,
        directoryPrefix: String = "",
        indexOffset: Int = 0,
        destinationDirectory: URL? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) async throws -> [DownloadUnit] {
        let mediaPlaylist = try await HLSPlaylistCompleter.resolveMediaPlaylist(
            playlistURL: playlistURL,
            credentials: credentials,
            downloader: downloader,
            isCancelled: isCancelled
        )
        let units = try MediaDownloadPlanner.hlsUnits(
            from: mediaPlaylist,
            directoryPrefix: directoryPrefix,
            indexOffset: indexOffset
        )
        if let destinationDirectory, let media = mediaPlaylist.media {
            let targetDir = directoryPrefix.isEmpty
                ? destinationDirectory
                : destinationDirectory.appendingPathComponent(
                    String(directoryPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
                    isDirectory: true
                )
            try? MediaDownloadPlanner.writeLocalMediaPlaylist(
                media: media,
                units: units,
                to: targetDir
            )
        }
        return units
    }

    private func planAudioUnits(for job: DownloadJob) async throws -> [DownloadUnit]? {
        if job.kind == .dash, let repID = job.selectedAudioDashRepresentationID {
            let text = try await downloader.fetchText(url: job.sourceURL, credentials: job.credentials)
            let manifest = try DASHParser.parse(xml: text, manifestURL: job.sourceURL)
            guard let representation = manifest.audioRepresentations.first(where: { $0.id == repID }) else {
                return nil
            }
            return try DASHParser.units(
                for: representation,
                directoryPrefix: "audio/",
                indexOffset: DownloadUnitOffset.audio
            )
        }
        guard let audioURL = job.selectedAudioTrackURL else { return nil }
        let ext = audioURL.pathExtension.lowercased()
        if ["mp4", "m4a", "aac", "webm"].contains(ext) {
            return MediaDownloadPlanner.progressiveUnit(
                url: audioURL,
                directoryPrefix: "audio/",
                indexOffset: DownloadUnitOffset.audio
            )
        }
        return try await planHLSMediaUnits(
            playlistURL: audioURL,
            credentials: job.credentials,
            directoryPrefix: "audio/",
            indexOffset: DownloadUnitOffset.audio,
            destinationDirectory: job.destinationDirectory
        )
    }

    private func planSubtitleUnits(for job: DownloadJob) async throws -> [DownloadUnit]? {
        if job.kind == .dash, let repID = job.selectedSubtitleDashRepresentationID {
            let text = try await downloader.fetchText(url: job.sourceURL, credentials: job.credentials)
            let manifest = try DASHParser.parse(xml: text, manifestURL: job.sourceURL)
            guard let representation = manifest.textRepresentations.first(where: { $0.id == repID }) else {
                return nil
            }
            return try DASHParser.units(
                for: representation,
                directoryPrefix: "subs/",
                indexOffset: DownloadUnitOffset.subtitle
            )
        }
        guard let subtitleURL = job.selectedSubtitleTrackURL else { return nil }
        let ext = subtitleURL.pathExtension.lowercased()
        if ["vtt", "srt", "ttml", "xml"].contains(ext) {
            return MediaDownloadPlanner.progressiveUnit(
                url: subtitleURL,
                directoryPrefix: "subs/",
                indexOffset: DownloadUnitOffset.subtitle
            )
        }
        return try await planHLSMediaUnits(
            playlistURL: subtitleURL,
            credentials: job.credentials,
            directoryPrefix: "subs/",
            indexOffset: DownloadUnitOffset.subtitle,
            destinationDirectory: job.destinationDirectory
        )
    }

    private func downloadUnits(
        allUnits: [DownloadUnit],
        pending: [DownloadUnit],
        jobID: UUID
    ) async throws {
        let total = allUnits.count
        var completed = Set(jobs[jobID]?.completedUnitIndices ?? [])
        guard let credentials = jobs[jobID]?.credentials,
              let directory = jobs[jobID]?.destinationDirectory
        else {
            throw DownloadError.message("Job introuvable")
        }

        let concurrency = segmentConcurrency
        let retries = AppPreferences.current.maxRetries
        let downloader = self.downloader
        let started = ContinuousClock.now
        var bytesDownloaded: Int64 = 0

        // Afficher tout de suite « Téléchargement » (sinon MP4 progressif reste bloqué sur Préparation).
        if var job = jobs[jobID] {
            job.state = .downloading(
                progress: Double(completed.count) / Double(max(total, 1)),
                completedUnits: completed.count,
                totalUnits: total
            )
            job.updatedAt = Date()
            jobs[jobID] = job
            publish(job)
            try? store.upsert(job)
        }

        // MP4 progressif (1 fichier) : hors TaskGroup pour progression octets + simplicité concurrency.
        if pending.count == 1, total <= 1, let unit = pending.first {
            let progressBox = ByteProgressBox()
            let progressTask = Task {
                var lastPublished: Int64 = -1
                while !Task.isCancelled {
                    let snap = progressBox.snapshot()
                    if snap.written != lastPublished {
                        lastPublished = snap.written
                        await self.publishByteProgress(
                            jobID: jobID,
                            written: snap.written,
                            expected: snap.expected
                        )
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            defer { progressTask.cancel() }

            let result: SegmentDownloadResult
            do {
                result = try await downloader.download(
                    unit: unit,
                    to: directory,
                    credentials: credentials,
                    isCancelled: { Task.isCancelled },
                    maxRetries: retries,
                    onProgress: { written, expected in
                        progressBox.update(written: written, expected: expected)
                    }
                )
            } catch {
                progressTask.cancel()
                throw error
            }
            progressTask.cancel()

            if Task.isCancelled {
                throw DownloadError.cancelled
            }
            completed.insert(unit.index)
            bytesDownloaded = result.byteCount
            if var job = jobs[jobID] {
                job.completedUnitIndices = completed.sorted()
                job.state = .downloading(progress: 1, completedUnits: 1, totalUnits: 1)
                job.updatedAt = Date()
                jobs[jobID] = job
                try store.upsert(job)
                publish(job)
            }
            let elapsed = ContinuousClock.now - started
            let seconds = max(0.001, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            let mib = Double(bytesDownloaded) / (1024 * 1024)
            AppLog.download.info(
                "Throughput job \(jobID.uuidString, privacy: .public): \(String(format: "%.1f", mib), privacy: .public) MiB in \(String(format: "%.1f", seconds), privacy: .public)s → \(String(format: "%.2f", mib / seconds), privacy: .public) MiB/s (progressive)"
            )
            return
        }

        try await withThrowingTaskGroup(of: Result<(Int, Int64), Error>.self) { group in
            var nextIndex = 0
            var sincePersist = 0
            var lastPublish = ContinuousClock.now
            let publishInterval: Duration = .milliseconds(150)
            let persistEvery = 25
            var failures: [Error] = []

            func enqueueNext() {
                guard nextIndex < pending.count else { return }
                let unit = pending[nextIndex]
                nextIndex += 1
                group.addTask {
                    if Task.isCancelled {
                        return .failure(DownloadError.cancelled)
                    }
                    do {
                        let result = try await downloader.download(
                            unit: unit,
                            to: directory,
                            credentials: credentials,
                            isCancelled: { Task.isCancelled },
                            maxRetries: retries
                        )
                        return .success((unit.index, result.byteCount))
                    } catch {
                        return .failure(error)
                    }
                }
            }

            func flushProgress(forcePersist: Bool, forcePublish: Bool) throws {
                guard var job = jobs[jobID] else { return }
                job.completedUnitIndices = completed.sorted()
                let progress = Double(completed.count) / Double(max(total, 1))
                job.state = .downloading(
                    progress: progress,
                    completedUnits: completed.count,
                    totalUnits: total
                )
                job.updatedAt = Date()
                jobs[jobID] = job

                let now = ContinuousClock.now
                let shouldPublish = forcePublish || (now - lastPublish) >= publishInterval
                if shouldPublish {
                    publish(job)
                    lastPublish = now
                }
                if forcePersist || sincePersist >= persistEvery {
                    try store.upsert(job)
                    sincePersist = 0
                }
            }

            let seed = min(concurrency, pending.count)
            for _ in 0..<seed {
                enqueueNext()
            }

            while let outcome = try await group.next() {
                if cancellationFlags[jobID] == true || Task.isCancelled {
                    group.cancelAll()
                    throw DownloadError.cancelled
                }
                switch outcome {
                case .success(let (index, bytes)):
                    completed.insert(index)
                    bytesDownloaded += bytes
                    sincePersist += 1
                    try flushProgress(forcePersist: false, forcePublish: false)
                    enqueueNext()
                case .failure(let error):
                    if let downloadError = error as? DownloadError, downloadError == .cancelled {
                        group.cancelAll()
                        throw DownloadError.cancelled
                    }
                    failures.append(error)
                    enqueueNext()
                }
            }

            try flushProgress(forcePersist: true, forcePublish: true)
            if let first = failures.first {
                let count = failures.count
                throw DownloadError.message(
                    "\(count) segment(s) en échec (\(first.localizedDescription)) — reprends le téléchargement"
                )
            }
        }

        let elapsed = ContinuousClock.now - started
        let seconds = max(0.001, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        let mib = Double(bytesDownloaded) / (1024 * 1024)
        let rate = mib / seconds
        let segRate = Double(pending.count) / seconds
        AppLog.download.info(
            "Throughput job \(jobID.uuidString, privacy: .public): \(String(format: "%.1f", mib), privacy: .public) MiB in \(String(format: "%.1f", seconds), privacy: .public)s → \(String(format: "%.2f", rate), privacy: .public) MiB/s, \(String(format: "%.1f", segRate), privacy: .public) seg/s (parallel=\(concurrency, privacy: .public))"
        )
    }

    private func publishByteProgress(jobID: UUID, written: Int64, expected: Int64) {
        guard var job = jobs[jobID] else { return }
        switch job.state {
        case .downloading, .preparing, .queued:
            break
        default:
            return
        }
        let fraction: Double
        if expected > 0 {
            fraction = min(0.99, Double(written) / Double(expected))
        } else {
            // Taille inconnue : avance lente factice pour montrer que ça tourne.
            fraction = min(0.95, 0.05 + log10(Double(max(written, 1))) / 40.0)
        }
        job.state = .downloading(progress: fraction, completedUnits: 0, totalUnits: 1)
        job.updatedAt = Date()
        jobs[jobID] = job
        publish(job)
    }

    /// Vérifie qu’un segment planifié existe encore sur disque (après rename .image→.ts possible).
    private func segmentFileExists(unit: DownloadUnit, in directory: URL) -> Bool {
        let primary = directory.appendingPathComponent(unit.fileName)
        if FileManager.default.fileExists(atPath: primary.path) { return true }
        let stem = primary.deletingPathExtension().lastPathComponent
        for ext in ["ts", "m4s", "mp4", "aac", "m4a", "image"] {
            let candidate = directory.appendingPathComponent("\(stem).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) { return true }
        }
        return false
    }
}

/// Boîte thread-safe pour relayer la progression octets hors de l’actor.
private final class ByteProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var written: Int64 = 0
    private var expected: Int64 = 0

    func update(written: Int64, expected: Int64) {
        lock.lock()
        self.written = written
        self.expected = expected
        lock.unlock()
    }

    func snapshot() -> (written: Int64, expected: Int64) {
        lock.lock()
        defer { lock.unlock() }
        return (written, expected)
    }
}
