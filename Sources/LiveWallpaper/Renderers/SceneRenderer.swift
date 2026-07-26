import AppKit
import Metal
import QuartzCore

/// CoreGraphics 的全局光标是“主显示器左上为原点、y 向下”，AppKit 的窗口 frame 是
/// “主显示器左下为原点、y 向上”。先统一坐标系，再相对当前壁纸窗口归一化；不能按“光标当前所在屏”
/// 重新取中心，否则所有显示器实例会同时收到同一组局部坐标。
enum WEMouseViewportMath {
    static func appKitPoint(fromQuartz point: CGPoint, mainDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: mainDisplayHeight - point.y)
    }

    static func normalized(point: CGPoint, viewport: CGRect) -> SIMD2<Float> {
        guard viewport.width > 0, viewport.height > 0 else { return .zero }
        let x = (point.x - viewport.midX) / (viewport.width * 0.5)
        let y = (point.y - viewport.midY) / (viewport.height * 0.5)
        return SIMD2(
            Float(min(1, max(-1, x))),
            Float(min(1, max(-1, y)))
        )
    }
}

/// JavaScriptCore 在完整 `engine.update → 图层脚本 → 文本刷新` 调用链里需要明显大于
/// GCD 工作线程默认约 512KB 的栈。这个执行器提供单一 8MB 栈线程和最小 async 接口。
private final class LargeStackSerialExecutor {
    private final class State {
        let condition = NSCondition()
        var jobs: [() -> Void] = []
        var stopped = false
    }

    private let state = State()
    private let thread: Thread

    init(label: String) {
        let state = self.state
        thread = Thread {
            while true {
                let job: (() -> Void)?
                state.condition.lock()
                while state.jobs.isEmpty && !state.stopped { state.condition.wait() }
                if state.stopped {
                    state.jobs.removeAll()
                    state.condition.unlock()
                    return
                }
                job = state.jobs.removeFirst()
                state.condition.unlock()
                if let job { autoreleasepool(invoking: job) }
            }
        }
        thread.name = label
        thread.qualityOfService = .userInteractive
        thread.stackSize = 8 * 1024 * 1024
        thread.start()
    }

    @discardableResult
    func async(_ job: @escaping () -> Void) -> Bool {
        state.condition.lock()
        guard !state.stopped else {
            state.condition.unlock()
            return false
        }
        state.jobs.append(job)
        state.condition.signal()
        state.condition.unlock()
        return true
    }

    func shutdown() {
        state.condition.lock()
        state.stopped = true
        state.jobs.removeAll()
        state.condition.broadcast()
        state.condition.unlock()
    }

    deinit { shutdown() }
}

/// CVDisplayLink 回调上下文:生命周期独立于 SceneRenderer 的堆盒子,内部 **weak** 持有 renderer。
/// 显示链回调跑在 CoreVideo 私有线程,而 renderer 可能在 stop() 返回后立刻被释放;把 weak 引用放进
/// 一个单独 retain 的盒子里,回调就永远只触碰活着的内存(renderer 没了 → owner 为 nil → 空跑)。
private final class LinkContext {
    weak var owner: SceneRenderer?
    init(_ owner: SceneRenderer) { self.owner = owner }
}

/// Scene 壁纸渲染器:Metal 把 scene.pkg 图层合成到桌面窗口。
/// 有视差的场景用 CVDisplayLink 每帧驱动(自动漂移 + 鼠标视差);
/// 无视差(单图)场景画一次即静止,零持续开销。
/// 0 图层解码失败时回退显示 preview 图,避免黑屏。
final class SceneRenderer: WallpaperRenderer {
    private var metalLayer: CAMetalLayer?
    private var fallbackImageView: NSView?
    private var hostView: NSView?
    private let engine: SceneRenderEngine?
    private var loaded = false

    private var displayLink: CVDisplayLink?
    /// CVDisplayLink 回调上下文盒子(passRetained 的裸指针);stop() 里释放。见 startDisplayLink 的说明。
    private var linkContext: UnsafeMutableRawPointer?
    private var startTime: CFTimeInterval = 0
    private var lastRenderTime: CFTimeInterval = 0   // 帧率上限节流:上次实际渲染时刻
    private var paused = false
    private var frameCount = 0
    private var lastTickWall: CFTimeInterval = 0      // 卡顿诊断:上次 frameTick 回调墙钟
    private let stutterLog = true                     // 常开:仅 >0.3s 掉帧才写日志(正常播放零噪声),供诊断台前调度卡顿
    // 台前调度切换卡顿真因(诊断铁证 FRAMEGAP 1s paused=N link=run):macOS 在台前调度切换/过场时会节流
    //   (被遮挡/过场的)桌面壁纸窗口的 CVDisplayLink 回调(回调间隔可达 ~1s,而显示链仍 isRunning=true)。
    //   非我们暂停、非我们停链 → 暂停逻辑修不到。正解=备用计时器在显示链回调停滞时接管渲染,桥过卡顿。
    private var lastLinkTick: CFTimeInterval = 0      // 仅 CVDisplayLink 回调更新(区别于 lastTickWall=任一驱动)
    private var stallTimer: DispatchSourceTimer?       // 备用渲染驱动:显示链被系统节流时接管
    /// CVDisplayLink 回调是 CoreVideo 的实时小栈线程，不适合直接跑 JavaScriptCore/Metal/AppKit。
    /// 所有帧工作投递到大栈串行线程；帧门(tickLock+tickInFlight)在投递前非阻塞抢占，上一帧尚未结束时直接丢帧，
    /// 避免显示链 120Hz 把队列堆成长尾。
    private let frameQueue = LargeStackSerialExecutor(label: "com.a55555.livewallpaper.scene-frame")
    // ⚠ 不用 DispatchSemaphore(与下面 drawableInflight 同一条铁律,2026-07-26 审计发现这里漏了一处)。
    //   闭包里强捕获 gate 只保护了「任务已在执行」的情况;真正的洞是任务**被 shutdown() 丢弃**:
    //   scheduleFrameTick 已经 wait 减到 0,而 LargeStackSerialExecutor.shutdown() 的 jobs.removeAll()
    //   把任务连同 defer{gate.signal()} 一起丢掉 → signal 永不发生,同时丢弃闭包又释放了对信号量的最后
    //   一个强引用 → 计数 0 < 初始 1 → `_dispatch_semaphore_dispose` SIGTRAP（切壁纸偶发闪退）。
    //   切壁纸路径 `renderers.forEach { $0.stop() }; renderers.removeAll()` 每次都会走到 deinit。
    //   改 NSLock+Bool:Bool 无析构约束;任务被丢弃最坏只是旗标滞留(stop() 后本实例不再复用，且
    //   stop() 末尾显式复位),不会崩。
    private let tickLock = NSLock()
    private var tickInFlight = false
    // 台前调度切换卡顿真正的阻塞点:`nextDrawable()`。过场时 WindowServer 暂停合成我们(桌面层)窗口 →
    //   已 present 的 drawable 不被消费释放 → maximumDrawableCount 个槽全占满 → 下一次 nextDrawable 阻塞 ~1s
    //   (FRAMEGAP 1s 真因;engine 的在途信号量在 nextDrawable 之后,管不到)。修:nextDrawable 前先过此「在途门」
    //   (值=maximumDrawableCount),槽满则短超时**跳帧**而非阻塞;drawable 真正 present 后 addPresentedHandler 还槽。
    //   值在 layer 建好后按真实 maximumDrawableCount 设(默认 3,同步呈现路径 2)。
    //   ⚠ 不用 DispatchSemaphore:它的 signal 在 addPresentedHandler 异步触发,切壁纸析构时若仍有 drawable 在途
    //   (wait 已减、present 回调未触发)→ 计数<初始 → `_dispatch_semaphore_dispose` SIGTRAP 崩溃(实测)。
    //   改用 NSLock + 普通容器:满则立即跳帧(非阻塞),无析构约束;在途 handler 用 weak self,析构后空跑。
    //   2026-07-26 审计 R7 再改进:由 Int 计数器换成 token 字典,以支持「超时未归还则兜底回收」——
    //   见 acquireDrawable(纯计数器无法区分迟到回调与丢失回调,回收会造成二次递减)。
    private let drawableLock = NSLock()
    /// 在途槽:token → 占用时刻。用字典而非计数器,才能让「兜底回收」与「迟到的 present 回调」
    /// 互不干扰(见 acquireDrawable)。在途数 = drawableSlots.count。
    private var drawableSlots: [Int: CFTimeInterval] = [:]
    private var nextDrawableToken = 0
    /// 超过这个时长仍未归还的槽,认定 present 回调已丢失并强制回收。取 2s:远大于任何正常呈现延迟
    /// (30fps 一帧 33ms),也大于台前调度过场时 present 停滞的量级(~1s)——那期间本就该跳帧,
    /// 不会误触发;只有真正丢失的回调才会被回收。
    private static let drawableStaleTimeout: CFTimeInterval = 2.0
    private var lastStaleReclaimLog: CFTimeInterval = 0
    private var drawableMax = 3
    private var lastDrawableFailureLog: CFTimeInterval = 0

    // WE「属性」通用区·播放速度:按倍率累积 sim 时间,中途改速度也连续(直接缩放墙钟会跳变)。
    private var scaledSimTime: CFTimeInterval = 0
    private var lastWallTime: CFTimeInterval = 0

    // 审计修复 #1:frameTick(CVDisplayLink 后台线程)的 engine.update/render 与
    // load/reloadInPlace/stop(主线程)对 engine 状态(layers/particleGroups)的重建/释放
    // 之间存在无锁数据竞争。用此锁串行化两侧对 engine 的访问。
    private let renderLock = NSLock()
    // AppKit 窗口几何只在主线程捕获；渲染线程只读这份快照，不碰 NSScreen/NSWindow。
    private let mouseViewportLock = NSLock()
    private var mouseViewportFrame = CGRect.zero
    private var quartzMainDisplayHeight: CGFloat = 0

    init() { engine = SceneRenderEngine() }

    private func captureMouseViewport(_ host: NSView) {
        let frame: CGRect
        if let window = host.window {
            frame = window.convertToScreen(host.convert(host.bounds, to: nil))
        } else {
            frame = .zero
        }
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        mouseViewportLock.lock()
        mouseViewportFrame = frame
        quartzMainDisplayHeight = mainHeight
        mouseViewportLock.unlock()
    }

    private func mouseViewportSnapshot() -> (CGRect, CGFloat) {
        mouseViewportLock.lock()
        let snapshot = (mouseViewportFrame, quartzMainDisplayHeight)
        mouseViewportLock.unlock()
        return snapshot
    }

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
        // nextDrawable 在窗口暂时不可合成时最多等待系统超时，不能无限卡住我们的串行渲染线程。
        layer.allowsNextDrawableTimeout = true
        // 内屏 120Hz ProMotion「3 分带」修复:保持 Metal 标准的 command-buffer present，启用 vsync
        //   并改为双缓冲。不要使用 presentsWithTransaction：桌面窗口长期由后台线程驱动时，CA transaction
        //   可能停止提交，两个 drawable 都等不到 presented 回调，最终整张桌面黑屏。
        if WPEnv.vars["WP_SYNC_PRESENT"] == "1" || PreferencesStore.shared.syncPresent {
            layer.presentsWithTransaction = false
            layer.displaySyncEnabled = true         // 强制 vsync(默认本就 true,显式保证)
            layer.maximumDrawableCount = 2          // 双缓冲(默认 3)——减少在途 drawable,避免合成抓到多帧
            Log.write("SceneRenderer: 同步呈现(vsync+双缓冲 Metal present；禁用 CA transaction 防久运行黑屏)")
        }
        // 在途门按真实 drawable 槽数(默认 3 / 同步呈现 2)——nextDrawable 只在有空槽时调,过场时跳帧不阻塞。
        drawableMax = max(1, layer.maximumDrawableCount)
        layer.frame = host.bounds
        layer.contentsScale = host.window?.backingScaleFactor ?? 2.0
        host.layer?.addSublayer(layer)
        metalLayer = layer
        captureMouseViewport(host)
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard let layer = metalLayer, let host = hostView else { return }
        // ⚠ layer.frame 永远 = 全屏点尺寸(WindowServer 据此把 layer 内容铺满屏)。
        //   只把 drawableSize 缩小成「屏幕像素 × presentScale」→ WindowServer 拿到一张更小的 surface、
        //   缩放填满屏(它缩放比合成全分辨率便宜很多)→ 同时降【WindowServer 合成成本】+【我们渲染像素】
        //   +【present surface 大小】。render(to:viewportSize:) 全链按 drawable 实际像素驱动(aspectMap 等只看
        //   outW/outH + canvas 长宽比),drawableSize 等比缩 → 长宽比不变、无形变、无错位。layer.frame 不动、
        //   present 同步逻辑(presentsWithTransaction/CATransaction/waitUntilCompleted)全在 engine.render 内
        //   不受影响 → 不破坏内屏防撕裂。WP_PRESENT_SCALE / 设置项可调,默认 0.8。
        layer.frame = host.bounds
        captureMouseViewport(host)
        let scale = host.window?.backingScaleFactor ?? 2.0
        let ps = PreferencesStore.shared.presentScale
        // 缩放后向下取偶(避免奇数宽在最终 blit/采样出现半像素接缝);并保底 ≥2。
        let pw = max(2, (Int((host.bounds.width * scale * ps).rounded()) / 2) * 2)
        let ph = max(2, (Int((host.bounds.height * scale * ps).rounded()) / 2) * 2)
        let size = CGSize(width: pw, height: ph)
        if size.width > 0 && size.height > 0 { layer.drawableSize = size }
        Log.write(String(format: "drawable: bounds=%.0fx%.0f scale=%.2f(win=%@) presentScale=%.2f drawableSize=%.0fx%.0f contentsScale=%.2f",
                         host.bounds.width, host.bounds.height, scale,
                         host.window == nil ? "nil" : "ok", ps, size.width, size.height, layer.contentsScale))
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

    /// 本次加载的渲染缺口(引擎收集:🔴覆盖问题/未转译特效/combo变体缺失)。供 UI 弹窗指明。
    var renderGaps: [String] { engine?.renderGaps ?? [] }

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
        // 解码失败的回退预览图:用 **cover**(保比例铺满裁切)而非旧的 fit(.scaleProportionallyUpOrDown 居中留黑边
        //   =看起来"没全屏")。layer contentsGravity .resizeAspectFill 不变形、裁掉溢出,与正常壁纸 cover 一致。
        let iv = NSView(frame: host.bounds)
        iv.autoresizingMask = [.width, .height]
        iv.wantsLayer = true
        iv.layer?.contents = img
        iv.layer?.contentsGravity = .resizeAspectFill
        iv.layer?.masksToBounds = true
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
        // ⚠ 回调上下文必须是**独立于 SceneRenderer 生命周期**的堆对象。
        //   原来直接传 `Unmanaged.passUnretained(self)`:CVDisplayLinkStop **不保证**正在执行的回调已返回,
        //   而切壁纸走 `renderers.forEach { $0.stop() }; renderers.removeAll()`(DesktopController),
        //   stop() 一返回 renderer 就析构 → 在途回调里 `fromOpaque().takeUnretainedValue()` 触到已释放内存
        //   = use-after-free(崩在 CoreVideo 私有线程,表现为切壁纸偶发闪退、栈难归因)。
        //   改:上下文是 passRetained 的独立盒子,盒内 **weak** 持有 renderer(weak 读取线程安全,对象析构后
        //   自动为 nil → 回调空跑);盒子在 stop() 里、**等 displayLink 释放之后**再 release(见 stop())。
        let box = LinkContext(self)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        linkContext = ctx
        CVDisplayLinkSetOutputCallback(link, { (_, _, _, _, _, userInfo) -> CVReturn in
            guard let userInfo else { return kCVReturnSuccess }
            let box = Unmanaged<LinkContext>.fromOpaque(userInfo).takeUnretainedValue()
            guard let me = box.owner else { return kCVReturnSuccess }   // renderer 已析构 → 空跑,不触已释放内存
            me.lastLinkTick = CACurrentMediaTime()   // 标记显示链「刚回调过」,备用计时器据此判是否被节流
            me.scheduleFrameTick()
            return kCVReturnSuccess
        }, ctx)
        CVDisplayLinkStart(link)
        displayLink = link
        startStallBridge()
    }

    /// 备用渲染驱动:桥过台前调度切换时系统节流 CVDisplayLink 回调造成的卡顿(见 lastLinkTick 注释)。
    /// 正常播放时显示链按时回调 → lastLinkTick 持续刷新 → 本计时器什么都不做(零额外渲染);
    /// 仅当显示链回调停滞 >50ms 且未被 PowerManager 暂停(壁纸仍可见、只是切换过场)时,以 ~33Hz 调
    /// frameTick 接管;显示链恢复后 lastLinkTick 变新 → 自动让位。frameTick 内有帧门串行 + 帧率上限,
    /// 故两个驱动并发不会重复渲染或竞争。暂停时(被全屏 App 完全遮挡)不接管 → 不浪费 CPU 渲不可见画面。
    private func startStallBridge() {
        stallTimer?.cancel()
        let q = DispatchQueue(label: "com.a55555.livewallpaper.stallbridge", qos: .userInteractive)
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.03, repeating: 0.03, leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in
            guard let self, !self.paused, self.loaded else { return }
            if CACurrentMediaTime() - self.lastLinkTick > 0.05 { self.scheduleFrameTick() }
        }
        t.resume()
        stallTimer = t
    }

    /// 从 CVDisplayLink/备用计时器请求一帧。调用方线程只做一次非阻塞 gate + enqueue；
    /// JavaScriptCore、鼠标/AppKit 查询、Metal 编码全部在大栈 frameQueue 上执行。
    private func scheduleFrameTick() {
        // 非阻塞抢门:上一帧还没结束就直接丢帧(不让显示链 120Hz 把队列堆成长尾)。
        tickLock.lock()
        if tickInFlight { tickLock.unlock(); return }
        tickInFlight = true
        tickLock.unlock()
        let accepted = frameQueue.async { [weak self] in
            defer { self?.releaseTickGate() }
            self?.frameTick()
        }
        if !accepted { releaseTickGate() }
    }

    private func releaseTickGate() {
        tickLock.lock()
        tickInFlight = false
        tickLock.unlock()
    }

    /// 大栈串行工作线程上的一帧。Metal 命令缓冲区线程安全;鼠标位置用全局函数获取。
    private func frameTick() {
        // 诊断台前调度卡顿(WP_STUTTER_LOG=1):每次回调记间隔,>0.3s 的掉帧打日志含 paused/显示链状态——
        //   若 link=run 但间隔大=系统对(遮挡)窗口节流显示链;paused=Y=PowerManager 暂停;link=stop=链被停。
        let _tw = CACurrentMediaTime()
        if stutterLog, lastTickWall > 0 {
            let g = _tw - lastTickWall
            if g > 0.3 {
                // 持锁读 displayLink:它是强引用 var,stop() 在 renderLock 内置 nil;ARC 的 retain 与
                // 并发置 nil 组合不是原子的(锁外裸读 = 可能对已释放对象 retain → double free)。
                renderLock.lock()
                let lr = displayLink.map { CVDisplayLinkIsRunning($0) } ?? false
                renderLock.unlock()
                Log.write(String(format: "FRAMEGAP %.2fs paused=%@ link=%@", g, paused ? "Y" : "N", lr ? "run" : "stop"))
            }
        }
        lastTickWall = _tw
        // 同上:metalLayer 是强引用 var,stop() 在 renderLock 内置 nil。这里持锁**快照**出来
        // (只取引用,不做任何重活),锁外继续用局部量;下面 renderLock 内还有一次拆除重校验。
        renderLock.lock()
        let ready = !paused && loaded
        let layerRef = metalLayer
        renderLock.unlock()
        guard ready, let engine, let layer = layerRef else { return }
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

        // 鼠标相对**当前壁纸窗口**归一化到 [-1,1](y 向上)。
        // ⚠ 关键(xray/视差不跟鼠标真因):本 app 是 .accessory 菜单栏代理,桌面窗口 ignoresMouseEvents=true 且
        //   canBecomeKey=false、全程无任何鼠标事件监视器 → 进程事件流为空 → `NSEvent.mouseLocation` 会**冻结**在
        //   最后一次有焦点时的值(实测卡死在 (-0.74,-0.36) 数千帧不变)→ xray 的 g_PointerPosition 恒定、揭示框不动。
        //   改用 CoreGraphics 全局硬件光标(windowserver 当前位置,不依赖本进程事件流);CG 是左上原点 y 向下,
        //   转回 AppKit 左下原点 y 向上:y = 主屏高度 - cg.y。CG/AppKit 的全局坐标都以主屏为基准，
        //   不能用“所有屏的 maxY”，否则显示器在主屏上方/下方时会整体错一屏。
        let cgLoc = CGEvent(source: nil)?.location ?? .zero
        let (mouseViewport, mainDisplayHeight) = mouseViewportSnapshot()
        let mouse = WEMouseViewportMath.appKitPoint(fromQuartz: cgLoc,
                                                    mainDisplayHeight: mainDisplayHeight)
        var mn = SIMD2<Float>(0, 0)
        // WE「属性」通用区·鼠标视差总闸:用户在该壁纸关掉「鼠标视差」→ 喂引擎归中光标(mn=0),
        //   引擎的鼠标驱动视差/交互(cameraparallax + xray/depthparallax)随之平滑归中、停止跟随。
        //   默认开 → 走真实光标 → 现状行为零回归。这是全引擎统一的鼠标输入入口,无需改 SceneRenderEngine。
        let mouseParallaxOn = GeneralWallpaperSettings.shared.mouseParallax(loadedItem?.id ?? "")
        if mouseParallaxOn {
            mn = WEMouseViewportMath.normalized(point: mouse, viewport: mouseViewport)
        }

        // 审计修复 #1:整段 update+render 持锁,防止主线程在此期间重建/释放 engine 状态(数据竞争)。
        // 锁内只做 GPU 命令编码(nextDrawable 可能阻塞但不回主线程同步等待),不会与主线程死锁。
        let _flog = WPEnv.vars["WP_FRAME_LOG"] != nil
        let _t0 = _flog ? CACurrentMediaTime() : 0
        renderLock.lock()
        // ⭐2026-06-24 切壁纸竞态修:L209 在锁外捕获了 engine/layer 局部;若此刻 stop() 已在主线程拿锁置
        //   loaded=false/metalLayer=nil(正在拆除),本帧不应再用 stale 的 layer 渲染(nextDrawable 可能阻塞/失败)。
        //   锁内重校验当前状态,已拆除则立刻放锁退出。
        guard loaded, metalLayer != nil else { renderLock.unlock(); return }
        engine.update(time: t, mouseNorm: mn)
        let _tU = _flog ? CACurrentMediaTime() : 0
        // 按需渲染:无连续动画内容、视差已收敛且鼠标未动 → 画面与上帧一致,跳过渲染(空闲 CPU/GPU 趋近 0)。
        guard engine.frameDidChange else { renderLock.unlock(); return }
        // 在途门:槽满(台前调度过场,WindowServer 暂停合成)→ 立即跳帧(不阻塞在 nextDrawable ~1s)。
        guard let acq = acquireDrawable(layer) else { renderLock.unlock(); return }
        let _tD = _flog ? CACurrentMediaTime() : 0
        let submitted = engine.render(to: acq.drawable, viewportSize: layer.drawableSize)
        if !submitted {
            // acquireDrawable 已占一个名额；未提交 present 时不会收到 addPresentedHandler，必须在这里归还。
            releaseDrawableSlot(acq.token)
            let now = CACurrentMediaTime()
            if now - lastDrawableFailureLog > 2 {
                Log.write("SceneRenderer: 本帧未提交，已归还 drawable 槽（保留上一帧，避免黑屏/永久停帧）")
                lastDrawableFailureLog = now
            }
        }
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

    /// 取 drawable 前先过在途门(见 drawableInflight 注释):空槽→nextDrawable(不会阻塞,因有空槽);
    /// 槽满(台前调度过场,present 回调停滞)→ 立即返回 nil(调用方跳帧,不阻塞 ~1s)。drawable present 后
    /// addPresentedHandler 还槽。nextDrawable 罕见返 nil(拆除中)时立刻还槽。handler 用 weak self,析构后空跑。
    private func acquireDrawable(_ layer: CAMetalLayer) -> (drawable: CAMetalDrawable, token: Int)? {
        drawableLock.lock()
        let now = CACurrentMediaTime()
        // 兜底回收:present 回调理应在一两帧内到达。若某个在途槽超过 drawableStaleTimeout 仍未归还,
        //   认定该回调**永久丢失**(拆除中/WindowServer 异常),强制回收。没有这层兜底时,一次丢失的
        //   回调就让槽位永久少一个,累计到 drawableMax 后 acquireDrawable 恒返回 nil →
        //   该 renderer 所有后续帧被跳过 = 画面永久定格且无自愈,只能切壁纸重建(审计 R7)。
        // ⚠ 必须用 token 而不是「按时间减计数」:被判定丢失的回调**可能迟到**(台前调度过场时
        //   present 会停滞约 1s),若那时再减一次就成了二次递减 → 计数低于真实在途数 → 门形同虚设 →
        //   退回 nextDrawable 阻塞。token 从字典移除后,迟到回调找不到自己的槽,自然空跑。
        var staleCount = 0
        for (tok, at) in drawableSlots where now - at > Self.drawableStaleTimeout {
            drawableSlots.removeValue(forKey: tok); staleCount += 1
        }
        if staleCount > 0, now - lastStaleReclaimLog > 5 {
            lastStaleReclaimLog = now
            Log.write("SceneRenderer: 回收 \(staleCount) 个超时未归还的 drawable 槽(present 回调丢失,已自愈)")
        }
        if drawableSlots.count >= drawableMax { drawableLock.unlock(); return nil }  // 槽满 → 跳帧
        let token = nextDrawableToken
        nextDrawableToken &+= 1
        drawableSlots[token] = now
        drawableLock.unlock()
        guard let d = layer.nextDrawable() else {
            releaseDrawableSlot(token); return nil
        }
        d.addPresentedHandler { [weak self] _ in self?.releaseDrawableSlot(token) }
        return (d, token)
    }

    /// 归还槽位。按 token 移除:重复归还(兜底回收后迟到的 present 回调)自然是空操作。
    private func releaseDrawableSlot(_ token: Int) {
        drawableLock.lock()
        drawableSlots.removeValue(forKey: token)
        drawableLock.unlock()
    }

    private func drawOnce() {
        guard loaded, let engine, let layer = metalLayer else { return }
        updateDrawableSize()
        // 审计修复 #1:与 frameTick 共用 engine,持锁防竞争。
        renderLock.lock()
        engine.update(time: 0, mouseNorm: SIMD2(0, 0))
        guard let acq = acquireDrawable(layer) else { renderLock.unlock(); return }
        let submitted = engine.render(to: acq.drawable, viewportSize: layer.drawableSize)
        if !submitted { releaseDrawableSlot(acq.token) }
        renderLock.unlock()
    }

    func stop() {
        engine?.releaseAudio()
        stallTimer?.cancel(); stallTimer = nil
        // 审计修复 #1:先停显示链,再持锁拆除 —— CVDisplayLinkStop 后持锁可确保正在执行的
        // frameTick 回调已结束(它在锁内编码),再置 nil/释放 engine 相关状态,避免拆除中竞争。
        if let link = displayLink { CVDisplayLinkStop(link) }
        renderLock.lock()
        displayLink = nil
        metalLayer?.removeFromSuperlayer()
        metalLayer = nil
        loaded = false
        renderLock.unlock()
        // 显示链已 Stop 且强引用已置 nil(CVDisplayLink 的最后一次 release 会停掉并 join 它的线程),
        // 此后不会再有回调进来 → 现在才可以安全释放回调上下文盒子。顺序不能反:先放盒子再放链
        // 会让在途回调 fromOpaque 到已释放的盒子。
        if let c = linkContext { Unmanaged<LinkContext>.fromOpaque(c).release(); linkContext = nil }
        fallbackImageView?.removeFromSuperview()
        fallbackImageView = nil
        hostView = nil
        frameQueue.shutdown()
        // shutdown() 会丢弃已入队但未执行的帧任务(它们的 defer 不会跑)→ 显式复位帧门,
        // 使旗标不会滞留在 true。旧实现这里是 DispatchSemaphore,丢任务=计数不还=析构 SIGTRAP。
        releaseTickGate()
    }

    /// 互动 hit-test:转发引擎(持锁,与渲染线程同步,interactiveHitAt 只读 layers 很快)。光标命中可交互对象→返回 id。
    func interactiveHitTest(mouseNorm: SIMD2<Float>) -> Int? {
        renderLock.lock(); defer { renderLock.unlock() }
        return engine?.interactiveHitAt(mouseNorm: mouseNorm)
    }

    func pause() {
        paused = true
        // ⭐不停 CVDisplayLink——只靠 frameTick 的 `!paused` 提前返回跳过渲染。这样 resume 是即时旗标翻转,
        //   没有 CVDisplayLinkStart 冷重启的 ~1s 延迟(台前调度「显示桌面」后壁纸恢复卡顿的真因之一)。
        //   被全屏 App 完全遮挡时 macOS 会自动 throttle 本(离屏)窗口的显示链回调,空转(早返回)开销可忽略。
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
