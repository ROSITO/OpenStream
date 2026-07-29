import Foundation
import Observation
import WebKit

enum NetworkObserverConstants {
    static let messageName = "openstreamMedia"
}

/// Prototype Phase 1 — observation via:
/// 1) WKNavigationDelegate (navigations document / médias)
/// 2) Script JS injecté (resource timing + hooks fetch/XHR/media) → WKScriptMessageHandler
///
/// Choix documenté dans MEMORY.md (D008).
@MainActor
@Observable
final class NetworkObserver: NSObject {
    private(set) var candidates: [NetworkMediaCandidate] = []

    /// Appelé uniquement quand un candidat est réellement ajouté (après filtres / dédup).
    var onCandidateAccepted: ((NetworkMediaCandidate) -> Void)?

    private var seenURLKeys = Set<String>()
    private weak var webView: WKWebView?
    private var scriptProxy: WeakScriptMessageHandler?

    func attachScriptMessaging(to webView: WKWebView) {
        self.webView = webView
        let contentController = webView.configuration.userContentController
        contentController.removeScriptMessageHandler(forName: NetworkObserverConstants.messageName)

        let proxy = WeakScriptMessageHandler(delegate: self)
        self.scriptProxy = proxy
        contentController.add(proxy, name: NetworkObserverConstants.messageName)

        let script = WKUserScript(
            source: Self.injectionSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        contentController.addUserScript(script)
        AppLog.network.info("NetworkObserver attached (JS + navigation)")
    }

    func ingest(_ candidate: NetworkMediaCandidate) {
        guard MediaURLHeuristics.looksLikeMedia(candidate.url, mimeType: candidate.mimeType) else {
            return
        }
        let key = candidate.url.absoluteString
        guard !seenURLKeys.contains(key) else { return }
        seenURLKeys.insert(key)
        candidates.insert(candidate, at: 0)
        AppLog.network.debug(
            "Candidate \(candidate.source.rawValue, privacy: .public): \(candidate.url.absoluteString, privacy: .public)"
        )
        onCandidateAccepted?(candidate)
    }

    func clear() {
        candidates.removeAll()
        seenURLKeys.removeAll()
    }

    fileprivate func handleScriptPayload(_ payload: ScriptMediaPayload) {
        let source = NetworkMediaCandidate.Source(rawValue: payload.sourceRaw) ?? .resourceTiming
        let candidate = NetworkMediaCandidate(
            url: payload.url,
            mimeType: payload.mimeType,
            source: source,
            pageURL: payload.pageURL
        )
        ingest(candidate)
    }
}

/// Payload Sendable extrait hors isolation WebKit.
struct ScriptMediaPayload: Sendable {
    let url: URL
    let mimeType: String?
    let sourceRaw: String
    let pageURL: URL?
}

extension NetworkObserver: WKScriptMessageHandler {
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // WK invoque typiquement sur le main thread ; on extrait un payload Sendable.
        let name = message.name
        guard name == NetworkObserverConstants.messageName else { return }
        guard let body = message.body as? [String: Any],
              let urlString = body["url"] as? String,
              let url = URL(string: urlString)
        else { return }

        let payload = ScriptMediaPayload(
            url: url,
            mimeType: body["mime"] as? String,
            sourceRaw: (body["source"] as? String) ?? "resourceTiming",
            pageURL: (body["page"] as? String).flatMap(URL.init(string:))
        )

        Task { @MainActor in
            self.handleScriptPayload(payload)
        }
    }
}

extension NetworkObserver {
    /// Script injecté : resource timing polling + hooks fetch / XHR / media elements.
    static let injectionSource: String = #"""
    (function () {
      if (window.__openstreamMediaHookInstalled) { return; }
      window.__openstreamMediaHookInstalled = true;

      function post(url, mime, source) {
        try {
          if (!url || typeof url !== 'string') { return; }
          if (url.indexOf('blob:') === 0 || url.indexOf('data:') === 0) { return; }
          window.webkit.messageHandlers.openstreamMedia.postMessage({
            url: url,
            mime: mime || null,
            source: source || 'resourceTiming',
            page: location.href
          });
        } catch (e) {}
      }

      function maybeMedia(url, mime) {
        if (!url) { return; }
        var lower = String(url).toLowerCase();
        var m = (mime || '').toLowerCase();
        if (
          lower.indexOf('.m3u8') !== -1 ||
          lower.indexOf('.mpd') !== -1 ||
          lower.indexOf('.mp4') !== -1 ||
          lower.indexOf('.m4s') !== -1 ||
          lower.indexOf('.ts') !== -1 ||
          lower.indexOf('m3u8') !== -1 ||
          m.indexOf('mpegurl') !== -1 ||
          m.indexOf('dash+xml') !== -1 ||
          m.indexOf('video/') === 0 ||
          m.indexOf('application/vnd.apple.mpegurl') !== -1
        ) {
          return true;
        }
        return false;
      }

      var seen = {};
      function consider(url, mime, source) {
        if (!url || seen[url]) { return; }
        if (!maybeMedia(url, mime)) { return; }
        seen[url] = true;
        post(url, mime, source);
      }

      function scanResources() {
        try {
          var entries = performance.getEntriesByType('resource');
          for (var i = 0; i < entries.length; i++) {
            var e = entries[i];
            consider(e.name, null, 'resourceTiming');
          }
        } catch (err) {}
      }
      setInterval(scanResources, 1000);
      scanResources();

      if (window.fetch) {
        var originalFetch = window.fetch;
        window.fetch = function () {
          try {
            var input = arguments[0];
            var url = typeof input === 'string' ? input : (input && input.url);
            if (url) { consider(url, null, 'fetchHook'); }
          } catch (e) {}
          return originalFetch.apply(this, arguments).then(function (response) {
            try {
              var ct = response.headers && response.headers.get && response.headers.get('content-type');
              consider(response.url, ct, 'fetchHook');
            } catch (e2) {}
            return response;
          });
        };
      }

      var OriginalXHR = window.XMLHttpRequest;
      if (OriginalXHR) {
        window.XMLHttpRequest = function () {
          var xhr = new OriginalXHR();
          var open = xhr.open;
          xhr.open = function (method, url) {
            try { consider(url, null, 'xhrHook'); } catch (e) {}
            return open.apply(xhr, arguments);
          };
          return xhr;
        };
      }

      function watchMedia(el) {
        try {
          if (el && el.src) { consider(el.src, el.type || null, 'mediaElement'); }
          if (el && el.currentSrc) { consider(el.currentSrc, el.type || null, 'mediaElement'); }
        } catch (e) {}
      }
      document.querySelectorAll('video, audio, source').forEach(watchMedia);
      var mo = new MutationObserver(function (mutations) {
        mutations.forEach(function (m) {
          m.addedNodes && m.addedNodes.forEach(function (n) {
            if (n.tagName === 'VIDEO' || n.tagName === 'AUDIO' || n.tagName === 'SOURCE') {
              watchMedia(n);
            }
            if (n.querySelectorAll) {
              n.querySelectorAll('video, audio, source').forEach(watchMedia);
            }
          });
        });
      });
      mo.observe(document.documentElement || document, { childList: true, subtree: true });
    })();
    """#
}
