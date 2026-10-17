import Foundation

enum FFmpegError: Error, LocalizedError, Sendable {
    case binaryNotFound
    case processFailed(exitCode: Int32, stderr: String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "FFmpeg embarqué introuvable (relance ./scripts/fetch-bundled-ffmpeg.sh puis rebuild)"
        case .processFailed(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = trimmed.split(separator: "\n").suffix(4).joined(separator: " | ")
            return "FFmpeg a échoué (\(code)): \(snippet)"
        case .message(let text):
            return text
        }
    }
}

/// Timestamps / durées des pistes A/V (secondes), via ffprobe.
struct MediaStreamTiming: Sendable, Equatable {
    var videoStart: Double?
    var audioStart: Double?
    var videoDuration: Double?
    var audioDuration: Double?
    var videoFrameCount: Double?
    var videoTimeBase: String?
    var videoRFrameRate: String?
    var videoAvgFrameRate: String?

    /// Écart |vidéo − audio| sur le start_time.
    var startDelta: Double? {
        guard let videoStart, let audioStart else { return nil }
        return abs(videoStart - audioStart)
    }

    /// audioDuration − videoDuration (négatif = audio plus court).
    var durationDelta: Double? {
        guard let videoDuration, let audioDuration else { return nil }
        return audioDuration - videoDuration
    }

    /// Facteur atempo pour coller la durée audio à la vidéo (`audio/video`).
    var atempoToMatchVideo: Double? {
        guard let videoDuration, let audioDuration,
              videoDuration > 0.5, audioDuration > 0.5
        else { return nil }
        return audioDuration / videoDuration
    }

    /// Durée vidéo attendue si CFR à `r_frame_rate` (frames / fps).
    var videoDurationAtNominalRate: Double? {
        guard let videoFrameCount, videoFrameCount > 0,
              let fps = Self.parseRate(videoRFrameRate), fps > 0
        else { return nil }
        return videoFrameCount / fps
    }

    /// La timeline vidéo est étirée/compressée vs le framerate nominal.
    var videoTimelineSkewRatio: Double? {
        guard let videoDuration, videoDuration > 1,
              let expected = videoDurationAtNominalRate, expected > 1
        else { return nil }
        return videoDuration / expected
    }

    var hasSignificantVideoTimelineSkew: Bool {
        guard let ratio = videoTimelineSkewRatio else { return false }
        return abs(ratio - 1) > 0.002
    }

    static func parseRate(_ value: String?) -> Double? {
        guard let value, !value.isEmpty, value != "0/0" else { return nil }
        let parts = value.split(separator: "/")
        if parts.count == 2,
           let n = Double(parts[0]),
           let d = Double(parts[1]),
           d != 0
        {
            return n / d
        }
        return Double(value)
    }

    static func parseTimeBase(_ value: String?) -> (num: Int, den: Int)? {
        guard let value else { return nil }
        let parts = value.split(separator: "/")
        guard parts.count == 2,
              let num = Int(parts[0]),
              let den = Int(parts[1]),
              num != 0, den != 0
        else { return nil }
        return (num, den)
    }
}

/// Wrapper isolé — invoque le binaire FFmpeg via Process.
/// Priorité : Helpers embarqués dans le bundle (D017), puis override env, puis Homebrew/PATH.
struct FFmpegWrapper: Sendable {
    var binaryURL: URL
    var probeBinaryURL: URL?

    init(binaryURL: URL? = nil, probeBinaryURL: URL? = nil) throws {
        if let binaryURL {
            self.binaryURL = binaryURL
        } else if let resolved = Self.resolveBinary(named: "ffmpeg") {
            self.binaryURL = resolved
        } else {
            throw FFmpegError.binaryNotFound
        }
        if let probeBinaryURL {
            self.probeBinaryURL = probeBinaryURL
        } else {
            let sibling = self.binaryURL.deletingLastPathComponent()
                .appendingPathComponent("ffprobe")
            if FileManager.default.isExecutableFile(atPath: sibling.path) {
                self.probeBinaryURL = sibling
            } else {
                self.probeBinaryURL = Self.resolveBinary(named: "ffprobe")
            }
        }
    }

    /// `true` si le binaire résolu est celui du bundle (pas Homebrew).
    static func isUsingBundledBinary() -> Bool {
        guard let url = resolveBinary(named: "ffmpeg"),
              let bundled = bundledBinaryURL(named: "ffmpeg")
        else { return false }
        return url.standardizedFileURL == bundled.standardizedFileURL
    }

    static func resolveBinary(named name: String = "ffmpeg") -> URL? {
        // 1) Bundle app (indépendant de l’environnement global).
        if let bundled = bundledBinaryURL(named: name) {
            return bundled
        }
        // 2) Override explicite (debug / CI).
        let envKey = name == "ffprobe" ? "OPENSTREAM_FFPROBE" : "OPENSTREAM_FFMPEG"
        if let override = ProcessInfo.processInfo.environment[envKey],
           FileManager.default.isExecutableFile(atPath: override)
        {
            return URL(fileURLWithPath: override)
        }
        // 3) Fallback Homebrew / PATH (dev sans Helpers fetchés).
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               FileManager.default.isExecutableFile(atPath: path)
            {
                return URL(fileURLWithPath: path)
            }
        } catch {
            return nil
        }
        return nil
    }

    /// App : `Contents/Resources/Helpers/`. CLI : `Helpers/` à côté du binaire.
    static func bundledBinaryURL(named name: String) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("Helpers/\(name)"))
        }
        if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Helpers") {
            candidates.append(url)
        }
        candidates.append(
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)")
        )
        // openstream-cli : Helpers/ (ou binaire à plat) voisin de l’exécutable
        // (résoudre les symlinks — install `~/.local/bin/openstream-cli` → opt/).
        if let execURL = Bundle.main.executableURL {
            let execDir = execURL.resolvingSymlinksInPath().deletingLastPathComponent()
            candidates.append(execDir.appendingPathComponent("Helpers/\(name)"))
            candidates.append(execDir.appendingPathComponent(name))
        }
        for bundle in [Bundle.main, Bundle(for: BundleToken.self)] {
            if let res = bundle.resourceURL {
                candidates.append(res.appendingPathComponent("Helpers/\(name)"))
            }
        }
        for url in candidates {
            if fm.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private final class BundleToken {}

    @discardableResult
    func run(arguments: [String]) async throws -> String {
        try await runProcess(executable: binaryURL, label: "ffmpeg", arguments: arguments)
    }

    /// Lit start_time + duration (+ métadonnées vidéo utiles au CFR) des pistes.
    func probeStreamTiming(url: URL) async throws -> MediaStreamTiming {
        guard let probeBinaryURL else {
            return MediaStreamTiming()
        }
        let output = try await runProcess(
            executable: probeBinaryURL,
            label: "ffprobe",
            arguments: [
                "-v", "error",
                "-show_entries",
                "stream=codec_type,start_time,duration,nb_frames,time_base,r_frame_rate,avg_frame_rate",
                "-of", "json",
                url.path
            ]
        )
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]]
        else {
            return MediaStreamTiming()
        }

        var timing = MediaStreamTiming()
        for stream in streams {
            let type = stream["codec_type"] as? String
            let start = Self.doubleValue(stream["start_time"])
            let duration = Self.doubleValue(stream["duration"])
            if type == "video", timing.videoStart == nil {
                timing.videoStart = start
                timing.videoDuration = duration
                timing.videoFrameCount = Self.doubleValue(stream["nb_frames"])
                timing.videoTimeBase = stream["time_base"] as? String
                timing.videoRFrameRate = stream["r_frame_rate"] as? String
                timing.videoAvgFrameRate = stream["avg_frame_rate"] as? String
            } else if type == "audio", timing.audioStart == nil {
                timing.audioStart = start
                timing.audioDuration = duration
            }
        }
        return timing
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? String { return Double(value) }
        return nil
    }

    private func runProcess(
        executable: URL,
        label: String,
        arguments: [String]
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    let out = Pipe()
                    let err = Pipe()
                    process.standardOutput = out
                    process.standardError = err

                    AppLog.ffmpeg.info("\(label, privacy: .public) \(arguments.joined(separator: " "), privacy: .public)")
                    try process.run()

                    // Drain pipes while the process runs — otherwise stderr progress fills the
                    // ~64 KiB pipe buffer and deadlocks waitUntilExit (0% CPU forever).
                    let group = DispatchGroup()
                    let stdoutBox = DataBox()
                    let stderrBox = DataBox()
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        stdoutBox.value = out.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        stderrBox.value = err.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }

                    process.waitUntilExit()
                    group.wait()

                    let stderr = String(data: stderrBox.value, encoding: .utf8) ?? ""
                    let stdout = String(data: stdoutBox.value, encoding: .utf8) ?? ""

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: stdout.isEmpty ? stderr : stdout)
                    } else {
                        continuation.resume(
                            throwing: FFmpegError.processFailed(
                                exitCode: process.terminationStatus,
                                stderr: stderr
                            )
                        )
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Mutable box so pipe drains can write without capturing `var` across queues.
final class DataBox: @unchecked Sendable {
    var value = Data()
}
