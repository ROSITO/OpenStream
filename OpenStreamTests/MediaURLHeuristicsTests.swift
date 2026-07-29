import Foundation
import Testing
@testable import OpenStream

struct MediaURLHeuristicsTests {
    @Test func detectsHLSExtension() throws {
        let url = try #require(URL(string: "https://cdn.example.com/video/master.m3u8"))
        #expect(MediaURLHeuristics.looksLikeMedia(url, mimeType: nil))
    }

    @Test func detectsMP4Extension() throws {
        let url = try #require(URL(string: "https://cdn.example.com/film.mp4"))
        #expect(MediaURLHeuristics.looksLikeMedia(url, mimeType: nil))
    }

    @Test func detectsMimeMpegURL() throws {
        let url = try #require(URL(string: "https://cdn.example.com/playlist"))
        #expect(MediaURLHeuristics.looksLikeMedia(url, mimeType: "application/vnd.apple.mpegurl"))
    }

    @Test func rejectsPlainHTML() throws {
        let url = try #require(URL(string: "https://example.com/index.html"))
        #expect(!MediaURLHeuristics.looksLikeMedia(url, mimeType: "text/html"))
    }
}
