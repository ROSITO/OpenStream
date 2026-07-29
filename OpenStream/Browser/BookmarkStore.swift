import Foundation
import Observation

struct SiteBookmark: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var url: URL
    var createdAt: Date
    var lastVisitedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        url: URL,
        createdAt: Date = Date(),
        lastVisitedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.createdAt = createdAt
        self.lastVisitedAt = lastVisitedAt
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return url.host() ?? url.absoluteString
    }

    var hostLabel: String {
        url.host() ?? url.absoluteString
    }
}

enum BookmarkStoreError: Error, LocalizedError, Sendable {
    case invalidURL
    case message(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "URL invalide pour un favori"
        case .message(let text): return text
        }
    }
}

/// Favoris de sites (pages utiles pour télécharger) — JSON dans Application Support.
@MainActor
@Observable
final class BookmarkStore {
    private(set) var bookmarks: [SiteBookmark] = []

    private let fileURL: URL
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OpenStream", isDirectory: true)
        fileURL = base.appendingPathComponent("bookmarks.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        load()
    }

    func bookmark(matching url: URL) -> SiteBookmark? {
        let key = Self.normalizedKey(for: url)
        return bookmarks.first { Self.normalizedKey(for: $0.url) == key }
    }

    func isBookmarked(_ url: URL) -> Bool {
        bookmark(matching: url) != nil
    }

    @discardableResult
    func add(title: String, url: URL) throws -> SiteBookmark {
        guard url.scheme == "http" || url.scheme == "https" else {
            throw BookmarkStoreError.invalidURL
        }
        if let existing = bookmark(matching: url) {
            return existing
        }
        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (url.host() ?? url.absoluteString)
            : title.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = SiteBookmark(title: resolvedTitle, url: Self.canonicalURL(url))
        bookmarks.insert(item, at: 0)
        try persist()
        AppLog.app.info("Bookmark added \(item.url.host() ?? "", privacy: .public)")
        return item
    }

    func remove(id: UUID) throws {
        bookmarks.removeAll { $0.id == id }
        try persist()
    }

    func remove(url: URL) throws {
        let key = Self.normalizedKey(for: url)
        bookmarks.removeAll { Self.normalizedKey(for: $0.url) == key }
        try persist()
    }

    @discardableResult
    func toggle(title: String, url: URL) throws -> Bool {
        if let existing = bookmark(matching: url) {
            try remove(id: existing.id)
            return false
        }
        _ = try add(title: title, url: url)
        return true
    }

    func rename(id: UUID, title: String) throws {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        bookmarks[index].title = trimmed
        try persist()
    }

    func markVisited(id: UUID) throws {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[index].lastVisitedAt = Date()
        let item = bookmarks.remove(at: index)
        bookmarks.insert(item, at: 0)
        try persist()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            bookmarks = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            bookmarks = try decoder.decode([SiteBookmark].self, from: data)
        } catch {
            AppLog.app.error("Bookmark load failed: \(error.localizedDescription, privacy: .public)")
            bookmarks = []
        }
    }

    private func persist() throws {
        let data = try encoder.encode(bookmarks)
        try data.write(to: fileURL, options: [.atomic])
    }

    static func canonicalURL(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url ?? url
    }

    static func normalizedKey(for url: URL) -> String {
        canonicalURL(url).absoluteString.lowercased()
    }
}
