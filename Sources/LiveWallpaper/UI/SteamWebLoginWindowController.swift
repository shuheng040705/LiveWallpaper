import AppKit
import WebKit

/// 官方 Steam 网页授权窗口。账号、密码和 Steam Guard 都直接输入 steamcommunity.com，
/// 应用只复用 WKWebsiteDataStore.default() 中由 Steam 写入的 Cookie，不读取表单内容。
final class SteamWebLoginWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    static let shared = SteamWebLoginWindowController()

    private var window: NSWindow?
    private var webView: WKWebView?
    private var pollTimer: Timer?
    private var completions: [(Bool) -> Void] = []
    private var finishing = false

    /// 已有有效 Cookie 时直接成功；否则打开官方登录页，检测到 Cookie 后自动关闭并回调。
    func authorize(workshopID: String? = nil, completion: @escaping (Bool) -> Void) {
        SteamWebSession.shared.refresh { [weak self] authenticated in
            guard let self else { return }
            if authenticated {
                completion(true)
                return
            }
            self.completions.append(completion)
            if let window = self.window {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            self.makeWindow(workshopID: workshopID)
        }
    }

    private func makeWindow(workshopID: String?) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        WebMediaCapturePolicy.install(into: config.userContentController)
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        let title = NSTextField(labelWithString: "Steam 网页授权")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString:
            "请在下方 Steam 官方页面完成登录。此授权仅用于订阅与取消订阅；SteamCMD 下载账号仍保持独立。登录成功后窗口会自动关闭并继续刚才的操作。")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2

        let info = NSStackView(views: [title, detail])
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 4
        info.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

        let root = NSStackView(views: [info, web])
        root.orientation = .vertical
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        web.setContentHuggingPriority(.defaultLow, for: .vertical)

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            web.heightAnchor.constraint(greaterThanOrEqualToConstant: 520)
        ])

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Steam 网页授权"
        window.contentView = container
        window.minSize = NSSize(width: 680, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        AppActivationPolicy.windowOpened(window)
        self.window = window
        self.webView = web
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let goto: String
        if let workshopID {
            goto = "sharedfiles/filedetails/?id=\(workshopID)"
        } else {
            goto = "workshop/"
        }
        var components = URLComponents(string: "https://steamcommunity.com/login/home/")
        components?.queryItems = [URLQueryItem(name: "goto", value: goto)]
        if let url = components?.url {
            web.load(URLRequest(url: url))
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            SteamWebSession.shared.refresh { authenticated in
                if authenticated { self?.finish(success: true) }
            }
        }
    }

    private func finish(success: Bool) {
        guard !finishing else { return }
        finishing = true
        pollTimer?.invalidate()
        pollTimer = nil
        let callbacks = completions
        completions.removeAll()
        let closingWindow = window
        window = nil
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        closingWindow?.delegate = nil
        if let closingWindow {
            AppActivationPolicy.windowClosed(closingWindow)
            closingWindow.close()
        }
        finishing = false
        callbacks.forEach { $0(success) }
    }

    func windowWillClose(_ notification: Notification) {
        guard !finishing else { return }
        finish(success: false)
    }

    @available(macOS 12.0, *)
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        Log.write("SteamWebLogin: denied camera/microphone request (host=\(origin.host), type=\(type.rawValue))")
        decisionHandler(.deny)
    }
}
