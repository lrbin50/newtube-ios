import SwiftUI
import WebKit
import SafariServices

@MainActor final class Browser: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    let web: WKWebView
    var play: ((Video) -> Void)?
    @Published var issue: String?
    @Published var canGoBack = false
    private var backObserver: NSKeyValueObservation?

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        if let file = Bundle.main.url(forResource: "Browse", withExtension: "js"),
           let code = try? String(contentsOf: file, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(source: code, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        web = WKWebView(frame: .zero, configuration: config)
        super.init()
        web.configuration.userContentController.add(self, name: "newTube")
        web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = true
        backObserver = web.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
            Task { @MainActor in self?.canGoBack = view.canGoBack }
        }
    }

    func load(path: String, query: [URLQueryItem] = []) {
        var url = URLComponents(string: "https://m.youtube.com")!
        url.path = path
        if !query.isEmpty { url.queryItems = query }
        issue = nil
        web.load(URLRequest(url: url.url!))
    }

    func search(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        if let url = URL(string: query), let video = Video.parse(url) { play?(video); return }
        load(path: "/results", query: [.init(name: "search_query", value: query)])
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              ["m.youtube.com", "youtube.com", "www.youtube.com"].contains(message.frameInfo.securityOrigin.host),
              let body = message.body as? [String: String], let value = body["url"],
              let url = URL(string: value), let video = Video.parse(url, title: body["title"] ?? "") else { return }
        play?(video)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.targetFrame?.isMainFrame != false, let url = action.request.url else {
            decisionHandler(.allow); return
        }
        if let video = Video.parse(url) { decisionHandler(.cancel); play?(video); return }
        guard url.scheme == "https", let host = url.host?.lowercased() else { decisionHandler(.cancel); return }
        if ["youtube.com", "google.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            if action.targetFrame == nil { decisionHandler(.cancel); webView.load(action.request) }
            else { decisionHandler(.allow) }
        } else {
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated { UIApplication.shared.open(url) }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { issue = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { issue = error.localizedDescription }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }
}

struct BrowseSurface: UIViewRepresentable {
    let browser: Browser
    func makeUIView(context: Context) -> WKWebView { browser.web }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

struct WebPlayer: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ view: SFSafariViewController, context: Context) {}
}
