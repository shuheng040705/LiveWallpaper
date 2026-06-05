import AppKit
import Metal
import QuartzCore

/// Scene 壁纸渲染器:Metal 把 scene.pkg 图层合成到桌面窗口。
/// 有视差的场景用 CVDisplayLink 每帧驱动(自动漂移 + 鼠标视差);
/// 无视差(单图)场景画一次即静止,零持续开销。
/// 0 图层解码失败时回退显示 preview 图,避免黑屏。
final class SceneRenderer: WallpaperRenderer {
    private var metalLayer: CAMetalLayer?
    private var fallbackImageView: NSImageView?
    private var hostView: NSView?
    private let engine: SceneRenderEngine?
    private var loaded = false

    private var displayLink: CVDisplayLink?
    private var startTime: CFTimeInterval = 0
    private var lastRenderTime: CFTimeInterval = 0   // 帧率上限节流:上次实际渲染时刻
    private var paused = false
    private var frameCount = 0

    // 审计修复 #1:frameTick(CVDisplayLink 后台线程)的 engine.update/render 与
    // load/reloadInPlace/stop(主线程)对 engine 状态(layers/particleGroups)的重建/释放
    // 之间存在无锁数据竞争。用此锁串行化两侧对 engine 的访问。
    private let renderLock = NSLock()

    init() { engine = SceneRenderEngine() }

    func attach(to host: NSView) {
        hostView = host
        host.wantsLayer = true
        guard let engine else { return }
        let layer = CAMetalLayer()
        layer.device = engine.device
        layer.pixelFormat = .bgra8Unorm
        // ⚠ 必须显式标 sRGB 色彩空间:广色域 XDR/P3 屏上,colorspace=nil 时 WindowServer 会把我们输出的
        // .bgra8Unorm 内容当"未管理"做色彩匹配 → 整体提亮(实测 luma 146→~193)→ 全库壁纸泛白/过曝、
        // 白字被冲没对比。我们所有贴图解码+shader 都在 sRGB 域算(忠实对应 lwe 的 GL_RGBA8 非线性管线、
        // 不开 GL_FRAMEBUFFER_SRGB),所以打 sRGB tag = 告诉合成器"这些字节就是 sRGB,1:1 直出别再匹配",
        // 等价 lwe 在 X11/Wayland 上裸 sRGB 直出。⚠ 不能改成 .bgra8Unorm_srgb 像素格式——那会让 blit 再做
        // 一次 linear→sRGB 编码(内容已是 sRGB)= 反向双重编码会变暗偏色。只补 colorspace、保持像素格式不变。
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.framebufferOnly = false   // M3 Max(TBDR):true 会让 drawable 留在压缩平铺显存,桌面合成时
                                         // 平铺边界可能泄漏成网格状黑线;false 强制解析为完整线性纹理。
        layer.frame = host.bounds
        layer.contentsScale = host.window?.backingScaleFactor ?? 2.0
        host.layer?.addSublayer(layer)
        metalLayer = layer
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard let layer = metalLayer, let host = hostView else { return }
        layer.frame = host.bounds
        let scale = host.window?.backingScaleFactor ?? 2.0
        let size = CGSize(width: host.bounds.width * scale, height: host.bounds.height * scale)
        if size.width > 0 && size.height > 0 { layer.drawableSize = size }
        Log.write(String(format: "drawable: bounds=%.0fx%.0f scale=%.2f(win=%@) drawableSize=%.0fx%.0f contentsScale=%.2f",
                         host.bounds.width, host.bounds.height, scale,
                         host.window == nil ? "nil" : "ok", size.width, size.height, layer.contentsScale))
    }

    private var loadedItem: WallpaperItem?

    func load(_ item: WallpaperItem) {
        loadedItem = item
        guard let engine else { Log.write("SceneRenderer: no Metal device"); showFallback(item); return }
        guard let source = SceneSourceFactory.make(for: item),
              let doc = SceneDocument.build(from: source, item: item) else {
            Log.write("SceneRenderer: cannot open/parse scene for \(item.id)")
            showFallback(item); return
        }
        // 审计修复 #1:engine.load 会重建 layers/particleGroups,与后台 frameTick 竞争 → 持锁。
        renderLock.lock()
        engine.load(document: doc, source: source)
        renderLock.unlock()
        if engine.layerCount == 0 {
            Log.write("SceneRenderer: 0 layers decoded for \(item.id) → preview fallback")
            showFallback(item); return
        }
        loaded = true
        Log.write("SceneRenderer: \(item.title) → \(engine.layerCount) gpu layers, animated=\(engine.isAnimated)")
    }

    /// 就地重载场景文档(属性改动后),**不重建 Metal 层** → 无黑屏。
    /// 只重新解析 SceneDocument 并换进引擎。换文档期间短暂置 paused,
    /// 避免显示链后台线程正读 engine.layers 时主线程改写(数据竞争)。
    func reloadInPlace() {
        guard let engine, let item = loadedItem,
              let source = SceneSourceFactory.make(for: item),
              let doc = SceneDocument.build(from: source, item: item) else { return }
        let wasPaused = paused
        paused = true                      // 让 frameTick 在换文档期间空转
        // 审计修复 #1:换文档(重建 engine 状态)必须与后台 frameTick 互斥 → 持锁包住整段。
        renderLock.lock()
        engine.load(document: doc, source: source)
        renderLock.unlock()
        paused = wasPaused
        if !engine.isAnimated { drawOnce() }   // 静态场景:显示链没跑,手动画一帧
        Log.write("SceneRenderer: reloadInPlace \(item.id) → \(engine.layerCount) layers")
    }

    private func showFallback(_ item: WallpaperItem) {
        guard let host = hostView, let url = item.previewURL, let img = NSImage(contentsOf: url) else { return }
        metalLayer?.isHidden = true
        let iv = NSImageView(frame: host.bounds)
        iv.autoresizingMask = [.width, .height]
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.image = img
        host.addSubview(iv)
        fallbackImageView = iv
    }

    func start() {
        guard loaded, let engine else { return }
        if engine.isAnimated {
            startTime = CACurrentMediaTime()
            startDisplayLink()
        } else {
            drawOnce()   // 静态场景:画一帧即可
        }
    }

    // MARK: - 动画循环

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { Log.write("SceneRenderer: CVDisplayLink create failed → static draw"); drawOnce(); return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { (_, _, _, _, _, userInfo) -> CVReturn in
            let me = Unmanaged<SceneRenderer>.fromOpaque(userInfo!).takeUnretainedValue()
            me.frameTick()
            return kCVReturnSuccess
        }, ctx)
        CVDisplayLinkStart(link)
        displayLink = link
    }

    /// CVDisplayLink 回调(后台线程)。Metal 命令缓冲区线程安全;鼠标位置用全局函数获取。
    private func frameTick() {
        guard !paused, loaded, let engine, let layer = metalLayer else { return }
        let now = CACurrentMediaTime()
        // 帧率上限(性能/省电):CVDisplayLink 按显示器刷新率回调(120Hz 屏即 120 次/秒),
        // 这里据 frameRateCap 跳过过密的帧——壁纸是后台动效,30fps 足够且 CPU 约减半。0=不限。
        let cap = PreferencesStore.shared.frameRateCap
        if cap > 0, now - lastRenderTime < (1.0 / Double(cap)) - 0.001 { return }
        lastRenderTime = now
        let t = now - startTime

        // 鼠标相对主屏中心归一化到 [-1,1](y 向上)。
        let mouse = NSEvent.mouseLocation
        var mn = SIMD2<Float>(0, 0)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.frame
            mn.x = Float((mouse.x - f.midX) / (f.width / 2))
            mn.y = Float((mouse.y - f.midY) / (f.height / 2))
        }

        // 审计修复 #1:整段 update+render 持锁,防止主线程在此期间重建/释放 engine 状态(数据竞争)。
        // 锁内只做 GPU 命令编码(nextDrawable 可能阻塞但不回主线程同步等待),不会与主线程死锁。
        renderLock.lock()
        engine.update(time: t, mouseNorm: mn)
        // 按需渲染:无连续动画内容、视差已收敛且鼠标未动 → 画面与上帧一致,跳过渲染(空闲 CPU/GPU 趋近 0)。
        guard engine.frameDidChange else { renderLock.unlock(); return }
        guard let drawable = layer.nextDrawable() else { renderLock.unlock(); return }
        engine.render(to: drawable, viewportSize: layer.drawableSize)
        renderLock.unlock()

        frameCount += 1
        if frameCount % 180 == 1 { Log.write("SceneRenderer: frame \(frameCount) t=\(String(format: "%.1f", t))s mouse=(\(String(format: "%.2f", mn.x)),\(String(format: "%.2f", mn.y)))") }
    }

    private func drawOnce() {
        guard loaded, let engine, let layer = metalLayer else { return }
        updateDrawableSize()
        // 审计修复 #1:与 frameTick 共用 engine,持锁防竞争。
        renderLock.lock()
        engine.update(time: 0, mouseNorm: SIMD2(0, 0))
        guard let drawable = layer.nextDrawable() else { renderLock.unlock(); return }
        engine.render(to: drawable, viewportSize: layer.drawableSize)
        renderLock.unlock()
    }

    func stop() {
        engine?.releaseAudio()
        // 审计修复 #1:先停显示链,再持锁拆除 —— CVDisplayLinkStop 后持锁可确保正在执行的
        // frameTick 回调已结束(它在锁内编码),再置 nil/释放 engine 相关状态,避免拆除中竞争。
        if let link = displayLink { CVDisplayLinkStop(link) }
        renderLock.lock()
        displayLink = nil
        metalLayer?.removeFromSuperlayer()
        metalLayer = nil
        loaded = false
        renderLock.unlock()
        fallbackImageView?.removeFromSuperview()
        fallbackImageView = nil
        hostView = nil
    }

    func pause() {
        paused = true
        if let link = displayLink { CVDisplayLinkStop(link) }
        engine?.pauseVideos()
    }

    func resume() {
        paused = false
        engine?.resumeVideos()
        if let link = displayLink {
            if !CVDisplayLinkIsRunning(link) { CVDisplayLinkStart(link) }
        } else {
            drawOnce()
        }
    }

    /// 全局音量/静音(DesktopController 广播,与 VideoRenderer 一致)→ 转发到壁纸音频播放。
    func setVolume(_ v: Double) { engine?.setAudioVolume(v) }
    func setMuted(_ m: Bool) { engine?.setAudioMuted(m) }
}
