import SwiftUI
import WebKit

/// 创意工坊页面:内嵌 Steam 创意工坊网页浏览。浏览到某个壁纸详情页时自动识别 workshop id,
/// 提供「下载」按钮 → SteamCMD 下载(可并发)→ 移入壁纸库 → 自动刷新。
/// 工具栏右侧有「下载管理」入口(角标=未完成数),进度行复用 DownloadRow。
struct WorkshopView: View {
    @ObservedObject private var web = WebController.shared
    @ObservedObject private var downloader = WorkshopDownloader.shared

    private let workshopURL = "https://steamcommunity.com/app/431960/workshop/"
    private let accent = Color.accentColor

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
        return LocalWallpaperProbe.isReady(
            at: PreferencesStore.shared.libraryRoot.appendingPathComponent(id, isDirectory: true)
        )
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
        let job = downloader.jobs.first { $0.id == id }
        let downloading = job.map { WorkshopDownloader.isActive($0.state) } ?? false
        if alreadyInLibrary {
            label("已在库中", "checkmark.circle.fill", .green, disabled: true)
        } else if downloading {
            let frac = downloader.jobs.first { $0.id == id }?.fraction
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(frac.map { String(format: "%d%%", Int($0 * 100)) } ?? job?.compactStatus ?? "下载中")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
        } else {
            Button {
                let title = web.pageTitle.isEmpty ? id : web.pageTitle
                // 立即入队并开始下载(不等网页抓尺寸——尺寸只用于进度估算,异步补即可)。
                // 之前先 fetchFileSize 再 enqueue,网页抓取耗时全算进「准备」,用户误以为卡住。
                WorkshopAcquisition.start(id: id, title: title)
                web.fetchFileSize { bytes in downloader.updateSize(id: id, bytes: bytes) }
            } label: {
                label("下载", "arrow.down.circle.fill", accent, filled: true)
            }
            .buttonStyle(.plain)
            .disabled(!downloader.isAnyDownloadBackendAvailable)
            .help(downloader.isAnyDownloadBackendAvailable
                  ? "优先使用当前 Steam 客户端，未接管时自动回退 SteamCMD"
                  : "未运行对应 Steam 客户端，且未安装 SteamCMD")
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
            Image(systemName: downloader.isAnyDownloadBackendAvailable ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10)).foregroundStyle(downloader.isAnyDownloadBackendAvailable ? .blue : .orange)
            Text(downloader.isCrossOverSteamAvailable
                 ? "下载会先交给当前 CrossOver Steam；20 秒未接管时自动回退 SteamCMD"
                 : (downloader.isSteamCMDAvailable
                    ? "当前 Steam 客户端未运行，使用已预热的 SteamCMD 直接下载"
                    : "请运行对应 CrossOver Steam，或安装 SteamCMD：brew install --cask steamcmd"))
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
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 24)
        }
        .buttonStyle(.borderless).disabled(!enabled).opacity(enabled ? 1 : 0.35)
    }
}

/// 持有一个**长期存活**的 WKWebView 并观察其状态。单例 + 持久实例:切换分类导致
/// WorkshopView 重建时,复用同一个 WebController/WKWebView → 保留浏览位置(不每次回首页)。
final class WebController: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
    static let shared = WebController()

    /// 注入页面的 JS:拦截「订阅」的网络请求(/sharedfiles/subscribe)本身,从 body 取 workshop id
    /// 通过消息桥发回 app → 触发下载。与页面结构无关 —— 详情页按钮、浏览网格悬停的绿色订阅按钮、合集订阅
    /// 都走同一个端点,所以都能捕获;取消订阅走 /unsubscribe(天然区分,不会误触发下载)。
    /// 在 documentStart 注入,确保在页面脚本发起请求前已包好 XHR/fetch。
    private static let subscribeHookJS = """
    (function(){
      if (window.__wpSubHook) return; window.__wpSubHook = true;
      function send(name, v){ try { var h=window.webkit&&webkit.messageHandlers; if (v && h && h[name]) h[name].postMessage(String(v)); } catch(_){} }
      function bodyStr(b){
        if (!b) return '';
        if (typeof b === 'string') return b;
        try { if (window.URLSearchParams && b instanceof URLSearchParams) return b.toString(); } catch(_){}
        try { if (window.FormData && b instanceof FormData){ var a=[]; b.forEach(function(v,k){ a.push(k+'='+v); }); return a.join('&'); } } catch(_){}
        return '';
      }
      // 解 protobuf(WebAPI 订阅的 input_protobuf_encoded):取 field 1 varint = publishedfileid
      function idFromProto(b64){
        try {
          var bin = atob(decodeURIComponent(b64).replace(/-/g,'+').replace(/_/g,'/'));
          var i = 0;
          while (i < bin.length){
            var tag = bin.charCodeAt(i++), field = tag >> 3, wire = tag & 7;
            if (wire === 0){ var val=0, sh=0, by; do { by=bin.charCodeAt(i++); val += (by & 0x7f) * Math.pow(2, sh); sh += 7; } while ((by & 0x80) && i < bin.length); if (field === 1 && val > 1000000) return String(val); }
            else if (wire === 2){ var len = bin.charCodeAt(i++); i += len; }
            else if (wire === 5){ i += 4; } else if (wire === 1){ i += 8; } else break;
          }
        } catch(_){}
        return null;
      }
      // 端点:WebAPI(主页/浏览,protobuf)+ 社区(详情页,明文 id)。订阅 vs 取消订阅分别处理。
      function isUnsub(u){ u = u || ''; return /IPublishedFileService\\/Unsubscribe/i.test(u) || /\\/sharedfiles\\/unsubscribe/i.test(u); }
      function isSub(u){ u = u || ''; return (/IPublishedFileService\\/Subscribe/i.test(u) || /\\/sharedfiles\\/subscribe/i.test(u)) && !isUnsub(u); }
      function eventFor(url, body){
        url = url || '';
        var unsub = isUnsub(url) || isUnsub(body);
        var sub = !unsub && (isSub(url) || isSub(body));
        if (!unsub && !sub) return null;
        var s = body + '&' + url;
        var m = s.match(/(?:^|&|\\?)(?:id|publishedfileid)=(\\d+)/i);
        var id = m ? m[1] : null;
        if (!id){ var p = s.match(/input_protobuf_encoded=([^&\\s]+)/); if (p) id = idFromProto(p[1]); }
        return id ? { name: unsub ? 'wpUnsubscribe' : 'wpSubscribe', id: id } : null;
      }
      function sendEvent(e){ if (e) send(e.name, e.id); }
      function httpOK(status){ return status >= 200 && status < 300; }
      function responseSaysSuccess(text){
        if (!text) return true;
        try {
          var j = JSON.parse(text);
          if (typeof j.success === 'number') return j.success === 1;
          if (typeof j.success === 'boolean') return j.success;
        } catch(_){}
        return true;
      }
      var O = XMLHttpRequest.prototype.open, S = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(m, u){ this.__wu = u; return O.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function(b){
        var e = null; try { e = eventFor(this.__wu, bodyStr(b)); } catch(_){}
        if (e) this.addEventListener('load', function(){ if (httpOK(this.status) && responseSaysSuccess(this.responseText)) sendEvent(e); }, { once:true });
        return S.apply(this, arguments);
      };
      if (window.fetch){
        var F = window.fetch;
        window.fetch = function(i, init){
          var e = null; try { var u=(typeof i==='string')?i:(i&&i.url)||''; e=eventFor(u, bodyStr(init&&init.body)); } catch(_){}
          return F.apply(this, arguments).then(function(r){
            if (e && r && r.ok) {
              try { r.clone().text().then(function(t){ if (responseSaysSuccess(t)) sendEvent(e); }); }
              catch(_) { sendEvent(e); }
            }
            return r;
          });
        };
      }
      if (navigator.sendBeacon){
        var B = navigator.sendBeacon.bind(navigator);
        navigator.sendBeacon = function(u, d){
          var e = null; try { e=eventFor(u, bodyStr(d)); } catch(_){}
          var accepted = B(u, d); if (accepted) sendEvent(e); return accepted;
        };
      }
    })();
    """

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
        let ucc = WKUserContentController()
        WebMediaCapturePolicy.install(into: ucc)
        ucc.addUserScript(WKUserScript(source: Self.subscribeHookJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        cfg.userContentController = ucc
        wkWebView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        ucc.add(self, name: "wpSubscribe")     // 网页订阅 → 同步下载
        ucc.add(self, name: "wpUnsubscribe")   // 网页取消订阅 → 同步删除本地壁纸
        ucc.add(self, name: "wpDebug")         // 诊断(保留,正式版 JS 不再发)
        wkWebView.navigationDelegate = self
        wkWebView.uiDelegate = self
        wkWebView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    }

    /// 订阅/取消订阅消息只接受 Steam 官方域(含子域,如 steamcommunity.com / store.steampowered.com)。
    /// 用后缀匹配且要求前面紧跟 "." ——避免 "evilsteamcommunity.com" 这种前缀拼接绕过。
    private static func isTrustedOrigin(_ origin: WKSecurityOrigin) -> Bool {
        guard origin.protocol == "https" else { return false }
        let host = origin.host.lowercased()
        let trusted = ["steamcommunity.com", "store.steampowered.com", "steampowered.com"]
        return trusted.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// 收到网页「订阅」事件 → 同步用 SteamCMD 下载该壁纸(已在库则跳过)。
    /// 详情页订阅:用页面标题 + 抓文件大小;浏览网格订阅:用 id 当标题(抓不到大小,进度走块数不受影响)。
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "wpDebug" { Log.write("WS-DBG \(message.body)"); return }
        // ⚠ 安全:钩子脚本以 forMainFrameOnly:false 注入**所有**页面的**所有** iframe,而本 webview
        //   允许导航到任意 http(s)(decidePolicyFor 只特判 steam://)。若不校验来源,任意网页(或
        //   Steam 页里嵌的第三方 iframe)执行 `fetch('/sharedfiles/subscribe?id=...')` 就能让我们
        //   静默用 SteamCMD 下载攻击者指定的工坊条目入库;`unsubscribe` 更能把用户本地壁纸移进废纸篓。
        //   钩子在请求**发起时**就上报(不需要请求成功、不受 CORS 限制),所以门槛极低。
        //   → 只接受来自 Steam 官方域的消息。
        guard Self.isTrustedOrigin(message.frameInfo.securityOrigin) else {
            Log.write("WorkshopView: 丢弃来自非 Steam 域的订阅消息(host=\(message.frameInfo.securityOrigin.host))")
            return
        }
        guard let id = message.body as? String, id.allSatisfy(\.isNumber), id.count >= 6 else { return }
        // 网页取消订阅 → 删除对应本地壁纸(交给 AppDelegate,以便处理正在播放/库刷新)。
        if message.name == "wpUnsubscribe" {
            let dest = PreferencesStore.shared.libraryRoot.appendingPathComponent(id)
            guard FileManager.default.fileExists(atPath: dest.path) else { return }   // 本地没有就不管
            Log.write("Unsubscribe→delete: 网页取消订阅 \(id),删除本地壁纸")
            NotificationCenter.default.post(name: .unsubscribeWallpaper, object: nil, userInfo: ["id": id])
            return
        }
        guard message.name == "wpSubscribe" else { return }
        let dest = PreferencesStore.shared.libraryRoot.appendingPathComponent(id)
        if LocalWallpaperProbe.isReady(at: dest) {   // 已在库,不重复下
            Log.write("Subscribe→download: \(id) 已在库,跳过"); return
        }
        Log.write("Subscribe→download: 捕获订阅 \(id),加入下载队列")
        let onDetail = currentURL?.absoluteString.contains("id=\(id)") ?? false
        if onDetail {
            let title = pageTitle.isEmpty ? id : pageTitle
            // 先立即入队给用户反馈，文件大小只作为进度估算异步补充，绝不能阻塞下载开始。
            WorkshopAcquisition.start(id: id, title: title, subscriptionConfirmed: true)
            fetchFileSize { bytes in WorkshopDownloader.shared.updateSize(id: id, bytes: bytes) }
        } else {
            WorkshopAcquisition.start(
                id: id,
                title: "创意工坊 #\(id)",
                sizeBytes: 0,
                subscriptionConfirmed: true
            )
        }
    }

    /// 仅首次加载首页;之后切走再切回保留当前页面。
    func loadInitialIfNeeded(_ urlString: String) {
        guard !didLoad, let u = URL(string: urlString) else { return }
        didLoad = true
        wkWebView.load(URLRequest(url: u))
    }

    /// 加载指定 URL(首页工坊货架点卡片 → 在创意工坊 tab 打开该详情页)。
    /// 标记已加载,避免之后 loadInitialIfNeeded 把它冲回首页。
    func load(_ url: URL) {
        didLoad = true
        wkWebView.load(URLRequest(url: url))
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
    @available(macOS 12.0, *)
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        Log.write("WorkshopView: denied camera/microphone request (host=\(origin.host), type=\(type.rawValue))")
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { sync(loading: true) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        sync(loading: false)
        SteamWebSession.shared.refresh()
    }
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
