import Foundation
import Testing
@testable import OpenStream

enum TestFixtures {
    /// Charge une fixture depuis le bundle de tests (`Fixtures/…`, sandbox-safe).
    static func load(_ relativePath: String) throws -> String {
        let resourceName = ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let ext = (relativePath as NSString).pathExtension
        let parent = (relativePath as NSString).deletingLastPathComponent
        let bundle = Bundle(for: BundleToken.self)

        let subdirs: [String?] = [
            parent.isEmpty ? "Fixtures" : "Fixtures/\(parent)",
            parent.isEmpty ? nil : parent,
            "Fixtures"
        ]

        for subdirectory in subdirs {
            if let url = bundle.url(forResource: resourceName, withExtension: ext, subdirectory: subdirectory) {
                return try String(contentsOf: url, encoding: .utf8)
            }
        }

        // Fallback : dossier Fixtures entier copié tel quel
        if let root = bundle.resourceURL?
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(relativePath),
           FileManager.default.fileExists(atPath: root.path)
        {
            return try String(contentsOf: root, encoding: .utf8)
        }

        Issue.record("Fixture introuvable dans le bundle: \(relativePath)")
        throw URLError(.fileDoesNotExist)
    }
}

func fixture(_ relativePath: String) throws -> String {
    try TestFixtures.load(relativePath)
}

private final class BundleToken {}
