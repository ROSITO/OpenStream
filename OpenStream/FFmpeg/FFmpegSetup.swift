import Foundation

enum FFmpegSetupError: Error, LocalizedError, Sendable {
    case brewNotFound
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .brewNotFound:
            return "Homebrew introuvable. Installez-le depuis https://brew.sh puis réessayez."
        case .installFailed(let text):
            return text
        }
    }
}

/// Détection / installation de FFmpeg via Homebrew (binaire externe, pas de liaison).
enum FFmpegSetup: Sendable {
    enum Status: Equatable, Sendable {
        case ready(path: String)
        case missingFFmpeg
        case missingHomebrew
    }

    static func status() -> Status {
        if let path = FFmpegWrapper.resolveBinary()?.path {
            return .ready(path: path)
        }
        return brewURL == nil ? .missingHomebrew : .missingFFmpeg
    }

    static var brewURL: URL? {
        let candidates = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew"
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func installFFmpeg() async throws {
        guard let brew = brewURL else {
            throw FFmpegSetupError.brewNotFound
        }
        let brewBin = brew.deletingLastPathComponent().path
        let output = try await run(
            executable: brew,
            arguments: ["install", "ffmpeg"],
            extraPath: brewBin
        )
        guard FFmpegWrapper.resolveBinary() != nil else {
            let snippet = output.split(separator: "\n").suffix(6).joined(separator: "\n")
            throw FFmpegSetupError.installFailed(
                snippet.isEmpty
                    ? "brew install ffmpeg a terminé sans installer le binaire."
                    : snippet
            )
        }
    }

    @discardableResult
    private static func run(executable: URL, arguments: [String], extraPath: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    var env = ProcessInfo.processInfo.environment
                    let path = env["PATH"] ?? "/usr/bin:/bin"
                    env["PATH"] = "\(extraPath):\(path)"
                    env["HOMEBREW_NO_ANALYTICS"] = "1"
                    env["NONINTERACTIVE"] = "1"
                    process.environment = env

                    let out = Pipe()
                    let err = Pipe()
                    process.standardOutput = out
                    process.standardError = err

                    AppLog.ffmpeg.info("brew \(arguments.joined(separator: " "), privacy: .public)")
                    try process.run()

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
                    let combined = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: combined)
                    } else {
                        let snippet = combined.split(separator: "\n").suffix(8).joined(separator: " | ")
                        continuation.resume(
                            throwing: FFmpegSetupError.installFailed(
                                snippet.isEmpty
                                    ? "brew a échoué (\(process.terminationStatus))"
                                    : snippet
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
