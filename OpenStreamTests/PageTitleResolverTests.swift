import Foundation
import Testing
@testable import OpenStream

struct PageTitleResolverTests {
    @Test func rejectsAppName() {
        #expect(PageTitleResolver.usefulTitle("OpenStream") == nil)
        #expect(PageTitleResolver.usefulTitle("openstream") == nil)
        #expect(PageTitleResolver.usefulTitle("") == nil)
        #expect(PageTitleResolver.usefulTitle("about:blank") == nil)
    }

    @Test func rejectsSiteBrandAlone() {
        #expect(PageTitleResolver.usefulTitle("Voiranime", host: "voiranime.com") == nil)
        #expect(PageTitleResolver.looksLikeSiteBrand("Voiranime", host: "www.voiranime.com"))
    }

    @Test func prefersContentSideOfDecoratedTitle() {
        let host = "voiranime.com"
        #expect(PageTitleResolver.usefulTitle("Demon Slayer | Voiranime", host: host) == "Demon Slayer")
        #expect(PageTitleResolver.usefulTitle("Voiranime - Demon Slayer", host: host) == "Demon Slayer")
    }

    @Test func ranksOgAboveDocumentSiteTitle() throws {
        let page = try #require(URL(string: "https://stream.example.com/watch/x"))
        let media = try #require(URL(string: "https://cdn.example.com/a.m3u8"))
        let title = PageTitleResolver.title(
            candidates: [
                .init(text: "StreamExample", source: "document"),
                .init(text: "Demon Slayer: Kimetsu no Yaiba", source: "og")
            ],
            pageTitle: "StreamExample",
            pageURL: page,
            mediaURL: media
        )
        #expect(title.contains("Demon Slayer"))
    }

    @Test func fallsBackFromURLWhenPageTitleJunk() throws {
        let page = try #require(URL(string: "https://cdn.example.com/watch/demon-slayer-movie"))
        let media = try #require(URL(string: "https://cdn.example.com/hls/index.m3u8"))
        let title = PageTitleResolver.title(pageTitle: "OpenStream", pageURL: page, mediaURL: media)
        #expect(title.lowercased().contains("demon"))
    }
}
