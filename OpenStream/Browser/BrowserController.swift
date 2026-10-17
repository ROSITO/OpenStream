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
    /// Bloque en silence les navigations auto **cross-site** (JS / meta) — plus d’alerte modale.
    var blockAutomaticRedirects: Bool = true
    /// Compteur de navigations / popups bloqués (bandeau UI, pas de modal).
    var blockedNavCount: Int = 0
    /// Message court pour le bandeau (nil = masqué).
    var blockedNavBanner: String?

    private weak var webView: WKWebView?
    private var progressObservation: NSKeyValueObservation?
    private var titleObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?
    /// Autorise la chaîne de redirects HTTP tant que la navigation utilisateur n’a pas fini.
    private var expectsRedirectChain = false
    private var bannerClearTask: Task<Void, Never>?

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
        resetBlockBanner()
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

    func dismissBlockBanner() {
        bannerClearTask?.cancel()
        blockedNavBanner = nil
    }

    private func resetBlockBanner() {
        bannerClearTask?.cancel()
        blockedNavCount = 0
        blockedNavBanner = nil
    }

    private func noteBlocked(_ kind: String, url: URL?) {
        blockedNavCount += 1
        let host = url?.host() ?? "?"
        blockedNavBanner = blockedNavCount == 1
            ? "\(kind) bloqué (\(host))"
            : "\(blockedNavCount) pubs / redirections bloquées"
        AppLog.browser.info(
            "Silent-blocked \(kind, privacy: .public) \(url?.absoluteString ?? "?", privacy: .public)"
        )
        bannerClearTask?.cancel()
        bannerClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self.blockedNavBanner = nil
        }
    }
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
        // target=_blank / pop-under : ne jamais laisser voler la vue principale.
        // Les vrais liens même-site passent par `createWebViewWith` → load in-place.
        if blockPopups, navigationAction.targetFrame == nil {
            noteBlocked("popup", url: navigationAction.request.url)
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

        // Cross-site auto (JS/meta) → cancel silencieux. Plus jamais d’alerte modale.
        if shouldSilentBlockAutoNavigation(navigationAction) {
            noteBlocked("redirect", url: navigationAction.request.url)
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

    /// Main-frame `.other` cross-site après chargement = hijack pub typique.
    private func shouldSilentBlockAutoNavigation(_ action: WKNavigationAction) -> Bool {
        guard blockAutomaticRedirects else { return false }
        guard action.targetFrame?.isMainFrame != false else { return false }
        guard let url = action.request.url, PopupGuard.isHTTPURL(url) else { return false }

        switch action.navigationType {
        case .linkActivated, .formSubmitted, .backForward, .reload:
            return false
        case .other:
            if expectsRedirectChain { return false }
            // Même site (SPA / soft nav) : laisser passer.
            if PopupGuard.sameSite(current: webView?.url, target: url) { return false }
            return true
        @unknown default:
            return false
        }
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
        let target = navigationAction.request.url
        let userActivated = navigationAction.navigationType == .linkActivated

        guard blockPopups else {
            // Pas de multi-onglets : ouvrir dans la même vue.
            if let target, PopupGuard.isHTTPURL(target) {
                webView.load(URLRequest(url: target))
            }
            return nil
        }

        // Pubs : window.open / blank cross-site → ignoré. Lien utilisateur même site → in-place.
        if PopupGuard.shouldOpenBlankInPlace(
            currentPage: webView.url,
            target: target,
            userActivated: userActivated
        ), let target {
            webView.load(URLRequest(url: target))
            AppLog.browser.debug("Blank link opened in-place \(target.absoluteString, privacy: .public)")
        } else {
            noteBlocked("popup", url: target)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        // Avaler sans spammer le bandeau (sites tirent des dizaines d’alertes).
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
            AppLog.browser.debug("Suppressed JS confirm")
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

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        if blockPopups {
            AppLog.browser.debug("Suppressed JS prompt")
            completionHandler(nil)
            return
        }
        completionHandler(defaultText)
    }
}

extension Notification.Name {
    static let openStreamNavigationDidFinish = Notification.Name("openStreamNavigationDidFinish")
}
