import Foundation
import Testing
@testable import OpenStream

@MainActor
struct DownloadHistoryStoreTests {
    @Test func recordsCompletedAndFilters() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OSHistory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = DownloadHistoryStore(directory: dir)
        let job = DownloadJob(
            title: "Film Test",
            kind: .hls,
            sourceURL: try #require(URL(string: "https://cdn.example.com/master.m3u8")),
            variantURL: try #require(URL(string: "https://cdn.example.com/1080.m3u8")),
            state: .completed(directoryURL: dir),
            destinationDirectory: dir,
            exportURL: dir.appendingPathComponent("Film Test.mp4")
        )
        store.record(from: job)
        #expect(store.records.count == 1)
        #expect(store.filtered(query: "film").count == 1)
        #expect(store.filtered(query: "zzz").isEmpty)

        let media = try #require(store.records.first).asDetectedMedia()
        #expect(media.kind == .hls)
        #expect(media.sourceURL.absoluteString.contains("master.m3u8"))

        let reloaded = DownloadHistoryStore(directory: dir)
        #expect(reloaded.records.count == 1)
    }
}

struct BatchURLParserTests {
    @Test func parsesAndPartitionsURLs() throws {
        let text = """
        https://cdn.example.com/a.m3u8
        https://site.example.com/watch
        https://cdn.example.com/b.mp4
        not-a-url
        https://cdn.example.com/a.m3u8
        """
        let urls = BatchURLParser.parse(text)
        #expect(urls.count == 3)
        let parts = BatchURLParser.partition(urls)
        #expect(parts.media.count == 2)
        #expect(parts.pages.count == 1)
    }
}

struct AutomationRulesTests {
    @Test func matchesKinds() {
        var rules = AutomationRules(autoEnqueueHLS: true, autoEnqueueDASH: false, autoEnqueueProgressive: true)
        #expect(rules.isEnabled)
        #expect(rules.shouldAutoEnqueue(.hls))
        #expect(!rules.shouldAutoEnqueue(.dash))
        #expect(rules.shouldAutoEnqueue(.progressive))
    }
}

struct LocalCommandCodecTests {
    @Test func roundTripsJSON() throws {
        let command = LocalCommand(
            kind: .download,
            url: try #require(URL(string: "https://cdn.example.com/x.m3u8"))
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(command)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LocalCommand.self, from: data)
        #expect(decoded.kind == .download)
        #expect(decoded.url?.absoluteString.hasSuffix("x.m3u8") == true)
    }
}
