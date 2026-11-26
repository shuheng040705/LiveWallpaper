import SwiftUI
import WebKit

/// The workshop tab and home-page links share the same page, history, and Steam login.
@MainActor
final class SteamWorkshopBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = SteamWorkshopBrowser()
    static let homeURL = URL(string: "https://steamcommunity.com/app/431960/workshop/?l=schinese")!

    @Published private(set) var url: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var loadingError: String?

    let webView: WKWebView
    private var hasOpenedPage = false
    private var requestedURL: URL?
    private var failedURL: URL?
    private var navigation: WKNavigation?
    private var requestedLogout = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        WebMediaCapturePolicy.install(into: configuration.userContentController)
        SteamWorkshopMenuLayout.install(in: configuration.userContentController)
        SteamWorkshopSubscriptionBridge.install(in: configuration.userContentController)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // Steam also uses history.pushState for filters and pagination.
        webView.publisher(for: \.url).removeDuplicates().assign(to: &$url)
        webView.publisher(for: \.canGoBack).removeDuplicates().assign(to: &$canGoBack)
        webView.publisher(for: \.canGoForward).removeDuplicates().assign(to: &$canGoForward)
        webView.publisher(for: \.isLoading).removeDuplicates().assign(to: &$isLoading)
    }

    func openIfNeeded() {
        guard !hasOpenedPage else { return }
        goHome()
    }

    func open(_ url: URL) {
        guard Self.isSteamPage(url) else { return }
        hasOpenedPage = true
        requestedURL = url
        loadingError = nil
        failedURL = nil
        webView.load(URLRequest(url: url))
    }

    func goHome() { open(Self.homeURL) }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() {
        if let failedURL { open(failedURL) }
        else if webView.url != nil { webView.reload() }
        else { goHome() }
    }

    static func isSteamPage(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return ["steamcommunity.com", "steampowered.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let destination = action.request.url else { return decisionHandler(.cancel) }
        let scheme = destination.scheme?.lowercased()
        if action.targetFrame?.isMainFrame == false {
            // Steam can embed third-party video, captcha, and sign-in frames.
            let allowed = ["https", "http", "about", "data", "blob"].contains(scheme)
            return decisionHandler(allowed ? .allow : .cancel)
        }
        if Self.isSteamPage(destination) {
            // Creator links go through Steam's outbound warning page before
            // redirecting to the external site. Keep that warning in the browser.
            if destination.host?.lowercased() == "steamcommunity.com", destination.path == "/linkfilter",
               action.navigationType == .linkActivated, action.sourceFrame.request.url.map(Self.isSteamPage) == true {
                NSWorkspace.shared.open(destination)
                return decisionHandler(.cancel)
            }
            if action.targetFrame?.isMainFrame == true {
                requestedURL = destination
                if destination.host?.lowercased() == "steamcommunity.com",
                   destination.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "login/logout",
                   action.request.httpMethod == "POST" { requestedLogout = true }
            }
            return decisionHandler(.allow)
        }
        if action.navigationType == .linkActivated, action.sourceFrame.request.url.map(Self.isSteamPage) == true,
           ["https", "http", "steam"].contains(scheme) {
            NSWorkspace.shared.open(destination)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame {
            guard let address = response.response.url, Self.isSteamPage(address) else {
                return decisionHandler(.cancel)
            }
            if let http = response.response as? HTTPURLResponse, (500...599).contains(http.statusCode) {
                failedURL = address
                loadingError = "Steam 页面暂时不可用（HTTP \(http.statusCode)）。"
            }
        }
        decisionHandler(.allow)
    }

    // Keep trusted target="_blank" item and login links in this workshop tab.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url, Self.isSteamPage(url) {
            webView.load(action.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        self.navigation = navigation
        loadingError = nil
        failedURL = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A failed provisional link leaves the previous page and its subscription button interactive.
        SteamWorkshopSubscriptionBridge.shared.clearDetail()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === self.navigation else { return }
        let afterLogout = requestedLogout
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, navigation === self.navigation else { return }
            SteamWebSession.shared.updateFromWebsite(cookies: cookies, afterLogout: afterLogout)
            if afterLogout { self.requestedLogout = false }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        recordFailure(navigation, error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        recordFailure(navigation, error)
    }

    private func recordFailure(_ attempted: WKNavigation?, _ error: Error) {
        guard attempted === navigation else { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        requestedLogout = false
        let address = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        failedURL = address.flatMap { Self.isSteamPage($0) ? $0 : nil } ?? requestedURL ?? webView.url ?? Self.homeURL
        loadingError = nsError.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navigation = nil
        SteamWorkshopSubscriptionBridge.shared.clearDetail()
        failedURL = webView.url ?? requestedURL ?? Self.homeURL
        loadingError = "Steam 网页进程已退出，请重新加载。"
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }
}

struct SteamWorkshopWebView: NSViewRepresentable {
    let browser: SteamWorkshopBrowser

    func makeNSView(context: Context) -> NSView {
        // SwiftUI owns the container for this tab instance. The page can move to a
        // new container even while the old tab is finishing its transition.
        let host = NSView()
        let page = browser.webView
        page.frame = host.bounds
        page.autoresizingMask = [.width, .height]
        host.addSubview(page)
        browser.openIfNeeded()
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
