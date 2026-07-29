import Foundation
import Testing
@testable import OpenStream

struct HLSParserTests {
    @Test func parsesMasterPlaylist() throws {
        let text = try fixture("hls/master.m3u8")
        let url = try #require(URL(string: "https://cdn.example.com/video/master.m3u8"))
        let playlist = try HLSParser.parse(text: text, playlistURL: url)

        #expect(playlist.kind == .master)
        #expect(playlist.streams.count == 3)
        #expect(playlist.streams.map(\.bandwidth) == [800_000, 1_400_000, 2_800_000])
        #expect(playlist.streams[1].resolution?.width == 1280)
        #expect(playlist.streams[1].resolution?.height == 720)
        #expect(playlist.streams[2].uri.absoluteString.hasSuffix("1080p.m3u8"))
    }

    @Test func parsesMediaVOD() throws {
        let text = try fixture("hls/media_vod.m3u8")
        let url = try #require(URL(string: "https://cdn.example.com/video/index.m3u8"))
        let playlist = try HLSParser.parse(text: text, playlistURL: url)

        #expect(playlist.kind == .media)
        let media = try #require(playlist.media)
        #expect(media.hasEndList)
        #expect(media.segments.count == 3)
        #expect(media.segments[0].uri.absoluteString.hasSuffix("seg0.ts"))
        #expect(abs(media.totalDuration - 26.5) < 0.001)
    }

    @Test func parsesFMP4MediaWithMap() throws {
        let text = try fixture("hls/media_fmp4.m3u8")
        let url = try #require(URL(string: "https://cdn.example.com/fmp4/index.m3u8"))
        let playlist = try HLSParser.parse(text: text, playlistURL: url)
        let media = try #require(playlist.media)
        #expect(media.mapURI?.absoluteString.hasSuffix("init.mp4") == true)
        #expect(media.segments.count == 2)
        #expect(media.hasEndList)
    }

    @Test func resolvesRelativeMasterURIs() throws {
        let text = try fixture("hls/master_relative.m3u8")
        let url = try #require(URL(string: "https://cdn.example.com/video/live/master.m3u8"))
        let playlist = try HLSParser.parse(text: text, playlistURL: url)
        #expect(playlist.streams.count == 2)
        #expect(playlist.streams[0].uri.absoluteString == "https://cdn.example.com/video/live/relative/720.m3u8")
        #expect(playlist.streams[1].uri.absoluteString == "https://cdn.example.com/video/1080/index.m3u8")
    }
}

struct MediaDetectorTests {
    @Test func classifiesHLSAndMP4AndSegments() throws {
        let hls = try #require(URL(string: "https://u14.vidzy.cc/list/abc.m3u8"))
        let mp4 = try #require(URL(string: "https://cdn.example.com/film.mp4"))
        let ts = try #require(URL(string: "https://u14.vidzy.cc/seg/1.ts"))

        #expect(MediaDetector.classify(url: hls, mimeType: nil) == .hls)
        #expect(MediaDetector.classify(url: mp4, mimeType: nil) == .progressive)
        #expect(MediaDetector.classify(url: ts, mimeType: nil) == .segment)
    }

    @Test func preferredVariantIsHighestBandwidth() throws {
        let candidateURL = try #require(URL(string: "https://cdn.example.com/video/master.m3u8"))
        let candidate = NetworkMediaCandidate(url: candidateURL, source: .manual)
        let text = try fixture("hls/master.m3u8")
        let playlist = try HLSParser.parse(text: text, playlistURL: candidateURL)
        let media = MediaDetector.makeHLS(from: candidate, playlist: playlist, title: "Demo")

        #expect(media.kind == .hls)
        #expect(media.variants.count == 3)
        #expect(media.preferredVariant?.bandwidth == 2_800_000)
        #expect(media.preferredVariant?.displayLabel.contains("1920") == true)
        #expect(media.displayTitle == "Demo")
    }

    @Test func makeProgressiveSetsSingleVariant() throws {
        let url = try #require(URL(string: "https://cdn.example.com/a.mp4"))
        let candidate = NetworkMediaCandidate(url: url, source: .manual)
        let media = MediaDetector.makeProgressive(from: candidate, contentLength: 1_024_000)
        #expect(media.kind == .progressive)
        #expect(media.variants.count == 1)
        #expect(media.contentLength == 1_024_000)
        #expect(media.protection == .none)
    }
}