import AppKit
import AVFoundation
import CoreImage

/// AVFoundation 在部分 macOS/硬件组合上不能解 VP9/AV1（常见于 WE 新上传的 vp09 MP4）。
/// AVPlayerItem 对这类文件可能长期停在 `.unknown`，rate 却仍是 1，表面“正在播放”但没有任何画面。
/// 这里先检查 asset 的 playable；不支持时用 FFmpeg 后台转为 H.264，缓存结果且不改工坊源文件。
enum VideoPlaybackResolver {
    struct Resolved {
        let url: URL
        let transcoded: Bool
    }

    enum ResolveError: LocalizedError {
        case unreadable(String)
        case ffmpegMissing
        case transcodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let path): return "视频文件不可读取: \(path)"
            case .ffmpegMissing: return "系统不支持该视频编码，且未找到 FFmpeg"
            case .transcodeFailed(let detail): return "视频兼容转换失败: \(detail)"
            }
        }
    }

    private static let worker = DispatchQueue(label: "livewallpaper.video.compat", qos: .userInitiated)
    private static let lock = NSLock()
    private static var waiters: [String: [(Result<Resolved, Error>) -> Void]] = [:]

    /// 多屏会为同一壁纸各建一个 VideoRenderer；按源文件 key 合并请求，避免同时转码 N 份。
    static func resolve(_ source: URL, itemID: String,
                        completion: @escaping (Result<Resolved, Error>) -> Void) {
        let key = source.standardizedFileURL.path
        lock.lock()
        if waiters[key] != nil {
            waiters[key]!.append(completion)
            lock.unlock()
            return
        }
        waiters[key] = [completion]
        lock.unlock()

        worker.async {
            let result = resolveSynchronously(source, itemID: itemID)
            lock.lock()
            let callbacks = waiters.removeValue(forKey: key) ?? []
            lock.unlock()
            DispatchQueue.main.async {
                callbacks.forEach { $0(result) }
            }
        }
    }

    /// 供测试验证缓存失效规则；源文件大小或修改时间变化时必须换缓存名。
    static func cacheFileName(itemID: String, fileSize: UInt64, modified: TimeInterval) -> String {
        return "\(safeCacheID(itemID))-\(fileSize)-\(Int64(modified)).mp4"
    }

    private static func safeCacheID(_ itemID: String) -> String {
        String(itemID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    private static func resolveSynchronously(_ source: URL, itemID: String) -> Result<Resolved, Error> {
        guard FileManager.default.isReadableFile(atPath: source.path) else {
            return .failure(ResolveError.unreadable(source.path))
        }
        if isPlayable(source) { return .success(Resolved(url: source, transcoded: false)) }

        guard let ffmpeg = ffmpegURL() else { return .failure(ResolveError.ffmpegMissing) }
        let fm = FileManager.default
        let attrs = (try? fm.attributesOfItem(atPath: source.path)) ?? [:]
        let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.a55555.livewallpaper", isDirectory: true)
            .appendingPathComponent("VideoCompatibility", isDirectory: true)
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            return .failure(error)
        }
        let name = cacheFileName(itemID: itemID, fileSize: fileSize, modified: modified)
        let cached = base.appendingPathComponent(name)
        if fm.fileExists(atPath: cached.path), isPlayable(cached) {
            Log.write("VideoRenderer: 使用兼容缓存 \(cached.lastPathComponent)")
            return .success(Resolved(url: cached, transcoded: true))
        }

        // 同一壁纸源文件更新后清掉旧版本缓存，避免下载更新多次后无限占盘。
        let prefix = safeCacheID(itemID) + "-"
        if let old = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
            for file in old where file.lastPathComponent.hasPrefix(prefix) && file != cached {
                try? fm.removeItem(at: file)
            }
        }

        let tmp = base.appendingPathComponent(".\(UUID().uuidString).mp4")
        defer { try? fm.removeItem(at: tmp) }
        Log.write("VideoRenderer: AVFoundation 不支持 \(source.lastPathComponent)，后台转为 H.264…")
        let args = [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-i", source.path,
            "-map", "0:v:0", "-map", "0:a?",
            "-sn", "-dn",
            "-c:v", "h264_videotoolbox", "-allow_sw", "1",
            "-q:v", "65", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k",
            "-movflags", "+faststart",
            tmp.path
        ]
        let run = runProcess(ffmpeg, arguments: args)
        guard run.status == 0, fm.fileExists(atPath: tmp.path), isPlayable(tmp) else {
            let detail = run.message.isEmpty ? "FFmpeg 退出码 \(run.status)" : run.message
            return .failure(ResolveError.transcodeFailed(detail))
        }
        do {
            if fm.fileExists(atPath: cached.path) { try fm.removeItem(at: cached) }
            try fm.moveItem(at: tmp, to: cached)
            Log.write("VideoRenderer: 兼容转换完成 → \(cached.lastPathComponent)")
            return .success(Resolved(url: cached, transcoded: true))
        } catch {
            return .failure(error)
        }
    }

    private static func isPlayable(_ url: URL) -> Bool {
        let asset = AVURLAsset(url: url)
        let sem = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var value = false }
        let box = Box()
        Task {
            box.value = (try? await asset.load(.isPlayable)) ?? false
            sem.signal()
        }
        return sem.wait(timeout: .now() + 15) == .success && box.value
    }

    private static func ffmpegURL() -> URL? {
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["WP_FFMPEG"], !override.isEmpty {
            candidates.append(override)
        }
        if let bundled = Bundle.main.url(forResource: "ffmpeg", withExtension: nil)?.path {
            candidates.append(bundled)
        }
        candidates += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map(URL.init(fileURLWithPath:))
    }

    private static func runProcess(_ executable: URL, arguments: [String]) -> (status: Int32, message: String) {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = executable
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (task.terminationStatus, String(message.prefix(800)))
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}

/// 承载 AVPlayerLayer 的视图。按「屏幕适配」(wallpaperScaleMode)缩放,与场景壁纸统一:
/// 填满(cover)/黑边(fit)/拉伸(stretch)/自适应(balanced:几何中间长宽比 overscan,无黑边、不放大、形变减半)。
final class VideoPlayerView: NSView {
    let playerLayer = AVPlayerLayer()
    private let previewLayer = CALayer()
    var videoAspect: CGFloat = 0   // 视频宽/高;0=未知(自适应暂回退 cover,拿到后重排)
    var itemID: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true   // 自适应 overscan 时裁掉溢出屏幕的部分
        layerContentsRedrawPolicy = .duringViewResize
        previewLayer.frame = bounds
        previewLayer.contentsGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
        playerLayer.frame = bounds
        layer?.addSublayer(playerLayer)
        applyScale()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showPreview(_ url: URL?) {
        guard let url, let image = NSImage(contentsOf: url) else {
            previewLayer.contents = nil
            return
        }
        var rect = CGRect(origin: .zero, size: image.size)
        previewLayer.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        previewLayer.isHidden = false
    }

    func hidePreview() {
        previewLayer.isHidden = true
    }

    /// 按每壁纸 Alignment + Position 布局。Position 只在实际有裁切的轴生效。
    func applyScale() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let b = bounds
        previewLayer.frame = b
        let settings = GeneralWallpaperSettings.shared
        let mode = itemID.isEmpty ? PreferencesStore.shared.wallpaperScaleMode : settings.effectiveScaleMode(itemID)
        let p = CGFloat(itemID.isEmpty ? 0.5 : settings.position(itemID) / 100)
        if videoAspect > 0, b.width > 1, b.height > 1, mode == 0 {
            // Cover 手工 overscan，才能像 WE 一样移动裁切窗口。
            playerLayer.videoGravity = .resize
            let screenAspect = b.width / b.height
            if videoAspect >= screenAspect {
                let width = b.height * videoAspect
                setPlayerRect(CGRect(x: -(width - b.width) * p, y: 0, width: width, height: b.height))
            } else {
                let height = b.width / videoAspect
                // CoreAnimation y 向上：p=0 对齐源图顶部，p=1 对齐底部。
                setPlayerRect(CGRect(x: 0, y: -(height - b.height) * (1 - p), width: b.width, height: height))
            }
        } else if mode == 3, videoAspect > 0, b.width > 1, b.height > 1 {
            // 自适应:裁切与形变各分一半(几何中间长宽比 Ab),无黑边、不放大。比例接近(<6%)→直接铺满。
            let sa = b.width / b.height, av = videoAspect
            playerLayer.videoGravity = .resize   // 视频拉满 layer(layer 取 Ab → 仅部分形变)
            let mm = av >= sa ? av / sa : sa / av
            if mm < 1.06 {
                setPlayerRect(b)
            } else {
                let ab = (av * sa).squareRoot()
                if ab >= sa {                       // layer 比屏更宽 → 横向 overscan(裁左右)
                    let w = b.height * ab
                    setPlayerRect(CGRect(x: -(w - b.width) * p, y: 0, width: w, height: b.height))
                } else {                            // layer 比屏更高 → 纵向 overscan(裁上下)
                    let h = b.width / ab
                    setPlayerRect(CGRect(x: 0, y: -(h - b.height) * (1 - p), width: b.width, height: h))
                }
            }
        } else {
            // 1=适应 / 2=拉伸。视频比例未知时 cover 暂用系统 gravity，拿到 presentationSize 后重排。
            playerLayer.videoGravity = mode == 1 ? .resizeAspect : (mode == 2 ? .resize : .resizeAspectFill)
            setPlayerRect(b)
        }
        if let scale = window?.backingScaleFactor { playerLayer.contentsScale = scale }
        CATransaction.commit()
    }

    private func setPlayerRect(_ rect: CGRect) {
        // transform 非 identity 时 CALayer.frame 是派生值，继续写 frame 会抖动；直接写 bounds+position 可稳定翻转与布局。
        playerLayer.bounds = CGRect(origin: .zero, size: rect.size)
        playerLayer.position = CGPoint(x: rect.midX, y: rect.midY)
    }

    func applyFilters() {
        let g = GeneralWallpaperSettings.shared
        guard !itemID.isEmpty, WPEnv.vars["WP_NO_GENERAL_PROPS"] == nil else {
            playerLayer.filters = nil
            return
        }
        var filters: [CIFilter] = []
        switch g.filter(itemID) {
        case .none: break
        case .grayscale:
            if let f = CIFilter(name: "CIColorControls") {
                f.setValue(0, forKey: kCIInputSaturationKey); filters.append(f)
            }
        case .sepia:
            if let f = CIFilter(name: "CISepiaTone") {
                f.setValue(1, forKey: kCIInputIntensityKey); filters.append(f)
            }
        case .invert:
            if let f = CIFilter(name: "CIColorInvert") { filters.append(f) }
        case .warm, .cool:
            if let f = CIFilter(name: "CITemperatureAndTint") {
                f.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
                f.setValue(CIVector(x: g.filter(itemID) == .warm ? 4500 : 8500, y: 0),
                           forKey: "inputTargetNeutral")
                filters.append(f)
            }
        }
        let brightness = g.brightness(itemID)
        let contrast = g.contrast(itemID)
        let saturation = g.saturation(itemID)
        if brightness != 100 || contrast != 100 || saturation != 100,
           let f = CIFilter(name: "CIColorControls") {
            f.setValue((brightness - 100) / 100, forKey: kCIInputBrightnessKey)
            f.setValue(contrast / 100, forKey: kCIInputContrastKey)
            f.setValue(saturation / 100, forKey: kCIInputSaturationKey)
            filters.append(f)
        }
        playerLayer.filters = filters.isEmpty ? nil : filters
    }

    override func layout() {
        super.layout()
        applyScale()
    }
}

/// 视频(mp4)壁纸渲染器:AVQueuePlayer + AVPlayerLooper 实现无缝循环。
final class VideoRenderer: WallpaperRenderer {
    private var view: VideoPlayerView?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var itemObs: NSKeyValueObservation?
    private var presObs: NSKeyValueObservation?
    private var statusObs: NSKeyValueObservation?
    private var itemID: String = ""
    private var loadGeneration = 0

    func attach(to host: NSView) {
        let v = VideoPlayerView(frame: host.bounds)
        v.autoresizingMask = [.width, .height]
        host.addSubview(v)
        view = v
        v.applyScale()
    }

    func load(_ item: WallpaperItem) {
        loadGeneration &+= 1
        itemID = item.id
        view?.itemID = item.id
        view?.applyScale()
        guard let url = item.fileURL else { Log.write("VideoRenderer: nil fileURL"); return }
        view?.showPreview(item.previewURL)
        configurePlayer(url: url, sourceName: url.lastPathComponent)
    }

    /// 视频编码兼容检查/转码会读完整文件，不能堵主线程。完成回调始终回主线程，
    /// 与 DesktopController 对 loadAsync 的时序约定一致。
    func loadAsync(_ item: WallpaperItem, completion: @escaping () -> Void) {
        loadGeneration &+= 1
        let generation = loadGeneration
        itemID = item.id
        view?.itemID = item.id
        view?.applyScale()
        view?.showPreview(item.previewURL)
        guard let source = item.fileURL else {
            Log.write("VideoRenderer: nil fileURL")
            completion()
            return
        }
        VideoPlaybackResolver.resolve(source, itemID: item.id) { [weak self] result in
            guard let self, self.loadGeneration == generation else { return }
            switch result {
            case .success(let resolved):
                self.configurePlayer(url: resolved.url, sourceName: source.lastPathComponent)
                if resolved.transcoded {
                    Log.write("VideoRenderer: \(source.lastPathComponent) 使用 H.264 兼容版本播放")
                }
            case .failure(let error):
                // 保留预览图，至少不再纯黑；错误写日志供 UI/排障。
                Log.write("VideoRenderer: \(error.localizedDescription)")
            }
            completion()
        }
    }

    private func configurePlayer(url: URL, sourceName: String) {
        let exists = FileManager.default.fileExists(atPath: url.path)
        Log.write("VideoRenderer.load url=\(sourceName) playback=\(url.lastPathComponent) exists=\(exists)")
        let playerItem = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        let g = GeneralWallpaperSettings.shared
        queue.isMuted = PreferencesStore.shared.isMuted
        // 音量:全局 × per-wallpaper(0–100)。
        queue.volume = Float(PreferencesStore.shared.volume * g.volume(itemID) / 100.0)
        queue.actionAtItemEnd = .none
        looper = AVPlayerLooper(player: queue, templateItem: playerItem)
        view?.playerLayer.player = queue
        player = queue
        // 观察实际播放 item 的 presentationSize,拿到视频长宽比 → 自适应缩放(looper 播的是 templateItem 的副本,
        // 故观察 queue.currentItem 而非 templateItem)。
        itemObs = queue.observe(\.currentItem, options: [.initial, .new]) { [weak self] q, _ in
            guard let it = q.currentItem else { return }
            self?.statusObs = it.observe(\.status, options: [.initial, .new]) { [weak self] cur, _ in
                guard cur.status == .readyToPlay else {
                    if cur.status == .failed {
                        Log.write("VideoRenderer item failed: \(String(describing: cur.error))")
                    }
                    return
                }
                DispatchQueue.main.async { self?.view?.hidePreview() }
            }
            self?.presObs = it.observe(\.presentationSize, options: [.initial, .new]) { [weak self] cur, _ in
                let s = cur.presentationSize
                guard s.width > 0, s.height > 0 else { return }
                DispatchQueue.main.async {
                    self?.view?.videoAspect = s.width / s.height
                    self?.view?.applyScale()
                }
            }
        }
        applyGeneralProps()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak playerItem, weak queue] in
            Log.write("VideoRenderer status: item=\(playerItem?.status.rawValue ?? -9) err=\(String(describing: playerItem?.error)) rate=\(queue?.rate ?? -1) pres=\(queue?.currentItem?.presentationSize ?? .zero)")
        }
    }

    /// WE「属性」通用区(视频侧):翻转(水平镜像图层)+ 播放速度(rate 倍率)+ 音量(已在 load 设)。
    /// WP_NO_GENERAL_PROPS 退回:不翻转、1.0×。默认值 = 现状,零回归。
    func applyGeneralProps() {
        let off = WPEnv.vars["WP_NO_GENERAL_PROPS"] != nil
        let g = GeneralWallpaperSettings.shared
        let flip = off ? false : g.flip(itemID)
        let speed = off ? 1.0 : g.speedMultiplier(itemID)
        if let v = view {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            v.applyScale()
            // 水平镜像:绕图层中心 X 翻转(scale x=-1)。默认不翻转 → identity → 零回归。
            v.playerLayer.transform = flip ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
            v.applyFilters()
            CATransaction.commit()
        }
        // 播放速度:正在播时直接设 rate(0=暂停);否则记到 start 时用。
        if let p = player, p.rate != 0 { p.rate = Float(speed) }
    }

    func start() { player?.rate = Float(WPEnv.vars["WP_NO_GENERAL_PROPS"] != nil ? 1.0 : GeneralWallpaperSettings.shared.speedMultiplier(itemID)) }

    func stop() {
        loadGeneration &+= 1
        statusObs = nil
        presObs = nil
        itemObs = nil
        player?.pause()
        view?.playerLayer.player = nil
        view?.removeFromSuperview()
        player = nil
        looper = nil
        view = nil
    }

    /// 通用区设置改动后(翻转/速度/音量)即时生效,无需重载视频。
    func reloadInPlace() {
        let g = GeneralWallpaperSettings.shared
        player?.volume = Float(PreferencesStore.shared.volume * g.volume(itemID) / 100.0)
        applyGeneralProps()
    }

    func pause() { player?.pause() }
    func resume() {
        let speed = WPEnv.vars["WP_NO_GENERAL_PROPS"] != nil ? 1.0 : GeneralWallpaperSettings.shared.speedMultiplier(itemID)
        player?.rate = Float(speed)
    }
    func setMuted(_ muted: Bool) { player?.isMuted = muted }
    /// v = 全局音量。⚠ 必须再乘上**每壁纸音量**,否则用户给某张视频壁纸单独设的音量
    /// (如 30%)会在拖动全局音量滑条时被整体覆盖成纯全局值 → 音量突然变大,直到下次
    /// load/reloadInPlace 才恢复。load(86 行)/reloadInPlace(143 行)用的就是这个乘积。
    func setVolume(_ v: Double) {
        let g = GeneralWallpaperSettings.shared
        player?.volume = Float(v * g.volume(itemID) / 100.0)
    }
    /// 屏幕适配模式变化:重新按 wallpaperScaleMode 布局(参数保留兼容旧 videoFill 调用,实际读 scaleMode)。
    func setFillMode(_ fill: Bool) { view?.applyScale() }
}
