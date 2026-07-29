import Foundation
import WebKit

/// Synchronise les cookies WKWebView vers un snapshot utilisable par URLSession (Phase 3).
@MainActor
final class CookieBridge {
    private weak var webView: WKWebView?
    private(set) var lastSnapshot: SessionCredentialSnapshot = .empty

    func attach(to webView: WKWebView) {
        self.webView = webView
        AppLog.session.info("CookieBridge attached")
    }

    func refreshSnapshot() async {
        guard let webView else {
            lastSnapshot = .empty
            return
        }

        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }

        lastSnapshot = SessionCredentialSnapshot(cookies: cookies)
        AppLog.session.debug("Cookie snapshot count=\(cookies.count, privacy: .public)")
    }
}

struct SessionCredentialSnapshot: Sendable {
    let cookies: [HTTPCookie]

    static let empty = SessionCredentialSnapshot(cookies: [])

    func cookieHeader(for url: URL) -> String? {
        let relevant = cookies.filter { cookie in
            cookieMatches(cookie, url: url)
        }
        guard !relevant.isEmpty else { return nil }
        return relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private func cookieMatches(_ cookie: HTTPCookie, url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let hostOK = host == domain || host.hasSuffix("." + domain) || host.hasSuffix(cookie.domain.lowercased())
        guard hostOK else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        return path.hasPrefix(cookie.path)
    }
}
