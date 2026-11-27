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
        let entry: String
        if let file = item.fileName, !file.isEmpty {
            entry = file
        } else if item.sharedPresetDependencyID != nil, item.presetVideoURL != nil {
            entry = Self.presetVideoPage
        } else {
            Log.write("WebRenderer.load: no entry file")
            return
        }
        webView?.resetPointer(release: true)
        loadedItem = item
        documentReady = false
        desktopInput?.invalidateHotspots()
        var comps = URLComponents()
        comps.scheme = Self.scheme
        comps.host = "wp"
        comps.path = "/" + entry
        guard let url = comps.url else { Log.write("WebRenderer.load: bad entry url"); return }
        Log.write("WebRenderer.load: \(url.absoluteString)")
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
        let fileBridge = item.sharedPresetDependencyID == nil ? "" : Self.presetFileBridge
        webView.callAsyncJavaScript(fileBridge + "\n" + """
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

    // Wallpaper Engine's file properties are often prefixed with "file:///" by the
    // template. Preset files already have an origin-local URL in this renderer.
    private static let presetFileBridge = #"""
        if (!window.__lwPresetFileBridge) {
            window.__lwPresetFileBridge = true;
            const normalize = value => typeof value === "string"
                ? value.replace(/file:\/+((?:lwwp:\/\/wp)\/__lw_preset_files__\/)/gi, "$1")
                : value;

            for (const type of [HTMLImageElement, HTMLMediaElement, HTMLSourceElement]) {
                const proto = type.prototype;
                const descriptor = Object.getOwnPropertyDescriptor(proto, "src");
                if (!descriptor?.set) continue;
                Object.defineProperty(proto, "src", {...descriptor, set(value) {
                    descriptor.set.call(this, normalize(value));
                }});
            }
            const set = Element.prototype.setAttribute;
            Element.prototype.setAttribute = function(name, value) {
                return set.call(this, name, normalize(value));
            };
            // Inline background images set with element.style bypass setAttribute.
            new MutationObserver(records => {
                for (const {target} of records) {
                    const style = target.getAttribute("style");
                    const fixed = normalize(style);
                    if (fixed !== style) set.call(target, "style", fixed);
                }
            }).observe(document.documentElement, {attributes:true, subtree:true, attributeFilter:["style"]});
        }
        """#

    // MARK: - WKURLSchemeHandler (经自定义 scheme 直接喂本地文件,XHR/fetch 可用)

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        // 审计修复(#7):登记为活跃 task;每次回调(didReceive/didFinish/didFail)前检查是否仍活跃,
        //   被 stop: 取消(或 renderer 已 stop)的 task 不再回调,避免 use-after-stop 崩溃。
        beginTask(urlSchemeTask)
        guard let item = loadedItem, let url = urlSchemeTask.request.url, url.host == "wp",
              let (fileData, mime) = Self.webResource(at: url, for: item) else {
            Log.write("WebRenderer.scheme: unavailable \(urlSchemeTask.request.url?.path ?? "")")
            if isTaskActive(urlSchemeTask) {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            }
            endTask(urlSchemeTask); return
        }
        var headers = ["Content-Type": mime, "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store"]
        var body = fileData
        var status = 200
        if mime.hasPrefix("video/") || mime.hasPrefix("audio/") {
            headers["Accept-Ranges"] = "bytes"
            if let range = Self.mediaRange(urlSchemeTask.request.value(forHTTPHeaderField: "Range"), count: fileData.count) {
                status = range.isEmpty ? 416 : 206
                headers["Content-Range"] = range.isEmpty ? "bytes */\(fileData.count)"
                    : "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(fileData.count)"
                body = fileData[range]
            }
        }
        headers["Content-Length"] = String(body.count)
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        // 审计修复(#7):每步回调前确认 task 仍活跃,否则提前收尾不再触碰已取消的 task。
        guard isTaskActive(urlSchemeTask) else { endTask(urlSchemeTask); return }
        urlSchemeTask.didReceive(resp)
        guard isTaskActive(urlSchemeTask) else { endTask(urlSchemeTask); return }
        if !body.isEmpty { urlSchemeTask.didReceive(body) }
        guard isTaskActive(urlSchemeTask) else { endTask(urlSchemeTask); return }
        urlSchemeTask.didFinish()
        endTask(urlSchemeTask)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // 审计修复(#7):标记取消——从活跃集合移除。进行中的 start() 回调链会在下一个检查点停下,不再调该 task。
        endTask(urlSchemeTask)
    }

    private static let presetVideoPage = "__lw_preset_video__.html"
    private static let presetVideoSource = "__lw_preset_video_source__"
    static let presetFilesPrefix = "__lw_preset_files__/"

    /// WebKit probes the media header with small byte ranges before starting playback.
    /// Return nil to serve an ordinary response, or an empty range for a valid request past EOF.
    static func mediaRange(_ header: String?, count: Int) -> Range<Int>? {
        guard let header, header.lowercased().hasPrefix("bytes=") else { return nil }
        let bounds = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }
        func byteOffset(_ value: Substring) -> Int? {
            value.allSatisfy(\.isNumber) ? Int(value) : nil
        }
        if bounds[0].isEmpty {
            guard let suffix = byteOffset(bounds[1]) else { return nil }
            return (count - min(count, suffix))..<count
        }
        guard let start = byteOffset(bounds[0]) else { return nil }
        if bounds[1].isEmpty { return min(start, count)..<count }
        guard let end = byteOffset(bounds[1]), end >= start else { return nil }
        guard start < count else { return count..<count }
        return start..<(min(end, count - 1) + 1)
    }

    private static func webResource(at url: URL, for item: WallpaperItem) -> (Data, String)? {
        // Decode exactly once so a literal percent sign in a Workshop filename survives.
        let path = String(url.path(percentEncoded: false).drop(while: { $0 == "/" }))
        let root: URL
        let file: URL
        if item.sharedPresetDependencyID != nil, item.fileName == nil, let video = item.presetVideoURL,
           path == presetVideoPage || path == presetVideoSource {
            if path == presetVideoPage {
                let html = """
                <!doctype html><meta charset="utf-8">
                <style>html,body,video{width:100%;height:100%;margin:0;background:black}video{display:block;object-fit:cover}</style>
                <video autoplay loop playsinline src="/\(presetVideoSource)"></video>
                """
                return (Data(html.utf8), "text/html; charset=utf-8")
            }
            root = item.folderURL
            file = video
        } else if item.sharedPresetDependencyID != nil, path.hasPrefix(presetFilesPrefix) {
            root = item.folderURL
            file = root.appendingPathComponent(String(path.dropFirst(presetFilesPrefix.count)))
        } else {
            root = item.contentFolderURL
            file = root.appendingPathComponent(path)
        }

        // Mounted template and preset directories retain separate containment boundaries,
        // including for symbolic links and similarly named neighbouring Workshop folders.
        let rootParts = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.pathComponents.count > rootParts.count,
              resolved.pathComponents.starts(with: rootParts),
              let data = try? Data(contentsOf: resolved, options: .mappedIfSafe) else { return nil }
        return (data, mimeType(for: resolved))
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
