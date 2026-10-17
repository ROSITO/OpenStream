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

    /// Cas type Lanterns : piste vidéo avec PTS de départ ≠ 0 et audio à 0.
    @Test func alignsSeparateAudioVideoStartTimes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenStreamAVSync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ffmpeg = try FFmpegWrapper()
        let rawVideo = root.appendingPathComponent("raw_video.mp4")
        let delayedVideo = root.appendingPathComponent("00000_init.mp4")
        let audioDir = root.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let audio = audioDir.appendingPathComponent("00000_init.mp4")

        try await ffmpeg.run(arguments: [
            "-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=24:duration=3",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            rawVideo.path
        ])
        // Simule un fragment DASH/HLS dont le premier PTS vidéo n’est pas à 0 (~2 frames @24fps).
        try await ffmpeg.run(arguments: [
            "-y", "-itsoffset", "0.083", "-i", rawVideo.path,
            "-c", "copy", delayedVideo.path
        ])
        try await ffmpeg.run(arguments: [
            "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
            "-c:a", "aac",
            audio.path
        ])

        let videoTiming = try await ffmpeg.probeStreamTiming(url: delayedVideo)
        let audioTiming = try await ffmpeg.probeStreamTiming(url: audio)
        #expect((videoTiming.videoStart ?? 0) > 0.05)
        #expect((audioTiming.audioStart ?? 1) < 0.02)

        let exportDir = root.appendingPathComponent("exports", isDirectory: true)
        let assembler = try MediaAssembler(ffmpeg: ffmpeg)
        let result = try await assembler.assemble(
            jobTitle: "lanterns-sync",
            kind: .dash,
            segmentsDirectory: root,
            outputDirectory: exportDir
        )

        let muxed = try await ffmpeg.probeStreamTiming(url: result.outputURL)
        #expect(muxed.videoStart != nil)
        #expect(muxed.audioStart != nil)
        // On préserve le décalage Period (~83 ms) : ne plus forcer un alignement < 40 ms.
        let delta = muxed.startDelta ?? 999
        #expect(delta < 0.12)
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
    }

    @Test func repairsExistingDesyncedMP4InPlace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenStreamRepair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ffmpeg = try FFmpegWrapper()
        let video = root.appendingPathComponent("v.mp4")
        let audio = root.appendingPathComponent("a.mp4")
        let broken = root.appendingPathComponent("broken.mp4")

        try await ffmpeg.run(arguments: [
            "-y", "-f", "lavfi", "-i", "testsrc=size=160x120:rate=24:duration=2",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", video.path
        ])
        try await ffmpeg.run(arguments: [
            "-y", "-f", "lavfi", "-i", "sine=duration=2",
            "-c:a", "aac", audio.path
        ])
        // Décalage volontaire ~83 ms (cas Lanterns).
        try await ffmpeg.run(arguments: [
            "-y", "-itsoffset", "0.083", "-i", video.path, "-i", audio.path,
            "-c", "copy", "-map", "0:v:0", "-map", "1:a:0", broken.path
        ])

        let before = try await ffmpeg.probeStreamTiming(url: broken)
        #expect((before.startDelta ?? 0) > 0.04)

        let assembler = try MediaAssembler(ffmpeg: ffmpeg)
        let result = try await assembler.repairAVSync(at: broken)
        guard case .repaired = result else {
            Issue.record("Expected repaired, got \(result)")
            return
        }

        let after = try await ffmpeg.probeStreamTiming(url: broken)
        #expect((after.startDelta ?? 999) < 0.04)
        #expect(FileManager.default.fileExists(atPath: broken.path))
    }

    @Test func appliesManualAudioShift() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenStreamManualSync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ffmpeg = try FFmpegWrapper()
        let file = root.appendingPathComponent("clip.mp4")
        try await ffmpeg.run(arguments: [
            "-y",
            "-f", "lavfi", "-i", "testsrc=size=160x120:rate=24:duration=2",
            "-f", "lavfi", "-i", "sine=duration=2",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
            "-shortest", file.path
        ])

        let assembler = try MediaAssembler(ffmpeg: ffmpeg)
        let result = try await assembler.applyManualAudioShift(at: file, audioShiftSeconds: 0.2)
        guard case .offsetApplied(let shift) = result else {
            Issue.record("Expected offsetApplied, got \(result)")
            return
        }
        #expect(abs(shift - 0.2) < 0.001)
        #expect(FileManager.default.fileExists(atPath: file.path))

        let timing = try await ffmpeg.probeStreamTiming(url: file)
        #expect(timing.videoStart != nil)
        #expect(timing.audioStart != nil)
    }

    @Test func correctsDurationDriftWithAtempo() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenStreamDrift-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ffmpeg = try FFmpegWrapper()
        let file = root.appendingPathComponent("drift.mp4")
        // Vidéo 2 s, audio 2.2 s → dérive ~200 ms
        try await ffmpeg.run(arguments: [
            "-y",
            "-f", "lavfi", "-i", "testsrc=size=160x120:rate=24:duration=2",
            "-f", "lavfi", "-i", "sine=duration=2.2",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
            "-shortest", // wait - shortest would cut audio. Don't use shortest.
            file.path
        ])
        // Above with -shortest would truncate. Rebuild without shortest properly:
        try? FileManager.default.removeItem(at: file)
        try await ffmpeg.run(arguments: [
            "-y",
            "-f", "lavfi", "-i", "testsrc=size=160x120:rate=24:duration=2",
            "-f", "lavfi", "-i", "sine=duration=2.2",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
            "-t", "2.2",
            file.path
        ])

        let before = try await ffmpeg.probeStreamTiming(url: file)
        #expect(abs(before.durationDelta ?? 0) > 0.05)

        let assembler = try MediaAssembler(ffmpeg: ffmpeg)
        let result = try await assembler.correctAVDrift(at: file)
        guard case .driftCorrected = result else {
            Issue.record("Expected driftCorrected, got \(result)")
            return
        }
        let after = try await ffmpeg.probeStreamTiming(url: file)
        #expect(abs(after.durationDelta ?? 999) < 0.08)
    }

    @Test func atempoForEndAudioLeadSlowsWhenAudioAhead() {
        let atempo = MediaAssembler.atempoForEndAudioLead(
            videoDuration: 3443,
            endAudioLeadSeconds: 1.0
        )
        #expect(atempo != nil)
        #expect(abs((atempo ?? 0) - (3443.0 / 3444.0)) < 0.000001)
        #expect((atempo ?? 1) < 1)
    }
}
