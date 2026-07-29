import Foundation

enum MediaURLHeuristics {
    private static let mediaExtensions: Set<String> = [
        "m3u8", "mpd", "mp4", "m4v", "m4s", "ts", "webm", "mov"
    ]

    private static let mediaPathTokens = ["m3u8", "mpd", ".mp4", "manifest", "playlist"]

    static func looksLikeMedia(_ url: URL, mimeType: String?) -> Bool {
        if looksLikeMediaCore(url, mimeType: mimeType) {
            return true
        }
        return PluginManager.shared.shouldAcceptMediaURL(url, mimeType: mimeType)
    }

    /// Heuristiques core uniquement (sans plugins) — utile pour tests / debug.
    static func looksLikeMediaCore(_ url: URL, mimeType: String?) -> Bool {
        if let mimeType, mimeLooksLikeMedia(mimeType) {
            return true
        }

        let ext = url.pathExtension.lowercased()
        if mediaExtensions.contains(ext) {
            return true
        }

        let haystack = url.absoluteString.lowercased()
        return mediaPathTokens.contains { haystack.contains($0) }
    }

    static func mimeLooksLikeMedia(_ mime: String) -> Bool {
        let m = mime.lowercased()
        if m.hasPrefix("video/") { return true }
        if m.contains("mpegurl") { return true }
        if m.contains("dash+xml") { return true }
        if m.contains("application/vnd.apple.mpegurl") { return true }
        if m.contains("application/mp4") { return true }
        return false
    }
}
