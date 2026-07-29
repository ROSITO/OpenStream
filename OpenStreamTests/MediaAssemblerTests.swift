import Foundation
import Testing
@testable import OpenStream

struct MediaAssemblerTests {
    @Test func assemblesLocalTSSegmentsToMP4() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenStreamAsm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Generate two tiny valid-ish TS packets via ffmpeg if available
        let ffmpeg = try FFmpegWrapper()
        let seg0 = root.appendingPathComponent("00000_seg.ts")
        let seg1 = root.appendingPathComponent("00001_seg.ts")

        try await ffmpeg.run(arguments: [
            "-y", "-f", "lavfi", "-i", "testsrc=size=160x120:rate=1:duration=1",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
            "-c:v", "libx264", "-c:a", "aac", "-shortest",
            "-f", "mpegts", seg0.path
        ])
        try await ffmpeg.run(arguments: [
            "-y", "-f", "lavfi", "-i", "testsrc=size=160x120:rate=1:duration=1",
            "-f", "lavfi", "-i", "sine=frequency=880:duration=1",
            "-c:v", "libx264", "-c:a", "aac", "-shortest",
            "-f", "mpegts", seg1.path
        ])

        let exportDir = root.appendingPathComponent("exports", isDirectory: true)
        let assembler = try MediaAssembler(ffmpeg: ffmpeg)
        let result = try await assembler.assemble(
            jobTitle: "test-clip",
            kind: .hls,
            segmentsDirectory: root,
            outputDirectory: exportDir
        )

        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: result.outputURL.path)
        let size = attrs[.size] as? NSNumber
        #expect((size?.intValue ?? 0) > 1000)
    }

    @Test func copiesProgressiveMP4() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenStreamProg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("clip.mp4")
        try Data(repeating: 7, count: 2048).write(to: source)
        let exportDir = root.appendingPathComponent("exports", isDirectory: true)
        let assembler = try MediaAssembler()
        let result = try await assembler.assemble(
            jobTitle: "prog",
            kind: .progressive,
            segmentsDirectory: root,
            outputDirectory: exportDir
        )
        #expect(result.outputURL.lastPathComponent.hasSuffix(".mp4"))
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
    }
}
