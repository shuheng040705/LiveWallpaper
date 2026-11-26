import AppKit
import Combine
import WebKit
import UniformTypeIdentifiers

/// 网页(index.html)壁纸渲染器。
///
/// 关键:WKWebView 用 `loadFileURL` 加载 file:// 页面时,页面对 file:// 子资源的
/// XMLHttpRequest / fetch 会被同源策略拦截(NetworkError)。WE 网页壁纸(如 Spine、
/// PIXI、Live2D)几乎都用 XHR/fetch 加载 .skel/.atlas/.json/.glsl 等资源,因此在
/// file:// 下会"加载成功但全黑、不动"。
///
/// 解决:用自定义 scheme(lwwp://)经 WKURLSchemeHandler 直接喂文件。自定义 scheme 是
/// 一个正常 origin,XHR/fetch 遵守普通同源规则,可正常读取同目录资源。
final class WebRenderer: NSObject, WallpaperRenderer, WKNavigationDelegate, WKURLSchemeHandler, WKUIDelegate {

    static let scheme = "lwwp"          // Live Wallpaper Web Project

    private var webView: WebWallpaperView?
    private var desktopInput: WallpaperDesktopInput?
    private var hostPaused = false
    private var mediaSuspended = false
    private var masterMuted = PreferencesStore.shared.isMuted
    private var masterVolume = PreferencesStore.shared.volume
    private var rootURL: URL?           // 壁纸文件夹(资源根)
    private var loadedItem: WallpaperItem?
    private var documentReady = false
    private var frameRateObserver: AnyCancellable?
    private var lastFrameRate: Int?

    /// 审计修复(#7):进行中的 scheme task 集合 + 已取消标记。WKWebView 在 stop()/导航中断时会调
    ///   webView(_:stop:) 取消进行中的 task;此后再调该 task 的 didReceive/didFinish 会崩。
    ///   这里登记活跃 task,stop 回调时标记取消,每次回调前检查,已取消则跳过。用 ObjectIdentifier 当 key
    ///   (WKURLSchemeTask 非 Hashable),lock 保护跨线程访问。
    private var activeTasks = Set<ObjectIdentifier>()
    private let taskLock = NSLock()

    private func beginTask(_ task: WKURLSchemeTask) {
        taskLock.lock(); activeTasks.insert(ObjectIdentifier(task)); taskLock.unlock()
    }
    /// 该 task 是否仍活跃(未被 stop 取消)。回调前调用。
    private func isTaskActive(_ task: WKURLSchemeTask) -> Bool {
        taskLock.lock(); defer { taskLock.unlock() }; return activeTasks.contains(ObjectIdentifier(task))
    }
    private func endTask(_ task: WKURLSchemeTask) {
        taskLock.lock(); activeTasks.remove(ObjectIdentifier(task)); taskLock.unlock()
    }

    func attach(to host: NSView) {
        host.wantsLayer = true
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []   // 允许自动播放
        config.setURLSchemeHandler(self, forURLScheme: Self.scheme)
        WebMediaCapturePolicy.install(into: config.userContentController)
        WebWallpaperHotspots.install(in: config.userContentController)
        config.userContentController.addUserScript(WKUserScript(source: WebWallpaperMedia.script,
            injectionTime: .atDocumentStart, forMainFrameOnly: true))

        // 注入最小 Wallpaper Engine 运行时垫片:很多 WE 网页壁纸在 wallpaperPropertyListener
        // 被调用(applyUserProperties)后才设置背景/初始化,WE 启动时会调一次。这里在文档开始
        // 时占位,待属性就绪后由 applyProperties() 派发。
        let weShim = WKUserScript(source: """
        (function(){
          if (window.wallpaperRegisterAudioListener) return;
          window.wallpaperRegisterAudioListener = function(){};
          window.wallpaperRequestRandomFileForProperty = function(){};
          window.wallpaperRegisterMediaPropertiesListener = function(){};
          window.wallpaperRegisterMediaThumbnailListener = function(){};
          window.wallpaperRegisterMediaTimelineListener = function(){};
          window.wallpaperRegisterMediaPlaybackListener = function(){};
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(weShim)

        let wv = WebWallpaperView(frame: host.bounds, configuration: config)
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = self
        // Web 壁纸是不受信任的第三方内容。它可以播放已有媒体，但绝不允许通过 getUserMedia
        // 打开 Mac 的摄像头或麦克风，否则仅启动壁纸就会抢占微信/FaceTime 的设备。
        wv.uiDelegate = self
        wv.setValue(false, forKey: "drawsBackground")          // 透明背景(失败也无妨)
        host.addSubview(wv)
        webView = wv
        frameRateObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: UserDefaults.standard)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyGeneralProperties() }
        if host.window is DesktopWindow {
            desktopInput = WallpaperDesktopInput(webView: wv) { [weak self] in
                guard let self else { return false }
                return self.documentReady && !self.hostPaused
            }
        }
        Log.write("WebRenderer.attach: webView added bounds=\(NSStringFromRect(host.bounds)) window=\(host.window == nil ? "nil" : "ok")")
    }

    func load(_ item: WallpaperItem) {
        guard let entry = item.fileName, !entry.isEmpty else { Log.write("WebRenderer.load: no entry file"); return }
        webView?.resetPointer(release: true)
        rootURL = item.folderURL
        loadedItem = item
        documentReady = false
        desktopInput?.invalidateHotspots()
        // 经自定义 scheme 加载入口页:lwwp://wp/<index.html>
        var comps = URLComponents()
        comps.scheme = Self.scheme
        comps.host = "wp"
        comps.path = "/" + entry
        guard let url = comps.url else { Log.write("WebRenderer.load: bad entry url"); return }
        let exists = FileManager.default.fileExists(atPath: item.folderURL.appendingPathComponent(entry).path)
        Log.write("WebRenderer.load: \(url.absoluteString) entryExists=\(exists)")
        webView?.load(URLRequest(url: url))
    }

    func start() {}

    func reloadInPlace() {
        desktopInput?.invalidateHotspots()
        applyProperties()
        applyMediaVolume()
    }

    func stop() {
        frameRateObserver = nil
        desktopInput?.stop()
        desktopInput = nil
        webView?.resetPointer(release: true)
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        rootURL = nil
        loadedItem = nil
        documentReady = false
        hostPaused = false
        mediaSuspended = false
        // 审计修复(#7):清空活跃 task 登记。停止后即使 WebKit 漏调 stop:,任何残留回调也会因不在集合里被跳过。
        taskLock.lock(); activeTasks.removeAll(); taskLock.unlock()
    }

    func pause() {
        guard !hostPaused else { return }
        hostPaused = true
        webView?.resetPointer(release: true)
        desktopInput?.invalidateHotspots()
        if let webView { notifyPagePaused(in: webView) }
    }

    func resume() {
        guard hostPaused else { return }
        hostPaused = false
        guard let webView else { return }
        if mediaSuspended {
            mediaSuspended = false
            webView.setAllMediaPlaybackSuspended(false) { [weak self, weak webView] in
                guard let self, let webView, self.webView === webView, !self.hostPaused else { return }
                self.notifyPagePaused(in: webView)
            }
        } else {
            notifyPagePaused(in: webView)
        }
    }

    private func notifyPagePaused(in view: WKWebView) {
        let paused = hostPaused
        let js = """
        (() => {
            const listener = window.wallpaperPropertyListener;
            if (typeof listener?.setPaused === 'function') listener.setPaused(\(paused));
            else {
                document.dispatchEvent(new Event('visibilitychange'));
                window.dispatchEvent(new Event('\(paused ? "blur" : "focus")'));
            }
        })()
        """
        view.evaluateJavaScript(js) { [weak self, weak view] _, _ in
            guard let self, let view, self.webView === view,
                  paused, self.hostPaused, !self.mediaSuspended else { return }
            // Let the wallpaper remember which voice was playing before WebKit suspends it.
            self.mediaSuspended = true
            view.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        }
    }

    func setMuted(_ muted: Bool) {
        masterMuted = muted
        applyMediaVolume()
    }

    func setVolume(_ v: Double) {
        masterVolume = v
        applyMediaVolume()
    }

    private func applyMediaVolume() {
        let localVolume = loadedItem.map { GeneralWallpaperSettings.shared.volume($0.id) / 100 } ?? 1
        let gain = masterMuted ? 0 : min(1, max(0, masterVolume * localVolume))
        webView?.evaluateJavaScript("window.__lwSetMediaGain?.(\(gain))", completionHandler: nil)
    }

    // MARK: - WKNavigationDelegate

    @available(macOS 12.0, *)
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        Log.write("WebRenderer: denied camera/microphone request from web wallpaper (host=\(origin.host), type=\(type.rawValue))")
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        (webView as? WebWallpaperView)?.resetPointer(release: false)
        documentReady = false
        desktopInput?.invalidateHotspots()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        documentReady = true
        lastFrameRate = nil
        applyGeneralProperties()
        Log.write("WebRenderer: didFinish \(webView.url?.absoluteString ?? "nil")")
        applyProperties()
        applyMediaVolume()
        if hostPaused { notifyPagePaused(in: webView) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.write("WebRenderer: didFail \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Log.write("WebRenderer: didFailProvisional \(error.localizedDescription)")
    }

    private func applyGeneralProperties() {
        guard documentReady, let webView else { return }
        let cap = PreferencesStore.shared.frameRateCap
        let screen = webView.window?.screen ?? NSScreen.main
        // Authors commonly calculate 1000 / fps. With no cap, WebKit paints at the display rate.
        let refreshRate = screen?.maximumFramesPerSecond ?? 60
        let fps = cap > 0 ? cap : (refreshRate > 0 ? refreshRate : 60)
        guard fps != lastFrameRate else { return }
        lastFrameRate = fps
        webView.callAsyncJavaScript("""
            const state = window.__lwGeneralPropertyState ??= { revision: 0 };
            const revision = ++state.revision;
            for (const delay of [0, 50, 150, 400, 1000, 2500, 5000, 10000, 20000]) {
                if (delay) await new Promise(resolve => setTimeout(resolve, delay));
                if (revision !== state.revision) return;
                const listener = window.wallpaperPropertyListener;
                if (typeof listener?.applyGeneralProperties === 'function') {
                    listener.applyGeneralProperties({fps});
                    return;
                }
            }
            """, arguments: ["fps": fps], in: nil, in: .page) { result in
            if case .failure(let error) = result {
                Log.write("WebRenderer: applyGeneralProperties failed: \(error.localizedDescription)")
            }
        }
    }

    /// 首次派发完整属性，之后只派发变化的项。切换预设或恢复默认无需重新加载网页。
    private func applyProperties() {
        guard documentReady, let item = loadedItem, let webView else { return }
        let properties = WallpaperPropertyStore.shared.webProperties(for: item)
        webView.callAsyncJavaScript("""
            const state = window.__lwUserPropertyState ??= { revision: 0 };
            const revision = ++state.revision;
            // 有些项目会等资源准备好才注册回调。在等待期间发生的修改由最新调用接管。
            for (const delay of [0, 50, 150, 400, 1000, 2500, 5000, 10000, 20000]) {
                if (delay) await new Promise(resolve => setTimeout(resolve, delay));
                if (revision !== state.revision) return;
                const listener = window.wallpaperPropertyListener;
                if (typeof listener?.applyUserProperties !== 'function') continue;
                const first = state.listener !== listener;
                const values = Object.create(null);
                const changes = [];
                for (const [key, prop] of Object.entries(properties)) {
                    values[key] = JSON.stringify([prop.type, prop.value]);
                    if (first || state.values[key] !== values[key]) changes.push([key, prop]);
                }
                if (first || changes.length) listener.applyUserProperties(Object.fromEntries(changes));
                state.listener = listener;
                state.values = values;
                return;
            }
            """, arguments: ["properties": properties], in: nil, in: .page) { result in
            if case .failure(let error) = result {
                Log.write("WebRenderer: applyUserProperties failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - WKURLSchemeHandler (经自定义 scheme 直接喂本地文件,XHR/fetch 可用)

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        // 审计修复(#7):登记为活跃 task;每次回调(didReceive/didFinish/didFail)前检查是否仍活跃,
        //   被 stop: 取消(或 renderer 已 stop)的 task 不再回调,避免 use-after-stop 崩溃。
        beginTask(urlSchemeTask)
        guard let root = rootURL, let url = urlSchemeTask.request.url else {
            if isTaskActive(urlSchemeTask) {
                urlSchemeTask.didFailWithError(NSError(domain: "lwwp", code: -1))
            }
            endTask(urlSchemeTask); return
        }
        // 用 path 解析相对资源(去掉前导 /,按文件夹根拼接);防目录穿越。
        var rel = url.path
        if rel.hasPrefix("/") { rel.removeFirst() }
        rel = rel.removingPercentEncoding ?? rel
        // ⚠ 安全(审计):必须 **resolvingSymlinksInPath** 后再比对,且按**路径分量**比对而非裸 hasPrefix。
        //   ① standardizedFileURL 只消 `.`/`..`,**不解析符号链接** → 壁纸包里放一个指向包外的软链接
        //      (如 link → ~/.ssh),`lwwp://wp/link/id_rsa` 就能被 Data(contentsOf:) 跟随读出;而响应头
        //      写死 `Access-Control-Allow-Origin: *`、页面本身能发外网请求 → 可外传。进程无沙箱,读取面
        //      是整个用户目录。
        //   ② 裸 hasPrefix 没有分量边界:root=…/123456789 时 `…/1234567890/x` 也算通过(工坊 id 是数字,
        //      天然容易前缀碰撞)。改用 path components 前缀比对。
        //   另注:url.path 本身已解码一次,下面又 removingPercentEncoding = 双重解码,`%252e%252e` 能把
        //   `..` 送进 rel —— 分量比对同时挡住这条。
        let realRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let fileURL = root.appendingPathComponent(rel).standardizedFileURL.resolvingSymlinksInPath()
        let rootParts = realRoot.pathComponents
        let fileParts = fileURL.pathComponents
        let insideRoot = fileParts.count >= rootParts.count && Array(fileParts.prefix(rootParts.count)) == rootParts
        // TODO(性能):此处 Data(contentsOf:) 同步整文件读入内存,大资源(视频/wasm/纹理)会阻塞且占内存;
        //   后续可改为按需 mmap / 分块流式喂(didReceive 多段)。本次审计不改。
        guard insideRoot,
              let fileData = try? Data(contentsOf: fileURL) else {
            Log.write("WebRenderer.scheme: 404 \(rel)")
            if isTaskActive(urlSchemeTask) {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            }
            endTask(urlSchemeTask); return
        }
        let mime = Self.mimeType(for: fileURL)
        let resp = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mime,
                "Content-Length": String(fileData.count),
                "Access-Control-Allow-Origin": "*",
                "Cache-Control": "no-store"
            ]
        )!
        // 审计修复(#7):每步回调前确认 task 仍活跃,否则提前收尾不再触碰已取消的 task。
        guard isTaskActive(urlSchemeTask) else { endTask(urlSchemeTask); return }
        urlSchemeTask.didReceive(resp)
        guard isTaskActive(urlSchemeTask) else { endTask(urlSchemeTask); return }
        urlSchemeTask.didReceive(fileData)
        guard isTaskActive(urlSchemeTask) else { endTask(urlSchemeTask); return }
        urlSchemeTask.didFinish()
        endTask(urlSchemeTask)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // 审计修复(#7):标记取消——从活跃集合移除。进行中的 start() 回调链会在下一个检查点停下,不再调该 task。
        endTask(urlSchemeTask)
    }

    private static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs":   return "text/javascript; charset=utf-8"
        case "css":         return "text/css; charset=utf-8"
        case "json":        return "application/json; charset=utf-8"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "svg":         return "image/svg+xml"
        case "mp4":         return "video/mp4"
        case "webm":        return "video/webm"
        case "ogg", "oga":  return "audio/ogg"
        case "ogv":         return "video/ogg"
        case "mp3":         return "audio/mpeg"
        case "wav":         return "audio/wav"
        case "wasm":        return "application/wasm"
        case "atlas", "skel", "txt": return "text/plain; charset=utf-8"
        case "ttf":         return "font/ttf"
        case "woff":        return "font/woff"
        case "woff2":       return "font/woff2"
        default:
            if let ut = UTType(filenameExtension: ext), let m = ut.preferredMIMEType { return m }
            return "application/octet-stream"
        }
    }
}

private extension WallpaperDesktopInput {
    convenience init(webView: WebWallpaperView, isEnabled: @escaping () -> Bool) {
        self.init(view: webView, isEnabled: { [weak webView] in
            isEnabled() && webView?.url?.scheme == WebRenderer.scheme && webView?.url?.host == "wp"
        }, readHotspots: { [weak webView] point, completion in
            guard let webView else { completion([]); return }
            WebWallpaperHotspots.read(in: webView, at: point, completion: completion)
        }, onPointer: { [weak webView] phase, point, count in
            webView?.send(phase, at: point, clickCount: count)
        })
    }
}
