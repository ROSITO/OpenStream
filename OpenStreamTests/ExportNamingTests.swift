import Foundation
import Testing
@testable import OpenStream

struct ExportNamingTests {
    @Test func filmPath() {
        let path = ExportNaming.relativePath(
            template: ExportNamingPreset.jellyfinMovie.template,
            context: ExportNamingContext(title: "Inception", year: "2010")
        )
        #expect(path == "Inception (2010)/Inception.mp4")
    }

    @Test func omitsEmptyYearParentheses() {
        let path = ExportNaming.relativePath(
            template: ExportNamingPreset.jellyfinMovie.template,
            context: ExportNamingContext(title: "Untitled Film", year: nil)
        )
        #expect(path == "Untitled Film/Untitled Film.mp4")
    }

    @Test func seriesPathPadsSeasonEpisode() {
        let path = ExportNaming.relativePath(
            template: ExportNamingPreset.jellyfinSeries.template,
            context: ExportNamingContext(
                title: "Pilot",
                show: "Breaking Bad",
                season: "1",
                episode: "7"
            )
        )
        #expect(path == "Breaking Bad/Saison 01/S01E07.mp4")
    }

    @Test func parsesTitleAndYear() {
        let a = ExportNaming.parseTitleAndYear(from: "Inception (2010) - Watch Online")
        #expect(a.title == "Inception")
        #expect(a.year == "2010")

        let b = ExportNaming.parseTitleAndYear(from: "Dune 2021")
        #expect(b.title == "Dune")
        #expect(b.year == "2021")
    }

    @Test func resolveURLCreatesNestedFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OSNaming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = ExportNaming.resolveURL(
            root: root,
            template: ExportNamingPreset.jellyfinMovie.template,
            context: ExportNamingContext(title: "Heat", year: "1995")
        )
        #expect(url.lastPathComponent == "Heat.mp4")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Heat (1995)")
        #expect(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }
}
