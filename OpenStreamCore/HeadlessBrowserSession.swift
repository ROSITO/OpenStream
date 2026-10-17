import AppKit
import Foundation
import WebKit

/// Session WKWebView offscreen pour détecter des flux média (Phase B agent).
@MainActor
final class HeadlessBrowserSession: NSObject {
    private let webView: WKWebView
    private let observer = NetworkObserver()
    private let catalog: MediaCatalog
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    private var pageURL: URL?
    private var pageTitle: String?

    override init() {
        HeadlessAppKit.prepare()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720), configuration: config)
        self.webView = wv
        self.catalog = MediaCatalog(session: .shared, cookieBridge: nil)
        super.init()
        wv.navigationDelegate = self
        observer.attachScriptMessaging(to: wv)
        observer.onCandidateAccepted = { [weak self] candidate in
            Task { @MainActor in
                guard let self else { return }
                self.catalog.ingest(candidate, pageTitle: self.resolvedPageTitle())
            }
        }
    }

    /// Charge une page et attend jusqu’à `timeout` pour collecter des détections.
    func fetch(pageURL: URL, timeout: TimeInterval) async throws -> [DetectedMedia] {
        catalog.clear()
        self.pageURL = pageURL
        pageTitle = nil

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            navigationContinuation = cont
            webView.load(URLRequest(url: pageURL))
            // WebKit a besoin que le runloop tourne pendant le chargement.
            HeadlessAppKit.schedulePump()
        }

        capturePageTitle()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            capturePageTitle()
            if let title = resolvedPageTitle() {
                catalog.refreshSuggestedTitles(using: title)
            }
            if !catalog.detected.isEmpty { break }
            HeadlessAppKit.pumpOnce()
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // Laisser l’enrichissement async finir + retitrer une dernière fois.
        for _ in 0..<10 {
            capturePageTitle()
            if let title = resolvedPageTitle() {
                catalog.refreshSuggestedTitles(using: title)
            }
            if catalog.processingURLs.isEmpty, !catalog.detected.isEmpty { break }
            HeadlessAppKit.pumpOnce()
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        if !catalog.detected.isEmpty {
            return catalog.detected
        }

        let hint = resolvedPageTitle()
        return observer.candidates.compactMap { candidate -> DetectedMedia? in
            let classification = MediaDetector.classify(url: candidate.url, mimeType: candidate.mimeType)
            let variant = MediaVariant(playlistURL: candidate.url)
            let title = PageTitleResolver.title(
                pageTitle: hint,
                pageURL: pageURL,
                mediaURL: candidate.url
            )
            switch classification {
            case .hls:
                return DetectedMedia(
                    sourceURL: candidate.url,
                    kind: .hls,
                    suggestedTitle: title,
                    pageURL: pageURL,
                    variants: [variant],
                    preferredVariantID: variant.id,
                    isVOD: true
                )
            case .dash:
                return DetectedMedia(
                    sourceURL: candidate.url,
                    kind: .dash,
                    suggestedTitle: title,
                    pageURL: pageURL,
                    variants: [variant],
                    preferredVariantID: variant.id,
                    isVOD: true
                )
            case .progressive:
                return MediaDetector.makeProgressive(from: candidate, title: title)
            case .segment, .unknown:
                return nil
            }
        }
    }

    /// Charge une page et extrait les liens épisode (DOM).
    func listEpisodeLinks(
        pageURL: URL,
        defaultSeason: Int?,
        showHint: String?,
        timeout: TimeInterval
    ) async throws -> [EpisodeRef] {
        self.pageURL = pageURL
        pageTitle = nil

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            navigationContinuation = cont
            webView.load(URLRequest(url: pageURL))
            HeadlessAppKit.schedulePump()
        }

        let deadline = Date().addingTimeInterval(min(timeout, 30))
        var lastParsed: [EpisodeRef] = []
        while Date() < deadline {
            capturePageTitle()
            HeadlessAppKit.pumpOnce()
            try await Task.sleep(nanoseconds: 100_000_000)
            guard let links = try? await extractEpisodeLinkRows(), !links.isEmpty else { continue }
            let show = showHint ?? resolvedPageTitle()
            let parsed = EpisodeEnumerator.parseDOMLinks(
                baseURL: webView.url ?? pageURL,
                links: links,
                defaultSeason: defaultSeason,
                showHint: show
            )
            if !parsed.isEmpty {
                return parsed
            }
            lastParsed = parsed
        }

        capturePageTitle()
        if lastParsed.isEmpty,
           let links = try? await extractEpisodeLinkRows(),
           !links.isEmpty {
            let show = showHint ?? resolvedPageTitle()
            return EpisodeEnumerator.parseDOMLinks(
                baseURL: webView.url ?? pageURL,
                links: links,
                defaultSeason: defaultSeason,
                showHint: show
            )
        }
        return lastParsed
    }

    private func extractEpisodeLinkRows() async throws -> [(href: String, text: String)] {
        let js = Self.episodeLinkExtractionJS
        let result = try await webView.evaluateJavaScript(js)
        guard let dict = result as? [String: Any],
              let rows = dict["links"] as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let href = row["href"] as? String else { return nil }
            let text = (row["text"] as? String) ?? ""
            return (href: href, text: text)
        }
    }

    private static let episodeLinkExtractionJS: String = #"""
    (function () {
      var out = [];
      var seen = {};
      document.querySelectorAll('a[href]').forEach(function (a) {
        var href = a.href || '';
        if (!href || href.indexOf('javascript:') === 0 || href === '#') return;
        if (seen[href]) return;
        seen[href] = true;
        var text = (a.textContent || '').replace(/\s+/g, ' ').trim();
        out.push({ href: href, text: text.slice(0, 160) });
      });
      return { links: out, title: document.title || '' };
    })();
    """#

    private func capturePageTitle() {
        if let raw = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            pageTitle = raw
        }
    }

    private func resolvedPageTitle() -> String? {
        PageTitleResolver.usefulTitle(pageTitle, host: pageURL?.host() ?? webView.url?.host())
            ?? pageTitle
    }
}

extension HeadlessBrowserSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        capturePageTitle()
        if let title = resolvedPageTitle() {
            catalog.refreshSuggestedTitles(using: title)
        }
        navigationContinuation?.resume()
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }
}

/// Runloop AppKit minimal pour WKWebView en CLI (pas de fenêtre visible).
enum HeadlessAppKit {
    @MainActor
    private static var prepared = false

    @MainActor
    static func prepare() {
        guard !prepared else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        prepared = true
    }

    @MainActor
    static func pumpOnce() {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }

    @MainActor
    static func schedulePump() {
        for _ in 0..<5 {
            pumpOnce()
        }
    }
}
