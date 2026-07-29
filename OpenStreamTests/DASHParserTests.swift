import Foundation
import Testing
@testable import OpenStream

struct DASHParserTests {
    @Test func parsesSegmentListWithAudioAndSubs() throws {
        let text = try fixture("dash/segmentlist.mpd")
        let url = try #require(URL(string: "https://cdn.example.com/manifest.mpd"))
        let manifest = try DASHParser.parse(xml: text, manifestURL: url)

        #expect(manifest.videoRepresentations.count == 2)
        #expect(manifest.audioRepresentations.count == 1)
        #expect(manifest.textRepresentations.count == 1)
        #expect(manifest.periodDurationSeconds == 30)

        let video = try #require(manifest.videoRepresentations.first { $0.id == "video720" })
        #expect(video.width == 1280)
        #expect(video.height == 720)
        #expect(video.segments.count == 4)
        #expect(video.segments[0].isInitialization)
        #expect(video.segments[0].url.absoluteString.hasSuffix("video/init.mp4"))
        #expect(video.segments[1].url.absoluteString.hasSuffix("video/seg-1.m4s"))

        let audio = try #require(manifest.audioRepresentations.first)
        #expect(audio.language == "fr")
        #expect(audio.segments.count == 1)
        #expect(audio.segments[0].url.absoluteString.hasSuffix("audio/fr.mp4"))

        let units = try DASHParser.units(for: video)
        #expect(units.count == 4)
        #expect(units[0].fileName.contains("init"))
    }

    @Test func parsesSegmentTemplate() throws {
        let text = try fixture("dash/template.mpd")
        let url = try #require(URL(string: "https://cdn.example.com/manifest.mpd"))
        let manifest = try DASHParser.parse(xml: text, manifestURL: url)

        let video = try #require(manifest.videoRepresentations.first)
        #expect(video.id == "v1")
        // init + 4 media (20s / 5s)
        #expect(video.segments.count == 5)
        #expect(video.segments[0].isInitialization)
        #expect(video.segments[0].url.absoluteString.contains("init-v1.mp4"))
        #expect(video.segments[1].url.absoluteString.contains("chunk-v1-00001.m4s"))
        #expect(video.segments[4].url.absoluteString.contains("chunk-v1-00004.m4s"))
    }

    @Test func makeDASHBuildsTracks() throws {
        let text = try fixture("dash/segmentlist.mpd")
        let url = try #require(URL(string: "https://cdn.example.com/manifest.mpd"))
        let candidate = NetworkMediaCandidate(url: url, source: .manual)
        let manifest = try DASHParser.parse(xml: text, manifestURL: url)
        let media = MediaDetector.makeDASH(from: candidate, manifest: manifest, title: "Film DASH")

        #expect(media.kind == .dash)
        #expect(media.variants.count == 2)
        #expect(media.preferredVariant?.dashRepresentationID == "video1080")
        #expect(media.audioTracks.count == 1)
        #expect(media.subtitleTracks.count == 1)
        #expect(media.displayTitle == "Film DASH")
        #expect(MediaDetector.classify(url: url, mimeType: "application/dash+xml") == .dash)
    }
}

struct HLSMediaRenditionTests {
    @Test func parsesEXTXMediaAudioAndSubs() throws {
        let text = try fixture("hls/master_with_media.m3u8")
        let url = try #require(URL(string: "https://cdn.example.com/video/master.m3u8"))
        let playlist = try HLSParser.parse(text: text, playlistURL: url)

        #expect(playlist.kind == .master)
        #expect(playlist.streams.count == 2)
        #expect(playlist.renditions.count == 3)

        let candidate = NetworkMediaCandidate(url: url, source: .manual)
        let media = MediaDetector.makeHLS(from: candidate, playlist: playlist, title: "Multi")
        #expect(media.audioTracks.count == 2)
        #expect(media.subtitleTracks.count == 1)
        #expect(media.audioTracks.contains { $0.language == "en" && $0.isDefault })
        #expect(media.hasSelectableTracks)
    }
}
