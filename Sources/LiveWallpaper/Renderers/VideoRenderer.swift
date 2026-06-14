import AppKit
import AVFoundation

/// 承载 AVPlayerLayer 的视图。按「屏幕适配」(wallpaperScaleMode)缩放,与场景壁纸统一:
/// 填满(cover)/黑边(fit)/拉伸(stretch)/自适应(balanced:几何中间长宽比 overscan,无黑边、不放大、形变减半)。
final class VideoPlayerView: NSView {
    let playerLayer = AVPlayerLayer()
    var videoAspect: CGFloat = 0   // 视频宽/高;0=未知(自适应暂回退 cover,拿到后重排)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true   // 自适应 overscan 时裁掉溢出屏幕的部分
        layerContentsRedrawPolicy = .duringViewResize
        playerLayer.frame = bounds
        layer?.addSublayer(playerLayer)
        applyScale()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 按 wallpaperScaleMode + 视频长宽比布局 playerLayer。
    func applyScale() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let b = bounds
        let mode = PreferencesStore.shared.wallpaperScaleMode
        if mode == 3, videoAspect > 0, b.width > 1, b.height > 1 {
            // 自适应:裁切与形变各分一半(几何中间长宽比 Ab),无黑边、不放大。比例接近(<6%)→直接铺满。
            let sa = b.width / b.height, av = videoAspect
            playerLayer.videoGravity = .resize   // 视频拉满 layer(layer 取 Ab → 仅部分形变)
            let mm = av >= sa ? av / sa : sa / av
            if mm < 1.06 {
                playerLayer.frame = b
            } else {
                let ab = (av * sa).squareRoot()
                if ab >= sa {                       // layer 比屏更宽 → 横向 overscan(裁左右)
                    let w = b.height * ab
                    playerLayer.frame = CGRect(x: (b.width - w) / 2, y: 0, width: w, height: b.height)
                } else {                            // layer 比屏更高 → 纵向 overscan(裁上下)
                    let h = b.width / ab
                    playerLayer.frame = CGRect(x: 0, y: (b.height - h) / 2, width: b.width, height: h)
                }
            }
        } else {
            // 0=填满 cover / 1=黑边 fit / 2=拉伸 stretch(自适应但视频比例未知时也回退到 cover)
            playerLayer.videoGravity = mode == 1 ? .resizeAspect : (mode == 2 ? .resize : .resizeAspectFill)
            playerLayer.frame = b
        }
        if let scale = window?.backingScaleFactor { playerLayer.contentsScale = scale }
        CATransaction.commit()
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

    func attach(to host: NSView) {
        let v = VideoPlayerView(frame: host.bounds)
        v.autoresizingMask = [.width, .height]
        host.addSubview(v)
        view = v
        v.applyScale()
    }

    func load(_ item: WallpaperItem) {
        guard let url = item.fileURL else { Log.write("VideoRenderer: nil fileURL"); return }
        let exists = FileManager.default.fileExists(atPath: url.path)
        Log.write("VideoRenderer.load url=\(url.lastPathComponent) exists=\(exists)")
        let playerItem = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = PreferencesStore.shared.isMuted
        queue.volume = Float(PreferencesStore.shared.volume)
        queue.actionAtItemEnd = .none
        looper = AVPlayerLooper(player: queue, templateItem: playerItem)
        view?.playerLayer.player = queue
        player = queue
        // 观察实际播放 item 的 presentationSize,拿到视频长宽比 → 自适应缩放(looper 播的是 templateItem 的副本,
        // 故观察 queue.currentItem 而非 templateItem)。
        itemObs = queue.observe(\.currentItem, options: [.initial, .new]) { [weak self] q, _ in
            guard let it = q.currentItem else { return }
            self?.presObs = it.observe(\.presentationSize, options: [.initial, .new]) { [weak self] cur, _ in
                let s = cur.presentationSize
                guard s.width > 0, s.height > 0 else { return }
                DispatchQueue.main.async {
                    self?.view?.videoAspect = s.width / s.height
                    self?.view?.applyScale()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak playerItem, weak queue] in
            Log.write("VideoRenderer status: item=\(playerItem?.status.rawValue ?? -9) err=\(String(describing: playerItem?.error)) rate=\(queue?.rate ?? -1) pres=\(queue?.currentItem?.presentationSize ?? .zero)")
        }
    }

    func start() { player?.play() }

    func stop() {
        presObs = nil
        itemObs = nil
        player?.pause()
        view?.playerLayer.player = nil
        view?.removeFromSuperview()
        player = nil
        looper = nil
        view = nil
    }

    func pause() { player?.pause() }
    func resume() { player?.play() }
    func setMuted(_ muted: Bool) { player?.isMuted = muted }
    func setVolume(_ v: Double) { player?.volume = Float(v) }
    /// 屏幕适配模式变化:重新按 wallpaperScaleMode 布局(参数保留兼容旧 videoFill 调用,实际读 scaleMode)。
    func setFillMode(_ fill: Bool) { view?.applyScale() }
}
