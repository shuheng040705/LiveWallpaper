import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import simd

/// 首页 hero 高清图:渲染壁纸**实际画面**(场景=引擎离屏渲染一帧、视频=抽帧),磁盘 + 内存缓存。
/// 比 pkg 自带的低清 preview.gif 清晰得多(用户要求「放实际渲染图」)。
/// 失败 / web 类型 / 关闭(WP_NO_RENDERED_HERO)时回退到 ThumbnailCache.largeImage(preview.gif)。
final class RenderedPreviewCache {
    static let shared = RenderedPreviewCache()

    private let mem = NSCache<NSString, NSImage>()

    private init() {
        // 内存中只缓存最近浏览到的若干张渲染预览(每张 ≤1600px 长边、可达数 MB);
        // 加 count 上限,避免整库逐张浏览后内存里堆几百张大 NSImage(磁盘 PNG 仍在,逐出后从磁盘秒读回)。
        mem.countLimit = 60
    }
    // 串行**后台**队列:一次只渲一张,避免多张场景同时占 GPU 影响正在播放的桌面壁纸。
    // QoS=.background(原 .utility):库预览是「锦上添花」的回退图(仅近全黑首帧的场景才走),
    // 不应与正在播放的桌面壁纸抢 GPU/CPU;调度优先级压到最低,渲染线程让位给壁纸。
    private let queue = DispatchQueue(label: "rendered-preview", qos: .background)
    private var inFlight = Set<String>()
    // 已请求但尚未开始渲染的 item:卡片滚出视口(onDisappear)/窗口隐藏时移除 → 跳过其渲染。
    // 这样滚动浏览时只渲「当前真正可见且需要回退渲染图」的少量卡片,不把整库排满队列。
    private var requested = Set<String>()
    private let lock = NSLock()

    /// 库窗口是否可见。窗口关闭/隐藏时由 LibraryWindowController 置 false:
    /// → 新的预览渲染请求一律拒绝(回退 gif),队列里尚未开始的也会因 requested 被清而跳过。
    /// 默认 false:只有库窗口打开时才允许渲染预览(后台壁纸进程平时不该渲库预览)。
    private var windowVisible = false
    func setWindowVisible(_ v: Bool) {
        lock.lock()
        windowVisible = v
        if !v { requested.removeAll() }   // 窗口隐藏:清掉所有「待渲染」请求,队列中的任务到点自检会跳过
        lock.unlock()
    }

    /// 卡片滚出视口 / 不再需要渲染:撤销该 item 的渲染请求(若尚未开始)。
    func cancel(_ id: String) {
        lock.lock(); requested.remove(id); lock.unlock()
    }

    private var cacheDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.a55555.livewallpaper/RenderedPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 启动时调一次:清空磁盘预览缓存 → 首页预览本次会话重新渲染一遍(反映引擎最新改动)。
    /// 用户要求「首页渲染每次重启重新渲染一次」(否则旧磁盘缓存永久不更新、看不到引擎修复后的新画面)。
    /// WP_NO_PREVIEW_REFRESH=1 跳过(保留旧磁盘缓存,省启动渲染)。
    func invalidateAllOnLaunch() {
        if WPEnv.vars["WP_NO_PREVIEW_REFRESH"] != nil { return }
        mem.removeAllObjects()
        try? FileManager.default.removeItem(at: cacheDir)
        _ = cacheDir   // 重新创建空目录
    }

    /// 异步取壁纸实际画面高清图。命中内存/磁盘即时返回;否则后台渲染后回主线程回调。
    /// 关闭(WP_NO_RENDERED_HERO)或不支持(web)→ 回调 nil(调用方回退 gif)。
    func image(for item: WallpaperItem, completion: @escaping (NSImage?) -> Void) {
        if WPEnv.vars["WP_NO_RENDERED_HERO"] != nil { completion(nil); return }
        let key = item.id as NSString
        // 命中内存/磁盘缓存:即时返回(不受窗口可见性限制,缓存读极廉价)。
        if let c = mem.object(forKey: key) { completion(c); return }
        let file = cacheDir.appendingPathComponent("\(item.id).png")
        if let img = NSImage(contentsOf: file) { mem.setObject(img, forKey: key); completion(img); return }

        lock.lock()
        // 库窗口不可见 → 不启动任何离屏渲染(后台壁纸进程平时不渲库预览,省 CPU/GPU)。
        guard windowVisible else { lock.unlock(); completion(nil); return }
        if inFlight.contains(item.id) { lock.unlock(); completion(nil); return }
        inFlight.insert(item.id)
        requested.insert(item.id)
        lock.unlock()

        queue.async {
            // ⚠ 内存增长修复:整段离屏渲染包进 autoreleasepool。一次预览要暖机 300~900 帧、解码整张壁纸
            //   的全部贴图、读回 PNG —— 期间产生大量 autoreleased 的 Metal 纹理/IOSurface/CGImage。本任务跑在
            //   忙碌的串行后台队列上,连续浏览时线程一直不空闲、不回 dispatch 事件循环 → 默认 pool 迟迟不 drain,
            //   这些大对象在突发浏览中持续堆积(实测 374MB→1.38GB 的诱因之一)。显式 pool 让每张预览渲完即回收。
            autoreleasepool {
            // 真正开始渲染前再自检一次:期间窗口可能已关闭、或卡片已滚出视口被 cancel。
            // 串行队列前面排着的渲染可能已耗时,此处跳过避免做无用功(浏览滚动时尤其有效)。
            self.lock.lock()
            let stillWanted = self.windowVisible && self.requested.contains(item.id)
            self.requested.remove(item.id)
            if !stillWanted { self.inFlight.remove(item.id); self.lock.unlock(); DispatchQueue.main.async { completion(nil) }; return }
            self.lock.unlock()

            let img = Self.render(item: item, to: file)
            if let img { self.mem.setObject(img, forKey: key) }
            self.lock.lock(); self.inFlight.remove(item.id); self.lock.unlock()
            DispatchQueue.main.async { completion(img) }
            }
        }
    }

    private static func render(item: WallpaperItem, to file: URL) -> NSImage? {
        switch item.type {
        case .scene:
            return renderScene(item: item, to: file)
        case .video:
            return renderVideo(item: item, to: file)
        default:
            return nil   // web 等暂回退 gif
        }
    }

    /// 场景:用 SceneRenderEngine 离屏渲染一帧(暖机若干帧让粒子/动画/3D 就位),写 PNG 缓存。
    /// 暖机默认 300 帧(=5s @60fps):开场动画类壁纸(琉璃/岚玉等)的黑幕层有 alpha 关键帧 1→0,
    /// 需约 5s 才完全淡出;旧默认 90 帧(1.5s)渲到黑幕未淡完 → 预览全黑(见 [[instanced-placeholder-black]])。
    /// WP_HERO_WARM 可覆盖。
    private static func renderScene(item: WallpaperItem, to file: URL) -> NSImage? {
        guard let source = SceneSourceFactory.make(for: item),
              let doc = SceneDocument.build(from: source, item: item),
              let engine = SceneRenderEngine() else { return nil }
        engine.load(document: doc, source: source)
        let env = WPEnv.vars
        let warm = Int(env["WP_HERO_WARM"] ?? "300") ?? 300
        let dt = 1.0 / 60.0
        // 暖机每帧包 autoreleasepool:engine.update 内部每帧分配命令缓冲区/临时纹理,逐帧 drain 把单张预览的
        // 峰值内存压到一帧的量(否则 300~900 帧的临时对象在这次渲染内累积成一个大尖峰)。
        for i in 0..<max(1, warm) { autoreleasepool { engine.update(time: Double(i) * dt, mouseNorm: .zero) } }
        // 目标尺寸:画布比例,长边封顶 1600(够清晰、控显存)。
        let cw = max(1, Int(doc.canvasWidth)), ch = max(1, Int(doc.canvasHeight))
        var w = cw, h = ch
        let longSide = 1600
        if max(cw, ch) > longSide {
            let s = Double(longSide) / Double(max(cw, ch))
            w = max(1, Int(Double(cw) * s)); h = max(1, Int(Double(ch) * s))
        }
        guard engine.renderToPNG(width: w, height: h, outURL: file) else { return nil }
        // 全黑兜底:暖机后仍接近全黑(开场动画淡出更慢/慢启动场景),再多暖机一段重渲一次。
        // 通用兜底,不针对特定壁纸。WP_NO_PREVIEW_DEBLACK=1 关闭。
        if env["WP_NO_PREVIEW_DEBLACK"] == nil,
           let m = meanLuminance(of: file), m < 8 {
            let extra = Int(env["WP_HERO_DEBLACK_WARM"] ?? "600") ?? 600
            for i in warm..<max(warm + 1, extra) { autoreleasepool { engine.update(time: Double(i) * dt, mouseNorm: .zero) } }
            _ = engine.renderToPNG(width: w, height: h, outURL: file)
        }
        return NSImage(contentsOf: file)
    }

    /// 读回 PNG 算平均亮度(0~255),用于检测渲染输出是否全黑。失败返回 nil(不触发兜底)。
    private static func meanLuminance(of file: URL) -> Double? {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = min(cg.width, 64), h = min(cg.height, 64)   // 缩到 ≤64² 算,够判全黑且极快
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var total = 0.0
        var i = 0
        while i < buf.count {
            total += Double(buf[i]) + Double(buf[i + 1]) + Double(buf[i + 2])
            i += 4
        }
        return total / Double(w * h * 3)
    }

    /// 视频:抽 ~1s 处一帧。
    private static func renderVideo(item: WallpaperItem, to file: URL) -> NSImage? {
        guard let url = item.fileURL else { return nil }
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1600, height: 1600)
        // 抽 ~1s 处一帧;短视频/超界则 copyCGImage 失败 → 回退首帧(.zero)。
        // 不读 asset.duration:macOS 13 起弃用(同步取需 async load(.duration),renderVideo 是同步上下文),
        // 而预览缩略图本不需要精确时长——1s 抽帧 + .zero 回退已足够。
        let t = CMTime(seconds: 1.0, preferredTimescale: 600)
        guard let cg = (try? gen.copyCGImage(at: t, actualTime: nil))
                ?? (try? gen.copyCGImage(at: .zero, actualTime: nil)) else { return nil }
        if let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg, nil)
            CGImageDestinationFinalize(dest)
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
