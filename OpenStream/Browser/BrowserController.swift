import AppKit
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

    /// Bloque `window.open` / target=_blank publicitaires (défaut : oui).
    var blockPopups: Bool = true
    /// Applique la liste `WKContentRuleList` pubs/trackers (défaut : oui).
    var blockAds: Bool = true
    /// Intercepte les navigations auto (JS / meta / chaîne après chargement) et demande confirmation.
    var blockAutomaticRedirects: Bool = true
    /// Redirection proposée à l’utilisateur (nil = aucune).
    var pendingRedirectURL: URL?

    private weak var webView: WKWebView?
    private var progressObservation: NSKeyValueObservation?
    private var titleObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?
    /// Autorise la chaîne de redirects HTTP tant que la navigation utilisateur n’a pas fini.
    private var expectsRedirectChain = false

    func attach(webView: WKWebView) {
        self.webView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
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
        Task { await self.refreshContentBlocking() }
        onWebViewReady?(webView)
        loadAddressBarURL()
    }

    /// Met à jour popups + adblock + redirects (démarrage / Paramètres).
    func applyBlockingPreferences(blockPopups: Bool, blockAds: Bool, blockAutomaticRedirects: Bool = true) {
        self.blockPopups = blockPopups
        self.blockAds = blockAds
        self.blockAutomaticRedirects = blockAutomaticRedirects
        Task { await refreshContentBlocking() }
    }

    private func refreshContentBlocking() async {
        guard let webView else { return }
        await ContentBlocker.apply(
            blockAds: blockAds,
            to: webView.configuration.userContentController
        )
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
        pendingRedirectURL = nil
        expectsRedirectChain = true
        webView?.load(URLRequest(url: url))
        AppLog.browser.info("Load \(url.absoluteString, privacy: .public)")
    }

    func goBack() {
        expectsRedirectChain = true
        webView?.goBack()
    }

    func goForward() {
        expectsRedirectChain = true
        webView?.goForward()
    }

    func reload() {
        expectsRedirectChain = true
        webView?.reload()
    }

    func stop() { webView?.stopLoading() }

    func confirmPendingRedirect() {
        guard let url = pendingRedirectURL else { return }
        pendingRedirectURL = nil
        load(url: url)
    }

    func cancelPendingRedirect() {
        pendingRedirectURL = nil
        AppLog.browser.info("Redirect declined")
    }}

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
        expectsRedirectChain = false
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
        expectsRedirectChain = false
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
        expectsRedirectChain = false
        lastErrorMessage = error.localizedDescription
        syncNavigationState(from: webView)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Pop-under / target=_blank sans cadre : bloquer si activé (sauf clic lien → même fenêtre).
        if blockPopups,
           navigationAction.targetFrame == nil,
           navigationAction.navigationType != .linkActivated
        {
            AppLog.browser.debug("Blocked popup navigation \(navigationAction.request.url?.absoluteString ?? "?", privacy: .public)")
            decisionHandler(.cancel)
            return
        }

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

        if shouldPromptBeforeNavigation(navigationAction) {
            if let url = navigationAction.request.url {
                pendingRedirectURL = url
                AppLog.browser.info("Redirect pending confirmation \(url.absoluteString, privacy: .public)")
            }
            decisionHandler(.cancel)
            return
        }

        switch navigationAction.navigationType {
        case .linkActivated, .formSubmitted, .backForward, .reload:
            expectsRedirectChain = true
        default:
            break
        }

        decisionHandler(.allow)
    }

    /// Navigations main-frame non initiées par l’utilisateur (JS, meta-refresh, etc.).
    private func shouldPromptBeforeNavigation(_ action: WKNavigationAction) -> Bool {
        guard blockAutomaticRedirects else { return false }
        guard action.targetFrame?.isMainFrame != false else { return false }
        guard let url = action.request.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return false }

        switch action.navigationType {
        case .linkActivated, .formSubmitted, .backForward, .reload:
            return false
        case .other:
            if expectsRedirectChain { return false }
            // Éviter de re-proposer la même URL déjà affichée.
            if let current = webView?.url, Self.samePage(current, url) { return false }
            return true
        @unknown default:
            return false
        }
    }

    private static func samePage(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host()?.lowercased() == b.host()?.lowercased()
            && a.path == b.path
            && (a.query ?? "") == (b.query ?? "")
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

extension BrowserController: WKUIDelegate {
    /// Intercepte `window.open` / target=_blank. Pas de nouvelle fenêtre : pubs → nil ;
    /// clic utilisateur sur un lien → charge dans la même vue.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard blockPopups else {
            // Pas de multi-onglets pour l’instant : même comportement (même fenêtre).
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https"
        {
            webView.load(URLRequest(url: url))
            AppLog.browser.debug("Popup link opened in-place \(url.absoluteString, privacy: .public)")
        } else {
            AppLog.browser.debug(
                "Blocked window.open \(navigationAction.request.url?.absoluteString ?? "?", privacy: .public)"
            )
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        // Les alertes JS sont souvent des pubs / arnaques sur les sites stream.
        if blockPopups {
            AppLog.browser.debug("Suppressed JS alert")
            completionHandler()
            return
        }
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Page"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        if blockPopups {
            completionHandler(false)
            return
        }
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Page"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Annuler")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
}

extension Notification.Name {
    static let openStreamNavigationDidFinish = Notification.Name("openStreamNavigationDidFinish")
}
