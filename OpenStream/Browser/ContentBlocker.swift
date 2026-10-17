import Foundation
import WebKit

/// Compile et applique une liste de règles Safari (`WKContentRuleList`) pour bloquer pubs / trackers.
@MainActor
enum ContentBlocker {
    /// Incrémenter si `adblock-rules.json` change (invalide le cache WebKit).
    static let listIdentifier = "app.openstream.adblock.v1"

    static func loadRulesJSON() throws -> String {
        let bundle = Bundle.main
        if let url = bundle.url(forResource: "adblock-rules", withExtension: "json"),
           let text = try? String(contentsOf: url, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return text
        }
        return Self.fallbackRulesJSON
    }

    static func compiledRuleList() async throws -> WKContentRuleList {
        guard let store = WKContentRuleListStore.default() else {
            throw ContentBlockerError.storeUnavailable
        }
        if let existing = try await lookUp(in: store) {
            return existing
        }
        let json = try loadRulesJSON()
        return try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: listIdentifier,
                encodedContentRuleList: json
            ) { list, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: ContentBlockerError.compilationFailed)
                }
            }
        }
    }

    private static func lookUp(in store: WKContentRuleListStore) async throws -> WKContentRuleList? {
        try await withCheckedThrowingContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: listIdentifier) { list, error in
                if let error {
                    let ns = error as NSError
                    if ns.domain == WKError.errorDomain {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(returning: list)
                }
            }
        }
    }

    /// Applique ou retire la liste sur un `WKUserContentController`.
    static func apply(blockAds: Bool, to controller: WKUserContentController) async {
        controller.removeAllContentRuleLists()
        guard blockAds else {
            AppLog.browser.info("Ad blocker off")
            return
        }
        do {
            let list = try await compiledRuleList()
            controller.add(list)
            AppLog.browser.info("Ad blocker on (\(listIdentifier, privacy: .public))")
        } catch {
            AppLog.browser.error(
                "Ad blocker compile failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

enum ContentBlockerError: LocalizedError {
    case compilationFailed
    case storeUnavailable

    var errorDescription: String? {
        switch self {
        case .compilationFailed:
            return "Impossible de compiler les règles adblock"
        case .storeUnavailable:
            return "WKContentRuleListStore indisponible"
        }
    }
}

extension ContentBlocker {
    fileprivate static let fallbackRulesJSON = #"""
    [
      {"trigger":{"url-filter":"doubleclick\\.net"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"googlesyndication\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"googleadservices\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"adservice\\.google\\."},"action":{"type":"block"}},
      {"trigger":{"url-filter":"amazon-adsystem\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"adnxs\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"popads\\.net"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"popcash\\.net"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"propellerads\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"exoclick\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*","resource-type":["popup"]},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".adsbygoogle, ins.adsbygoogle, [id^=\"google_ads_\"], .ad-banner, .ad-container, #ads, #ad-container"}}
    ]
    """#
}
