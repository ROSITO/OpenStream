import Foundation

/// Persistance Flix : seen + dernier digest (`Application Support/OpenStream/`).
enum FlixStore {
    static func seenURL(supportRoot: URL) -> URL {
        supportRoot.appendingPathComponent("flix_seen.json")
    }

    static func digestURL(supportRoot: URL) -> URL {
        supportRoot.appendingPathComponent("flix_last_digest.json")
    }

    static func loadSeen(supportRoot: URL) -> Set<String> {
        let file = seenURL(supportRoot: supportRoot)
        guard let data = try? Data(contentsOf: file),
              let arr = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(arr)
    }

    static func saveSeen(_ ids: Set<String>, supportRoot: URL) throws {
        try FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        let sorted = ids.sorted()
        let data = try JSONEncoder().encode(sorted)
        try data.write(to: seenURL(supportRoot: supportRoot), options: [.atomic])
    }

    static func markSeen(_ ids: [String], supportRoot: URL) throws {
        var set = loadSeen(supportRoot: supportRoot)
        for id in ids { set.insert(id) }
        try saveSeen(set, supportRoot: supportRoot)
    }

    static func clearSeen(supportRoot: URL) throws {
        let file = seenURL(supportRoot: supportRoot)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    static func loadDigest(supportRoot: URL) -> FlixDigest? {
        let file = digestURL(supportRoot: supportRoot)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(FlixDigest.self, from: data)
    }

    static func saveDigest(_ digest: FlixDigest, supportRoot: URL) throws {
        try FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(digest)
        try data.write(to: digestURL(supportRoot: supportRoot), options: [.atomic])
    }
}
