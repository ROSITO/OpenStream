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

    @Test func rejectsOpaqueCDNToken() {
        #expect(PageTitleResolver.usefulTitle("92mW6Kt5veFvcyfNnNfXlq70N3z8DgtZ3Pf") == nil)
        #expect(PageTitleResolver.usefulTitle("a1b2c3d4e5f6789012345678abcdef") == nil)
    }

    @Test func prefersPageTitleOverOpaqueMediaName() throws {
        let page = try #require(URL(string: "https://rizmov.com/83ab188/b/rizmov/12161298"))
        let media = try #require(
            URL(string: "https://cdn.example.com/files/aa/92mW6Kt5veFvcyfNnNfXlq70N3z8DgtZ3Pf.m3u8")
        )
        let title = PageTitleResolver.title(
            pageTitle: "Rizmov - Masterplan (2026)",
            pageURL: page,
            mediaURL: media
        )
        #expect(title == "Masterplan (2026)")
    }
}
