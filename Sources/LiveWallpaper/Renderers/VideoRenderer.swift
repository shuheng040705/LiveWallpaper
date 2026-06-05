import AppKit
import AVFoundation

/// 承载 AVPlayerLayer 的视图,layout 时保持图层填满。
final class VideoPlayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        playerLayer.videoGravity = .resizeAspectFill   // 铺满、按比例裁切
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        playerLayer.frame = bounds
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        // 禁隐式动画(避免 frame 变化时图层动画到错误尺寸的瞬态)+ 跟随屏幕 backing scale(Retina)。
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        if let scale = window?.backingScaleFactor { playerLayer.contentsScale = scale }
        CATransaction.commit()
    }
}

/// 视频(mp4)壁纸渲染器:AVQueuePlayer + AVPlayerLooper 实现无缝循环。
final class VideoRenderer: WallpaperRenderer {
    private var view: VideoPlayerView?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?

    func attach(to host: NSView) {
        let v = VideoPlayerView(frame: host.bounds)
        v.autoresizingMask = [.width, .height]
        v.playerLayer.videoGravity = PreferencesStore.shared.videoFill ? .resizeAspectFill : .resizeAspect
        host.addSubview(v)
        view = v
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak playerItem, weak queue] in
            Log.write("VideoRenderer status: item=\(playerItem?.status.rawValue ?? -9) err=\(String(describing: playerItem?.error)) rate=\(queue?.rate ?? -1)")
        }
    }

    func start() { player?.play() }

    func stop() {
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
    func setFillMode(_ fill: Bool) { view?.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect }
}
