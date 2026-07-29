import Foundation
import Testing
@testable import OpenStream

struct PluginManagerTests {
    @Test func examplePluginAcceptsHintURLIgnoredByCore() throws {
        PluginManager.shared.resetForTests()
        defer { PluginManager.shared.resetForTests() }

        try PluginManager.shared.register(ExampleMediaHintPlugin())

        let plain = try #require(URL(string: "https://cdn.example.com/asset.bin"))
        #expect(MediaURLHeuristics.looksLikeMediaCore(plain, mimeType: nil) == false)
        #expect(MediaURLHeuristics.looksLikeMedia(plain, mimeType: nil) == false)

        let hinted = try #require(URL(string: "https://cdn.example.com/asset.bin#openstream-media"))
        #expect(MediaURLHeuristics.looksLikeMediaCore(hinted, mimeType: nil) == false)
        #expect(MediaURLHeuristics.looksLikeMedia(hinted, mimeType: nil) == true)

        let pathHint = try #require(URL(string: "https://cdn.example.com/__openstream_media__/clip.bin"))
        #expect(MediaURLHeuristics.looksLikeMedia(pathHint, mimeType: nil) == true)
    }

    @Test func rejectsIncompatibleAPIVersion() {
        PluginManager.shared.resetForTests()
        defer { PluginManager.shared.resetForTests() }

        struct BadPlugin: OpenStreamPlugin {
            let id = "bad"
            let name = "Bad"
            let version = "0"
            let apiVersion = 999
        }

        do {
            try PluginManager.shared.register(BadPlugin())
            Issue.record("Expected incompatible API to throw")
        } catch let error as PluginValidationError {
            if case .incompatibleAPI = error {
                // ok
            } else {
                Issue.record("Unexpected PluginValidationError: \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func validatesBundleInfoPlist() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OSPlugin-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = dir.appendingPathComponent("Demo.openstreamplugin", isDirectory: true)
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let info: [String: Any] = [
            "CFBundleIdentifier": "app.openstream.plugin.demo",
            "OpenStreamPluginAPIVersion": OpenStreamPluginAPI.version,
            "CFBundleName": "Demo"
        ]
        let infoURL = contents.appendingPathComponent("Info.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: infoURL)

        try PluginManager.shared.validateBundle(at: bundleURL)
        let loaded = PluginManager.shared.loadBundles(from: dir)
        #expect(loaded.contains("Demo.openstreamplugin"))
    }
}
