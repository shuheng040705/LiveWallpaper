import SwiftUI
import WebKit

/// 创意工坊页面:内嵌 Steam 创意工坊网页浏览。浏览到某个壁纸详情页时自动识别 workshop id,
/// 提供「下载」按钮 → SteamCMD 下载(可并发)→ 移入壁纸库 → 自动刷新。
/// 工具栏右侧有「下载管理」入口(角标=未完成数),进度行复用 DownloadRow。
struct WorkshopView: View {
    @ObservedObject private var web = WebController.shared
    @ObservedObject private var downloader = WorkshopDownloader.shared

    private let workshopURL = "https://steamcommunity.com/app/431960/workshop/"
    private let accent = Color(red: 0.92, green: 0.36, blue: 0.62)

    /// 从当前 URL 解析 workshop id(详情页 …/filedetails/?id=12345)。
    private var currentItemID: String? {
        guard let url = web.currentURL,
              url.path.contains("filedetails"),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = comps.queryItems?.first(where: { $0.name == "id" })?.value,
              id.allSatisfy(\.isNumber), id.count >= 6
        else { return nil }
        return id
    }

    private var alreadyInLibrary: Bool {
        guard let id = currentItemID else { return false }
        return FileManager.default.fileExists(atPath: PreferencesStore.shared.libraryRoot.appendingPathComponent(id).path)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            infoBar
            if !downloader.jobs.isEmpty { downloadBar }
            WebViewRepresentable(controller: web, initialURL: workshopURL)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            navButton("chevron.left", enabled: web.canGoBack) { web.goBack() }
            navButton("chevron.right", enabled: web.canGoForward) { web.goForward() }
            navButton("arrow.clockwise", enabled: true) { web.reload() }
            navButton("house", enabled: true) { web.goHome() }

            HStack(spacing: 6) {
                if web.isLoading { ProgressView().controlSize(.small).scaleEffect(0.7) }
                Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                Text(web.host.isEmpty ? "steamcommunity.com" : web.host)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))

            // 详情页才出现的「下载」按钮
            if let id = currentItemID {
                downloadButton(id: id)
            }

            // 下载管理入口(角标=未完成数)
            Button { NotificationCenter.default.post(name: .showDownloads, object: nil) } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 15))
                        .frame(width: 30, height: 26)
                    if downloader.pendingCount > 0 {
                        Text("\(downloader.pendingCount)")
                            .font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                            .frame(minWidth: 13, minHeight: 13)
                            .background(Circle().fill(accent))
                            .offset(x: 4, y: -3)
                    }
                }
            }
            .buttonStyle(.plain).help("下载管理")

            Button { if let u = web.currentURL { NSWorkspace.shared.open(u) } } label: {
                Image(systemName: "safari").font(.system(size: 13))
            }
            .buttonStyle(.plain).help("用浏览器打开")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder
    private func downloadButton(id: String) -> some View {
        let downloading = downloader.jobs.contains { $0.id == id && ($0.state == .downloading || $0.state == .connecting || $0.state == .queued) }
        if alreadyInLibrary {
            label("已在库中", "checkmark.circle.fill", .green, disabled: true)
        } else if downloading {
            let frac = downloader.jobs.first { $0.id == id }?.fraction
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(frac.map { String(format: "%d%%", Int($0 * 100)) } ?? "下载中")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
        } else {
            Button {
                let title = web.pageTitle.isEmpty ? id : web.pageTitle
                // 立即入队并开始下载(不等网页抓尺寸——尺寸只用于进度估算,异步补即可)。
                // 之前先 fetchFileSize 再 enqueue,网页抓取耗时全算进「准备」,用户误以为卡住。
                downloader.enqueue(id: id, title: title)
                web.fetchFileSize { bytes in downloader.updateSize(id: id, bytes: bytes) }
            } label: {
                label("下载", "arrow.down.circle.fill", accent, filled: true)
            }
            .buttonStyle(.plain)
            .disabled(!downloader.isSteamCMDAvailable)
            .help(downloader.isSteamCMDAvailable ? "用 SteamCMD 下载到壁纸库" : "未安装 SteamCMD")
        }
    }

    private func label(_ text: String, _ icon: String, _ color: Color,
                       filled: Bool = false, disabled: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium))
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(filled ? .white : color)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(filled ? AnyShapeStyle(color) : AnyShapeStyle(color.opacity(0.15))))
        .opacity(disabled ? 0.8 : 1)
    }

    private var infoBar: some View {
        HStack(spacing: 6) {
            Image(systemName: downloader.isSteamCMDAvailable ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10)).foregroundStyle(downloader.isSteamCMDAvailable ? .blue : .orange)
            Text(downloader.isSteamCMDAvailable
                 ? "进入壁纸详情页点「下载」即可直接下到壁纸库(可同时下多个,无需 Steam 客户端)"
                 : "未检测到 SteamCMD,无法直接下载。终端运行:brew install --cask steamcmd")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    /// 工坊页内嵌的下载进度(只显示前几个,完整列表在「下载管理」窗口)。
    private var downloadBar: some View {
        VStack(spacing: 9) {
            ForEach(downloader.jobs.prefix(3)) { DownloadRow(job: $0) }
            if downloader.jobs.count > 3 {
                Button { NotificationCenter.default.post(name: .showDownloads, object: nil) } label: {
                    Text("查看全部 \(downloader.jobs.count) 个下载 →")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.black.opacity(0.18))
    }

    private func navButton(_ icon: String, enabled: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.06)))
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35)
    }
}

/// 持有一个**长期存活**的 WKWebView 并观察其状态。单例 + 持久实例:切换分类导致
/// WorkshopView 重建时,复用同一个 WebController/WKWebView → 保留浏览位置(不每次回首页)。
final class WebController: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = WebController()

    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var host = ""
    @Published var currentURL: URL?   // @Published:URL 变化驱动「下载」按钮显隐
    var pageTitle = ""

    let wkWebView: WKWebView           // 注意:不能叫 webView,会和 WKNavigationDelegate 方法名冲突
    private var didLoad = false

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // 保留 Steam 登录态
        wkWebView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        wkWebView.navigationDelegate = self
        wkWebView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    }

    /// 仅首次加载首页;之后切走再切回保留当前页面。
    func loadInitialIfNeeded(_ urlString: String) {
        guard !didLoad, let u = URL(string: urlString) else { return }
        didLoad = true
        wkWebView.load(URLRequest(url: u))
    }

    func goBack() { wkWebView.goBack() }
    func goForward() { wkWebView.goForward() }
    func reload() { wkWebView.reload() }
    func goHome() {
        if let u = URL(string: "https://steamcommunity.com/app/431960/workshop/") {
            wkWebView.load(URLRequest(url: u))
        }
    }

    /// 从当前 Steam 详情页抓「文件大小」(如 30.917 MB)换算成字节,供下载进度估算。抓不到回 0。
    func fetchFileSize(_ completion: @escaping (Int64) -> Void) {
        let js = """
        (function(){
          var els=document.querySelectorAll('.detailsStatRight');
          for(var i=0;i<els.length;i++){
            var m=els[i].textContent.trim().match(/([\\d.,]+)\\s*(GB|MB|KB|B)\\b/i);
            if(m){var v=parseFloat(m[1].replace(/,/g,''));var u=m[2].toUpperCase();
              var k=u==='GB'?1073741824:(u==='MB'?1048576:(u==='KB'?1024:1));
              return Math.round(v*k);}
          }
          return 0;
        })()
        """
        wkWebView.evaluateJavaScript(js) { result, _ in
            completion((result as? NSNumber)?.int64Value ?? 0)
        }
    }

    // MARK: - WKNavigationDelegate
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { sync(loading: true) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { sync(loading: false) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { sync(loading: false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { sync(loading: false) }

    /// steam:// 协议(订阅唤起 Steam 客户端)交给系统处理,不在 WebView 里加载。
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, url.scheme == "steam" {
            NSWorkspace.shared.open(url); decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    private func sync(loading: Bool) {
        canGoBack = wkWebView.canGoBack
        canGoForward = wkWebView.canGoForward
        isLoading = loading
        currentURL = wkWebView.url
        host = wkWebView.url?.host ?? ""
        pageTitle = wkWebView.title ?? ""
    }
}

/// 把常驻的 WKWebView 嵌进 SwiftUI。每次 WorkshopView 重建都复用 controller.wkWebView 同一实例。
struct WebViewRepresentable: NSViewRepresentable {
    let controller: WebController
    let initialURL: String

    func makeNSView(context: Context) -> WKWebView {
        controller.loadInitialIfNeeded(initialURL)
        return controller.wkWebView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
