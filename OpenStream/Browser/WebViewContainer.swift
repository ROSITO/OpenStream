import SwiftUI
import WebKit

struct WebViewContainer: NSViewRepresentable {
    let controller: BrowserController

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.isElementFullscreenEnabled = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true

        DispatchQueue.main.async {
            controller.attach(webView: webView)
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Navigation is driven by BrowserController.
    }
}
