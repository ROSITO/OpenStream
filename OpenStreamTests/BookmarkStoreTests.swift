import Foundation
import Testing
@testable import OpenStream

@MainActor
struct BookmarkStoreTests {
    @Test func addTogglePersistAndDedupe() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenStreamBookmarks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = BookmarkStore(directory: dir)
        let url = try #require(URL(string: "https://videos.example.com/watch?v=1#frag"))

        let added = try store.add(title: "Demo", url: url)
        #expect(store.bookmarks.count == 1)
        #expect(added.url.absoluteString == "https://videos.example.com/watch?v=1")
        #expect(store.isBookmarked(url))

        // Dedupe (fragment ignored)
        _ = try store.add(title: "Other", url: url)
        #expect(store.bookmarks.count == 1)

        let reloaded = BookmarkStore(directory: dir)
        #expect(reloaded.bookmarks.count == 1)
        #expect(reloaded.bookmarks[0].title == "Demo")

        let removed = try reloaded.toggle(title: "Demo", url: url)
        #expect(removed == false)
        #expect(reloaded.bookmarks.isEmpty)

        let again = BookmarkStore(directory: dir)
        #expect(again.bookmarks.isEmpty)
    }

    @Test func renameAndVisitReorder() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenStreamBookmarks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = BookmarkStore(directory: dir)
        let a = try store.add(title: "A", url: try #require(URL(string: "https://a.example/")))
        let b = try store.add(title: "B", url: try #require(URL(string: "https://b.example/")))
        #expect(store.bookmarks.map(\.title) == ["B", "A"])

        try store.rename(id: a.id, title: "Alpha")
        try store.markVisited(id: a.id)
        #expect(store.bookmarks.first?.id == a.id)
        #expect(store.bookmarks.first?.title == "Alpha")
        #expect(store.bookmarks.first?.lastVisitedAt != nil)
        #expect(b.id != a.id)
    }
}
