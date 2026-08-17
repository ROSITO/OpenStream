import Foundation

enum FFmpegError: Error, LocalizedError, Sendable {
    case binaryNotFound
    case processFailed(exitCode: Int32, stderr: String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "FFmpeg introuvable (installe via Homebrew: brew install ffmpeg)"
        case .processFailed(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = trimmed.split(separator: "\n").suffix(4).joined(separator: " | ")
            return "FFmpeg a échoué (\(code)): \(snippet)"
        case .message(let text):
            return text
        }
    }
}

/// Wrapper isolé — invoque le binaire FFmpeg via Process (Homebrew / PATH).
/// Pas de liaison libav* pour l’instant (D010).
struct FFmpegWrapper: Sendable {
    var binaryURL: URL

    init(binaryURL: URL? = nil) throws {
        if let binaryURL {
            self.binaryURL = binaryURL
        } else if let resolved = Self.resolveBinary() {
            self.binaryURL = resolved
        } else {
            throw FFmpegError.binaryNotFound
        }
    }

    static func resolveBinary() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        // PATH lookup
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["ffmpeg"]
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

    @discardableResult
    func run(arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = self.binaryURL
                    process.arguments = arguments
                    let out = Pipe()
                    let err = Pipe()
                    process.standardOutput = out
                    process.standardError = err

                    AppLog.ffmpeg.info("ffmpeg \(arguments.joined(separator: " "), privacy: .public)")
                    try process.run()

                    // Drain pipes while ffmpeg runs — otherwise stderr progress fills the
                    // ~64 KiB pipe buffer and deadlocks waitUntilExit (0% CPU forever).
                    let group = DispatchGroup()
                    var stdoutData = Data()
                    var stderrData = Data()
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        stdoutData = out.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        stderrData = err.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }

                    process.waitUntilExit()
                    group.wait()

                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""

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
