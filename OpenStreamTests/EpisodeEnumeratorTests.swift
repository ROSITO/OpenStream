import Foundation
import Testing
@testable import OpenStream

struct EpisodeEnumeratorTests {
    @Test func parsesMovixWatchPathWithEpisode() throws {
        let url = try #require(URL(string: "https://movix.luxe/watch/tv/1668/s/1/e/4"))
        let match = try #require(EpisodeEnumerator.parseWatchPath(url))
        #expect(match.showId == "1668")
        #expect(match.season == 1)
        #expect(match.episode == 4)
    }

    @Test func parsesMovixWatchPathSeasonOnly() throws {
        let url = try #require(URL(string: "https://movix.luxe/watch/tv/1668/s/2"))
        let match = try #require(EpisodeEnumerator.parseWatchPath(url))
        #expect(match.showId == "1668")
        #expect(match.season == 2)
        #expect(match.episode == nil)
    }

    @Test func buildsEpisodeURL() throws {
        let base = try #require(URL(string: "https://movix.luxe/watch/tv/1668/s/1/e/4?x=1"))
        let ep = try #require(EpisodeEnumerator.episodeURL(from: base, season: 1, episode: 7))
        #expect(ep.path == "/watch/tv/1668/s/1/e/7")
        #expect(ep.query == nil)
    }

    @Test func expandsCandidates() throws {
        let base = try #require(URL(string: "https://movix.luxe/watch/tv/1668/s/1/e/1"))
        let refs = EpisodeEnumerator.expandWatchCandidates(
            pageURL: base,
            season: 1,
            show: "Friends",
            maxEpisodes: 3
        )
        #expect(refs.count == 3)
        #expect(refs[0].displayTitle == "Friends S01E01")
        #expect(refs[2].episode == 3)
        #expect(refs[2].url.path.hasSuffix("/e/3"))
    }

    @Test func parsesDOMLinksFromHrefAndText() throws {
        let base = try #require(URL(string: "https://example.com/show/friends"))
        let refs = EpisodeEnumerator.parseDOMLinks(
            baseURL: base,
            links: [
                (href: "https://example.com/watch/tv/1/s/1/e/2", text: "Episode 2"),
                (href: "https://example.com/foo", text: "Home"),
                (href: "/watch/tv/1/s/1/e/1", text: "S01E01 Pilot"),
                (href: "https://other.com/e/9", text: "Episode 9")
            ],
            defaultSeason: 1,
            showHint: "Friends"
        )
        #expect(refs.map(\.episode) == [1, 2])
        #expect(refs[0].displayTitle == "Friends S01E01")
        #expect(refs[1].url.path.hasSuffix("/e/2"))
    }

    @Test func extractorsReadSxxExx() {
        let url = URL(string: "https://example.com/x")!
        #expect(EpisodeEnumerator.extractEpisode(from: url, text: "Friends S01E12") == 12)
        #expect(EpisodeEnumerator.extractSeason(from: url, text: "Saison 3") == 3)
        #expect(EpisodeEnumerator.extractEpisode(from: url, text: "épisode 5") == 5)
    }

    @Test func mergePrefersWatchPath() throws {
        let a = EpisodeRef(
            url: try #require(URL(string: "https://example.com/ep/1")),
            show: "X",
            season: 1,
            episode: 1,
            title: nil
        )
        let b = EpisodeRef(
            url: try #require(URL(string: "https://example.com/watch/tv/1/s/1/e/1")),
            show: "X",
            season: 1,
            episode: 1,
            title: nil
        )
        let merged = EpisodeEnumerator.merge([b], [a])
        #expect(merged.count == 1)
        #expect(merged[0].url.path.contains("/e/1"))
    }

    @Test func extractsNewsID() throws {
        let url = try #require(URL(string: "https://fs26.lol/index.php?newsid=15112864"))
        #expect(EpisodeEnumerator.extractNewsID(from: url) == "15112864")
    }

    @Test func parsesFrenchStreamCatalog() throws {
        let json = """
        {"vf":{"1":{"vidzy":"https://vidzy.cc/embed-a.html","uqload":"https://uqload.vc/x"},"2":{"premium":"https://fsvid.lol/embed-b.html"}},"vostfr":{}}
        """.data(using: .utf8)!
        let refs = EpisodeEnumerator.parseFrenchStreamCatalog(
            data: json,
            season: 1,
            show: "Tulsa King",
            preferredVersion: "vf"
        )
        #expect(refs.map(\.episode) == [1, 2])
        #expect(refs[0].displayTitle == "Tulsa King S01E01")
        #expect(refs[0].url.host() == "vidzy.cc")
        #expect(refs[1].url.host() == "fsvid.lol") // premium seul sur ep2
    }
}
