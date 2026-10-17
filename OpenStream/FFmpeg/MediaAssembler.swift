import Foundation

struct ExportResult: Sendable {
    let outputURL: URL
    let usedRemux: Bool
}

enum MediaAssemblerError: Error, LocalizedError, Sendable {
    case noSegments
    case message(String)

    var errorDescription: String? {
        switch self {
        case .noSegments: return "Aucun segment à assembler"
        case .message(let text): return text
        }
    }
}

enum AVSyncRepairResult: Sendable, Equatable {
    case alreadyAligned(deltaSeconds: Double)
    case repaired(beforeDeltaSeconds: Double, afterDeltaSeconds: Double)
    case missingAudioOrVideo
    case offsetApplied(audioShiftSeconds: Double)
    case driftCorrected(durationDeltaSeconds: Double, atempo: Double)
    /// Alignement type lecteur : PTS communs + coupe à la piste la plus courte.
    case playerAligned(trimmedSeconds: Double)
    case timelineCorrected(skewRatio: Double)
    /// Timeline DASH détruite à l’export — Sync post-hoc insuffisant.
    case needsRedownload

    var userMessage: String {
        switch self {
        case .alreadyAligned:
            return "Audio et image déjà alignés"
        case .repaired(let before, _):
            return String(format: "Sync corrigé (écart %.0f ms → aligné)", before * 1000)
        case .missingAudioOrVideo:
            return "Fichier sans piste audio et vidéo"
        case .offsetApplied(let shift):
            let ms = Int((shift * 1000).rounded())
            if ms == 0 { return "Aucun décalage appliqué" }
            if ms > 0 {
                return "Audio retardé de \(ms) ms"
            }
            return "Audio avancé de \(-ms) ms"
        case .driftCorrected(let delta, let atempo):
            let ms = Int((abs(delta) * 1000).rounded())
            return String(
                format: "Dérive corrigée (%d ms, atempo %.5f)",
                ms,
                atempo
            )
        case .playerAligned(let trimmedSeconds):
            if trimmedSeconds < 0.05 {
                return "Recalé comme le lecteur (PTS alignés)"
            }
            return String(format: "Recalé comme le lecteur (rogne %.1f s en trop)", trimmedSeconds)
        case .timelineCorrected(let skew):
            return String(format: "Dérive corrigée (audio ×%.4f pour coller à la timeline)", skew)
        case .needsRedownload:
            return "Timeline cassée à l’export — re-télécharge avec OpenStream à jour (Sync ne peut pas récupérer une dérive non linéaire)"
        }
    }
}

/// Cible pour la feuille d’ajustement sync manuel.
struct AVSyncTarget: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let title: String

    init(url: URL, title: String? = nil) {
        self.id = UUID()
        self.url = url
        self.title = title ?? url.deletingPathExtension().lastPathComponent
    }
}

/// Assemble segments téléchargés → fichier MP4 (remux `-c copy` privilégié).
/// Pistes optionnelles : dossiers `audio/` et `subs/` sous le répertoire segments (Phase 6).
struct MediaAssembler: Sendable {
    let ffmpeg: FFmpegWrapper

    init(ffmpeg: FFmpegWrapper? = nil) throws {
        self.ffmpeg = try ffmpeg ?? FFmpegWrapper()
    }

    func assemble(
        jobTitle: String,
        kind: ManifestKind,
        segmentsDirectory: URL,
        outputDirectory: URL,
        namingTemplate: String? = nil,
        namingContext: ExportNamingContext? = nil
    ) async throws -> ExportResult {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let context = namingContext ?? ExportNamingContext(title: jobTitle, kind: kind)
        let template = namingTemplate ?? "{title}.{ext}"
        let outputURL = ExportNaming.resolveURL(root: outputDirectory, template: template, context: context)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let audioDir = segmentsDirectory.appendingPathComponent("audio", isDirectory: true)
        let subsDir = segmentsDirectory.appendingPathComponent("subs", isDirectory: true)
        let hasExtraAudio = directoryHasMediaFiles(audioDir)
        let workDirectory = segmentsDirectory

        // HLS audio séparé (MPEG-TS) : un seul ffmpeg sur les deux concat —
        // remuxer chaque piste puis muxer détruit les PTS / drop des frames (~Lanterns).
        if kind == .hls, hasExtraAudio, directoryHasTSFiles(segmentsDirectory) {
            try await assembleDemuxedHLSTS(
                videoDirectory: segmentsDirectory,
                audioDirectory: audioDir,
                outputURL: outputURL,
                workDirectory: workDirectory
            )
            Self.scrubTransientFiles(in: outputURL.deletingLastPathComponent())
            Self.scrubTransientFiles(in: workDirectory)
            if let subtitle = findSubtitleFile(in: subsDir) {
                let ext = subtitle.pathExtension.isEmpty ? "vtt" : subtitle.pathExtension
                var subContext = context
                subContext.ext = ext
                let sidecar = ExportNaming.resolveURL(root: outputDirectory, template: template, context: subContext)
                try FileManager.default.createDirectory(
                    at: sidecar.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: sidecar.path) {
                    try FileManager.default.removeItem(at: sidecar)
                }
                try exportSubtitle(from: subtitle, siblingsIn: subsDir, to: sidecar)
            }
            return ExportResult(outputURL: outputURL, usedRemux: true)
        }

        let videoTarget: URL
        if hasExtraAudio {
            videoTarget = workDirectory.appendingPathComponent(".__os_video.mp4")
        } else {
            videoTarget = outputURL
        }

        var usedRemux: Bool
        switch kind {
        case .progressive:
            usedRemux = try assembleProgressive(from: segmentsDirectory, to: videoTarget).usedRemux
        case .hls:
            usedRemux = try await assembleHLS(
                from: segmentsDirectory,
                to: videoTarget,
                workDirectory: workDirectory,
                preserveTimeline: hasExtraAudio
            ).usedRemux
        case .dash:
            usedRemux = try await assembleDASH(
                from: segmentsDirectory,
                to: videoTarget,
                workDirectory: workDirectory,
                preserveTimeline: hasExtraAudio
            ).usedRemux
        }

        var finalURL = videoTarget
        if hasExtraAudio {
            let audioTarget = workDirectory.appendingPathComponent(".__os_audio.mp4")
            _ = try await assembleAuxiliaryMedia(
                from: audioDir,
                to: audioTarget,
                workDirectory: workDirectory,
                preserveTimeline: true
            )
            try await muxAlignedAudioVideo(
                videoURL: videoTarget,
                audioURL: audioTarget,
                outputURL: outputURL
            )
            try await normalizeTimelineSkewIfNeeded(at: outputURL)
            try? FileManager.default.removeItem(at: videoTarget)
            try? FileManager.default.removeItem(at: audioTarget)
            finalURL = outputURL
            usedRemux = true
        }

        // Aucun temporaire à côté du MP4 final
        Self.scrubTransientFiles(in: outputURL.deletingLastPathComponent())
        Self.scrubTransientFiles(in: workDirectory)

        if let subtitle = findSubtitleFile(in: subsDir) {
            let ext = subtitle.pathExtension.isEmpty ? "vtt" : subtitle.pathExtension
            var subContext = context
            subContext.ext = ext
            let sidecar = ExportNaming.resolveURL(root: outputDirectory, template: template, context: subContext)
            try FileManager.default.createDirectory(
                at: sidecar.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try FileManager.default.removeItem(at: sidecar)
            }
            try exportSubtitle(from: subtitle, siblingsIn: subsDir, to: sidecar)
        }

        return ExportResult(outputURL: finalURL, usedRemux: usedRemux)
    }

    /// Répare le lip-sync d’un MP4 déjà exporté (in-place, via staging temporaire).
    func repairAVSync(at url: URL) async throws -> AVSyncRepairResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MediaAssemblerError.message("Fichier introuvable")
        }

        let before = try await ffmpeg.probeStreamTiming(url: url)
        guard before.videoStart != nil, before.audioStart != nil else {
            return .missingAudioOrVideo
        }

        if before.hasSignificantVideoTimelineSkew {
            try await normalizeTimelineSkewIfNeeded(at: url)
            return .timelineCorrected(skewRatio: before.videoTimelineSkewRatio ?? 1)
        }

        let beforeDelta = before.startDelta ?? 0
        if beforeDelta <= Self.avSyncToleranceSeconds {
            return .alreadyAligned(deltaSeconds: beforeDelta)
        }

        // Décalage constant de départ : retarder la piste qui commence trop tôt.
        let vStart = before.videoStart ?? 0
        let aStart = before.audioStart ?? 0
        let audioShift = vStart - aStart // >0 → audio trop tôt → retarder l’audio
        let result = try await applyManualAudioShift(at: url, audioShiftSeconds: audioShift)
        if case .offsetApplied = result {
            let after = try await ffmpeg.probeStreamTiming(url: url)
            return .repaired(beforeDeltaSeconds: beforeDelta, afterDeltaSeconds: after.startDelta ?? 0)
        }
        return result
    }

    /// Décale manuellement l’audio par rapport à la vidéo.
    /// - Parameter audioShiftSeconds: positif = retarder l’audio (son trop tôt) ;
    ///   négatif = avancer l’audio (son trop tard).
    func applyManualAudioShift(at url: URL, audioShiftSeconds: Double) async throws -> AVSyncRepairResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MediaAssemblerError.message("Fichier introuvable")
        }
        let shift = (audioShiftSeconds * 1000).rounded() / 1000
        if abs(shift) < 0.001 {
            return .offsetApplied(audioShiftSeconds: 0)
        }

        let timing = try await ffmpeg.probeStreamTiming(url: url)
        guard timing.videoStart != nil, timing.audioStart != nil else {
            return .missingAudioOrVideo
        }

        let work = url.deletingLastPathComponent()
        let staging = work.appendingPathComponent(".__os_manual_sync.mp4")
        if FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.removeItem(at: staging)
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        // Deux lectures du même fichier : une piste vidéo, une audio décalée.
        var args: [String] = ["-y"]
        if shift < 0 {
            // Son trop tard → retarder la vidéo (= avancer l’audio relatif)
            args += ["-itsoffset", String(format: "%.3f", -shift), "-i", url.path, "-i", url.path]
        } else {
            // Son trop tôt → retarder l’audio
            args += ["-i", url.path, "-itsoffset", String(format: "%.3f", shift), "-i", url.path]
        }
        args += [
            "-map", "0:v:0",
            "-map", "1:a:0",
            "-c", "copy",
            "-shortest",
            "-avoid_negative_ts", "make_zero",
            "-muxpreload", "0",
            "-muxdelay", "0",
            "-movflags", "+faststart",
            staging.path
        ]
        try await ffmpeg.run(arguments: args)
        try replaceFileAtomically(original: url, with: staging)
        Self.scrubTransientFiles(in: work)
        return .offsetApplied(audioShiftSeconds: shift)
    }

    /// Corrige une dérive progressive (son qui prend de l’avance / du retard au fil du temps).
    /// - Parameter endAudioLeadSeconds: avance estimée de l’audio **en fin de fichier**
    ///   (positif = son en avance ; négatif = son en retard). Si `nil`, utilise l’écart de
    ///   durées ffprobe (souvent insuffisant quand les durées déclarées sont quasi égales).
    func correctAVDrift(
        at url: URL,
        endAudioLeadSeconds: Double? = nil
    ) async throws -> AVSyncRepairResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MediaAssemblerError.message("Fichier introuvable")
        }
        let timing = try await ffmpeg.probeStreamTiming(url: url)
        guard timing.videoStart != nil, timing.audioStart != nil else {
            return .missingAudioOrVideo
        }
        guard let videoDuration = timing.videoDuration, videoDuration > 1 else {
            throw MediaAssemblerError.message("Durée vidéo illisible")
        }

        let lead: Double
        let atempo: Double
        if let endLead = endAudioLeadSeconds {
            // Son en avance de L en fin de fichier → audio trop rapide → ralentir.
            // atempo = V / (V + L)
            let rounded = (endLead * 1000).rounded() / 1000
            if abs(rounded) < 0.02 {
                return .alreadyAligned(deltaSeconds: timing.startDelta ?? 0)
            }
            let denom = videoDuration + rounded
            guard denom > 1 else {
                throw MediaAssemblerError.message("Dérive trop extrême")
            }
            lead = rounded
            atempo = videoDuration / denom
        } else {
            guard let delta = timing.durationDelta,
                  let ratio = timing.atempoToMatchVideo
            else {
                throw MediaAssemblerError.message("Durées A/V illisibles")
            }
            if abs(delta) < 0.05 {
                return .alreadyAligned(deltaSeconds: timing.startDelta ?? 0)
            }
            // audio plus court (delta < 0) → son « en avance » progressif
            lead = -delta
            atempo = ratio
        }

        if atempo < 0.5 || atempo > 2.0 {
            throw MediaAssemblerError.message(
                String(format: "Dérive trop extrême (atempo %.5f) — re-téléchargement conseillé", atempo)
            )
        }

        let work = url.deletingLastPathComponent()
        let staging = work.appendingPathComponent(".__os_drift_sync.mp4")
        if FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.removeItem(at: staging)
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        let filter = Self.atempoFilterChain(atempo)
        try await ffmpeg.run(arguments: [
            "-y",
            "-i", url.path,
            "-map", "0:v:0",
            "-map", "0:a:0",
            "-c:v", "copy",
            "-c:a", "aac",
            "-af", filter,
            "-shortest",
            "-avoid_negative_ts", "make_zero",
            "-movflags", "+faststart",
            staging.path
        ])
        try replaceFileAtomically(original: url, with: staging)
        Self.scrubTransientFiles(in: work)
        return .driftCorrected(durationDeltaSeconds: lead, atempo: atempo)
    }

    /// Facteur atempo pour une avance audio estimée en fin de fichier.
    static func atempoForEndAudioLead(videoDuration: Double, endAudioLeadSeconds: Double) -> Double? {
        guard videoDuration > 1 else { return nil }
        let denom = videoDuration + endAudioLeadSeconds
        guard denom > 1 else { return nil }
        return videoDuration / denom
    }

    /// Chaîne `atempo` (chaque facteur entre 0.5 et 2.0).
    static func atempoFilterChain(_ ratio: Double) -> String {
        var r = ratio
        var parts: [String] = []
        while r > 2.0 {
            parts.append("atempo=2.0")
            r /= 2.0
        }
        while r < 0.5 {
            parts.append("atempo=0.5")
            r /= 0.5
        }
        parts.append(String(format: "atempo=%.6f", r))
        return parts.joined(separator: ",")
    }

    private func replaceFileAtomically(original: URL, with staging: URL) throws {
        let backup = original.deletingLastPathComponent()
            .appendingPathComponent(".__os_repair_bak.mp4")
        if FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.removeItem(at: backup)
        }
        try FileManager.default.moveItem(at: original, to: backup)
        do {
            try FileManager.default.moveItem(at: staging, to: original)
            try? FileManager.default.removeItem(at: backup)
        } catch {
            try? FileManager.default.moveItem(at: backup, to: original)
            throw error
        }
    }

    private func assembleProgressive(from directory: URL, to outputURL: URL) throws -> ExportResult {
        let files = listMediaFiles(in: directory)
        guard let source = files.first(where: {
            let ext = $0.pathExtension.lowercased()
            return ["mp4", "m4v", "mov", "webm"].contains(ext)
        }) ?? files.first else {
            throw MediaAssemblerError.noSegments
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.copyItem(at: source, to: outputURL)
        return ExportResult(outputURL: outputURL, usedRemux: false)
    }

    private func assembleHLS(
        from directory: URL,
        to outputURL: URL,
        workDirectory: URL? = nil,
        preserveTimeline: Bool = false
    ) async throws -> ExportResult {
        let work = workDirectory ?? directory
        let files = listMediaFiles(in: directory)
        guard !files.isEmpty else { throw MediaAssemblerError.noSegments }

        let hasInit = files.contains { $0.lastPathComponent.contains("init") }
        let tsFiles = files.filter { $0.pathExtension.lowercased() == "ts" }
        let m4sFiles = files.filter {
            let ext = $0.pathExtension.lowercased()
            return ext == "m4s" || ext == "mp4"
        }

        if hasInit || (!m4sFiles.isEmpty && tsFiles.isEmpty) {
            return try await assembleFMP4(
                files: files,
                to: outputURL,
                workDirectory: work,
                preserveTimeline: preserveTimeline
            )
        }

        // MPEG-TS HLS — toujours via playlist.m3u8 (EXTINF).
        // Le demuxer `concat` sur les .ts étire les PTS (~+1.5 %) même en A/V muxés
        // dans les mêmes segments (cas Lanterns S01E05 / Obsession).
        try normalizeHLSSegmentDirectory(directory)

        let refreshed = listMediaFiles(in: directory)
        let tsAfter = refreshed.filter { $0.pathExtension.lowercased() == "ts" }
        let segments = tsAfter.isEmpty
            ? refreshed.filter { !["m3u8", "vtt", "srt"].contains($0.pathExtension.lowercased()) }
            : tsAfter
        guard !segments.isEmpty else {
            throw MediaAssemblerError.message(
                "Aucun segment média dans \(directory.lastPathComponent) — relance le téléchargement"
            )
        }

        let playlistURL = directory.appendingPathComponent("playlist.m3u8")
        // Toujours réécrire la playlist depuis les fichiers réels (évite .image orphelin).
        try rewriteHLSPlaylistMatchingFiles(segments: segments, playlistURL: playlistURL)

        let staging = work.appendingPathComponent(".__os_remux.mp4")
        if FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.removeItem(at: staging)
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        let firstSegment = segments[0]
        guard FileManager.default.fileExists(atPath: firstSegment.path) else {
            throw MediaAssemblerError.message("Premier segment introuvable: \(firstSegment.lastPathComponent)")
        }

        do {
            try await ffmpeg.run(arguments: [
                "-y",
                "-allowed_extensions", "ALL",
                "-extension_picky", "0",
                "-i", playlistURL.path,
                "-c", "copy",
                "-bsf:a", "aac_adtstoasc",
                "-movflags", "+faststart",
                staging.path
            ])
        } catch {
            try await ffmpeg.run(arguments: [
                "-y",
                "-allowed_extensions", "ALL",
                "-extension_picky", "0",
                "-i", playlistURL.path,
                "-c", "copy",
                "-movflags", "+faststart",
                staging.path
            ])
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.moveItem(at: staging, to: outputURL)

        return ExportResult(outputURL: outputURL, usedRemux: true)
    }

    private func assembleDASH(
        from directory: URL,
        to outputURL: URL,
        workDirectory: URL? = nil,
        preserveTimeline: Bool = false
    ) async throws -> ExportResult {
        let files = listMediaFiles(in: directory)
        guard !files.isEmpty else { throw MediaAssemblerError.noSegments }
        return try await assembleFMP4(
            files: files,
            to: outputURL,
            workDirectory: workDirectory ?? directory,
            preserveTimeline: preserveTimeline
        )
    }

    private func assembleAuxiliaryMedia(
        from directory: URL,
        to outputURL: URL,
        workDirectory: URL,
        preserveTimeline: Bool = true
    ) async throws -> ExportResult {
        let files = listMediaFiles(in: directory)
        guard !files.isEmpty else { throw MediaAssemblerError.noSegments }

        if files.count == 1,
           ["mp4", "m4a", "aac", "m4v"].contains(files[0].pathExtension.lowercased())
        {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try FileManager.default.copyItem(at: files[0], to: outputURL)
            return ExportResult(outputURL: outputURL, usedRemux: false)
        }

        let hasInit = files.contains { $0.lastPathComponent.contains("init") }
        let tsFiles = files.filter { $0.pathExtension.lowercased() == "ts" }
        if hasInit || tsFiles.isEmpty {
            return try await assembleFMP4(
                files: files,
                to: outputURL,
                workDirectory: workDirectory,
                preserveTimeline: preserveTimeline
            )
        }

        return try await assembleHLS(
            from: directory,
            to: outputURL,
            workDirectory: workDirectory,
            preserveTimeline: preserveTimeline
        )
    }

    private func assembleFMP4(
        files: [URL],
        to outputURL: URL,
        workDirectory: URL,
        preserveTimeline: Bool = false
    ) async throws -> ExportResult {
        // Concaténation binaire init + fragments.
        let ordered = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let merged = workDirectory.appendingPathComponent(".__merged_tmp.mp4")
        if FileManager.default.fileExists(atPath: merged.path) {
            try FileManager.default.removeItem(at: merged)
        }
        FileManager.default.createFile(atPath: merged.path, contents: nil)
        let handle = try FileHandle(forWritingTo: merged)
        defer { try? handle.close() }
        for file in ordered {
            let data = try Data(contentsOf: file)
            try handle.write(contentsOf: data)
        }
        try handle.close()

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // Pistes séparées : NE PAS remuxer chaque piste avant le mux A/V.
        // Un remux ffmpeg isolé réécrit les PTS (trous / étirement ~1.5 %) et casse
        // le lip-sync même avec `-copyts`. On garde le fMP4 concaténé brut.
        if preserveTimeline {
            try FileManager.default.moveItem(at: merged, to: outputURL)
            return ExportResult(outputURL: outputURL, usedRemux: false)
        }

        defer { try? FileManager.default.removeItem(at: merged) }
        try await ffmpeg.run(arguments: [
            "-y",
            "-i", merged.path,
            "-c", "copy",
            "-avoid_negative_ts", "make_zero",
            "-movflags", "+faststart",
            outputURL.path
        ])
        return ExportResult(outputURL: outputURL, usedRemux: true)
    }

    /// Seuil au-delà duquel on retente un remux A/V (cas type DASH séparés / Lanterns ~83 ms).
    static let avSyncToleranceSeconds: Double = 0.04
    /// Au-delà : on force un calage type lecteur (rogne la piste longue).
    static let avDurationMismatchLimitSeconds: Double = 1.0

    /// Recale un MP4 déjà exporté : coupe à la piste courte + remux.
    /// Si la timeline vidéo est étirée (skew), refuse — `atempo` linéaire ne fixe pas une dérive non linéaire.
    func realignLikePlayer(at url: URL) async throws -> AVSyncRepairResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MediaAssemblerError.message("Fichier introuvable")
        }
        let before = try await ffmpeg.probeStreamTiming(url: url)
        guard before.videoStart != nil, before.audioStart != nil else {
            return .missingAudioOrVideo
        }

        if before.hasSignificantVideoTimelineSkew {
            try await normalizeTimelineSkewIfNeeded(at: url)
            return .timelineCorrected(skewRatio: before.videoTimelineSkewRatio ?? 1)
        }

        let work = url.deletingLastPathComponent()
        let stagingOut = work.appendingPathComponent(".__os_player_sync.mp4")
        defer { try? FileManager.default.removeItem(at: stagingOut) }
        if FileManager.default.fileExists(atPath: stagingOut.path) {
            try FileManager.default.removeItem(at: stagingOut)
        }

        let videoPart = work.appendingPathComponent(".__os_repair_v.mp4")
        let audioPart = work.appendingPathComponent(".__os_repair_a.mp4")
        defer {
            try? FileManager.default.removeItem(at: videoPart)
            try? FileManager.default.removeItem(at: audioPart)
        }
        for part in [videoPart, audioPart] where FileManager.default.fileExists(atPath: part.path) {
            try FileManager.default.removeItem(at: part)
        }
        try await ffmpeg.run(arguments: [
            "-y", "-i", url.path, "-map", "0:v:0", "-c", "copy", videoPart.path
        ])
        try await ffmpeg.run(arguments: [
            "-y", "-i", url.path, "-map", "0:a:0", "-c", "copy", audioPart.path
        ])
        let trimmed = abs((before.videoDuration ?? 0) - (before.audioDuration ?? 0))
        try await muxAlignedAudioVideo(
            videoURL: videoPart,
            audioURL: audioPart,
            outputURL: stagingOut
        )
        try replaceFileAtomically(original: url, with: stagingOut)
        Self.scrubTransientFiles(in: work)
        return .playerAligned(trimmedSeconds: trimmed)
    }

    /// HLS MPEG-TS démuxé (vidéo + audio séparés) : un seul passage FFmpeg.
    /// Évite le remux piste-à-piste qui drop des frames et casse le lip-sync (Lanterns / vidzy).
    private func assembleDemuxedHLSTS(
        videoDirectory: URL,
        audioDirectory: URL,
        outputURL: URL,
        workDirectory: URL
    ) async throws {
        try normalizeHLSSegmentDirectory(videoDirectory)
        try normalizeHLSSegmentDirectory(audioDirectory)

        let videoSegments = listMediaFiles(in: videoDirectory).filter {
            ["ts", "m4s", "mp4"].contains($0.pathExtension.lowercased())
        }
        let audioSegments = listMediaFiles(in: audioDirectory).filter {
            ["ts", "m4s", "mp4", "aac", "m4a"].contains($0.pathExtension.lowercased())
        }
        guard !videoSegments.isEmpty else { throw MediaAssemblerError.noSegments }
        guard !audioSegments.isEmpty else {
            throw MediaAssemblerError.message("Piste audio HLS introuvable (dossier audio/)")
        }

        AppLog.ffmpeg.info(
            "Demuxed HLS TS mux: \(videoSegments.count, privacy: .public)v + \(audioSegments.count, privacy: .public)a segments"
        )

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let localVideoPlaylist = videoDirectory.appendingPathComponent("playlist.m3u8")
        let localAudioPlaylist = audioDirectory.appendingPathComponent("playlist.m3u8")
        if !FileManager.default.fileExists(atPath: localVideoPlaylist.path) {
            try writeSyntheticHLSPlaylist(segments: videoSegments, to: localVideoPlaylist)
        }
        if !FileManager.default.fileExists(atPath: localAudioPlaylist.path) {
            try writeSyntheticHLSPlaylist(segments: audioSegments, to: localAudioPlaylist)
        }

        // Préserver les PTS MPEG-TS partagés entre renditions (= même info que le
        // player HLS du navigateur). Sans -copyts, ffmpeg remet A et V à 0 chacun
        // de son côté : si l’audio démarre plus tard sur la timeline commune
        // (GoT FR seg1 @ +1.85 s), tout le son se retrouve en avance.
        // -start_at_zero est interdit ici (même effet destructeur).
        if let vFirst = videoSegments.first, let aFirst = audioSegments.first {
            let vStart = (try? await ffmpeg.probeStreamTiming(url: vFirst))?.videoStart
            let aStart = (try? await ffmpeg.probeStreamTiming(url: aFirst))?.audioStart
            if let vStart, let aStart {
                AppLog.ffmpeg.info(
                    "Demuxed HLS PTS offset A−V=\(String(format: "%+.3f", aStart - vStart), privacy: .public)s (v0=\(String(format: "%.3f", vStart), privacy: .public) a0=\(String(format: "%.3f", aStart), privacy: .public)) — preserved via -copyts"
                )
            }
        }

        do {
            try await ffmpeg.run(arguments: [
                "-y",
                "-allowed_extensions", "ALL",
                "-extension_picky", "0",
                "-copyts",
                "-i", localVideoPlaylist.path,
                "-allowed_extensions", "ALL",
                "-extension_picky", "0",
                "-i", localAudioPlaylist.path,
                "-map", "0:v:0",
                "-map", "1:a:0",
                "-c", "copy",
                "-bsf:a", "aac_adtstoasc",
                "-movflags", "+faststart",
                outputURL.path
            ])
        } catch {
            try await ffmpeg.run(arguments: [
                "-y",
                "-allowed_extensions", "ALL",
                "-extension_picky", "0",
                "-copyts",
                "-i", localVideoPlaylist.path,
                "-allowed_extensions", "ALL",
                "-extension_picky", "0",
                "-i", localAudioPlaylist.path,
                "-map", "0:v:0",
                "-map", "1:a:0",
                "-c", "copy",
                "-movflags", "+faststart",
                outputURL.path
            ])
        }

        let timing = try await ffmpeg.probeStreamTiming(url: outputURL)
        if let delta = timing.startDelta {
            AppLog.ffmpeg.info(
                "Demuxed HLS mux done: A−V start=\(String(format: "%+.3f", delta), privacy: .public)s"
            )
        }
        if let skew = timing.videoTimelineSkewRatio, abs(skew - 1) > 0.002 {
            AppLog.ffmpeg.info(
                "Demuxed HLS m3u8 result still skewed ×\(String(format: "%.4f", skew), privacy: .public)"
            )
        }
    }

    private func writeSyntheticHLSPlaylist(segments: [URL], to playlistURL: URL) throws {
        // Ne jamais inventer 10s : les segments GoT font 12s, Lanterns ~10s.
        // Sans EXTINF réels, on estime via ffprobe sur le 1er segment (fallback 10).
        var segmentDuration = 10.0
        if let first = segments.first {
            if let probed = try? awaitProbeDuration(url: first), probed > 0.5 {
                segmentDuration = probed
            }
        }
        let target = max(1, Int(ceil(segmentDuration)))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-TARGETDURATION:\(target)"
        ]
        let extinf = String(format: "#EXTINF:%.3f,", segmentDuration)
        for file in segments {
            lines.append(extinf)
            lines.append(file.lastPathComponent)
        }
        lines.append("#EXT-X-ENDLIST")
        try lines.joined(separator: "\n").write(to: playlistURL, atomically: true, encoding: .utf8)
    }

    /// Durée approximative d’un .ts (sync, hors acteur assemble).
    private func awaitProbeDuration(url: URL) throws -> Double? {
        // Probe sync via ffprobe process — réutilise le wrapper async n’est pas dispo ici
        // (writeSynthetic est sync). On utilise une estimation légère via attributs fichier
        // impossible ; fallback fixe évité. Appel ffprobe Process bloquant court.
        guard let ffprobe = (try? FFmpegWrapper())?.probeBinaryURL else { return nil }
        let process = Process()
        process.executableURL = ffprobe
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "csv=p=0",
            url.path
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Double(text), value.isFinite, value > 0
        else { return nil }
        return value
    }

    private func writeConcatList(_ files: [URL], to listURL: URL) throws {
        let body = files.map { file in
            let path = file.path.replacingOccurrences(of: "'", with: "'\\''")
            return "file '\(path)'"
        }.joined(separator: "\n")
        try body.write(to: listURL, atomically: true, encoding: .utf8)
    }

    /// Retire les leurres PNG/JPEG devant du MPEG-TS et renomme `.image` → `.ts`.
    /// Réécrit `playlist.m3u8` pour pointer vers les fichiers réellement présents
    /// (le download peut déjà avoir renommé `.image` → `.ts` sans toucher la playlist planifiée).
    private func normalizeHLSSegmentDirectory(_ directory: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }

        let files = listMediaFiles(in: directory).filter {
            $0.pathExtension.lowercased() != "m3u8"
        }
        var renames: [String: String] = [:]
        var strippedCount = 0

        for file in files {
            let originalName = file.lastPathComponent
            guard let raw = try? Data(contentsOf: file), !raw.isEmpty else { continue }
            let normalized = MediaSegmentNormalizer.normalize(raw)
            let preferredExt = MediaSegmentNormalizer.preferredExtension(
                for: normalized.kind,
                currentExtension: file.pathExtension
            )
            let decoyExts = Set(["image", "png", "jpg", "jpeg", "gif", "webp", "bin", "dat"])
            let shouldRename = normalized.kind != .unknown
                && decoyExts.contains(file.pathExtension.lowercased())
                && preferredExt != file.pathExtension.lowercased()

            var target = file
            if shouldRename {
                target = file.deletingPathExtension().appendingPathExtension(preferredExt)
            }

            let needsWrite = normalized.strippedBytes > 0 || target.path != file.path
            guard needsWrite else { continue }

            if normalized.strippedBytes > 0 { strippedCount += 1 }

            let partial = target.appendingPathExtension("partial")
            try normalized.data.write(to: partial, options: .atomic)
            if target.path != file.path, fm.fileExists(atPath: file.path) {
                try? fm.removeItem(at: file)
            }
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.moveItem(at: partial, to: target)
            if target.lastPathComponent != originalName {
                renames[originalName] = target.lastPathComponent
            }
        }

        if strippedCount > 0 || !renames.isEmpty {
            AppLog.ffmpeg.info(
                "HLS normalize \(directory.lastPathComponent, privacy: .public): stripped=\(strippedCount, privacy: .public) renamed=\(renames.count, privacy: .public)"
            )
        }

        try reconcileHLSPlaylistFilenames(in: directory)
    }

    /// Aligne les URI de `playlist.m3u8` sur les fichiers du dossier (même stem, autre extension).
    private func reconcileHLSPlaylistFilenames(in directory: URL) throws {
        let fm = FileManager.default
        let playlistURL = directory.appendingPathComponent("playlist.m3u8")
        guard fm.fileExists(atPath: playlistURL.path),
              let text = try? String(contentsOf: playlistURL, encoding: .utf8)
        else { return }

        let existing = Dictionary(
            uniqueKeysWithValues: listMediaFiles(in: directory)
                .filter { $0.pathExtension.lowercased() != "m3u8" }
                .map { ($0.deletingPathExtension().lastPathComponent.lowercased(), $0.lastPathComponent) }
        )

        var changed = 0
        let lines = text.components(separatedBy: .newlines).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return line }
            let name = URL(fileURLWithPath: trimmed).lastPathComponent
            if fm.fileExists(atPath: directory.appendingPathComponent(name).path) {
                return line
            }
            let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent.lowercased()
            guard let replacement = existing[stem], replacement != name else { return line }
            changed += 1
            return replacement
        }

        guard changed > 0 else { return }
        try lines.joined(separator: "\n").write(to: playlistURL, atomically: true, encoding: .utf8)
        AppLog.ffmpeg.info(
            "HLS playlist reconciled \(changed, privacy: .public) URI(s) in \(directory.lastPathComponent, privacy: .public)"
        )
    }

    /// Réécrit la playlist en gardant les `#EXTINF` et en pointant vers les segments présents (triés).
    private func rewriteHLSPlaylistMatchingFiles(segments: [URL], playlistURL: URL) throws {
        let sorted = segments.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let existingText = (try? String(contentsOf: playlistURL, encoding: .utf8)) ?? ""
        let extinfs = existingText
            .components(separatedBy: .newlines)
            .filter { $0.hasPrefix("#EXTINF:") }

        var targetDuration = 10
        if let line = existingText.components(separatedBy: .newlines).first(where: { $0.hasPrefix("#EXT-X-TARGETDURATION:") }),
           let value = Int(line.split(separator: ":").last ?? "10")
        {
            targetDuration = max(1, value)
        } else if let first = extinfs.first,
                  let raw = first.split(separator: ":").last?.split(separator: ",").first,
                  let seconds = Double(raw)
        {
            targetDuration = max(1, Int(ceil(seconds)))
        }

        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:1"
        ]
        for (index, file) in sorted.enumerated() {
            let extinf: String
            if index < extinfs.count {
                extinf = extinfs[index]
            } else {
                extinf = String(format: "#EXTINF:%.3f,", Double(targetDuration))
            }
            lines.append(extinf)
            lines.append(file.lastPathComponent)
        }
        lines.append("#EXT-X-ENDLIST")
        try lines.joined(separator: "\n").write(to: playlistURL, atomically: true, encoding: .utf8)
        AppLog.ffmpeg.info(
            "HLS playlist rewritten with \(sorted.count, privacy: .public) real segment(s)"
        )
    }

    private func directoryHasTSFiles(_ directory: URL) -> Bool {
        listMediaFiles(in: directory).contains { $0.pathExtension.lowercased() == "ts" }
    }

    /// Mux fMP4 concaténés bruts (A+V) en un seul passage — préserve tfdt/PTS du Period.
    private func muxAlignedAudioVideo(
        videoURL: URL,
        audioURL: URL,
        outputURL: URL
    ) async throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let videoTiming = try await ffmpeg.probeStreamTiming(url: videoURL)
        let audioTiming = try await ffmpeg.probeStreamTiming(url: audioURL)

        AppLog.ffmpeg.info(
            "Raw fMP4 mux: v_start=\(String(format: "%.3f", videoTiming.videoStart ?? -1), privacy: .public) a_start=\(String(format: "%.3f", audioTiming.audioStart ?? -1), privacy: .public) v_dur=\(String(format: "%.1f", videoTiming.videoDuration ?? -1), privacy: .public) a_dur=\(String(format: "%.1f", audioTiming.audioDuration ?? -1), privacy: .public)"
        )

        // Un seul remux : copyts + start_at_zero (décalage global unique).
        // Pas de genpts / make_zero / itsoffset / atempo ici.
        try await ffmpeg.run(arguments: [
            "-y",
            "-copyts",
            "-i", videoURL.path,
            "-i", audioURL.path,
            "-map", "0:v:0",
            "-map", "1:a:0?",
            "-c", "copy",
            "-start_at_zero",
            "-movflags", "+faststart",
            "-shortest",
            outputURL.path
        ])
    }

    /// Compacte la timeline vidéo étirée (trous PTS) et accélère l’audio du même facteur.
    private func normalizeTimelineSkewIfNeeded(at url: URL) async throws {
        let timing = try await ffmpeg.probeStreamTiming(url: url)
        guard timing.hasSignificantVideoTimelineSkew,
              let skew = timing.videoTimelineSkewRatio,
              skew > 1.002,
              skew < 1.08
        else { return }

        let scale = 1.0 / skew
        let atempo = skew
        let filter = Self.atempoFilterChain(atempo)
        AppLog.ffmpeg.info(
            "Post-mux skew \(String(format: "%.5f", skew), privacy: .public) → itsscale \(String(format: "%.5f", scale), privacy: .public) + af \(filter, privacy: .public)"
        )

        let work = url.deletingLastPathComponent()
        let videoPart = work.appendingPathComponent(".__os_skew_v.mp4")
        let staging = work.appendingPathComponent(".__os_skew_fix.mp4")
        defer {
            try? FileManager.default.removeItem(at: videoPart)
            try? FileManager.default.removeItem(at: staging)
        }
        for part in [videoPart, staging] where FileManager.default.fileExists(atPath: part.path) {
            try FileManager.default.removeItem(at: part)
        }

        // 1) Compresser uniquement les timestamps vidéo (copy, pas de re-encode).
        try await ffmpeg.run(arguments: [
            "-y",
            "-itsscale", String(format: "%.8f", scale),
            "-i", url.path,
            "-map", "0:v:0",
            "-c", "copy",
            videoPart.path
        ])

        // 2) Remux : vidéo compressée + audio accéléré du même ratio.
        var args: [String] = [
            "-y",
            "-i", videoPart.path,
            "-i", url.path,
            "-map", "0:v:0",
            "-map", "1:a:0",
            "-c:v", "copy",
            "-af", filter,
            "-c:a", "aac",
            "-movflags", "+faststart",
            "-shortest"
        ]
        args.append(staging.path)
        try await ffmpeg.run(arguments: args)
        try replaceFileAtomically(original: url, with: staging)
    }

    /// Supprime les fichiers de travail OpenStream (jamais le MP4 final).
    static func scrubTransientFiles(in directory: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let junkNames: Set<String> = [
            "merged_tmp.mp4",
            "concat_list.txt",
            ".__merged_tmp.mp4",
            ".__concat_list.txt",
            ".__concat_video.txt",
            ".__concat_audio.txt",
            ".__os_video.mp4",
            ".__os_audio.mp4",
            ".__os_remux.mp4",
            ".__os_avsync.mp4",
            ".__os_repair_v.mp4",
            ".__os_repair_a.mp4",
            ".__os_repair_out.mp4",
            ".__os_repair_bak.mp4",
            ".__os_manual_sync.mp4",
            ".__os_drift_sync.mp4",
            ".__os_player_sync.mp4",
            ".__os_player_in.mp4",
            ".__os_cfr.mp4",
            ".__os_skew_fix.mp4",
            ".__os_skew_v.mp4"
        ]
        for url in items {
            let name = url.lastPathComponent
            if junkNames.contains(name)
                || name.hasPrefix(".__os_")
                || name.hasPrefix("merged_tmp")
                || name == "concat_list.txt"
            {
                try? fm.removeItem(at: url)
            }
        }
        // Hidden work files (skipsHiddenFiles may miss some platforms)
        for name in junkNames {
            let url = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }
    }

    private func listMediaFiles(in directory: URL) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls.filter { url in
            let name = url.lastPathComponent
            if name.hasPrefix(".") || name.hasPrefix(".__") { return false }
            if name == "concat_list.txt" || name.hasPrefix("merged") { return false }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { return false }
            return true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func directoryHasMediaFiles(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.path) && !listMediaFiles(in: directory).isEmpty
    }

    private func findSubtitleFile(in directory: URL) -> URL? {
        let files = listMediaFiles(in: directory)
        return files.first(where: {
            ["vtt", "srt", "ttml"].contains($0.pathExtension.lowercased())
        }) ?? files.first
    }

    private func exportSubtitle(from primary: URL, siblingsIn directory: URL, to destination: URL) throws {
        let ext = primary.pathExtension.lowercased()
        let siblings = listMediaFiles(in: directory).filter {
            $0.pathExtension.lowercased() == ext || (ext.isEmpty && $0.pathExtension.isEmpty)
        }
        if siblings.count <= 1 {
            try FileManager.default.copyItem(at: primary, to: destination)
            return
        }
        // Concat texte pour multi-segments VTT/SRT
        let body = try siblings.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        try body.write(to: destination, atomically: true, encoding: .utf8)
    }

    private func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "export" : cleaned).prefix(80))
    }

    private func uniqueURL(in directory: URL, preferredName: String) -> URL {
        var url = directory.appendingPathComponent(preferredName)
        if !FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let base = (preferredName as NSString).deletingPathExtension
        let ext = (preferredName as NSString).pathExtension
        for i in 2...99 {
            let candidate = directory.appendingPathComponent("\(base)-\(i).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            url = candidate
        }
        return directory.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(6)).\(ext)")
    }
}
