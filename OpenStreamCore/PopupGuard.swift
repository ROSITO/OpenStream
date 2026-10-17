import Foundation

/// Politique anti-onglets pub pour le navigateur mono-onglet (app + headless).
enum PopupGuard {
    /// Même site (host exact ou sous-domaine l’un de l’autre).
    static func sameSite(current: URL?, target: URL) -> Bool {
        guard let currentHost = current?.host()?.lowercased(),
              let targetHost = target.host()?.lowercased(),
              !currentHost.isEmpty,
              !targetHost.isEmpty
        else { return false }
        if currentHost == targetHost { return true }
        return targetHost.hasSuffix("." + currentHost) || currentHost.hasSuffix("." + targetHost)
    }

    static func isHTTPURL(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Autorise d’ouvrir une destination « blank » dans la même vue (lien utilisateur, même site).
    /// Les pubs `window.open` / `target=_blank` cross-site sont refusées.
    static func shouldOpenBlankInPlace(
        currentPage: URL?,
        target: URL?,
        userActivated: Bool
    ) -> Bool {
        guard userActivated,
              let target,
              isHTTPURL(target),
              sameSite(current: currentPage, target: target)
        else { return false }
        return true
    }

    /// Script document-start : neutralise `window.open` (pop-under / onglets pub).
    static let neutralizeWindowOpenJS: String = """
    (function () {
      try {
        window.open = function () { return null; };
        Object.defineProperty(window, 'open', {
          configurable: true,
          writable: true,
          value: function () { return null; }
        });
      } catch (e) {}
    })();
    """
}
