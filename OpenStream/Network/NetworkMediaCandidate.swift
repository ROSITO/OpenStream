import Foundation

struct NetworkMediaCandidate: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let mimeType: String?
    let source: Source
    let observedAt: Date
    let pageURL: URL?

    enum Source: String, Sendable, Hashable {
        case navigation
        case resourceTiming
        case fetchHook
        case xhrHook
        case mediaElement
        case manual
    }

    init(
        id: UUID = UUID(),
        url: URL,
        mimeType: String? = nil,
        source: Source,
        observedAt: Date = Date(),
        pageURL: URL? = nil
    ) {
        self.id = id
        self.url = url
        self.mimeType = mimeType
        self.source = source
        self.observedAt = observedAt
        self.pageURL = pageURL
    }

    var displayHost: String {
        url.host() ?? url.absoluteString
    }

    var pathExtensionHint: String {
        url.pathExtension.lowercased()
    }
}
