import Foundation
import Testing
@testable import OpenStream

struct SeasonResolverTests {
    @Test func matchBookmarkPrefersExplicitSeasonTitle() throws {
        let bookmarks = [
            SeasonResolver.BookmarkEntry(
                title: "French Stream",
                url: try #require(URL(string: "https://fs26.lol/"))
            ),
            SeasonResolver.BookmarkEntry(
                title: "Tulsa King - Saison 1",
                url: try #require(URL(string: "https://fs26.lol/index.php?newsid=15112864"))
            ),
            SeasonResolver.BookmarkEntry(
                title: "Tulsa King - Saison 2",
                url: try #require(URL(string: "https://fs26.lol/index.php?newsid=999"))
            )
        ]
        let hit = try #require(
            SeasonResolver.matchBookmark(show: "Tulsa King", season: 1, bookmarks: bookmarks)
        )
        #expect(hit.pageURL.absoluteString.contains("15112864"))
        #expect(hit.source == "bookmark")
        #expect(hit.season == 1)
    }

    @Test func searchRootsSkipsNewsIDPages() throws {
        let bookmarks = [
            SeasonResolver.BookmarkEntry(
                title: "FS",
                url: try #require(URL(string: "https://fs26.lol/"))
            ),
            SeasonResolver.BookmarkEntry(
                title: "Tulsa King - Saison 1",
                url: try #require(URL(string: "https://fs26.lol/index.php?newsid=1"))
            ),
            SeasonResolver.BookmarkEntry(
                title: "DLE",
                url: try #require(URL(string: "https://dle.example/"))
            )
        ]
        let roots = SeasonResolver.searchRoots(from: bookmarks)
        let hosts = Set(roots.compactMap(\.host))
        #expect(hosts == ["fs26.lol", "dle.example"])
    }

    @Test func parseSearchHTMLPicksMatchingSeason() throws {
        let base = try #require(URL(string: "https://fs26.lol/"))
        let html = """
        <a href="index.php?newsid=111">Other Show - Saison 1</a>
        <a href="index.php?newsid=15112864">Tulsa King - Saison 1</a>
        <a href="index.php?newsid=222">Tulsa King - Saison 2</a>
        """
        let hit = try #require(
            SeasonResolver.parseSearchHTML(html, baseURL: base, show: "Tulsa King", season: 1)
        )
        #expect(hit.pageURL.absoluteString.contains("newsid=15112864"))
        #expect(hit.source == "search:fs26.lol")
    }

    @Test func normalizeFoldsDiacritics() {
        #expect(SeasonResolver.normalize("Saison") == "saison")
        #expect(SeasonResolver.normalize("Été  ") == "ete")
    }
}
