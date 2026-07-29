import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class BrowserController: NSObject {
    var urlString: String = "https://example.com"
    var pageTitle: String = ""
    var isLoading: Bool = false
    var estimatedProgress: Double = 0
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var lastErrorMessage: String?

    var onMediaCandidate: ((NetworkMediaCandidate) -> Void)?
    var onWebViewReady: ((WKWebView) -> Void)?
    /// Notifié quand le titre de page devient utilisable (après SPA / didFinish).
    var onPageTitleChange: ((String) -> Void)?

    private weak var webView: WKWebView?
    private var progressObservation: NSKeyValueObservation?
    private var titleObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?

    func attach(webView: WKWebView) {
        self.webView = webView
        webView.navigationDelegate = self
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            Task { @MainActor in
                self?.estimatedProgress = view.estimatedProgress
            }
        }
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] view, _ in
            Task { @MainActor in
                self?.applyTitle(view.title)
            }
        }
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] view, _ in
            Task { @MainActor in
                if let url = view.url {
                    self?.urlString = url.absoluteString
                }
            }
        }
        onWebViewReady?(webView)
        loadAddressBarURL()
    }

    /// Titre sync (fallback rapide).
    func mediaTitleHint(pageURL: URL?, mediaURL: URL) -> String {
        applyTitle(webView?.title)
        return PageTitleResolver.title(
            pageTitle: pageTitle,
            pageURL: pageURL ?? webView?.url ?? URL(string: urlString),
            mediaURL: mediaURL
        )
    }

    /// Titre de contenu via métadonnées page (og / JSON-LD / h1), pas le nom du site.
    func resolveContentTitle(pageURL: URL?, mediaURL: URL) async -> String {
        let page = pageURL ?? webView?.url ?? URL(string: urlString)
        let candidates = await extractContentTitleCandidates()
        let resolved = PageTitleResolver.title(
            candidates: candidates,
            pageTitle: webView?.title ?? pageTitle,
            pageURL: page,
            mediaURL: mediaURL
        )
        if PageTitleResolver.usefulTitle(resolved, host: page?.host()) != nil {
            if pageTitle != resolved {
                pageTitle = resolved
                onPageTitleChange?(resolved)
            }
        }
        return resolved
    }

    private func extractContentTitleCandidates() async -> [PageTitleResolver.Candidate] {
        guard let webView else { return [] }
        let js = Self.contentTitleExtractionJS
        do {
            let result = try await webView.evaluateJavaScript(js)
            guard let dict = result as? [String: Any],
                  let rows = dict["titles"] as? [[String: Any]]
            else { return [] }
            return rows.compactMap { row in
                guard let text = row["t"] as? String, let source = row["s"] as? String else { return nil }
                return PageTitleResolver.Candidate(text: text, source: source)
            }
        } catch {
            AppLog.browser.debug("Content title extract failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private static let contentTitleExtractionJS: String = #"""
    (function () {
      function meta(key) {
        var el = document.querySelector('meta[property="' + key + '"]')
          || document.querySelector('meta[name="' + key + '"]');
        return el && el.content ? String(el.content).trim() : null;
      }
      function text(sel) {
        var el = document.querySelector(sel);
        if (!el) return null;
        var t = (el.getAttribute('content') || el.textContent || '').replace(/\s+/g, ' ').trim();
        return t || null;
      }
      var out = [];
      function push(v, s) {
        if (!v) return;
        v = String(v).replace(/\s+/g, ' ').trim();
        if (v.length < 2 || v.length > 200) return;
        out.push({ t: v, s: s });
      }

      push(meta('og:title'), 'og');
      push(meta('twitter:title'), 'twitter');

      document.querySelectorAll('script[type="application/ld+json"]').forEach(function (node) {
        try {
          var raw = JSON.parse(node.textContent);
          var list = Array.isArray(raw) ? raw : [raw];
          list.forEach(function (obj) {
            if (!obj) return;
            var nodes = obj['@graph'] ? obj['@graph'] : [obj];
            (Array.isArray(nodes) ? nodes : [nodes]).forEach(function (n) {
              if (!n) return;
              var type = (n['@type'] || '').toString();
              if (/Movie|TVSeries|TVEpisode|VideoObject|CreativeWork|Episode/i.test(type)) {
                if (n.name) push(n.name, 'jsonld');
                if (n.headline) push(n.headline, 'jsonld');
                if (n.alternateName) push(n.alternateName, 'jsonld');
              }
            });
          });
        } catch (e) {}
      });

      push(text('[itemprop="name"]'), 'itemprop');
      push(text('h1'), 'h1');
      push(text('.video-title, .player-title, .media-title, .title-name, .film-title, .movie-title, .episode-title, [class*="episode-title"], [class*="movie-title"], [class*="video-title"]'), 'player');

      var video = document.querySelector('video[title], video[aria-label]');
      if (video) push(video.getAttribute('title') || video.getAttribute('aria-label'), 'video');

      push(document.title, 'document');
      return { titles: out, host: location.hostname || '' };
    })();
    """#

    private func applyTitle(_ raw: String?) {
        let host = webView?.url?.host() ?? URL(string: urlString)?.host()
        guard let useful = PageTitleResolver.usefulTitle(raw, host: host) else { return }
        if pageTitle != useful {
            pageTitle = useful
            onPageTitleChange?(useful)
        }
    }

    func loadAddressBarURL() {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let withScheme: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            withScheme = trimmed
        } else if trimmed.contains(".") && !trimmed.contains(" ") {
            withScheme = "https://\(trimmed)"
        } else {
            let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
            withScheme = "https://duckduckgo.com/?q=\(query)"
        }

        guard let url = URL(string: withScheme) else {
            lastErrorMessage = "URL invalide"
            return
        }

        load(url: url)
    }

    func load(url: URL) {
        urlString = url.absoluteString
        lastErrorMessage = nil
        webView?.load(URLRequest(url: url))
        AppLog.browser.info("Load \(url.absoluteString, privacy: .public)")
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func stop() { webView?.stopLoading() }
}

extension BrowserController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        lastErrorMessage = nil
        // Ne pas garder l’ancien titre (sinon faux nom sur les médias détectés tôt)
        pageTitle = ""
        syncNavigationState(from: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        applyTitle(webView.title)
        if let url = webView.url {
            urlString = url.absoluteString
        }
        syncNavigationState(from: webView)
        NotificationCenter.default.post(name: .openStreamNavigationDidFinish, object: webView)
        // Re-scan métadonnées contenu après chargement (SPA / og:title tardif)
        Task { @MainActor in
            guard let url = webView.url else { return }
            _ = await self.resolveContentTitle(pageURL: url, mediaURL: url)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        lastErrorMessage = error.localizedDescription
        syncNavigationState(from: webView)
        AppLog.browser.error("Navigation failed: \(error.localizedDescription, privacy: .public)")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        isLoading = false
        lastErrorMessage = error.localizedDescription
        syncNavigationState(from: webView)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url,
           MediaURLHeuristics.looksLikeMedia(url, mimeType: nil)
        {
            let candidate = NetworkMediaCandidate(
                url: url,
                mimeType: nil,
                source: .navigation,
                pageURL: webView.url
            )
            onMediaCandidate?(candidate)
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let url = http.url
        {
            let mime = http.mimeType ?? navigationResponse.response.mimeType
            if MediaURLHeuristics.looksLikeMedia(url, mimeType: mime) {
                let candidate = NetworkMediaCandidate(
                    url: url,
                    mimeType: mime,
                    source: .navigation,
                    pageURL: webView.url
                )
                onMediaCandidate?(candidate)
            }
        }
        decisionHandler(.allow)
    }

    private func syncNavigationState(from webView: WKWebView) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        estimatedProgress = webView.estimatedProgress
    }
}

extension Notification.Name {
    static let openStreamNavigationDidFinish = Notification.Name("openStreamNavigationDidFinish")
}
