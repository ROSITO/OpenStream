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
            usedRemux = try await assembleHLS(from: segmentsDirectory, to: videoTarget, workDirectory: workDirectory).usedRemux
        case .dash:
            usedRemux = try await assembleDASH(from: segmentsDirectory, to: videoTarget, workDirectory: workDirectory).usedRemux
        }

        var finalURL = videoTarget
        if hasExtraAudio {
            let audioTarget = workDirectory.appendingPathComponent(".__os_audio.mp4")
            _ = try await assembleAuxiliaryMedia(from: audioDir, to: audioTarget, workDirectory: workDirectory)
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try await ffmpeg.run(arguments: [
                "-y",
                "-i", videoTarget.path,
                "-i", audioTarget.path,
                "-c", "copy",
                "-map", "0:v:0",
                "-map", "1:a:0?",
                "-shortest",
                "-movflags", "+faststart",
                outputURL.path
            ])
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

    private func assembleHLS(from directory: URL, to outputURL: URL, workDirectory: URL? = nil) async throws -> ExportResult {
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
            return try await assembleFMP4(files: files, to: outputURL, workDirectory: work)
        }

        // MPEG-TS HLS — concat demuxer + remux MP4
        let segments = tsFiles.isEmpty ? files : tsFiles
        let listURL = work.appendingPathComponent(".__concat_list.txt")
        let listBody = segments.map { file in
            let path = file.path.replacingOccurrences(of: "'", with: "'\\''")
            return "file '\(path)'"
        }.joined(separator: "\n")
        try listBody.write(to: listURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: listURL) }

        // Remux vers un temporaire dans .parts, puis rename atomique — évite
        // deux jobs concurrentes / un retry qui écrasent un MP4 partiel.
        let staging = work.appendingPathComponent(".__os_remux.mp4")
        if FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.removeItem(at: staging)
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            try await ffmpeg.run(arguments: [
                "-y",
                "-f", "concat",
                "-safe", "0",
                "-i", listURL.path,
                "-c", "copy",
                "-bsf:a", "aac_adtstoasc",
                "-movflags", "+faststart",
                staging.path
            ])
        } catch {
            try await ffmpeg.run(arguments: [
                "-y",
                "-f", "concat",
                "-safe", "0",
                "-i", listURL.path,
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

    private func assembleDASH(from directory: URL, to outputURL: URL, workDirectory: URL? = nil) async throws -> ExportResult {
        let files = listMediaFiles(in: directory)
        guard !files.isEmpty else { throw MediaAssemblerError.noSegments }
        return try await assembleFMP4(files: files, to: outputURL, workDirectory: workDirectory ?? directory)
    }

    private func assembleAuxiliaryMedia(from directory: URL, to outputURL: URL, workDirectory: URL) async throws -> ExportResult {
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
            return try await assembleFMP4(files: files, to: outputURL, workDirectory: workDirectory)
        }

        return try await assembleHLS(from: directory, to: outputURL, workDirectory: workDirectory)
    }

    private func assembleFMP4(files: [URL], to outputURL: URL, workDirectory: URL) async throws -> ExportResult {
        // Concaténation binaire init + fragments dans .parts, puis remux vers le MP4 final
        let ordered = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let merged = workDirectory.appendingPathComponent(".__merged_tmp.mp4")
        if FileManager.default.fileExists(atPath: merged.path) {
            try FileManager.default.removeItem(at: merged)
        }
        FileManager.default.createFile(atPath: merged.path, contents: nil)
        let handle = try FileHandle(forWritingTo: merged)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: merged)
        }
        for file in ordered {
            let data = try Data(contentsOf: file)
            try handle.write(contentsOf: data)
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try await ffmpeg.run(arguments: [
            "-y",
            "-i", merged.path,
            "-c", "copy",
            "-movflags", "+faststart",
            outputURL.path
        ])
        return ExportResult(outputURL: outputURL, usedRemux: true)
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
            ".__os_video.mp4",
            ".__os_audio.mp4",
            ".__os_remux.mp4"
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
