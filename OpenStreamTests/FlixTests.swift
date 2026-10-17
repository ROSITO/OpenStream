import Foundation
import Testing
@testable import OpenStream

struct FlixTests {
    @Test func parsesSeasonTitle() {
        let p = FlixTitleParser.parse("Tulsa King - Saison 4")
        #expect(p.mode == .season)
        #expect(p.show == "Tulsa King")
        #expect(p.season == 4)
        #expect(p.display == "Tulsa King — S4")
    }

    @Test func parsesFilmAsFetch() {
        let p = FlixTitleParser.parse("Some Movie (2024)")
        #expect(p.mode == .fetch)
        #expect(p.season == nil)
    }

    @Test func normalizesRSSLinkHostToHub() throws {
        let hub = try #require(URL(string: "https://fs26.lol/"))
        let url = try #require(
            FlixRSS.normalizeLink("https://fs20.lol/index.php?newsid=15140996", hubOrigin: hub)
        )
        #expect(url.host() == "fs26.lol")
        #expect(url.absoluteString.contains("newsid=15140996"))
    }

    @Test func parseRSSStripsBOMAndReadsItems() {
        let bom = "\u{FEFF}"
        let xml = bom + """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel>
          <item>
            <title>Tulsa King - Saison 4</title>
            <link>https://fs20.lol/index.php?newsid=1</link>
            <guid>https://fs20.lol/index.php?newsid=1</guid>
            <pubDate>Sat, 17 Oct 2026 03:17:57 +0200</pubDate>
          </item>
          <item>
            <title>Other Show - Saison 1</title>
            <link>https://fs20.lol/index.php?newsid=2</link>
            <guid>https://fs20.lol/index.php?newsid=2</guid>
            <pubDate>Fri, 16 Oct 2026 01:00:00 +0200</pubDate>
          </item>
        </channel></rss>
        """
        let data = Data(xml.utf8)
        let text = FlixRSS.decodeRSSText(data)
        #expect(!text.hasPrefix("\u{FEFF}"))
        let entries = FlixRSS.parseRSS(text)
        #expect(entries.count == 2)
        #expect(entries[0].title == "Tulsa King - Saison 4")
    }

    @Test func hubsSkipNewsIDPages() throws {
        let bookmarks = [
            SeasonResolver.BookmarkEntry(
                title: "FS26",
                url: try #require(URL(string: "https://fs26.lol/"))
            ),
            SeasonResolver.BookmarkEntry(
                title: "Tulsa King - Saison 1",
                url: try #require(URL(string: "https://fs26.lol/index.php?newsid=1"))
            )
        ]
        let hubs = FlixRSS.hubs(from: bookmarks)
        #expect(hubs.count == 1)
        #expect(hubs[0].title == "FS26")
    }

    @Test func pickSpecParses() throws {
        #expect(try FlixService.parsePickSpec("1,3") == [1, 3])
        #expect(try FlixService.parsePickSpec("2") == [2])
    }

    @Test func seenRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flix-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FlixStore.markSeen(["a", "b"], supportRoot: dir)
        #expect(FlixStore.loadSeen(supportRoot: dir) == Set(["a", "b"]))
        try FlixStore.clearSeen(supportRoot: dir)
        #expect(FlixStore.loadSeen(supportRoot: dir).isEmpty)
    }
}
