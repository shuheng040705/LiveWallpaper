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

    // WE「属性」通用区·播放速度:按倍率累积 sim 时间,中途改速度也连续(直接缩放墙钟会跳变)。
    private var scaledSimTime: CFTimeInterval = 0
    private var lastWallTime: CFTimeInterval = 0

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
        // 内屏 120Hz ProMotion「3 分带」实验性修复(WP_SYNC_PRESENT gate):后台线程异步 present 与
        //   WindowServer 合成不同步 → 撕裂成横向带。presentsWithTransaction + CATransaction 包裹的同步
        //   present(见 SceneRenderEngine.render)。默认关(走旧异步路,稳);=1 时开启测试。上次没包
        //   CATransaction 导致黑屏,这次补上。
        if ProcessInfo.processInfo.environment["WP_SYNC_PRESENT"] == "1" || PreferencesStore.shared.syncPresent {
            layer.presentsWithTransaction = true
            layer.displaySyncEnabled = true        // 强制 vsync(默认本就 true,显式保证)
            layer.maximumDrawableCount = 2          // 双缓冲(默认 3)——减少在途 drawable,避免合成抓到多帧
            Log.write("SceneRenderer: 同步呈现(presentsWithTransaction+vsync+双缓冲+waitUntilCompleted)修内屏分带")
        }
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
        // ⭐内屏「3 分带」诊断(实机跑一次,把 /tmp/livewallpaper.log 里 DISPLAY-DIAG 行发我):
        //   采集这块屏的真实参数,判断分带是分辨率/缩放/native-vs-scaled/EDR/notch/刷新 哪一类。
        if let scr = host.window?.screen {
            let num = (scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let nativeW = num != 0 ? CGDisplayPixelsWide(num) : 0
            let nativeH = num != 0 ? CGDisplayPixelsHigh(num) : 0
            var modeStr = "?"
            if num != 0, let m = CGDisplayCopyDisplayMode(num) {
                modeStr = "\(m.pixelWidth)x\(m.pixelHeight)px/\(m.width)x\(m.height)pt@\(Int(m.refreshRate))Hz"
            }
            let edr = scr.maximumExtendedDynamicRangeColorComponentValue
            let potEDR = scr.maximumPotentialExtendedDynamicRangeColorComponentValue
            var safe = "0"
            if #available(macOS 12.0, *) { let i = scr.safeAreaInsets; safe = "\(Int(i.top))/\(Int(i.left))/\(Int(i.bottom))/\(Int(i.right))" }
            Log.write(String(format: "DISPLAY-DIAG name=%@ id=%u frame=%.0fx%.0f visible=%.0fx%.0f back=%.2f maxFPS=%ld nativePx=%dx%d mode=%@ EDR=%.2f/%.2f safeAreaTLBR=%@ colorspace=%@",
                             scr.localizedName, num,
                             scr.frame.width, scr.frame.height, scr.visibleFrame.width, scr.visibleFrame.height,
                             scr.backingScaleFactor, scr.maximumFramesPerSecond,
                             nativeW, nativeH, modeStr, edr, potEDR, safe,
                             (layer.colorspace?.name as String?) ?? "nil"))
        }
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
        // 3D 透视场景(太阳系/土星)走 3D 模型路径,故意清空 2D layers——此时 layerCount=0 但**不是**加载失败,
        // 有 3D 模型即成功。漏掉 has3DScene 会把 3D 场景误判为空、回退到静态预览图(土星显示成 2D 照片的真因)。
        if engine.layerCount == 0 && !engine.has3DScene {
            Log.write("SceneRenderer: 0 layers decoded for \(item.id) → preview fallback")
            showFallback(item); return
        }
        loaded = true
        applyGeneralProps()
        Log.write("SceneRenderer: \(item.title) → \(engine.layerCount) gpu layers, 3D=\(engine.has3DScene), animated=\(engine.isAnimated)")
    }

    /// 把 WE「属性」通用区(音频监听/翻转/图片筛选器/音量)推入引擎。load/reloadInPlace 与属性改动后调用。
    /// 播放速度在 frameTick 里按倍率累积 sim 时间(不在此推)。默认值 = 现状,零回归。
    private func applyGeneralProps() {
        guard let engine, let item = loadedItem else { return }
        let g = GeneralWallpaperSettings.shared
        engine.setGeneralProps(audioListen: g.audioListen(item.id),
                               flip: g.flip(item.id),
                               filter: g.filter(item.id).rawValue)
        // 音量:WE 是 per-wallpaper(0–100)。叠加全局静音/音量上限作整体乘子,喂壁纸自带 BGM 播放。
        engine.setAudioVolume(PreferencesStore.shared.volume * g.volume(item.id) / 100.0)
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
        applyGeneralProps()
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
            scaledSimTime = 0; lastWallTime = 0   // 播放速度累积器复位(避免跨次启动残留)
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
        // WE「属性」通用区·播放速度:按倍率累积 sim 时间(中途改速度连续不跳)。倍率 1.0(默认)= 现状(t=now-startTime)。
        let speed = GeneralWallpaperSettings.shared.speedMultiplier(loadedItem?.id ?? "")
        let wallDelta = lastWallTime > 0 ? (now - lastWallTime) : 0
        lastWallTime = now
        scaledSimTime += wallDelta * speed
        let t = scaledSimTime

        // 鼠标相对主屏中心归一化到 [-1,1](y 向上)。
        // ⚠ 关键(xray/视差不跟鼠标真因):本 app 是 .accessory 菜单栏代理,桌面窗口 ignoresMouseEvents=true 且
        //   canBecomeKey=false、全程无任何鼠标事件监视器 → 进程事件流为空 → `NSEvent.mouseLocation` 会**冻结**在
        //   最后一次有焦点时的值(实测卡死在 (-0.74,-0.36) 数千帧不变)→ xray 的 g_PointerPosition 恒定、揭示框不动。
        //   改用 CoreGraphics 全局硬件光标(windowserver 当前位置,不依赖本进程事件流);CG 是左上原点 y 向下,
        //   转回 AppKit 左下原点 y 向上:y = 全局顶 - cg.y(用各屏 maxY 的最大值,兼容主屏上方还有显示器的布局)。
        let cgLoc = CGEvent(source: nil)?.location ?? .zero
        let globalTop = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
        let mouse = NSPoint(x: cgLoc.x, y: globalTop - cgLoc.y)
        var mn = SIMD2<Float>(0, 0)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.frame
            mn.x = Float((mouse.x - f.midX) / (f.width / 2))
            mn.y = Float((mouse.y - f.midY) / (f.height / 2))
        }

        // 审计修复 #1:整段 update+render 持锁,防止主线程在此期间重建/释放 engine 状态(数据竞争)。
        // 锁内只做 GPU 命令编码(nextDrawable 可能阻塞但不回主线程同步等待),不会与主线程死锁。
        let _flog = ProcessInfo.processInfo.environment["WP_FRAME_LOG"] != nil
        let _t0 = _flog ? CACurrentMediaTime() : 0
        renderLock.lock()
        engine.update(time: t, mouseNorm: mn)
        let _tU = _flog ? CACurrentMediaTime() : 0
        // 按需渲染:无连续动画内容、视差已收敛且鼠标未动 → 画面与上帧一致,跳过渲染(空闲 CPU/GPU 趋近 0)。
        guard engine.frameDidChange else { renderLock.unlock(); return }
        guard let drawable = layer.nextDrawable() else { renderLock.unlock(); return }
        let _tD = _flog ? CACurrentMediaTime() : 0
        engine.render(to: drawable, viewportSize: layer.drawableSize)
        renderLock.unlock()
        if _flog {
            let total = (CACurrentMediaTime() - _t0) * 1000
            if total > 20 {   // 只报慢帧(>20ms=掉帧)
                let upd = (_tU - _t0) * 1000, drw = (_tD - _tU) * 1000, rnd = (CACurrentMediaTime() - _tD) * 1000
                FileHandle.standardError.write("WPF f\(frameCount) t=\(String(format:"%.1f",t))s total=\(String(format:"%.0f",total))ms [upd=\(String(format:"%.0f",upd)) drawable=\(String(format:"%.0f",drw)) render=\(String(format:"%.0f",rnd))]\n".data(using:.utf8)!)
            }
        }

        frameCount += 1
        if frameCount % 180 == 1 {
            let d = engine.debugCursorInfo
            Log.write("SceneRenderer: frame \(frameCount) t=\(String(format: "%.1f", t))s mouse=(\(String(format: "%.2f", mn.x)),\(String(format: "%.2f", mn.y))) drawable=\(Int(layer.drawableSize.width))x\(Int(layer.drawableSize.height)) aspectMouse=(\(String(format: "%.3f", d.aspect.x)),\(String(format: "%.3f", d.aspect.y))) cursorUV=(\(String(format: "%.3f", d.cursorUV.x)),\(String(format: "%.3f", d.cursorUV.y))) canvas=\(Int(d.canvas.x))x\(Int(d.canvas.y))")
        }
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
